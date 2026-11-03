"""Compare CTD segmentation and LaMa on the same real crops; no quality score inferred."""
import argparse,json,pathlib,resource,time
import cv2,numpy as np
from PIL import Image
from engine import Engine

def ctd(engine,rgb):
 h,w=rgb.shape[:2];scale=min(1024/h,1024/w);cw=max(1,round(w*scale));ch=max(1,round(h*scale))
 image=cv2.copyMakeBorder(cv2.resize(rgb,(cw,ch)),0,1024-ch,0,1024-cw,cv2.BORDER_CONSTANT,value=(0,0,0))
 session=engine.session('ctd.onnx');outputs=session.run(None,{session.get_inputs()[0].name:image.astype(np.float32).transpose(2,0,1)[None]/255})
 mask=outputs[1][0,0][:ch,:cw];mask=cv2.resize(mask,(w,h))
 return cv2.dilate((mask>.3).astype(np.uint8)*255,np.ones((3,3),np.uint8))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--models',required=True);p.add_argument('--cases',required=True);p.add_argument('--count',type=int,default=10);p.add_argument('--ids',default='');a=p.parse_args();root=pathlib.Path(a.cases);engine=Engine(a.models);results=[]
 for case in json.loads((root/'cases.json').read_text()):
  if case['split']!='calibration' or (a.ids and case['id'] not in a.ids.split(',')):continue
  dest=root/case['id'];rgb=np.asarray(Image.open(dest/'original.png').convert('RGB'));mask=np.asarray(Image.open(dest/'mask.png'));start=time.perf_counter()
  predicted=ctd(engine,rgb);Image.fromarray(predicted).save(dest/'ctd-mask.png')
  # Only intersect with recognized text ownership, never erase all detector output.
  ownership=np.zeros_like(mask)
  cx,cy,_,_=case['box']
  for line in case['lines']:
   x,y,r,b=line['box'];pad=8;cv2.rectangle(ownership,(max(0,x-cx-pad),max(0,y-cy-pad)),(min(rgb.shape[1]-1,r-cx+pad),min(rgb.shape[0]-1,b-cy+pad)),255,-1)
  local_boxes=[[x-cx,y-cy,r-cx,b-cy]for x,y,r,b in [line['box']for line in case['lines']]]
  bounded=engine.refine(rgb,predicted,local_boxes)
  Image.fromarray(bounded).save(dest/'refined-mask.png')
  restored=engine.lama(rgb,bounded);Image.fromarray(restored).save(dest/'ctd-lama.png')
  Image.fromarray(engine.lama(rgb,mask)).save(dest/'lama.png')
  results.append(dict(id=case['id'],ctd_mask_pixels=int(np.count_nonzero(predicted)),bounded_pixels=int(np.count_nonzero(bounded)),outside_mask_changes=int(np.count_nonzero(np.any(restored!=rgb,axis=2)&(bounded==0))),seconds=time.perf_counter()-start))
  print(results[-1],flush=True)
  if len(results)>=a.count:break
 (root/'model-comparison.json').write_text(json.dumps(dict(cases=results,peak_rss_kib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,quality_equivalence_proven=False),indent=2))
