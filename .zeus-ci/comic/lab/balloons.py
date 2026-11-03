"""Recover closed colour plates and enforce one owner per line, like ComicBalloons."""
import cv2,numpy as np
from run_geometry import group

def paragraphs(rgb,lines,include_layout=False,engine=None):
 h,w=rgb.shape[:2];cache={};plates=[];shapes={}
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
  if not candidates:return None
  result=max(candidates,key=lambda b:(b[2]-b[0])*(b[3]-b[1]));xx,yy,rr,bb=result
  label=next(int(label)for label in np.unique(labels[np.ix_(ys,xs)])if label and list(map(int,stats[label,:4]))==[xx,yy,rr-xx,bb-yy])
  shapes[tuple(result)]=np.pad((labels[yy:bb,xx:rr]==label).astype(np.uint8)*255,1)
  return result
 initial=group(lines)
 for g in initial+[[line]for line in lines]:
  box=[min(l['box'][0]for l in g),min(l['box'][1]for l in g),max(l['box'][2]for l in g),max(l['box'][3]for l in g)]
  p=plate(box)
  if p is None:continue
  def overlaps(q):
   overlap=max(0,min(q[2],p[2])-max(q[0],p[0]))*max(0,min(q[3],p[3])-max(q[1],p[1]));return overlap>.7*min((q[2]-q[0])*(q[3]-q[1]),(p[2]-p[0])*(p[3]-p[1]))
  matches=[i for i,q in enumerate(plates)if overlaps(q)]
  if not matches:plates.append(p)
  elif (p[2]-p[0])*(p[3]-p[1])>max((plates[i][2]-plates[i][0])*(plates[i][3]-plates[i][1])for i in matches):plates[matches[0]]=p
 owned=[[]for _ in plates];unplated=[]
 for line in lines:
  x,y,r,b=line['box'];matches=[i for i,p in enumerate(plates)if p[0]+2<=x and p[1]+2<=y and p[2]-2>=r and p[3]-2>=b]
  if matches:owned[min(matches,key=lambda i:(plates[i][2]-plates[i][0])*(plates[i][3]-plates[i][1]))].append(line)
  else:unplated.append(line)
 result=[]
 for p,g in zip(plates,owned):
  if not g:continue
  lobes=[(p,g)]
  if engine is not None:
   x,y,r,b=p;local=[[l['box'][0]-x+1,l['box'][1]-y+1,l['box'][2]-x+1,l['box'][3]-y+1]for l in g]
   owners,bounds=engine.balloon_lobes(shapes[tuple(p)],local)
   if len(bounds)>1:lobes=[([int(q[0]+x-1),int(q[1]+y-1),int(q[2]+x-1),int(q[3]+y-1)],[line for i,line in enumerate(g)if owners[i]==j])for j,q in enumerate(bounds)]
  for p,g in lobes:
   if not g:continue
   x,y,r,b=p;dx=(r-x)*.15;dy=(b-y)*.15
   area=[max(x+2,min(x+dx,min(l['box'][0]-3 for l in g))),max(y+2,min(y+dy,min(l['box'][1]-3 for l in g))),min(r-2,max(r-dx,max(l['box'][2]+3 for l in g))),min(b-2,max(b-dy,max(l['box'][3]+3 for l in g)))]
   result.append((sorted(g,key=lambda l:(l['box'][1],l['box'][0])),[int(v)for v in area],True))
 for g in group(unplated):
  x=min(l['box'][0]for l in g);y=min(l['box'][1]for l in g);r=max(l['box'][2]for l in g);b=max(l['box'][3]for l in g);pad=max(3,min(r-x,b-y)*.12)
  result.append((g,[max(1,int(x-pad)),max(1,int(y-pad)),min(w-1,int(r+pad)),min(h-1,int(b+pad))],False))
 return result if include_layout else[(g,area)for g,area,_ in result]
