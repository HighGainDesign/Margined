"use strict";
// Dependency-free adapter: run the actual layout source with controlled DOM
// geometry and animation-frame delivery. This does not simulate WebKit layout,
// painting, native scrolling, or the reading-position observer.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");
const sourcePath = process.env.MARGINED_LAYOUT_SOURCE ||
    path.resolve(process.cwd(), "Shared/Resources/reader-discussion-layout.js");
const source = fs.readFileSync(sourcePath, "utf8");

class EventTargetAdapter {
    constructor() { this.listeners = new Map(); }
    addEventListener(type, callback, options = {}) {
        const entries = this.listeners.get(type) || [];
        const entry = { callback, signal: options.signal };
        entries.push(entry); this.listeners.set(type, entries);
        options.signal?.addEventListener("abort", () => {
            this.listeners.set(type, (this.listeners.get(type) || []).filter(x => x !== entry));
        }, { once: true });
    }
    dispatch(type) {
        for (const entry of [...(this.listeners.get(type) || [])]) {
            if (!entry.signal?.aborted) entry.callback({ type });
        }
    }
}
class ElementAdapter extends EventTargetAdapter {
    constructor(localName) {
        super(); this.localName = localName; this.style = {}; this.dataset = {};
        this.children = []; this.attributes = new Map(); this.isConnected = true;
    }
    appendChild(child) { child.parentElement = this; this.children.push(child); return child; }
    remove() {
        if (this.parentElement) {
            this.parentElement.children = this.parentElement.children.filter(child => child !== this);
            this.parentElement = null;
        }
        this.isConnected = false;
    }
    setAttribute(name, value) { this.attributes.set(name, value); }
    getAttribute(name) { return this.attributes.get(name) ?? null; }
}
function fixture() {
    const geometry = { width: 808, documentTop: 120, scrollY: 0 };
    const frames = new Map(), messages = [];
    let nextFrame = 1, rangeReads = 0;
    const body = new ElementAdapter("body"), main = new ElementAdapter("main");
    main.getBoundingClientRect = () => ({ left: 0, right: geometry.width, top: 0, width: geometry.width, height: 5000 });
    const textNode = { nodeType: 3, isConnected: true, textContent: "Passage" };
    const projection = { text: "Passage", units: [{ raw: "Passage", location: 0,
        parts: [{ kind: "text", node: textNode, location: 0, length: 7 }] }] };
    const state = { token: "current", sourceID: "fixture", allowed: new Set(["thread"]),
        projection, abort: new AbortController() };
    const window = new EventTargetAdapter();
    window.__marginedDiscussions = state;
    window.webkit = { messageHandlers: { discussion: { postMessage(value) {
        messages.push(JSON.parse(JSON.stringify(value)));
    } } } };
    const document = {
        body, documentElement: { get clientWidth() { return geometry.width; }, scrollHeight: 5000 },
        createElement: tag => new ElementAdapter(tag),
        createRange() {
            return {
                collapsed: false,
                setStart(node, offset) { this.startContainer = node; this.startOffset = offset; },
                setEnd(node, offset) { this.endContainer = node; this.endOffset = offset; },
                getClientRects() {
                    rangeReads++;
                    const top = geometry.documentTop - geometry.scrollY;
                    return [{ left: 24, right: 324, top, bottom: top + 20, width: 300, height: 20 }];
                }
            };
        }
    };
    const sandbox = {
        window, document, main, token: "current", sourceID: "fixture", expectedText: "Passage",
        operation: "decorate", visible: true, selectedID: "thread", markerLabel: "Open discussion",
        anchors: [{ id: "thread", location: 0, length: 7, startUnit: 0, startOffset: 0, endUnit: 0, endOffset: 7 }],
        canonicalOffset: (unit, offset) => offset, AbortController,
        getComputedStyle: node => node === body ? { fontSize: "16px" } : { paddingLeft: "24px", paddingRight: "24px" },
        requestAnimationFrame(callback) { const id = nextFrame++; frames.set(id, callback); return id; },
        cancelAnimationFrame(id) { frames.delete(id); },
        ResizeObserver: class {
            constructor(callback) { this.callback = callback; }
            observe() {}
            disconnect() { this.disconnected = true; }
            trigger() { assert.ok(!this.disconnected); this.callback([]); }
        }
    };
    Object.defineProperties(sandbox, {
        scrollX: { get: () => 0 }, scrollY: { get: () => geometry.scrollY },
        innerWidth: { get: () => geometry.width }, innerHeight: { get: () => 600 }
    });
    const context = vm.createContext(sandbox);
    vm.runInContext(source, context, { filename: sourcePath });
    const mount = () => vm.runInContext("marginedDiscussionLayout()", context);
    mount();
    function markerLeft() {
        const button = state.layout.overlay.children.find(node => node.className.includes("margined-note-button"));
        assert.ok(button); return Number.parseFloat(button.style.left);
    }
    return { geometry, frames, messages, window, main, state, body, mount, markerLeft,
        get rangeReads() { return rangeReads; },
        triggerFull(kind) {
            if (kind === "resize") window.dispatch("resize");
            else if (kind === "load") main.dispatch("load");
            else if (kind === "ResizeObserver") state.layout.observer.trigger();
            else throw new Error("Unknown full-refresh event");
        },
        flushFrame() {
            const callbacks = [...frames.values()]; frames.clear();
            for (const callback of callbacks) callback(16);
        }
    };
}
function shrinkAndScroll(f, trigger) {
    f.geometry.width = 550; f.geometry.documentTop = 220;
    f.triggerFull(trigger);
    f.geometry.scrollY = 40; f.window.dispatch("scroll");
}
for (const trigger of ["resize", "load", "ResizeObserver"]) {
    test(`${trigger} full refresh survives a later scroll before the animation frame`, () => {
        const f = fixture();
        assert.equal(f.markerLeft(), 780);
        assert.equal(f.messages.at(-1).anchors[0].top, 120);
        const oldOverlay = f.state.layout.overlay;
        shrinkAndScroll(f, trigger);
        assert.equal(f.frames.size, 1, "Coalesce into one pending frame");
        f.flushFrame();
        assert.deepEqual({ markerLeft: f.markerLeft(), publishedAnchorTop: f.messages.at(-1).anchors[0].top,
            rangeReads: f.rangeReads, rebuiltOverlay: f.state.layout.overlay !== oldOverlay },
            { markerLeft: 522, publishedAnchorTop: 180, rangeReads: 2, rebuiltOverlay: true });
        assert.equal(f.messages.length, 2, "Only initial and coalesced publications");
    });
}
test(`scroll-only delivery publishes without rebuilding the overlay`, () => {
    const f = fixture(), overlay = f.state.layout.overlay;
    f.geometry.scrollY = 50; f.window.dispatch("scroll"); f.flushFrame();
    assert.equal(f.state.layout.overlay, overlay);
    assert.equal(f.rangeReads, 1); assert.equal(f.messages.at(-1).anchors[0].top, 70);
});
test(`scroll followed by full refresh still refreshes once`, () => {
    const f = fixture();
    f.geometry.scrollY = 40; f.window.dispatch("scroll");
    f.geometry.width = 550; f.geometry.documentTop = 220; f.triggerFull("resize"); f.flushFrame();
    assert.equal(f.markerLeft(), 522); assert.equal(f.rangeReads, 2);
    assert.equal(f.messages.length, 2);
});
test(`multiple cheap events cannot downgrade a pending full refresh; the flag resets after delivery`, () => {
    const f = fixture(); shrinkAndScroll(f, "resize");
    f.geometry.scrollY = 50; f.window.dispatch("scroll");
    f.geometry.scrollY = 60; f.window.dispatch("scroll");
    f.flushFrame();
    assert.equal(f.markerLeft(), 522); assert.equal(f.rangeReads, 2);
    const overlay = f.state.layout.overlay;
    f.geometry.scrollY = 80; f.window.dispatch("scroll"); f.flushFrame();
    assert.equal(f.state.layout.overlay, overlay, "A delivered full refresh must not make later scrolls rebuild");
    assert.equal(f.rangeReads, 2); assert.equal(f.messages.at(-1).anchors[0].top, 140);
});
test(`disposal cancels pending work and removes listeners and overlay`, () => {
    const f = fixture(); shrinkAndScroll(f, "resize");
    const overlay = f.state.layout.overlay;
    f.state.layout.dispose();
    assert.equal(f.frames.size, 0); assert.ok(!f.body.children.includes(overlay));
    f.window.dispatch("resize"); f.window.dispatch("scroll"); f.main.dispatch("load");
    f.flushFrame();
    assert.equal(f.frames.size, 0); assert.equal(f.messages.length, 1); assert.equal(f.rangeReads, 1);
});
test(`replacing a layout cancels the old pending callback`, () => {
    const f = fixture(); shrinkAndScroll(f, "resize"); f.mount();
    assert.equal(f.frames.size, 0); f.flushFrame();
    assert.equal(f.markerLeft(), 522); assert.equal(f.rangeReads, 2);
    assert.equal(f.body.children.length, 1); assert.equal(f.messages.length, 2);
});
