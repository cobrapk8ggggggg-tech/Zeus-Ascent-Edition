import base64
import json
from pathlib import Path
import unittest
import zlib
import numpy as np
from inference import Runner,pack,unpack

class TensorTransportTests(unittest.TestCase):
    def test_lossless_bits(self):
        a=np.array([0,1,-1,.3,np.nextafter(np.float32(0),np.float32(1))],dtype='<f4')
        self.assertEqual(a.tobytes(),unpack(pack(a),a.shape).tobytes())
    def test_rejects_wrong_size_trailing_data_and_nonfinite(self):
        a=np.zeros((2,),dtype='<f4');encoded=pack(a)
        with self.assertRaises(ValueError):unpack(encoded,(3,))
        with self.assertRaises(ValueError):unpack(base64.b64encode(base64.b64decode(encoded)+b'extra').decode(),(2,))
        with self.assertRaises(ValueError):pack(np.array([float('nan')],dtype='<f4'))
    def test_rejects_expansion_beyond_declared_tensor(self):
        value=base64.b64encode(zlib.compress(b'0'*1000000)).decode()
        with self.assertRaises(ValueError):unpack(value,(2,))
    def test_actual_models_match_direct_ort(self):
        import os
        if 'ZEUS_TEST_MODELS'not in os.environ:self.skipTest('Actual pinned models not configured')
        catalog=json.loads(Path('ZEUSNext/Resources/comic-models.json').read_text())
        runner=Runner(os.environ['ZEUS_TEST_MODELS'],catalog);runner.prepare()
        rng=np.random.default_rng(17)
        for name,edge in [('ctd.onnx',1024),('lama.onnx',512)]:
            tensors={'image':rng.random((1,3,edge,edge),dtype=np.float32)}
            if name=='lama.onnx':
                tensors['mask']=np.zeros((1,1,edge,edge),dtype=np.float32);tensors['mask'][:,:,180:220,200:270]=1
            result=runner.infer(name,{k:pack(v)for k,v in tensors.items()})
            outputs=runner.current.get_outputs();output=outputs[1].name if name=='ctd.onnx'else outputs[0].name
            inputs={runner.current.get_inputs()[0].name:tensors['image']}if name=='ctd.onnx'else tensors
            direct=runner.current.run([output],inputs)[0]
            self.assertEqual(direct.tobytes(),unpack(result['output'],direct.shape).tobytes())
            self.assertEqual(result['sha256'],runner.catalog[name]['sha256'])

if __name__=='__main__':unittest.main()
