#define SCENE 3
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
vec3 renderScene(vec2 uv){
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
 // Neon Club: open black ceiling, large luminous dance-floor panels,
 // scattered variable-size wall fixtures and overhead moving spotlights.
 vec3 ro=vec3(0.,1.72,-mod(t*1.45,24.));
 vec3 rd=normalize(vec3(p.x*1.7,-p.y*1.22,-1.9));
 float nearT=1000.;vec3 hit=vec3(0.);float face=0.;
 if(rd.y<-.0001){float d=-ro.y/rd.y;if(d>0.&&d<nearT){nearT=d;hit=ro+rd*d;face=1.;}}
 if(rd.x<-.0001){float d=(-3.8-ro.x)/rd.x;if(d>0.&&d<nearT){nearT=d;hit=ro+rd*d;face=3.;}}
 if(rd.x>.0001){float d=(3.8-ro.x)/rd.x;if(d>0.&&d<nearT){nearT=d;hit=ro+rd*d;face=4.;}}
 // Ceiling deliberately has no surface: overhead fixtures float in darkness.
 float distanceFade=exp(-max(0.,nearT-1.5)*.075);
 if(nearT<1000.&&hit.z<-.05){
   if(face==1.){
     // Larger physical floor tiles, no scrolling grid: light animates in place.
     vec2 coord=vec2(hit.x*.78,hit.z*.78);
     vec2 cell=floor(coord),local=abs(fract(coord)-.5);
     float border=max(local.x,local.y);
     float panel=1.-smoothstep(.425,.485,border);
     float bloom=exp(-pow(max(0.,border-.33)/.26,2.));
     float seed=hash(cell+vec2(9.,2.));
     float phase=t*3.6+cell.x*2.17+cell.y*1.63;
     float pulse=.48+.52*sin(phase+1.2*sin(t*.85+cell.y*.7));
     vec3 tint=pal(fract(seed*.83+.11*sin(t*.11)));
     float chase=.5+.5*sin(t*3.7-cell.y*1.65+cell.x*2.2);
     float randomGate=hash(cell+floor(t*2.8)*vec2(17.3,39.7));
     float lit=step(.72,randomGate)*step(.20,seed)*(.35+.65*pulse)*(.5+.5*pow(chase,2.));
     col+=vec3(.004,.005,.012)*distanceFade;
     col+=tint*(panel*1.65+bloom*.95)*lit*distanceFade;
     // Soft chromatic spill over neighboring dark grout.
     col+=tint*exp(-pow(max(0.,border-.46)/.38,2.))*.32*lit*distanceFade;
   }else{
     // Sparse, staggered wall fixtures with multiple rectangular proportions.
     vec2 coord=vec2(-hit.z*.92,hit.y*1.35);
     vec2 cell=floor(coord),local=abs(fract(coord)-.5);
     float seed=hash(cell+vec2(face*7.,13.));
     float fixtureEnabled=step(.70,seed);
     float wallChase=.55+.45*sin(t*1.8+cell.x*.72+face);
     float variant=hash(cell+vec2(2.,19.));
     vec2 halfSize=variant<.33?vec2(.37,.055):
                   (variant<.67?vec2(.085,.34):vec2(.22,.20));
     vec2 delta=max(local-halfSize,vec2(0.));
     float dist=length(delta);
     float panel=1.-smoothstep(.006,.055,dist);
     float glow=exp(-dist*dist*42.);
     float pulse=.42+.58*sin(t*2.1+seed*11.+.8*sin(t*.65+cell.x));
     vec3 tint=pal(fract(seed*1.7+t*.025));
     col+=vec3(.003,.004,.009)*distanceFade;
     col+=tint*(panel*1.45+glow*.56)*fixtureEnabled*(.35+.65*wallChase)*pulse*distanceFade;
   }
 }
 // Physically related spotlight cones and pools: beam and floor share targets.
 for(int i=0;i<3;i++){
   float fi=float(i);
   vec3 origin=ro+vec3((fi-1.)*1.8,3.8,-4.0-fi*.9);
   vec3 target=vec3(1.7*sin(t*(.65+fi*.085)+fi*2.1),
                    0.,ro.z-4.5+2.0*cos(t*.55+fi*1.9));
   vec3 axis=normalize(target-origin);
   vec3 w=ro-origin;
   float ab=dot(rd,axis);
   float denom=max(.0001,1.-ab*ab);
   float rayT=max(0.,(ab*dot(w,axis)-dot(w,rd))/denom);
   vec3 sampleP=ro+rd*rayT;
   float along=dot(sampleP-origin,axis);
   float radial=length(sampleP-origin-axis*along);
   float spread=.065+max(0.,along)*.105;
   float cone=exp(-pow(radial/spread,2.)*1.7)*
     smoothstep(0.,.7,along)*(1.-smoothstep(5.8,7.4,along));
   vec3 tint=pal(fract(fi*.43+.11));
   float mist=.38+.40*fog(sampleP,t*2.0);
   col+=tint*cone*mist*(.46+.20*bass);
   vec3 fixture=normalize(origin-ro);
   float hot=gauss(length(rd-fixture),.015);
   col+=tint*(hot*1.15+gauss(length(rd-fixture),.045)*.06);
   if(face==1.&&nearT<1000.&&hit.z<-.05){
     float radius=length((hit-target).xz);
     float pool=exp(-radius*radius*1.1);
     // Colored spot pools light the tile material and boost its glow.
     col+=tint*pool*(.19+.12*bass)*distanceFade;
   }
 }

#endif
#if SCENE != 3
 // Existing cinematic shading for the other environments.
 float vignette=1.-.45*smoothstep(.3,1.7,dot(p,p));
 col*=vignette;
#endif
 return tone(col);
}
void main(){
 vec2 uv=FlutterFragCoord().xy/uSize;
#if SCENE == 3
 // The center remains optically clean. Turbulent edge lensing and
 // RGB channel separation build rapidly beyond 55% of screen radius.
 vec2 centered=uv-.5;
 vec2 normalized=centered*2.;
 float radius=length(normalized);
 float edge=smoothstep(.72,1.12,radius);
 float strength=edge*edge*edge;
 float t=uTime;
 float bass=clamp(uBass,0.,1.);
 float a=atan(normalized.y,normalized.x);
 float swirl=sin(a*7.0+t*3.1+radius*12.)+
             .65*sin(a*13.-t*2.4+radius*19.);
 float turbulence=noise(normalized*vec2(5.,7.)+
             vec2(t*.8,-t*.67))-.5;
 vec2 radial=normalize(normalized+vec2(.00001));
 vec2 tangent=vec2(-radial.y,radial.x);
 vec2 displacement=strength*(
    radial*(.034*swirl+.042*turbulence)+
    tangent*(.023*sin(t*4.2+radius*21.+a*9.)+
             .025*turbulence));
 displacement*=1.+bass*.65;
 vec2 warped=clamp(uv+displacement,vec2(0.),vec2(1.));
 // Chromatic split is directional, animated and deliberately pronounced
 // near corners; the center has no channel displacement.
 float split=(.006+.023*strength)*(1.+.7*bass)*strength;
 vec2 chromaDir=normalize(radial+.38*tangent*sin(t*2.7+a*6.));
 vec3 redSample=renderScene(clamp(warped+chromaDir*split,vec2(0.),vec2(1.)));
 vec3 greenSample=renderScene(warped);
 vec3 blueSample=renderScene(clamp(warped-chromaDir*split,vec2(0.),vec2(1.)));
 fragColor=vec4(redSample.r,greenSample.g,blueSample.b,1.);
#else
 fragColor=vec4(renderScene(uv),1.);
#endif
}
