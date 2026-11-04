#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>
#include <utility>

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
    for(int y=top;y<bottom;y++){border.push_back(gray(left-1,y));border.push_back(gray(right,y));}
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
    // Pale glowing text can be brighter than its paper while its coloured halo
    // is darker. A single polarity threshold then joins the halo to the paper
    // and rejects the complete word as an edge component. Retain enclosed CTD
    // glyph components in that case; never accept an edge-connected hint/frame.
    if(hints){
        int supported=0,covered=0;
        for(int y=0;y<h;y++)for(int x=0;x<w;x++)if(hints[(top+y)*width+left+x]){supported++;if(ink[y*w+x])covered++;}
        if(supported>=4 && covered<supported*.8f){
            std::fill(seen.begin(),seen.end(),0);
            for(int i=0;i<w*h;i++)if(hints[(top+i/w)*width+left+i%w]&&!seen[i]){
                std::vector<int> component(1,i);seen[i]=1;bool edge=false;int minx=i%w,maxx=minx,miny=i/w,maxy=miny;
                for(size_t head=0;head<component.size();head++){
                    int q=component[head],x=q%w,y=q/w;edge=edge||x==0||y==0||x==w-1||y==h-1;
                    minx=std::min(minx,x);maxx=std::max(maxx,x);miny=std::min(miny,y);maxy=std::max(maxy,y);
                    for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++)if(x+dx>=0&&x+dx<w&&y+dy>=0&&y+dy<h){
                        int next=(y+dy)*w+x+dx;
                        if(!seen[next]&&hints[(top+y+dy)*width+left+x+dx]){seen[next]=1;component.push_back(next);}
                    }
                }
                if(edge||component.size()<2||component.size()>size_t(w*h*.9f)||(maxx-minx>w*.8f&&maxy-miny<2))continue;
                for(int q:component)ink[q]=1;
            }
        }
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
        for(auto delta:{1,width})if(!mask[y*width+x+delta]){int q=p+delta*4,d=0;for(int c=0;c<3;c++)d+=std::abs(int(rgba[p+c])-int(rgba[q+c]));edge=edge||d>24;}
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
    if(count<std::max(4,w*h/50))return false;
    if(count>w*h*.98f){
        // Condensed letters with a broad glow can merge after mask dilation.
        // A dense result is allowed only with independently structured CTD
        // evidence: a solid rectangle or a detected frame still fails.
        int supported=0,edge=0,hx0=right,hx1=left,hy0=bottom,hy1=top;
        for(int y=top;y<bottom;y++)for(int x=left;x<right;x++)if(hints[y*width+x]){
            supported++;edge+=x==left||x==right-1||y==top||y==bottom-1;
            hx0=std::min(hx0,x);hx1=std::max(hx1,x);hy0=std::min(hy0,y);hy1=std::max(hy1,y);
        }
        if(supported<w*h*.08f||supported>w*h*.8f||edge>supported*.25f)return false;
        float hx=float(hx1-hx0+1)/w,hy=float(hy1-hy0+1)/h;
        if(w>=h ? (hx<.8f||hy<.55f):(hy<.8f||hx<.55f))return false;
    }
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



// Opposing inward corners identify joined lobes even when their diagonal neck
// is too broad for erosion. A cut requires both geometric concavities and a full
// glyph-sized whitespace gap; ordinary cloud scallops or line spacing are insufficient.
static inline int comic_concave_cut(const std::vector<unsigned char>&mask,int w,int h,const int*boxes,int count,float glyph,int*owners,int*bounds){
    struct Point{int x,y;};std::vector<Point> edge;
    auto cross=[](Point a,Point b,Point c){return int64_t(b.x-a.x)*(c.y-a.y)-int64_t(b.y-a.y)*(c.x-a.x);};
    for(int y=1;y<h-1;y++)for(int x=1;x<w-1;x++)if(mask[y*w+x]&&(!mask[y*w+x-1]||!mask[y*w+x+1]||!mask[(y-1)*w+x]||!mask[(y+1)*w+x]))edge.push_back({x,y});
    if(edge.size()<8||edge.size()>20000)return 0;
    std::sort(edge.begin(),edge.end(),[](Point a,Point b){return a.x<b.x||(a.x==b.x&&a.y<b.y);});
    std::vector<Point> hull(edge.size()*2);int k=0;
    for(Point p:edge){while(k>=2&&cross(hull[k-2],hull[k-1],p)<=0)k--;hull[k++]=p;}
    int lower=k;for(int i=int(edge.size())-2;i>=0;i--){Point p=edge[i];while(k>lower&&cross(hull[k-2],hull[k-1],p)<=0)k--;hull[k++]=p;}hull.resize(k-1);if(hull.size()>256)return 0;
    struct Defect{Point p;float depth;};std::vector<Defect> defects;
    for(size_t i=0;i<hull.size();i++){
        Point a=hull[i],b=hull[(i+1)%hull.size()];float dx=b.x-a.x,dy=b.y-a.y,length=std::hypot(dx,dy);if(length<glyph)continue;
        float deepest=0;Point found=a;
        for(Point p:edge){float u=((p.x-a.x)*dx+(p.y-a.y)*dy)/(length*length);if(u<=0||u>=1)continue;
            float depth=float(cross(a,b,p))/length;
            // Only boundary visible from this hull edge belongs to its defect:
            // the segment from the edge to this pixel must lie outside the mask.
            if(depth<=deepest||depth<glyph*.45f)continue;
            float qx=a.x+u*dx,qy=a.y+u*dy;bool visible=true;
            for(int step=1;step<12;step++){float v=float(step)/12;int xx=int(qx+(p.x-qx)*v),yy=int(qy+(p.y-qy)*v);if(xx>=0&&xx<w&&yy>=0&&yy<h&&mask[yy*w+xx]){visible=false;break;}}
            if(visible){deepest=depth;found=p;}
        }
        if(deepest>=glyph*.45f)defects.push_back({found,deepest});
    }
    float best=0;Point ca{},cb{};
    for(size_t a=0;a<defects.size();a++)for(size_t b=a+1;b<defects.size();b++){
        Point p=defects[a].p,q=defects[b].p;float dx=q.x-p.x,dy=q.y-p.y,len=std::hypot(dx,dy);if(len<glyph||len>std::min(w,h)*1.5f)continue;
        float score=(defects[a].depth+defects[b].depth)/len;if(score<.4f||score<=best)continue;
        int inside=0;for(int t=1;t<20;t++){int x=int(p.x+dx*t/20),y=int(p.y+dy*t/20);inside+=mask[y*w+x]>0;}if(inside<17)continue;
        int sides[2]={0,0},regions[8]={w,h,0,0,w,h,0,0};
        for(int i=0;i<count;i++){
            const int*r=boxes+4*i;float lo=1e9f,hi=-1e9f;
            for(int x:{r[0],r[2]})for(int y:{r[1],r[3]}){float d=(dx*(y-p.y)-dy*(x-p.x))/len;lo=std::min(lo,d);hi=std::max(hi,d);}
            // Diagonal neck lines can intersect an OCR bounding corner while
            // a horizontal/vertical whitespace separator still clears every
            // word. Assign by centre; the full group bounds below must prove
            // that final, axis-aligned lettering cut before accepting it.
            int side=(lo+hi)<=0?0:1;sides[side]++;int*region=regions+side*4;for(int c=0;c<2;c++)region[c]=std::min(region[c],r[c]);for(int c=2;c<4;c++)region[c]=std::max(region[c],r[c]);
        }
        int gx=std::max(regions[0],regions[4])-std::min(regions[2],regions[6]),gy=std::max(regions[1],regions[5])-std::min(regions[3],regions[7]);
        if(sides[0]&&sides[1]&&std::max(gx,gy)>=glyph*.8f){best=score;ca=p;cb=q;}
    }
    if(!best)return 0;
    for(int i=0;i<2;i++){bounds[i*4]=w;bounds[i*4+1]=h;bounds[i*4+2]=bounds[i*4+3]=0;}
    auto side=[&](float x,float y){return (cb.x-ca.x)*(y-ca.y)-(cb.y-ca.y)*(x-ca.x)>0?1:0;};
    for(int i=0;i<count;i++)owners[i]=side((boxes[i*4]+boxes[i*4+2])*.5f,(boxes[i*4+1]+boxes[i*4+3])*.5f);
    for(int y=0;y<h;y++)for(int x=0;x<w;x++)if(mask[y*w+x]){int*r=bounds+side(x,y)*4;r[0]=std::min(r[0],x);r[1]=std::min(r[1],y);r[2]=std::max(r[2],x+1);r[3]=std::max(r[3],y+1);}
    // Convert diagonal ownership to nonoverlapping lettering rectangles wherever
    // an axis-aligned whitespace separator exists between the source groups.
    int text[8]={w,h,0,0,w,h,0,0};for(int i=0;i<count;i++){int*t=text+owners[i]*4;for(int c=0;c<2;c++)t[c]=std::min(t[c],boxes[i*4+c]);for(int c=2;c<4;c++)t[c]=std::max(t[c],boxes[i*4+c]);}
    int gx=std::max(text[0],text[4])-std::min(text[2],text[6]),gy=std::max(text[1],text[5])-std::min(text[3],text[7]);
    if(std::max(gx,gy)<glyph*.5f)return 0;
    int axis=gx>gy?0:1,first=text[axis]<text[4+axis]?0:1,second=1-first,cut=(text[first*4+axis+2]+text[second*4+axis])/2;
    bounds[first*4+axis+2]=std::min(bounds[first*4+axis+2],cut);bounds[second*4+axis]=std::max(bounds[second*4+axis],cut);return 2;
}
// Split a closed interior only at a narrow geometric neck. Text holes are filled
// before erosion, so the gaps between letters/rows never become bubble borders.
// Boxes and returned bounds use local top-left coordinates; owners are 0-based.
static inline int comic_balloon_lobes(const unsigned char *interior,int w,int h,
                                     const int *boxes,int count,int *owners,int *bounds){
    if(!interior||!boxes||!owners||!bounds||w<3||h<3||int64_t(w)*h>1000000||count<1||count>2000)return 0;
    const int n=w*h;std::fill(owners,owners+count,0);
    std::vector<unsigned char> outside(n,0),filled(n,0);std::vector<int> queue;
    auto enqueue=[&](int p){if(!interior[p]&&!outside[p]){outside[p]=1;queue.push_back(p);}};
    for(int x=0;x<w;x++){enqueue(x);enqueue((h-1)*w+x);}for(int y=1;y<h-1;y++){enqueue(y*w);enqueue(y*w+w-1);}
    for(size_t k=0;k<queue.size();k++){int p=queue[k],x=p%w,y=p/w;if(x)enqueue(p-1);if(x+1<w)enqueue(p+1);if(y)enqueue(p-w);if(y+1<h)enqueue(p+w);}
    std::vector<int> distance(n,0);int maximum=0;
    for(int p=0;p<n;p++){filled[p]=!outside[p];distance[p]=filled[p]?w+h:0;}
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){int p=y*w+x;if(filled[p])distance[p]=std::min({distance[p],x?distance[p-1]+1:1,y?distance[p-w]+1:1});}
    for(int y=h-1;y>=0;y--)for(int x=w-1;x>=0;x--){int p=y*w+x;if(filled[p]){distance[p]=std::min({distance[p],x+1<w?distance[p+1]+1:1,y+1<h?distance[p+w]+1:1});maximum=std::max(maximum,distance[p]);}}
    std::vector<int> heights;for(int i=0;i<count;i++)heights.push_back(std::min(boxes[i*4+2]-boxes[i*4],boxes[i*4+3]-boxes[i*4+1]));
    std::sort(heights.begin(),heights.end());float glyph=std::max(4,heights[count/2]);
    for(int threshold=std::max(3,int(glyph*.35f));threshold<=maximum*.55f;threshold+=std::max(2,int(glyph*.15f))){
        std::vector<int> labels(n,0),peaks(1,0),sizes(1,0);int components=0;
        for(int p=0;p<n;p++)if(distance[p]>=threshold&&!labels[p]){
            components++;peaks.push_back(0);sizes.push_back(0);queue.assign(1,p);labels[p]=components;
            for(size_t k=0;k<queue.size();k++){int q=queue[k],x=q%w,y=q/w;sizes.back()++;peaks.back()=std::max(peaks.back(),distance[q]);
                auto visit=[&](int r){if(distance[r]>=threshold&&!labels[r]){labels[r]=components;queue.push_back(r);}};
                if(x)visit(q-1);if(x+1<w)visit(q+1);if(y)visit(q-w);if(y+1<h)visit(q+w);
            }
        }
        if(components<2)continue;
        // Grow substantial cores through the original filled shape. Tiny tails
        // and scallops cannot acquire their own translation segment.
        queue.clear();for(int p=0;p<n;p++)if(labels[p]){int c=labels[p];if(sizes[c]>=glyph*glyph*.4f&&peaks[c]>=threshold*1.8f)queue.push_back(p);else labels[p]=0;}
        for(size_t k=0;k<queue.size();k++){int p=queue[k],x=p%w,y=p/w;
            auto visit=[&](int r){if(filled[r]&&!labels[r]){labels[r]=labels[p];queue.push_back(r);}};
            if(x)visit(p-1);if(x+1<w)visit(p+1);if(y)visit(p-w);if(y+1<h)visit(p+w);
        }
        std::vector<int> votes(components+1,0),assignment(count,0);
        for(int i=0;i<count;i++){
            const int*b=boxes+4*i;std::vector<int> hits(components+1,0);
            for(int y=std::max(0,b[1]);y<std::min(h,b[3]);y++)for(int x=std::max(0,b[0]);x<std::min(w,b[2]);x++)if(labels[y*w+x])hits[labels[y*w+x]]++;
            int owner=int(std::max_element(hits.begin(),hits.end())-hits.begin());assignment[i]=owner;if(owner)votes[owner]++;
        }
        int supported=0;for(int c=1;c<=components;c++)if(votes[c])supported++;
        if(supported<2||std::any_of(assignment.begin(),assignment.end(),[](int c){return !c;}))continue;
        // Every pair must have a whitespace cut between its source paragraphs.
        // Never cut through a recognized word, even when the shape is scalloped.
        std::vector<int> text((components+1)*4,0);for(int c=1;c<=components;c++){text[c*4]=w;text[c*4+1]=h;}
        for(int i=0;i<count;i++){int c=assignment[i];for(int a=0;a<2;a++)text[c*4+a]=std::min(text[c*4+a],boxes[i*4+a]);for(int a=2;a<4;a++)text[c*4+a]=std::max(text[c*4+a],boxes[i*4+a]);}
        bool separate=true;for(int a=1;a<=components;a++)if(votes[a])for(int b=a+1;b<=components;b++)if(votes[b]){
            int gx=std::max(text[a*4],text[b*4])-std::min(text[a*4+2],text[b*4+2]);
            int gy=std::max(text[a*4+1],text[b*4+1])-std::min(text[a*4+3],text[b*4+3]);
            if(std::max(gx,gy)<glyph*.5f)separate=false;
        }
        if(!separate)continue;
        std::vector<int> remap(components+1,-1);int result=0;for(int c=1;c<=components;c++)if(votes[c])remap[c]=result++;
        for(int i=0;i<count;i++)owners[i]=remap[assignment[i]];
        for(int c=0;c<result;c++){bounds[c*4]=w;bounds[c*4+1]=h;bounds[c*4+2]=bounds[c*4+3]=0;}
        for(int p=0;p<n;p++)if(labels[p]&&remap[labels[p]]>=0){int*c=bounds+4*remap[labels[p]],x=p%w,y=p/w;c[0]=std::min(c[0],x);c[1]=std::min(c[1],y);c[2]=std::max(c[2],x+1);c[3]=std::max(c[3],y+1);}
        // Clip overlapping lobe rectangles at a whitespace midpoint. This also
        // prevents a diagonal neighbour's cleanup/lettering entering this lobe.
        for(int a=1;a<=components;a++)if(votes[a])for(int b=a+1;b<=components;b++)if(votes[b]){
            int *ta=text.data()+a*4,*tb=text.data()+b*4,*ra=bounds+remap[a]*4,*rb=bounds+remap[b]*4;
            int gx=std::max(ta[0],tb[0])-std::min(ta[2],tb[2]),gy=std::max(ta[1],tb[1])-std::min(ta[3],tb[3]);
            int axis=gx>gy?0:1;if(ta[axis]>tb[axis]){std::swap(ta,tb);std::swap(ra,rb);}int cut=(ta[axis+2]+tb[axis])/2;
            ra[axis+2]=std::min(ra[axis+2],cut);rb[axis]=std::max(rb[axis],cut);
        }
        return result;
    }
    if(comic_concave_cut(filled,w,h,boxes,count,glyph,owners,bounds)==2)return 2;
    std::fill(owners,owners+count,0);bounds[0]=bounds[1]=0;bounds[2]=w;bounds[3]=h;return 1;
}


// Infer foreground and a surrounding stroke from untouched OCR crops. The
// enclosing colour transition, rather than merely a second histogram peak,
// distinguishes outlined letters from plain text on a contrasting background.
// output = fill RGB, outline RGB, CoreText stroke percentage; returns confidence.
static inline float comic_ink_style(const unsigned char *rgba,int w,int h,const int *boxes,int count,float *output){
    if(!rgba||!boxes||!output||w<3||h<3||int64_t(w)*h>1000000||count<1||count>2000)return 0;
    int hist[512]={},sums[512][3]={},edgeHist[512]={};
    std::vector<unsigned char> roi(w*h,0);std::vector<int> heights;
    auto key=[&](int p){return (rgba[p*4]/32)*64+(rgba[p*4+1]/32)*8+rgba[p*4+2]/32;};
    for(int i=0;i<count;i++){
        int l=std::clamp(boxes[i*4],1,w-2),t=std::clamp(boxes[i*4+1],1,h-2),r=std::clamp(boxes[i*4+2],l+1,w-1),b=std::clamp(boxes[i*4+3],t+1,h-1);heights.push_back(std::min(r-l,b-t));
        for(int y=t;y<b;y++)for(int x=l;x<r;x++)roi[y*w+x]=1;
        int pad=std::max(2,std::min(r-l,b-t)/6);
        for(int x=l;x<r;x++){edgeHist[key(std::max(0,t-pad)*w+x)]++;edgeHist[key(std::min(h-1,b+pad)*w+x)]++;}
        for(int y=t;y<b;y++){edgeHist[key(y*w+std::max(0,l-pad))]++;edgeHist[key(y*w+std::min(w-1,r+pad))]++;}
    }
    for(int p=0;p<w*h;p++)if(roi[p]){int k=key(p);hist[k]++;for(int c=0;c<3;c++)sums[k][c]+=rgba[p*4+c];}
    int bg=int(std::max_element(edgeHist,edgeHist+512)-edgeHist);
    auto center=[&](int k,int c)->float{if(hist[k])return float(sums[k][c])/hist[k];return (c==0?k/64:c==1?(k/8)%8:k%8)*32+16;};
    auto delta=[&](int a,int b){int d=0;for(int c=0;c<3;c++)d+=std::abs(center(a,c)-center(b,c));return d;};
    std::vector<int> palette;for(int k=0;k<512;k++)if(hist[k]>=8&&delta(k,bg)>=80)palette.push_back(k);
    std::sort(palette.begin(),palette.end(),[&](int a,int b){return hist[a]>hist[b];});if(palette.size()>8)palette.resize(8);
    if(palette.empty())return 0;
    std::sort(heights.begin(),heights.end());float glyph=std::max(4,heights[heights.size()/2]);
    int fill=palette[0],stroke=-1;float best=0,strokePercent=0;
    auto energy=[&](int k){return double(hist[k])*delta(k,bg)*delta(k,bg);};
    for(int k:palette)if(energy(k)>energy(fill))fill=k;
    int sampled=0;for(int k=0;k<512;k++)sampled+=hist[k];
    for(int a:palette)for(int b:palette)if(a!=b&&delta(a,b)>=160&&hist[b]<sampled*.7f){
        // Antialias pixels lie between the two solid inks. An intermediate
        // cluster cannot replace a stronger colour farther along the same ray.
        auto farther=[&](int start,int middle,int end){
            float dot=0,length=0;for(int c=0;c<3;c++){float u=center(middle,c)-center(start,c),v=center(end,c)-center(start,c);dot+=u*v;length+=u*u;}
            float factor=dot/std::max(1.f,length),error=0;
            for(int c=0;c<3;c++){float d=center(end,c)-center(start,c)-factor*(center(middle,c)-center(start,c));error+=d*d;}
            return factor>1.08f&&delta(end,start)>=delta(middle,start)+64&&error<1800;
        };
        bool antialias=false;for(int c:palette)if(c!=a&&c!=b){if(hist[c]>=hist[a]*.5f&&farther(b,a,c))antialias=true;if(hist[c]>=hist[b]*.5f&&farther(a,b,c))antialias=true;}
        if(antialias)continue;
        // A colour lying inside the fill-to-paper antialias ramp is not a
        // separate outline. Its apparent band changes with JPEG/raster sampling.
        float dot=0,length=0;for(int c=0;c<3;c++){float u=center(bg,c)-center(a,c),v=center(b,c)-center(a,c);dot+=u*v;length+=u*u;}
        float fraction=dot/std::max(1.f,length),rampError=0;
        for(int c=0;c<3;c++){float v=center(b,c)-center(a,c)-fraction*(center(bg,c)-center(a,c));rampError+=v*v;}
        if(fraction>.05f&&fraction<.95f&&rampError<2500)continue;
        int ab=0,otherA=0,otherB=0,cores=0;
        auto classify=[&](int p){
            int winner=bg,bestDistance=1000000;
            for(int candidate:{a,b,bg}){int d=0;for(int c=0;c<3;c++){int v=int(rgba[p*4+c])-center(candidate,c);d+=v*v;}if(d<bestDistance){bestDistance=d;winner=candidate;}}
            return winner;
        };
        for(int y=1;y<h-1;y++)for(int x=1;x<w-1;x++){int p=y*w+x;if(!roi[p])continue;int k=key(p);if(k!=a&&k!=b)continue;
            int same=0;
            for(int d:{-1,1,-w,w}){int q=classify(p+d);if(q==k){same++;continue;}
                // Cross the thin antialias ramp to the next solid ink. Classing
                // its middle grey as background would lose half every boundary.
                for(int step=2;step<=3&&q!=a&&q!=b;step++){
                    int next=p+d*step,nx=next%w,ny=next/w;
                    if(next<0||next>=w*h||std::abs(nx-x)>3||std::abs(ny-y)>3)break;
                    q=classify(next);
                }
                if(k==a){if(q==b)ab++;else if(q!=a)otherA++;}
                else if(q!=a&&q!=b)otherB++;
            }
            if(k==a&&same>=2)cores++;
        }
        float enclosure=float(ab)/std::max(1,ab+otherA),outer=float(otherB)/std::max(1,ab+otherB);
        float thickness=float(hist[b])/std::max(1,ab);
        if(ab<12||cores<8||enclosure<.75f||outer<.12f||thickness>glyph*.22f)continue;
        float score=enclosure+outer*.25f+.35f*std::sqrt(float(hist[a])/hist[palette[0]])+.1f*std::sqrt(float(hist[b])/hist[palette[0]]);
        if(score>best){best=score;fill=a;stroke=b;strokePercent=std::clamp(160.f*thickness/glyph,2.f,20.f);}
    }
    if(stroke<0&&delta(fill,bg)>=300){
        // White/black halos over halftone can share the dominant paper colour.
        // Large glyph components have a uniform near ring followed by texture;
        // plain lettering on flat paper has the same paper at every distance.
        std::vector<unsigned char> ink(w*h,0),seen(w*h,0);std::vector<int> queue;
        for(int p=0;p<w*h;p++)if(roi[p]&&key(p)==fill&&!seen[p]){
            queue.assign(1,p);seen[p]=1;
            for(size_t i=0;i<queue.size();i++){int q=queue[i],x=q%w,y=q/w;
                auto visit=[&](int r){if(roi[r]&&!seen[r]&&key(r)==fill){seen[r]=1;queue.push_back(r);}};
                if(x)visit(q-1);if(x+1<w)visit(q+1);if(y)visit(q-w);if(y+1<h)visit(q+w);
            }
            if(queue.size()>=std::max(5,int(glyph*glyph*.008f)))for(int q:queue)ink[q]=1;
        }
        int limit=std::clamp(int(glyph*.2f),4,12);std::vector<int> dist(w*h,limit+5);
        for(int p=0;p<w*h;p++)if(ink[p])dist[p]=0;
        for(int y=0;y<h;y++)for(int x=0;x<w;x++){int p=y*w+x;dist[p]=std::min({dist[p],x?dist[p-1]+1:limit+5,y?dist[p-w]+1:limit+5});}
        for(int y=h-1;y>=0;y--)for(int x=w-1;x>=0;x--){int p=y*w+x;dist[p]=std::min({dist[p],x+1<w?dist[p+1]+1:limit+5,y+1<h?dist[p+w]+1:limit+5});}
        std::vector<int> paper(limit+5,0),total(limit+5,0);
        for(int p=0;p<w*h;p++)if(dist[p]>0&&dist[p]<limit+5){int d=dist[p];total[d]++;if(delta(key(p),bg)<=96)paper[d]++;}
        float strongest=0;int radius=0;
        for(int r=1;r<=limit;r++){
            int near=0,nt=0,far=0,ft=0;for(int d=1;d<=r;d++){near+=paper[d];nt+=total[d];}for(int d=r+1;d<=r+3;d++){far+=paper[d];ft+=total[d];}
            float inner=float(near)/std::max(1,nt),outer=float(far)/std::max(1,ft),drop=inner-outer;
            if(nt>=20&&ft>=20&&inner>.65f&&drop>.2f&&drop>strongest){strongest=drop;radius=r;}
        }
        if(radius){stroke=bg;strokePercent=std::clamp(160.f*radius/glyph,2.f,20.f);}
    }
    double mass=0;for(int k:palette)mass+=energy(k);
    if((stroke<0&&energy(fill)<mass*.18)||hist[fill]<12)return 0;
    for(int c=0;c<3;c++){output[c]=float(sums[fill][c])/hist[fill];output[c+3]=stroke<0?0:hist[stroke] ? float(sums[stroke][c])/hist[stroke]:std::min(255.f,center(stroke,c));}
    output[6]=strokePercent;return stroke>=0?.95f:.7f;
}


// A closed, uniform balloon needs no image model. Its paper flood surrounds
// glyph-shaped holes. Fill those holes only after every one has an OCR owner;
// the exterior and balloon border can never enter this mask.
static inline bool comic_flat_balloon_mask(const unsigned char *paper,unsigned char *mask,int w,int h,int left,int top,int right,int bottom,const int *boxes,int count){
    if(!paper||!mask||!boxes||w<3||h<3||int64_t(w)*h>1000000||count<1||count>2000)return false;
    left=std::clamp(left,1,w-1);right=std::clamp(right,1,w-1);top=std::clamp(top,1,h-1);bottom=std::clamp(bottom,1,h-1);
    std::vector<unsigned char> outside(w*h,0),holes(w*h,0);std::vector<int> queue;
    auto enqueue=[&](int p){if(!paper[p]&&!outside[p]){outside[p]=1;queue.push_back(p);}};
    for(int x=0;x<w;x++){enqueue(x);enqueue((h-1)*w+x);}for(int y=1;y<h-1;y++){enqueue(y*w);enqueue(y*w+w-1);}
    for(size_t i=0;i<queue.size();i++){int p=queue[i],x=p%w,y=p/w;if(x)enqueue(p-1);if(x+1<w)enqueue(p+1);if(y)enqueue(p-w);if(y+1<h)enqueue(p+w);}
    // White letter outlines can touch a balloon through a one-pixel bridge.
    // Retain shape cores supported by this dialogue, excluding those attached
    // ornaments while keeping every missing line inside the actual balloon.
    std::vector<int> d(w*h,0);std::vector<int> glyphs;
    for(int i=0;i<count;i++)glyphs.push_back(std::min(boxes[i*4+2]-boxes[i*4],boxes[i*4+3]-boxes[i*4+1]));
    std::sort(glyphs.begin(),glyphs.end());int radius=std::clamp(glyphs[count/2]/5,3,12);
    for(int p=0;p<w*h;p++)d[p]=outside[p]?0:w+h;
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){int p=y*w+x;if(d[p])d[p]=std::min({d[p],x?d[p-1]+1:1,y?d[p-w]+1:1});}
    for(int y=h-1;y>=0;y--)for(int x=w-1;x>=0;x--){int p=y*w+x;if(d[p])d[p]=std::min({d[p],x+1<w?d[p+1]+1:1,y+1<h?d[p+w]+1:1});}
    std::vector<int> labels(w*h,0);int components=0;
    for(int p=0;p<w*h;p++)if(d[p]>=radius&&!labels[p]){
        components++;queue.assign(1,p);labels[p]=components;
        for(size_t k=0;k<queue.size();k++){int q=queue[k],x=q%w,y=q/w;auto visit=[&](int r){if(d[r]>=radius&&!labels[r]){labels[r]=components;queue.push_back(r);}};if(x)visit(q-1);if(x+1<w)visit(q+1);if(y)visit(q-w);if(y+1<h)visit(q+w);}
    }
    std::vector<unsigned char> keep(components+1,0);bool supported=false;
    for(int i=0;i<count;i++){int x=std::clamp((boxes[i*4]+boxes[i*4+2])/2,0,w-1),y=std::clamp((boxes[i*4+1]+boxes[i*4+3])/2,0,h-1),c=labels[y*w+x];if(c){keep[c]=1;supported=true;}}
    if(supported){
        for(int p=0;p<w*h;p++)d[p]=labels[p]&&keep[labels[p]]?0:w+h;
        for(int y=0;y<h;y++)for(int x=0;x<w;x++){int p=y*w+x;d[p]=std::min({d[p],x?d[p-1]+1:w+h,y?d[p-w]+1:w+h});}
        for(int y=h-1;y>=0;y--)for(int x=w-1;x>=0;x--){int p=y*w+x;d[p]=std::min({d[p],x+1<w?d[p+1]+1:w+h,y+1<h?d[p+w]+1:w+h});}
        for(int p=0;p<w*h;p++)if(d[p]>=radius)outside[p]=1;
    }
    int ink=0;for(int y=top;y<bottom;y++)for(int x=left;x<right;x++)if(!paper[y*w+x]&&!outside[y*w+x]){holes[y*w+x]=255;ink++;}
    if(ink<4||!comic_mask_owned(holes.data(),w,h,left,top,right,bottom,boxes,count))return false;
    for(int y=top;y<bottom;y++)for(int x=left;x<right;x++)if(holes[y*w+x])for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){
        int xx=x+dx,yy=y+dy;if(xx>=left&&xx<right&&yy>=top&&yy<bottom&&!outside[yy*w+xx])mask[yy*w+xx]=255;
    }
    return true;
}


// Largest axis-aligned lettering rectangle inside this lobe's actual paper.
// Glyph holes are filled first; a bounding rectangle alone can cross the frame
// of staggered joined balloons. Every source line centre must remain inside.
static inline bool comic_lettering_box(const unsigned char *paper,int w,int h,int left,int top,int right,int bottom,const int *boxes,int count,int *output){
    if(!paper||!boxes||!output||w<3||h<3||count<1||int64_t(w)*h>1000000)return false;
    left=std::clamp(left,1,w-1);right=std::clamp(right,1,w-1);top=std::clamp(top,1,h-1);bottom=std::clamp(bottom,1,h-1);
    if(right<=left||bottom<=top)return false;
    std::vector<unsigned char> outside(w*h,0);std::vector<int> queue;
    auto add=[&](int p){if(!paper[p]&&!outside[p]){outside[p]=1;queue.push_back(p);}};
    for(int x=0;x<w;x++){add(x);add((h-1)*w+x);}for(int y=1;y<h-1;y++){add(y*w);add(y*w+w-1);}
    for(size_t k=0;k<queue.size();k++){int p=queue[k],x=p%w,y=p/w;if(x)add(p-1);if(x+1<w)add(p+1);if(y)add(p-w);if(y+1<h)add(p+w);}
    std::vector<int> distance(w*h,0);for(int p=0;p<w*h;p++)distance[p]=outside[p]?0:w+h;
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){int p=y*w+x;if(distance[p])distance[p]=std::min({distance[p],x?distance[p-1]+1:1,y?distance[p-w]+1:1});}
    for(int y=h-1;y>=0;y--)for(int x=w-1;x>=0;x--){int p=y*w+x;if(distance[p])distance[p]=std::min({distance[p],x+1<w?distance[p+1]+1:1,y+1<h?distance[p+w]+1:1});}
    float minx=w,miny=h,maxx=0,maxy=0;
    for(int i=0;i<count;i++){float x=(boxes[i*4]+boxes[i*4+2])*.5f,y=(boxes[i*4+1]+boxes[i*4+3])*.5f;minx=std::min(minx,x);maxx=std::max(maxx,x);miny=std::min(miny,y);maxy=std::max(maxy,y);}
    int best=0;float bestDistance=1e20f;std::vector<int> heights(w,0);std::vector<std::pair<int,int>> stack;
    for(int y=top;y<bottom;y++){
        for(int x=left;x<right;x++)heights[x]=distance[y*w+x]>=3?heights[x]+1:0;
        stack.clear();
        for(int x=left;x<=right;x++){
            int value=x==right?0:heights[x],start=x;
            while(!stack.empty()&&stack.back().second>value){
                auto bar=stack.back();stack.pop_back();start=bar.first;int yy=y-bar.second+1,area=(x-bar.first)*bar.second;
                if(bar.first<=minx&&x>maxx&&yy<=miny&&y+1>maxy){float dx=(bar.first+x)*.5f-(minx+maxx)*.5f,dy=(yy+y+1)*.5f-(miny+maxy)*.5f,d=dx*dx+dy*dy;
                    if(area>best||(area==best&&d<bestDistance)){best=area;bestDistance=d;output[0]=bar.first;output[1]=yy;output[2]=x;output[3]=y+1;}
                }
            }
            if(value>0&&(stack.empty()||stack.back().second<value))stack.push_back({start,value});
        }
    }
    return best>=16;
}

// JPEG ringing belongs to text/frame edges, not the paper colour field.
// Sample beyond that narrow fringe, then use a robust channel median. A real
// gradient still fails the same strict colour spread test inside the paper.
static inline bool comic_plate_color(const unsigned char *rgba,int iw,int ih,const unsigned char *paper,int w,int h,int ox,int oy,unsigned char *color){
    if(!rgba||!paper||!color||w<3||h<3||int64_t(w)*h>1000000)return false;
    std::vector<int> distance(w*h,0);
    for(int p=0;p<w*h;p++)distance[p]=paper[p]?w+h:0;
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){int p=y*w+x;if(paper[p])distance[p]=std::min({distance[p],x?distance[p-1]+1:1,y?distance[p-w]+1:1});}
    for(int y=h-1;y>=0;y--)for(int x=w-1;x>=0;x--){int p=y*w+x;if(paper[p])distance[p]=std::min({distance[p],x+1<w?distance[p+1]+1:1,y+1<h?distance[p+w]+1:1});}
    int core=0;for(int p=0;p<w*h;p++)core+=distance[p]>=5;int minimum=core>=32?5:1;
    int histogram[3][256]={},total=0;
    for(int y=0;y<h;y++)for(int x=0;x<w;x++)if(distance[y*w+x]>=minimum&&x+ox>=0&&x+ox<iw&&y+oy>=0&&y+oy<ih){int p=((y+oy)*iw+x+ox)*4;for(int c=0;c<3;c++)histogram[c][rgba[p+c]]++;total++;}
    if(!total)return false;
    for(int c=0;c<3;c++){int sum=0;for(int v=0;v<256;v++){sum+=histogram[c][v];if(sum*2>=total){color[c]=v;break;}}}
    int matching=0;
    for(int y=0;y<h;y++)for(int x=0;x<w;x++)if(distance[y*w+x]>=minimum&&x+ox>=0&&x+ox<iw&&y+oy>=0&&y+oy<ih){int p=((y+oy)*iw+x+ox)*4,d=0;for(int c=0;c<3;c++)d+=std::abs(int(rgba[p+c])-int(color[c]));matching+=d<=6;}
    return matching>=total*.95f;
}

// A colour contour inside a gradient is not a balloon border. Filled interiors
// must meet an actual contrast edge in every outward direction, excluding glyph
// holes from the boundary vote.
static inline bool comic_plate_has_edge(const unsigned char *rgba,int imagew,int imageh,const unsigned char *paper,int w,int h,int ox,int oy,const int *boxes,int count){
    if(!rgba||!paper||w<3||h<3||int64_t(w)*h>1000000)return false;
    std::vector<unsigned char> outside(w*h,0);std::vector<int> queue;
    auto enqueue=[&](int p){if(!paper[p]&&!outside[p]){outside[p]=1;queue.push_back(p);}};
    for(int x=0;x<w;x++){enqueue(x);enqueue((h-1)*w+x);}for(int y=1;y<h-1;y++){enqueue(y*w);enqueue(y*w+w-1);}
    for(size_t i=0;i<queue.size();i++){int p=queue[i],x=p%w,y=p/w;if(x)enqueue(p-1);if(x+1<w)enqueue(p+1);if(y)enqueue(p-w);if(y+1<h)enqueue(p+w);}
    int samples[4]={},edges[4]={};int dx[4]={-1,1,0,0},dy[4]={0,0,-1,1};
    for(int y=1;y<h-1;y++)for(int x=1;x<w-1;x++)if(!outside[y*w+x])for(int d=0;d<4;d++)if(outside[(y+dy[d])*w+x+dx[d]]){
        bool text=false;for(int i=0;i<count;i++){const int*r=boxes+i*4;if(x+ox>=r[0]&&x+ox<r[2]&&y+oy>=r[1]&&y+oy<r[3]){text=true;break;}}if(text)continue;
        samples[d]++;int a=((y+oy)*imagew+x+ox)*4,xx=std::clamp(x+ox+dx[d]*2,0,imagew-1),yy=std::clamp(y+oy+dy[d]*2,0,imageh-1),b=(yy*imagew+xx)*4,difference=0;
        for(int c=0;c<3;c++)difference+=std::abs(int(rgba[a+c])-int(rgba[b+c]));if(difference>=60)edges[d]++;
    }
    int total=0,strong=0;for(int d=0;d<4;d++){if(samples[d]<4||edges[d]<samples[d]*.6f)return false;total+=samples[d];strong+=edges[d];}
    return strong>=total*.65f;
}

static inline void comic_grow_text_mask(unsigned char *mask,int w,int h,int left,int top,int right,int bottom,int radius){
    if(!mask||w<3||h<3||int64_t(w)*h>1000000)return;
    left=std::clamp(left,1,w-1);right=std::clamp(right,1,w-1);top=std::clamp(top,1,h-1);bottom=std::clamp(bottom,1,h-1);radius=std::clamp(radius,0,12);
    std::vector<unsigned char> original(mask,mask+w*h);
    for(int y=0;y<h;y++)for(int x=0;x<w;x++)if(x<left||x>=right||y<top||y>=bottom)mask[y*w+x]=0;
    for(int y=top;y<bottom;y++)for(int x=left;x<right;x++)if(original[y*w+x])for(int dy=-radius;dy<=radius;dy++)for(int dx=-radius;dx<=radius;dx++){
        int xx=x+dx,yy=y+dy;if(xx>=left&&xx<right&&yy>=top&&yy<bottom)mask[yy*w+xx]=255;
    }
}

// Detect a surviving glyph edge template after reconstruction. Background
// intensity alone is insufficient: black lettering can sit on dark artwork.
// Evaluate all foreground in the OCR bounds, including strokes missed by the
// proposed mask; the mask cannot certify its own omissions.
static inline float comic_ink_residue(const unsigned char *source,const unsigned char *clean,const unsigned char *mask,int w,int h,int left,int top,int right,int bottom){
    if(!source||!clean||!mask||w<3||h<3)return 1;
    left=std::clamp(left,1,w-1);right=std::clamp(right,1,w-1);top=std::clamp(top,1,h-1);bottom=std::clamp(bottom,1,h-1);
    int hist[256]={},total=0;double sum=0;
    auto gray=[&](int p){return (source[p*4]*54+source[p*4+1]*183+source[p*4+2]*19)/256;};
    for(int y=top;y<bottom;y++)for(int x=left;x<right;x++){int v=gray(y*w+x);hist[v]++;sum+=v;total++;}
    double partial=0,best=-1;int weight=0,threshold=0;
    for(int v=0;v<255;v++){weight+=hist[v];partial+=double(v)*hist[v];if(!weight||weight==total)continue;double d=partial/weight-(sum-partial)/(total-weight),score=double(weight)*(total-weight)*d*d;if(score>best){best=score;threshold=v;}}
    if(best<=0)return 0;
    std::vector<int> border;for(int x=left;x<right;x++){border.push_back(gray(std::max(0,top-3)*w+x));border.push_back(gray(std::min(h-1,bottom+2)*w+x));}
    for(int y=top;y<bottom;y++){border.push_back(gray(y*w+std::max(0,left-3)));border.push_back(gray(y*w+std::min(w-1,right+2)));}
    if(border.empty())return 1;std::nth_element(border.begin(),border.begin()+border.size()/2,border.end());bool bright=border[border.size()/2]<=threshold;
    // Artwork can legitimately retain its original edges inside padded OCR
    // bounds (for example a radial balloon frame beside a Japanese column).
    // Only enclosed foreground components supply glyph evidence. Expand the
    // window first so tight OCR boxes cannot turn a cropped glyph into a frame.
    int sx=std::max(0,left-3),sy=std::max(0,top-3),ex=std::min(w,right+3),ey=std::min(h,bottom+3),rw=ex-sx,rh=ey-sy;
    if(int64_t(rw)*rh>1000000)return 1;
    std::vector<unsigned char> foreground(rw*rh,0);std::vector<int> component;
    for(int y=0;y<rh;y++)for(int x=0;x<rw;x++){int v=gray((y+sy)*w+x+sx);foreground[y*rw+x]=(bright?v>threshold:v<=threshold)?1:0;}
    for(int i=0;i<rw*rh;i++)if(foreground[i]==1){
        component.assign(1,i);foreground[i]=3;bool boundary=false;
        for(size_t k=0;k<component.size();k++){int q=component[k],x=q%rw,y=q/rw;boundary=boundary||x==0||x==rw-1||y==0||y==rh-1;
            for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){int xx=x+dx,yy=y+dy;if(xx>=0&&xx<rw&&yy>=0&&yy<rh&&foreground[yy*rw+xx]==1){foreground[yy*rw+xx]=3;component.push_back(yy*rw+xx);}}
        }
        if(boundary)for(int q:component)foreground[q]=2;
    }
    int evidence=0,retained=0;
    for(int y=top;y<bottom;y++)for(int x=left;x<right;x++){
        int p=y*w+x;if(foreground[(y-sy)*rw+x-sx]!=3)continue;
        float strongest=0;int neighbour=-1;
        for(int dy:{-3,0,3})for(int dx:{-3,0,3})if(dx||dy){int xx=std::clamp(x+dx,0,w-1),yy=std::clamp(y+dy,0,h-1),q=yy*w+xx;float norm=0;for(int c=0;c<3;c++){float d=int(source[p*4+c])-int(source[q*4+c]);norm+=d*d;}if(norm>strongest){strongest=norm;neighbour=q;}}
        if(strongest<1800||neighbour<0)continue;
        evidence++;float dot=0,outputNorm=0;
        for(int c=0;c<3;c++){float a=int(source[p*4+c])-int(source[neighbour*4+c]),b=int(clean[p*4+c])-int(clean[neighbour*4+c]);dot+=a*b;outputNorm+=b*b;}
        if(dot>strongest*.22f&&dot*dot>=strongest*outputNorm*.64f)retained++;
    }
    return evidence>=8?float(retained)/evidence:1;
}
