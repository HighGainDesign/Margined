'use strict';

// Geometry model, not a CSS engine or native-commit proof. Keep the
// native origin independent from the DOM origin in the existing reader rig.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const candidatePath = process.argv[2];
if (!candidatePath) throw new Error('Provide the complete candidate JavaScript path');
const candidate = new vm.Script(`(function(){\n${fs.readFileSync(candidatePath, 'utf8')}\n})()`);
const adapterPath = path.resolve('script/tests/test_reader_resize.cjs');
const prefix = fs.readFileSync(adapterPath, 'utf8').split("test('stale-inner-size-at-resize-event'")[0];
const rig = new Function('require', 'process', prefix + '\nreturn rig;')(require,
    {argv: [process.argv[0], adapterPath, path.resolve('App/Resources/reader-document.js')]});

function fixture(nativeY = 5968) {
    const r = rig();
    r.committedResize(286, 710, 5971.1875, {deliver: false});
    r.state.y = 3498;
    r.state.x = 3;
    // inner* remain old; actual committed root dimensions are independent.
    Object.defineProperties(r.root, {
        scrollWidth: {get: () => r.state.rootWidth},
        scrollHeight: {get: () => 10000}
    });
    r.context.visualViewport = {width: 160.4373231303335, height: 398.27419250492495, scale: 1.782689443334461};
    const nativeViewport = {x: 17, y: nativeY, width: 286, height: 710};
    return {r, nativeViewport, run(args = {}) {
        Object.assign(r.context, {operation: 'capture', documentToken: 'lease-A', nativeViewport}, args);
        return candidate.runInContext(r.context);
    }};
}
const tests = [];
function test(name, run) { tests.push({name, run}); }
function position(value) { return value?.position ?? value; }

test('stale DOM feedback captures the native-visible passage', () => {
    const f = fixture(), p = position(f.run());
    assert.equal(p.candidates[0].id, 'resize-reading-passage');
    assert.equal(p.top, 3.1875);
    assert.equal(p.y, 5968);
    assert.equal(p.x, 17);
});
test('genuine new native scroll keeps its different passage', () => {
    const f = fixture(3498), p = position(f.run());
    assert.equal(p.candidates[0].id, 'paragraph-10');
    assert.equal(p.top, -26.8125);
    assert.equal(p.y, 3498);
});
test('virtual top and bottom filter out the stale DOM viewport', () => {
    const f = fixture(5991.1875), p = position(f.run());
    assert.equal(p.candidates[0].id, 'resize-reading-passage');
    assert.equal(p.top, -20);
});
test('blocks entirely above the native viewport cannot become its anchor', () => {
    const f = fixture(9500);
    f.nativeViewport.height = 100;
    f.r.state.rootHeight = 100;
    const p = position(f.run());
    assert.equal(p.candidates.length, 0);
    assert.equal(p.y, 9500);
});
test('metrics describe committed root dimensions with independent origins', () => {
    const f = fixture(), value = f.run();
    assert.equal(value.metrics.width, 286);
    assert.equal(value.metrics.height, 710);
    assert.equal(value.metrics.contentWidth, 286);
    assert.equal(value.metrics.contentHeight, 10000);
    assert.equal(value.metrics.domY, 3498);
    assert.equal(value.metrics.visual.scale, 1.782689443334461);
    assert.equal(value.metrics.visual.width, 160.4373231303335);
    assert.equal(value.position.y, 5968);
});
test('destination computation never scrolls or focuses', () => {
    const f = fixture(), p = position(f.run());
    f.r.committedResize(626, 230, 2639.375, {deliver: false});
    f.r.state.y = 100;
    const value = f.run({operation: 'destination', position: p});
    assert.equal(value.x, 17);
    assert.equal(value.y, 2636.1875);
    assert.equal(value.metrics.width, 626);
    assert.equal(f.r.state.scrollWrites.length, 0);
    assert.equal(f.r.state.focusWrites, 0);
    assert.equal(f.r.state.y, 100);
});
test('capture never scrolls or focuses', () => {
    const f = fixture(); f.run();
    assert.equal(f.r.state.scrollWrites.length, 0);
    assert.equal(f.r.state.focusWrites, 0);
    assert.equal(f.r.state.y, 3498);
});
test('retained descriptors stay bounded and skip a changed passage', () => {
    const f = fixture();
    for (let index = 70; index < 200; index++) {
        f.r.nodes.push({...f.r.nodes[69], id: 'extra-' + index, textContent: 'Extra paragraph ' + index,
            getBoundingClientRect() {
                const top = f.r.state.targetTop + (index - 35) * 100 - f.r.state.y;
                return {top, bottom: top + 90, height: 90};
            }});
    }
    const p = position(f.run());
    assert.equal(p.candidates.length, 128);
    f.r.nodes[35].textContent = 'Changed after capture';
    f.r.committedResize(626, 230, 2639.375, {deliver: false});
    const value = f.run({operation: 'destination', position: p});
    assert.equal(value.y, 2736.1875);
    assert.equal(f.r.state.scrollWrites.length, 0);
});
test('invalid native viewport cannot create a position', () => {
    for (const patch of [{y: NaN}, {width: 0}, {height: -1}, {x: Infinity}]) {
        const f = fixture();
        assert.equal(f.run({nativeViewport: {...f.nativeViewport, ...patch}}), null);
    }
});
test('superseded document cannot capture or compute a destination', () => {
    const f = fixture();
    f.r.state.attributes.set('data-margined-mobile-token', 'replacement');
    assert.equal(f.run(), null);
    assert.equal(f.run({operation: 'destination', position: {x: 0, y: 0, top: 0, candidates: []}}), null);
});

let failures = 0;
for (const {name, run} of tests) {
    try { run(); console.log('PASS ' + name); }
    catch (error) { failures++; console.log('FAIL ' + name + ': ' + error.message.slice(0, 240)); }
}
console.log(`${tests.length - failures}/${tests.length} passed`);
process.exitCode = failures ? 1 : 0;
