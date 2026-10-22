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
// Signed liquid contours: each band has a broad translucent body, an
// intensely lit irregular rim, and a narrow white-hot filament.
vec3 filament(vec2 q,float t,float index,vec3 tint) {
  float phase=index*1.618;
  float depth=mod(index,3.);
  vec2 r=q+vec2(.21*sin(phase+t*.09),.19*cos(phase*.83-t*.11));
  float field=sin(r.x*(3.6+depth*.48)+phase)
      +.92*cos(r.y*(4.1+depth*.55)-phase*.83)
      +.44*sin((r.x+r.y)*6.7+t*.21+phase*.73);
  float contour=(index-5.5)*.19;
  float signedDistance=field-contour;
  float d=abs(signedDistance);
  // Variable thickness creates expanding sheets and narrowing tendrils.
  float swelling=.5+.5*sin(r.x*4.2-r.y*3.1+t*.57+phase);
  float width=mix(.012,.085,pow(swelling,2.3));
  float core=exp(-pow(d/max(width*.27,.004),1.3));
  float rim=exp(-pow(d/max(width,.013),1.5));
  float bloom=exp(-pow(d/(width+.16),2.));
  float liquid=smoothstep(-.19,.09,signedDistance)
      *(1.-smoothstep(.12,.67,signedDistance));
  float softBody=liquid*(.08+.13*swelling);
  float depthGain=depth<.5?.44:(depth<1.5?.68:.90);
  return tint*(core*1.48+rim*.54+bloom*.13+softBody)
      *depthGain*(.82+.18*sin(t*.37+phase));
}
void main() {
  vec2 uv=FlutterFragCoord().xy/uSize;
  float aspect=uSize.x/uSize.y;
  vec2 p=vec2((uv.x-.5)*aspect,(uv.y-.5));
  float t=uTime;
  vec3 a=normalize(uColorA+.001),b=normalize(uColorB+.001),c=normalize(uColorC+.001);
  vec3 col=mix(vec3(.0015,.002,.011),vec3(.008,.003,.026),smoothstep(-.45,.5,p.y));
  // Shared advected coordinates: every luminous sheet, boundary and
  // background pool bends through the same moving liquid.
  vec2 q=flow(p,t*.78);
  float depthLight=.5+.5*sin(q.x*3.1+t*.18)*cos(q.y*4.3-t*.16);
  col+=(a*.046+b*.041+c*.045)*depthLight*exp(-dot(q,q)*.35);
  // Deep, middle and foreground contours with independent color shifts.
  for(int i=0;i<12;i++){
    float fi=float(i);
    vec3 tint=mod(fi,3.)<.5?a:(mod(fi,3.)<1.5?b:c);
    float layer=fi<4.? .38 : (fi<8.? .67 : 1.);
    vec2 shifted=q+vec2(.045*sin(t*.18+fi),.055*cos(t*.14+fi));
    col+=filament(shifted,t*(.68+layer*.32),fi,tint)*layer;
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
