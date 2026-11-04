"""Independent ownership and colour truth for joined bubbles and source outlines."""
import base64,io,json,pathlib,unittest
import cv2,numpy as np
from PIL import Image,ImageDraw,ImageFont
from engine import Engine
from balloons import paragraphs
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
 def test_a_thick_outline_cannot_replace_thin_black_letter_cores(self):
  font=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',50)
  alpha=Image.new('L',(450,130));draw=ImageDraw.Draw(alpha);draw.text((30,25),'HELLO',font=font,fill=255)
  alpha=np.array(alpha);kernel=cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(7,7));outer=cv2.dilate(alpha,kernel);inner=cv2.erode(alpha,kernel)
  source=np.zeros((130,450,3),np.float32);source[:]=(65,100,150);a=outer[:,:,None]/255;source=source*(1-a)+255*a;a=inner[:,:,None]/255;source=source*(1-a)
  yy,xx=np.where(outer>0);box=[int(xx.min()),int(yy.min()),int(xx.max()+1),int(yy.max()+1)];self.assertGreater(int((inner>240).sum()),12)
  style=self.engine.ink_style(source.astype(np.uint8),[box]);self.assertIsNotNone(style['stroke']);self.assertLess(max(style['fill']),15);self.assertGreater(min(style['stroke']),235)
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
 def test_staggered_real_connected_balloons_have_two_text_owners(self):
  f=json.loads((pathlib.Path(__file__).parent/'fixtures/neural-connected-staggered.json').read_text())
  rgb=np.array(Image.open(io.BytesIO(base64.b64decode(f['image']))).convert('RGB'))
  lines=[dict(text=l['text'],confidence=1,box=[l['x'],l['y'],l['x']+l['width'],l['y']+l['height']])for l in f['lines']]
  groups=paragraphs(rgb,lines,True,self.engine)
  self.assertEqual(len(groups),2)
  self.assertEqual([len(g[0])for g in groups],[5,5])
  self.assertTrue(all(g[2]for g in groups))
  self.assertLessEqual(groups[0][1][3],groups[1][1][1])
  paper=(rgb.min(2)>230).astype(np.uint8)*255;_,labels,_,_=cv2.connectedComponentsWithStats(paper,4);l,t,r,b=lines[0]['box'];ids,hits=np.unique(labels[t:b,l:r],return_counts=True);owner=max(((n,i)for i,n in zip(ids,hits)if i),default=(0,0))[1];paper=(labels==owner).astype(np.uint8)*255;flood=paper.copy();cv2.floodFill(flood,None,(0,0),255);filled=(paper>0)|(flood==0)
  for rows,area,closed in groups:
   l,t,r,b=map(int,area);self.assertTrue(filled[t:b,l:r].all(),'A lettering rectangle must not cross the real frame or enter the other white panel')
 def test_japanese_column_order_cannot_drop_a_recognized_column(self):
  from run_geometry import group
  f=json.loads((pathlib.Path(__file__).parent/'fixtures/neural-staggered-columns.json').read_text())
  lines=[dict(text=l['text'],confidence=1,box=[l['x'],l['y'],l['x']+l['width'],l['y']+l['height']])for l in f['lines']]
  for order in [lines,list(reversed(lines)),lines[2:]+lines[:2]]:
   groups=group(order);self.assertEqual(len(groups),1);self.assertEqual(len(groups[0]),4)
  separate=[dict(text='separate',confidence=1,box=[390,60,440,280])]
  self.assertEqual(len(group(lines+separate)),2)
 def test_maximum_paper_rectangle_does_not_collapse_to_a_thin_strip(self):
  paper=np.zeros((400,400),np.uint8);cv2.circle(paper,(200,200),150,255,-1)
  boxes=[[150,150,200,175],[180,195,240,220]];area=self.engine.lettering_box(paper,[1,1,399,399],boxes)
  self.assertIsNotNone(area);l,t,r,b=area;self.assertGreater((r-l)*(b-t),40000);self.assertTrue((paper[t:b,l:r]>0).all())
  for a,c,d,f in boxes:self.assertTrue(l<=(a+d)/2<r and t<=(c+f)/2<b)
 def test_recognized_column_near_frame_keeps_its_balloon_width(self):
  f=json.loads((pathlib.Path(__file__).parent/'fixtures/neural-near-frame-column.json').read_text())
  rgb=np.array(Image.open(io.BytesIO(base64.b64decode(f['image']))).convert('RGB'))
  lines=[dict(text=l['text'],confidence=1,box=[l['x'],l['y'],l['x']+l['width'],l['y']+l['height']])for l in f['lines']]
  groups=paragraphs(rgb,lines,True,self.engine,True,True);self.assertEqual(len(groups),1)
  rows,area,closed,flat,physical=groups[0];self.assertTrue(closed);self.assertGreater(area[2]-area[0],90)
  self.assertTrue(flat['uniform']);self.assertTrue(flat['complete'])
  clean,mask,accepted=self.engine.apply_flat_cleanup(rgb,[0,0],flat);self.assertTrue(accepted)
  self.assertLessEqual(self.engine.ink_residue(rgb,clean,mask,[l['box']for l in rows]),.08)
  self.assertEqual(np.count_nonzero(np.any(rgb!=clean,axis=2)&(mask==0)),0)
 def test_only_a_recovered_balloon_certifies_expanded_neural_masks(self):
  f=json.loads((pathlib.Path(__file__).parent/'fixtures/neural-near-frame-column.json').read_text());rgb=np.array(Image.open(io.BytesIO(base64.b64decode(f['image']))).convert('RGB'))
  lines=[dict(text=l['text'],confidence=1,box=[l['x'],l['y'],l['x']+l['width'],l['y']+l['height']])for l in f['lines']]
  self.assertTrue(paragraphs(rgb,lines,True,self.engine,True,True,True)[0][5])
  open_caption=np.full((200,300,3),255,np.uint8)
  lines=[dict(text='CAPTION',confidence=1,box=[80,70,220,110])]
  group=paragraphs(open_caption,lines,True,self.engine,True,True,True)[0]
  self.assertFalse(group[2]);self.assertFalse(group[5],'An open field must not authorize an expanded paper mask')
if __name__=='__main__':unittest.main()
