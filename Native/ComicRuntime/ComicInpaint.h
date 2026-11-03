#pragma once
#include <algorithm>
#include <cmath>
#include <vector>

// A bounded, CPU-only text mask. The surrounding colour field seeds a harmonic
// reconstruction; unlike a solid fill this retains local gradients. Coordinates
// and the output buffer use the source image's top-left pixel convention.
static inline void comic_inpaint(unsigned char *rgba, int width, int height,
                                 int left, int top, int right, int bottom,
                                 unsigned char *output_mask=nullptr, bool restore=true,
                                 const unsigned char *source=nullptr) {
    left=std::max(1,left); top=std::max(1,top);
    right=std::min(width-1,right); bottom=std::min(height-1,bottom);
    if (!rgba || right<=left || bottom<=top) return;
    const int w=right-left, h=bottom-top, n=w*h;
    if (n>1000000) return;
    std::vector<float> field(n*3);
    std::vector<unsigned char> mask(n,0), expanded(n,0);
    if (!source) source=rgba;
    auto sample=[&](int x,int y,int c) { return float(source[(y*width+x)*4+c]); };
    // Median samples reject isolated antialiased dots in the surrounding ring.
    auto edge=[&](int x,int y,int c,bool horizontal) {
        float values[5];
        for(int k=-2;k<=2;k++) values[k+2]=sample(std::clamp(x+(horizontal?k:0),0,width-1),std::clamp(y+(horizontal?0:k),0,height-1),c);
        std::sort(values,values+5); return values[2];
    };
    // A robust dominant perimeter colour prevents a neighbouring glyph or a
    // balloon edge contaminating a whole reconstructed column on flat balloons.
    int bins[512]={0},sums[512][3]={}; int ring=0;
    auto add=[&](int x,int y) {
        int rr=int(sample(x,y,0)),gg=int(sample(x,y,1)),bb=int(sample(x,y,2));
        int key=(rr/32)*64+(gg/32)*8+bb/32;bins[key]++;
        sums[key][0]+=rr;sums[key][1]+=gg;sums[key][2]+=bb;ring++;
    };
    for(int x=left-1;x<=right;x++){add(x,top-1);add(x,bottom);}
    for(int y=top;y<bottom;y++){add(left-1,y);add(right,y);}
    int dominant=int(std::max_element(bins,bins+512)-bins);float bg[3];
    for(int c=0;c<3;c++)bg[c]=float(sums[dominant][c])/std::max(1,bins[dominant]);
    bool flat=bins[dominant]>ring*.75f;
    for(int y=0;y<h;y++) for(int x=0;x<w;x++) {
        const float u=float(x+1)/(w+1),v=float(y+1)/(h+1);
        float difference=0;
        for(int c=0;c<3;c++) {
            const float a=edge(left+x,top-1,c,true),b=edge(left+x,bottom,c,true);
            const float l=edge(left-1,top+y,c,false),r=edge(right,top+y,c,false);
            const float vertical=a*(1-v)+b*v, horizontal=l*(1-u)+r*u;
            // Prefer the nearest edges: narrow text rows recover from above/below.
            const float wy=1.f/(float(h)*h),wx=1.f/(float(w)*w);
            const float value=flat?bg[c]:(vertical*wy+horizontal*wx)/(wy+wx);
            field[(y*w+x)*3+c]=value;
            difference+=std::abs(sample(left+x,top+y,c)-value);
        }
        mask[y*w+x]=difference>24;
    }
    // Components crossing the protected ROI edge are usually panel/balloon
    // borders or artwork. Source text has an explicit safety margin around it.
    std::vector<unsigned char> seen(n,0);
    for(int i=0;i<n;i++) if(mask[i]&&!seen[i]) {
        std::vector<int> component(1,i);seen[i]=1;bool touches=false;
        for(size_t head=0;head<component.size();head++) {
            int index=component[head],x=index%w,y=index/w;
            touches=touches||x==0||y==0||x==w-1||y==h-1;
            for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++)if(x+dx>=0&&x+dx<w&&y+dy>=0&&y+dy<h){
                int next=(y+dy)*w+x+dx;
                if(mask[next]&&!seen[next]){seen[next]=1;component.push_back(next);}
            }
        }
        if(touches)for(int index:component)mask[index]=0;
    }
    const int radius=std::clamp(h/14,2,5);
    for(int y=0;y<h;y++) for(int x=0;x<w;x++) if(mask[y*w+x])
        for(int dy=-radius;dy<=radius;dy++) for(int dx=-radius;dx<=radius;dx++)
            if(x+dx>=0&&x+dx<w&&y+dy>=0&&y+dy<h) expanded[(y+dy)*w+x+dx]=1;
    if (output_mask) for(int y=0;y<h;y++) for(int x=0;x<w;x++)
        if(expanded[y*w+x]) output_mask[(top+y)*width+left+x]=255;
    if (!restore) return;
    std::vector<float> values(n*3);
    for(int y=0;y<h;y++) for(int x=0;x<w;x++) for(int c=0;c<3;c++)
        values[(y*w+x)*3+c]=expanded[y*w+x]?field[(y*w+x)*3+c]:sample(left+x,top+y,c);
    // Red/black Gauss-Seidel converges through thin glyph masks without pulling
    // the old glyph colour back into the result. Boundary pixels never change.
    for(int iteration=0;iteration<(flat?0:100);iteration++) for(int parity=0;parity<2;parity++)
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

// Coverage of the actual high-contrast ink inside a tight OCR line. A renderer
// may decline to letter an incompletely erased line instead of overlapping it.
static inline float comic_mask_coverage(const unsigned char *rgba,const unsigned char *mask,int width,int height,int left,int top,int right,int bottom){
    if(!rgba||!mask||width<=0||height<=0)return 0;
    left=std::clamp(left,0,width-1);right=std::clamp(right,0,width);
    top=std::clamp(top,0,height-1);bottom=std::clamp(bottom,0,height);
    if(right<=left||bottom<=top)return 0;
    int histogram[256]={},border[256]={};int total=0,edgeCount=0;
    auto gray=[&](int x,int y){const auto*p=rgba+(y*width+x)*4;return (int(p[0])*54+int(p[1])*183+int(p[2])*19)/256;};
    for(int y=top;y<bottom;y++)for(int x=left;x<right;x++){
        int v=gray(x,y);histogram[v]++;total++;
    }
    // Tight OCR rectangles often touch ink on all four sides. Estimate paper
    // polarity outside the line, not from the glyph-bearing rectangle edge.
    auto edge=[&](int x,int y){int v=gray(std::clamp(x,0,width-1),std::clamp(y,0,height-1));border[v]++;edgeCount++;};
    for(int x=left;x<right;x++){edge(x,top-3);edge(x,bottom+2);}
    for(int y=top;y<bottom;y++){edge(left-3,y);edge(right+2,y);}
    double sum=0;for(int i=0;i<256;i++)sum+=double(i)*histogram[i];
    int weight=0,threshold=0;double partial=0,best=-1;
    for(int i=0;i<255;i++){
        weight+=histogram[i];partial+=double(i)*histogram[i];if(!weight||weight==total)continue;
        double d=partial/weight-(sum-partial)/(total-weight),variance=double(weight)*(total-weight)*d*d;
        if(variance>best){best=variance;threshold=i;}
    }
    if(best<=0)return 0;
    int middle=0,accum=0;for(;middle<255;middle++){accum+=border[middle];if(accum>=edgeCount/2)break;}
    bool bright=middle<=threshold;int ink=0,covered=0;
    for(int y=top;y<bottom;y++)for(int x=left;x<right;x++){
        int v=gray(x,y);bool foreground=bright?v>threshold:v<=threshold;
        if(foreground){ink++;if(mask[y*width+x])covered++;}
    }
    return ink>=4?float(covered)/ink:0;
}
