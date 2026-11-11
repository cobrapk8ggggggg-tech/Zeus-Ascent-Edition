"""Add pixel-coordinate ink/protection annotation canvases to a local gallery."""
import argparse,pathlib
SCRIPT=r'''<script>
const annotations={};
for(const article of document.querySelectorAll('article')){
 const image=article.querySelector('img'),canvas=document.createElement('canvas');
 const label=document.createElement('p');label.textContent='Ink mask / protected artwork: draw in original pixel coordinates; use the selector. These annotations require human review.';
 const mode=document.createElement('select');mode.innerHTML='<option value="ink">Source ink</option><option value="protect">Protect artwork</option>';
 const clear=document.createElement('button');clear.textContent='Clear annotations';
 const text=document.createElement('textarea');text.placeholder='Exact source text, in reading order';
 article.append(label,mode,clear,text,canvas);let drawing=false;
 const record={id:article.id,source_text:'',ink:[],protect:[]};annotations[article.id]=record;
 function init(){canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;canvas.style.maxWidth='100%';canvas.style.border='1px solid #888';canvas.getContext('2d').drawImage(image,0,0);}
 if(image.complete)init();else image.addEventListener('load',init);
 const point=e=>{const b=canvas.getBoundingClientRect();return [Math.max(0,Math.min(canvas.width-1,(e.clientX-b.left)*canvas.width/b.width)),Math.max(0,Math.min(canvas.height-1,(e.clientY-b.top)*canvas.height/b.height))];};
 canvas.style.touchAction='none';canvas.onpointerdown=e=>{drawing=true;canvas.setPointerCapture(e.pointerId);record[mode.value].push([]);};
 canvas.onpointermove=e=>{if(!drawing)return;const p=point(e),stroke=record[mode.value].at(-1);stroke.push(p);const c=canvas.getContext('2d');c.fillStyle=mode.value==='ink'?'rgba(255,30,30,.45)':'rgba(30,130,255,.45)';c.beginPath();c.arc(p[0],p[1],3,0,Math.PI*2);c.fill();};
 canvas.onpointerup=()=>drawing=false;clear.onclick=()=>{record.ink=[];record.protect=[];init();};text.oninput=()=>record.source_text=text.value;
}
const button=document.createElement('button');button.textContent='Export pixel annotations';button.onclick=()=>{const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify({version:1,brush_radius:3,annotations:Object.values(annotations)},null,2)],{type:'application/json'}));a.download='pixel-annotations.json';a.click();};document.body.prepend(button);
</script>'''
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('gallery',type=pathlib.Path);a=p.parse_args();s=a.gallery.read_text();a.gallery.write_text(s+SCRIPT)
