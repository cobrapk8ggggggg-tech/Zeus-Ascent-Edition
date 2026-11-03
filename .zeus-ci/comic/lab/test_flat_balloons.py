"""Flat balloon cleanup has independent pixel truth and never crosses borders."""
import pathlib,unittest
import cv2,numpy as np
from PIL import Image,ImageDraw,ImageFont
from engine import Engine
class FlatBalloons(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.engine=Engine(pathlib.Path(__file__).parent/'models')
 def sample(self,color,rectangular=False,missing=False):
  clean=Image.new('RGB',(400,300),(25,45,80));d=ImageDraw.Draw(clean)
  if rectangular:d.rectangle((30,20,370,280),fill=color,outline='black',width=3)
  else:d.ellipse((30,20,370,280),fill=color,outline='black',width=3)
  source=clean.copy();d=ImageDraw.Draw(source);font=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',27);boxes=[]
  for y,text in [(75,'HELLO'),(120,'SECOND LINE'),(165,'GOODBYE')]:
   box=d.textbbox((85,y),text,font=font);d.text((85,y),text,font=font,fill='white'if sum(color)<300 else'black');boxes.append(box)
  rgb=np.array(source);match=(np.abs(rgb.astype(int)-color).sum(2)<75).astype(np.uint8);_,labels,_,_=cv2.connectedComponentsWithStats(match,4);paper=(labels==labels[45,190]).astype(np.uint8)*255
  owned=[]
  for l,t,r,b in boxes[:2]if missing else boxes:
   pad=max(8,min(r-l,b-t)*.3);owned.append([int(l-pad),int(t-pad),int(r+pad),int(b+pad)])
  mask,complete=self.engine.flat_balloon_mask(paper,owned);result=rgb.copy()
  if complete:result[mask>0]=color
  return np.array(clean),rgb,result,mask,complete
 def test_flat_white_coloured_and_dark_balloons_need_no_neural_model(self):
  for color in [(255,255,255),(235,205,140),(25,10,40)]:
   for rectangular in [False,True]:
    clean,original,result,mask,complete=self.sample(color,rectangular)
    self.assertTrue(complete);self.assertLessEqual(int(np.abs(result.astype(int)-clean.astype(int)).max()),3)
    self.assertEqual(int(np.count_nonzero(np.any(original!=result,axis=2)&(mask==0))),0)
    self.assertTrue(np.array_equal(result[20,:],clean[20,:]),'balloon border must remain exact')
 def test_transparent_balloon_keeps_the_visible_gradient_without_a_model(self):
  h,w=300,400;values=np.linspace(222,248,h)[:,None,None];clean=np.repeat(np.repeat(values,w,axis=1),3,axis=2).astype(np.uint8)
  shape=Image.new('L',(w,h));d=ImageDraw.Draw(shape);d.ellipse((25,15,375,285),fill=255)
  clean[np.array(shape)==0]=(25,45,80);image=Image.fromarray(clean);draw=ImageDraw.Draw(image);draw.ellipse((25,15,375,285),outline='black',width=3);clean=np.array(image)
  source=image.copy();draw=ImageDraw.Draw(source);font=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',27);boxes=[]
  for y,text in [(75,'HELLO'),(120,'SECOND LINE'),(165,'GOODBYE')]:boxes.append(draw.textbbox((85,y),text,font=font));draw.text((85,y),text,font=font,fill='black')
  rgb=np.array(source);match=(np.abs(rgb.astype(int)-235).sum(2)<75).astype(np.uint8);_,labels,_,_=cv2.connectedComponentsWithStats(match,4);paper=(labels==labels[45,190]).astype(np.uint8)*255
  owned=[[l-8,t-8,r+8,b+8]for l,t,r,b in boxes];mask,complete=self.engine.flat_balloon_mask(paper,owned);self.assertTrue(complete)
  flat=dict(mask=mask,complete=complete,color=np.array([235]*3),uniform=False,origin=[0,0],boxes=boxes)
  result,mask,accepted=self.engine.apply_flat_cleanup(rgb,[0,0],flat);self.assertTrue(accepted)
  self.assertLess(int(np.abs(result.astype(int)-clean.astype(int)).max()),8)
  self.assertEqual(int(np.count_nonzero(np.any(rgb!=result,axis=2)&(mask==0))),0)
 def test_attached_white_outline_is_preserved_outside_the_dialogue(self):
  clean=Image.new('RGB',(400,320),(25,45,80));draw=ImageDraw.Draw(clean);draw.ellipse((80,90,320,305),fill='white');draw.line((130,68,150,115),fill='white',width=2);draw.ellipse((105,22,151,68),outline='white',width=5)
  source=clean.copy();draw=ImageDraw.Draw(source);font=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',27);box=draw.textbbox((140,160),'HELLO',font=font);draw.text((140,160),'HELLO',font=font,fill='black')
  rgb=np.array(source);match=(np.abs(rgb.astype(int)-255).sum(2)<75).astype(np.uint8);_,labels,_,_=cv2.connectedComponentsWithStats(match,4);paper=(labels==labels[120,200]).astype(np.uint8)*255
  l,t,r,b=box;mask,complete=self.engine.flat_balloon_mask(paper,[[l-8,t-8,r+8,b+8]]);self.assertTrue(complete)
  result=rgb.copy();result[mask>0]=255
  self.assertTrue(np.array_equal(result[:80],rgb[:80]),'The attached ornament must remain original')
  self.assertLessEqual(int(np.abs(result.astype(int)-np.array(clean).astype(int)).max()),3)
 def test_missing_source_line_blocks_erasure_and_leaves_identity(self):
  clean,original,result,mask,complete=self.sample((255,255,255),missing=True)
  self.assertFalse(complete);self.assertFalse(mask.any());self.assertTrue(np.array_equal(original,result))
if __name__=='__main__':unittest.main()
