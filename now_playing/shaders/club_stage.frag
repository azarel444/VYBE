#define SCENE 0
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
 // Club Stage: audience-facing camera, visible moving heads, volumetric
 // light cones, and an illuminated reflective floor (no floating horizon line).
 float aspect=uSize.x/uSize.y;
 float stageWidth=clamp(aspect*.78,.60,1.70);
 vec3 ro=vec3(0.,1.65,6.8);
 vec3 rd=normalize(vec3(p.x*1.6,-p.y*1.22,-2.25));
 float floorD=ro.y/max(-rd.y,.0001);
 vec3 hit=ro+rd*floorD;
 // Fade the floor into stage haze instead of drawing a hard horizontal seam.
 float floorMask=smoothstep(.008,.105,p.y);
 float floorGrain=noise(hit.xz*3.2);
 if(rd.y<-.001){
   vec2 tile=abs(fract(hit.xz*.55)-.5);
   float joint=1.-smoothstep(.475,.50,max(tile.x,tile.y));
   col+=floorMask*(vec3(.011,.012,.023)+floorGrain*.010+joint*.006);
 }
 // Subdued truss and atmospheric back wall establish a physical room.
 float backHaze=gauss(p.y+.065,.24)*(1.-smoothstep(.45,1.40,abs(p.x)));
 col+=pal(.40)*backHaze*(.028+.035*bass);
 float rigY=-.322;
 float rigExtent=1.-smoothstep(.74*stageWidth,1.10*stageWidth,abs(p.x));
 col+=vec3(.042,.047,.065)*gauss(p.y-rigY,.006)*rigExtent;
 col+=vec3(.025,.029,.044)*gauss(p.y-rigY+.018,.004)*rigExtent;
 // Nine moving-head spots with unique pan phases and real floor targets.
 for(int i=0;i<9;i++){
   float fi=float(i);
   float x=(fi-4.)*1.0*stageWidth;
   vec3 origin=vec3(x,3.7,-4.8-.12*mod(fi,3.));
   float pan=sin(t*(.34+.017*fi)+fi*1.18);
   vec3 target=vec3(x*.42+pan*1.45*stageWidth,
                    .0,-4.35+cos(t*.25+fi*1.65)*1.1);
   vec3 axis=normalize(target-origin);
   // Distance between view ray and spotlight's finite central axis.
   vec3 w=ro-origin;
   float ab=dot(rd,axis);
   float rayT=max(0.,(ab*dot(w,axis)-dot(w,rd))/max(.0001,1.-ab*ab));
   vec3 sampleP=ro+rd*rayT;
   float beamT=dot(sampleP-origin,axis);
   float radial=length(sampleP-origin-axis*beamT);
   float spread=.065+max(0.,beamT)*.112;
   float lengthFade=smoothstep(0.,.34,beamT)*
       (1.-smoothstep(4.9,6.8,beamT));
   float beamCore=exp(-pow(radial/spread,2.)*2.1);
   float beamHaze=exp(-pow(radial/(spread*2.25),2.)*2.0);
   float mist=.44+.84*fog(sampleP,t);
   float pulse=.82+.20*sin(t*.72+fi*1.5)+bass*.77;
   vec3 tint=pal(fract(fi*.297));
   col+=tint*(beamCore*.83+beamHaze*.16)*lengthFade*mist*pulse;
   // Small visible housings and luminous lenses at the beam origins.
   float cameraDepth=ro.z-origin.z;
   vec2 lamp=vec2(origin.x/cameraDepth*(2.25/1.6),
       -(origin.y-ro.y)/cameraDepth*(2.25/1.22));
   float head=1.-smoothstep(.016,.024,length((p-lamp)*vec2(1.,1.28)));
   col=mix(col,vec3(.015,.017,.030),head*.60);
   float core=gauss(length(p-lamp),.013);
   float halo=gauss(length(p-lamp),.058);
   col+=tint*(core*1.65+halo*.22)*(1.+bass*.36);
   col+=vec3(1.)*pow(core,3.)*.42;
   // Broad pools at each target, plus broken glossy floor streaks.
   if(rd.y<-.001){
     vec2 d=hit.xz-target.xz;
     float pool=exp(-dot(d,d)*.29);
     float glint=pow(max(0.,sin(hit.z*7.2+
         floorGrain*4.2+t*.20)),8.);
     float stripe=exp(-pow(d.x/(.24+.09*abs(d.y)),2.))*
         exp(-abs(d.y)*.27);
     col+=floorMask*tint*(pool*(.28+.42*bass)+
         pool*glint*.23+stripe*(.05+.10*glint));
   }
 }
 // A faint stage edge beneath the distant lights, not a bright floating line.
 float stageLip=gauss(p.y-.115,.012)*
     (1.-smoothstep(.57*stageWidth,.92*stageWidth,abs(p.x)));
 col+=pal(.46)*stageLip*.045;
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
