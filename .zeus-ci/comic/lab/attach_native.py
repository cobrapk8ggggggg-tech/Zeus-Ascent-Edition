"""Attach exported XCTest image evidence to a local review, with source revision."""
import argparse,html,json,pathlib,shutil
p=argparse.ArgumentParser();p.add_argument('--artifact',required=True);p.add_argument('--review',required=True);a=p.parse_args()
artifact=pathlib.Path(a.artifact);review=pathlib.Path(a.review);out=review/'native-ios';out.mkdir(parents=True,exist_ok=True)
manifest=json.loads((artifact/'screenshots/manifest.json').read_text());revision=(artifact/'source-commit.txt').read_text().strip();rows=[];evidence=[]
for test in manifest:
 if not test['testIdentifier'].startswith('NativeComicTranslationTests/'):continue
 images=[]
 for attachment in test.get('attachments',[]):
  name=attachment.get('exportedFileName','')
  if name.lower().endswith('.txt') and 'diagnostic' in attachment.get('suggestedHumanReadableName','').lower():
   shutil.copy2(artifact/'screenshots'/name,out/name)
   images.append('<pre>'+html.escape((out/name).read_text())+'</pre>')
   continue
  if not name.lower().endswith('.png'):continue
  shutil.copy2(artifact/'screenshots'/name,out/name)
  label=attachment.get('suggestedHumanReadableName',name).split('_0_')[0]
  images.append('<figure><figcaption>'+html.escape(label)+'</figcaption><img src="'+html.escape(name)+'"></figure>')
  evidence.append(dict(test=test['testIdentifier'],file=name,label=label))
 if images:rows.append('<article><h2>'+html.escape(test['testIdentifier'])+'</h2><div>'+''.join(images)+'</div></article>')
(out/'manifest.json').write_text(json.dumps(dict(source_revision=revision,origin='actual XCTest attachments exported from GitHub Actions',images=evidence),indent=2))
(out/'index.html').write_text('<meta charset="utf-8"><title>Native iOS pixel evidence</title><style>body{background:#181a20;color:#eee;font:16px sans-serif}article{padding:20px;border-bottom:1px solid #777}article div{display:flex;flex-wrap:wrap;gap:16px}figure{margin:0}img{max-width:500px;max-height:600px;object-fit:contain}figcaption{padding:8px}</style><h1>Actual iOS CoreText and ONNX output</h1><p>Source: '+html.escape(revision)+'</p><p>These are native simulator outputs. Test success does not establish full-chapter quality or physical-device memory behavior.</p>'+''.join(rows))
print('Attached',len(evidence),'native image outputs from',revision)
