"""Known clean backgrounds provide independent pixel truth, not OCR self-grading."""
import unittest, pathlib
import cv2,numpy as np
from PIL import Image,ImageDraw,ImageFont
from engine import Engine
class Masks(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.engine=Engine(pathlib.Path(__file__).parent/'models')
 def test_outlined_text_on_flat_and_gradient_backgrounds(self):
  errors=[]
  for dark in [False,True]:
   for slope in [0,.08,.2]:
    h,w=120,360;values=np.arange(h)[:,None]*slope+(18 if dark else 220)
    clean=np.repeat(np.repeat(values[:,:,None],w,axis=1),3,axis=2).clip(0,255).astype(np.uint8)
    image=Image.fromarray(clean);draw=ImageDraw.Draw(image);font=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',26)
    draw.text((40,40),'EXCUSE ME',font=font,fill=(245,)*3 if dark else (10,)*3,stroke_width=2,stroke_fill=(5,)*3 if dark else (250,)*3)
    source=np.asarray(image);box=draw.textbbox((40,40),'EXCUSE ME',font=font,stroke_width=2)
    restored,mask=self.engine.clean(source,[box]);difference=np.abs(restored.astype(float)-clean.astype(float))
    changed=np.any(source!=restored,axis=2)
    self.assertEqual(int(np.count_nonzero(changed&(mask==0))),0)
    self.assertEqual(int(np.count_nonzero((source!=clean).any(axis=2)&(mask==0))),0,'mask must cover all source ink and outlines')
    error=float(difference.max());errors.append(error);self.assertLess(error,8,'no visible source remnants on known clean background')
  print('independent known-background maximum errors:',errors)
 def test_empty_mask_is_identity(self):
  image=np.full((100,240,3),180,np.uint8);output,mask=self.engine.clean(image,[[30,30,190,60]])
  self.assertTrue(np.array_equal(image,output));self.assertEqual(int(mask.sum()),0)
if __name__=='__main__':unittest.main()
