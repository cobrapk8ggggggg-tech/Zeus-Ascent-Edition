import argparse,hashlib,json,pathlib,urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[3]
def download(destination,comparison=False):
 destination.mkdir(parents=True,exist_ok=True)
 artifacts=json.loads((ROOT/'ZEUSNext/Resources/comic-models.json').read_text())['models']
 if comparison:artifacts+=json.loads((pathlib.Path(__file__).parent/'comparison-models.json').read_text())
 for a in artifacts:
  if not comparison and a['name'].split('.')[0] not in ['det','latin','han','korean','arabic']:continue
  p=destination/a['name']
  if not p.exists():
   part=p.with_suffix(p.suffix+'.part');urllib.request.urlretrieve(a['url'],part);part.replace(p)
  b=p.read_bytes()
  if len(b)!=a['bytes'] or hashlib.sha256(b).hexdigest()!=a['sha256']:raise ValueError('model verification failed: '+a['name'])
  print(a['name'],'verified',flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('directory',type=pathlib.Path);p.add_argument('--comparison',action='store_true');a=p.parse_args();download(a.directory,a.comparison)
