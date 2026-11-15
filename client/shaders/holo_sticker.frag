#include <flutter/runtime_effect.glsl>
uniform vec2 size;
uniform vec2 tilt;
uniform float time;
out vec4 fragColor;
void main(){
 vec2 uv=FlutterFragCoord().xy/size;
 float phase=uv.x*.8+uv.y*.35+dot(tilt,vec2(.35,.55))+.08*sin(time);
 vec3 foil=.55+.45*cos(6.283*(phase+vec3(0.,.33,.67)));
 float gleam=pow(max(0.,cos(6.283*phase)),20.);
 vec2 grid=uv*13.;
 vec2 p=abs(fract(grid)-.5);
 float sparkle=exp(-min(p.x,p.y)*75.-max(p.x,p.y)*11.)*pow(max(0.,sin(dot(floor(grid),vec2(2.1,7.2))+time)),10.);
 float a=.08+.23*gleam+.43*sparkle;
 fragColor=vec4(mix(foil,vec3(1.),gleam*.7)*a,a);
}
