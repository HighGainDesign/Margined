// Temporary native resize lease. Calls are synchronous in one isolated world.
// The native owner serializes acquisition and coalesced retirement requests.
const root=document.documentElement;
if(lockOperation==='release') {
    const retired=Math.max(Number(window.__marginedNativeResizeRetiredOrder)||0,resizeOrder);
    window.__marginedNativeResizeRetiredOrder=retired;
    const lock=window.__marginedNativeResizeScrollLock;
    if(!lock||lock.order>retired) return true;
    if(lock.root===root) {
        for(const [key,axis,owned] of [['overflow-x','x','hidden'],['overflow-y','y','hidden'],['overflow-anchor','anchor','none']]) {
            // Restore each property only while its exact value/priority is ours.
            if(lock[axis]&&root.style.getPropertyValue(key)===owned&&root.style.getPropertyPriority(key)==='') {
                const saved=lock[axis];
                if(saved.value) root.style.setProperty(key,saved.value,saved.priority);
                else root.style.removeProperty(key);
            }
        }
    }
    delete window.__marginedNativeResizeScrollLock;
    return true;
}
if(root.getAttribute('data-margined-mobile-token')!==documentToken ||
    resizeOrder<=(Number(window.__marginedNativeResizeRetiredOrder)||0)) return false;
const properties=shouldLock ? [['overflow-x','x','hidden'],['overflow-y','y','hidden']] : [];
if(disableAnchor) properties.push(['overflow-anchor','anchor','none']);
if(properties.length===0) return true;
let lock=window.__marginedNativeResizeScrollLock;
if(!lock||lock.root!==root) lock={root};
for(const [key,axis,owned] of properties) {
    const value=root.style.getPropertyValue(key),priority=root.style.getPropertyPriority(key);
    if(!lock[axis]||value!==owned||priority!=='') lock[axis]={value,priority};
    root.style.setProperty(key,owned);
}
lock.session=resizeSession;lock.order=resizeOrder;
window.__marginedNativeResizeScrollLock=lock;
return true;
