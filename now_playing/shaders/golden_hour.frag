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
  vec3 col=mix(vec3(.007,.009,.019),uAmber*.17, smoothstep(-.48,.43,p.y));
  col+=mix(uGold,uAccent,.25)*pow(max(cloud-.32,0.),2.)*.45;
  // Animated light rig: rotating shafts with traveling shadow patterns.
  // Beam direction and intensity are functions of time, not static rays.
  float radiusFade=exp(-dist*.72);
  float sweepAngle=ang-t*.28;
  float beams=pow(.5+.5*cos(sweepAngle*18.0
      +sin(ang*5.0-t*.52)*.65), 18.0);
  float wideBeams=pow(.5+.5*cos(ang*9.0+t*.19), 9.0);
  float turbulence=fbm(vec2(ang*7.0+t*.32,dist*2.5-t*.44));
  float shadow=.35+.65*smoothstep(.28,.78,turbulence);
  float breathing=.75+.25*sin(t*1.6);
  col+=uGold*beams*radiusFade*shadow*1.45*breathing;
  col+=uAmber*wideBeams*radiusFade*(.45+.5*turbulence)*.82;
  // Luminous moving clouds cross the beams, revealing their motion.
  float movingMist=fbm(p*3.7+vec2(t*.27,-t*.19));
  float mistBand=smoothstep(.38,.72,movingMist);
  col+=mix(uGold,uAmber,.55)*mistBand*exp(-dist*.9)*.38;
  // Intense white-hot source and concentric diffused glow.
  float core=exp(-dist*dist*(82.+18.*sin(t*.9)));
  float halo=exp(-dist*dist*(5.2+1.1*sin(t*.55)));
  float haloWide=exp(-dist*dist*(.85+.20*sin(t*.42)));
  col+=uGold*haloWide*.18+uAmber*halo*.54+vec3(1.,.92,.70)*core*2.1;
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
  col=1.-exp(-col*1.32);
  col=pow(max(col,vec3(0.)),vec3(.87));
  fragColor=vec4(col,1.);
}
