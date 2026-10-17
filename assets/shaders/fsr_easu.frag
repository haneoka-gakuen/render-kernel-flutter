// Generated from @haneoka/render-shaders FSR 1.0.2 (MIT).
// See LICENSE-FidelityFX-FSR.txt. All backends use the same FP32 tap footprint.
#version 450
layout(location=0) in vec2 uv;
layout(location=1) in vec4 tint;
layout(location=0) out vec4 fragment;
layout(set=0,binding=0) uniform sampler2D image;
layout(set=0,binding=1) uniform EasuSettings { vec4 inputOutput; } settings;
vec3 tap(vec2 p) {
  vec2 size=settings.inputOutput.xy;
  return texture(image,(clamp(p,vec2(0.0),size-1.0)+0.5)/size).rgb;
}
float luma(vec3 c) { return c.b*0.5+(c.r*0.5+c.g); }
void direction(inout vec2 dir,inout float len,float w,
  float a,float b,float c,float d,float e) {
  float dx=d-b,dy=e-a;
  dir+=vec2(dx,dy)*w;
  float lx=clamp(abs(dx)/max(max(abs(d-c),abs(c-b)),1e-20),0.0,1.0);
  float ly=clamp(abs(dy)/max(max(abs(e-c),abs(c-a)),1e-20),0.0,1.0);
  len+=(lx*lx+ly*ly)*w;
}
void accumulate(inout vec3 colour,inout float weight,vec2 offset,
  vec2 dir,vec2 stretch,float lobe,float clipping,vec3 c) {
  vec2 v=vec2(dot(offset,dir),dot(offset,vec2(-dir.y,dir.x)))*stretch;
  float d2=min(dot(v,v),clipping);
  float b=0.4*d2-1.0,a=lobe*d2-1.0;
  float w=(1.5625*b*b-0.5625)*a*a;
  colour+=c*w;weight+=w;
}
void main() {
  vec2 pp=floor(uv*settings.inputOutput.zw)*settings.inputOutput.xy/settings.inputOutput.zw
    +0.5*settings.inputOutput.xy/settings.inputOutput.zw-0.5;
  vec2 fp=floor(pp);pp-=fp;
  vec3 b=tap(fp+vec2(0,-1)),c=tap(fp+vec2(1,-1));
  vec3 e=tap(fp+vec2(-1,0)),f=tap(fp),g=tap(fp+vec2(1,0)),h=tap(fp+vec2(2,0));
  vec3 i=tap(fp+vec2(-1,1)),j=tap(fp+vec2(0,1)),k=tap(fp+vec2(1,1)),l=tap(fp+vec2(2,1));
  vec3 n=tap(fp+vec2(0,2)),o=tap(fp+vec2(1,2));
  vec2 dir=vec2(0.0);float len=0.0;
  direction(dir,len,(1.0-pp.x)*(1.0-pp.y),luma(b),luma(e),luma(f),luma(g),luma(j));
  direction(dir,len,pp.x*(1.0-pp.y),luma(c),luma(f),luma(g),luma(h),luma(k));
  direction(dir,len,(1.0-pp.x)*pp.y,luma(f),luma(i),luma(j),luma(k),luma(n));
  direction(dir,len,pp.x*pp.y,luma(g),luma(j),luma(k),luma(l),luma(o));
  float norm=dot(dir,dir);
  dir=norm<1.0/32768.0?vec2(1.0,0.0):dir*inversesqrt(norm);
  len*=0.5;len*=len;
  float diagonal=dot(dir,dir)/max(abs(dir.x),abs(dir.y));
  vec2 stretch=vec2(1.0+(diagonal-1.0)*len,1.0-0.5*len);
  float lobe=0.5+(0.25-0.04-0.5)*len,clipping=1.0/lobe;
  vec3 sum=vec3(0.0);float weight=0.0;
  accumulate(sum,weight,vec2(0,-1)-pp,dir,stretch,lobe,clipping,b);
  accumulate(sum,weight,vec2(1,-1)-pp,dir,stretch,lobe,clipping,c);
  accumulate(sum,weight,vec2(-1,1)-pp,dir,stretch,lobe,clipping,i);
  accumulate(sum,weight,vec2(0,1)-pp,dir,stretch,lobe,clipping,j);
  accumulate(sum,weight,vec2(0,0)-pp,dir,stretch,lobe,clipping,f);
  accumulate(sum,weight,vec2(-1,0)-pp,dir,stretch,lobe,clipping,e);
  accumulate(sum,weight,vec2(1,1)-pp,dir,stretch,lobe,clipping,k);
  accumulate(sum,weight,vec2(2,1)-pp,dir,stretch,lobe,clipping,l);
  accumulate(sum,weight,vec2(2,0)-pp,dir,stretch,lobe,clipping,h);
  accumulate(sum,weight,vec2(1,0)-pp,dir,stretch,lobe,clipping,g);
  accumulate(sum,weight,vec2(1,2)-pp,dir,stretch,lobe,clipping,o);
  accumulate(sum,weight,vec2(0,2)-pp,dir,stretch,lobe,clipping,n);
  vec3 low=min(min(f,g),min(j,k)),high=max(max(f,g),max(j,k));
  fragment=vec4(clamp(sum/weight,low,high),1.0)*tint;
}
