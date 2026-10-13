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
out vec4 fragColor;

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
  vec2 p = uv * vec2(u_size.x / max(u_size.y, 1.0), 1.0);
  float a = wave(p, t);
  float b = wave(p.yx * 1.21 + vec2(1.7, 0.8), t * 0.83);
  vec2 displacement = vec2(a, b) * (0.006 + bass * 0.009) * strength;
  float mode = floor(u_mode + 0.5);
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
      center += vec2(sin(t * (0.035 + depth * 0.055) + fi), cos(t * (0.027 + depth * 0.04) + fi * 1.7)) * 0.055;
      vec2 local = uv - center;
      float angle = seed2 * 6.283185 + sin(t * 0.08 + fi) * 0.18;
      local = mat2(cos(angle), -sin(angle), sin(angle), cos(angle)) * local;
      float width = mix(0.055, 0.17, seed) * (0.6 + depth * 0.6);
      float height = mix(0.055, 0.22, seed2) * (0.6 + depth * 0.6);
      // Three half-planes describe a free-floating triangle; softened edges.
      float edge = min(min(local.y + height * 0.48, local.x * 0.85 - local.y * 0.48 + width * 0.55),
          -local.x * 0.85 - local.y * 0.48 + width * 0.55);
      float mask = smoothstep(-0.008, 0.009, edge) * (0.4 + depth * 0.6);
      if (mask > 0.01 && depth > bestDepth) {
        bestDepth = depth;
        shardShift = vec2(cos(angle + fi * 0.91), sin(angle + fi * 0.91)) *
          (0.012 + depth * 0.032 + bass * 0.012) * mask;
      }
    }
    displacement += shardShift * strength;
  } else if (mode > 2.5) {
    displacement += vec2(sin(uv.y * 70.0 + t * 1.1), 0.0) * 0.0025 * strength;
  }
  vec2 sampleUv = clamp(uv + displacement, vec2(0.002), vec2(0.998));
  // RGB separation follows actual displaced pixels, never painted borders.
  float fringe = (mode > 1.5 && mode < 2.5 ? 0.006 : 0.0013)
      * strength + 0.001 * bass * strength;
  vec2 shift = normalize(displacement + vec2(0.0001)) * fringe;
  vec4 base = texture(u_texture, sampleUv);
  float red = texture(u_texture, clamp(sampleUv + shift, vec2(0.002), vec2(0.998))).r;
  float blue = texture(u_texture, clamp(sampleUv - shift, vec2(0.002), vec2(0.998))).b;
  vec3 rgb = vec3(red, base.g, blue);
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
