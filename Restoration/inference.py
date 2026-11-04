"""Lossless remote execution of the app's pinned CTD and LaMa tensors.

No OCR, resizing, mask refinement, compositing, or image storage happens here.
Those operations stay identical in the native reader. Only ORT moves off-device.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import threading
import urllib.request
import zlib
import numpy as np
import onnxruntime as ort

SHAPES={'ctd.onnx':{'image':(1,3,1024,1024)},'lama.onnx':{'image':(1,3,512,512),'mask':(1,1,512,512)}}
OUTPUTS={'ctd.onnx':(1,1,1024,1024),'lama.onnx':(1,3,512,512)}

def unpack(encoded,shape):
    limit=int(np.prod(shape))*4
    if not isinstance(encoded,str) or len(encoded)>24_000_000:raise ValueError('Invalid tensor size')
    packed=base64.b64decode(encoded,validate=True)
    stream=zlib.decompressobj();raw=stream.decompress(packed,limit+1)
    if len(raw)!=limit or not stream.eof or stream.unused_data or stream.unconsumed_tail:raise ValueError('Invalid tensor stream')
    value=np.frombuffer(raw,dtype='<f4').reshape(shape)
    if not np.isfinite(value).all():raise ValueError('Non-finite tensor')
    return value

def pack(value):
    value=np.ascontiguousarray(value,dtype='<f4')
    if not np.isfinite(value).all():raise ValueError('Non-finite model output')
    return base64.b64encode(zlib.compress(value.tobytes(),1)).decode('ascii')

class Runner:
    def __init__(self,root,catalog):
        self.root=Path(root);self.catalog={x['name']:x for x in catalog['models']if x['name']in SHAPES}
        self.lock=threading.Lock();self.current=None;self.name=None
    def prepare(self):
        self.root.mkdir(parents=True,exist_ok=True)
        for name,a in self.catalog.items():
            target=self.root/name
            if not target.exists():
                part=target.with_suffix('.part')
                with urllib.request.urlopen(a['url'],timeout=120)as source,part.open('wb')as dest:
                    remaining=a['bytes']
                    while chunk:=source.read(min(1048576,remaining+1)):
                        remaining-=len(chunk)
                        if remaining<0:raise ValueError('Oversized model')
                        dest.write(chunk)
                part.replace(target)
            digest=hashlib.sha256()
            with target.open('rb')as f:
                while chunk:=f.read(1048576):digest.update(chunk)
            if target.stat().st_size!=a['bytes']or digest.hexdigest()!=a['sha256']:raise ValueError('Model verification failed: '+name)
    def infer(self,name,inputs):
        if name not in SHAPES or set(inputs)!=set(SHAPES[name]):raise ValueError('Unsupported model inputs')
        tensors={key:unpack(inputs[key],shape)for key,shape in SHAPES[name].items()}
        with self.lock:
            if self.name!=name:
                self.current=None;self.name=None
                options=ort.SessionOptions();options.intra_op_num_threads=2;options.graph_optimization_level=ort.GraphOptimizationLevel.ORT_ENABLE_ALL
                self.current=ort.InferenceSession(str(self.root/name),options,providers=['CPUExecutionProvider']);self.name=name
            names=self.current.get_outputs();output=names[1].name if name=='ctd.onnx'else names[0].name
            source=self.current.get_inputs()[0].name
            actual={source:tensors['image']}if name=='ctd.onnx'else tensors
            result=self.current.run([output],actual)[0]
            if tuple(result.shape)!=OUTPUTS[name]:raise ValueError('Unexpected model output')
            return {'version':1,'model':name,'sha256':self.catalog[name]['sha256'],'output':pack(result)}
