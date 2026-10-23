#include <flutter/runtime_effect.glsl>
uniform vec2 uSize;
uniform float uTime;
uniform vec3 uGold;
uniform vec3 uAmber;
uniform vec3 uAccent;
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
  vec2 sun=vec2(.015, .19);
  vec2 d=p-sun;
  float dist=length(d);
  float ang=atan(d.y,d.x);
  // Deep cinematic atmosphere with evolving smoke density.
  float fog=fbm(p*2.7+vec2(t*.16,-t*.10));
  float cloud=fbm(p*5.0+vec2(-t*.19,t*.12)+fog*.8);
  vec3 col=mix(vec3(.002,.003,.008),vec3(.14,.03,.007),smoothstep(.12,.9,p.y));
  col+=vec3(.72,.16,.018)*pow(max(cloud-.48,0.),2.)*.42;
  // Golden Hour is atmospheric sunlight, not neon contour lines.
  // Broad irregular shafts pass through slowly evolving cloud occlusion.
  float radiusFade=exp(-dist*.82);
  float shaftNoise=fbm(vec2(ang*2.4 + .35*sin(t*.045),
                            dist*.85 - t*.018));
  float shaftMask=smoothstep(.39,.72,shaftNoise);
  float softShafts=pow(.5+.5*cos(ang*5.2+.12*sin(t*.09)),3.);
  float cloudShadow=1.-.65*smoothstep(.43,.73,
      fbm(p*2.1+vec2(t*.025,-t*.018)));
  col+=vec3(.98,.54,.12)*softShafts*shaftMask*
      cloudShadow*radiusFade*.55;
  col+=vec3(.67,.25,.025)*shaftMask*radiusFade*.13;
  // Luminous moving clouds cross the beams, revealing their motion.
  float movingMist=fbm(p*3.7+vec2(t*.27,-t*.19));
  float mistBand=smoothstep(.52,.78,movingMist);
  col+=vec3(.62,.12,.012)*mistBand*exp(-dist*.9)*.22;
  // Independent foreground haze moves faster than the distant clouds.
  // Its dark occlusion adds depth without painting the entire scene gold.
  float nearHaze=fbm(p*8.0+vec2(t*.19,-t*.14));
  float nearVeil=smoothstep(.58,.81,nearHaze);
  col*=1.0-nearVeil*.48;
  col+=vec3(.38,.055,.006)*nearVeil*.075;
  // Intense white-hot source and concentric diffused glow.
  float core=exp(-dist*dist*(175.+18.*sin(t*.9)));
  float halo=exp(-dist*dist*(22.+2.*sin(t*.55)));
  float haloWide=exp(-dist*dist*(5.5+.4*sin(t*.42)));
  col+=vec3(.42,.075,.009)*haloWide*.15+vec3(1.,.36,.045)*halo*.48+vec3(1.,.96,.76)*core*2.3;
  // Golden volumetric bloom is concentrated around the light source.
  // Keep the corners dark instead of applying a full-screen gold wash.
  float warmBloom=exp(-dist*dist*5.6);
  col+=mix(uAmber,uGold,.55)*warmBloom*(.055+.018*sin(t*.3));
  // Cinematic lens bokeh: broad defocused foreground lights and distinct
  // smaller midground discs, rather than repeated thin neon curves.
  // Foreground defocused amber motes drift independently of the tiny dust.
  // Soft translucent discs overlap the beams, giving them real depth.
  for(int i=0;i<15;i++){
    float fi=float(i);
    float seed=fi*2.39996323;
    vec2 drift=vec2(.035*sin(t*(.12+fi*.007)+seed),
                    -.018*t*(.42+mod(fi,3.)*.23));
    vec2 center=vec2(
      (hash21(vec2(fi,7.1))*1.36-.68)*aspect,
      fract(hash21(vec2(fi,19.3))+drift.y)*1.35-.67
    )+vec2(drift.x,0.);
    float r=mix(.045,.19,hash21(vec2(fi,29.7)));
    float rr=length(p-center)/r;
    float soft=1.-smoothstep(.64,1.12,rr);
    float inner=1.-smoothstep(.0,.8,rr);
    float alpha=(.055+.17*hash21(vec2(fi,37.2)))*soft;
    col+=mix(uAmber,uGold,.68)*alpha*(.58+.42*inner);
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
    col+=mix(uGold,vec3(1.,.83,.40),.3)*disc*.19;
  }
  // Shimmering reflective horizon with perspective widening toward camera.
  float horizon=.24;
  float below=smoothstep(horizon-.01,horizon+.03,p.y);
  float depth=max(p.y-horizon,0.);
  float ripple=sin(depth*220./(1.+depth*12.)+t*4.2+sin(p.x*17.)*.4);
  float glint=pow(max(0.,sin(depth*145.+t*3.1+noise2(vec2(p.x*12.,depth*30.))*6.)),10.);
  float reflection=exp(-abs(p.x)*3.8/(depth+.09)) * exp(-depth*2.8);
  col+=below*reflection*(uAmber*(.10+.13*ripple)+uGold*glint*.24);
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
  col+=vec3(1.,.76,.39)*dust*.65;
  // Tonemap highlights without flattening the black atmosphere.
  col=1.-exp(-col*1.12);
  col=pow(max(col,vec3(0.)),vec3(1.08));
  fragColor=vec4(col,1.);
}
