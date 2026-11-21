#include <flutter/runtime_effect.glsl>
uniform vec2 size;
uniform vec2 tilt;
uniform float time;
out vec4 fragColor;
void main(){
 vec2 uv=FlutterFragCoord().xy/size;
 float distance=uv.x*.7+uv.y*.3-.45-tilt.x*.15-tilt.y*.1;
 float alpha=.08*exp(-distance*distance*80.);
 fragColor=vec4(vec3(alpha),alpha);
}
