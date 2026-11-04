'use strict';

// No packages or browser automation. Execute the complete, unmodified input
// reader-document.js in a vm, with independently controlled viewport signals.
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
        x: 0, y: 3538, targetTop: 3541.1875, frames: new Map(), nextFrame: 1,
        scrollWrites: [], observers: [], listeners: new Map(), focusWrites: 0,
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
        focus() { state.focusWrites++; document.activeElement = this; }
    }));
    const main = {
        id: 'document', querySelectorAll() { return nodes; },
        contains(node) { return nodes.includes(node); },
        getBoundingClientRect() { return {left: 0, width: state.rootWidth}; }
    };
    const root = {
        style: {scrollBehavior: 'smooth'},
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
        elementFromPoint(x, y) {
            if (x < 0 || x >= state.rootWidth || y < 0 || y >= state.rootHeight) return null;
            return nodes.find(node => {
                const rect = node.getBoundingClientRect();
                return rect.top <= y && rect.bottom > y;
            }) ?? null;
        }
    };
    document.activeElement = document.body;
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
            observe(target) { assert.equal(target, root); this.active = true; }
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
        state, context, target, nodes,
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
            if (deliver) api.deliverResizeObserver();
        },
        deliverResizeObserver() {
            for (const observer of state.observers) if (observer.active) observer.callback([{target: root}]);
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
