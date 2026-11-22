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
  // Distortion modes author their own displacement. Atmospheric FX must
  // not inherit liquid ripples unrelated to their selected behavior.
  vec2 displacement = mode < 3.5
      ? vec2(a, b) * (0.006 + bass * 0.009) * strength
      : vec2(0.0);
  float glassHighlight = 0.0;
  vec3 illumination = vec3(0.0);
  vec2 d = uv - vec2(0.5);
  float radius = length(d);
  vec2 radial = d / max(radius, 0.001);
  if (mode > 0.5 && mode < 1.5) {
    vec2 d = uv - vec2(0.5);
    float r = length(d);
    float angle = (0.13 + 0.11 * bass) * strength * exp(-r * 2.4)
      * sin(t * 0.40 + r * 13.0);
    displacement += vec2(-d.y, d.x) * angle;
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
    // Electric Arcs: the stroke carries local specular illumination and
    // warps artwork pixels as if heated/ionized, not just a painted zigzag.
    for (int i = 0; i < 5; i++) {
      float fi = float(i);
      float py = .14 + fi * .18 +
          .052 * sin(uv.x * 25.0 + t * (3.1 + fi * .13) + fi * 6.0) +
          .021 * sin(uv.x * 113.0 - t * 6.5 + fi * 9.0);
      float core = gauss(uv.y - py, .0025);
      float halo = gauss(uv.y - py, .018);
      float flicker = .4 + .6 * pow(abs(sin(t * 4.3 + fi * 8.7)), 1.5);
      float electric = (core + .29 * halo) * flicker;
      illumination += (fxColor(fi / 5.0) * .48 +
          vec3(.57) * core) * electric;
      displacement.y += (uv.y - py) * halo * .19 * strength * flicker;
    }
  } else if (mode > 6.5 && mode < 7.5) {
    // Light Trails: bright moving cores with image-space lens displacement.
    for (int i = 0; i < 6; i++) {
      float fi = float(i);
      float y = .10 + fi * .155 +
          .095 * sin(uv.x * 8.5 + fi * .87 + t * (.65 + fi * .07));
      float head = fract(t * (.08 + fi * .012) + fi * .137);
      float span = fract(head - uv.x + 1.0);
      float tail = exp(-span * 5.6) * (1.0 - smoothstep(.68, 1.0, span));
      float trail = gauss(uv.y - y, .012) * tail;
      illumination += fxColor(fi / 6.0) * trail * (.24 + .26 * bass);
      displacement.y += (uv.y - y) * gauss(uv.y - y, .034) * tail * .14 * strength;
    }
  } else if (mode > 7.5 && mode < 8.5) {
    // Morphing Wireframe: a living refractive mesh, not static outlines.
    vec2 q = p * 8.0;
    q.x += .35 * sin(q.y * .7 + t * .58);
    q.y += .3 * cos(q.x * .7 - t * .52);
    vec2 warp = vec2(sin(q.y * 1.3 + t), cos(q.x * 1.1 - t));
    displacement += warp * .017 * strength;
    float gx = gauss(fract(q.x) - .5, .042);
    float gy = gauss(fract(q.y) - .5, .042);
    illumination += fxColor(.53) * max(gx, gy) * .12;
  } else if (mode > 8.5 && mode < 9.5) {
    // Particle Currents: moving micro-lenses warp source and cast glints.
    vec2 flow = vec2(sin(p.y * 8.0 + t * .55), cos(p.x * 9.0 - t * .41));
    displacement += flow * .008 * strength;
    for (int i = 0; i < 12; i++) {
      float fi = float(i);
      float seed = hash21(vec2(fi, 8.1));
      vec2 center = fract(vec2(seed * 13.7, fi * .618) +
          vec2(t * (.023 + seed * .019), t * (.011 + seed * .014)));
      float dist = length((uv - center) * vec2(1.0, 1.3));
      float lens = gauss(dist, .016 + seed * .012);
      illumination += fxColor(fract(fi * .38)) * lens * .31;
      displacement += (uv - center) * lens * .09 * strength;
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
    // Moving Bokeh: glassy lenslets plus authentic light bleed.
    for (int i = 0; i < 9; i++) {
      float fi = float(i);
      float seed = hash21(vec2(fi, 5.7));
      vec2 center = fract(vec2(seed * 7.3, fi * .174 + seed) +
          vec2(sin(t * .08 + fi)*.075, t * (.012 + seed * .009)));
      vec2 q = (uv - center) * vec2(1.0, 1.15);
      float lens = gauss(length(q), .065 + seed * .045);
      float edge = gauss(length(q) - (.06 + seed*.04), .010);
      illumination += fxColor(fi / 9.0) * (lens * .065 + edge * .12);
      displacement += q * lens * .045 * strength;
    }
  } else if (mode > 12.5 && mode < 13.5) {
    // Aurora Sweep: translucent moving fold bends underlying imagery.
    float field = sin(p.y * 6.1 + p.x * 3.9 + t * .5 +
        sin(p.x * 6.4 - t * .28));
    float light = pow(max(0.0, field), 3.0);
    displacement += vec2(field, sin(field * 3.1 + t*.31)) * .012 * strength;
    illumination += mix(u_colorB,u_colorA,uv.y) * light * .22;
  } else if (mode > 13.5 && mode < 14.5) {
    // Light Rays: screen-space scattering and nearby pixel warping.
    float angle = atan(d.y,d.x);
    float spoke = pow(max(0.0, sin(angle * 9.0 + sin(t*.22)*1.5)), 18.0);
    float reach = (1.0 - smoothstep(.08,.70,radius));
    illumination += fxColor(.32 + .15*sin(t*.14)) * spoke * reach * .33;
    displacement += radial * spoke * reach * .014 * strength;
  } else if (mode > 14.5 && mode < 15.5) {
    // Nebula Haze: soft volumetric turbulence alters light and pixels.
    float n = sin(p.x * 5.3 + t * .13 + sin(p.y*3.7)) *
              cos(p.y * 7.7 - t * .16 + sin(p.x*2.8));
    displacement += vec2(n, sin(n*3.7+t*.21)) * .007 * strength;
    illumination += fxColor(.5+.3*n) * pow(max(0.0,n*.5+.5), 3.0) * .13;
  } else if (mode > 15.5 && mode < 16.5) {
    // Perspective Grid: projected geometry catches highlights.
    float depth = 1.0 / max(.13, uv.y + .10);
    float gx = sin((uv.x-.5) * depth * 26.0 + sin(t*.10));
    float gy = sin(depth * 11.0 - t * 1.25);
    float grid = max(pow(max(0.0,gx),36.0), pow(max(0.0,gy),36.0));
    float ground = smoothstep(.30,.91,uv.y);
    illumination += fxColor(.62) * grid * ground * .18;
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
    // Floating Particles: individually phased luminous refractive droplets.
    for (int i = 0; i < 14; i++) {
      float fi = float(i);
      float seed = hash21(vec2(fi,12.3));
      vec2 center = fract(vec2(fi*.618+seed,t*(.014+seed*.014)+fi*.217));
      vec2 dv = uv-center;
      float lens = gauss(length(dv),.009+seed*.016);
      illumination += fxColor(fract(fi*.24)) * lens * .33;
      displacement += dv * lens * .18 * strength;
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
  float blend = clamp(u_blendOpacity, 0.0, 1.0);
  if (bm == 0) blend = 0.0;
  // For prism, limit treatment to shard regions, not the entire screen.
  if (mode > 1.5 && mode < 2.5) blend *= clamp(length(displacement) * 32.0, 0.0, 1.0);
  rgb = mix(rgb, treated, blend);
  fragColor = vec4(clamp(rgb, vec3(0.0), vec3(base.a)), base.a);
}
