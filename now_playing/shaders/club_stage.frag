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
  return pow(vec3(1.)-exp(-max(c,vec3(0.))*1.28),vec3(.88));
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
  // Aspect-corrected expanding chevrons on all four sides: an animated
  // symmetrical X / neon tunnel, with true black gaps between the strips.
  vec2 q=vec2(p.x/max(aspect*.71,.20),(p.y+.035)*1.56);
  float chevron=abs(abs(q.x)-abs(q.y));
  float radial=length(q);
  float gate=(1.-smoothstep(.13,.36,p.y))*
      smoothstep(.085,.20,radial);
  float edgeVignette=1.-.64*smoothstep(.75,1.53,radial);
  vec3 bg=vec3(0.);
  for(int i=0;i<12;i++) {
    float fi=float(i);
    // Constant outward motion; after exiting the field each stripe restarts
    // at the vanishing point. Multiple hues/shapes create neon layering.
    float phase=fract(fi/12.+time*.070);
    float radius=phase*1.48;
    float dist=abs(chevron-radius);
    float core=gauss(dist,.0060);
    float bloom=gauss(dist,.031);
    float halo=gauss(dist,.085);
    float segmented=.78+.22*sin(q.x*31.+q.y*13.+fi*2.7);
    vec3 tint=stageColor(fi*.265+.07);
    // Periodic white-hot and violet accents; color remains palette led.
    vec3 light=mix(tint,vec3(1.),.11+.16*step(.83,hash21(vec2(fi,8.))));
    bg+=light*(core*.50+bloom*.20+halo*.046)*segmented;
  }
  // Bright center energy keeps the neon pattern from becoming an empty X.
  float pulse=.72+.28*bass;
  float center=gauss(radial,.19);
  bg+=mix(uB,uA,.4)*center*.065*pulse;
  return bg*gate*edgeVignette*(.88+.34*bass);
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
  col+=mix(uA,uB,.54)*wallMist*(.013+.023*bass);

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
    float energy=.84+.17*sin(t*.76+fi*1.20)+bass*.56;
    col+=tint*(core*.63+halo*.15)*energy;
    float lens=gauss(length(p-src),.013);
    col+=tint*(lens*1.25+gauss(length(p-src),.047)*.11);
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
    float level=.86+.17*sin(t*.8+fi)+bass*.82;
    col+=tint*(shaft*.96+atmosphere*.18)*drift*level;
    // Real fixture bloom, with a small white-hot lamp at its root.
    float lens=gauss(length(p-src),.017);
    col+=tint*(lens*1.40+gauss(length(p-src),.065)*.25);
    col+=vec3(1.)*pow(lens,2.)*.28;
  }

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
    col+=tint*(pass*.37+nearMist*.085)*(.82+.52*bass);
  }

  // Satin stage floor, not a wireframe/hard horizon. Soft reflections of
  // individual lamp targets fade toward the audience and break into glints.
  float floorMask=smoothstep(.12,.34,p.y);
  float floorDepth=max(p.y-.17,0.);
  float grain=noise2(vec2(p.x*8.+t*.018,p.y*18.));
  col=mix(col,col*.60+vec3(.004,.005,.013),floorMask*.35);
  col+=floorMask*vec3(.006,.007,.013)*(.5+.5*grain);
  for(int i=0;i<6;i++) {
    float fi=float(i);
    float side=(fi-2.5)/2.5;
    float pan=sin(t*(.42+.022*fi)+fi*1.57);
    float targetX=side*aspect*.12+pan*aspect*.36;
    float width=.07+floorDepth*.65;
    float strip=gauss(p.x-targetX,width);
    float broken=.28+.72*pow(max(0.,sin(floorDepth*61.+
        grain*4.1+fi*1.3+t*.36)),8.);
    float falloff=exp(-floorDepth*3.7);
    vec3 tint=stageColor(fi*.297+.24);
    col+=floorMask*tint*strip*falloff*broken*
        (.16+.24*bass);
  }
  // Filmic vignette frames the stage without crushing center neon detail.
  vec2 v=vec2(p.x/max(aspect*.80,.20),p.y*1.60);
  float vignette=1.-.49*smoothstep(.52,1.55,length(v));
  col*=vignette;
  fragColor=vec4(tonemap(col),1.);
}
