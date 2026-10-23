#define SCENE 1
#include <flutter/runtime_effect.glsl>
uniform vec2 uSize;
uniform float uTime;
uniform vec3 uA;
uniform vec3 uB;
uniform vec3 uC;
uniform float uBass;
out vec4 fragColor;
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float noise(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x),f.y);}
float fog(vec3 p,float t){return .50*noise(p.xz*.36+vec2(t*.045,-t*.022))+.3*noise(p.xy*.85+vec2(t*.06,0.))+.2*noise(p.yz*1.8);}
float gauss(float x,float w){return exp(-x*x/(w*w));}
vec3 pal(float x){return x<.34?mix(uA,uB,x*2.94):mix(uB,uC,(x-.34)*1.51);}
vec3 tone(vec3 c){return pow(vec3(1.)-exp(-max(c,vec3(0.))*1.3),vec3(.88));}
void main(){
 vec2 uv=FlutterFragCoord().xy/uSize;
 vec2 p=(uv-.5)*vec2(uSize.x/uSize.y,1.);
 float t=uTime, bass=clamp(uBass,0.,1.);
 vec3 col=vec3(.003,.004,.014);
#if SCENE == 0 || SCENE == 2
 // Stage: fixed audience camera, grounded perspective floor and overhead rig.
 vec3 ro=vec3(0.,1.65,6.8),rd=normalize(vec3(p.x*1.6,p.y*-1.22,-2.25));
 float floorD=(-ro.y)/min(rd.y,-.0001);
 if(rd.y<-.02&&floorD>0.){
  vec3 hit=ro+rd*floorD;
  float grain=noise(hit.xz*4.);
  float grid=pow(1.-smoothstep(.015,.035,min(fract(hit.x*.72),fract(hit.z*.72))),1.5);
  col+=vec3(.014,.013,.027)+grain*.014+grid*.009;
 }
 // Distinct physical spot fixtures above the stage, panning independently.
 for(int i=0;i<9;i++){
  float fi=float(i);
  float x=(fi-4.)*.82;
  float side=mod(fi,2.)<.5?1.:-1.;
  vec3 origin=vec3(x,4.8,-3.2-.7*mod(fi,3.));
  vec3 target=vec3(x*.35+side*sin(t*(.27+.035*fi)+fi)*2.6,
                   .0,-3.7+cos(t*.22+fi*1.9)*1.6);
  vec3 axis=normalize(target-origin);
  // Closest approach of camera ray to a finite beam axis.
  vec3 w=ro-origin;
  float ab=dot(rd,axis),den=max(.0001,1.-ab*ab);
  float rayT=max(0.,(ab*dot(w,axis)-dot(w,rd))/den);
  vec3 sampleP=ro+rd*rayT;
  float beamT=dot(sampleP-origin,axis);
  float radial=length(sampleP-origin-axis*beamT);
  float spread=.065+max(0.,beamT)*.16;
  float within=smoothstep(0.,.45,beamT)*(1.-smoothstep(6.3,8.3,beamT));
  float cone=exp(-pow(radial/spread,2.)*1.65)*within;
  float mist=.32+.9*fog(sampleP,t);
  float pulse=.68+.35*sin(t*.85+fi*1.4)+bass*.75;
  vec3 tint=pal(fract(fi*.385));
  col+=tint*cone*mist*pulse*.45;
  // Fixture hot spots: lens glow and controlled bloom.
  vec3 lightDir=normalize(origin-ro);
  float sparkle=gauss(length(rd-lightDir),.018);
  col+=tint*sparkle*1.8+vec3(1.)*pow(sparkle,3.)*.65;
  // Floor pools respond to beam target rather than screen-space painting.
  if(rd.y<-.02&&floorD>0.){
    vec3 hit=ro+rd*floorD;
    float dist=length((hit-target).xz);
    float pool=exp(-dist*dist*.55)*(.35+.65*bass);
    col+=tint*pool*.25;
  }
 }
 // Atmospheric backdrop with stage edge.
 float stage=gauss(p.y+.14,.009)*smoothstep(.8,.35,abs(p.x));
 col+=pal(.46)*stage*.18;
#if SCENE == 2
 // Rave: foreground crowd silhouettes at staggered depths, with heads,
 // shoulders and raised arms. They remain opaque against the stage.
 for(int i=0;i<21;i++){
  float fi=float(i),seed=hash(vec2(fi,6.));
  float x=(fi/20.-.5)*2.25+(.5-seed)*.09;
  float height=.18+.18*hash(vec2(fi,2.));
  float baseY=.62+.065*hash(vec2(fi,4.));
  float head=length((p-vec2(x,baseY-height*.77))*vec2(1.,1.28));
  float body=length((p-vec2(x,baseY+.10))*vec2(.75,1.2));
  float silhouette=max(1.-smoothstep(.045,.052,head),1.-smoothstep(.095,.16,body));
  float handX=x+(.13+.1*seed)*sin(fi*3.);
  float arm=length(p-vec2(handX,baseY-height*.86-.08*sin(t*.8+fi)));
  silhouette=max(silhouette,1.-smoothstep(.023,.036,arm));
  col=mix(col,vec3(.001,.001,.006),silhouette*.98);
 }
#endif
#elif SCENE == 1
 // Lightstorm: perspective radial tunnel, streaks and blazing moving fixtures.
 vec2 van=vec2(.10*sin(t*.09),.07*cos(t*.13));
 vec2 q=p-van;
 float r=length(q),a=atan(q.y,q.x);
 float depth=1./max(.10,r);
 float phase=depth*2.5-t*.95;
 float ribs=pow(max(0.,cos(a*22.+sin(depth*.7)*.4)),22.);
 float rings=pow(max(0.,cos(phase*4.)),30.);
 col+=pal(fract(a/6.283+.5))*ribs*(.08+.48*rings)*(.25+.75*exp(-r*.75));
 for(int i=0;i<90;i++){
  float fi=float(i);
  float ang=fi*2.39996;
  float z=fract(fi*.618+t*(.055+.015*hash(vec2(fi,2.))));
  float depthSize=.035/(.09+z);
  vec2 pos=van+vec2(cos(ang),sin(ang))*(.045+z*z*1.55);
  float streak=gauss(dot(p-pos,normalize(pos-van)),depthSize*2.)*
    gauss(dot(p-pos,vec2(-sin(ang),cos(ang))),.002+.003*z);
  col+=pal(fract(fi*.27))*streak*(.07+.33*z);
 }
 for(int i=0;i<4;i++){
  float fi=float(i);
  vec2 pos=vec2(.47*sin(fi*2.2+t*.15),.3*cos(fi*1.7+t*.21));
  float d=length(p-pos);
  float core=gauss(d,.014);
  float halo=gauss(d,.16);
  float cross=gauss(p.x-pos.x,.004)*gauss(p.y-pos.y,.16)+gauss(p.y-pos.y,.004)*gauss(p.x-pos.x,.16);
  col+=pal(fract(fi*.37))*(core*3.+halo*.18+cross*.26)*(1.+bass*.9);
 }
#elif SCENE == 3
 // Neon Club: ray-plane intersection for 3D floor, side walls and ceiling.
 vec3 ro=vec3(0.,1.7,0.);
 vec3 rd=normalize(vec3(p.x*1.7,-p.y*1.22,-1.9));
 float nearT=1000.;vec3 hit=vec3(0.);float face=0.;
 if(rd.y<-.0001){float d=-ro.y/rd.y;if(d>0.&&d<nearT){nearT=d;hit=ro+rd*d;face=1.;}}
 if(rd.y>.0001){float d=(4.-ro.y)/rd.y;if(d>0.&&d<nearT){nearT=d;hit=ro+rd*d;face=2.;}}
 if(rd.x<-.0001){float d=(-3.8-ro.x)/rd.x;if(d>0.&&d<nearT){nearT=d;hit=ro+rd*d;face=3.;}}
 if(rd.x>.0001){float d=(3.8-ro.x)/rd.x;if(d>0.&&d<nearT){nearT=d;hit=ro+rd*d;face=4.;}}
 if(nearT<1000.&&hit.z<-.1){
   vec2 tile=face<2.5?vec2(hit.x,hit.z):vec2(hit.z,hit.y);
   float forward=-tile.y+t*.62;
   vec2 cell=floor(vec2(tile.x*2.2,forward*1.6));
   vec2 edge=abs(fract(vec2(tile.x*2.2,forward*1.6))-.5);
   float panel=1.-smoothstep(.43,.49,max(edge.x,edge.y));
   float seed=hash(cell);
   float wave=.5+.5*sin(t*1.1+cell.x*.9+cell.y*.45);
   vec3 light=pal(fract(seed*.8+floor(t*.12)*.07));
   float focus=abs(nearT-6.);
   // Depth-aware lens approximation: distance attenuates and softens panels.
   float dof=clamp(focus*.026,0.,.25);
   float softPanel=1.-smoothstep(.36-dof,.48+dof,max(edge.x,edge.y));
   float brightness=(.16+.72*wave+bass*.55)*step(.22,seed);
   col+=light*softPanel*brightness*(face==1.? .72:.42);
   col+=vec3(.008,.009,.018);
   col+=light*panel*.045;
   float fogAmt=exp(-nearT*.055);
   col*=fogAmt;
 }
 // Far tunnel lights and cross-beams through the center.
 for(int i=0;i<7;i++){
   float fi=float(i);
   vec2 pos=vec2(.48*sin(fi*1.9+t*.19),-.2+.28*cos(fi*2.1+t*.23));
   float d=length(p-pos);
   float halo=gauss(d,.19),core=gauss(d,.022);
   vec3 tint=pal(fract(fi*.37));
   col+=tint*(halo*.13+core*1.45)*(1.+bass*.6);
   float beam=gauss(p.x-pos.x-.3*(p.y-pos.y),.045)*gauss(p.y-pos.y,.36);
   col+=tint*beam*.16;
 }
#endif
 // Filmic vignette, distant haze and highlight roll-off.
 float vignette=1.-.45*smoothstep(.3,1.7,dot(p,p));
 col*=vignette;
 fragColor=vec4(tone(col),1.);
}
