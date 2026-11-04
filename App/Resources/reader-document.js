// App-owned code, evaluated only in Margined's isolated WKContentWorld.
// Document-supplied JavaScript remains disabled.
const main = document.getElementById('document');
const selector = 'h1,h2,h3,h4,h5,h6,p,li,pre,tr,dt,dd,figure';
function resizeDiagnostic(event, values = {}, position = null) {
    const trace = window.marginedResizeDiagnostics;
    if (!trace) return;
    const first = position?.candidates?.[0];
    trace.events.push({event, time:performance.now(), operation, phase:trace.phase, ...values,
        ...(position ? {saved:{x:position.x,y:position.y,top:position.top,count:position.candidates?.length ?? 0,
            first:first ? {id:first.id,tag:first.tag,length:first.length} : null}} : {})});
    if (trace.events.length > 500) { trace.events.splice(20,1); trace.dropped++; }
}
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
    resizeDiagnostic('scrollInstant', {x,y});
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
    resizeDiagnostic('restore', {found:!!target}, position);
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
    // Callers lease their own document namespace. Mobile remains the default
    // for existing reading-page callers; history must opt into its token.
    const tokenAttribute = typeof documentTokenAttribute === 'undefined' ? 'data-margined-mobile-token' : documentTokenAttribute;
    if (tokenAttribute !== 'data-margined-mobile-token' && tokenAttribute !== 'data-margined-history-token') return false;
    const controller = new AbortController();
    // Use the usable viewport for hit testing and hidden-layout guards. Its
    // classic scrollbar gutter is not a change to the native reading viewport.
    const viewport = document.compatMode === 'BackCompat' ? document.body : document.documentElement;
    const measurementHost = document.createElement('div');
    measurementHost.setAttribute('aria-hidden','true');
    Object.assign(measurementHost.style,{position:'fixed',left:'0px',top:'0px',
        width:'0px',height:'0px',margin:'0px',padding:'0px',border:'0px',
        display:'block',minWidth:'0px',maxWidth:'none',minHeight:'0px',maxHeight:'none',
        boxSizing:'content-box',overflow:'hidden',contain:'strict',visibility:'hidden',pointerEvents:'none'});
    const measurement = document.createElement('div');
    Object.assign(measurement.style,{display:'block',width:'100vw',height:'100vh',
        minWidth:'0px',maxWidth:'none',minHeight:'0px',maxHeight:'none',
        margin:'0px',padding:'0px',border:'0px',boxSizing:'content-box'});
    measurementHost.appendChild(measurement);
    document.documentElement.appendChild(measurementHost);
    // Under the reader's default root overflow:auto, viewport units retain
    // full committed dimensions when a content scrollbar appears or disappears.
    // Unlike innerWidth/innerHeight, this box participates in committed layout.
    let width = measurement.clientWidth, height = measurement.clientHeight, pending = 0;
    function hasUsableViewport() { return viewport.clientWidth > 0 && viewport.clientHeight > 0; }
    let resizeObserver;
    function sample(reason) {
        const box = main?.getBoundingClientRect();
        const viewWidth = viewport.clientWidth, viewHeight = viewport.clientHeight;
        const x = box ? Math.max(1, Math.min(viewWidth - 1, box.left + box.width / 2)) : viewWidth / 2;
        // Point queries avoid scanning the whole document on each scroll.
        // Margins and unusual layouts fall back to the semantic block search.
        let node;
        for (const y of [24, 64, 128]) {
            if (y >= viewHeight) break;
            const candidate = document.elementFromPoint(x, y)?.closest(selector);
            if (candidate && main?.contains(candidate)) { node = candidate; break; }
        }
        node ??= visibleAnchor()?.candidates[0];
        const sampled = {x:scrollX, y:scrollY, top:node?.getBoundingClientRect().top ?? 0,
            focus:null, candidates:node ? [descriptor(node)] : []};
        resizeDiagnostic('sample', {reason,width,height,viewWidth,viewHeight,pending}, sampled);
        return sampled;
    }
    function stop() {
        resizeDiagnostic('stop', {width,height,pending}, saved);
        controller.abort();
        resizeObserver?.disconnect();
        if (pending) cancelAnimationFrame(pending);
        pending = 0;
        measurementHost.remove();
    }
    function current() {
        return !controller.signal.aborted &&
            document.documentElement.getAttribute(tokenAttribute) === documentToken;
    }
    let saved = hasUsableViewport() ? sample('install') : null;
    const options = {passive:true, signal:controller.signal};
    window.addEventListener('scroll', () => {
        resizeDiagnostic('scroll-event', {width,height,pending}, saved);
        if (!current()) { stop(); return; }
        // Retain a user scroll before its pending frame can be overtaken by a
        // layout commit. Never sample a reflowed or hidden page against old dimensions.
        if (!hasUsableViewport()) return;
        if (measurement.clientWidth === width && measurement.clientHeight === height) saved = sample('scroll-event');
        if (pending) cancelAnimationFrame(pending);
        pending = requestAnimationFrame(() => {
            pending = 0;
            if (!current()) { stop(); return; }
            // A scroll event can precede the resize event for the same layout.
            if (!hasUsableViewport()) return;
            if (measurement.clientWidth === width && measurement.clientHeight === height) saved = sample('scroll-frame');
        });
    }, options);
    function commitResize(input) {
        if (!current()) { stop(); return; }
        const nextWidth = measurement.clientWidth, nextHeight = measurement.clientHeight;
        const source = Array.isArray(input) ? 'resize-observer' : input?.type ?? 'direct';
        const box = Array.isArray(input) ? input[0]?.contentRect : null;
        resizeDiagnostic('commit-event', {source,width,height,nextWidth,nextHeight,pending,
            observerBox:box ? {width:box.width,height:box.height} : null}, saved);
        // Viewport-unit boxes can retain dimensions while the usable page is
        // hidden. Neither kind of zero-sized layout may erase a valid snapshot.
        if (!hasUsableViewport() || nextWidth <= 0 || nextHeight <= 0) return;
        if (!saved) { width = nextWidth; height = nextHeight; saved = sample('first-usable'); return; }
        if (nextWidth === width && nextHeight === height) return;
        if (pending) cancelAnimationFrame(pending);
        pending = 0;
        resizeDiagnostic('commit-before-restore', {source,width,height,nextWidth,nextHeight}, saved);
        // TEMPORARY A/B: retain observation and explicit navigation/capture,
        // but let native WebKit alone perform resize scroll restoration on iOS.
        if (typeof nativeResizeRestoration === 'undefined' || !nativeResizeRestoration) restore(saved);
        else resizeDiagnostic('native-resize-restoration', {source,width,height,nextWidth,nextHeight}, saved);
        width = nextWidth; height = nextHeight;
        saved = sample('after-resize-restore');
        resizeDiagnostic('commit-after-restore', {source,width,height}, saved);
    }
    window.addEventListener('resize', commitResize, options);
    // A native resize can dispatch before layout commits, with no later
    // window event. Observe the committed full-viewport box without polling.
    if (typeof ResizeObserver !== 'undefined') {
        resizeObserver = new ResizeObserver(commitResize);
        resizeObserver.observe(measurement);
    }
    window.marginedReadingResize = {stop};
    resizeDiagnostic('installed', {width,height,pending,expectedToken:documentToken,tokenAttribute}, saved);
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
