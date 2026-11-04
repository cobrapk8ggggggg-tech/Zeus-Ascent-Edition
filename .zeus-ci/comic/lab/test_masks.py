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
    self.assertTrue(self.engine.safe_to_letter(source,mask,[box]),'known complete text mask must permit lettering')
    changed=np.any(source!=restored,axis=2)
    self.assertEqual(int(np.count_nonzero(changed&(mask==0))),0)
    self.assertEqual(int(np.count_nonzero((source!=clean).any(axis=2)&(mask==0))),0,'mask must cover all source ink and outlines')
    error=float(difference.max());errors.append(error);self.assertLess(error,8,'no visible source remnants on known clean background')
  print('independent known-background maximum errors:',errors)
 def test_colored_balloons_have_no_source_ink_residue(self):
  font=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',28)
  for color in [(20,40,85),(225,200,100),(25,10,35),(210,35,30)]:
   clean=np.zeros((120,360,3),np.uint8);clean[:]=color;image=Image.fromarray(clean);draw=ImageDraw.Draw(image)
   light=sum(color)/3<128
   draw.text((40,40),'HELLO WORLD',font=font,fill=(245,)*3 if light else(8,)*3,stroke_width=2,stroke_fill=(5,)*3 if light else(250,)*3)
   source=np.asarray(image);box=draw.textbbox((40,40),'HELLO WORLD',font=font,stroke_width=2)
   output,mask=self.engine.clean(source,[box])
   self.assertLess(int(np.abs(output.astype(int)-clean.astype(int)).max()),4)
   self.assertTrue(self.engine.safe_to_letter(source,mask,[box]))
 def test_missing_balloon_line_must_not_be_overpainted(self):
  image=Image.new('RGB',(400,240),'white');draw=ImageDraw.Draw(image);font=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',30)
  draw.text((80,35),'HELLO',font=font,fill='black');draw.text((30,140),'OTHER LINE',font=font,fill='black')
  rgb=np.asarray(image);known=draw.textbbox((80,35),'HELLO',font=font);missing=draw.textbbox((30,140),'OTHER LINE',font=font);area=[10,10,390,230]
  self.assertFalse(self.engine.owns_text(rgb,[known],area),'unrecognized source line must block the entire balloon')
  self.assertTrue(self.engine.owns_text(rgb,[known,missing],area),'a fully recognized balloon must remain usable')
 def test_empty_mask_is_identity(self):
  image=np.full((100,240,3),180,np.uint8);output,mask=self.engine.clean(image,[[30,30,190,60]])
  self.assertTrue(np.array_equal(image,output));self.assertEqual(int(mask.sum()),0)
  self.assertFalse(self.engine.safe_to_letter(image,mask,[[30,30,190,60]]))

 def test_dense_mask_does_not_accept_solid_hints_or_a_frame(self):
  rgb=np.full((120,360,3),240,np.uint8);im=Image.fromarray(rgb);d=ImageDraw.Draw(im);font=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',36);box=d.textbbox((40,40),'GLOWING TEXT',font=font);d.text((40,40),'GLOWING TEXT',font=font,fill='black');rgba=np.ascontiguousarray(cv2.cvtColor(np.array(im),cv2.COLOR_RGB2RGBA));mask=np.zeros(rgb.shape[:2],np.uint8);l,t,r,b=box;mask[t:b,l:r]=255
  solid=mask.copy();frame=np.zeros_like(mask);frame[t:b,l]=255;frame[t:b,r-1]=255;frame[t,l:r]=255;frame[b-1,l:r]=255
  for hint in [solid,frame]:self.assertFalse(self.engine.lib.neural_valid(rgba,hint,mask,360,120,*box),'A dense erase needs glyph-shaped evidence, not a rectangle or panel frame')

if __name__=='__main__':unittest.main()
