'use strict';
// Protocol/ownership tests for a temporary experiment, not native-layout proof.
// The shared rig executes the complete reader source supplied on the command line.
const assert = require('node:assert/strict');
const {rig} = require('./test_reader_resize.cjs');
const tests = [];
const test = (name, run) => tests.push({name, run});
function setup() {
    const requests = [], cancellations = [], restorations = [];
    const geometryGate = {postMessage(body) {
        if (body.kind === 'restored') { restorations.push(body); return Promise.resolve({ready:false}); }
        if (body.kind === 'cancel') { cancellations.push(body); return Promise.resolve({ready:false}); }
        return new Promise((resolve, reject) => requests.push({body, resolve, reject}));
    }};
    return {r:rig({geometryGate}), requests, cancellations, restorations};
}
const settle = async () => { await Promise.resolve(); await Promise.resolve(); };

test('restore waits for native geometry without requiring the target origin', async () => {
    const {r, requests} = setup();
    r.committedResize(286, 446, 5971.1875);
    assert.equal(r.state.scrollWrites.length, 0);
    assert.equal(requests.length, 1);
    assert.deepEqual(Object.keys(requests[0].body).sort(),
        ['contentHeight','contentWidth','height','kind','lease','revision','token','width']);
    requests[0].resolve({ready:true}); await settle();
    assert.equal(r.state.scrollWrites.length, 1); r.assertAnchor();
});
test('stale scroll feedback while waiting cannot replace the anchor', async () => {
    const {r, requests} = setup();
    r.committedResize(286, 446, 5971.1875);
    r.state.y = 3498; r.emit('scroll'); r.frame();
    requests[0].resolve({ready:true}); await settle();
    r.assertAnchor();
});
test('superseded geometry cannot restore an older viewport', async () => {
    const {r, requests} = setup();
    r.committedResize(286, 446, 5971.1875);
    r.committedResize(890, 446, 2639.375);
    assert.equal(requests.length, 2);
    requests[0].resolve({ready:true}); await settle();
    assert.equal(r.state.scrollWrites.length, 0);
    requests[1].resolve({ready:true}); await settle();
    assert.equal(r.state.scrollWrites.length, 1); r.assertAnchor();
});
test('returning to old dimensions still retires the intervening request', async () => {
    const {r, requests} = setup();
    r.committedResize(286, 446, 5971.1875);
    r.committedResize(550, 446, 3541.1875, {deliver:false});
    r.state.y = 3498; r.emit('scroll'); r.frame();
    r.deliverResizeObserver();
    assert.equal(requests.length, 2);
    requests[0].resolve({ready:true}); await settle();
    assert.equal(r.state.scrollWrites.length, 0);
    requests[1].resolve({ready:true}); await settle(); r.assertAnchor();
});
test('same pending dimensions coalesce repeated notifications', async () => {
    const {r, requests} = setup();
    r.committedResize(286, 446, 5971.1875); r.emit('resize'); r.deliverResizeObserver();
    assert.equal(requests.length, 1);
    requests[0].resolve({ready:true}); await settle(); r.assertAnchor();
});
test('return to old dimensions before the old verdict keeps ownership without an RO', async () => {
    const {r, requests} = setup();
    r.committedResize(286, 446, 5971.1875);
    r.committedResize(550, 446, 3541.1875, {deliver:false});
    r.state.y = 3498; r.emit('scroll'); r.frame();
    requests[0].resolve({ready:true}); await settle();
    assert.equal(r.state.scrollWrites.length, 0);
    assert.equal(requests.length, 2, 'The verdict must reconcile A without inventing an RO delivery');
    requests[1].resolve({ready:true}); await settle(); r.assertAnchor();
    r.deliverResizeObserver(); assert.equal(requests.length, 2);
});
test('stop retires pending work before a late success', async () => {
    const {r, requests, cancellations} = setup();
    r.committedResize(286, 446, 5971.1875); r.context.marginedReadingResize.stop();
    assert.equal(cancellations.length, 1);
    assert.ok(cancellations[0].revision > requests[0].body.revision);
    requests[0].resolve({ready:true}); await settle();
    assert.equal(r.state.scrollWrites.length, 0);
});
test('document replacement refuses a late success', async () => {
    const {r, requests} = setup();
    r.committedResize(286, 446, 5971.1875);
    r.state.attributes.set('data-margined-mobile-token','replacement');
    requests[0].resolve({ready:true}); await settle();
    assert.equal(r.state.scrollWrites.length, 0);
});
test('changed content dimensions refuse a stale native verdict', async () => {
    const {r, requests} = setup();
    r.committedResize(286, 446, 5971.1875); r.state.contentHeight += 100;
    requests[0].resolve({ready:true}); await settle();
    assert.equal(r.state.scrollWrites.length, 0);
    assert.equal(requests.length, 2, 'The verdict must reconcile changed content without an RO');
    requests[1].resolve({ready:true}); await settle(); r.assertAnchor();
});
test('content changes during the native wait reconcile after a failed old verdict', async () => {
    const {r, requests} = setup();
    r.committedResize(286, 446, 5971.1875); r.state.contentHeight += 100;
    requests[0].resolve({ready:false,reason:'diagnostic-budget-expired'}); await settle();
    assert.equal(r.state.scrollWrites.length, 0); assert.equal(requests.length, 2);
    requests[1].resolve({ready:true}); await settle(); r.assertAnchor();
});
test('deadline or mismatch never grants readiness', async () => {
    const {r, requests} = setup();
    r.committedResize(286, 446, 5971.1875);
    requests[0].resolve({ready:false,reason:'diagnostic-budget-expired'}); await settle();
    assert.equal(r.state.scrollWrites.length, 0);
    r.committedResize(890, 446, 2639.375);
    requests[1].resolve({ready:true}); await settle(); r.assertAnchor();
});
test('hidden geometry cancels and cannot consume the retained anchor', async () => {
    const {r, requests, cancellations} = setup();
    r.committedResize(286, 446, 5971.1875);
    r.committedResize(0, 0, 0);
    assert.equal(cancellations.length, 1);
    requests[0].resolve({ready:true}); await settle();
    assert.equal(r.state.scrollWrites.length, 0);
    r.committedResize(890, 446, 2639.375);
    requests[1].resolve({ready:true}); await settle(); r.assertAnchor();
});

(async () => {
    let failures = 0;
    for (const {name, run} of tests) {
        try { await run(); console.log(`PASS ${name}`); }
        catch (error) { failures++; console.log(`FAIL ${name}: ${error.message}`); }
    }
    console.log(`${tests.length-failures}/${tests.length} geometry experiment cases passed`);
    process.exitCode = failures ? 1 : 0;
})().catch(error => { console.error(error); process.exitCode=1; });
