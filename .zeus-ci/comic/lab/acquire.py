"""Acquire reproducible, original-resolution local fixtures; never commit chapters."""
import concurrent.futures, hashlib, json, pathlib, time, urllib.request, urllib.parse
from PIL import Image
ROOT=pathlib.Path(__file__).resolve().parents[3]

def fetch(url):
    for attempt in range(3):
        try:return urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'ZeusComicLab/1.0'}),timeout=45).read()
        except Exception:
            if attempt==2:raise
            time.sleep(attempt+1)

def acquire(root):
    root.mkdir(parents=True,exist_ok=True); manifest=root/'corpus.json'
    corpus=json.loads(manifest.read_text()) if manifest.exists() else {'version':1,'chapters':[]}
    for language in ['en','ja','ko','zh','ar']:
        existing=[c for c in corpus['chapters'] if c['language']==language]
        if len(existing)>=2:continue
        query=urllib.parse.urlencode({'limit':100,'translatedLanguage[]':language,'includeEmptyPages':0,'includeExternalUrl':0,'contentRating[]':'safe'})
        chapters=json.loads(fetch('https://api.mangadex.org/chapter?'+query))['data']
        selected={c['manga'] for c in existing}
        for chapter in chapters:
            a=chapter['attributes']; manga=next(r['id'] for r in chapter['relationships'] if r['type']=='manga')
            if manga in selected or not 6<=a['pages']<=45:continue
            cid=chapter['id']
            try:
                server=json.loads(fetch('https://api.mangadex.org/at-home/server/'+cid))
                names=server['chapter']['data']; base=server['baseUrl']+'/data/'+server['chapter']['hash']+'/'
                if not names:continue
                dest=root/language/cid;dest.mkdir(parents=True,exist_ok=True)
                def page(item):
                    index,name=item;url=base+name;p=dest/f'{index:03d}{pathlib.Path(name).suffix}'
                    if not p.exists():p.write_bytes(fetch(url))
                    with Image.open(p) as im:w,h=im.size;im.verify()
                    return dict(path=str(p.relative_to(root)),url=url,width=w,height=h,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                with concurrent.futures.ThreadPoolExecutor(4) as pool:pages=list(pool.map(page,enumerate(names)))
            except Exception as e:
                print('skip',language,cid,str(e),flush=True);continue
            entry=dict(id=cid,manga=manga,language=language,title=a.get('title'),chapter=a.get('chapter'),split='calibration' if not existing else 'holdout',source='https://mangadex.org/chapter/'+cid,pages=pages)
            corpus['chapters'].append(entry);existing.append(entry);selected.add(manga)
            manifest.write_text(json.dumps(corpus,ensure_ascii=False,indent=2));print('acquired',language,entry['split'],len(pages),entry['source'],flush=True)
            if len(existing)>=2:break
    counts={lang:len([c for c in corpus['chapters'] if c['language']==lang]) for lang in ['en','ja','ko','zh','ar']}
    print(json.dumps(counts));return corpus
if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser();p.add_argument('directory',type=pathlib.Path);args=p.parse_args();acquire(args.directory)
