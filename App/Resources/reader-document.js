// App-owned code, evaluated only in Margined's isolated WKContentWorld.
// Document-supplied JavaScript remains disabled.
const main = document.getElementById('document');
const selector = 'h1,h2,h3,h4,h5,h6,p,li,pre,tr,dt,dd,figure';
function visibleAnchor() {
    if (!main) return null;
    const blocks = Array.from(main.querySelectorAll(selector));
    const visible = blocks.filter(node => {
        const rect = node.getBoundingClientRect();
        return rect.height > 0 && rect.bottom > 0 && rect.top < innerHeight;
    });
    const node = visible.sort((a,b) => Math.abs(a.getBoundingClientRect().top) - Math.abs(b.getBoundingClientRect().top))[0];
    if (!node) return null;
    const index = blocks.indexOf(node);
    // If the reading block disappears, prefer the next surviving block.
    const candidates = [node, ...blocks.slice(index + 1), ...blocks.slice(0,index).reverse()];
    return {top:node.getBoundingClientRect().top, candidates};
}
function descriptor(node) {
    return {id:node.id, tag:node.tagName, text:node.textContent.slice(0,1024), length:node.textContent.length, label:node.getAttribute('aria-label')};
}
function snapshot() {
    const anchor = visibleAnchor();
    const active = document.activeElement;
    return {x:scrollX, y:scrollY, top:anchor?.top ?? 0,
        focus:active && main?.contains(active) ? descriptor(active) : null,
        candidates:anchor ? anchor.candidates.slice(0,128).map(descriptor) : []};
}
function scrollInstant(x,y) {
    const previous = document.documentElement.style.scrollBehavior;
    document.documentElement.style.scrollBehavior = 'auto';
    window.scrollTo(x,y);
    document.documentElement.style.scrollBehavior = previous;
}
function locate(candidate, blocks) {
    const matches = node => node.tagName === candidate.tag && node.textContent.length === candidate.length &&
        node.textContent.slice(0,1024) === candidate.text && node.getAttribute('aria-label') === candidate.label;
    const byID = candidate.id ? document.getElementById(candidate.id) : null;
    return byID && matches(byID) ? byID : blocks.find(matches);
}
function restore(position) {
    if (!position) return;
    let target;
    const blocks = Array.from(document.querySelectorAll(selector));
    for (const candidate of position.candidates ?? []) {
        target = locate(candidate,blocks);
        if (target) break;
    }
    if (restoreFocus && position.focus) {
        const active = locate(position.focus,Array.from(main?.querySelectorAll('*') ?? []));
        if (active && !active.disabled) {
            if (!active.matches('a[href],input,button,summary')) active.tabIndex = -1;
            active.focus({preventScroll:true});
        }
    }
    scrollInstant(position.x, target ? scrollY + target.getBoundingClientRect().top - position.top : position.y);
}
if (operation === 'navigate') {
    let target;
    if (kind === 'element') {
        target = document.getElementById(id);
        window.marginedLastTask = null;
    } else if (kind === 'unchecked') {
        const tasks = Array.from(main?.querySelectorAll('input[type="checkbox"]') ?? []).filter(node => !node.defaultChecked);
        if (!tasks.length) return false;
        const active = document.activeElement;
        let index = tasks.findIndex(node => node === active || node.closest('li') === active);
        if (index < 0) index = tasks.indexOf(window.marginedLastTask);
        if (index >= 0) index = (index + (backwards ? -1 : 1) + tasks.length) % tasks.length;
        else {
            const next = tasks.findIndex(node => node.getBoundingClientRect().top >= 0);
            index = backwards ? (next < 0 ? tasks.length-1 : (next-1+tasks.length)%tasks.length) : (next < 0 ? 0 : next);
        }
        window.marginedLastTask = tasks[index];
        target = tasks[index].disabled ? tasks[index].closest('li') ?? tasks[index].parentElement : tasks[index];
    } else if (kind === 'reading') {
        target = visibleAnchor()?.candidates[0] ?? main;
    }
    if (!target) return false;
    if (focus) {
        if (!target.matches('a[href],input:not([disabled]),button,summary')) target.tabIndex = -1;
        target.focus({preventScroll:true});
    }
    // Focused jumps are atomic: an older smooth-scroll animation must not
    // keep moving the viewport after a policy reload or newer focus request.
    if (kind !== 'reading') target.scrollIntoView({block:'start',behavior:focus ? 'instant' : 'auto'});
    return true;
}
// Keep the passage being read, rather than its old pixel offset, while a
// live window resize reflows paragraphs. Cache before layout, because the
// resize event arrives after WebKit has already changed line wrapping.
if (operation === 'observeResize') {
    window.marginedReadingResize?.stop();
    const controller = new AbortController();
    let width = innerWidth, height = innerHeight, pending = 0;
    function sample() {
        const box = main?.getBoundingClientRect();
        const x = box ? Math.max(1, Math.min(innerWidth - 1, box.left + box.width / 2)) : innerWidth / 2;
        // Point queries avoid scanning the whole document on each scroll.
        // Margins and unusual layouts fall back to the semantic block search.
        let node;
        for (const y of [24, 64, 128]) {
            if (y >= innerHeight) break;
            const candidate = document.elementFromPoint(x, y)?.closest(selector);
            if (candidate && main?.contains(candidate)) { node = candidate; break; }
        }
        node ??= visibleAnchor()?.candidates[0];
        return {x:scrollX, y:scrollY, top:node?.getBoundingClientRect().top ?? 0,
            focus:null, candidates:node ? [descriptor(node)] : []};
    }
    function stop() {
        controller.abort();
        if (pending) cancelAnimationFrame(pending);
        pending = 0;
    }
    function current() {
        return !controller.signal.aborted &&
            document.documentElement.getAttribute('data-margined-mobile-token') === documentToken;
    }
    let saved = sample();
    const options = {passive:true, signal:controller.signal};
    window.addEventListener('scroll', () => {
        if (!current()) { stop(); return; }
        if (pending) cancelAnimationFrame(pending);
        pending = requestAnimationFrame(() => {
            pending = 0;
            if (!current()) { stop(); return; }
            // A scroll event can precede the resize event for the same layout.
            if (innerWidth === width && innerHeight === height) saved = sample();
        });
    }, options);
    window.addEventListener('resize', () => {
        if (!current()) { stop(); return; }
        if (innerWidth === width && innerHeight === height) return;
        if (pending) cancelAnimationFrame(pending);
        pending = 0;
        restore(saved);
        width = innerWidth; height = innerHeight;
        saved = sample();
    }, options);
    window.marginedReadingResize = {stop};
    return true;
}
if (operation === 'capture') return snapshot();
if (operation === 'restore') { restore(position); return true; }
if (operation !== 'update') return false;
const next = new DOMParser().parseFromString(html,'text/html');
const nextMain = next.getElementById('document');
// A changed CSP or stylesheet must still take the full navigation path.
if (!main || !nextMain || next.head.innerHTML !== document.head.innerHTML) return false;
const anchor = visibleAnchor();
const x = scrollX, y = scrollY;
const active = document.activeElement;
function identity(node) {
    if (node.nodeType !== Node.ELEMENT_NODE) return `${node.nodeType}:${node.nodeValue}`;
    const content = node.tagName === 'INPUT' ? node.getAttribute('aria-label') ?? '' :
        node.tagName === 'IMG' ? node.getAttribute('data-margined-image-source') ?? node.getAttribute('src') ?? '' : node.textContent;
    // Generated review IDs and task offsets are not stable identities. Bound
    // keys on large nested blocks; reconciliation still checks all their text.
    return `${node.tagName}:${content.length}:${content.slice(0,256)}:${content.slice(-128)}`;
}
function compatible(a,b) { return a.nodeType === b.nodeType && a.nodeName === b.nodeName; }
function attributes(a,b) {
    for (const attr of Array.from(a.attributes)) if (!(a.tagName === 'INPUT' && attr.name === 'disabled') && !(attr.name === 'tabindex' && attr.value === '-1') && !b.hasAttribute(attr.name)) a.removeAttribute(attr.name);
    for (const attr of Array.from(b.attributes)) if (!(a.tagName === 'INPUT' && attr.name === 'disabled') && a.getAttribute(attr.name) !== attr.value) a.setAttribute(attr.name,attr.value);
}
function reconcile(a,b) {
    if (a === b) return;
    if (a.nodeType !== Node.ELEMENT_NODE) {
        if (a.nodeValue !== b.nodeValue) a.nodeValue = b.nodeValue;
        return;
    }
    attributes(a,b);
    const oldChildren = Array.from(a.childNodes), newChildren = Array.from(b.childNodes);
    const byIdentity = new Map();
    for (const child of oldChildren) {
        const key = identity(child);
        if (!byIdentity.has(key)) byIdentity.set(key,[]);
        byIdentity.get(key).push(child);
    }
    const used = new Set();
    // Claim every exact sibling match before reusing any changed sibling, so
    // insertions cannot consume the paragraph/input currently being read.
    const chosen = newChildren.map(child => {
        const match = byIdentity.get(identity(child))?.shift();
        if (match) used.add(match);
        return match;
    });
    for (let i=0;i<newChildren.length;i++) {
        if (chosen[i]) continue;
        const fallback = oldChildren[i];
        if (fallback && !used.has(fallback) && compatible(fallback,newChildren[i])) {
            chosen[i] = fallback; used.add(fallback);
        }
    }
    for (let i=0;i<newChildren.length;i++) {
        const child = chosen[i] ?? newChildren[i];
        if (a.childNodes[i] !== child) a.insertBefore(child,a.childNodes[i] ?? null);
        reconcile(child,newChildren[i]);
    }
    for (const child of oldChildren) if (!used.has(child) && child.parentNode === a) child.remove();
}
reconcile(main,nextMain);
attributes(document.body,next.body);
attributes(document.documentElement,next.documentElement);
const surviving = anchor?.candidates.find(node => node.isConnected);
scrollInstant(x,surviving ? scrollY + surviving.getBoundingClientRect().top - anchor.top : y);
// Keep a surviving DOM focus when a reorder temporarily blurs it. This never
// makes WebKit the native first responder or focuses an unrelated window.
if (restoreFocus && active && active !== document.body && active.isConnected && document.activeElement !== active) {
    active.focus({preventScroll:true});
}
return true;
