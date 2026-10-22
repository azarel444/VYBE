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
// Independent animated displacement map. Broad folds move whole sheets;
// fine ripples shear their boundaries like colored light through oil.
float displacementHeight(vec2 p,float t) {
  float large=sin(p.x*2.7+t*.31)*cos(p.y*3.3-t*.27);
  float medium=sin(p.x*6.8-p.y*3.1-t*.48)
      *cos(p.y*6.1+p.x*2.4+t*.37);
  float fine=sin(p.x*13.1+p.y*8.7+t*.67)
      *sin(p.y*11.7-p.x*5.4-t*.53);
  return large*.55+medium*.31+fine*.14;
}
vec2 oilDisplacement(vec2 p,float t) {
  float e=.018;
  float dx=displacementHeight(p+vec2(e,0.),t)
          -displacementHeight(p-vec2(e,0.),t);
  float dy=displacementHeight(p+vec2(0.,e),t)
          -displacementHeight(p-vec2(0.,e),t);
  vec2 gradient=vec2(dx,dy)/(2.*e);
  // Curl drives swirling rather than simply sliding everything sideways.
  vec2 curl=vec2(gradient.y,-gradient.x);
  float amplitude=.035+.012*sin(t*.23);
  return curl*amplitude;
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
// Smooth union makes nearby liquid pockets connect through a glowing neck,
// rather than merely drawing two independent contours over one another.
float smoothUnion(float a,float b,float k) {
  float h=max(k-abs(a-b),0.)/k;
  return min(a,b)-h*h*k*.25;
}
float pocket(vec2 q,vec2 center,vec2 radii,float t,float phase) {
  vec2 v=(q-center)/radii;
  float theta=atan(v.y,v.x);
  float wobble=1.+.15*sin(theta*3.+t*.47+phase)
                 +.10*cos(theta*5.-t*.33+phase);
  return (length(v)-wobble)*min(radii.x,radii.y);
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
  vec2 displaced=p+oilDisplacement(p,t);
  vec2 q=flow(displaced,t*.78);
  // A smaller second displacement bends already-deformed features.
  q+=oilDisplacement(q,t*.71)*.28;
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
  // Refracting oil pockets: distorted circular light pools grow, touch,
  // merge into larger sheets, then pull apart as the flow changes.
  vec3 pools=vec3(0.);
  float joined=1.;
  float closest=10.;
  float second=10.;
  for(int i=0;i<6;i++){
    float fi=float(i);
    float phase=fi*2.39996;
    vec2 center=vec2(
      .50*sin(phase*1.3+t*(.12+.02*mod(fi,3.))),
      .38*cos(phase*.91-t*(.10+.017*mod(fi,2.))));
    vec2 radii=vec2(.19+.10*sin(phase*.8+t*.29),
                    .14+.065*cos(phase+t*.24));
    float d=pocket(q,center,radii,t,phase);
    closest=min(closest,d);
    second=min(second,max(d,closest));
    joined=smoothUnion(joined,d,.105);
    float interior=1.-smoothstep(-.035,.10,d);
    vec3 tint=mod(fi,3.)<.5?a:(mod(fi,3.)<1.5?b:c);
    pools+=tint*interior*(.07+.08*sin(t*.24+phase)*sin(t*.24+phase));
  }
  // A smooth union forms a single lit boundary when pools intersect.
  // The local joining region blooms as formerly separate edges converge.
  float joinRim=exp(-pow(abs(joined)/.021,1.35));
  float joinHalo=exp(-pow(abs(joined)/.105,1.6));
  float contact=exp(-pow(abs(second-closest)/.095,2.));
  float mergeGlow=contact*(.55+.45*sin(t*.35+q.x*2.));
  col+=pools*.54;
  col+=(a*.48+b*.39+c*.42)*joinRim*(.40+.65*mergeGlow);
  col+=(a*.19+b*.16+c*.18)*joinHalo*(.22+.35*mergeGlow);
  // Oil-like chromatic refraction: color bands shear on either side of
  // the moving merged boundary, including broad luminous filled regions.
  float refractBand=sin(joined*21.+q.x*3.7-q.y*2.8+t*.37);
  float fill=1.-smoothstep(-.16,.12,joined);
  col+=mix(a,b,.5+.5*refractBand)*fill*(.035+.095*contact);
  // Dispersion is strongest at curved oil boundaries, where compressed
  // filaments brighten and split into adjacent colored highlights.
  float refractionStrength=exp(-pow(abs(joined)/.10,2.));
  vec2 refracted=q+oilDisplacement(q,t+.37)*.45;
  float spectral=sin(refracted.x*19.-refracted.y*13.+t*.51);
  col+=mix(b,c,.5+.5*spectral)*refractionStrength*.095;
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
