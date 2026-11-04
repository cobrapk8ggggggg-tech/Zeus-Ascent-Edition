import argparse, html, json, pathlib, time, resource, random, math, hashlib
from functools import lru_cache
import cv2,numpy as np
from PIL import Image,ImageDraw,ImageFont
from engine import Engine
from balloons import paragraphs
FONT='/usr/share/fonts/truetype/noto/NotoNaskhArabic-Regular.ttf'
LATIN_FONT='/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf'
FALLBACK_FONT='/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
@lru_cache(maxsize=4096)
def supported_glyph(path,char):
    font=coverage_font(path);missing=font.getmask(chr(0x10FFFF));glyph=font.getmask(char)
    return glyph.size!=missing.size or bytes(glyph)!=bytes(missing)
@lru_cache(maxsize=3)
def coverage_font(path):return ImageFont.truetype(path,16)
def font_path(text,direction):
    preferred=LATIN_FONT if direction=='ltr'else FONT
    for path in [preferred,FALLBACK_FONT]:
        if all(char.isspace()or supported_glyph(path,char)for char in set(text)):return path
    return None



def lettering(rgb,box,text,size,color,direction="rtl",vertical=False,ink_style=None):
    if vertical:
        x,y,r,b=[int(round(v))for v in box];x=max(0,x);y=max(0,y);r=min(rgb.shape[1],r);b=min(rgb.shape[0],b)
        if r-x<3 or b-y<3:return rgb,False
        cut=np.ascontiguousarray(np.rot90(rgb[y:b,x:r]));drawn,fit=lettering(cut,[0,0,cut.shape[1],cut.shape[0]],text,size,color,direction,ink_style=ink_style)
        result=rgb.copy()
        if fit:result[y:b,x:r]=np.rot90(drawn,-1)
        return result,fit
    selected=font_path(text,direction)
    if selected is None:return rgb,False
    image=Image.fromarray(rgb);draw=ImageDraw.Draw(image);x,y,r,b=box
    minimum=max(5,int(size*.55))
    for size in range(max(5,int(size)),minimum-1,-1):
        font=ImageFont.truetype(selected,size);words=text.split();rows=[];row=''
        for word in words:
            test=(row+' '+word).strip()
            if draw.textlength(test,font=font,direction=direction)<=r-x-4:row=test
            else:
                if row:rows.append(row)
                row=word
        if row:rows.append(row)
        lineheight=max(1,max(font.getbbox(row,direction=direction)[3]-font.getbbox(row,direction=direction)[1]for row in rows)+int(size*.2))
        if len(rows)*lineheight<=b-y and all(draw.textlength(row,font=font,direction=direction)<=r-x-4 for row in rows):break
    else:return rgb,False
    top=y+(b-y-len(rows)*lineheight)/2
    stroke=ink_style.get('stroke')if ink_style else None
    if ink_style and ink_style['confidence']>=.65:color=tuple(round(v)for v in ink_style['fill'])
    sw=max(1,round(size*ink_style['stroke_percent']/200))if stroke is not None else 0
    for i,row in enumerate(rows):draw.text(((x+r)/2,top+i*lineheight),row,font=font,fill=tuple(color),direction=direction,anchor='mt',stroke_width=sw,stroke_fill=tuple(round(v)for v in stroke)if stroke is not None else None)
    return np.asarray(image),True

def gallery(out,cases):
    rows=[]
    for c in cases:
        images=''.join(f'<figure><figcaption>{name}</figcaption><img loading="lazy" src="{c["id"]}/{name}.png"></figure>' for name in ['original','mask','clean','rendered']+(['lama']if(out/c['id']/'lama.png').exists()else[]))
        rows.append(f'<article id="{c["id"]}"><h2>{c["id"]}</h2><p>{html.escape(" / ".join(c["ocr"]))}</p><div class="stages">{images}</div><label>Review <select data-id="{c["id"]}"><option>unreviewed</option><option>pass</option><option>mask failure</option><option>cleanup failure</option><option>layout failure</option><option>missed text</option></select></label><input data-note="{c["id"]}" placeholder="review notes"></article>')
    review='''<script>function save(){const reviews=[...document.querySelectorAll('select[data-id]')].map(e=>({id:e.dataset.id,verdict:e.value,note:document.querySelector('[data-note="'+e.dataset.id+'"]').value}));const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(reviews,null,2)],{type:'application/json'}));a.download='reviews.json';a.click();}</script>'''
    (out/'index.html').write_text('<meta charset="utf-8"><title>Zeus comic quality lab</title><style>body{background:#181a20;color:#eee;font:16px sans-serif}article{padding:16px;border-bottom:1px solid #777}.stages{display:flex;flex-wrap:wrap;gap:10px}figure{margin:0}img{max-width:420px;max-height:440px;object-fit:contain;image-rendering:auto}select,input,button{font:inherit;padding:10px}</style><h1>Real comic quality lab</h1><p>Fixed Arabic text tests layout only. Unreviewed proposals are not ground truth.</p><button onclick="save()">Export reviews</button>'+''.join(rows)+review)
def run(args):
    root=pathlib.Path(args.corpus);out=pathlib.Path(args.output);out.mkdir(parents=True,exist_ok=True)
    engine=Engine(args.models);corpus=json.loads((root/'corpus.json').read_text());cases=[];stages=[]
    files=[pathlib.Path(__file__),pathlib.Path(__file__).with_name('engine.py'),pathlib.Path(__file__).with_name('balloons.py'),pathlib.Path(__file__).with_name('run_geometry.py')]
    identity=dict(pipeline_sha256=hashlib.sha256(b''.join(p.read_bytes()for p in files)+engine.native_sha.encode()).hexdigest(),corpus_sha256=hashlib.sha256((root/'corpus.json').read_bytes()).hexdigest(),settings=dict(regions=args.regions,ocr=args.ocr,neural=args.neural,lama=args.lama))
    progress=out/'quality-run.json';completed=[]
    if args.resume and progress.exists():
        previous=json.loads(progress.read_text())
        if any(previous.get(k)!=v for k,v in identity.items()):raise ValueError('Resume source, corpus or settings changed; use a new output directory')
        completed=previous.get('completed_chapters',[])
        if(out/'cases.json').exists():cases=[c for c in json.loads((out/'cases.json').read_text())if c['chapter']in completed]
    def checkpoint():
        temporary=out/'cases.json.tmp';temporary.write_text(json.dumps(cases,ensure_ascii=False,indent=2));temporary.replace(out/'cases.json')
        temporary=out/'quality-run.json.tmp';temporary.write_text(json.dumps(dict(identity,completed_chapters=completed),indent=2));temporary.replace(progress)
    checkpoint()
    for chapter in corpus['chapters']:
        if chapter['id']in completed:print('Resuming after completed chapter',chapter['id'],flush=True);continue
        limit=args.regions//len(corpus['chapters']);count=0
        pages=list(chapter['pages']);random.Random(0).shuffle(pages)
        per_page=math.ceil(limit/len(pages))+2
        for page in pages:
            if count>=limit:break
            rgb=np.asarray(Image.open(root/page['path']).convert('RGB'));start=time.perf_counter();lines=engine.detect(rgb)
            groups=paragraphs(rgb,lines,include_layout=True,engine=engine,include_cleanup=True,include_bounds=True,include_inside=True);random.Random(0).shuffle(groups)
            for paragraph,area,closed,flat,physical,inside in groups[:per_page]:
                if count>=limit:break
                boxes=[l['box'] for l in paragraph];x=min(b[0]for b in boxes);y=min(b[1]for b in boxes);r=max(b[2]for b in boxes);b=max(b[3]for b in boxes)
                if r-x<15 or b-y<10 or (r-x)*(b-y)>750000:continue
                context=physical if physical is not None else area
                pad=24;cx=max(0,min(x,context[0])-pad);cy=max(0,min(y,context[1])-pad);cr=min(rgb.shape[1],max(r,context[2])+pad);cb=min(rgb.shape[0],max(b,context[3])+pad)
                crop=np.ascontiguousarray(rgb[cy:cb,cx:cr]);local=[[a-cx,c-cy,d-cx,e-cy] for a,c,d,e in boxes]
                recognized=[];confidence=[]
                if args.ocr:
                    info=[engine.recognize_info(crop,box,chapter['language'])for box in local]
                    recognized=[t for t,c in info];confidence=[c for t,c in info]
                readable=all(t.strip() and c>=.65 for t,c in zip(recognized,confidence))if args.ocr else True
                text=('This is a translated paragraph.' if len(paragraph)>1 else 'Translation') if chapter['language']=='ar' else ('هذه ترجمة عربية تجريبية داخل الفقاعة' if len(paragraph)>1 else 'ترجمة تجريبية')
                source_style=engine.ink_style(crop,local)
                fg=(12,12,12) if np.median(crop)>128 else (248,248,248)
                vertical=not closed and all(q[3]-q[1]>(q[2]-q[0])*1.5 for q in local)
                area_local=[area[0]-cx,area[1]-cy,area[2]-cx,area[3]-cy]
                physical_local=None if physical is None else[physical[0]-cx,physical[1]-cy,physical[2]-cx,physical[3]-cy]
                columnar=vertical and any(0x3040<=ord(ch)<=0x30ff or 0x3400<=ord(ch)<=0x9fff or 0xac00<=ord(ch)<=0xd7af for ch in ''.join(recognized))
                if columnar:
                    upright=[x-cx,y-cy,r-cx,b-cy]
                    _,fits=lettering(crop,upright,text,np.median([l['glyph_height']for l in paragraph])*1.3,fg,direction='ltr' if chapter['language']=='ar' else 'rtl',ink_style=source_style)
                    if fits:vertical=False;area_local=upright
                _,fit=lettering(crop,area_local,text,np.median([l['glyph_height']for l in paragraph])*1.3,fg,direction='ltr' if chapter['language']=='ar' else 'rtl',vertical=vertical,ink_style=source_style)
                accepted=False;route='original';clean=crop.copy();mask=np.zeros(crop.shape[:2],np.uint8)
                if fit and readable:
                    if flat is not None:clean,mask,accepted=engine.apply_flat_cleanup(crop,[cx,cy],flat)
                    else:clean,mask=engine.clean(crop,local);accepted=engine.can_letter_light(crop,mask,local,physical_local if closed else None)
                    if accepted and engine.ink_residue(crop,clean,mask,local)>.08:accepted=False
                    if accepted:route='flat'if flat is not None and flat['uniform']else'light'
                    elif args.neural:
                        clean,mask,accepted=engine.restore_neural(crop,local,physical_local if closed else None,lettering_inside=area_local if inside else None)
                        if accepted:route='neural'
                if not accepted:clean=crop.copy()
                rendered=clean
                if accepted:rendered,_=lettering(clean,area_local,text,np.median([l['glyph_height']for l in paragraph])*1.3,fg,direction='ltr' if chapter['language']=='ar' else 'rtl',vertical=vertical,ink_style=source_style)
                outside=int(np.count_nonzero(np.any(clean!=crop,axis=2)&(mask==0)))
                cid=f'{chapter["language"]}-{chapter["id"][:8]}-{chapter["split"]}-{count:03d}';dest=out/cid;dest.mkdir(exist_ok=True)
                for name,a in [('original',crop),('mask',mask),('clean',clean),('rendered',rendered)]:Image.fromarray(a).save(dest/(name+'.png'))
                case=dict(id=cid,language=chapter['language'],split=chapter['split'],chapter=chapter['id'],source=page['path'],source_sha256=page['sha256'],box=[cx,cy,cr,cb],layout_box=area_local,balloon_bounds=physical_local,lettering_inside_balloon=inside,lines=paragraph,balloon=closed,vertical_caption=vertical,ocr=recognized,ocr_confidence=confidence,source_readable=readable,outside_mask_changes=outside,fit=fit,restoration_route=route,cleanup_accepted=accepted,source_ink_style=source_style,annotation_status='unreviewed',translation='fixed Arabic layout probe',seconds=time.perf_counter()-start)
                cases.append(case);count+=1;start=time.perf_counter()
                if args.lama and count<=args.lama:
                    restored=engine.lama(crop,mask);Image.fromarray(restored).save(dest/'lama.png')
                    case['lama_outside_mask_changes']=int(np.count_nonzero(np.any(restored!=crop,axis=2)&(mask==0)))
            print(chapter['language'],chapter['split'],page['path'],'regions',count,flush=True)
        completed.append(chapter['id']);checkpoint()
    gallery(out,cases)
    report=dict(chapters=len(corpus['chapters']),pages=sum(len(c['pages'])for c in corpus['chapters']),regions=len(cases),languages=sorted(set(c['language']for c in cases)),outside_mask_changes=sum(c['outside_mask_changes']for c in cases),layout_probe_fits=sum(c['fit']for c in cases),neural_restored=sum(c['restoration_route']=='neural'for c in cases),light_restored=sum(c['restoration_route']in['flat','light']for c in cases),flat_restored=sum(c['restoration_route']=='flat'for c in cases),cleanup_gate_accepted=sum(c['cleanup_accepted']for c in cases),cleanup_gate_abstained=sum(not c['cleanup_accepted']for c in cases),manually_reviewed=0,quality_acceptance_proven=False,native_kernel_sha256=engine.native_sha,protocol='adaptive-v13: bounded source-line neural masks; near-frame ownership; inscribed lettering; upright CJK; post-clean glyph gate',peak_rss_kib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    (out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report),flush=True)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--corpus',required=True);p.add_argument('--models',required=True);p.add_argument('--output',required=True);p.add_argument('--regions',type=int,default=400);p.add_argument('--ocr',action='store_true');p.add_argument('--lama',type=int,default=0);p.add_argument('--neural',action='store_true');p.add_argument('--resume',action='store_true');run(p.parse_args())
