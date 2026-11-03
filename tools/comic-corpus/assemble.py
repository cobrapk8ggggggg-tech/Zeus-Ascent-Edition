"""Convert exported native XCTest attachments into a stand-alone pixel review."""
import argparse,html,json,pathlib,shutil
p=argparse.ArgumentParser();p.add_argument('results',type=pathlib.Path);a=p.parse_args();screens=a.results/'screenshots';out=a.results/'review';out.mkdir(exist_ok=True)
manifest=json.loads((screens/'manifest.json').read_text());attachments=[item for test in manifest for item in test.get('attachments',[])];friendly=lambda x:x.get('suggestedHumanReadableName','').split('_0_')[0]
def get_json(prefix):
 item=next(x for x in attachments if friendly(x).startswith(prefix));return json.loads((screens/item['exportedFileName']).read_text())
if not any(friendly(x).startswith('native-corpus-cases')for x in attachments):
 (out/'report.json').write_text(json.dumps(dict(status='native test did not export corpus cases',quality_acceptance_proven=False),indent=2));raise SystemExit('No corpus result; inspect native.log and summary.json')
cases=get_json('native-corpus-cases');pages=get_json('native-corpus-pages');provenance=get_json('native-corpus-provenance')
rows=[]
for case in cases:
 directory=out/case['id'];directory.mkdir(exist_ok=True)
 for name in ['original','clean','rendered']:
  item=next(x for x in attachments if friendly(x)==case['id']+'-'+name);shutil.copy2(screens/item['exportedFileName'],directory/(name+'.png'))
 images=''.join('<figure><figcaption>'+name+'</figcaption><a target="_blank" href="'+case['id']+'/'+name+'.png"><img loading="lazy" src="'+case['id']+'/'+name+'.png"></a></figure>'for name in ['original','clean','rendered'])
 rows.append('<article><h2>'+case['id']+' · '+case['route']+'</h2><p>'+html.escape(case['speech']['text'])+'</p><p>'+html.escape(case['translation'])+'</p><p>'+html.escape(case['translation_source']+' / '+case['note'])+'</p><div>'+images+'</div></article>')
(out/'cases.json').write_text(json.dumps(cases,ensure_ascii=False,indent=2)+'\n');(out/'pages.json').write_text(json.dumps(pages,ensure_ascii=False,indent=2)+'\n');(out/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
(out/'index.html').write_text('<meta charset="utf-8"><title>Native real-chapter pixel review</title><style>body{font:16px sans-serif;color:#eee;background:#181a20}article{padding:20px;border-bottom:1px solid #777}article div{display:flex;gap:15px;flex-wrap:wrap}figure{margin:0}img{max-width:450px;max-height:600px;object-fit:contain}</style><h1>Actual Vision/Paddle + CTD/LaMa + CoreText output</h1><p>Native simulator execution. Memory guard is bypassed for inference measurement. No quality-equivalence claim.</p>'+''.join(rows))
report=dict(cases=len(cases),scanned_pages=len(pages),routes={route:sum(c['route']==route for c in cases)for route in ['light','neural','original']},provider_success=sum(c['translation_source']=='Google batch'for c in cases),quality_acceptance_proven=False,physical_device=False,provenance=provenance)
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
