/* ZEUS image translation bridge. Independent implementation; runs in an isolated WKContentWorld. */
(() => {
  if (globalThis.zeusComic) return;
  // randomUUID is unavailable on ordinary HTTP pages; getRandomValues still is.
  const uuid = () => globalThis.crypto?.randomUUID?.() || Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2,'0')).join('');
  const documentID = uuid();
  const records = new Map(), ids = new WeakMap(), transfers = new Map();
  const outputs=new Map();
  let sequence = 0, generation = 0, active = false, showingOriginal = false, sessionTicket = null, observerTimer, viewportTimer, prefetchTimer, wholeChapter = false;
  const lazyAttributes = ['data-src','data-lazy-src','data-original','data-lazy','data-url','data-echo','data-cfsrc','data-pagespeed-lazy-src','data-ks-lazyload'];
  const absolute = v => { try { return new URL(v, location.href).href; } catch { return ''; } };
  const css = (el,n) => [el.style.getPropertyValue(n),el.style.getPropertyPriority(n)];
  const putCSS = (el,n,v) => v[0] ? el.style.setProperty(n,v[0],v[1]) : el.style.removeProperty(n);
  function notify(kind) { try { webkit.messageHandlers.zeusComic.postMessage({document:documentID,kind}); } catch {} }
  function record(el,kind) {
    let id = ids.get(el), r = id && records.get(id);
    if (!r) { id = 'i'+ ++sequence; ids.set(el,id); r={id,el,kind,revision:0,parts:new Map(),urls:new Set(),original:null,mark:null,holdUntil:0}; records.set(id,r); }
    return r;
  }
  function policyOf(r) {
    const valid=new Set(['no-referrer','no-referrer-when-downgrade','origin','origin-when-cross-origin','same-origin','strict-origin','strict-origin-when-cross-origin','unsafe-url']);
    const policies=[r.original?.referrerPolicy,r.el.referrerPolicy,r.el.getAttribute('referrerpolicy'),document.referrerPolicy,document.querySelector('meta[name="referrer" i]')?.content];
    return policies.map(v=>(v||'').trim().toLowerCase()).find(v=>valid.has(v))||null;
  }
  function sourceOf(r) { return r.original?.source || (r.kind==='canvas' ? 'canvas:'+r.id : r.kind==='background' ? absolute((/url\(["']?(.*?)["']?\)/.exec(r.el.style.backgroundImage)||[])[1]||'') : r.el.currentSrc || r.el.src || ''); }
  function release(r) {
    if (r.held) { if(r.el.style.getPropertyValue('filter')==='blur(18px) saturate(0.7)'||r.el.style.getPropertyValue('filter')==='blur(18px) saturate(.7)')putCSS(r.el,'filter',r.held);r.held=null; }
    r.holdUntil=0;observer.takeRecords();
  }
  function setStyle(r,name,value){r.el.style.setProperty(name,value,'important');(r.written||(r.written={}))[name]=css(r.el,name);}
  function reset(r,restore=true) {
    release(r); r.guard?.disconnect();r.guard=null;
    if (restore && r.original) {
      const o=r.original;
      if (r.kind==='image') {
        // Do not overwrite a new picture the site placed in a recycled element.
        const current=r.el.getAttribute('src')||'';
        if (r.urls.has(current) || current===o.src || r.parts.size) {
          if(o.src===null)r.el.removeAttribute('src');else r.el.setAttribute('src',o.src);
          if(o.srcset===null)r.el.removeAttribute('srcset');else r.el.setAttribute('srcset',o.srcset);
          for(const [el,old] of o.sources) if(el.isConnected&&!el.hasAttribute('srcset'))el.setAttribute('srcset',old);
        }
      } else if(r.kind==='canvas' && o.canvas && r.el.width===o.canvas.width && r.el.height===o.canvas.height) {
        // A lightweight fingerprint protects a canvas the page has since repainted.
        if(fingerprint(r.el)===r.canvasMark)r.el.getContext('2d')?.drawImage(o.canvas,0,0);
      }

    }
    if(r.original?.styles)for(const [name,value]of Object.entries(r.original.styles)){const written=r.written?.[name];if(written&&css(r.el,name).join('\0')===written.join('\0'))putCSS(r.el,name,value);}
    r.written={};
    for(const u of r.urls)URL.revokeObjectURL(u);
    r.urls.clear();r.parts.clear();r.original=null;r.captureSource=null;r.backingURL=null;r.presentation=null;r.mark=null;r.renderMark=null;r.canvasMark=null;
    // Restoring our own attributes is not a new source revision.
    observer.takeRecords();
  }
  function fingerprint(el) { try { const c=document.createElement('canvas');c.width=c.height=16;c.getContext('2d').drawImage(el,0,0,16,16);return Array.from(c.getContext('2d').getImageData(0,0,16,16).data).join(','); }catch{return '';} }
  function shortSource(source,id,revision){if(!source.startsWith('data:')||source.length<=512)return source;let hash=2166136261;for(const start of [0,Math.max(0,(source.length>>1)-128),Math.max(0,source.length-256)])for(let i=start;i<Math.min(source.length,start+256);i++){hash^=source.charCodeAt(i);hash=Math.imul(hash,16777619);}return 'data:#'+source.length+'.'+(hash>>>0).toString(36);}
  // Only a coherent reader is prepared in full: never sweep covers, navigation,
  // recommendations or every image on an ordinary web page.
  function chapterImages() {
    const indexed=[...document.querySelectorAll('img[data-page-index]')];
    if(indexed.length>=2)return new Set(indexed);
    const roots=[...document.querySelectorAll('#readerarea,.reading-content,.chapter-content,.reader-content,[data-reader]')];
    for(const root of roots){const images=[...root.querySelectorAll('img')];if(images.length>=2)return new Set(images);}
    const groups=new Map();
    for(const el of document.images){
      const b=el.getBoundingClientRect();
      if(b.width<200||b.height<b.width*.8||el.closest('nav,header,footer,aside'))continue;
      const parent=el.closest('picture')?.parentElement||el.parentElement;
      if(!parent)continue;const group=groups.get(parent)||[];group.push(el);groups.set(parent,group);
    }
    const best=[...groups.values()].filter(v=>v.length>=3).sort((a,b)=>b.length-a.length)[0];
    return new Set(best||[]);
  }
  function wakeChapter(){clearTimeout(prefetchTimer);prefetchTimer=setTimeout(()=>{if(active&&wholeChapter&&!showingOriginal)scan(true)},50);}
  function scan(wake=true) {
    wholeChapter=wake;
    const items=[], viewport=visualViewport?.height||innerHeight,chapter=wake ? chapterImages():new Set();
    let woken=0;
    for(const el of document.images) {
      const r=record(el,'image'), box=el.getBoundingClientRect(),member=chapter.has(el);
      if(box.width<64||(!member&&box.height<1)||(!member&&(box.bottom< -viewport||box.top>viewport*9)))continue;
      if(wake&&chapter.size&&!member)continue;
      if(/^(광고|廣告|广告|ad|ads|advert|advertisement|sponsored)$/i.test((el.alt||'').trim()))continue;
      let desired=''; for(const key of lazyAttributes){const value=el.getAttribute(key);if(value&&/^https?:/i.test(absolute(value))){desired=absolute(value);break;}}
      const source=sourceOf(r);
      const waiting=(!el.complete||!el.naturalWidth||!!desired&&desired!==source&&!r.original);
      if(wake&&waiting&&!r.loadFailed&&(member||box.top<viewport*8)&&woken<4){if(el.loading==='lazy')el.loading='eager';if(desired&&r.woken!==desired){el.src=desired;r.woken=desired;}woken++;}
      items.push({id:r.id,source:shortSource(sourceOf(r),r.id,r.revision),kind:r.kind,width:r.original?.width||el.naturalWidth||0,height:r.original?.height||el.naturalHeight||0,x:box.left+scrollX,y:box.top+scrollY,w:box.width,h:box.height,pending:waiting,loadFailed:!!r.loadFailed&&r.loadRetries>=2,revision:String(r.revision),referrerPolicy:policyOf(r)});
    }
    observer.takeRecords(); // Our lazy-source writes are not a new page revision.
    for(const el of document.querySelectorAll('canvas,[style*="background-image"]')) {
      if(el.tagName==='IMG')continue; // Partial image overlays already have an image record.
      const kind=el.tagName==='CANVAS'?'canvas':'background',r=record(el,kind),box=el.getBoundingClientRect();
      if(kind==='canvas'&&r.original&&fingerprint(el)!==r.canvasMark){reset(r,false);r.revision++;}
      if(box.width<64||box.height<24||box.bottom< -viewport||box.top>viewport*3)continue;
      items.push({id:r.id,source:shortSource(sourceOf(r),r.id,r.revision),kind,width:r.original?.width||el.width||Math.round(box.width),height:r.original?.height||el.height||Math.round(box.height),x:box.left+scrollX,y:box.top+scrollY,w:box.width,h:box.height,pending:false,revision:String(r.revision),referrerPolicy:policyOf(r)});
    }
    for(const [id,r] of records)if(!r.el.isConnected){reset(r,false);records.delete(id);}
    return {document:documentID,url:location.href,language:document.documentElement.lang||'',viewport,scroll:scrollY,items};
  }
  function live(id,revision) { const r=records.get(id);if(!r||!r.el.isConnected||String(r.revision)!==String(revision))throw Error('stale image');return r; }
  async function capture(id,revision,region) {
    const r=live(id,revision);if(r.original && !r.captureSource && r.kind!=='canvas'){const original=new Image();original.referrerPolicy=policyOf(r);original.src=r.original.source;await original.decode();r.captureSource=original;}
    let image=r.original?.canvas || r.captureSource || r.el;
    if(r.kind==='background'){image=new Image();image.crossOrigin='anonymous';image.referrerPolicy=policyOf(r);image.src=sourceOf(r);await image.decode();}
    if(r.kind==='canvas')r.captureFingerprint=fingerprint(r.el);
    const c=document.createElement('canvas');c.width=region.width;c.height=region.height;
    if(c.width*c.height>8000000)throw Error('pixel limit');
    const context=c.getContext('2d');
    if(r.kind==='background'){
      const style=getComputedStyle(r.el),box=r.el.getBoundingClientRect(),width=r.original?.width||Math.round(box.width),height=r.original?.height||Math.round(box.height);
      const paint=r.original?.paint||{size:style.backgroundSize,position:style.backgroundPosition,repeat:style.backgroundRepeat},size=paint.size.trim(),values=size.split(/\s+/);
      let dw=image.naturalWidth,dh=image.naturalHeight;
      const dimension=(value,full)=>value?.endsWith('%')?parseFloat(value)*full/100:parseFloat(value);
      if(size==='cover'||size==='contain'){const factor=(size==='cover'?Math.max:Math.min)(width/dw,height/dh);dw*=factor;dh*=factor;}
      else{const w=dimension(values[0],width),h=dimension(values[1],height);if(Number.isFinite(w)){dw=w;dh=Number.isFinite(h)?h:image.naturalHeight*w/image.naturalWidth;}else if(Number.isFinite(h)){dh=h;dw=image.naturalWidth*h/image.naturalHeight;}}
      if(!(dw>0&&dh>0))throw Error('unsupported background size');
      const positions=paint.position.split(/\s+/),position=(value,space)=>value?.endsWith('%')?parseFloat(value)*space/100:value==='center'?space/2:value==='right'||value==='bottom'?space:parseFloat(value)||0;
      const left=position(positions[0],width-dw),top=position(positions[1]||'50%',height-dh),repeat=paint.repeat||'repeat';
      context.translate(-region.x,-region.y);
      if(repeat==='no-repeat')context.drawImage(image,left,top,dw,dh);
      else{const pattern=context.createPattern(image,repeat);if(!pattern)throw Error('unsupported background repeat');pattern.setTransform(new DOMMatrix().translate(left,top).scale(dw/image.naturalWidth,dh/image.naturalHeight));context.fillStyle=pattern;context.fillRect(region.x,region.y,region.width,region.height);}
    }else context.drawImage(image,region.x,region.y,region.width,region.height,0,0,c.width,c.height);
    const blob=await new Promise(resolve=>c.toBlob(resolve,'image/png'));if(!blob||blob.size>33554432)throw Error('capture too large');
    const bytes=new Uint8Array(await blob.arrayBuffer()),token=uuid();
    if(transfers.size>=6)throw Error('transfer limit');
    transfers.set(token,{bytes,at:Date.now()});return {token,length:bytes.length,width:c.width,height:c.height};
  }
  function take(token,offset,count){const transfer=transfers.get(token);if(!transfer||count>65536||offset<0)throw Error('missing transfer');let result='';for(const b of transfer.bytes.subarray(offset,offset+count))result+=String.fromCharCode(b);transfer.at=Date.now();return btoa(result);}
  function begin(id,revision) {
    const r=live(id,revision);if(r.original)return r;
    const el=r.el;
    if(r.kind==='canvas'&&el.width*el.height>8000000)throw Error('canvas original exceeds reversible pixel limit');
    const styles={};for(const n of ['background-image','background-size','background-position','background-repeat','background-origin','background-clip','object-position','object-fit','opacity','transition'])styles[n]=css(el,n);
    r.original={referrerPolicy:policyOf(r),source:sourceOf(r),src:el.getAttribute('src'),srcset:el.getAttribute('srcset'),width:el.naturalWidth||el.width||Math.round(el.getBoundingClientRect().width),height:el.naturalHeight||el.height||Math.round(el.getBoundingClientRect().height),styles,sources:[]};
    if(r.kind==='background'){const style=getComputedStyle(el);r.original.paint={size:style.backgroundSize,position:style.backgroundPosition,repeat:style.backgroundRepeat};}
    if(el.parentElement?.tagName==='PICTURE')for(const s of el.parentElement.querySelectorAll('source[srcset]'))r.original.sources.push([s,s.getAttribute('srcset')]);
    if(r.kind==='canvas'){const c=document.createElement('canvas');c.width=el.width;c.height=el.height;c.getContext('2d').drawImage(el,0,0);r.original.canvas=c;}
    return r;
  }
  function hold(id,revision) {const r=live(id,revision);if(!r.held){r.held=css(r.el,'filter');r.el.style.setProperty('filter','blur(18px) saturate(.7)','important');}r.holdUntil=Date.now()+180000;observer.takeRecords();}
  async function apply(id,revision,data,region,mark,expectedGeneration) {
    if(expectedGeneration!==generation||showingOriginal)return false;
    const r=live(id,revision),beforeSource=sourceOf(r),image=new Image(),bytes=typeof data==='string'?Uint8Array.from(atob(data),v=>v.charCodeAt(0)):data;
    let url=URL.createObjectURL(new Blob([bytes],{type:'image/png'}));
    try{image.src=url;await image.decode();}catch{URL.revokeObjectURL(url);let raw='';for(const byte of bytes)raw+=String.fromCharCode(byte);url='data:image/png;base64,'+btoa(raw);image.src=url;try{await image.decode();}catch{return false;}}
    if(expectedGeneration!==generation||String(r.revision)!==String(revision)||sourceOf(r)!==beforeSource||!r.el.isConnected||(r.kind==='canvas'&&r.captureFingerprint&&fingerprint(r.el)!==r.captureFingerprint)){URL.revokeObjectURL(url);return false;}
    begin(id,revision);r.urls.add(url);
    const el=r.el;
    if(r.kind==='canvas') {
      const ctx=el.getContext('2d');if(!ctx){reset(r);return false;}ctx.save();ctx.setTransform(1,0,0,1,0,0);ctx.drawImage(image,region.x,region.y,region.width,region.height);ctx.restore();r.canvasMark=fingerprint(el);
    } else if(region.y===0&&region.height===r.original.height&&r.kind==='image') {
      for(const [source]of r.original.sources)source.removeAttribute('srcset');el.removeAttribute('srcset');el.src=url;
      let resets=[];r.guard?.disconnect();r.guard=new MutationObserver(()=>{if(!r.original)return;const now=el.getAttribute('src');if(r.urls.has(now))return;
        if(absolute(now)===r.original.source){resets=resets.filter(t=>Date.now()-t<1000);if(resets.length>=4){reset(r);return;}resets.push(Date.now());el.src=url;el.removeAttribute('srcset');}
        else{reset(r,false);r.revision++;notify('changed');}});r.guard.observe(el,{attributes:true,attributeFilter:['src','srcset']});
    } else {
      const fit=getComputedStyle(el).objectFit;
      if(r.kind==='image'&&fit&&fit!=='fill'&&Math.abs(el.clientWidth*r.original.height/r.original.width-el.clientHeight)>1.5){reset(r);return false;}
      r.parts.set(region.y,{url,top:region.y/r.original.height,height:region.height/r.original.height});
      const parts=Array.from(r.parts.values());
      // Use the already fetched original, avoiding a second CSS request with a
      // different referrer policy from the source <img>.
      setStyle(r,'background-image',parts.map(p=>'url("'+p.url+'")').concat('url("'+(r.backingURL||r.original.source).replace(/"/g,'%22')+'")').join(','),'important');
      setStyle(r,'background-size',parts.map(p=>'100% '+p.height*100+'%').concat('100% 100%').join(','),'important');
      setStyle(r,'background-position',parts.map(p=>'0 '+(p.height>=1?0:p.top/(1-p.height)*100)+'%').concat('0 0').join(','),'important');
      setStyle(r,'background-repeat','no-repeat','important');setStyle(r,'background-origin','content-box','important');setStyle(r,'background-clip','content-box','important');
      if(r.kind==='image'){setStyle(r,'object-fit','none','important');setStyle(r,'object-position','-100000px -100000px','important');}
    }
    r.renderMark=mark;release(r);
    if(typeof requestAnimationFrame==='function'&&!globalThis.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches){
      setStyle(r,'transition','opacity 180ms ease-out');setStyle(r,'opacity','0.6');
      requestAnimationFrame(()=>{if(r.original&&!showingOriginal){setStyle(r,'opacity','1');observer.takeRecords();}});
      setTimeout(()=>{if(r.original&&!showingOriginal){
        for(const name of ['opacity','transition']){if(css(el,name).join('\0')===r.written?.[name]?.join('\0'))putCSS(el,name,r.original.styles[name]);delete r.written[name];}
        observer.takeRecords();
      }},240);
    }
    observer.takeRecords();return true;
  }
  // Switching the visual representation keeps OCR, lettering and object URLs alive.
  // Restore never overwrites an element the reader has recycled for another panel.
  function setOriginal(show,ticket) {
    if(ticket!=null&&ticket!==sessionTicket)return false;
    if(show===showingOriginal)return true;
    showingOriginal=show;
    for(const r of records.values()) {
      const el=r.el,o=r.original;
      if(!o||!el.isConnected)continue;
      if(show) {
        release(r);r.guard?.disconnect();
        for(const name of ['opacity','transition']){
          if(r.written?.[name]&&css(el,name).join('\0')===r.written[name].join('\0')){putCSS(el,name,o.styles[name]);delete r.written[name];}
        }
        const styles={};for(const name of Object.keys(o.styles))styles[name]=css(el,name);
        r.presentation={src:el.getAttribute('src'),srcset:el.getAttribute('srcset'),styles,
          sources:o.sources.map(([node])=>[node,node.getAttribute('srcset')])};
        if(r.kind==='canvas') {
          const c=document.createElement('canvas');c.width=el.width;c.height=el.height;
          c.getContext('2d').drawImage(el,0,0);r.presentation.canvas=c;
          el.getContext('2d')?.drawImage(o.canvas,0,0);r.canvasMark=fingerprint(el);
        } else if(r.kind==='image') {
          el.src=o.source;
          if(o.srcset===null)el.removeAttribute('srcset');else el.setAttribute('srcset',o.srcset);
          for(const [node,value]of o.sources)if(node.isConnected)node.setAttribute('srcset',value);
        }
        for(const [name,value]of Object.entries(o.styles))putCSS(el,name,value);
      } else if(r.presentation) {
        const v=r.presentation;
        if(r.kind==='canvas') {el.getContext('2d')?.drawImage(v.canvas,0,0);r.canvasMark=fingerprint(el);}
        else if(r.kind==='image') {
          if(v.src===null)el.removeAttribute('src');else el.setAttribute('src',v.src);
          if(v.srcset===null)el.removeAttribute('srcset');else el.setAttribute('srcset',v.srcset);
          for(const [node,value]of v.sources)if(node.isConnected){if(value===null)node.removeAttribute('srcset');else node.setAttribute('srcset',value);}
        }
        for(const [name,value]of Object.entries(v.styles))putCSS(el,name,value);
        r.presentation=null;
        r.guard?.observe(el,{attributes:true,attributeFilter:['src','srcset']});
      }
    }
    observer.takeRecords();return true;
  }
  function restore(){setOriginal(false);generation++;active=false;for(const r of records.values())reset(r);transfers.clear();}
  function start(){active=true;return generation;}
  function resume(mark,ticket){if(ticket&&ticket!==sessionTicket){generation++;sessionTicket=ticket;}setOriginal(false);active=true;for(const r of records.values())if((r.mark||r.renderMark)&&(r.mark||r.renderMark)!==mark)reset(r);return generation;}
  const observer=new MutationObserver(changes=>{if(!active)return;
    let external=false;
    for(const change of changes){
      let target=change.target;
      if(target.tagName==='SOURCE')target=target.parentElement?.querySelector('img')||target;
      const id=ids.get(target),r=id&&records.get(id);
      if(showingOriginal&&r?.presentation){
        if(change.type==='attributes'&&['src','srcset'].includes(change.attributeName)&&sourceOf(r)!==(r.el.currentSrc||r.el.src||'')){reset(r,false);r.presentation=null;r.revision++;external=true;}
        continue;
      }
      if(r&&change.type==='attributes'&&change.attributeName==='style'){
        if(r.original&&Object.entries(r.written||{}).some(([name,value])=>css(r.el,name).join('\0')!==value.join('\0'))){reset(r,false);r.revision++;external=true;}
        else if(!r.original){r.revision++;external=true;}
      }else if(r&&change.type==='attributes'&&['src','srcset'].includes(change.attributeName)){
        if(r.original){
          if(change.target.tagName==='SOURCE'){
            const prior=r.original.sources.find(([el])=>el===change.target),now=change.target.getAttribute('srcset');
            if(now&&prior&&now===prior[1]){change.target.removeAttribute('srcset');continue;}
            if(now){reset(r,false);r.revision++;external=true;}
          }else{const now=r.el.currentSrc||r.el.src||'';if(!r.urls.has(now)&&now!==r.original.source){reset(r,false);r.revision++;external=true;}}
        }else{r.revision++;r.mark=null;external=true;}
      }else if(change.type==='childList'||!r){external=true;}
    }
    if(external){clearTimeout(observerTimer);observerTimer=setTimeout(()=>notify('changed'),200);}
  });
  observer.observe(document.documentElement,{subtree:true,childList:true,attributes:true,attributeFilter:['src','srcset','style']});
  document.addEventListener('load',e=>{
    const r=records.get(ids.get(e.target));
    if(active&&e.target?.tagName==='IMG'&&!r?.original){if(r)r.loadFailed=false;notify('loaded');wakeChapter();}
  },true);
  document.addEventListener('error',e=>{
    if(!active||e.target?.tagName!=='IMG')return;
    const r=records.get(ids.get(e.target));notify('image-error');
    if(!r||r.original)return;r.loadFailed=true;wakeChapter();
    if((r.loadRetries||0)>=2)return;
    const attempt=r.loadRetries=(r.loadRetries||0)+1;
    setTimeout(()=>{if(!active||!r.el.isConnected||r.original)return;r.loadFailed=false;r.el.src=r.woken||sourceOf(r);observer.takeRecords();},attempt===1?2000:6000);
  },true);
  addEventListener('resize',()=>{if(active)notify('viewport');},{passive:true});
  addEventListener('scroll',()=>{if(!active)return;clearTimeout(viewportTimer);viewportTimer=setTimeout(()=>notify('viewport'),120);},{passive:true});
  addEventListener('pageshow',e=>{if(e.persisted)restore();notify('ready');});
  setInterval(()=>{for(const r of records.values())if(r.holdUntil&&r.holdUntil<Date.now())release(r);for(const [id,t]of transfers)if(Date.now()-t.at>30000)transfers.delete(id);},5000);
  function outputStart(token,length){if(length>33554432||length<1||outputs.size>=4)throw Error("output limit");outputs.set(token,{bytes:new Uint8Array(length),offset:0});}
  function outputPart(token,offset,data){const o=outputs.get(token);if(!o||offset!==o.offset||data.length>65536)throw Error("output offset");const b=Uint8Array.from(atob(data),v=>v.charCodeAt(0));if(offset+b.length>o.bytes.length)throw Error("output overflow");o.bytes.set(b,offset);o.offset+=b.length;}
  function outputOriginal(token,id,revision){
    const o=outputs.get(token);if(!o||o.offset!==o.bytes.length)throw Error('incomplete original');
    outputs.delete(token);const r=live(id,revision);
    if(r.backingURL)return;
    const type=o.bytes[0]===255?'image/jpeg':o.bytes[0]===137?'image/png':'image/webp';
    r.backingURL=URL.createObjectURL(new Blob([o.bytes],{type}));r.urls.add(r.backingURL);
  }
  async function outputApply(token,id,revision,region,mark,generation){const o=outputs.get(token);if(!o||o.offset!==o.bytes.length)throw Error("incomplete output");outputs.delete(token);return apply(id,revision,o.bytes,region,mark,generation);}
  globalThis.zeusComic={pause:ticket=>{if(ticket===sessionTicket){generation++;active=false;for(const r of records.values())release(r);}},setOriginal,outputOriginal,hasBacking:(id,revision)=>!!live(id,revision).backingURL,outputStart,outputPart,outputApply,outputDrop:t=>outputs.delete(t),releaseAll:()=>{for(const r of records.values())release(r);},documentID,scan,capture,take,drop:t=>transfers.delete(t),apply,hold,release:id=>{const r=records.get(id);if(r)release(r);},start,resume,restore,mark:(id,revision,mark)=>{live(id,revision).mark=mark;},has:(id,revision,mark)=>{const r=live(id,revision);return r.mark===mark;}};
  notify('ready');
})();
