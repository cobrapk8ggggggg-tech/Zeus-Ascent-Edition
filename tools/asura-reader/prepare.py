"""Pinned original pixels from the reported chapter; no generated test artwork."""
import concurrent.futures,hashlib,json,pathlib,urllib.request,time
here=pathlib.Path(__file__).resolve().parent
manifest=json.loads((here/'manifest.json').read_text());out=here/'images';out.mkdir(exist_ok=True)
def acquire(p):
 target=out/p['path']
 for attempt in range(3):
  try:
   data=target.read_bytes()if target.exists()else urllib.request.urlopen(urllib.request.Request(p['url'],headers={'User-Agent':'Mozilla/5.0','Referer':manifest['source_url']}),timeout=45).read()
   if hashlib.sha256(data).hexdigest()!=p['sha256']:raise ValueError('Changed chapter pixels: '+p['path'])
   target.write_bytes(data);return len(data)
  except Exception:
   if attempt==2:raise
   time.sleep(attempt+1)
with concurrent.futures.ThreadPoolExecutor(max_workers=4)as pool:sizes=list(pool.map(acquire,manifest['pages']))
markup=''.join('<img data-page-index="'+str(p['index'])+'" src="images/'+p['path']+'" width="'+str(p['width'])+'" height="'+str(p['height'])+'" style="width:100%;height:auto;display:block" loading="lazy">'for p in manifest['pages'])
(out.parent/'index.html').write_text('<meta name="viewport" content="width=device-width,initial-scale=1"><title>Asura original chapter 2</title><body style="margin:0;background:black"><main id="readerarea">'+markup+'</main>')
print('Verified Asura:',len(sizes),'pages,',sum(sizes),'bytes')
