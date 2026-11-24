#version 460 core
#include <flutter/runtime_effect.glsl>

// ImageFilter.shader supplies the composited Riot text as input. Every effect
// follows the actual alpha silhouette of the final, optically spaced wordmark.
// The shader never modifies glyphs or references the artwork/fanart textures.
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_time;    // integrated lighting phase (0 = frozen)
uniform float u_mode;    // 1 chrome, 2 neon, 3 distressed, 4 emboss, 5 energy, 6 holo
uniform float u_depth;   // relief depth
uniform float u_edge;    // rim/halo strength
uniform float u_beat;    // actual FFT onset only, not simulated bars
uniform vec3 u_colorA;   // artwork-driven accent
uniform vec3 u_colorB;   // artwork-driven secondary accent
out vec4 fragColor;

float saturate(float v) { return clamp(v, 0.0, 1.0); }
float noise21(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}
float alphaAt(vec2 uv) {
  return texture(u_texture, clamp(uv, vec2(0.001), vec2(0.999))).a;
}
void main() {
  vec2 size = max(u_size, vec2(1.0));
  vec2 uv = FlutterFragCoord().xy / size;
  vec2 px = 1.0 / size;
  vec4 ink = texture(u_texture, uv);
  float alpha = saturate(ink.a);
  float depth = saturate(u_depth);
  float edging = saturate(u_edge);
  float beat = saturate(u_beat);
  float t = u_time;
  float mode = floor(u_mode + 0.5);

  // Sample the letter silhouette, not the whole rectangular text box.
  // This makes highlights and edge light respect each brush stroke.
  vec2 stepUv = px * (1.1 + depth * 1.7);
  float left  = alphaAt(uv - vec2(stepUv.x, 0.0));
  float right = alphaAt(uv + vec2(stepUv.x, 0.0));
  float up    = alphaAt(uv - vec2(0.0, stepUv.y));
  float down  = alphaAt(uv + vec2(0.0, stepUv.y));
  vec2 grad = vec2(left - right, up - down);
  float bevel = saturate(length(grad) * 2.0);
  float lit = saturate(0.48 + dot(grad, vec2(-0.53, -0.85)) * (0.75 + depth*.50));
  float rim = saturate(bevel * (0.4 + 0.6*edging));

  // Soft halo in transparent margin surrounding each glyph.
  vec2 gp = px * (2.5 + edging * 3.0);
  float haloNear = max(max(alphaAt(uv+vec2(gp.x,0.0)), alphaAt(uv-vec2(gp.x,0.0))),
                       max(alphaAt(uv+vec2(0.0,gp.y)), alphaAt(uv-vec2(0.0,gp.y))));
  float haloDiagonal = max(
    max(alphaAt(uv+gp),alphaAt(uv-gp)),
    max(alphaAt(uv+vec2(gp.x,-gp.y)),alphaAt(uv+vec2(-gp.x,gp.y))));
  float halo = saturate(max(haloNear,haloDiagonal) - alpha) * edging;

  vec3 a = clamp(u_colorA, vec3(0.0), vec3(1.0));
  vec3 b = clamp(u_colorB, vec3(0.0), vec3(1.0));
  // Raise very dark album colors enough to keep the logo legible.
  vec3 accent = mix(a, vec3(.58,.80,.95), .20);
  vec3 secondary = mix(b, vec3(.80,.48,.98), .18);

  // A slow broad reflection crossing the whole letter group.
  float sweep = pow(saturate(1.0 -
      abs(uv.x - (0.5 + 0.59*sin(t * .38))) * 3.5), 2.5);
  float band = sin(uv.y * 18.0 + .75*sin(uv.x*5.0) + t*.15);
  float mirror = smoothstep(-.72,.85, band);
  float fineSpec = pow(max(0.0,sin(uv.y*37.0 - t*.32)), 18.0);
  vec3 metal = mix(vec3(.13,.17,.22), vec3(.86,.93,1.0), mirror);
  metal = mix(metal, vec3(1.0), .30 * fineSpec);
  metal += vec3(.23,.29,.32) * sweep;

  vec3 face = vec3(.98);
  float effectHalo = halo * .16;

  if (mode < 1.5) {
    // SCULPTED CHROME: reflective metal with actual contour-based bevels,
    // dark opposite edge, album-color rim and restrained moving highlight.
    face = metal * (0.72 + 0.53*lit*depth);
    face = mix(face, accent, .17 + .20*rim);
    face += vec3(.40,.40,.44) * rim * lit * edging;
    face *= 1.0 + beat*.13;
    effectHalo = halo * (.20 + .12*beat);
  } else if (mode < 2.5) {
    // NEON EDGE: bright solid face, colored rim and colored halo beyond ink.
    face = mix(vec3(.84,.91,.97), accent, .12);
    face += mix(accent,secondary,.48) * rim * (0.75 + .55*edging);
    face += vec3(.24) * sweep * .28;
    face *= 1.0 + beat*.16;
    effectHalo = halo * (.33 + beat*.15);
  } else if (mode < 3.5) {
    // DISTRESSED METAL: directional scratches and worn ink contained inside
    // each letter; full-sized random pixels are not a background overlay.
    float grain = noise21(floor(uv * size * .71));
    float scratch = sin(uv.y*size.y*.83 + 3.0*sin(uv.x*size.x*.21));
    float worn = smoothstep(.72,.96,grain*.58 + .42*abs(scratch));
    face = metal * (1.02 - .42*worn);
    face *= .77 + .29*lit*depth;
    face = mix(face, accent*.48, worn*.24);
    face += vec3(.22) * rim*lit;
    effectHalo = halo * .10;
  } else if (mode < 4.5) {
    // EMBOSSED: stronger light/dark contours and low-key deep shadow.
    face = mix(vec3(.17,.22,.31),vec3(.98,.98,1.0),lit);
    face = mix(face, metal, .38);
    face += accent*.21*rim;
    face *= 0.85 + 0.29*depth;
    face *= 1.0 + beat*.10;
    effectHalo = halo*.16;
  } else if (mode < 5.5) {
    // ELECTRIC: plasma current runs inside the glyph mask, strongest at
    // contour edges. Driven by real bass transients, never fake kick pulses.
    float current = pow(max(0.0,sin(uv.x*48.0 + uv.y*21.0 - t*1.7)),14.0);
    float current2 = pow(max(0.0,sin(uv.x*22.0 - uv.y*32.0 + t*1.2)),20.0);
    float charge = saturate(current*.62 + current2*.47 + beat*.24);
    face = mix(vec3(.85,.93,1.0),accent,.28);
    face += secondary * charge * (.45 + .42*edging);
    face += accent * rim * (.67 + .72*beat);
    effectHalo = halo * (.37 + charge*.18 + beat*.14);
  } else {
    // HOLOGRAPHIC: moving interference bands and diffracted accent colors.
    float prism = .5 + .5*sin(uv.x*15.5 - uv.y*9.5 - t*.78);
    vec3 iridescence = mix(accent,secondary,prism);
    vec3 spectral = vec3(.5+.5*sin(6.28*prism+0.0),
                         .5+.5*sin(6.28*prism+2.094),
                         .5+.5*sin(6.28*prism+4.188));
    face = mix(vec3(.80,.88,1.0),iridescence,.48);
    face = mix(face,spectral,.33);
    face += vec3(.38) * rim * lit;
    face += vec3(.27) * sweep;
    effectHalo = halo * .25;
  }

  // Shallow shadow/extrusion is also sculpted from the wordmark mask.
  // The padding supplied by the widget leaves room for the contour spill.
  float back = alphaAt(uv - px*vec2(1.6+depth*4.0,2.8+depth*4.5));
  float extruded = max(0.0,back-alpha) * depth * .43;
  vec3 shadow = mix(vec3(.018,.024,.045),accent*.19, .40);

  // Input is premultiplied RGBA. Keep premultiplication on output: this
  // prevents colored fringes when text sits over album art or fanart.
  float glowOpacity = effectHalo * (1.0-alpha) * (1.0-extruded);
  float finalAlpha = saturate(alpha + extruded*(1.0-alpha) + glowOpacity);
  vec3 fill = clamp(face,vec3(0.0),vec3(1.0));
  vec3 rgb = fill*alpha;
  rgb += shadow*extruded*(1.0-alpha);
  rgb += mix(accent,secondary,.40)*glowOpacity;
  rgb = min(rgb,vec3(finalAlpha));
  fragColor = vec4(rgb,finalAlpha);
}
