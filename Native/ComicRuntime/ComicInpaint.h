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
                                 const unsigned char *source=nullptr, const unsigned char *approved_mask=nullptr) {
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
    if (approved_mask) for(int y=0;y<h;y++)for(int x=0;x<w;x++)expanded[y*w+x]=approved_mask[(top+y)*width+left+x]>0;
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
static inline float comic_mask_coverage(const unsigned char *rgba,const unsigned char *mask,int width,int height,int left,int top,int right,int bottom,const unsigned char *hints=nullptr){
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
        if(foreground&&(!hints||hints[y*width+x])){ink++;if(mask[y*width+x])covered++;}
    }
    return ink>=4?float(covered)/ink:0;
}

// Turn neural text hints into whole glyph components, including enclosed cores
// of outlined lettering. All coordinates and masks remain at source resolution.
static inline void comic_refine_text_mask(const unsigned char *rgba,const unsigned char *hints,unsigned char *mask,int width,int height,int left,int top,int right,int bottom){
    if(!rgba||!mask)return;
    left=std::max(1,left);top=std::max(1,top);right=std::min(width-1,right);bottom=std::min(height-1,bottom);
    int w=right-left,h=bottom-top;if(w<2||h<2||w*h>1000000)return;
    int histogram[256]={},hintCount=0;double sum=0;
    auto gray=[&](int x,int y){auto*p=rgba+(y*width+x)*4;return (int(p[0])*54+int(p[1])*183+int(p[2])*19)/256;};
    for(int y=top;y<bottom;y++)for(int x=left;x<right;x++){int v=gray(x,y);histogram[v]++;sum+=v;if(!hints||hints[y*width+x])hintCount++;}
    if(hintCount<std::max(4,w*h/500))return;
    double partial=0,best=-1;int weight=0,threshold=0,total=w*h;
    for(int i=0;i<255;i++){weight+=histogram[i];partial+=double(i)*histogram[i];if(!weight||weight==total)continue;double d=partial/weight-(sum-partial)/(total-weight),v=double(weight)*(total-weight)*d*d;if(v>best){best=v;threshold=i;}}
    if(best<=0)return;
    std::vector<int> border;for(int x=left;x<right;x++){border.push_back(gray(x,top-1));border.push_back(gray(x,bottom));}
    std::nth_element(border.begin(),border.begin()+border.size()/2,border.end());bool bright=border[border.size()/2]<=threshold;
    std::vector<unsigned char> foreground(w*h,0),seen(w*h,0),ink(w*h,0);
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){int v=gray(left+x,top+y);foreground[y*w+x]=bright?v>threshold:v<=threshold;}
    for(int i=0;i<w*h;i++)if(foreground[i]&&!seen[i]){
        std::vector<int> component(1,i);seen[i]=1;int minx=i%w,maxx=minx,miny=i/w,maxy=miny;bool edge=false;
        for(size_t head=0;head<component.size();head++){int p=component[head],x=p%w,y=p/w;minx=std::min(minx,x);maxx=std::max(maxx,x);miny=std::min(miny,y);maxy=std::max(maxy,y);edge=edge||x==0||y==0||x==w-1||y==h-1;
            for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++)if(x+dx>=0&&x+dx<w&&y+dy>=0&&y+dy<h){int next=(y+dy)*w+x+dx;if(foreground[next]&&!seen[next]){seen[next]=1;component.push_back(next);}}
        }
        if(edge||component.size()<2||(maxx-minx>w*.8f&&maxy-miny<2))continue;
        for(int p:component)ink[p]=1;
    }
    // Fill holes of outlined glyphs, then include antialiasing and drop shadows.
    std::vector<unsigned char> outside(w*h,0);std::vector<int> queue;
    for(int x=0;x<w;x++){queue.push_back(x);queue.push_back((h-1)*w+x);}for(int y=1;y<h-1;y++){queue.push_back(y*w);queue.push_back(y*w+w-1);}
    for(size_t head=0;head<queue.size();head++){int p=queue[head];if(outside[p]||ink[p])continue;outside[p]=1;int x=p%w,y=p/w;for(auto d: {-1,1}){if(x+d>=0&&x+d<w&&!outside[p+d])queue.push_back(p+d);if(y+d>=0&&y+d<h&&!outside[p+d*w])queue.push_back(p+d*w);}}
    int radius=std::clamp(h/12,2,6);
    for(int y=0;y<h;y++)for(int x=0;x<w;x++)if(ink[y*w+x]||!outside[y*w+x])for(int dy=-radius;dy<=radius;dy++)for(int dx=-radius;dx<=radius;dx++)if(x+dx>=0&&x+dx<w&&y+dy>=0&&y+dy<h)mask[(top+y+dy)*width+left+x+dx]=255;
}

// High-contrast structure remaining outside the glyph mask needs a restoration
// model; harmonic diffusion would smear panel artwork across the erased strokes.
static inline bool comic_simple_background(const unsigned char *rgba,const unsigned char *mask,int width,int height,int left,int top,int right,int bottom){
    if(!rgba||!mask)return false;left=std::max(1,left);top=std::max(1,top);right=std::min(width-1,right);bottom=std::min(height-1,bottom);
    int edges=0,samples=0;
    for(int y=top;y<bottom;y++)for(int x=left;x<right;x++)if(!mask[y*width+x]){
        int p=(y*width+x)*4;bool edge=false;
        for(auto delta:{1,width})if(!mask[y*width+x+delta]){int q=p+delta*4,d=0;for(int c=0;c<3;c++)d+=std::abs(int(rgba[p+c])-int(rgba[q+c]));edge=edge||d>60;}
        samples++;if(edge)edges++;
    }
    return samples>0&&edges<double(samples)*.003;
}

// Neural masks must cover the hint-supported ink and the OCR line's footprint.
// Requiring every dark artwork pixel in the box would reject correctly preserved
// panel lines; checking only a nonempty neural mask would accept half-erased words.
static inline bool comic_neural_mask_valid(const unsigned char *rgba,const unsigned char *hints,const unsigned char *mask,int width,int height,int left,int top,int right,int bottom){
    if(!rgba||!hints||!mask)return false;
    left=std::clamp(left,0,width-1);right=std::clamp(right,0,width);top=std::clamp(top,0,height-1);bottom=std::clamp(bottom,0,height);
    int w=right-left,h=bottom-top;if(w<2||h<2)return false;
    if(comic_mask_coverage(rgba,mask,width,height,left,top,right,bottom,hints)<.95f)return false;
    int count=0,minx=right,maxx=left,miny=bottom,maxy=top;
    for(int y=top;y<bottom;y++)for(int x=left;x<right;x++)if(mask[y*width+x]){count++;minx=std::min(minx,x);maxx=std::max(maxx,x);miny=std::min(miny,y);maxy=std::max(maxy,y);}
    if(count<std::max(4,w*h/50)||count>w*h*.98)return false;
    float sx=float(maxx-minx+1)/w,sy=float(maxy-miny+1)/h;
    return w>=h?(sx>=.8f&&sy>=.55f):(sy>=.8f&&sx>=.55f);
}

// Every text-like pixel in a closed balloon needs an OCR owner before lettering.
// This rejects a missing source line instead of translating over its remaining ink.
static inline bool comic_mask_owned(const unsigned char *evidence,int width,int height,int left,int top,int right,int bottom,const int *boxes,int count){
    if(!evidence||!boxes||width<=0||height<=0||count<=0)return false;
    left=std::clamp(left,0,width);right=std::clamp(right,0,width);top=std::clamp(top,0,height);bottom=std::clamp(bottom,0,height);
    int total=0,unowned=0;
    for(int y=top;y<bottom;y++)for(int x=left;x<right;x++)if(evidence[y*width+x]){
        total++;bool owner=false;
        for(int i=0;i<count;i++){const int *r=boxes+i*4;if(x>=r[0]&&y>=r[1]&&x<r[2]&&y<r[3]){owner=true;break;}}
        if(!owner)unowned++;
    }
    return unowned<=std::max(12,int(total*.05f));
}
