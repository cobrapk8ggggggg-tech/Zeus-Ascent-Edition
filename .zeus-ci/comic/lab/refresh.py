"""Evaluate frozen real-page proposals with current kernels; never relabel them gold."""
import argparse,json,pathlib,time,resource,importlib.metadata
import numpy as np
from PIL import Image
from engine import Engine
from run import lettering,gallery
p=argparse.ArgumentParser();p.add_argument('--models',required=True);p.add_argument('--cases',required=True);p.add_argument('--output');p.add_argument('--neural',action='store_true');p.add_argument('--ocr',action='store_true');a=p.parse_args()
source=pathlib.Path(a.cases);root=pathlib.Path(a.output or a.cases);root.mkdir(parents=True,exist_ok=True)
engine=Engine(a.models);cases=json.loads((source/'cases.json').read_text());start=time.perf_counter()
# One recognition pass per script avoids loading the OCR graphs between every
# neural crop. Keep failed proposals visible; an OCR pass is not a gold label.
for case in cases:
 dest=root/case['id'];dest.mkdir(exist_ok=True);rgb=np.asarray(Image.open(source/case['id']/'original.png').convert('RGB'))
 if root!=source:Image.fromarray(rgb).save(dest/'original.png')
 x,y,r,b=case['box'];boxes=[[aa-x,bb-y,rr-x,ee-y]for aa,bb,rr,ee in [l['box']for l in case['lines']]]
 for line in case['lines']:q=line['box'];line['glyph_height']=min(q[2]-q[0],q[3]-q[1])*.72
 if a.ocr:
  info=[engine.recognize_info(rgb,box,case['language'])for box in boxes]
  case['ocr']=[t for t,c in info];case['ocr_confidence']=[c for t,c in info]
print('Recognition complete',flush=True)
for index,case in enumerate(cases):
 dest=root/case['id'];rgb=np.asarray(Image.open(dest/'original.png').convert('RGB'));x,y,r,b=case['box']
 boxes=[[aa-x,bb-y,rr-x,ee-y]for aa,bb,rr,ee in [l['box']for l in case['lines']]]
 area=case.get('layout_box',[min(q[i]for q in boxes)if i<2 else max(q[i]for q in boxes)for i in range(4)])
 text=('This is a translated paragraph.'if len(boxes)>1 else'Translation')if case['language']=='ar'else('هذه ترجمة عربية تجريبية داخل الفقاعة'if len(boxes)>1 else'ترجمة تجريبية')
 source_style=engine.ink_style(rgb,boxes)
 color=(12,)*3 if np.median(rgb)>128 else(248,)*3
 # Exact same layout is used before and after erasure; declined layout is identity.
 _,fit=lettering(rgb,area,text,np.median([l['glyph_height']for l in case['lines']])*1.3,color,direction='ltr'if case['language']=='ar'else'rtl',vertical=case.get('vertical_caption',False),ink_style=source_style)
 source_readable=all(t.strip() and c>=.65 for t,c in zip(case.get('ocr',[]),case.get('ocr_confidence',[])))if case.get('ocr_confidence') is not None else True
 accepted=False;route='original';clean=rgb.copy();mask=np.zeros(rgb.shape[:2],np.uint8)
 if fit and source_readable:
  clean,mask=engine.clean(rgb,boxes);accepted=engine.can_letter_light(rgb,mask,boxes,area if case.get('balloon',False)else None)
  if accepted:route='light'
  elif a.neural:
   clean,mask,accepted=engine.restore_neural(rgb,boxes,area if case.get('balloon',False)else None)
   if accepted:route='neural'
 if not accepted:clean=rgb.copy()
 rendered=clean
 if accepted:rendered,_=lettering(clean,area,text,np.median([l['glyph_height']for l in case['lines']])*1.3,color,direction='ltr'if case['language']=='ar'else'rtl',vertical=case.get('vertical_caption',False),ink_style=source_style)
 case.update(source_ink_style=source_style,fit=fit,source_readable=source_readable,restoration_route=route,cleanup_accepted=accepted,outside_mask_changes=int(np.count_nonzero(np.any(clean!=rgb,axis=2)&(mask==0))))
 for name,array in [('mask',mask),('clean',clean),('rendered',rendered)]:Image.fromarray(array).save(dest/(name+'.png'))
 if index%20==0:
  print(index,case['id'],route,flush=True);(root/'cases.json').write_text(json.dumps(cases,ensure_ascii=False,indent=2))
(root/'cases.json').write_text(json.dumps(cases,ensure_ascii=False,indent=2));gallery(root,cases)
report=json.loads((source/'report.json').read_text());report.update(outside_mask_changes=sum(c['outside_mask_changes']for c in cases),layout_probe_fits=sum(c['fit']for c in cases),mask_refresh_seconds=time.perf_counter()-start,cleanup_gate_accepted=sum(c['cleanup_accepted']for c in cases),cleanup_gate_abstained=sum(not c['cleanup_accepted']for c in cases),neural_restored=sum(c['restoration_route']=='neural'for c in cases),light_restored=sum(c['restoration_route']=='light'for c in cases),unreadable_source_proposals=sum(not c['source_readable']for c in cases),native_kernel_sha256=engine.native_sha,protocol='adaptive-v4: whole-balloon text ownership; frozen geometry; layout preflight',dependency_versions={k:importlib.metadata.version(k)for k in['onnxruntime','opencv-python-headless','numpy','Pillow','PyYAML']},peak_rss_kib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
(root/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report),flush=True)
