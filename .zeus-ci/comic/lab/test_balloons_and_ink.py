"""Independent ownership and colour truth for joined bubbles and source outlines."""
import base64,io,json,pathlib,unittest
import cv2,numpy as np
from PIL import Image,ImageDraw,ImageFont
from engine import Engine
class BalloonsAndInk(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.engine=Engine(pathlib.Path(__file__).parent/'models')
 def test_necks_split_horizontal_vertical_diagonal_and_three_lobes(self):
  for centers,boxes in [([(100,100),(100,290)],[[55,80,145,110],[55,270,145,300]]), ([(100,100),(290,100)],[[55,80,145,110],[245,80,335,110]]), ([(100,100),(270,270)],[[55,80,145,110],[225,250,315,280]]), ([(100,100),(290,100),(480,100)],[[55,80,145,110],[245,80,335,110],[435,80,525,110]])]:
   mask=np.zeros((400,600),np.uint8)
   for c in centers:cv2.circle(mask,c,85,255,-1)
   for a,b in zip(centers,centers[1:]):cv2.line(mask,a,b,255,12)
   owners,bounds=self.engine.balloon_lobes(mask,boxes)
   self.assertEqual(len(bounds),len(centers));self.assertEqual(len(set(owners)),len(boxes))
   for i,box in enumerate(boxes):
    l,t,r,b=bounds[owners[i]];self.assertTrue(l<=box[0] and t<=box[1] and r>=box[2] and b>=box[3])
 def test_single_multiline_cloud_and_tail_have_one_owner(self):
  for shape in ['ellipse','cloud','tail']:
   mask=np.zeros((400,400),np.uint8);cv2.ellipse(mask,(200,180),(140,150),0,0,360,255,-1)
   if shape=='cloud':
    for theta in np.linspace(0,2*np.pi,16,endpoint=False):cv2.circle(mask,(int(200+120*np.cos(theta)),int(180+130*np.sin(theta))),36,255,-1)
   if shape=='tail':cv2.fillPoly(mask,[np.array([[90,250],[25,365],[150,300]],np.int32)],255)
   # Ink holes must never split one paragraph into separate translation requests.
   boxes=[[140,95,260,120],[130,135,270,160],[140,175,260,200],[155,215,245,240]]
   for l,t,r,b in boxes:cv2.rectangle(mask,(l+5,t+3),(r-5,b-3),0,-1)
   owners,bounds=self.engine.balloon_lobes(mask,boxes)
   self.assertEqual(len(bounds),1,shape);self.assertTrue(np.all(owners==0),shape)
 def test_real_wide_diagonal_join_keeps_each_dialogue(self):
  f=json.loads((pathlib.Path(__file__).parent/'fixtures/neural-connected.json').read_text());rgb=np.array(Image.open(io.BytesIO(base64.b64decode(f['image']))).convert('RGB'))
  paper=(np.abs(rgb.astype(int)-255).sum(2)<75).astype(np.uint8);_,labels,stats,_=cv2.connectedComponentsWithStats(paper,4)
  label=labels[155,235];x,y,w,h,_=stats[label];mask=np.pad((labels[y:y+h,x:x+w]==label).astype(np.uint8)*255,1)
  boxes=[[l['x']-x+1,l['y']-y+1,l['x']+l['width']-x+1,l['y']+l['height']-y+1]for l in f['lines']]
  owners,bounds=self.engine.balloon_lobes(mask,boxes)
  self.assertEqual(len(bounds),2);self.assertEqual(len(set(owners[:3])),1);self.assertEqual(len(set(owners[3:])),1);self.assertNotEqual(owners[0],owners[3])
 def test_original_fill_and_outline_across_colours_and_sizes(self):
  for size in [24,40,64]:
   font=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',size)
   for fill,stroke in [((0,0,0),(255,255,255)),((255,255,255),(0,0,0)),((210,20,40),(255,255,255)),((240,200,30),(0,0,0))]:
    im=Image.new('RGB',(500,150),(75,110,150));draw=ImageDraw.Draw(im);sw=max(1,round(size*.06));box=draw.textbbox((30,30),'HELLO',font=font,stroke_width=sw);draw.text((30,30),'HELLO',font=font,fill=fill,stroke_fill=stroke,stroke_width=sw)
    style=self.engine.ink_style(np.array(im),[box]);self.assertIsNotNone(style['stroke'],(size,fill,style));self.assertLess(max(abs(a-b)for a,b in zip(style['fill'],fill)),12);self.assertLess(max(abs(a-b)for a,b in zip(style['stroke'],stroke)),12)
 def test_real_ink_ignores_antialias_ramp_but_keeps_halftone_halo(self):
  for filename,outlined in [('neural-connected.json',False),('neural-halftone-style.json',True)]:
   f=json.loads((pathlib.Path(__file__).parent/'fixtures'/filename).read_text());rgb=np.array(Image.open(io.BytesIO(base64.b64decode(f['image']))).convert('RGB'));boxes=[[l['x'],l['y'],l['x']+l['width'],l['y']+l['height']]for l in f['lines']]
   style=self.engine.ink_style(rgb,boxes);self.assertGreater(style['confidence'],.65);self.assertLess(max(style['fill']),20)
   if outlined:self.assertIsNotNone(style['stroke']);self.assertGreater(min(style['stroke']),235)
   else:self.assertIsNone(style['stroke'],'grey raster antialiasing must not become an outline')
 def test_plain_ink_does_not_acquire_an_outline(self):
  font=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',40)
  for bg,fill in [((255,)*3,(0,)*3),((0,)*3,(255,)*3),((90,120,170),(210,20,40))]:
   im=Image.new('RGB',(400,130),bg);draw=ImageDraw.Draw(im);box=draw.textbbox((30,30),'HELLO',font=font);draw.text((30,30),'HELLO',font=font,fill=fill)
   style=self.engine.ink_style(np.array(im),[box]);self.assertIsNone(style['stroke'],style);self.assertLess(max(abs(a-b)for a,b in zip(style['fill'],fill)),12)
if __name__=='__main__':unittest.main()
