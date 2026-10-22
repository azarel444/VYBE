#include <flutter/runtime_effect.glsl>
uniform vec2 uSize;
uniform float uTime;
uniform vec3 uColorA;
uniform vec3 uColorB;
uniform vec3 uColorC;
out vec4 fragColor;

float hash21(vec2 p) {
  p=fract(p*vec2(123.34,456.21));
  p+=dot(p,p+45.32);
  return fract(p.x*p.y);
}
vec2 flow(vec2 p,float t) {
  vec2 q=p;
  for(int i=0;i<3;i++){
    float fi=float(i);
    float freq=2.6+fi*2.3;
    vec2 d=vec2(
      sin(q.y*freq+t*(.37+fi*.13)+fi*1.7)
        +.55*cos(q.x*freq*.8-q.y*1.8-t*.29),
      cos(q.x*freq*.9-t*(.32+fi*.11)+fi*2.1)
        +.5*sin(q.y*freq*.8+q.x*2.1+t*.24));
    q+=d*(.14/(1.+fi*.7));
  }
  return q;
}
vec3 filament(vec2 p,float t,float index,vec3 tint) {
  float phase=index*1.618;
  float depth=mod(index,3.);
  vec2 q=flow(p+vec2(.16*sin(phase),.13*cos(phase)),t+phase*.21);
  float field=sin(q.x*(4.7+depth*.45)+phase)
      +.85*cos(q.y*(5.2+depth*.65)-phase*.81)
      +.42*sin((q.x+q.y)*7.3+t*.19+phase*.7);
  float target=(index-5.5)*.17;
  float d=abs(field-target);
  float thickness=.024+.015*sin(q.x*2.6+q.y*3.2+t*.41+phase);
  float fine=exp(-pow(d/max(thickness,.008),1.25));
  float glow=exp(-pow(d/.15,2.));
  float aura=exp(-pow(d/.42,2.));
  float intensity=.73+.27*sin(q.x*4.1-q.y*3.5+t*.52+phase);
  return tint*(fine*1.75+glow*.48+aura*.085)*intensity
      *(.55+.22*depth);
}
void main() {
  vec2 uv=FlutterFragCoord().xy/uSize;
  float aspect=uSize.x/uSize.y;
  vec2 p=vec2((uv.x-.5)*aspect,(uv.y-.5));
  float t=uTime;
  vec3 a=normalize(uColorA+.001),b=normalize(uColorB+.001),c=normalize(uColorC+.001);
  vec3 col=mix(vec3(.0015,.002,.011),vec3(.008,.003,.026),smoothstep(-.45,.5,p.y));
  // Shared flow coordinates deform the background illumination as well
  // as the filaments: it is a liquid field, not independent moving lines.
  vec2 q=flow(p,t*.78);
  float depthLight=.5+.5*sin(q.x*3.1+t*.18)*cos(q.y*4.3-t*.16);
  col+=(a*.055+b*.048+c*.052)*depthLight*exp(-dot(q,q)*.35);
  for(int i=0;i<12;i++){
    float fi=float(i);
    vec3 tint=mod(fi,3.)<.5?a:(mod(fi,3.)<1.5?b:c);
    float layer=fi<4.? .34 : (fi<8.? .66 : 1.);
    col+=filament(p,t*(.64+layer*.36),fi,tint)*layer;
  }
  // Moving caustics and diffused light pools warp with the same fluid.
  float caustic=pow(.5+.5*sin(q.x*8.5+t*.4)*cos(q.y*7.4-t*.32),5.);
  col+=(a*.08+b*.06+c*.07)*caustic;
  vec2 grid=(q+vec2(.6,.5))*vec2(75.,43.);
  grid.y-=t*.28;
  vec2 cell=floor(grid),local=fract(grid)-.5;
  vec2 jitter=vec2(hash21(cell+3.1),hash21(cell+8.7))-.5;
  float star=exp(-dot(local-jitter*.7,local-jitter*.7)*160.);
  col+=(a+b+c)*.12*star*step(.985,hash21(cell+17.));
  // Filmic compression: bright neon cores without lifting the black stage.
  col=vec3(1.)-exp(-col*1.35);
  col=pow(max(col,vec3(0.)),vec3(.94));
  fragColor=vec4(col,1.);
}
