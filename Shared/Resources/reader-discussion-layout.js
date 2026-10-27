// App-owned layout: canonical ranges map back through the current DOM projection.
// Decorations live outside main, preserving text nodes, selections and reading maps.
function marginedDiscussionLayout() {
    const state=window.__marginedDiscussions;
    if (!state || state.token!==token || state.sourceID!==sourceID) return false;
    if (operation==='goTo') {
        const id=typeof threadID==='string' ? threadID : '';
        const item=state.layout?.ranges.find(item=>item.id===id);
        if (!state.allowed.has(id) || !item || !item.range.startContainer.isConnected) return false;
        const element=item.range.startContainer.nodeType===Node.ELEMENT_NODE ? item.range.startContainer : item.range.startContainer.parentElement;
        for(let parent=element;parent;parent=parent.parentElement) if(parent.localName==='details')parent.open=true;
        const rect=item.range.getClientRects()[0] ?? item.range.getBoundingClientRect();
        if (!rect.height) return false;
        const target=element.closest('p,li,pre,th,td,h1,h2,h3,h4,h5,h6,summary,figcaption') ?? element;
        if (typeof focus!=='undefined' && focus) {
            if(!target.hasAttribute('tabindex'))target.setAttribute('tabindex','-1');
            target.focus({preventScroll:true});
        }
        window.scrollTo({top:Math.max(0,scrollY+rect.top-Math.min(80,innerHeight/4)),behavior:'instant'});
        state.layout.refresh();
        return true;
    }
    const projection=state.projection ?? project();
    if (typeof expectedText!=='string' || projection.text!==expectedText) return false;
    state.projection=projection;
    function boundary(unit,offset,end) {
        if (!Number.isInteger(offset) || offset<0 || offset>unit.raw.length) return null;
        const parts=end ? [...unit.parts].reverse() : unit.parts;
        const part=parts.find(p=>p.location<=offset && offset<=p.location+p.length);
        if(!part || !part.node.isConnected)return null;
        if(part.kind==='text')return {node:part.node,offset:offset-part.location};
        const parent=part.node.parentNode,index=Array.prototype.indexOf.call(parent.childNodes,part.node);
        return {node:parent,offset:index+(end ? 1 : 0)};
    }
    function rangeFor(anchor) {
        if (!anchor || !state.allowed.has(anchor.id) || ![anchor.location,anchor.length,anchor.startUnit,anchor.startOffset,anchor.endUnit,anchor.endOffset].every(Number.isInteger)) return null;
        const first=projection.units[anchor.startUnit],last=projection.units[anchor.endUnit];
        if(!first || !last || anchor.length<=0 || anchor.location<0)return null;
        const begin=canonicalOffset(first,anchor.startOffset),finish=canonicalOffset(last,anchor.endOffset);
        if(begin===null || finish===null || first.location+begin!==anchor.location || last.location+finish!==anchor.location+anchor.length)return null;
        const start=boundary(first,anchor.startOffset,false),end=boundary(last,anchor.endOffset,true);
        if(!start || !end)return null;
        const range=document.createRange();
        try{range.setStart(start.node,start.offset);range.setEnd(end.node,end.offset);}catch{return null;}
        return range.collapsed ? null : range;
    }
    state.layout?.dispose();
    const seen=new Set(),ranges=[];
    for(const anchor of typeof anchors!=='undefined' && Array.isArray(anchors) ? anchors : []) {
        if(seen.has(anchor.id))continue;
        const range=rangeFor(anchor);if(range){seen.add(anchor.id);ranges.push({id:anchor.id,range,location:anchor.location,length:anchor.length});}
    }
    const layout={ranges,visible:typeof visible!=='undefined' && visible,selected:typeof selectedID==='string' ? selectedID : '',
        label:typeof markerLabel==='string' ? markerLabel : 'Open discussion',positions:[],overlay:null,observer:null,pending:null,abort:new AbortController()};
    state.layout=layout;
    function positioned(className,rect,parent) {
        const node=document.createElement('span');node.className=className;
        Object.assign(node.style,{left:`${rect.left+scrollX}px`,top:`${rect.top+scrollY}px`,width:`${rect.width}px`,height:`${rect.height}px`});
        node.setAttribute('aria-hidden','true');parent.appendChild(node);return node;
    }
    function snapshot() {
        const bodyStyle=getComputedStyle(document.body),mainStyle=getComputedStyle(main);
        return {kind:'geometry',token,sourceID,bodyFont:parseFloat(bodyStyle.fontSize),
            horizontalInsets:(parseFloat(mainStyle.paddingLeft)||0)+(parseFloat(mainStyle.paddingRight)||0),
            viewportHeight:innerHeight,anchors:layout.visible ? layout.positions.map(item=>({id:item.id,top:item.top-scrollY,height:item.height})) : []};
    }
    function publish(){if(window.__marginedDiscussions===state)window.webkit?.messageHandlers?.discussion?.postMessage(snapshot());}
    function refresh() {
        if(window.__marginedDiscussions!==state)return;
        layout.overlay?.remove();layout.positions=[];
        if(!layout.visible){publish();return;}
        const layer=document.createElement('div');layer.className='margined-note-layer margined-discussion-decoration';
        const groups=new Map(),documentHeight=document.documentElement.scrollHeight;
        // innerWidth includes classic scrollbars. Decorations belong inside the
        // usable page, and their leader lines stay outside the prose column.
        const viewportWidth=document.documentElement.clientWidth;
        const markerLeft=Math.max(0,viewportWidth-28);
        const mainRect=main.getBoundingClientRect(),mainStyle=getComputedStyle(main);
        const gutterStart=Math.max(0,mainRect.right-(parseFloat(mainStyle.paddingRight)||0)+4);
        for(const item of ranges) {
            if(!item.range.startContainer.isConnected)continue;
            const rects=Array.from(item.range.getClientRects()).filter(r=>r.width>0 && r.height>0);
            if(!rects.length)continue;
            const first=rects[0];layout.positions.push({id:item.id,top:first.top+scrollY,height:first.height});
            const key=`${item.location}:${item.length}`;
            if(!groups.has(key))groups.set(key,{rects,items:[]});groups.get(key).items.push(item);
        }
        let previous=-Infinity;
        for(const group of [...groups.values()].sort((a,b)=>a.rects[0].top-b.rects[0].top)) {
            const active=group.items.some(item=>item.id===layout.selected),color=active ? ' margined-note-selected' : '';
            for(const rect of group.rects) {
                if(active)positioned('margined-note-fill',rect,layer);
                positioned('margined-note-line'+color,{left:rect.left,top:rect.bottom-1,width:rect.width,height:1},layer);
            }
            const first=group.rects[0],y=Math.min(documentHeight-24,Math.max(first.top+scrollY,previous+28));previous=y;
            const marker=document.createElement('button');marker.type='button';marker.className='margined-note-button'+color;
            marker.dataset.marginedThread=(group.items.find(item=>item.id===layout.selected) ?? group.items[0]).id;
            marker.textContent=String(group.items.length);marker.setAttribute('aria-label',`${layout.label} (${group.items.length})`);marker.title=marker.getAttribute('aria-label');
            Object.assign(marker.style,{left:`${markerLeft+scrollX}px`,top:`${Math.max(0,y)}px`});layer.appendChild(marker);
            if(gutterStart<markerLeft-2) positioned('margined-note-connector'+color,{left:gutterStart,top:first.top+first.height/2,width:markerLeft-2-gutterStart,height:1},layer);
        }
        document.body.appendChild(layer);layout.overlay=layer;publish();
    }
    function schedule(full) {
        if(layout.pending!==null)cancelAnimationFrame(layout.pending);
        layout.pending=requestAnimationFrame(()=>{layout.pending=null;full ? refresh() : publish();});
    }
    layout.refresh=refresh;
    const options={signal:layout.abort.signal};
    window.addEventListener('scroll',()=>schedule(false),options);
    window.addEventListener('resize',()=>schedule(true),options);
    main.addEventListener('load',()=>schedule(true),{...options,capture:true});
    layout.observer=new ResizeObserver(()=>schedule(true));layout.observer.observe(main);
    layout.dispose=()=>{layout.abort.abort();state.abort.signal.removeEventListener('abort',layout.dispose);if(layout.pending!==null)cancelAnimationFrame(layout.pending);layout.observer?.disconnect();layout.overlay?.remove();};
    state.abort.signal.addEventListener('abort',layout.dispose,{once:true});
    refresh();return snapshot();
}
