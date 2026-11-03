#include "../../../Native/ComicRuntime/ComicInpaint.h"
extern "C" void clean(unsigned char*p,int w,int h,int l,int t,int r,int b){comic_inpaint(p,w,h,l,t,r,b);}
extern "C" void text_mask(unsigned char*p,unsigned char*m,int w,int h,int l,int t,int r,int b){comic_inpaint(p,w,h,l,t,r,b,m,false);}
extern "C" void clean_source(unsigned char*s,unsigned char*p,int w,int h,int l,int t,int r,int b){comic_inpaint(p,w,h,l,t,r,b,nullptr,true,s);}
extern "C" float coverage(unsigned char*p,unsigned char*m,int w,int h,int l,int t,int r,int b){return comic_mask_coverage(p,m,w,h,l,t,r,b);}
extern "C" void refine(unsigned char*p,unsigned char*h,unsigned char*m,int w,int hh,int l,int t,int r,int b){comic_refine_text_mask(p,h,m,w,hh,l,t,r,b);}
extern "C" void refine_ocr(unsigned char*p,unsigned char*m,int w,int h,int l,int t,int r,int b){comic_refine_text_mask(p,nullptr,m,w,h,l,t,r,b);}
extern "C" void clean_mask(unsigned char*s,unsigned char*p,unsigned char*m,int w,int h,int l,int t,int r,int b){comic_inpaint(p,w,h,l,t,r,b,nullptr,true,s,m);}
extern "C" int simple_background(unsigned char*p,unsigned char*m,int w,int h,int l,int t,int r,int b){return comic_simple_background(p,m,w,h,l,t,r,b);}
