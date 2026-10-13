#version 460 core
#include <flutter/runtime_effect.glsl>

// BackdropFilter/ImageFilter.shader automatically supplies size and texture.
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_time;
uniform float u_bass;
uniform float u_strength;
uniform float u_mode; // 0 liquid, 1 vortex, 2 prism, 3 holographic
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
    // Faceted, moving triangular prisms: adjacent regions refract in
    // different directions instead of merely wobbling the whole image.
    vec2 facet = floor((p + vec2(t * 0.045, -t * 0.032)) * 8.0);
    float seed = fract(sin(dot(facet, vec2(127.1, 311.7))) * 43758.5453);
    vec2 local = fract((p + vec2(t * 0.045, -t * 0.032)) * 8.0);
    float triangle = step(local.x + local.y, 1.0);
    float angle = (seed * 6.2831853) + triangle * 2.0944;
    vec2 normal = vec2(cos(angle), sin(angle));
    // Geometry exists only in the displacement field, never as painted shapes.
    // Piecewise-constant offsets form optically fractured regions.
    displacement += normal * (0.021 + 0.023 * bass) * strength;
  } else if (mode > 2.5) {
    displacement += vec2(sin(uv.y * 70.0 + t * 1.1), 0.0) * 0.0025 * strength;
  }
  vec2 sampleUv = clamp(uv + displacement, vec2(0.002), vec2(0.998));
  // Dispersion is strongest around the refractive facet seams, rather than
  // tinting the interiors of entire polygons.
  float seam = 1.0;
  if (mode > 1.5 && mode < 2.5) {
    vec2 cell = fract((p + vec2(t * 0.045, -t * 0.032)) * 8.0);
    float boundary = min(min(cell.x, cell.y), min(1.0 - cell.x, 1.0 - cell.y));
    boundary = min(boundary, abs(1.0 - cell.x - cell.y) * 0.7071);
    seam = 1.0 - smoothstep(0.0, 0.11, boundary);
  }
  float fringe = (mode > 1.5 && mode < 2.5 ? 0.009 * seam : 0.0013)
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
  fragColor = vec4(clamp(rgb, vec3(0.0), vec3(base.a)), base.a);
}
