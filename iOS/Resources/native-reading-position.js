// Captures normal-flow passages using the native-projected viewport. No scroll or focus writes.
// The native caller must verify matching layout geometry and unchanged origin
// after this reply; this JavaScript result alone is never a commit permission.
const main = document.getElementById('document');
if (!main || document.documentElement.getAttribute('data-margined-mobile-token') !== documentToken) return null;
const selector = 'h1,h2,h3,h4,h5,h6,p,li,pre,tr,dt,dd,figure';
const blocks = Array.from(main.querySelectorAll(selector));
// Read one DOM origin for all absolute coordinates in this synchronous sample.
const domX = scrollX, domY = scrollY;
const viewport = document.compatMode === 'BackCompat' ? document.body : document.documentElement;
const metrics = {width:viewport.clientWidth,height:viewport.clientHeight,
    contentWidth:document.documentElement.scrollWidth,contentHeight:document.documentElement.scrollHeight,
    domX,domY,visual:{width:visualViewport.width,height:visualViewport.height,scale:visualViewport.scale}};
function descriptor(node) {
    return {id:node.id,tag:node.tagName,text:node.textContent.slice(0,1024),
        length:node.textContent.length,label:node.getAttribute('aria-label')};
}
function finite(value) { return typeof value === 'number' && Number.isFinite(value); }
if (operation === 'capture') {
    if (!nativeViewport || !['x','y','width','height'].every(key=>finite(nativeViewport[key])) ||
        nativeViewport.width <= 0 || nativeViewport.height <= 0) return null;
    const visible = blocks.map((node,index) => {
        const rect = node.getBoundingClientRect();
        return {node,index,height:rect.height,top:rect.top+domY-nativeViewport.y,
            bottom:rect.bottom+domY-nativeViewport.y};
    }).filter(block=>block.height>0 && block.bottom>0 && block.top<nativeViewport.height);
    visible.sort((a,b)=>Math.abs(a.top)-Math.abs(b.top));
    const anchor = visible[0];
    const candidates = anchor ? [anchor.node,...blocks.slice(anchor.index+1),...blocks.slice(0,anchor.index).reverse()] : [];
    return {position:{x:nativeViewport.x,y:nativeViewport.y,top:anchor?.top ?? 0,
        focus:null,candidates:candidates.slice(0,128).map(descriptor)},metrics};
}
if (operation === 'destination') {
    if (!position || !['x','y','top'].every(key=>finite(position[key])) || !Array.isArray(position.candidates)) return null;
    let target;
    for (const candidate of position.candidates.slice(0,128)) {
        if (!candidate) continue;
        const matches = node=>node.tagName===candidate.tag && node.textContent.length===candidate.length &&
            node.textContent.slice(0,1024)===candidate.text && node.getAttribute('aria-label')===candidate.label;
        const byID = candidate.id ? document.getElementById(candidate.id) : null;
        target = byID && main.contains(byID) && matches(byID) ? byID : blocks.find(matches);
        if (target) break;
    }
    return {x:position.x,y:target ? domY+target.getBoundingClientRect().top-position.top : position.y,metrics};
}
return null;
