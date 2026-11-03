"""Independent post-clean truth: a supplied mask is not proof of erased text."""
import unittest,pathlib,json,io,base64
import cv2,numpy as np
from PIL import Image,ImageDraw,ImageFont
from engine import Engine
from balloons import paragraphs
class CleanupQuality(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.engine=Engine(pathlib.Path(__file__).parent/'models')
 def test_source_and_partial_source_are_rejected_but_clean_gradient_is_accepted(self):
  h,w=160,420;clean=np.repeat(np.repeat((225+np.arange(h)[:,None,None]*.1).astype(np.uint8),w,1),3,2);im=Image.fromarray(clean);d=ImageDraw.Draw(im);font=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',32);box=d.textbbox((40,50),'HELLO WORLD',font=font);d.text((40,50),'HELLO WORLD',font=font,fill='black');source=np.array(im);mask=np.zeros((h,w),np.uint8);l,t,r,b=box;mask[t-3:b+3,l-3:r+3]=255
  self.assertGreater(self.engine.ink_residue(source,source,mask,[box]),.9)
  partial=source.copy();partial[:,:160]=clean[:,:160];self.assertGreater(self.engine.ink_residue(source,partial,mask,[box]),.08)
  incomplete_mask=mask.copy();incomplete_mask[:,160:]=0;self.assertGreater(self.engine.ink_residue(source,partial,incomplete_mask,[box]),.08,"Missing mask strokes must still fail post-clean validation")
  self.assertLess(self.engine.ink_residue(source,clean,mask,[box]),.01)
 def test_real_failed_restoration_cannot_be_approved(self):
  f=json.loads((pathlib.Path(__file__).parent/'fixtures/neural-remaining-caption.json').read_text());decode=lambda key:np.array(Image.open(io.BytesIO(base64.b64decode(f[key]))).convert('RGB'));source=decode('image');bad=decode('badRestoration');mask=decode('mask')[:,:,0].copy();boxes=[[l['x'],l['y'],l['x']+l['width'],l['y']+l['height']]for l in f['lines']]
  self.assertGreater(self.engine.ink_residue(source,bad,mask,boxes),.5)
 def test_gradient_contours_do_not_split_one_real_caption(self):
  f=json.loads((pathlib.Path(__file__).parent/'fixtures/neural-gradient-caption.json').read_text());rgb=np.array(Image.open(io.BytesIO(base64.b64decode(f['image']))).convert('RGB'));lines=[dict(box=[l['x'],l['y'],l['x']+l['width'],l['y']+l['height']],confidence=1,text=l['text'])for l in f['lines']]
  groups=paragraphs(rgb,lines,True,self.engine);self.assertEqual(len(groups),1);self.assertEqual(len(groups[0][0]),4)
 def test_true_outline_is_accepted_and_smooth_colour_contour_is_rejected(self):
  h,w=300,360;yy,xx=np.mgrid[:h,:w];distance=np.sqrt((xx-180)**2+(yy-150)**2);gray=np.clip(245-distance*.55,0,255).astype(np.uint8);rgb=np.repeat(gray[:,:,None],3,2);paper=(distance<100).astype(np.uint8)*255
  self.assertFalse(self.engine.plate_has_edge(rgb,paper,[0,0],[]))
  im=Image.new('RGB',(w,h),(20,35,70));d=ImageDraw.Draw(im);d.ellipse((80,50,280,250),fill='white',outline='black',width=3);rgb=np.array(im);paper=(rgb.min(2)>240).astype(np.uint8)*255
  self.assertTrue(self.engine.plate_has_edge(rgb,paper,[0,0],[]))
 def test_preserved_radial_frame_is_not_counted_as_surviving_glyphs(self):
  f=json.loads((pathlib.Path(__file__).parent/'fixtures/neural-staggered-columns.json').read_text());decode=lambda key:np.array(Image.open(io.BytesIO(base64.b64decode(f[key]))).convert('RGB'));source=decode('image');clean=decode('goodRestoration');mask=np.full(source.shape[:2],255,np.uint8);boxes=[[l['x'],l['y'],l['x']+l['width'],l['y']+l['height']]for l in f['lines']]
  self.assertLessEqual(self.engine.ink_residue(source,clean,mask,boxes),.08)
  self.assertGreater(self.engine.ink_residue(source,source,mask,boxes),.9)
if __name__=='__main__':unittest.main()
