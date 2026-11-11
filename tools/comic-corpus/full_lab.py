"""Run the pinned, real-chapter Linux counterpart when the local executor is unavailable."""
import argparse, hashlib, importlib.metadata, json, os, pathlib, subprocess, sys
import numpy as np
from PIL import Image
REPO=pathlib.Path(__file__).resolve().parents[2]
LAB=REPO/'.zeus-ci/comic/lab'
def command(*args):
    subprocess.run([str(x) for x in args],cwd=REPO,check=True)
def main():
    p=argparse.ArgumentParser();p.add_argument('--root',type=pathlib.Path,required=True);a=p.parse_args()
    root=a.root.resolve();root.mkdir(parents=True,exist_ok=True)
    models=root/'models';data=root/'data';review=root/'review';data.mkdir(exist_ok=True)
    command(sys.executable,LAB/'models.py',models)
    chapters={}
    for language in ['en','ja','ko','zh','ar']:
        shard=root/'shards'/language
        command(sys.executable,REPO/'tools/comic-corpus/prepare.py','--language',language,'--output',shard)
        manifest=json.loads((shard/'corpus.json').read_text())
        for chapter in manifest['chapters']:
            chapters[chapter['id']]=chapter
            for page in chapter['pages']:
                target=data/page['path'];target.parent.mkdir(parents=True,exist_ok=True)
                if not target.exists():
                    if target.is_symlink():target.unlink()
                    target.symlink_to((shard/page['path']).resolve())
    base=json.loads((REPO/'docs/comic-translation/lab/corpus.json').read_text())
    order=[c['id'] for c in base['chapters']]+['violet-broken-ring-1']
    corpus=dict(version=1,chapters=[chapters[c] for c in order])
    (data/'corpus.json').write_text(json.dumps(corpus,ensure_ascii=False,indent=2))
    command(sys.executable,LAB/'run.py','--corpus',data,'--models',models,'--output',review,'--regions','480','--ocr','--neural','--resume')
    cases=json.loads((review/'cases.json').read_text());report=json.loads((review/'report.json').read_text())
    assert len(cases)==480,(len(cases),'Expected the complete diagnostic quota')
    assert report['outside_mask_changes']==0
    identity_failures=[]
    for case in cases:
        if case['cleanup_accepted']:continue
        directory=review/case['id']
        original=np.array(Image.open(directory/'original.png').convert('RGB'))
        for phase in ['clean','rendered']:
            if not np.array_equal(original,np.array(Image.open(directory/(phase+'.png')).convert('RGB'))):
                identity_failures.append([case['id'],phase])
    assert not identity_failures,identity_failures
    revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip()
    provenance=dict(app_source_commit=os.environ.get('APP_SOURCE',revision),harness_source_commit=os.environ.get('GITHUB_SHA',revision),
        native_kernel_sha256=report['native_kernel_sha256'],corpus_sha256=hashlib.sha256((data/'corpus.json').read_bytes()).hexdigest(),
        downloaded_original_pages=sum(len(c['pages'])for c in corpus['chapters']),sampled_regions=len(cases),
        declined_output_identity_failures=0,quality_acceptance_proven=False,physical_device=False,
        note='Shared C++ cleanup with Paddle/ONNX and fixed text on Linux; native OCR, Google and CoreText are separate evidence.',
        dependencies={n:importlib.metadata.version(n)for n in ['onnxruntime','opencv-python-headless','numpy','Pillow','PyYAML']})
    (review/'provenance.json').write_text(json.dumps(provenance,indent=2))
    (review/'corpus.json').write_text(json.dumps(corpus,ensure_ascii=False,indent=2))
    command(sys.executable,LAB/'annotate.py',review/'index.html')
    command(sys.executable,LAB/'review_ui.py',review)
    page=(review/'index.html').read_text()
    page=page.replace('</option value="en">','</option><option value="en">')
    page=page.replace('<option value="light">','<option value="flat">خلفية سادة</option><option value="light">')
    (review/'index.html').write_text(page)
    print('FULL_LAB_REPORT:'+json.dumps(dict(report,declined_output_identity_failures=0)),flush=True)
if __name__=='__main__':main()
