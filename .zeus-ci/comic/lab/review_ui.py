"""Add review filters and full-resolution links without altering measured images."""
import argparse,html,json,pathlib,re
p=argparse.ArgumentParser();p.add_argument('review',type=pathlib.Path);a=p.parse_args();index=a.review/'index.html';s=index.read_text();cases=json.loads((a.review/'cases.json').read_text())
if 'id="lab-filters"'in s:raise SystemExit('Review filters already installed')
for c in cases:
 s=s.replace('<article id="'+c['id']+'">','<article id="'+c['id']+'" data-language="'+c['language']+'" data-route="'+c['restoration_route']+'">')
s=re.sub(r'<img loading="lazy" src="([^"]+)"[^>]*>',lambda m:'<a target="_blank" rel="noopener" href="'+m[1]+'">'+m[0]+'</a>',s)
filters='''<nav id="lab-filters" style="position:sticky;top:0;padding:12px;background:#282c34;z-index:10;display:flex;gap:12px;align-items:center;flex-wrap:wrap">
<label>اللغة <select id="language-filter"><option value="">كل اللغات</option value="en">الإنجليزية</option><option value="ja">اليابانية</option><option value="ko">الكورية</option><option value="zh">الصينية</option><option value="ar">العربية</option></select></label>
<label>المسار <select id="route-filter"><option value="">كل المسارات</option><option value="light">تنظيف خفيف</option><option value="neural">ترميم عصبي</option><option value="original">احتُفظ بالأصل</option></select></label><span id="visible-count"></span>
<a style="color:#9cf" href="native-ios/index.html">صور iOS الفعلية</a><a style="color:#9cf" href="report.json">الأرقام التشخيصية</a></nav>
<p dir="rtl">اضغط على أي صورة لعرض دقتها الأصلية. هذه مقترحات للفحص وليست مناطق معلّمة يدويًا؛ النصوص البديلة ثابتة لاختبار الرسم.</p>
<script>
function filterCases(){let count=0;const language=document.getElementById('language-filter').value,route=document.getElementById('route-filter').value;for(const article of document.querySelectorAll('article')){article.hidden=!!((language&&article.dataset.language!==language)||(route&&article.dataset.route!==route));if(!article.hidden)count++;}document.getElementById('visible-count').textContent=count+' منطقة للفحص';}
for(const id of ['language-filter','route-filter'])document.getElementById(id).onchange=filterCases;
window.addEventListener('DOMContentLoaded',filterCases);
</script>'''
s=s.replace('<h1>Real comic quality lab</h1>','<h1>Real comic quality lab</h1>'+filters)
index.write_text(s);print('Installed filters for',len(cases),'review proposals')
