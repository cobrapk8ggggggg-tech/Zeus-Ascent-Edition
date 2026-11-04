"""Recover closed colour plates and enforce one owner per line, like ComicBalloons."""
import cv2,numpy as np
from run_geometry import group

def paragraphs(rgb,lines,include_layout=False,engine=None,include_cleanup=False,include_bounds=False,include_inside=False):
 h,w=rgb.shape[:2];cache={};plates=[];shapes={};colors={}
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
  exclusions=[[l['box'][0]-4,l['box'][1]-4,l['box'][2]+4,l['box'][3]+4]for l in lines]
  if engine is not None and not engine.plate_has_edge(rgb,shapes[tuple(result)],[xx-1,yy-1],exclusions):return None
  region=rgb[yy:bb,xx:rr][shapes[tuple(result)][1:-1,1:-1]>0]
  field=region.mean(axis=0);colors[tuple(result)]=engine.plate_color(rgb,shapes[tuple(result)],[xx-1,yy-1])if engine is not None else(np.round(field).astype(np.uint8),float((np.abs(region.astype(int)-field).sum(1)<=6).mean())>=.95)
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
  x,y,r,b=line['box'];matches=[i for i,p in enumerate(plates)if p[0]<=x and p[1]<=y and p[2]>=r and p[3]>=b]
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
  original_plate=p
  for p,g in lobes:
   if not g:continue
   flat=None
   if engine is not None:
    xx,yy,rr,bb=original_plate;origin=[xx-1,yy-1];paper=shapes[tuple(original_plate)];boxes=[]
    for line in g:
     a,c,d,f=line['box'];pad=max(8,min(d-a,f-c)*.3);boxes.append([int(np.floor(a-pad-xx+1)),int(np.floor(c-pad-yy+1)),int(np.ceil(d+pad-xx+1)),int(np.ceil(f+pad-yy+1))])
    mask,complete=engine.flat_balloon_mask(paper,boxes,[p[0]-xx+1,p[1]-yy+1,p[2]-xx+1,p[3]-yy+1])
    tight=[[l['box'][0]-xx+1,l['box'][1]-yy+1,l['box'][2]-xx+1,l['box'][3]-yy+1]for l in g]
    if complete:complete=engine.safe_to_letter(np.ascontiguousarray(rgb[yy-1:bb+1,xx-1:rr+1]),mask,tight)
    if complete or colors[tuple(original_plate)][1]:flat=dict(mask=mask,complete=complete,color=colors[tuple(original_plate)][0],uniform=colors[tuple(original_plate)][1],origin=origin,boxes=[l['box']for l in g])

   x,y,r,b=p;dx=(r-x)*.15;dy=(b-y)*.15
   area=[max(x+2,min(x+dx,min(l['box'][0]-3 for l in g))),max(y+2,min(y+dy,min(l['box'][1]-3 for l in g))),min(r-2,max(r-dx,max(l['box'][2]+3 for l in g))),min(b-2,max(b-dy,max(l['box'][3]+3 for l in g)))]
   inside=None
   if engine is not None:
    xx,yy,rr,bb=original_plate;local=[[l['box'][0]-xx+1,l['box'][1]-yy+1,l['box'][2]-xx+1,l['box'][3]-yy+1]for l in g]
    inside=engine.lettering_box(shapes[tuple(original_plate)],[p[0]-xx+1,p[1]-yy+1,p[2]-xx+1,p[3]-yy+1],local)
    if inside is not None:area=[inside[0]+xx-1,inside[1]+yy-1,inside[2]+xx-1,inside[3]+yy-1]
   result.append((sorted(g,key=lambda l:(l['box'][1],l['box'][0])),[int(v)for v in area],True,flat,list(p),inside is not None))
 for g in group(unplated):
  x=min(l['box'][0]for l in g);y=min(l['box'][1]for l in g);r=max(l['box'][2]for l in g);b=max(l['box'][3]for l in g);pad=max(3,min(r-x,b-y)*.12)
  result.append((g,[max(1,int(x-pad)),max(1,int(y-pad)),min(w-1,int(r+pad)),min(h-1,int(b+pad))],False,None,None,False))
 return result if include_inside else[row[:5]for row in result]if include_bounds else[row[:4]for row in result]if include_cleanup else[row[:3]for row in result]if include_layout else[row[:2]for row in result]
