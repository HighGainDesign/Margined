'use strict';

// No packages or browser automation. Execute the complete, unmodified input
// reader-document.js in a vm. Logical full viewport, usable root/body dimensions,
// and stale inner* values are independent adapter inputs, not a CSS engine.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const sourcePath = process.argv[2];
if (!sourcePath) throw new Error('Usage: node regression.cjs path/to/reader-document.js [test-name-filter]');
const source = fs.readFileSync(sourcePath, 'utf8');
const script = new vm.Script(`(function () {\n${source}\n})()`, {filename: sourcePath});
const tests = [];
const test = (name, run) => tests.push({name, run});

function rig({attribute = 'data-margined-mobile-token', resizeObserver = true, compatMode = 'CSS1Compat'} = {}) {
    const state = {
        innerWidth: 550, innerHeight: 446, rootWidth: 550, rootHeight: 446,
        layoutWidth: 550, layoutHeight: 446, createdElements: [],
        x: 0, y: 3538, targetTop: 3541.1875, frames: new Map(), nextFrame: 1,
        scrollWrites: [], navigationScrolls: [], observers: [], listeners: new Map(), focusWrites: 0,
        attributes: new Map([[attribute, 'lease-A']])
    };
    const nodes = Array.from({length: 70}, (_, index) => ({
        id: index === 35 ? 'resize-reading-passage' : `paragraph-${index}`,
        tagName: 'P', textContent: `Synthetic paragraph ${index}.`, isConnected: true,
        getAttribute() { return null; },
        getBoundingClientRect() {
            if (state.rootWidth === 0) return {left: 0, right: 0, width: 0, top: 0, bottom: 0, height: 0};
            const top = state.targetTop + (index - 35) * 100 - state.y;
            return {left: 0, right: state.rootWidth, width: state.rootWidth, top, bottom: top + 90, height: 90};
        },
        closest() { return this; },
        matches() { return false; },
        scrollIntoView(options) {
            state.y = Math.floor(state.y + this.getBoundingClientRect().top);
            state.navigationScrolls.push(options);
            // WebKit delivers the resulting scroll event asynchronously.
        },
        focus() { state.focusWrites++; document.activeElement = this; }
    }));
    const main = {
        id: 'document', querySelectorAll() { return nodes; },
        contains(node) { return nodes.includes(node); },
        getBoundingClientRect() { return {left: 0, width: state.rootWidth}; }
    };
    const root = {
        style: {scrollBehavior: 'smooth'}, children: [],
        appendChild(node) { node.parentNode = this; this.children.push(node); return node; },
        get clientWidth() { return compatMode === 'BackCompat' ? 1200 : state.rootWidth; },
        get clientHeight() { return compatMode === 'BackCompat' ? 9000 : state.rootHeight; },
        getAttribute(key) { return state.attributes.get(key) ?? null; }
    };
    const document = {
        compatMode, documentElement: root,
        body: {get clientWidth() { return state.rootWidth; }, get clientHeight() { return state.rootHeight; }},
        activeElement: null,
        getElementById(id) { return id === 'document' ? main : nodes.find(node => node.id === id) ?? null; },
        querySelectorAll() { return nodes; },
        createElement(tag) {
            const attributes = new Map();
            const node = {
                tagName: tag.toUpperCase(), style: {}, children: [], parentNode: null, textContent: '',
                get isConnected() {
                    let ancestor = this;
                    while (ancestor.parentNode) ancestor = ancestor.parentNode;
                    return ancestor === root;
                },
                get clientWidth() {
                    if (!this.isConnected) return 0;
                    return this.style.width === '100vw' ? state.layoutWidth : Number.parseFloat(this.style.width) || 0;
                },
                get clientHeight() {
                    if (!this.isConnected) return 0;
                    return this.style.height === '100vh' ? state.layoutHeight : Number.parseFloat(this.style.height) || 0;
                },
                setAttribute(key, value) { attributes.set(key, String(value)); },
                getAttribute(key) { return attributes.get(key) ?? null; },
                appendChild(child) { child.parentNode = this; this.children.push(child); return child; },
                remove() {
                    if (this.parentNode) this.parentNode.children = this.parentNode.children.filter(child => child !== this);
                    this.parentNode = null;
                }
            };
            state.createdElements.push(node);
            return node;
        },
        elementFromPoint(x, y) {
            if (x < 0 || x >= state.rootWidth || y < 0 || y >= state.rootHeight) return null;
            return nodes.find(node => {
                const rect = node.getBoundingClientRect();
                return rect.top <= y && rect.bottom > y;
            }) ?? null;
        }
    };
    document.activeElement = document.body;
    const authoredNode = document.createElement('div');
    authoredNode.setAttribute('data-authored', 'keep'); root.appendChild(authoredNode);
    function addEventListener(name, callback, options = {}) {
        if (options.signal?.aborted) return;
        const entries = state.listeners.get(name) ?? new Set();
        state.listeners.set(name, entries);
        const entry = {callback}; entries.add(entry);
        options.signal?.addEventListener('abort', () => entries.delete(entry), {once: true});
    }
    const context = vm.createContext({
        document, AbortController,
        get innerWidth() { return state.innerWidth; },
        get innerHeight() { return state.innerHeight; },
        get scrollX() { return state.x; },
        get scrollY() { return state.y; },
        requestAnimationFrame(callback) {
            const id = state.nextFrame++; state.frames.set(id, callback); return id;
        },
        cancelAnimationFrame(id) { state.frames.delete(id); },
        operation: 'observeResize', restoreFocus: false, documentToken: 'lease-A', documentTokenAttribute: attribute,
        ResizeObserver: resizeObserver ? class {
            constructor(callback) { this.callback = callback; this.active = false; state.observers.push(this); }
            observe(target) {
                assert.ok(target === root || (target.parentNode?.parentNode === root &&
                    target.style.width === '100vw' && target.style.height === '100vh'),
                    'Observe the original root or the owned full-viewport measurement child');
                this.target = target; this.active = true;
            }
            disconnect() { this.active = false; }
        } : undefined
    });
    context.window = context;
    context.addEventListener = addEventListener;
    context.scrollTo = (x, y) => {
        state.x = x; state.y = Math.floor(y);
        state.scrollWrites.push({x, requestedY: y, y: state.y});
    };
    const target = nodes[35];
    const api = {
        state, context, target, nodes, root, document, authoredNode,
        run(args) {
            Object.assign(context, args);
            return script.runInContext(context);
        },
        install({token = 'lease-A', tokenAttribute = attribute} = {}) {
            context.operation = 'observeResize'; context.documentToken = token; context.documentTokenAttribute = tokenAttribute;
            return script.runInContext(context);
        },
        emit(name) { for (const {callback} of [...(state.listeners.get(name) ?? [])]) callback(); },
        frame() {
            const callbacks = [...state.frames.values()]; state.frames.clear();
            for (const callback of callbacks) callback();
        },
        committedResize(width, height, targetTop, {deliver = true} = {}) {
            state.rootWidth = width; state.rootHeight = height; state.targetTop = targetTop;
            state.layoutWidth = width; state.layoutHeight = height;
            if (deliver) api.deliverResizeObserver();
        },
        usableResize(width, height, targetTop, {deliver = true} = {}) {
            state.rootWidth = width; state.rootHeight = height; state.targetTop = targetTop;
            if (deliver) api.deliverResizeObserver();
        },
        deliverResizeObserver() {
            for (const observer of state.observers) if (observer.active) observer.callback([{target: observer.target}]);
        },
        userScrollToParagraph(index) {
            state.y = state.targetTop + (index - 35) * 100 - 3.1875;
            api.emit('scroll');
        },
        assertAnchor(index = 35) {
            const rect = nodes[index].getBoundingClientRect();
            assert.ok(Math.abs(rect.top - 3.1875) <= 1,
                `paragraph ${index} must retain its pre-reflow top; actual=${rect.top}, scrollY=${state.y}`);
            assert.equal(state.focusWrites, 0, 'resize must not steal DOM focus');
            assert.equal(root.style.scrollBehavior, 'smooth', 'temporary instant restoration must retain authored scroll policy');
        }
    };
    assert.equal(api.install(), true);
    return api;
}

test('stale-inner-size-at-resize-event', () => {
    const r = rig();
    // Captured failure: cached 550x446, saved p35 at y3538/top3.1875;
    // later committed 890-wide layout puts p35 at -898.625 with no later resize.
    r.committedResize(890, 446, 2639.375, {deliver: false});
    r.emit('resize'); // innerWidth/Height deliberately remain 550/446.
    r.assertAnchor();
});

test('layout-commits-after-last-window-resize', () => {
    const r = rig();
    r.emit('resize'); // Both APIs still report the old dimensions in this event.
    r.committedResize(890, 446, 2639.375); // Layout commit; no window resize follows.
    r.assertAnchor();
});

test('pending-scroll-frame-does-not-replace-pre-reflow-anchor', () => {
    const r = rig();
    r.emit('scroll');
    assert.equal(r.state.frames.size, 1);
    r.committedResize(890, 446, 2639.375);
    r.frame();
    r.assertAnchor();
});

test('finished-user-scroll-is-the-next-reading-anchor', () => {
    const r = rig();
    r.userScrollToParagraph(36); r.frame();
    r.committedResize(890, 446, 2639.375); r.emit('resize');
    r.assertAnchor(36);
});

test('pending-user-scroll-is-not-lost-to-resize', () => {
    const r = rig();
    r.userScrollToParagraph(36); // Its sampling frame has not run yet.
    r.committedResize(890, 446, 2639.375);
    r.frame();
    r.assertAnchor(36);
});

test('same-size-content-notification-preserves-user-scroll', () => {
    const r = rig();
    r.userScrollToParagraph(37);
    r.deliverResizeObserver(); r.frame();
    assert.equal(r.state.scrollWrites.length, 0, 'a content-only observation is not a viewport resize');
    r.committedResize(890, 446, 2639.375); r.emit('resize');
    r.assertAnchor(37);
});

test('height-only-committed-layout-restores-the-anchor', () => {
    const r = rig();
    r.emit('resize');
    r.committedResize(550, 600, 3000);
    r.assertAnchor();
});

test('zero-sized-hidden-layout-cannot-erase-the-reading-anchor', () => {
    const r = rig();
    // A root observation while hidden must not replace the valid pre-hide
    // semantic snapshot with empty geometry. No window resize occurs here.
    r.committedResize(0, 0, 0);
    r.state.innerWidth = 890; r.state.innerHeight = 446;
    r.committedResize(890, 446, 2639.375); r.emit('resize');
    r.assertAnchor();
});

test('quirks-document-uses-body-viewport-with-root-layout-observation', () => {
    const r = rig({compatMode: 'BackCompat', attribute: 'data-margined-history-token'});
    r.emit('resize');
    r.committedResize(890, 446, 2639.375);
    r.assertAnchor();
});

test('stop-cancels-frame-disconnects-observer-and-rejects-late-delivery', () => {
    const r = rig(); r.emit('scroll');
    const old = r.state.observers[0];
    r.context.marginedReadingResize.stop();
    assert.equal(r.state.frames.size, 0);
    assert.equal([...r.state.listeners.values()].reduce((sum, entries) => sum + entries.size, 0), 0);
    assert.ok(!old || !old.active);
    r.committedResize(890, 446, 2639.375);
    old?.callback([]); r.emit('resize'); r.emit('scroll'); r.frame();
    assert.equal(r.state.scrollWrites.length, 0);
});

test('expired-mobile-token-cannot-restore-or-resample', () => {
    const r = rig(); r.emit('scroll');
    r.state.attributes.set('data-margined-mobile-token', 'lease-B');
    r.committedResize(890, 446, 2639.375); r.emit('resize'); r.frame();
    assert.equal(r.state.scrollWrites.length, 0);
    assert.equal(r.state.frames.size, 0);
    assert.ok(r.state.observers.every(observer => !observer.active));
});

test('history-token-namespace-remains-independent', () => {
    const r = rig({attribute: 'data-margined-history-token'});
    r.state.attributes.set('data-margined-mobile-token', 'unrelated');
    r.committedResize(890, 446, 2639.375); r.emit('resize'); r.assertAnchor();
    const writes = r.state.scrollWrites.length;
    r.state.attributes.set('data-margined-history-token', 'lease-B');
    r.committedResize(550, 446, 3541.1875); r.emit('resize');
    assert.equal(r.state.scrollWrites.length, writes);
});

test('reinstall-disconnects-the-old-observer-and-pending-frame', () => {
    const r = rig(); r.emit('scroll'); const old = r.state.observers[0];
    assert.equal(r.install(), true);
    assert.equal(r.state.frames.size, 0);
    assert.ok(!old || !old.active);
    r.committedResize(890, 446, 2639.375, {deliver: false});
    old?.callback([]);
    assert.equal(r.state.scrollWrites.length, 0);
    r.deliverResizeObserver(); r.emit('resize'); r.assertAnchor();
});

test('unsupported-token-attribute-cannot-leave-a-prior-observer-active', () => {
    const r = rig(); r.emit('scroll');
    assert.equal(r.install({tokenAttribute: 'data-author-token'}), false);
    r.committedResize(890, 446, 2639.375); r.emit('resize'); r.frame();
    assert.equal(r.state.scrollWrites.length, 0);
    assert.equal(r.state.frames.size, 0);
    assert.ok(r.state.observers.every(observer => !observer.active));
});

test('window-resize-fallback-without-resize-observer', () => {
    const r = rig({resizeObserver: false});
    r.state.innerWidth = 890; r.state.innerHeight = 446;
    r.committedResize(890, 446, 2639.375, {deliver: false}); r.emit('resize');
    r.assertAnchor();
});

for (const compatMode of ['CSS1Compat', 'BackCompat']) {
    test('auto-gutter-17px-late-observation-preserves-explicit-scroll-' + compatMode, () => {
        const r = rig({compatMode, attribute: 'data-margined-history-token'});
        r.usableResize(533, 446, 3660, {deliver: false});
        assert.equal(r.state.layoutWidth, 550, 'Automatic gutter does not change the logical viewport');
        r.userScrollToParagraph(38); // No sampling frame has run before the late RO.
        const explicitY = r.state.y;
        r.deliverResizeObserver(); r.frame();
        assert.equal(r.state.scrollWrites.length, 0, 'A gutter-only observation must not restore the old anchor');
        assert.equal(r.state.y, explicitY, 'The explicit ending jump must survive');
        r.committedResize(890, 446, 2639.375); r.assertAnchor(38);
    });
}
test('actual-native-17px-width-change-must-restore', () => {
    const r = rig();
    r.committedResize(533, 446, 3660);
    assert.equal(r.state.scrollWrites.length, 1, 'A native 17px change is a resize, never a gutter heuristic');
    r.assertAnchor();
});
test('actual-native-17px-height-change-must-restore', () => {
    const r = rig();
    r.committedResize(550, 429, 3660);
    assert.equal(r.state.scrollWrites.length, 1);
    r.assertAnchor();
});
for (const compatMode of ['CSS1Compat', 'BackCompat']) {
    test('zero-usable-page-cannot-resample-positive-measurement-child-' + compatMode, () => {
        const r = rig({compatMode});
        r.usableResize(0, 0, 0, {deliver: false});
        assert.equal(r.state.layoutWidth, 550); assert.equal(r.state.layoutHeight, 446);
        r.state.y = 0; r.emit('scroll'); r.frame(); r.deliverResizeObserver();
        assert.equal(r.state.scrollWrites.length, 0, 'Hidden geometry must not initiate restoration');
        r.usableResize(550, 446, 3541.1875, {deliver: false});
        r.committedResize(890, 446, 2639.375);
        r.assertAnchor();
    });
}
test('lease-stop-removes-only-its-owned-measurement-host', () => {
    const r = rig(); const old = r.state.observers[0], host = old.target.parentNode;
    r.emit('scroll'); r.context.marginedReadingResize.stop();
    assert.equal(host.parentNode, null); assert.ok(!old.active);
    assert.equal(r.root.children.length, 1); assert.equal(r.root.children[0], r.authoredNode);
    assert.equal(r.authoredNode.getAttribute('data-authored'), 'keep');
    assert.equal(r.state.frames.size, 0);
    r.committedResize(533, 446, 3660, {deliver: false});
    old.callback([{target: old.target}]);
    assert.equal(r.state.scrollWrites.length, 0);
});
test('lease-reinstall-replaces-only-the-prior-owned-host', () => {
    const r = rig(); const old = r.state.observers[0], host = old.target.parentNode;
    r.emit('scroll'); assert.equal(r.install(), true);
    const current = r.state.observers.find(observer => observer.active);
    assert.ok(current && current !== old); assert.ok(!old.active);
    assert.equal(host.parentNode, null); assert.equal(r.state.frames.size, 0);
    assert.equal(r.root.children.length, 2); assert.ok(r.root.children.includes(r.authoredNode));
    assert.equal(current.target.parentNode.parentNode, r.root);
});
test('expired-lease-removes-the-owned-host-and-rejects-late-measurement', () => {
    const r = rig(); const old = r.state.observers[0], host = old.target.parentNode;
    r.state.attributes.set('data-margined-mobile-token', 'lease-B');
    r.committedResize(533, 446, 3660);
    assert.equal(host.parentNode, null); assert.ok(!old.active);
    assert.equal(r.state.scrollWrites.length, 0);
    assert.equal(r.root.children.length, 1); assert.equal(r.root.children[0], r.authoredNode);
});

test('owned-instant-navigation-publishes-before-the-scroll-event', () => {
    const r = rig(), target = r.nodes[36];
    assert.equal(r.run({operation:'navigate',kind:'element',id:target.id,focus:true}), true);
    assert.equal(r.state.navigationScrolls[0].behavior, 'instant');
    const top = target.getBoundingClientRect().top;
    r.committedResize(890, 446, 2639.375);
    assert.ok(Math.abs(target.getBoundingClientRect().top-top) <= 1,
        'A resize before the queued scroll event must retain the newer passage jump');
    assert.equal(r.document.activeElement, target);
    assert.equal(r.state.focusWrites, 1, 'resize must not refocus the target');
});
test('owned-navigation-after-reflow-supersedes-the-undelivered-resize', () => {
    const r = rig(), target = r.nodes[36];
    r.committedResize(286, 446, 5971.1875, {deliver:false});
    assert.equal(r.run({operation:'navigate',kind:'element',id:target.id,focus:true}), true);
    const top = target.getBoundingClientRect().top;
    r.deliverResizeObserver();
    assert.equal(r.state.scrollWrites.length, 0, 'The old reading anchor must not undo newer navigation');
    r.committedResize(890, 446, 2639.375);
    assert.ok(Math.abs(target.getBoundingClientRect().top-top) <= 1);
});
test('explicit-restore-publishes-before-the-scroll-event', () => {
    const r = rig(), target = r.nodes[36];
    r.state.y = Math.floor(r.state.targetTop+100);
    const position = r.run({operation:'capture'});
    r.state.y = 3538;
    assert.equal(r.run({operation:'restore',position}), true);
    const top = target.getBoundingClientRect().top;
    r.committedResize(890, 446, 2639.375);
    assert.ok(Math.abs(target.getBoundingClientRect().top-top) <= 1,
        'The restored semantic position must replace the older resize snapshot synchronously');
});
test('failed-navigation-cannot-publish-a-stale-dom-position', () => {
    const r = rig();
    r.state.y = 4000;
    assert.equal(r.run({operation:'navigate',kind:'element',id:'missing',focus:true}), false);
    r.committedResize(890, 446, 2639.375); r.assertAnchor();
});
test('unfocused-smooth-navigation-does-not-publish-its-starting-position', () => {
    const r = rig(), target = r.nodes[36];
    r.state.y = 4000;
    target.scrollIntoView = options => r.state.navigationScrolls.push(options);
    assert.equal(r.run({operation:'navigate',kind:'element',id:target.id,focus:false}), true);
    assert.equal(r.state.navigationScrolls[0].behavior, 'auto');
    r.committedResize(890, 446, 2639.375); r.assertAnchor();
});
test('null-restore-cannot-publish-a-stale-dom-position', () => {
    const r = rig();
    r.state.y = 4000;
    assert.equal(r.run({operation:'restore',position:null}), true);
    r.committedResize(890, 446, 2639.375); r.assertAnchor();
});
test('navigation-cannot-revive-an-expired-resize-lease', () => {
    const r = rig(), target = r.nodes[36];
    r.state.attributes.set('data-margined-mobile-token','replacement');
    assert.equal(r.run({operation:'navigate',kind:'element',id:target.id,focus:true}), true);
    r.committedResize(890, 446, 2639.375);
    assert.equal(r.state.scrollWrites.length, 0);
    assert.equal(r.root.children.length, 1);
});

test('native-owner-disables-only-the-automatic-js-resize-writer', () => {
    const r = rig();
    r.context.nativeResizeOwnsRestore = true;
    r.install();
    r.committedResize(286, 710, 5971.1875); r.emit('resize');
    assert.equal(r.state.scrollWrites.length, 0, 'Only native may perform this resize restore');
    assert.equal(typeof r.context.marginedReadingResize.stop, 'function');
    assert.equal(r.run({operation:'restore',position:{x:0,y:100,top:0,candidates:[]}}), true);
    assert.equal(r.state.scrollWrites.length, 1, 'Explicit app restoration keeps its existing behavior');
});
test('native-owner-keeps-explicit-navigation-and-lease-retirement', () => {
    const r = rig();
    r.context.nativeResizeOwnsRestore = true;
    r.install();
    assert.equal(r.run({operation:'navigate',kind:'element',id:r.nodes[36].id,focus:true}), true);
    assert.equal(r.state.navigationScrolls.length, 1);
    r.context.marginedReadingResize.stop();
    r.committedResize(286, 710, 5971.1875);
    assert.equal(r.state.scrollWrites.length, 0);
    assert.ok(r.state.observers.every(observer=>!observer.active));
});

let failures = 0, count = 0;
for (const {name, run} of tests) {
    if (process.argv[3] && !name.includes(process.argv[3])) continue;
    count++;
    try { run(); console.log(`PASS ${name}`); }
    catch (error) { failures++; console.log(`FAIL ${name}: ${error.message}`); }
}
if (!count) throw new Error('No matching tests');
console.log(`${path.basename(sourcePath)}: ${count - failures}/${count} passed`);
process.exitCode = failures ? 1 : 0;
