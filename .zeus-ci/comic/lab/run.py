import argparse, html, json, pathlib, time, resource, random, math
import cv2,numpy as np
from PIL import Image,ImageDraw,ImageFont
from engine import Engine
from balloons import paragraphs
FONT='/usr/share/fonts/truetype/noto/NotoNaskhArabic-Regular.ttf'


def lettering(rgb,box,text,size,color,direction="rtl"):
    image=Image.fromarray(rgb);draw=ImageDraw.Draw(image);x,y,r,b=box
    minimum=max(5,int(size*.55))
    for size in range(max(5,int(size)),minimum-1,-1):
        font=ImageFont.truetype(FONT,size);words=text.split();rows=[];row=''
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
    for i,row in enumerate(rows):draw.text(((x+r)/2,top+i*lineheight),row,font=font,fill=tuple(color),direction=direction,anchor='mt')
    return np.asarray(image),True

def run(args):
    root=pathlib.Path(args.corpus);out=pathlib.Path(args.output);out.mkdir(parents=True,exist_ok=True)
    engine=Engine(args.models);corpus=json.loads((root/'corpus.json').read_text());cases=[];stages=[]
    for chapter in corpus['chapters']:
        limit=args.regions//len(corpus['chapters']);count=0
        pages=list(chapter['pages']);random.Random(0).shuffle(pages)
        per_page=math.ceil(limit/len(pages))+2
        for page in pages:
            if count>=limit:break
            rgb=np.asarray(Image.open(root/page['path']).convert('RGB'));start=time.perf_counter();lines=engine.detect(rgb)
            groups=paragraphs(rgb,lines);random.Random(0).shuffle(groups)
            for paragraph,area in groups[:per_page]:
                if count>=limit:break
                boxes=[l['box'] for l in paragraph];x=min(b[0]for b in boxes);y=min(b[1]for b in boxes);r=max(b[2]for b in boxes);b=max(b[3]for b in boxes)
                if r-x<15 or b-y<10 or (r-x)*(b-y)>750000:continue
                pad=24;cx=max(0,min(x,area[0])-pad);cy=max(0,min(y,area[1])-pad);cr=min(rgb.shape[1],max(r,area[2])+pad);cb=min(rgb.shape[0],max(b,area[3])+pad)
                crop=np.ascontiguousarray(rgb[cy:cb,cx:cr]);local=[[a-cx,c-cy,d-cx,e-cy] for a,c,d,e in boxes]
                clean,mask=engine.clean(crop,local);accepted=engine.safe_to_letter(crop,mask,local)
                if not accepted:clean=crop.copy()
                outside=int(np.count_nonzero(np.any(clean!=crop,axis=2)&(mask==0)))
                cid=f'{chapter["language"]}-{chapter["id"][:8]}-{chapter["split"]}-{count:03d}';dest=out/cid;dest.mkdir(exist_ok=True)
                for name,a in [('original',crop),('mask',mask),('clean',clean)]:Image.fromarray(a).save(dest/(name+'.png'))
                text=('This is a translated paragraph.' if len(paragraph)>1 else 'Translation') if chapter['language']=='ar' else ('هذه ترجمة عربية تجريبية داخل الفقاعة' if len(paragraph)>1 else 'ترجمة تجريبية')
                fg=(12,12,12) if np.median(crop)>128 else (248,248,248)
                rendered,fit=lettering(clean,[area[0]-cx,area[1]-cy,area[2]-cx,area[3]-cy],text,np.median([l['glyph_height']for l in paragraph])*1.3,fg,direction='ltr' if chapter['language']=='ar' else 'rtl')
                if not accepted:rendered=crop.copy()
                Image.fromarray(rendered).save(dest/'rendered.png')
                recognized=[]
                if args.ocr:
                    for line in paragraph:recognized.append(engine.recognize(rgb,line['box'],chapter['language']))
                case=dict(id=cid,language=chapter['language'],split=chapter['split'],chapter=chapter['id'],source=page['path'],source_sha256=page['sha256'],box=[cx,cy,cr,cb],layout_box=[area[0]-cx,area[1]-cy,area[2]-cx,area[3]-cy],lines=paragraph,ocr=recognized,outside_mask_changes=outside,fit=fit,cleanup_accepted=accepted,annotation_status='unreviewed',translation='fixed Arabic layout probe',seconds=time.perf_counter()-start)
                cases.append(case);count+=1;start=time.perf_counter()
                if args.lama and count<=args.lama:
                    restored=engine.lama(crop,mask);Image.fromarray(restored).save(dest/'lama.png')
                    case['lama_outside_mask_changes']=int(np.count_nonzero(np.any(restored!=crop,axis=2)&(mask==0)))
            print(chapter['language'],chapter['split'],page['path'],'regions',count,flush=True)
        (out/'cases.json').write_text(json.dumps(cases,ensure_ascii=False,indent=2))
    rows=[]
    for c in cases:
        images=''.join(f'<figure><figcaption>{name}</figcaption><img loading="lazy" src="{c["id"]}/{name}.png"></figure>' for name in ['original','mask','clean','rendered']+(['lama']if(out/c['id']/'lama.png').exists()else[]))
        rows.append(f'<article id="{c["id"]}"><h2>{c["id"]}</h2><p>{html.escape(" / ".join(c["ocr"]))}</p><div class="stages">{images}</div><label>Review <select data-id="{c["id"]}"><option>unreviewed</option><option>pass</option><option>mask failure</option><option>cleanup failure</option><option>layout failure</option><option>missed text</option></select></label><input data-note="{c["id"]}" placeholder="review notes"></article>')
    review='''<script>function save(){const reviews=[...document.querySelectorAll('select[data-id]')].map(e=>({id:e.dataset.id,verdict:e.value,note:document.querySelector('[data-note="'+e.dataset.id+'"]').value}));const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(reviews,null,2)],{type:'application/json'}));a.download='reviews.json';a.click();}</script>'''
    (out/'index.html').write_text('<meta charset="utf-8"><title>Zeus comic quality lab</title><style>body{background:#181a20;color:#eee;font:16px sans-serif}article{padding:16px;border-bottom:1px solid #777}.stages{display:flex;flex-wrap:wrap;gap:10px}figure{margin:0}img{max-width:420px;max-height:440px;object-fit:contain;image-rendering:auto}select,input,button{font:inherit;padding:10px}</style><h1>Real comic quality lab</h1><p>Fixed Arabic text tests layout only. Unreviewed proposals are not ground truth.</p><button onclick="save()">Export reviews</button>'+''.join(rows)+review)
    report=dict(chapters=len(corpus['chapters']),pages=sum(len(c['pages'])for c in corpus['chapters']),regions=len(cases),languages=sorted(set(c['language']for c in cases)),outside_mask_changes=sum(c['outside_mask_changes']for c in cases),layout_probe_fits=sum(c['fit']for c in cases),cleanup_gate_accepted=sum(c['cleanup_accepted']for c in cases),cleanup_gate_abstained=sum(not c['cleanup_accepted']for c in cases),manually_reviewed=0,quality_acceptance_proven=False,peak_rss_kib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    (out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report),flush=True)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--corpus',required=True);p.add_argument('--models',required=True);p.add_argument('--output',required=True);p.add_argument('--regions',type=int,default=400);p.add_argument('--ocr',action='store_true');p.add_argument('--lama',type=int,default=0);run(p.parse_args())
