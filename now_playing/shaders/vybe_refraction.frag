#version 460 core
#include <flutter/runtime_effect.glsl>

// BackdropFilter/ImageFilter.shader automatically supplies size and texture.
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_time;
uniform float u_bass;
uniform float u_strength;
uniform float u_mode; // 0 liquid, 1 vortex, 2 prism, 3 holographic
uniform float u_blendMode; // 0 normal, 1 screen, 2 multiply, 3 overlay, 4 soft light, 5 dodge, 6 difference, 7 hue shift
uniform float u_blendOpacity;
uniform float u_effectSize;
uniform float u_pulseAge; // Time since last REAL FFT bass onset, 99 = none.
uniform vec3 u_colorA;
uniform vec3 u_colorB;
uniform vec3 u_colorC;
uniform vec2 u_origin; // Artwork center in normalized screen coordinates.
out vec4 fragColor;

float hash21(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float gauss(float x, float width) {
  float d = x / max(width, 0.0001);
  return exp(-d*d);
}
vec3 fxColor(float f) {
  return mix(mix(u_colorA, u_colorB, clamp(f * 2.0, 0.0, 1.0)),
             u_colorC, clamp(f * 2.0 - 1.0, 0.0, 1.0));
}

float wave(vec2 p, float t) {
  return sin(p.x * 12.0 + sin(p.y * 7.0 + t * 0.37) * 1.7 + t * 0.78)
       * cos(p.y * 15.0 - t * 0.59 + sin(p.x * 8.0 - t * 0.27));
}

void main() {
  vec2 uv = FlutterFragCoord().xy / max(u_size, vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  float strength = clamp(u_strength, 0.0, 1.0);
  float bass = clamp(u_bass, 0.0, 1.0);
  float t = u_time;
  vec2 p = uv * vec2(u_size.x / max(u_size.y, 1.0), 1.0) / max(0.5, u_effectSize);
  float a = wave(p, t);
  float b = wave(p.yx * 1.21 + vec2(1.7, 0.8), t * 0.83);
  float mode = floor(u_mode + 0.5);
  // Only liquid refraction uses the shared wave. Other modes must have
  // independent displacement fields or they all look like wavy water.
  vec2 displacement = mode < 0.5
      ? vec2(a, b) * (0.006 + bass * 0.009) * strength
      : vec2(0.0);
  float glassHighlight = 0.0;
  vec3 illumination = vec3(0.0);
  vec2 origin = clamp(u_origin, vec2(-0.15), vec2(1.15));
#ifdef IMPELLER_TARGET_OPENGLES
  origin.y = 1.0 - origin.y;
#endif
  // Aspect-correct radial space makes rings and trails circular in pixels.
  vec2 aspect = vec2(u_size.x / max(u_size.y, 1.0), 1.0);
  vec2 d = (uv - origin) * aspect;
  float radius = length(d);
  vec2 radial = d / max(radius, 0.001) / aspect;
  float theta = atan(d.y, d.x);
  if (mode > 0.5 && mode < 1.5) {
    // Actual rotational image mapping, accelerated near the artwork.
    // The scene spirals into a dark perspective tunnel, not a sine wobble.
    float proximity = exp(-radius * 1.85 / max(u_effectSize, 0.5));
    float twist = (1.55 + bass * .55) * strength * proximity *
        (0.83 + 0.17 * sin(t * 0.37));
    float spin = t * 0.78;
    float cs = cos(twist), sn = sin(twist);
    vec2 rotated = vec2(cs*d.x - sn*d.y, sn*d.x + cs*d.y);
    float depthPull = 1.0 - (0.34 + 0.10 * bass) * strength * proximity;
    displacement += (rotated * depthPull - d) / aspect;
    // The spinning luminous arms and receding concentric tunnel are
    // visible even where the underlying photograph has little detail.
    float spiral = pow(max(0.0,
        sin(theta * 4.0 + 16.0 * log(radius + 0.075) + spin * 2.0)), 12.0);
    float ring = pow(max(0.0,
        cos(26.0 * log(radius + 0.10) + spin * 2.3)), 22.0);
    float visibility = smoothstep(.08, .22, radius) *
        (1.0 - smoothstep(.75, 1.35, radius));
    illumination += fxColor(.5 + .35 * sin(theta + spin)) *
        (spiral * .58 + ring * .23) * visibility;
  } else if (mode > 1.5 && mode < 2.5) {
    // Sparse, irregular floating refractive shards, each with a unique size,
    // depth, velocity and rotation. No tiled cells or painted geometry.
    vec2 shardShift = vec2(0.0);
    float bestDepth = -1.0;
    for (int i = 0; i < 18; i++) {
      float fi = float(i);
      float seed = fract(sin(fi * 71.37 + 4.2) * 43758.5453);
      float seed2 = fract(sin(fi * 39.83 + 18.3) * 22578.1453);
      float depth = 0.3 + 0.7 * fract(sin(fi * 13.17 + 7.0) * 19453.3);
      vec2 center = vec2(fract(seed * 5.73 + 0.14), fract(seed2 * 8.91 + 0.27));
      center += vec2(sin(t * (0.065 + depth * 0.085) + fi), cos(t * (0.055 + depth * 0.07) + fi * 1.7)) * 0.12;
      vec2 local = (uv - center) / max(0.5, u_effectSize);
      float angle = seed2 * 6.283185 + sin(t * 0.15 + fi) * 0.36;
      local = mat2(cos(angle), -sin(angle), sin(angle), cos(angle)) * local;
      float width = mix(0.055, 0.17, seed) * (0.6 + depth * 0.6);
      float height = mix(0.055, 0.22, seed2) * (0.6 + depth * 0.6);
      // Three half-planes describe a free-floating triangle; softened edges.
      float edge = min(min(local.y + height * 0.48, local.x * 0.85 - local.y * 0.48 + width * 0.55),
          -local.x * 0.85 - local.y * 0.48 + width * 0.55);
      float mask = smoothstep(-0.008, 0.009, edge) * (0.4 + depth * 0.6);
      if (mask > 0.01 && depth > bestDepth) {
        bestDepth = depth;
        // Thin specular highlight on the lit facet, with occasional glints.
        // Never outline all three edges.
        float litEdge = 1.0 - smoothstep(0.0, 0.018, abs(local.y + height * 0.48));
        float sparkle = pow(max(0.0, sin(t * 1.15 + fi * 2.7)), 16.0);
        glassHighlight = (litEdge * 0.18 + litEdge * sparkle * 0.22) * mask;
        shardShift = vec2(cos(angle + fi * 0.91), sin(angle + fi * 0.91)) *
          (0.012 + depth * 0.032 + bass * 0.012) * mask;
      }
    }
    displacement += shardShift * strength;
  } else if (mode > 2.5 && mode < 3.5) {
    // Holographic scan interference warps source pixels, not just scanlines.
    float bands = sin(uv.y * 148.0 - t * 2.7) * sin(uv.y * 27.0 + t * 0.6);
    displacement += vec2(bands * 0.0065, 0.0) * strength;
    illumination += fxColor(0.4) * gauss(bands, 0.18) * 0.08;
  } else if (mode > 3.5 && mode < 4.5) {
    // Bass Shockwave: a genuine circular refractive compression wave.
    float age = u_pulseAge;
    if (age >= 0.0 && age < 1.3) {
      float head = 0.075 + age * 0.57;
      float ring = gauss(radius - head, 0.038 + age * 0.010);
      float impulse = (1.0 - age / 1.3);
      displacement += radial * ring * 0.062 * strength * impulse;
      illumination += fxColor(0.55) * ring * 0.19 * impulse;
    }
  } else if (mode > 4.5 && mode < 5.5) {
    // Aurora Curtains: refractive, layered colored light sheets.
    float p1 = sin(p.x * 13.0 + t * 0.43 + sin(p.y * 5.5 - t * .21));
    float p2 = cos(p.x * 7.3 - t * 0.31 + sin(p.y * 7.0 + t * .13));
    float fold = p1 * .72 + p2 * .28;
    displacement.x += fold * 0.021 * strength;
    float curtain = pow(max(0.0, 1.0 - abs(fold)), 3.0);
    illumination += mix(u_colorA, u_colorC, uv.x) *
        curtain * (.13 + bass * .14);
  } else if (mode > 5.5 && mode < 6.5) {
    // Lightning bolts branch radially from the artwork; jagged and
    // intermittent rather than another set of horizontal sine lines.
    for (int i = 0; i < 7; i++) {
      float fi = float(i);
      float direction = fi * 2.399963 + .22 * sin(t*.27+fi*1.9)
          + .05 * sin(radius*82.0 + floor(t*13.0)+fi*7.1)
          + .025 * sin(radius*183.0 - floor(t*21.0)+fi*13.7);
      float lateral = atan(sin(theta-direction),cos(theta-direction))*radius;
      float reach = smoothstep(.08,.25,radius) *
          (1.0-smoothstep(.75,1.40,radius));
      float flash = .22 + .78 * pow(max(0.0,
          sin(t*4.9+fi*3.7)), 7.0);
      float core = gauss(lateral,.0045) * reach * flash;
      float halo = gauss(lateral,.035) * reach * flash;
      illumination += (fxColor(fi/7.0)*.9+vec3(.55)*core) *
          (core*.90+halo*.34);
      displacement += radial * halo * .012 * strength;
    }
  } else if (mode > 6.5 && mode < 7.5) {
    // Light Trails have overlapping life cycles. After the bright head
    // travels away, the previous trail remains in place, thins and fades.
    // Continuing the prior generation across the modulo boundary prevents
    // the whole streak abruptly disappearing and restarting.
    for (int i = 0; i < 9; i++) {
      float fi = float(i);
      float direction = fi * 2.399963 + sin(t*.19+fi*1.7)*.19;
      float curve = direction + radius*.95 +
          .23*sin(radius*6.0-t*.62+fi*.8);
      float sideways = atan(sin(theta-curve),cos(theta-curve))*radius;
      float phase = fract(t*(.19+fi*.013)+fi*.173);
      float life = smoothstep(.03,.20,radius) *
          (1.0-smoothstep(1.15,1.60,radius));
      vec3 light = fxColor(fract(fi*.29));
      for (int generation = 0; generation < 2; generation++) {
        // generation=1 keeps the last trail alive beyond the head reset.
        float age = phase + float(generation);
        float head = .16 + age * 1.16;
        float fadeIn = smoothstep(.0,.22,age);
        float fadeOut = 1.0 - smoothstep(1.05,1.90,age);
        float envelope = fadeIn * fadeOut;
        float behind = head - radius;
        // The far tail decays progressively as the light travels away.
        float tail = smoothstep(-.025,.045,behind) *
            exp(-max(behind,0.0)*2.3) * life * envelope;
        float core = gauss(sideways,.008) * tail;
        float halo = gauss(sideways,.065) * tail;
        float tip = gauss(radius-head,.034) *
            gauss(sideways,.028) * life * envelope;
        illumination += light * (halo*.64+core*1.05+tip*2.15) *
            (1.0 + bass*.6);
        displacement += radial * (core+tip)*.013*strength;
      }
    }
  } else if (mode > 7.5 && mode < 8.5) {
    // Concentric polar wireframe with a slowly morphing projected grid.
    // Its geometry is distinct from fluid/aurora oscillations.
    float angleCells = theta * 12.0 / 6.283185;
    float ringCells = radius * 15.0;
    float px = angleCells + .24*sin(radius*9.0-t*.67);
    float py = ringCells + .35*cos(theta*5.0+t*.43);
    float radialLine = gauss(fract(px)-.5,.054);
    float hoopLine = gauss(fract(py)-.5,.054);
    float mesh = max(radialLine,hoopLine) *
        smoothstep(.06,.20,radius) *
        (1.0-smoothstep(1.0,1.7,radius));
    illumination += fxColor(.56) * mesh * .34;
    displacement += radial * sin(py*6.283185) * .009 * strength;
    displacement += vec2(-radial.y,radial.x) *
        cos(px*6.283185) * .009 * strength;
  } else if (mode > 8.5 && mode < 9.5) {
    // Particle currents swirl out from the selected album with unique
    // trajectories rather than a screen-wide generic sinusoidal warp.
    for (int i = 0; i < 15; i++) {
      float fi = float(i);
      float seed = hash21(vec2(fi, 8.1));
      float age = fract(t * (.018 + seed*.014) + fi*.193);
      float angle = fi*2.399963 + .65*age + .13*sin(t*.2+fi);
      float travel = .03+age*1.34;
      vec2 center = origin + vec2(cos(angle),sin(angle))*travel/aspect;
      vec2 dv = (uv-center)*aspect;
      float fade = smoothstep(0.0,.16,age) *
          (1.0-smoothstep(.86,1.0,age));
      float lens = gauss(length(dv),.016+seed*.022)*fade;
      illumination += fxColor(fract(fi*.38)) * lens * .58;
      displacement += dv/aspect * lens * .16 * strength;
    }
  } else if (mode > 9.5 && mode < 10.5) {
    // Water Shimmer: surface-normal refraction with a moving caustic.
    float h1 = sin(p.x * 32.0 + t * .82 + sin(p.y * 14.0));
    float h2 = cos(p.y * 25.0 - t * 1.01 + sin(p.x * 12.0));
    displacement += vec2(h1, h2) * .013 * strength;
    illumination += fxColor(.31) * pow(max(0.0, h1*h2), 5.0) * .17;
  } else if (mode > 10.5 && mode < 11.5) {
    // Beat Ripples: FFT-triggered concentric image-space displacement.
    float age = u_pulseAge;
    if (age >= 0.0 && age < 1.4) {
      float head = .12 + age * .47;
      float ring = gauss(radius - head, .020 + .011 * age);
      displacement += radial * ring * .047 * strength * (1.0 - age / 1.4);
      illumination += fxColor(.45) * ring * .18;
    }
  } else if (mode > 11.5 && mode < 12.5) {
    // Photographic defocus: filled soft aperture discs, layered diffusion
    // and a broad light bleed. No outlined ellipses or popping rings.
    // Each light drifts smoothly outward from the hidden album source.
    for (int i = 0; i < 16; i++) {
      float fi = float(i);
      float seed = hash21(vec2(fi, 5.7));
      float seed2 = hash21(vec2(fi, 22.1));
      float age = fract(t * (.009 + seed*.007) + seed2);
      float direction = fi*2.399963 + sin(fi*1.3+t*.095)*.20;
      float travel = mix(.025, 1.28, age);
      vec2 spot = origin +
          vec2(cos(direction),sin(direction))*travel/aspect;
      float dist = length((uv-spot)*aspect);
      float aperture = mix(.025,.115,seed) * max(.55,u_effectSize);
      float life = smoothstep(0.0,.17,age) *
          (1.0-smoothstep(.82,1.0,age));
      float disc = 1.0-smoothstep(aperture*.38,aperture*1.13,dist);
      float soft = gauss(dist,aperture*.98);
      float spill = gauss(dist,aperture*2.5);
      float twinkle = .88+.12*sin(t*.7+fi);
      vec3 light = mix(fxColor(fract(fi*.33)),vec3(1.0),.26);
      illumination += light * life * twinkle *
          (disc*.20 + soft*.32 + spill*.13);
      displacement += (uv-spot)*soft*.014*strength*life;
    }
  } else if (mode > 12.5 && mode < 13.5) {
    // Aurora Sweep: translucent moving fold bends underlying imagery.
    float field = sin(p.y * 6.1 + p.x * 3.9 + t * .5 +
        sin(p.x * 6.4 - t * .28));
    float light = pow(max(0.0, field), 3.0);
    displacement += vec2(field, sin(field * 3.1 + t*.31)) * .012 * strength;
    illumination += mix(u_colorB,u_colorA,uv.y) * light * .22;
  } else if (mode > 13.5 && mode < 14.5) {
    // Album-emitted Light Rays: wide luminous scattering with a bright
    // filament and soft, long-distance feathered volumetric spill.
    // Size controls *both* beam spread and beam reach (0.5..2.5).
    float raySize = clamp(u_effectSize, 0.5, 2.5);
    float rayAngle = atan(d.y, d.x);
    // Rotate continuously around the artwork, rather than oscillating
    // by barely one degree as the last version did.
    float rotation = t * 3.8 + sin(t * .19) * .12;
    float beamPhase = rayAngle * 10.0 - rotation;
    float blade = max(0.0, cos(beamPhase));
    float core = pow(blade, 25.0 / raySize);
    float halo = pow(blade, 5.5 / sqrt(raySize));
    float scatter = pow(blade, 1.65);
    float beamLength = .36 + raySize * .48;
    float reach = 1.0 - smoothstep(beamLength * .27, beamLength, radius);
    float softStart = smoothstep(.015, .13, radius);
    // Colored luminous cores remain visible over bright fanart.
    // Low-level bass adds only a subtle extra kick; light remains steady.
    float energy = reach * softStart *
        (core * 1.40 + halo * 1.04 + scatter * .48);
    illumination += fxColor(.32 + .15 * sin(t * .14)) *
        energy * (1.0 + .12 * bass);
    displacement += radial * core * reach * .010 * strength;
  } else if (mode > 14.5 && mode < 15.5) {
    // Nebula Haze: soft volumetric turbulence alters light and pixels.
    float n = sin(p.x * 5.3 + t * .13 + sin(p.y*3.7)) *
              cos(p.y * 7.7 - t * .16 + sin(p.x*2.8));
    displacement += vec2(n, sin(n*3.7+t*.21)) * .007 * strength;
    illumination += fxColor(.5+.3*n) * pow(max(0.0,n*.5+.5), 3.0) * .13;
  } else if (mode > 15.5 && mode < 16.5) {
    // Perspective vanishing point is behind the active album, not fixed
    // at the middle of the display on every theme.
    float depth = 1.0 / max(.11, abs(uv.y-origin.y) + .11);
    float gx = sin((uv.x-origin.x) * depth * 26.0 + sin(t*.10));
    float gy = sin(depth * 11.0 - t * 1.25);
    float grid = max(pow(max(0.0,gx),36.0), pow(max(0.0,gy),36.0));
    float ground = smoothstep(origin.y,origin.y+.5,uv.y);
    illumination += fxColor(.62) * grid * ground * .28;
    displacement.y += gy * ground * .003 * strength;
  } else if (mode > 16.5 && mode < 17.5) {
    // Twinkling Stars: star lens glints with restrained chromatic sparkle.
    vec2 cell = floor(uv * vec2(33.0,23.0));
    vec2 local = fract(uv * vec2(33.0,23.0));
    float seed = hash21(cell);
    vec2 point = vec2(hash21(cell+1.7),hash21(cell+6.8));
    float dist = length((local-point)*vec2(.8,1.0));
    float glitter = pow(max(0.0,sin(t*(1.5+seed*2.0)+seed*48.0)),14.0);
    float star = gauss(dist,.06) * step(.85,seed) * glitter;
    illumination += vec3(.64,.77,1.0) * star * .62;
    displacement += (local-point) * star * .004 * strength;
  } else if (mode > 17.5 && mode < 18.5) {
    // Particles emerge from the album, spreading into the background.
    for (int i = 0; i < 18; i++) {
      float fi = float(i);
      float seed = hash21(vec2(fi,12.3));
      float age = fract(t*(.013+seed*.013)+fi*.217);
      float direction = fi*2.399963 + .18*sin(t*.27+fi);
      float travel = .035 + age*1.26;
      vec2 center = origin +
          vec2(cos(direction),sin(direction))*travel/aspect;
      vec2 dv = (uv-center)*aspect;
      float fade = smoothstep(0.0,.13,age) *
          (1.0-smoothstep(.86,1.0,age));
      float lens = gauss(length(dv),.009+seed*.016)*fade;
      illumination += fxColor(fract(fi*.24)) * lens * .55;
      displacement += dv/aspect * lens * .18 * strength;
    }
  } else if (mode > 19.5 && mode < 20.5) {
    // VHS: analogue tape tracking physically displaces and chromatically
    // separates the scene, rather than drawing colored overlay stripes.
    float stripe = floor(uv.y * 84.0);
    float tracking = step(.965, hash21(vec2(floor(t*2.9), stripe*.13)));
    float wobble = sin(uv.y*93.0+t*6.7)*.0018 +
        sin(uv.y*271.0-t*11.0)*.0007;
    displacement.x += (wobble + tracking*.028) * strength;
    illumination += vec3(.025,.018,.032) *
        sin(uv.y*u_size.y*2.1) * .75;
  } else if (mode > 18.5 && mode < 19.5) {
    // Cover Bloom: sample source highlights across a small pixel footprint.
    vec2 texel = vec2(2.0) / max(u_size,vec2(1.0));
    vec3 neighborhood = texture(u_texture,clamp(uv+texel,vec2(.002),vec2(.998))).rgb +
        texture(u_texture,clamp(uv-texel,vec2(.002),vec2(.998))).rgb +
        texture(u_texture,clamp(uv+texel*vec2(1,-1),vec2(.002),vec2(.998))).rgb +
        texture(u_texture,clamp(uv+texel*vec2(-1,1),vec2(.002),vec2(.998))).rgb;
    float brightness = dot(neighborhood * .25,vec3(.2126,.7152,.0722));
    illumination += fxColor(.36) * pow(max(0.0,brightness-.35),2.0) * .24;
  }
  vec2 sampleUv = clamp(uv + displacement, vec2(0.002), vec2(0.998));
  // RGB separation follows actual displaced pixels, never painted borders.
  float fringe = mode > 1.5 && mode < 2.5
      ? (0.006 + 0.001 * bass) * strength
      : mode < 3.5 ? (0.0013 + 0.001 * bass) * strength
      : mode > 5.5 && mode < 6.5 ? 0.0016 * strength
      : mode > 19.5 ? .0034 * strength : 0.0;
  vec2 shift = normalize(displacement + vec2(0.0001)) * fringe;
  vec4 base = texture(u_texture, sampleUv);
  float red = texture(u_texture, clamp(sampleUv + shift, vec2(0.002), vec2(0.998))).r;
  float blue = texture(u_texture, clamp(sampleUv - shift, vec2(0.002), vec2(0.998))).b;
  vec3 rgb = vec3(red, base.g, blue);
  if (mode > 1.5 && mode < 2.5) {
    rgb += vec3(glassHighlight * strength * base.a);
  }
  // The GPU effects illuminate and distort the scene's actual sample.
  // Premultiply against backdrop alpha so transparent regions remain intact.
  rgb += illumination * strength * base.a;
  if (mode > 19.5) {
    // Analog grain, soft scanline attenuation and restrained chroma shift.
    float scan = .92 + .08 * sin(uv.y * u_size.y * 2.2);
    float grain = hash21(floor(uv * u_size * .45) + floor(t * 17.0));
    rgb = rgb * mix(1.0, scan, strength) +
        vec3(grain-.5) * .075 * strength * base.a;
  }
  // Highlights respond to gradients in the displacement field, not a static overlay.
  float crest = pow(max(0.0, 1.0 - abs(a - b)), 12.0);
  // Caustics belong to fluid refraction only; other distortion modes should
  // alter the sampled image without imposing an additional color treatment.
  if (mode < 0.5) {
    rgb += vec3(0.055, 0.10, 0.14) * crest * strength * (0.55 + bass * 0.65) * base.a;
  }
  // Transfer/blend mode modifies the refracted sample against original art.
  // Normal preserves pure refraction. Other modes only affect displaced pixels.
  vec3 original = texture(u_texture, uv).rgb;
  vec3 treated = rgb;
  int bm = int(floor(u_blendMode + 0.5));
  if (bm == 1) treated = 1.0 - (1.0 - original) * (1.0 - rgb);
  else if (bm == 2) treated = original * rgb;
  else if (bm == 3) treated = mix(2.0 * original * rgb,
      1.0 - 2.0 * (1.0 - original) * (1.0 - rgb), step(vec3(0.5), original));
  else if (bm == 4) treated = (1.0 - 2.0 * rgb) * original * original + 2.0 * rgb * original;
  else if (bm == 5) treated = min(vec3(1.0), original / max(vec3(0.035), 1.0 - rgb));
  else if (bm == 6) treated = abs(original - rgb);
  else if (bm == 7) treated = mix(rgb, rgb.gbr, 0.55);
  // Blend opacity is the visibility of the *entire* FX pass even in
  // Normal mode. Previously bm==0 disabled this control completely.
  float effectOpacity = clamp(u_blendOpacity, 0.0, 1.0);
  float transferAmount = bm == 0 ? 0.0 : 1.0;
  // Prism's alternate blending stays bounded to its refracted regions.
  if (mode > 1.5 && mode < 2.5) {
    transferAmount *= clamp(length(displacement) * 32.0, 0.0, 1.0);
  }
  vec3 result = mix(rgb, treated, transferAmount);
  rgb = mix(original, result, effectOpacity);
  fragColor = vec4(clamp(rgb, vec3(0.0), vec3(base.a)), base.a);
}
