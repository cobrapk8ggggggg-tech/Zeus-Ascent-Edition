"""Recover closed colour plates and enforce one owner per line, like ComicBalloons."""
import cv2,numpy as np
from run_geometry import group

def paragraphs(rgb,lines):
 h,w=rgb.shape[:2];cache={};plates=[]
 def plate(box):
  x,y,r,b=box
  xs=np.linspace(x+1,max(x+1,r-2),7).astype(int).clip(0,w-1);ys=np.linspace(y+1,max(y+1,b-2),7).astype(int).clip(0,h-1)
  samples=rgb[np.ix_(ys,xs)].reshape(-1,3);keys=(samples//32).astype(int);codes=keys[:,0]*64+keys[:,1]*8+keys[:,2];key=int(np.bincount(codes,minlength=512).argmax());bg=samples[codes==key].mean(axis=0)
  if key not in cache:
   if len(cache)>=4:cache.clear()
   mask=cv2.inRange(rgb,np.maximum(0,bg-25).astype(np.uint8),np.minimum(255,bg+25).astype(np.uint8));cache[key]=cv2.connectedComponentsWithStats(mask,4)
  count,labels,stats,_=cache[key]
  candidates=[]
  for label in np.unique(labels[np.ix_(ys,xs)]):
   if not label:continue
   xx,yy,ww,hh,area=map(int,stats[label]);rr=xx+ww;bb=yy+hh
   if xx<=0 or yy<=0 or rr>=w or bb>=h or area>800000:continue
   if xx<=x and yy<=y and rr>=r and bb>=b and area>(r-x)*(b-y)*.5:candidates.append([xx,yy,rr,bb])
  return max(candidates,key=lambda b:(b[2]-b[0])*(b[3]-b[1]))if candidates else None
 initial=group(lines)
 for g in initial:
  box=[min(l['box'][0]for l in g),min(l['box'][1]for l in g),max(l['box'][2]for l in g),max(l['box'][3]for l in g)]
  p=plate(box)
  if p is None:continue
  def overlaps(q):
   overlap=max(0,min(q[2],p[2])-max(q[0],p[0]))*max(0,min(q[3],p[3])-max(q[1],p[1]));return overlap>.7*min((q[2]-q[0])*(q[3]-q[1]),(p[2]-p[0])*(p[3]-p[1]))
  if not any(overlaps(q)for q in plates):plates.append(p)
 owned=[[]for _ in plates];unplated=[]
 for line in lines:
  x,y,r,b=line['box'];matches=[i for i,p in enumerate(plates)if p[0]+2<=x and p[1]+2<=y and p[2]-2>=r and p[3]-2>=b]
  if matches:owned[min(matches,key=lambda i:(plates[i][2]-plates[i][0])*(plates[i][3]-plates[i][1]))].append(line)
  else:unplated.append(line)
 result=[]
 for p,g in zip(plates,owned):
  if not g:continue
  x,y,r,b=p;dx=(r-x)*.15;dy=(b-y)*.15
  # Match the conservative nonrectangular plate inset used by the native path.
  area=[min(x+dx,min(l['box'][0]-3 for l in g)),min(y+dy,min(l['box'][1]-3 for l in g)),max(r-dx,max(l['box'][2]+3 for l in g)),max(b-dy,max(l['box'][3]+3 for l in g))]
  result.append((sorted(g,key=lambda l:(l['box'][1],l['box'][0])),[int(v)for v in area]))
 for g in group(unplated):
  x=min(l['box'][0]for l in g);y=min(l['box'][1]for l in g);r=max(l['box'][2]for l in g);b=max(l['box'][3]for l in g);pad=max(3,min(r-x,b-y)*.12)
  result.append((g,[max(1,int(x-pad)),max(1,int(y-pad)),min(w-1,int(r+pad)),min(h-1,int(b+pad))]))
 return result
