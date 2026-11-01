/* ZEUS image translation bridge. Independent implementation; runs in an isolated WKContentWorld. */
(() => {
  if (globalThis.zeusComic) return;
  const documentID = crypto.randomUUID();
  const records = new Map(), ids = new WeakMap(), transfers = new Map();
  const outputs=new Map();
  let sequence = 0, generation = 0, active = false, observerTimer, viewportTimer;
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
  function sourceOf(r) { return r.original?.source || (r.kind==='canvas' ? 'canvas:'+r.id : r.kind==='background' ? absolute((/url\(["']?(.*?)["']?\)/.exec(r.el.style.backgroundImage)||[])[1]||'') : r.el.currentSrc || r.el.src || ''); }
  function release(r) {
    if (r.held) { putCSS(r.el,'filter',r.held);r.held=null; }
    r.holdUntil=0;
  }
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
      if(o.styles)for(const [name,value] of Object.entries(o.styles))putCSS(r.el,name,value);
    }
    for(const u of r.urls)URL.revokeObjectURL(u);
    r.urls.clear();r.parts.clear();r.original=null;r.captureSource=null;r.mark=null;r.renderMark=null;r.canvasMark=null;
  }
  function fingerprint(el) { try { const c=document.createElement('canvas');c.width=c.height=16;c.getContext('2d').drawImage(el,0,0,16,16);return Array.from(c.getContext('2d').getImageData(0,0,16,16).data).join(','); }catch{return '';} }
  function scan(wake=true) {
    const items=[], viewport=visualViewport?.height||innerHeight;
    let woken=0;
    for(const el of document.images) {
      const r=record(el,'image'), box=el.getBoundingClientRect();
      if(box.width<64||box.height<1||box.bottom< -viewport||box.top>viewport*9)continue;
      if(/^(광고|廣告|广告|ad|ads|advert|advertisement|sponsored)$/i.test((el.alt||'').trim()))continue;
      let desired=''; for(const key of lazyAttributes){const value=el.getAttribute(key);if(value&&/^https?:/i.test(absolute(value))){desired=absolute(value);break;}}
      const source=sourceOf(r);
      const waiting=(!el.complete||!el.naturalWidth||!!desired&&desired!==source&&!r.original);
      if(wake&&waiting&&box.top<viewport*8&&woken<4){if(el.loading==='lazy')el.loading='eager';if(desired&&r.woken!==desired){el.src=desired;r.woken=desired;}woken++;}
      items.push({id:r.id,source:sourceOf(r),kind:r.kind,width:r.original?.width||el.naturalWidth||0,height:r.original?.height||el.naturalHeight||0,x:box.left+scrollX,y:box.top+scrollY,w:box.width,h:box.height,pending:waiting,revision:String(r.revision)});
    }
    for(const el of document.querySelectorAll('canvas,[style*="background-image"]')) {
      const kind=el.tagName==='CANVAS'?'canvas':'background',r=record(el,kind),box=el.getBoundingClientRect();
      if(box.width<64||box.height<24||box.bottom< -viewport||box.top>viewport*3||r.parts.size)continue;
      items.push({id:r.id,source:sourceOf(r),kind,width:el.width||Math.round(box.width),height:el.height||Math.round(box.height),x:box.left+scrollX,y:box.top+scrollY,w:box.width,h:box.height,pending:false,revision:String(r.revision)});
    }
    for(const [id,r] of records)if(!r.el.isConnected){reset(r,false);records.delete(id);}
    return {document:documentID,url:location.href,language:document.documentElement.lang||'',viewport,scroll:scrollY,items};
  }
  function live(id,revision) { const r=records.get(id);if(!r||!r.el.isConnected||String(r.revision)!==String(revision))throw Error('stale image');return r; }
  async function capture(id,revision,region) {
    const r=live(id,revision);if(r.original && !r.captureSource && r.kind!=='canvas'){const original=new Image();original.src=r.original.source;await original.decode();r.captureSource=original;}
    let image=r.original?.canvas || r.captureSource || r.el;
    if(r.kind==='background'){image=new Image();image.crossOrigin='anonymous';image.src=sourceOf(r);await image.decode();}
    const c=document.createElement('canvas');c.width=region.width;c.height=region.height;
    if(c.width*c.height>8000000)throw Error('pixel limit');
    c.getContext('2d').drawImage(image,region.x,region.y,region.width,region.height,0,0,c.width,c.height);
    const blob=await new Promise(resolve=>c.toBlob(resolve,'image/png'));if(!blob||blob.size>33554432)throw Error('capture too large');
    const bytes=new Uint8Array(await blob.arrayBuffer()),token=crypto.randomUUID();
    if(transfers.size>=6)throw Error('transfer limit');
    transfers.set(token,{bytes,at:Date.now()});return {token,length:bytes.length,width:c.width,height:c.height};
  }
  function take(token,offset,count){const transfer=transfers.get(token);if(!transfer||count>65536||offset<0)throw Error('missing transfer');let result='';for(const b of transfer.bytes.subarray(offset,offset+count))result+=String.fromCharCode(b);transfer.at=Date.now();return btoa(result);}
  function begin(id,revision) {
    const r=live(id,revision);if(r.original)return r;
    const el=r.el,styles={};for(const n of ['background-image','background-size','background-position','background-repeat','background-origin','background-clip','object-position','object-fit','opacity','transition'])styles[n]=css(el,n);
    r.original={source:sourceOf(r),src:el.getAttribute('src'),srcset:el.getAttribute('srcset'),width:el.naturalWidth||el.width,height:el.naturalHeight||el.height,styles,sources:[]};
    if(el.parentElement?.tagName==='PICTURE')for(const s of el.parentElement.querySelectorAll('source[srcset]'))r.original.sources.push([s,s.getAttribute('srcset')]);
    if(r.kind==='canvas'){const c=document.createElement('canvas');c.width=el.width;c.height=el.height;c.getContext('2d').drawImage(el,0,0);r.original.canvas=c;}
    return r;
  }
  function hold(id,revision) {const r=live(id,revision);if(!r.held){r.held=css(r.el,'filter');r.el.style.setProperty('filter','blur(18px) saturate(.7)','important');}r.holdUntil=Date.now()+180000;observer.takeRecords();}
  async function apply(id,revision,data,region,mark,expectedGeneration) {
    if(expectedGeneration!==generation)return false;
    const r=live(id,revision),beforeSource=sourceOf(r),image=new Image(),bytes=typeof data==='string'?Uint8Array.from(atob(data),v=>v.charCodeAt(0)):data;
    let url=URL.createObjectURL(new Blob([bytes],{type:'image/png'}));
    try{image.src=url;await image.decode();}catch{URL.revokeObjectURL(url);let raw='';for(const byte of bytes)raw+=String.fromCharCode(byte);url='data:image/png;base64,'+btoa(raw);image.src=url;try{await image.decode();}catch{return false;}}
    if(expectedGeneration!==generation||sourceOf(r)!==beforeSource||!r.el.isConnected){URL.revokeObjectURL(url);return false;}
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
      el.style.setProperty('background-image',parts.map(p=>'url("'+p.url+'")').concat('url("'+r.original.source.replace(/"/g,'%22')+'")').join(','),'important');
      el.style.setProperty('background-size',parts.map(p=>'100% '+p.height*100+'%').concat('100% 100%').join(','),'important');
      el.style.setProperty('background-position',parts.map(p=>'0 '+(p.height>=1?0:p.top/(1-p.height)*100)+'%').concat('0 0').join(','),'important');
      el.style.setProperty('background-repeat','no-repeat','important');el.style.setProperty('background-origin','content-box','important');el.style.setProperty('background-clip','content-box','important');
      if(r.kind==='image'){el.style.setProperty('object-fit','none','important');el.style.setProperty('object-position','-100000px -100000px','important');}
    }
    r.renderMark=mark;release(r);observer.takeRecords();return true;
  }
  function restore(){generation++;active=false;for(const r of records.values())reset(r);transfers.clear();}
  function start(){active=true;return generation;}
  function resume(mark){active=true;for(const r of records.values())if((r.mark||r.renderMark)&&(r.mark||r.renderMark)!==mark)reset(r);return generation;}
  const observer=new MutationObserver(changes=>{if(!active)return;for(const change of changes){const id=ids.get(change.target),r=id&&records.get(id);if(r&&!r.original&&change.type==='attributes'&&['src','srcset'].includes(change.attributeName)){r.revision++;r.mark=null;}}
    clearTimeout(observerTimer);observerTimer=setTimeout(()=>notify('changed'),200);});
  observer.observe(document.documentElement,{subtree:true,childList:true,attributes:true,attributeFilter:['src','srcset','style']});
  addEventListener('scroll',()=>{if(!active)return;clearTimeout(viewportTimer);viewportTimer=setTimeout(()=>notify('viewport'),120);},{passive:true});
  addEventListener('pageshow',e=>{if(e.persisted)restore();notify('ready');});
  setInterval(()=>{for(const r of records.values())if(r.holdUntil&&r.holdUntil<Date.now())release(r);for(const [id,t]of transfers)if(Date.now()-t.at>30000)transfers.delete(id);},5000);
  function outputStart(token,length){if(length>33554432||length<1||outputs.size>=4)throw Error("output limit");outputs.set(token,{bytes:new Uint8Array(length),offset:0});}
  function outputPart(token,offset,data){const o=outputs.get(token);if(!o||offset!==o.offset||data.length>65536)throw Error("output offset");const b=Uint8Array.from(atob(data),v=>v.charCodeAt(0));if(offset+b.length>o.bytes.length)throw Error("output overflow");o.bytes.set(b,offset);o.offset+=b.length;}
  async function outputApply(token,id,revision,region,mark,generation){const o=outputs.get(token);if(!o||o.offset!==o.bytes.length)throw Error("incomplete output");outputs.delete(token);return apply(id,revision,o.bytes,region,mark,generation);}
  globalThis.zeusComic={outputStart,outputPart,outputApply,outputDrop:t=>outputs.delete(t),releaseAll:()=>{for(const r of records.values())release(r);},documentID,scan,capture,take,drop:t=>transfers.delete(t),apply,hold,release:id=>{const r=records.get(id);if(r)release(r);},start,resume,restore,mark:(id,revision,mark)=>{live(id,revision).mark=mark;},has:(id,revision,mark)=>{const r=live(id,revision);return r.mark===mark;}};
  notify('ready');
})();
