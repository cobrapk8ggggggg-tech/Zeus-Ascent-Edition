"""CPU reference harness. Shared native masks; ONNX tensors match the app."""
import ctypes, hashlib, json, pathlib, subprocess, time, os, uuid
import cv2, numpy as np, onnxruntime as ort, yaml
HERE=pathlib.Path(__file__).resolve().parent
class Engine:
    def __init__(self,models):
        self.models=pathlib.Path(models);self.sessions={};self.dictionaries={}
        header=HERE.parents[2]/'Native/ComicRuntime/ComicInpaint.h'
        self.native_sha=hashlib.sha256(header.read_bytes()+(HERE/'native.cpp').read_bytes()).hexdigest()
        library=HERE/'output'/('mask-'+self.native_sha[:16]+'.so');library.parent.mkdir(exist_ok=True)
        if not library.exists():
            temporary=library.with_name(library.name+'.'+uuid.uuid4().hex+'.tmp')
            subprocess.run(['g++','-O2','-std=c++17','-shared','-fPIC',str(HERE/'native.cpp'),'-o',str(temporary)],check=True)
            os.replace(temporary,library)
        self.lib=ctypes.CDLL(str(library));p=np.ctypeslib.ndpointer(dtype=np.uint8,flags='C_CONTIGUOUS')
        self.lib.clean.argtypes=[p]+[ctypes.c_int]*6;self.lib.text_mask.argtypes=[p,p]+[ctypes.c_int]*6;self.lib.clean_source.argtypes=[p,p]+[ctypes.c_int]*6;self.lib.coverage.argtypes=[p,p]+[ctypes.c_int]*6;self.lib.coverage.restype=ctypes.c_float;self.lib.refine.argtypes=[p,p,p]+[ctypes.c_int]*6;self.lib.refine_ocr.argtypes=[p,p]+[ctypes.c_int]*6;self.lib.clean_mask.argtypes=[p,p,p]+[ctypes.c_int]*6;self.lib.simple_background.argtypes=[p,p]+[ctypes.c_int]*6;self.lib.neural_valid.argtypes=[p,p,p]+[ctypes.c_int]*6
    def session(self,name):
        if name not in self.sessions:
            # Match the app's memory discipline: only one restoration graph,
            # or the detector plus the currently selected OCR script.
            if name in ['ctd.onnx','lama.onnx']:self.sessions.clear()
            else:self.sessions={k:v for k,v in self.sessions.items()if k in ['det.onnx',name]}
            options=ort.SessionOptions();options.intra_op_num_threads=2;options.inter_op_num_threads=1;options.log_severity_level=3
            self.sessions[name]=ort.InferenceSession(str(self.models/name),options,providers=['CPUExecutionProvider'])
        return self.sessions[name]
    def detect(self,rgb):
        h,w=rgb.shape[:2];scale=min(1,(2_000_000/(w*h))**.5,4000/max(w,h));dw=max(32,round(w*scale/32)*32);dh=max(32,round(h*scale/32)*32)
        a=cv2.resize(rgb[:,:,::-1],(dw,dh)).astype(np.float32)/255
        a=(a-np.array([.485,.456,.406],np.float32))/np.array([.229,.224,.225],np.float32)
        s=self.session('det.onnx');prob=s.run(None,{s.get_inputs()[0].name:a.transpose(2,0,1)[None]})[0][0,0]
        count,labels,stats,_=cv2.connectedComponentsWithStats((prob>.3).astype(np.uint8),4)
        lines=[]
        for label in range(1,count):
            x,y,bw,bh,area=map(int,stats[label]);confidence=float(prob[labels==label].mean())
            if area<3 or confidence<=.5:continue
            # DB emits a shrunken text kernel, not a complete glyph rectangle.
            # Offset by area/perimeter (DB unclip), rather than 1/4 box height.
            pad=1.5*bw*bh/(2*(bw+bh))
            box=[max(1,int((x-pad)*w/prob.shape[1])),max(1,int((y-pad)*h/prob.shape[0])),min(w-1,int(np.ceil((x+bw+pad)*w/prob.shape[1]))),min(h-1,int(np.ceil((y+bh+pad)*h/prob.shape[0])))]
            lines.append(dict(box=box,confidence=confidence,glyph_height=min(box[2]-box[0],box[3]-box[1])*.72))
        return sorted(lines,key=lambda l:(l['box'][1],l['box'][0]))
    def recognize(self,rgb,box,language):
        return self.recognize_info(rgb,box,language)[0]
    def recognize_info(self,rgb,box,language):
        name={'en':'latin','ja':'han','zh':'han','ko':'korean','ar':'arabic'}[language]
        if name not in self.dictionaries:self.dictionaries[name]=['']+yaml.safe_load((self.models/(name+'.yml')).read_text())['PostProcess']['character_dict']+[' ']
        x,y,r,b=box;cut=rgb[y:b,x:r]
        if cut.shape[0]>cut.shape[1]*1.5:cut=cv2.rotate(cut,cv2.ROTATE_90_COUNTERCLOCKWISE)
        width=max(8,min(4096,int(np.ceil(cut.shape[1]*48/cut.shape[0]))))
        tensor=cv2.resize(cut[:,:,::-1],(width,48)).astype(np.float32)/127.5-1
        s=self.session(name+'.onnx');logits=s.run(None,{s.get_inputs()[0].name:tensor.transpose(2,0,1)[None]})[0][0]
        indices=np.argmax(logits,axis=1);text=[];scores=[];last=0
        for timestep,i in enumerate(indices):
            if i and i!=last and i<len(self.dictionaries[name]):text.append(self.dictionaries[name][i]);scores.append(float(logits[timestep,i]))
            last=i
        return ''.join(text),float(np.mean(scores)) if scores else 0
    def clean(self,rgb,boxes):
        rgba=np.ascontiguousarray(cv2.cvtColor(rgb,cv2.COLOR_RGB2RGBA));mask=np.zeros(rgb.shape[:2],np.uint8);h,w=mask.shape
        merged=[]
        for x,y,r,b in boxes:
            pad=max(3,min(r-x,b-y)*.18)
            box=[max(1,int(x-pad)),max(1,int(y-pad)),min(w-1,int(np.ceil(r+pad))),min(h-1,int(np.ceil(b+pad)))]
            while True:
                overlaps=[q for q in merged if min(q[2],box[2])>max(q[0],box[0]) and min(q[3],box[3])>max(q[1],box[1])]
                if not overlaps:break
                for q in overlaps:
                    merged.remove(q);box=[min(q[0],box[0]),min(q[1],box[1]),max(q[2],box[2]),max(q[3],box[3])]
            merged.append(box)
        # Masks are computed against the untouched source, then cleaned separately.
        for box in merged:self.lib.text_mask(rgba,mask,w,h,*map(int,box))
        if not self.safe_to_letter(rgb,mask,boxes):
            refined=np.zeros_like(mask)
            for box in merged:self.lib.refine_ocr(rgba,refined,w,h,*map(int,box))
            if self.safe_to_letter(rgb,refined,boxes):mask=refined
        out=rgba.copy()
        for box in merged:self.lib.clean_mask(rgba,out,mask,w,h,*map(int,box))
        return out[:,:,:3],mask
    def refine(self,rgb,hints,boxes):
        rgba=np.ascontiguousarray(cv2.cvtColor(rgb,cv2.COLOR_RGB2RGBA));mask=np.zeros(rgb.shape[:2],np.uint8);h,w=mask.shape
        for x,y,r,b in boxes:
            pad=max(3,min(r-x,b-y)*.18);box=[max(1,int(x-pad)),max(1,int(y-pad)),min(w-1,int(r+pad)),min(h-1,int(b+pad))]
            self.lib.refine(rgba,hints,mask,w,h,*box)
        return mask
    def hints(self,rgb):
        h,w=rgb.shape[:2];scale=min(1024/h,1024/w);cw=max(1,round(w*scale));ch=max(1,round(h*scale))
        image=cv2.copyMakeBorder(cv2.resize(rgb,(cw,ch)),0,1024-ch,0,1024-cw,cv2.BORDER_CONSTANT,value=(0,0,0))
        session=self.session('ctd.onnx');output=session.run(['seg'],{session.get_inputs()[0].name:image.astype(np.float32).transpose(2,0,1)[None]/255})[0][0,0]
        return ((cv2.resize(output[:ch,:cw],(w,h)))>.3).astype(np.uint8)*255
    def restore_neural(self,rgb,boxes):
        h,w=rgb.shape[:2];x=max(0,min(b[0]for b in boxes)-48);y=max(0,min(b[1]for b in boxes)-48);r=min(w,max(b[2]for b in boxes)+48);b=min(h,max(b[3]for b in boxes)+48)
        crop=np.ascontiguousarray(rgb[y:b,x:r]);local=[[a-x,c-y,d-x,e-y]for a,c,d,e in boxes]
        hint=self.hints(crop);mask=self.refine(crop,hint,local)
        rgba=np.ascontiguousarray(cv2.cvtColor(crop,cv2.COLOR_RGB2RGBA))
        if not all(self.lib.neural_valid(rgba,hint,mask,crop.shape[1],crop.shape[0],*map(int,box))for box in local):return rgb.copy(),np.zeros((h,w),np.uint8),False
        restored=self.lama(crop,mask);result=rgb.copy();result[y:b,x:r]=restored
        whole_mask=np.zeros((h,w),np.uint8);whole_mask[y:b,x:r]=mask
        return result,whole_mask,True
    def can_letter_light(self,rgb,mask,boxes):
        return self.safe_to_letter(rgb,mask,boxes) and self.simple_background(rgb,mask,boxes)
    def safe_to_letter(self,rgb,mask,boxes):
        rgba=np.ascontiguousarray(cv2.cvtColor(rgb,cv2.COLOR_RGB2RGBA));h,w=mask.shape
        return all(self.lib.coverage(rgba,mask,w,h,*map(int,box))>=.95 for box in boxes)
    def simple_background(self,rgb,mask,boxes):
        rgba=np.ascontiguousarray(cv2.cvtColor(rgb,cv2.COLOR_RGB2RGBA));h,w=mask.shape
        expanded=[]
        for x,y,r,b in boxes:
            pad=max(3,min(r-x,b-y)*.18);expanded.append([max(1,int(x-pad)),max(1,int(y-pad)),min(w-1,int(np.ceil(r+pad))),min(h-1,int(np.ceil(b+pad)))])
        return all(self.lib.simple_background(rgba,mask,w,h,*box) for box in expanded)
    def lama(self,rgb,mask):
        ys,xs=np.where(mask>0)
        if not len(xs):return rgb.copy()
        h,w=mask.shape;pad=48;x=max(0,int(xs.min())-pad);y=max(0,int(ys.min())-pad);r=min(w,int(xs.max())+pad+1);b=min(h,int(ys.max())+pad+1)
        crop=rgb[y:b,x:r];m=mask[y:b,x:r]
        # Preserve aspect ratio and pad to the fixed model canvas; never stretch.
        scale=min(512/crop.shape[0],512/crop.shape[1]);cw=max(1,round(crop.shape[1]*scale));ch=max(1,round(crop.shape[0]*scale))
        image=cv2.copyMakeBorder(cv2.resize(crop,(cw,ch)),0,512-ch,0,512-cw,cv2.BORDER_REFLECT_101)
        binary=np.zeros((512,512),np.float32);binary[:ch,:cw]=cv2.resize(m,(cw,ch),interpolation=cv2.INTER_NEAREST)>0
        s=self.session('lama.onnx');out=s.run(None,{'image':image.astype(np.float32).transpose(2,0,1)[None]/255,'mask':binary[None,None]})[0]
        if out.shape[1]==3:out=out[0].transpose(1,2,0)
        else:out=out[0]
        restored=cv2.resize(out[:ch,:cw].clip(0,255).astype(np.uint8),(r-x,b-y))
        result=rgb.copy();target=result[y:b,x:r];target[m>0]=restored[m>0]
        return result
