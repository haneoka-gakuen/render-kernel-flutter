// Generated from @haneoka/render-shaders FSR 1.0.2 (MIT).
// See LICENSE-FidelityFX-FSR.txt. All backends use the same FP32 tap footprint.
#version 450
layout(location=0) in vec2 uv;
layout(location=1) in vec4 tint;
layout(location=0) out vec4 fragment;
layout(set=0,binding=0) uniform sampler2D image;
layout(set=0,binding=1) uniform RcasSettings { vec4 sizeSharpness; } settings;
vec3 tap(vec2 p) {
  vec2 size=settings.sizeSharpness.xy;
  return texture(image,(clamp(p,vec2(0.0),size-1.0)+0.5)/size).rgb;
}
void main() {
  vec2 p=floor(uv*settings.sizeSharpness.xy);
  vec3 b=tap(p+vec2(0,-1)),d=tap(p+vec2(-1,0)),e=tap(p),f=tap(p+vec2(1,0)),h=tap(p+vec2(0,1));
  vec3 lo=min(min(b,d),min(f,h)),hi=max(max(b,d),max(f,h));
  // Exact reciprocals with finite limits for constant black/white regions.
  vec3 hitMin=min(lo,e)/max(4.0*hi,vec3(1e-20));
  vec3 hitMax=(1.0-max(hi,e))/min(4.0*lo-4.0,vec3(-1e-20));
  vec3 lobes=max(-hitMin,hitMax);
  float lobe=max(-0.1875,min(max(lobes.r,max(lobes.g,lobes.b)),0.0))*settings.sizeSharpness.z;
  vec3 result=(lobe*(b+d+f+h)+e)/(4.0*lobe+1.0);
  fragment=vec4(clamp(result,0.0,1.0),1.0)*tint;
}
