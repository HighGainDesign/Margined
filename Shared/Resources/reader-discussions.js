// App-owned code: call only in an isolated WKContentWorld. No author scripts.
const main = document.getElementById('document');
if (!main) return null;
const blocks = new Set(['h1','h2','h3','h4','h5','h6','p','li','pre','th','td','dt','dd','caption','summary','figcaption']);
const containers = new Set(['body','div','section','blockquote','ul','ol','dl','table','thead','tbody','tfoot','tr','figure','details']);
const whitespace = /^\p{White_Space}+$/u;
const trim = value => value.replace(/^\p{White_Space}+|\p{White_Space}+$/gu,'');
const segmenter = new Intl.Segmenter('und',{granularity:'grapheme'});
function normalize(raw) {
    const leading = raw.match(/^\p{White_Space}+/u)?.[0].length ?? 0;
    const middle = trim(raw), canonical = middle.normalize('NFC').replace(/\p{White_Space}+/gu,' ');
    if (!canonical) return {text:'',runs:[]};
    if (canonical === middle) return {text:canonical,runs:[{start:0,length:canonical.length,raw:leading,rawLength:middle.length,identity:true}]};
    let text='', pending=null; const runs=[];
    function append(value,start,length,identity) {
        const last = runs.at(-1);
        if (identity && last?.identity && last.start+last.length===text.length && last.raw+last.rawLength===start) {
            last.length+=value.length; last.rawLength+=length;
        } else runs.push({start:text.length,length:value.length,raw:start,rawLength:length,identity});
        text+=value;
    }
    for (const {segment:character,index} of segmenter.segment(raw)) {
        if (whitespace.test(character)) {
            pending = pending ? {start:pending.start,end:index+character.length} : {start:index,end:index+character.length};
            continue;
        }
        if (pending && text) append(' ',pending.start,pending.end-pending.start,raw.slice(pending.start,pending.end)===' ');
        pending=null;
        const value=character.normalize('NFC'); append(value,index,character.length,value===character);
    }
    return {text,runs};
}
function rawOffset(unit,offset) {
    if (offset<0 || offset>unit.text.length) return null;
    for (const run of unit.runs) {
        if (run.start<=offset && offset<=run.start+run.length) {
            if (offset===run.start) return run.raw;
            if (offset===run.start+run.length) return run.raw+run.rawLength;
            return run.identity ? run.raw+offset-run.start : null;
        }
    }
    return null;
}
function canonicalOffset(unit,raw) {
    for (const run of unit.runs) {
        if (raw<=run.raw) return run.start;
        if (raw<=run.raw+run.rawLength) {
            if (raw===run.raw+run.rawLength) return run.start+run.length;
            return run.identity ? run.start+raw-run.raw : null;
        }
    }
    return unit.text.length;
}
function ignored(node) {
    return node.hasAttribute('hidden') || node.getAttribute('aria-hidden')==='true' ||
        ['script','style','input','button','noscript'].includes(node.localName) || node.classList.contains('margined-discussion-decoration');
}
function unsupported(node) {
    return node.classList.contains('margined-math') || node.classList.contains('margined-diagram') || ['math','svg'].includes(node.localName);
}
function headingText(node) {
    if (node.nodeType===Node.TEXT_NODE) return node.data;
    if (node.nodeType!==Node.ELEMENT_NODE || ignored(node) || unsupported(node)) return '';
    if (node.localName==='img') return node.getAttribute('alt') ?? '';
    return Array.from(node.childNodes,headingText).join('');
}
function project() {
    let text='',owner=null,raw='',parts=[],headings=[];
    const units=[],barriers=[],artwork=[];
    function flush() {
        if (!owner) return;
        const normalized=normalize(raw),value=normalized.text;
        if (value) {
            if (text) text+=' ';
            units.push({id:units.length,kind:owner.kind,text:value,location:text.length,length:value.length,
                section:headings.length ? headings.map(h=>h.title).join(' › ') : null,raw,parts,runs:normalized.runs});
            text+=value;
        }
        owner=null;raw='';parts=[];
    }
    function append(value,kind,node,nextOwner) {
        if (!owner || owner.node!==nextOwner.node || owner.kind!==nextOwner.kind) {flush();owner=nextOwner;}
        if (value) parts.push({kind,node,location:raw.length,length:value.length});
        raw+=value;
    }
    function walk(node,inherited) {
        if (node.nodeType===Node.TEXT_NODE) {append(node.data,'text',node,inherited);return;}
        if (node.nodeType!==Node.ELEMENT_NODE || ignored(node)) return;
        if (unsupported(node)) {flush();if(barriers.at(-1)!==text.length)barriers.push(text.length);artwork.push(node);return;}
        const tag=node.localName,isBlock=blocks.has(tag),isContainer=containers.has(tag);
        const current=isBlock ? {kind:tag,node} : inherited;
        if (isBlock || isContainer) flush();
        if (/^h[1-6]$/.test(tag)) {
            const level=Number(tag[1]);headings=headings.filter(h=>h.level<level);
            headings.push({level,title:normalize(headingText(node)).text});
        }
        if (tag==='img') append(node.getAttribute('alt') ?? '','image',node,current);
        else if (tag==='br') append(' ','separator',node,current);
        else for(const child of node.childNodes)walk(child,current);
        if (isBlock || isContainer) flush();
    }
    walk(main,{kind:'p',node:main});flush();
    return {text,units,barriers,artwork};
}
function selectionPayload(projection) {
    const selection=getSelection();
    if (!selection || selection.rangeCount!==1 || selection.isCollapsed) return null;
    const range=selection.getRangeAt(0);
    if (!main.contains(range.startContainer) || !main.contains(range.endContainer)) return null;
    if (projection.artwork.some(node=>range.intersectsNode(node))) return null;
    let first=null,last=null;
    for(const unit of projection.units)for(const part of unit.parts) {
        let start=0,end=part.length;
        if (part.kind==='text') {
            if(!range.intersectsNode(part.node))continue;
            // Binary search actual DOM boundary points; ancestor selections and
            // inline formatting need no text-node index guesses.
            let low=0,high=part.length;
            while(low<high){const mid=Math.floor((low+high)/2);if(range.comparePoint(part.node,mid)<0)low=mid+1;else high=mid;}
            start=low;low=0;high=part.length;
            while(low<high){const mid=Math.ceil((low+high)/2);if(range.comparePoint(part.node,mid)>0)high=mid-1;else low=mid;}
            end=low;
        } else {
            const parent=part.node.parentNode,index=Array.prototype.indexOf.call(parent.childNodes,part.node);
            if(range.comparePoint(parent,index)!==0 || range.comparePoint(parent,index+1)!==0)continue;
        }
        if(end<=start)continue;
        if(!first)first={unit,raw:part.location+start};
        last={unit,raw:part.location+end};
    }
    if(!first || !last)return null;
    const localStart=canonicalOffset(first.unit,first.raw),localEnd=canonicalOffset(last.unit,last.raw);
    if(localStart===null || localEnd===null)return null;
    let start=first.unit.location+localStart,end=last.unit.location+localEnd;
    let quote=projection.text.slice(start,end),leading=quote.match(/^\p{White_Space}+/u)?.[0].length ?? 0;
    const trailing=quote.match(/\p{White_Space}+$/u)?.[0].length ?? 0;
    start+=leading;end-=trailing;
    if(end<=start || projection.barriers.some(point=>start<point && point<end))return null;
    const startUnit=projection.units.find(u=>u.location<=start && start<u.location+u.length);
    const endUnit=projection.units.findLast(u=>u.location<end && end<=u.location+u.length);
    if(!startUnit || !endUnit)return null;
    const startOffset=rawOffset(startUnit,start-startUnit.location),endOffset=rawOffset(endUnit,end-endUnit.location);
    if(startOffset===null || endOffset===null)return null;
    return {kind:'selection',token,sourceID,location:start,length:end-start,quote:projection.text.slice(start,end),
        startUnit:startUnit.id,startOffset,endUnit:endUnit.id,endOffset};
}
if (operation==='project') {
    const value=project();
    return {text:value.text,barriers:value.barriers,units:value.units.map(({id,kind,text,location,length,section,raw})=>({id,kind,text,location,length,section,rawLength:raw.length}))};
}
if (operation==='selection') return selectionPayload(project());
if (operation!=='configure') return false;
window.__marginedDiscussions?.abort.abort();
const state={token,sourceID,allowed:new Set(allowedThreadIDs),abort:new AbortController(),pending:null};
window.__marginedDiscussions=state;
const options={signal:state.abort.signal};
function send(payload) {
    if(!payload || window.__marginedDiscussions!==state)return;
    window.webkit?.messageHandlers?.discussion?.postMessage(payload);
}
document.addEventListener('click',event=>{
    if(!event.isTrusted || !(event.target instanceof Element))return;
    const marker=event.target.closest('[data-margined-thread]'),id=marker?.getAttribute('data-margined-thread');
    if(!id || !state.allowed.has(id))return;
    event.preventDefault();send({kind:'openThread',id,token,sourceID});
},options);
function selected(event) {
    if(!event.isTrusted || getSelection()?.isCollapsed)return;
    if(state.pending!==null)cancelAnimationFrame(state.pending);
    state.pending=requestAnimationFrame(()=>{state.pending=null;send(selectionPayload(project()));});
}
document.addEventListener('pointerup',selected,options);
document.addEventListener('keyup',selected,options);
return true;
