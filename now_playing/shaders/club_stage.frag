#include <flutter/runtime_effect.glsl>

// Club Stage — front-row view. Distinct from Rave, Neon Club and Golden Hour.
uniform vec2 uSize;
uniform float uTime;
uniform vec3 uA;
uniform vec3 uB;
uniform vec3 uC;
uniform float uBass;
out vec4 fragColor;

float hash21(vec2 p) {
  return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);
}
float noise2(vec2 p) {
  vec2 i=floor(p), f=fract(p);
  f=f*f*(3.-2.*f);
  return mix(mix(hash21(i),hash21(i+vec2(1.,0.)),f.x),
             mix(hash21(i+vec2(0.,1.)),hash21(i+vec2(1.,1.)),f.x),f.y);
}
float gauss(float x,float width) {
  return exp(-pow(x/max(width,.0001),2.));
}
vec3 stageColor(float seed) {
  float n=fract(seed);
  vec3 c=n<.333 ? mix(uA,uB,n*3.)
     : n<.666 ? mix(uB,uC,(n-.333)*3.)
              : mix(uC,uA,(n-.666)*3.);
  // Saturate the actual chosen stage/album palette, not a milky white wash.
  float low=min(c.r,min(c.g,c.b));
  return clamp(vec3(low)+(c-vec3(low))*1.60,0.,1.);
}
vec3 tonemap(vec3 c) {
  // A quieter highlight shoulder preserves separation between colored
  // fixtures even when multiple beams cross on a strong bass hit.
  return pow(vec3(1.)-exp(-max(c,vec3(0.))*.91),vec3(.97));
}

// A tapering spotlight in camera space. Distinct core and smoky outer cone;
// angled moving beams keep their fixture position while their targets sweep.
float lightCone(vec2 p,vec2 origin,vec2 target,
                float startWidth,float widening,float reach) {
  vec2 ray=target-origin;
  float len=max(length(ray),.001);
  vec2 dir=ray/len;
  vec2 v=p-origin;
  float along=dot(v,dir);
  float sideways=abs(v.x*dir.y-v.y*dir.x);
  float width=startWidth+max(along,0.)*widening;
  float cone=gauss(sideways,width);
  return cone*smoothstep(-.025,.065,along)*
      (1.-smoothstep(len*.82,len*reach,along));
}
vec3 neonBackdrop(vec2 p,float aspect,float time,float bass) {
  // LED wall: consecutive nested X / chevron frames move OUT from a true
  // central vanishing point. Their projected size and line width accelerate
  // toward the audience, unlike uniformly sliding diagonal lines.
  vec2 q=vec2(p.x/max(aspect*.79,.25),(p.y+.015)*1.55);
  float radial=length(q);
  float chevron=abs(abs(q.x)-abs(q.y));
  float wallMask=(1.-smoothstep(.085,.21,p.y))*
                 (1.-.62*smoothstep(.82,1.48,radial));
  vec3 bg=vec3(0.);
  for(int i=0;i<10;i++) {
    float fi=float(i);
    float depth=fract(fi/10.+time*.105);
    float projected=.025+1.70*depth*depth;
    float width=.0028+.010*depth;
    // The paired outward-opening chevrons form successive moving X frames.
    float d=abs(chevron-projected);
    float line=gauss(d,width);
    float glow=gauss(d,width*3.8);
    // Each receding ring has a different saturated hue and a restrained halo.
    vec3 tint=stageColor(fi*.295+.07);
    float visibility=smoothstep(.02,.14,depth)*
                     (1.-smoothstep(.86,1.0,depth));
    float distanceGain=.20+.78*depth;
    bg+=tint*(line*.47+glow*.085)*visibility*distanceGain;
  }
  // Keep the LED wall's black negative space. Bass changes individual
  // highlights slightly, never the entire wall's brightness.
  return bg*wallMask*(.92+.08*bass);
}
void main() {
  vec2 uv=FlutterFragCoord().xy/uSize;
  float aspect=uSize.x/max(uSize.y,1.);
  vec2 p=(uv-.5)*vec2(aspect,1.);
  float t=uTime;
  float bass=clamp(uBass,0.,1.);

  // Layers are rendered back-to-front. Stage art remains responsive to the
  // same portrait/landscape camera; no orientation-specific bitmap scaling.
  vec3 col=vec3(.002,.002,.008);
  col+=neonBackdrop(p,aspect,t,bass);

  // Distant concert-hall haze separates the geometric LED wall from the
  // moving lights. No bright floating horizon line.
  float wallMist=gauss(p.y+.035,.28);
  col+=mix(uA,uB,.54)*wallMist*.012;

  // Rear rig: seven slim, saturated beams behind the main light heads.
  // Lamps are small and rays end around the back of the stage.
  for(int i=0;i<7;i++) {
    float fi=float(i);
    float side=(fi-3.)/3.;
    vec2 src=vec2(side*aspect*.39,-.355);
    vec2 dst=vec2(side*aspect*.20+
        sin(t*(.33+.025*fi)+fi*1.48)*aspect*.21,.28);
    vec3 tint=stageColor(fi*.273+.11);
    float core=lightCone(p,src,dst,.010,.065,1.30);
    float halo=lightCone(p,src,dst,.034,.125,1.36);
    float energy=.68+.13*sin(t*.76+fi*1.20)+bass*.13;
    col+=tint*(core*.54+halo*.055)*energy;
    float lens=gauss(length(p-src),.013);
    col+=tint*(lens*1.18+gauss(length(p-src),.047)*.075);
  }

  // Main moving heads: large, visibly panning spotlights at front-row
  // distance, with sharper colored shafts and a drifting haze envelope.
  for(int i=0;i<6;i++) {
    float fi=float(i);
    float side=(fi-2.5)/2.5;
    vec2 src=vec2(side*aspect*.48,-.305+.015*sin(fi*2.3));
    float pan=sin(t*(.42+.022*fi)+fi*1.57);
    vec2 dst=vec2(side*aspect*.12+pan*aspect*.36,
                  .48+.035*cos(t*.29+fi));
    vec3 tint=stageColor(fi*.297+.24);
    float shaft=lightCone(p,src,dst,.018,.092,1.34);
    float atmosphere=lightCone(p,src,dst,.075,.190,1.40);
    float drift=.78+.22*noise2(p*vec2(4.2,7.4)+vec2(t*.16,fi*2.8));
    float level=.65+.13*sin(t*.8+fi)+bass*.20;
    col+=tint*(shaft*.82+atmosphere*.065)*drift*level;
    // Real fixture bloom, with a small white-hot lamp at its root.
    float lens=gauss(length(p-src),.017);
    col+=tint*(lens*1.30+gauss(length(p-src),.065)*.13);
    col+=vec3(1.)*pow(lens,2.)*.20;
  }

  // Physical dark stage floor. A gently curved/hazy join marks where the
  // LED wall meets the deck, while receding rectangular seams and grazing
  // reflections create a readable ground plane, including in portrait.
  float horizon=.105;
  float floorMask=smoothstep(horizon-.018,horizon+.078,p.y);
  float depth=max(p.y-horizon,0.);
  float perspective=1./max(depth+.064,.064);
  vec2 ground=vec2(p.x*perspective*1.05,perspective*.85);
  float tx=fract(ground.x*.40);
  float tz=fract(ground.y*.35);
  float lineX=1.-smoothstep(.005,.028,min(tx,1.-tx));
  float lineZ=1.-smoothstep(.005,.027,min(tz,1.-tz));
  float detail=noise2(ground*1.1+vec2(t*.004,0.));
  float distanceFade=smoothstep(.015,.25,depth);
  float seams=(lineX*.028+lineZ*.045)*distanceFade;
  vec3 floorColor=vec3(.012,.013,.026)*
      (1.+.15*detail)+vec3(.025,.026,.045)*seams;

  // Soft light pools stay localized and never create a solid pastel overlay.
  // A few broken thin reflection streaks anchor the moving heads to the deck.
  for(int i=0;i<6;i++) {
    float fi=float(i);
    float side=(fi-2.5)/2.5;
    float pan=sin(t*(.42+.022*fi)+fi*1.57);
    float targetX=side*aspect*.12+pan*aspect*.36;
    float width=.07+depth*.55;
    float pool=gauss(p.x-targetX,width)*exp(-depth*3.5);
    float micro=pow(max(0.,sin(ground.y*2.4+
        detail*3.8+fi*1.4+t*.24)),10.);
    vec3 tint=stageColor(fi*.297+.24);
    floorColor+=tint*pool*(.065+.055*micro+.028*bass);
  }
  // Leave a visible stage lip at the back without a line across the sky.
  float lip=gauss(p.y-horizon,.008)*
      (1.-smoothstep(aspect*.54,aspect*.88,abs(p.x)));
  floorColor+=stageColor(.46)*lip*.065;
  // Ground is largely opaque: foreground beams can still cross it because
  // their camera-pass layer remains above this stage surface.
  col=mix(col,floorColor,floorMask*.98);
  // CLOSE CAMERA PASS: wide beams originate just above/outside the frame.
  // They sweep across the viewer, overlapping and partially leaving the
  // screen, while smaller lights stay visible further back.
  for(int i=0;i<4;i++) {
    float fi=float(i);
    float signX=mod(fi,2.)<.5 ? -1. : 1.;
    vec2 src=vec2(signX*(aspect*.57+.09),
                  -.61+.07*floor(fi*.50));
    float sweep=sin(t*(.25+.057*fi)+fi*1.90);
    vec2 dst=vec2(sweep*aspect*.56-signX*aspect*.16,
                  .55+.18*sin(t*.18+fi*1.34));
    vec3 tint=stageColor(fi*.292+.39);
    float pass=lightCone(p,src,dst,.095,.24,1.45);
    float nearMist=lightCone(p,src,dst,.19,.40,1.55);
    // Large near beams never bleach the scene white.
    col+=tint*(pass*.17+nearMist*.022)*(.75+.12*bass);
  }

  // Filmic vignette frames the stage without crushing center neon detail.
  vec2 v=vec2(p.x/max(aspect*.80,.20),p.y*1.60);
  float vignette=1.-.49*smoothstep(.52,1.55,length(v));
  col*=vignette;
  fragColor=vec4(tonemap(col),1.);
}
