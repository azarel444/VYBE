#include <flutter/runtime_effect.glsl>
uniform vec2 uSize;
uniform float uTime;
uniform vec3 uGold;
uniform vec3 uAmber;
uniform vec3 uAccent;
uniform vec2 uLightOrigin;
uniform float uBass;
out vec4 fragColor;

float hash21(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
float noise2(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f*f*(3.0-2.0*f);
  return mix(mix(hash21(i),hash21(i+vec2(1,0)),f.x),
             mix(hash21(i+vec2(0,1)),hash21(i+vec2(1,1)),f.x),f.y);
}
float fbm(vec2 p) {
  float v=0.0, a=.5;
  for(int i=0;i<5;i++){v+=a*noise2(p);p=p*2.04+vec2(12.7,8.3);a*=.5;}
  return v;
}
void main() {
  vec2 uv=FlutterFragCoord().xy/uSize;
  float aspect=uSize.x/uSize.y;
  vec2 p=vec2((uv.x-.5)*aspect,uv.y-.5);
  float t=uTime;
  float beat=clamp(uBass,0.,1.);
  vec3 beamColor=mix(uGold,uAmber,.35);
  vec2 sun=vec2((uLightOrigin.x-.5)*aspect,uLightOrigin.y-.5);
  vec2 d=p-sun;
  float dist=length(d);
  float ang=atan(d.y,d.x);
  // Deep cinematic atmosphere with evolving smoke density.
  float fog=fbm(p*2.7+vec2(t*.16,-t*.10));
  float cloud=fbm(p*5.0+vec2(-t*.19,t*.12)+fog*.8);
  vec3 col=mix(vec3(.002,.003,.008),uAmber*.14,smoothstep(.12,.9,p.y));
  col+=uAmber*pow(max(cloud-.48,0.),2.)*.30;
  // Golden Hour is atmospheric sunlight, not neon contour lines.
  // Broad irregular shafts pass through slowly evolving cloud occlusion.
  float radiusFade=exp(-dist*.82);
  float shaftNoise=fbm(vec2(ang*2.4 + .68*sin(t*.24) + .17*sin(t*.51),
                            dist*.85 - t*.018));
  float shaftMask=smoothstep(.39,.72,shaftNoise);
  float softShafts=pow(.5+.5*cos(ang*5.2+.46*sin(t*.27)+.16*sin(t*.53+ang*2.)),3.);
  float secondaryShafts=pow(.5+.5*cos(ang*8.3-.35*sin(t*.19)+t*.045),5.);
  float cloudShadow=1.-.65*smoothstep(.43,.73,
      fbm(p*2.1+vec2(t*.025,-t*.018)));
  // Subtle music swells brighten broad rays without a hard flash.
  col+=beamColor*softShafts*shaftMask*
      cloudShadow*radiusFade*(.77+.12*sin(t*.37)+.48*beat);
  col+=mix(uAmber,uAccent,.38)*secondaryShafts*radiusFade*.24*cloudShadow;
  col+=uGold*shaftMask*radiusFade*.14;
  // Luminous moving clouds cross the beams, revealing their motion.
  float movingMist=fbm(p*3.7+vec2(t*.27,-t*.19));
  float mistBand=smoothstep(.52,.78,movingMist);
  col+=uAmber*mistBand*exp(-dist*.9)*.24;
  // Independent foreground haze moves faster than the distant clouds.
  // Its dark occlusion adds depth without painting the entire scene gold.
  float nearHaze=fbm(p*8.0+vec2(t*.37,-t*.24));
  float nearVeil=smoothstep(.58,.81,nearHaze);
  col*=1.0-nearVeil*.48;
  col+=uAmber*nearVeil*.08;
  // Music-reactive sun: bass expands and brightens the core/halo, then
  // naturally recedes with the spectrum envelope. No strobe or sharp cut.
  float core=exp(-dist*dist*(175.+25.*sin(t*.9))/(1.+.80*beat));
  float halo=exp(-dist*dist*(22.+2.*sin(t*.55))/(1.+.66*beat));
  float haloWide=exp(-dist*dist*(5.5+.4*sin(t*.42))/(1.+.34*beat));
  col+=uAmber*haloWide*(.15+.12*beat)
      +mix(uGold,uAmber,.36)*halo*(.50+.72*beat)
      +mix(uAccent,vec3(1.),.65)*core*(2.05+1.00*beat);
  // Soft anamorphic glint and drifting flare ghosts, tied to the source.
  float flareLine=exp(-abs(d.y)*170.)*exp(-abs(d.x)*2.8);
  col+=mix(uGold,uAccent,.28)*flareLine*(.07+.025*sin(t*.7)+.05*beat);
  vec2 ghostPos=sun+vec2(.18*sin(t*.16),-.11*cos(t*.13));
  float ghost=exp(-length(p-ghostPos)*length(p-ghostPos)*190.);
  col+=mix(uAmber,uGold,.55)*ghost*.10;
  // Golden volumetric bloom is concentrated around the light source.
  // Keep the corners dark instead of applying a full-screen gold wash.
  float warmBloom=exp(-dist*dist*5.6);
  col+=mix(uAmber,uGold,.55)*warmBloom*(.070+.018*sin(t*.3)+.10*beat);
  // Cinematic lens bokeh: broad defocused foreground lights and distinct
  // smaller midground discs, rather than repeated thin neon curves.
  // Foreground defocused amber motes drift independently of the tiny dust.
  // Soft translucent discs overlap the beams, giving them real depth.
  for(int i=0;i<15;i++){
    float fi=float(i);
    float seed=fi*2.39996323;
    vec2 drift=vec2(.035*sin(t*(.12+fi*.007)+seed),
                    -.065*t*(.42+mod(fi,3.)*.23));
    vec2 center=vec2(
      (hash21(vec2(fi,7.1))*1.36-.68)*aspect,
      fract(hash21(vec2(fi,19.3))+drift.y)*1.35-.67
    )+vec2(drift.x,0.);
    float r=mix(.035,.15,hash21(vec2(fi,29.7)));
    float rr=length(p-center)/r;
    float soft=1.-smoothstep(.64,1.12,rr);
    float inner=1.-smoothstep(.0,.8,rr);
    float alpha=(.09+.27*hash21(vec2(fi,37.2)))*soft;
    col+=mix(uAmber,uGold,.68)*alpha*(.58+.42*inner);
    // Bright drifting near-camera glints provide visible foreground motion.
    float sparkle=pow(max(0.,1.-rr),3.)*(.5+.5*sin(t*(.8+fi*.13)+seed));
    col+=mix(uAccent,vec3(1.),.55)*sparkle*.085;
  }
  // A small number of brighter mid-depth golden discs float near the source.
  for(int i=0;i<11;i++){
    float fi=float(i);
    float seed=fi*4.371;
    vec2 center=vec2(
      (hash21(vec2(fi,51.))*1.2-.6)*aspect+.018*sin(t*.22+seed),
      fract(hash21(vec2(fi,61.))-t*(.004+fi*.0007))*1.2-.6);
    float radius=mix(.010,.038,hash21(vec2(fi,71.)));
    float rr=length(p-center)/radius;
    float disc=1.-smoothstep(.55,1.2,rr);
    col+=mix(uGold,uAccent,.30)*disc*.19;
  }
  // Wider and more legible horizontal water glints near the bottom.
  // Their reflection follows the sun when a theme moves the emitter.
  float horizon=.19;
  float below=smoothstep(horizon-.012,horizon+.045,p.y);
  float depth=max(p.y-horizon,0.);
  float ripple=sin(depth*156./(1.+depth*8.)+t*3.3+sin(p.x*10.)*.45);
  float glint=pow(max(0.,sin(depth*100.+t*2.8+
      noise2(vec2(p.x*9.,depth*23.))*4.2)),7.);
  float wideStreak=pow(max(0.,sin(depth*84.-t*2.1+p.x*1.8)),8.);
  float reflection=exp(-abs(p.x-sun.x)*2.9/(depth+.18))*exp(-depth*1.6);
  col+=below*reflection*(mix(uGold,uAmber,.5)*(.19+.18*max(ripple,0.))
      +uAccent*glint*.42+uGold*wideStreak*(.25+.07*beat));
  // Floating dust, several depth layers, with subtle drifting parallax.
  float dust=0.;
  for(int k=0;k<3;k++){
    float layer=float(k);
    vec2 cell=(uv+vec2(t*(.001+.0007*layer),-t*(.002+.0009*layer)))*vec2(32.+layer*18.,16.+layer*9.);
    vec2 id=floor(cell), q=fract(cell)-.5;
    vec2 center=vec2(hash21(id+layer*17.)-.5,hash21(id+layer*31.)-.5)*.72;
    float star=exp(-dot(q-center,q-center)*(200.+layer*130.));
    dust+=star*step(.91,hash21(id+layer*47.))*(.5+.5*sin(t*.9+id.x));
  }
  col+=mix(uAccent,vec3(1.),.48)*dust*.65;
  // Tonemap highlights without flattening the black atmosphere.
  col=1.-exp(-col*1.12);
  col=pow(max(col,vec3(0.)),vec3(1.08));
  fragColor=vec4(col,1.);
}
