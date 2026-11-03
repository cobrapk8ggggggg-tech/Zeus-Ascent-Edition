"""Download the user's exact chapter with pinned pixel provenance for iOS tests."""
import argparse,concurrent.futures,hashlib,json,pathlib,urllib.request,time
p=argparse.ArgumentParser();p.add_argument('--reuse');a=p.parse_args();here=pathlib.Path(__file__).resolve().parent;manifest=json.loads((here/'violet.json').read_text());out=here/'lab/output/violet';out.mkdir(parents=True,exist_ok=True)
def acquire(page):
 target=out/page['path'];reuse=pathlib.Path(a.reuse)/page['path']if a.reuse else target
 if reuse.exists()and hashlib.sha256(reuse.read_bytes()).hexdigest()==page['sha256']:data=reuse.read_bytes()
 else:
  for attempt in range(3):
   try:
    with urllib.request.urlopen(urllib.request.Request(page['url'],headers={'User-Agent':'Mozilla/5.0','Referer':manifest['source_url']}),timeout=40)as r:data=r.read()
    break
   except Exception:
    if attempt==2:raise
    time.sleep(1)
 if hashlib.sha256(data).hexdigest()!=page['sha256']:raise ValueError('Chapter pixels changed: '+page['path'])
 target.write_bytes(data);return len(data)
with concurrent.futures.ThreadPoolExecutor(max_workers=4)as pool:sizes=list(pool.map(acquire,manifest['pages']))
print('Verified Violet chapter:',len(sizes),'pages,',sum(sizes),'bytes')
