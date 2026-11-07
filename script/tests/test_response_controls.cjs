'use strict';
// Exercise the shipped isolated-world controller with a dependency-free DOM
// adapter. Native editor/layout behavior is covered by headless WebKit tests.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Shared/Resources/reader-responses.js', 'utf8');
class Element {
    constructor(tag, document) { this.tag = tag; this.document = document; this.attributes = {}; this.children = []; this.disabled = false; }
    get isConnected() { return this === this.document.body || !!this.parent?.isConnected; }
    get id() { return this.getAttribute('id'); }
    set id(value) { this.setAttribute('id', value); }
    setAttribute(key, value) { this.attributes[key] = String(value); }
    getAttribute(key) { return this.attributes[key] ?? null; }
    removeAttribute(key) { delete this.attributes[key]; }
    appendChild(node) { node.parent = this; this.children.push(node); }
    before(node) { node.parent = this.parent; this.parent.children.splice(this.parent.children.indexOf(this), 0, node); }
    remove() { this.parent.children.splice(this.parent.children.indexOf(this), 1); this.parent = null; }
    matches(selector) {
        const m = selector.match(/^(\w*)\[([^=\]]+)(?:="([^"]*)")?\]$/);
        return m && (!m[1] || m[1] === this.tag) && this.getAttribute(m[2]) !== null && (m[3] === undefined || this.getAttribute(m[2]) === m[3]);
    }
    closest(selector) { return this.matches(selector) ? this : this.parent?.closest(selector); }
    querySelectorAll(selector) { return this.children.flatMap(child => [...(selector.split(',').some(s => child.matches(s)) ? [child] : []), ...child.querySelectorAll(selector)]); }
    querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
    focus() { this.document.activeElement = this; this.document.dispatch('focusin', {target:this}); }
}
function fixture() {
    const listeners = new Map(), messages = [];
    const document = {
        createElement(tag) { return new Element(tag, this); },
        querySelectorAll(selector) { return this.body.querySelectorAll(selector); },
        querySelector(selector) { return this.body.querySelector(selector); },
        getElementById(id) { return this.querySelector(`[id="${id}"]`); },
        addEventListener(type, handler) { const list = listeners.get(type) || []; list.push(handler); listeners.set(type, list); },
        dispatch(type, event) { for (const handler of listeners.get(type) || []) handler(event); }
    };
    document.body = new Element('body', document); document.activeElement = document.body;
    document.documentElement = new Element('html', document);
    const p = document.createElement('p'); p.setAttribute('data-margined-answer', '0'); document.body.appendChild(p);
    const group = document.createElement('ul'); group.setAttribute('data-margined-choice', '0'); document.body.appendChild(group);
    const input = document.createElement('input'); input.setAttribute('data-margined-task', '0'); group.appendChild(input);
    const window = {webkit:{messageHandlers:{taskToggle:{postMessage(value) {messages.push(value);}}}}};
    const context = vm.createContext({document, window, Element});
    const defaults = {tokenAttribute:'', token:'current', documentID:'file-A', enabled:true,
        answerKeys:{0:'20:Notes'}, focusIntent:0, focusReturn:0, editTitle:'Edit answer',
        answerLabels:{0:'Edit answer for Notes'}, conflictText:'Choose one to resolve the conflict.', restoreFocus:true};
    function configure(overrides = {}) {
        const args = {...defaults, ...overrides};
        Object.assign(context, args);
        return vm.runInContext(`(function(){${source}\n})()`, context);
    }
    configure();
    return {document, window, p, group, input, messages, configure, button:()=>p.querySelector('button[data-margined-answer-action]')};
}
test('only trusted enabled connected answer buttons dispatch mapped IDs and disable both controls', () => {
    const f = fixture(), button = f.button();
    assert.equal(button.getAttribute('aria-label'), 'Edit answer for Notes');
    f.document.dispatch('click', {target:button, isTrusted:false}); assert.equal(f.messages.length, 0);
    f.configure({enabled:false}); f.document.dispatch('click', {target:button, isTrusted:true}); assert.equal(f.messages.length, 0);
    f.configure(); f.document.dispatch('click', {target:button, isTrusted:true});
    assert.deepEqual(JSON.parse(JSON.stringify(f.messages)), [{kind:'answer',id:0,token:'current'}]);
    assert.equal(button.disabled, true); assert.equal(f.input.disabled, true);
    f.configure(); button.remove(); f.document.dispatch('click', {target:button, isTrusted:true}); assert.equal(f.messages.length, 1);
});
test('conflicts receive visible described warnings without modifying markers', () => {
    const f = fixture(); f.group.setAttribute('aria-invalid', 'true'); f.configure(); f.configure();
    const warning = f.document.querySelector('[data-margined-response-warning="0"]');
    assert.equal(f.document.querySelectorAll('[data-margined-response-warning]').length, 1);
    assert.equal(warning.getAttribute('role'), 'status'); assert.equal(warning.textContent, 'Choose one to resolve the conflict.');
    assert.equal(f.group.getAttribute('aria-describedby'), warning.id);
    f.group.removeAttribute('aria-invalid'); f.configure();
    assert.equal(f.group.getAttribute('aria-describedby'), null); assert.equal(warning.isConnected, false);
});
test('editor dismissal pulse restores the same answer after reconciliation, not before dismissal', () => {
    const f = fixture(), button = f.button(); button.focus();
    f.document.dispatch('click', {target:button, isTrusted:true}); f.configure({enabled:false});
    f.document.activeElement = f.document.body; button.remove(); f.configure();
    assert.equal(f.document.activeElement, f.document.body);
    f.configure({focusReturn:1}); assert.equal(f.document.activeElement, f.button());
});
test('new focus intent, field identity, document or user movement wins over focus return', () => {
    for (const overrides of [{focusIntent:1}, {answerKeys:{0:'50:Other'}}, {documentID:'file-B'}, {restoreFocus:false}]) {
        const f = fixture(), button = f.button(); button.focus(); f.document.dispatch('click', {target:button, isTrusted:true});
        f.configure({enabled:false}); f.document.activeElement = f.document.body;
        f.configure({...overrides, focusReturn:1}); assert.equal(f.document.activeElement, f.document.body);
    }
    const f = fixture(); f.button().focus(); f.document.dispatch('click', {target:f.button(), isTrusted:true});
    const other = f.document.createElement('button'); f.document.body.appendChild(other); other.focus();
    f.configure({focusReturn:1}); assert.equal(f.document.activeElement, other);
});
test('stale mobile page token prevents configuration', () => {
    const f = fixture(); f.document.documentElement.setAttribute('data-margined-mobile-token', 'new');
    assert.equal(f.configure({tokenAttribute:'data-margined-mobile-token', token:'old', enabled:false}), false);
    assert.equal(f.button().disabled, false);
});
