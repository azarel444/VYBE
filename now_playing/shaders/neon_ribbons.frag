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
float curve(float x,float t,float phase,float depth) {
  return .20*sin(x*2.3+t*.44+phase)
       + .11*sin(x*4.8-t*.29+phase*1.7)
       + .07*sin(x*8.0+t*.23+phase*.63)
       + depth*.13*sin(x*1.15-t*.17+phase);
}
vec3 ribbon(vec2 p,float t,float index,vec3 tint) {
  float phase=index*1.37;
  float depth=mod(index,3.);
  float y=curve(p.x,t*(.66+depth*.16),phase,depth)
        + (index-5.5)*.048;
  float dy=curve(p.x+.003,t*(.66+depth*.16),phase,depth)-curve(p.x-.003,t*(.66+depth*.16),phase,depth);
  float dist=abs(p.y-y)/sqrt(1.+pow(dy/.006,2.));
  float thickness=mix(.0018,.005,depth/2.);
  float core=exp(-pow(dist/thickness,1.25));
  float halo=exp(-dist*dist/(.028*.028));
  float wide=exp(-dist*dist/(.085*.085));
  float pulse=.70+.30*sin(t*.95+p.x*4.1+phase);
  float perspective=.56+.44*exp(-pow(p.x-.18*sin(t*.14+phase),2.)*.6);
  float opacity=(.58+.18*depth)*pulse*perspective;
  return tint*(core*1.8+halo*.48+wide*.105)*opacity;
}
void main() {
  vec2 uv=FlutterFragCoord().xy/uSize;
  float aspect=uSize.x/uSize.y;
  vec2 p=vec2((uv.x-.5)*aspect,(uv.y-.5));
  float t=uTime;
  vec3 a=normalize(uColorA+.001),b=normalize(uColorB+.001),c=normalize(uColorC+.001);
  vec3 col=mix(vec3(.0015,.002,.011),vec3(.008,.003,.026),smoothstep(-.45,.5,p.y));
  // Backlight: distant illuminated atmosphere behind the ribbons.
  float mist=.5+.5*sin(p.x*1.9+t*.16)*sin(p.y*4.1-t*.11);
  col+=(a*.025+b*.021+c*.022)*mist*exp(-dot(p,p)*.9);
  // Rear ribbons are dimmer and thinner, the near ribbons have hot cores.
  for(int i=0;i<12;i++) {
    float fi=float(i);
    vec3 tint=mod(fi,3.)<.5?a:(mod(fi,3.)<1.5?b:c);
    float layer=fi<4.? .30 : (fi<8.? .65 : 1.);
    col+=ribbon(p+vec2(0.,(1.-layer)*.04),t*(.52+layer*.45),fi,tint)*layer;
  }
  // Intermittent flowing glints chase the ribbons, like energized filaments.
  for(int i=0;i<9;i++) {
    float fi=float(i);
    float phase=fi*1.37;
    float x=mod(t*(.15+.018*mod(fi,3.))+hash21(vec2(fi,12.3))*2.5,2.8)-1.4;
    float y=curve(x,t*(.66+mod(fi,3.)*.16),phase,mod(fi,3.))+(fi-5.5)*.048;
    vec2 delta=p-vec2(x,y);
    float sparkle=exp(-dot(delta,delta)*2200.);
    vec3 tint=mod(fi,3.)<.5?a:(mod(fi,3.)<1.5?b:c);
    col+=tint*sparkle*.82;
  }
  // Scattered tiny light motes create a further depth plane.
  vec2 grid=uv*vec2(90.,46.);
  grid.y-=t*.43;
  vec2 cell=floor(grid);
  vec2 local=fract(grid)-.5;
  vec2 jitter=vec2(hash21(cell+3.1),hash21(cell+8.7))-.5;
  float star=exp(-dot(local-jitter*.7,local-jitter*.7)*175.);
  float gate=step(.972,hash21(cell+17.));
  col+=(a+b+c)*.21*star*gate;
  // Filmic compression: bright neon cores without lifting the black stage.
  col=vec3(1.)-exp(-col*1.35);
  col=pow(max(col,vec3(0.)),vec3(.94));
  fragColor=vec4(col,1.);
}
