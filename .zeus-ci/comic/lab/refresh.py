"""Re-run shared native masks/lettering on frozen proposals without re-running OCR."""
import argparse,json,pathlib,time
import numpy as np
from PIL import Image
from engine import Engine
from run import lettering
p=argparse.ArgumentParser();p.add_argument('--models',required=True);p.add_argument('--cases',required=True);a=p.parse_args();root=pathlib.Path(a.cases);engine=Engine(a.models);cases=json.loads((root/'cases.json').read_text());start=time.perf_counter()
for case in cases:
 dest=root/case['id'];rgb=np.asarray(Image.open(dest/'original.png').convert('RGB'));x,y,r,b=case['box']
 boxes=[[aa-x,bb-y,rr-x,ee-y]for aa,bb,rr,ee in [l['box']for l in case['lines']]]
 clean,mask=engine.clean(rgb,boxes)
 case['cleanup_accepted']=engine.safe_to_letter(rgb,mask,boxes)
 if not case['cleanup_accepted']:clean=rgb.copy()
 case['outside_mask_changes']=int(np.count_nonzero(np.any(clean!=rgb,axis=2)&(mask==0)))
 for name,array in [('mask',mask),('clean',clean)]:Image.fromarray(array).save(dest/(name+'.png'))
 source=[min(q[i]for q in boxes)if i<2 else max(q[i]for q in boxes)for i in range(4)]
 text=('This is a translated paragraph.' if len(boxes)>1 else 'Translation')if case['language']=='ar'else('هذه ترجمة عربية تجريبية داخل الفقاعة'if len(boxes)>1 else 'ترجمة تجريبية')
 color=(12,)*3 if np.median(rgb)>128 else (248,)*3
 rendered,fit=lettering(clean,source,text,np.median([l['glyph_height']for l in case['lines']])*1.3,color,direction='ltr'if case['language']=='ar'else'rtl')
 case['fit']=fit
 if not case['cleanup_accepted']:rendered=rgb.copy()
 Image.fromarray(rendered).save(dest/'rendered.png')
(root/'cases.json').write_text(json.dumps(cases,ensure_ascii=False,indent=2));report=json.loads((root/'report.json').read_text());report.update(outside_mask_changes=sum(c['outside_mask_changes']for c in cases),layout_probe_fits=sum(c['fit']for c in cases),mask_refresh_seconds=time.perf_counter()-start,cleanup_gate_accepted=sum(c['cleanup_accepted']for c in cases),cleanup_gate_abstained=sum(not c['cleanup_accepted']for c in cases))
(root/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
