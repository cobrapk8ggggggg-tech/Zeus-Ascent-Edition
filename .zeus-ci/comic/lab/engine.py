"""CPU reference harness. Shared native masks; ONNX tensors match the app."""
import ctypes, hashlib, json, pathlib, subprocess, time
import cv2, numpy as np, onnxruntime as ort, yaml
HERE=pathlib.Path(__file__).resolve().parent
class Engine:
    def __init__(self,models):
        self.models=pathlib.Path(models);self.sessions={};self.dictionaries={}
        library=HERE/'output'/'mask.so';library.parent.mkdir(exist_ok=True)
        subprocess.run(['g++','-O2','-std=c++17','-shared','-fPIC',str(HERE/'native.cpp'),'-o',str(library)],check=True)
        self.lib=ctypes.CDLL(str(library));p=np.ctypeslib.ndpointer(dtype=np.uint8,flags='C_CONTIGUOUS')
        self.lib.clean.argtypes=[p]+[ctypes.c_int]*6;self.lib.text_mask.argtypes=[p,p]+[ctypes.c_int]*6;self.lib.clean_source.argtypes=[p,p]+[ctypes.c_int]*6;self.lib.coverage.argtypes=[p,p]+[ctypes.c_int]*6;self.lib.coverage.restype=ctypes.c_float
    def session(self,name):
        if name not in self.sessions:
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
            lines.append(dict(box=box,confidence=confidence,glyph_height=bh*h/prob.shape[0]*1.7))
        return sorted(lines,key=lambda l:(l['box'][1],l['box'][0]))
    def recognize(self,rgb,box,language):
        name={'en':'latin','ja':'han','zh':'han','ko':'korean','ar':'arabic'}[language]
        if name not in self.dictionaries:self.dictionaries[name]=['']+yaml.safe_load((self.models/(name+'.yml')).read_text())['PostProcess']['character_dict']+[' ']
        x,y,r,b=box;cut=rgb[y:b,x:r]
        if cut.shape[0]>cut.shape[1]*1.5:cut=cv2.rotate(cut,cv2.ROTATE_90_CLOCKWISE)
        width=max(8,min(4096,int(np.ceil(cut.shape[1]*48/cut.shape[0]))))
        tensor=cv2.resize(cut[:,:,::-1],(width,48)).astype(np.float32)/127.5-1
        s=self.session(name+'.onnx');logits=s.run(None,{s.get_inputs()[0].name:tensor.transpose(2,0,1)[None]})[0][0]
        indices=np.argmax(logits,axis=1);text=[];last=0
        for i in indices:
            if i and i!=last and i<len(self.dictionaries[name]):text.append(self.dictionaries[name][i])
            last=i
        return ''.join(text)
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
        out=rgba.copy()
        for box in merged:self.lib.clean_source(rgba,out,w,h,*map(int,box))
        return out[:,:,:3],mask
    def safe_to_letter(self,rgb,mask,boxes):
        rgba=np.ascontiguousarray(cv2.cvtColor(rgb,cv2.COLOR_RGB2RGBA));h,w=mask.shape
        return all(self.lib.coverage(rgba,mask,w,h,*map(int,box))>=.95 for box in boxes)
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
