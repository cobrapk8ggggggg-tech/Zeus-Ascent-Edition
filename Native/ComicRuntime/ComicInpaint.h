#pragma once
#include <algorithm>
#include <cmath>
#include <vector>

// A bounded, CPU-only text mask. The surrounding colour field seeds a harmonic
// reconstruction; unlike a solid fill this retains local gradients. Coordinates
// and the output buffer use the source image's top-left pixel convention.
static inline void comic_inpaint(unsigned char *rgba, int width, int height,
                                 int left, int top, int right, int bottom) {
    left=std::max(1,left); top=std::max(1,top);
    right=std::min(width-1,right); bottom=std::min(height-1,bottom);
    if (!rgba || right<=left || bottom<=top) return;
    const int w=right-left, h=bottom-top, n=w*h;
    if (n>1000000) return;
    std::vector<float> field(n*3);
    std::vector<unsigned char> mask(n,0), expanded(n,0);
    auto sample=[&](int x,int y,int c) { return float(rgba[(y*width+x)*4+c]); };
    // Median samples reject isolated antialiased dots in the surrounding ring.
    auto edge=[&](int x,int y,int c,bool horizontal) {
        float values[5];
        for(int k=-2;k<=2;k++) values[k+2]=sample(std::clamp(x+(horizontal?k:0),0,width-1),std::clamp(y+(horizontal?0:k),0,height-1),c);
        std::sort(values,values+5); return values[2];
    };
    for(int y=0;y<h;y++) for(int x=0;x<w;x++) {
        const float u=float(x+1)/(w+1),v=float(y+1)/(h+1);
        float difference=0;
        for(int c=0;c<3;c++) {
            const float a=edge(left+x,top-1,c,true),b=edge(left+x,bottom,c,true);
            const float l=edge(left-1,top+y,c,false),r=edge(right,top+y,c,false);
            const float vertical=a*(1-v)+b*v, horizontal=l*(1-u)+r*u;
            // Prefer the nearest edges: narrow text rows recover from above/below.
            const float wy=1.f/float(h*h),wx=1.f/float(w*w);
            const float value=(vertical*wy+horizontal*wx)/(wy+wx);
            field[(y*w+x)*3+c]=value;
            difference+=std::abs(sample(left+x,top+y,c)-value);
        }
        mask[y*w+x]=difference>24;
    }
    const int radius=std::clamp(h/14,2,5);
    for(int y=0;y<h;y++) for(int x=0;x<w;x++) if(mask[y*w+x])
        for(int dy=-radius;dy<=radius;dy++) for(int dx=-radius;dx<=radius;dx++)
            if(x+dx>=0&&x+dx<w&&y+dy>=0&&y+dy<h) expanded[(y+dy)*w+x+dx]=1;
    std::vector<float> values(n*3);
    for(int y=0;y<h;y++) for(int x=0;x<w;x++) for(int c=0;c<3;c++)
        values[(y*w+x)*3+c]=expanded[y*w+x]?field[(y*w+x)*3+c]:sample(left+x,top+y,c);
    // Red/black Gauss-Seidel converges through thin glyph masks without pulling
    // the old glyph colour back into the result. Boundary pixels never change.
    for(int iteration=0;iteration<100;iteration++) for(int parity=0;parity<2;parity++)
        for(int y=0;y<h;y++) for(int x=(y+parity)&1;x<w;x+=2) if(expanded[y*w+x])
            for(int c=0;c<3;c++) {
                const float l=x?values[(y*w+x-1)*3+c]:sample(left-1,top+y,c);
                const float r=x+1<w?values[(y*w+x+1)*3+c]:sample(right,top+y,c);
                const float a=y?values[((y-1)*w+x)*3+c]:sample(left+x,top-1,c);
                const float b=y+1<h?values[((y+1)*w+x)*3+c]:sample(left+x,bottom,c);
                values[(y*w+x)*3+c]=(l+r+a+b)*.25f;
            }
    for(int y=0;y<h;y++) for(int x=0;x<w;x++) if(expanded[y*w+x]) for(int c=0;c<3;c++)
        rgba[((top+y)*width+left+x)*4+c]=std::clamp(int(std::lround(values[(y*w+x)*3+c])),0,255);
}
