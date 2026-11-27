#version 460 core
#include <flutter/runtime_effect.glsl>

// VYBE Artist Logo FX v2. Samples a SHARP, shadow-free Riot alpha wordmark.
// Each material has its own face, contour response, silhouette extrusion,
// album-palette gradient and bloom. Never modifies optical font spacing.
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_time;           // continuous independent lighting clock
uniform float u_mode;           // 1 chrome, 2 neon, 3 extruded 3D, 4 emboss, 5 electric, 6 holo
uniform float u_depth;
uniform float u_edge;
uniform float u_beat;
uniform vec3 u_colorA;          // extracted from current album art
uniform vec3 u_colorB;
uniform vec3 u_colorC;
uniform float u_colorStrength;  // 0 monochrome, 1 art colors
out vec4 fragColor;

float sat(float x) { return clamp(x, 0.0, 1.0); }
vec3 sat3(vec3 x) { return clamp(x, vec3(0.0), vec3(1.0)); }
float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1,311.7))) * 43758.5453); }
float maskAt(vec2 uv) {
  // The 16px text padding prevents this from sampling adjacent content.
  return texture(u_texture, clamp(uv, vec2(0.001), vec2(0.999))).a;
}
float compass(vec2 uv, vec2 delta) {
  float a = maskAt(uv + vec2(delta.x, 0.0));
  float b = maskAt(uv - vec2(delta.x, 0.0));
  float c = maskAt(uv + vec2(0.0, delta.y));
  float d = maskAt(uv - vec2(0.0, delta.y));
  float e = maskAt(uv + delta*.7071);
  float f = maskAt(uv - delta*.7071);
  float g = maskAt(uv + vec2(delta.x,-delta.y)*.7071);
  float h = maskAt(uv + vec2(-delta.x,delta.y)*.7071);
  return max(max(max(a,b),max(c,d)),max(max(e,f),max(g,h)));
}
vec3 artColor(float x, vec3 a, vec3 b, vec3 c) {
  float t = sat(x);
  return t < .5 ? mix(a,b,smoothstep(0.0,.5,t))
                : mix(b,c,smoothstep(.5,1.0,t));
}
void main() {
  vec2 size = max(u_size, vec2(1.0));
  vec2 p = FlutterFragCoord().xy;
  vec2 uv = p / size;
  vec2 px = 1.0 / size;
  float alpha = sat(maskAt(uv));
  float d = sat(u_depth);
  float edge = sat(u_edge);
  float beat = sat(u_beat);
  float phase = u_time;
  float mode = floor(u_mode + .5);
  float chroma = sat(u_colorStrength);

  // Real glyph contour, sampled inside the opaque strokes.
  vec2 e = px * (1.7 + d*1.9);
  float ml = maskAt(uv - vec2(e.x,0.0));
  float mr = maskAt(uv + vec2(e.x,0.0));
  float mt = maskAt(uv - vec2(0.0,e.y));
  float mb = maskAt(uv + vec2(0.0,e.y));
  float low = min(min(ml,mr),min(mt,mb));
  vec2 normal = vec2(ml-mr, mt-mb);
  float bevel = sat((alpha-low)*1.35);
  float highlight = sat(.48 + dot(normal,vec2(-.52,-.85))*.92);
  float shadowSide = 1.0 - highlight;

  // Three distances in screen pixels: clear silhouette, colored outline,
  // and glow. Input has NO old Flutter text shadows to wash these out.
  float near = compass(uv, px*(2.1+edge*1.8));
  float mid = compass(uv, px*(4.5+edge*1.9));
  float far = compass(uv, px*(8.0+edge*3.0));
  float outline = sat(near-alpha);
  float halo1 = sat(mid-max(alpha,near));
  float halo2 = sat(far-max(alpha,mid));

  // All COLOR materials sample all three album-derived colors. Do not
  // replace artist colors with a generic cyan/purple RGB preset.
  vec3 a = mix(vec3(.86), sat3(u_colorA), chroma);
  vec3 b = mix(vec3(.86), sat3(u_colorB), chroma);
  vec3 c = mix(vec3(.86), sat3(u_colorC), chroma);
  float x = uv.x;
  float y = uv.y;
  vec3 gradient = artColor(sat(x*.96 + .04),a,b,c);
  vec3 movingColor = artColor(sat(x*.86 + .11 + .11*sin(phase*.65 + y*5.0)),a,b,c);
  vec3 rimColor = artColor(sat(x*.93 + .04),c,b,a);

  float sweepX = .48 + .40*sin(phase*.48);
  float sweep = pow(sat(1.0 - abs(x-sweepX)*5.7),5.0);
  float thinSweep = pow(sat(1.0 - abs(x-sweepX)*12.0),7.0);
  float wave = sin(y*29.0 + sin(x*8.0)*.7 + phase*.15);
  float stripe = smoothstep(-.85,.80,wave);
  float chromeBand = .14 + .73*stripe + .26*pow(sat(sin(y*47.0-phase*.35)),14.0);

  vec3 face = vec3(1.0);
  vec3 glowTint = gradient;
  float ring = 0.0;
  float haze = 0.0;
  float farHaze = 0.0;
  float extrusion = 0.0;
  vec3 extrudeColor = vec3(.025,.028,.055);

  if (mode < 1.5) {
    // POLISHED CHROME: genuinely dark mirror bands, narrow white hot strips,
    // album-colored reflective facets and crisp steel beveled edges.
    vec3 silver = mix(vec3(.095,.12,.18),vec3(.95,.95,.98),sat(chromeBand));
    face = silver*(.60 + .72*highlight*d);
    face = mix(face, movingColor, sat(.30 + .28*sin(y*13.0+phase*.23)) * chroma);
    face += vec3(.42)*thinSweep;
    face += mix(vec3(.8,.9,1.0),rimColor,.50)*bevel*highlight*(.35+.8*edge);
    face -= vec3(.38)*bevel*shadowSide*d;
    glowTint = gradient;
    ring = (.18+.24*edge)*outline;
    haze = .10*edge*halo1;
    extrusion = .48*d;
    extrudeColor = vec3(.04,.045,.075);
  } else if (mode < 2.5) {
    // NEON TUBE: deliberately DARK glass interior and a visibly
    // saturated 3-4px perimeter, with two layers of colored light.
    face = mix(gradient*.22,gradient*.65,bevel);
    face += rimColor*bevel*(.20 + 1.0*edge);
    face += vec3(.42)*thinSweep*.25;
    glowTint = gradient;
    ring = (.56+.40*edge)*outline;
    haze = (.20+.38*edge)*halo1;
    farHaze = (.07+.23*edge)*halo2;
    extrusion = .09*d;
    extrudeColor = rimColor*.14;
  } else if (mode < 3.5) {
    // Solid extruded 3D lettering: sculpted face, sharply separated side walls.
    vec3 base = artColor(sat(x*.30+y*.70),a,b,c);
    face = mix(base*.48,base*.88+vec3(.12),1.0-y);
    face += vec3(.52)*bevel*highlight;
    face -= vec3(.38)*bevel*shadowSide;
    glowTint = mix(rimColor,vec3(.08),.45);
    ring = (.32+.30*edge)*outline;
    haze = .025*halo1;
    extrusion = 1.0;
    extrudeColor = mix(vec3(.035,.045,.08),base*.32,.62);
  } else if (mode < 4.5) {
    // DEEP EMBOSS: bold SOLID album-colored face, hard highlight
    // from upper left, dark opposing bevel and thick visible backing.
    face = mix(gradient*.55, gradient*1.16, .60+.32*highlight);
    face += vec3(.40)*bevel*highlight*d;
    face -= vec3(.48)*bevel*shadowSide*d;
    face += vec3(.22)*thinSweep*.35;
    glowTint = rimColor;
    ring = (.22+.19*edge)*outline;
    haze = .07*edge*halo1;
    extrusion = .96*d;
    extrudeColor = mix(vec3(.026,.035,.075),gradient*.25,.50);
  } else if (mode < 5.5) {
    // ELECTRIC ENERGY: a dark solid face with fast branching lightning
    // restricted to the actual glyph contour. No interior holographic stripes.
    float cell = floor(phase*10.0);
    vec2 jitter = vec2(hash21(vec2(cell, floor(p.y*.30))),
                       hash21(vec2(cell+19.0, floor(p.x*.24))))-.5;
    vec2 q = p + jitter*5.5;
    float path = q.x*.19 + q.y*.26 + .65*sin(q.y*.49+cell*1.7)
               + .33*sin(q.x*.71-cell*2.1) - phase*7.0;
    float spark = pow(sat(.5+.5*sin(path)),15.0);
    float branch = pow(sat(.5+.5*sin(q.x*.31-q.y*.39+sin(q.y*.81)*1.5+phase*8.0)),23.0);
    float burst = sat(spark+branch*.70);
    float live = sat(.32+burst*.75+beat*.22);
    float innerRim = sat(bevel*1.75);
    face = mix(gradient*.20,gradient*.42,.42+highlight*.26);
    face += rimColor*innerRim*(.65+live*.65);
    face += vec3(1.0)*innerRim*burst*(.75+.35*edge);
    glowTint = mix(movingColor,vec3(.90,.98,1.0),burst*.68);
    ring = outline*(.32+.65*live);
    haze = halo1*(.12+.43*burst+.18*beat);
    farHaze = halo2*(.04+.25*burst);
    extrusion = .08*d;
    extrudeColor = gradient*.14;
  } else {
    // HOLOGRAPHIC: vivid tricolor iridescent face, moving rainbow
    // interference within the ACTUAL album palette, not silver chrome.
    float film = .5+.5*sin(x*19.0 - y*14.0 + phase*1.15);
    float phase2 = .5+.5*sin(y*29.0+x*8.0-phase*.64);
    vec3 iridescent = artColor(film,a,b,c);
    face = mix(iridescent, artColor(phase2,c,b,a), .31);
    face *= .82+.28*highlight;
    face += vec3(.48)*thinSweep*.44;
    face += rimColor*bevel*(.26+.26*edge);
    glowTint = iridescent;
    ring = (.24+.25*edge)*outline;
    haze = (.13+.20*edge)*halo1;
    farHaze = .09*edge*halo2;
    extrusion = .26*d;
    extrudeColor = gradient*.15;
  }

  // Extruded sides are rendered behind the original glyph, not on its face.
  float back = max(max(maskAt(uv - px*vec2(2.5+7.0*d,3.0+6.5*d)),
                       maskAt(uv - px*vec2(1.1+4.0*d,1.5+3.5*d))),
                       maskAt(uv - px*vec2(.8+2.0*d,.9+2.2*d)));
  if (mode > 2.5 && mode < 3.5) {
    float lengthPx = 3.0+9.0*d;
    back = 0.0;
    for (int i=1; i<=12; i++) {
      float stepPx = float(i)*lengthPx/12.0;
      back = max(back,maskAt(uv-px*vec2(stepPx*.80,stepPx)));
    }
  }
  float solidBack = sat(back-alpha)*extrusion;

  // Output MUST be premultiplied. Never reuse the input RGBA's old white
  // shading or multiply alpha by bright color (causes pale fringes).
  float outside = (1.0-alpha);
  float litRing = sat(ring + haze + farHaze)*outside;
  float shadowAlpha = solidBack*outside*(1.0-litRing);
  float finalAlpha = sat(alpha + litRing + shadowAlpha);
  vec3 rgb = sat3(face)*alpha +
             sat3(glowTint)*litRing +
             sat3(extrudeColor)*shadowAlpha;
  fragColor = vec4(min(rgb,vec3(finalAlpha)),finalAlpha);
}
