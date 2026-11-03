"""Prepare a language shard of the frozen corpus without changing source hashes."""
import argparse,hashlib,json,pathlib,subprocess,sys,urllib.request
REPO=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'.zeus-ci/comic/lab'))
from acquire import restore
p=argparse.ArgumentParser();p.add_argument('--language',required=True,choices=['en','ja','ko','zh','ar']);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--reuse-data',type=pathlib.Path);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
corpus=json.loads((REPO/'docs/comic-translation/lab/corpus.json').read_text())
if a.language=='en':
 violet=json.loads((REPO/'.zeus-ci/comic/violet.json').read_text())
 pages=[dict(page,path='violet/'+page['path'])for page in violet['pages']]
 corpus['chapters'].append(dict(id='violet-broken-ring-1',language='en',split='reported',source=violet['source_url'],chapter='1',pages=pages))
 if not a.reuse_data:
  subprocess.run([sys.executable,str(REPO/'.zeus-ci/comic/prepare_violet.py')],check=True)
  for page in violet['pages']:
   destination=a.output/'violet'/page['path'];destination.parent.mkdir(parents=True,exist_ok=True)
   if not destination.exists():destination.symlink_to(REPO/'.zeus-ci/comic/lab/output/violet'/page['path'])
corpus['chapters']=[c for c in corpus['chapters']if c['language']==a.language]
for chapter in corpus['chapters']:
 if chapter['id']not in ['comix-148','violet-broken-ring-1']and not a.reuse_data:
  try:
   req=urllib.request.Request('https://api.mangadex.org/at-home/server/'+chapter['id'],headers={'User-Agent':'ZeusComicLab/1.0'})
   with urllib.request.urlopen(req,timeout=30)as response:fresh=json.load(response)
   names=fresh['chapter']['data']
   if len(names)==len(chapter['pages']):
    for page,name in zip(chapter['pages'],names):page['url']=fresh['baseUrl']+'/data/'+fresh['chapter']['hash']+'/'+name
  except Exception as error:print('Using pinned CDN URLs:',type(error).__name__,flush=True)
 if a.reuse_data:
  for page in chapter['pages']:
   destination=a.output/page['path'];destination.parent.mkdir(parents=True,exist_ok=True)
   if not destination.exists():destination.symlink_to((a.reuse_data/page['path']).resolve())
manifest=a.output/'shard.json';manifest.write_text(json.dumps(corpus,ensure_ascii=False,indent=2));restore(a.output,manifest)
probe=dict(version=1,app_source_commit='f640c8786f41507a0f3eb45b37aef5240dc180f5',probe_source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip(),quota=40,translation_engine='google',simulator_memory_guard_bypassed=True,chapters=corpus['chapters'])
(a.output/'native-manifest.json').write_text(json.dumps(probe,ensure_ascii=False,indent=2)+'\n');print('Native shard',a.language,'pages',sum(len(c['pages'])for c in corpus['chapters']))
