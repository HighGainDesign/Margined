'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const file=process.argv[2];if(!file) throw Error('Provide the exact lock resource');
const script=new vm.Script('(function(){'+fs.readFileSync(file,'utf8')+'})()');
function fixture() {
 const values=new Map(),priorities=new Map();
 const root={style:{getPropertyValue:k=>values.get(k)||'',getPropertyPriority:k=>priorities.get(k)||'',
  setProperty(k,v,p=''){values.set(k,v);priorities.set(k,p)},removeProperty(k){values.delete(k);priorities.delete(k)}},
  token:'A',getAttribute(){return this.token}};
 const c=vm.createContext({document:{documentElement:root},window:{}});
 return {root,c,run(args={}){Object.assign(c,{lockOperation:'acquire',resizeSession:'one',resizeOrder:1,shouldLock:true,disableAnchor:false,documentToken:'A'},args);return script.runInContext(c)}};
}
let failed=0,total=0;function test(name,f){total++;try{f();console.log('PASS '+name)}catch(e){failed++;console.log('FAIL '+name+': '+e.message.slice(0,180))}}
test('in-place token replacement releases the old lease',()=>{let f=fixture();assert.equal(f.run(),true);f.root.token='B';assert.equal(f.run({lockOperation:'release'}),true);assert.equal(f.root.style.getPropertyValue('overflow-y'),'')});
test('wrong document cannot acquire and retired work cannot reacquire',()=>{let f=fixture();assert.equal(f.run({documentToken:'B'}),false);f.run({lockOperation:'release'});assert.equal(f.run(),false);assert.equal(f.root.style.getPropertyValue('overflow-y'),'')});
test('older cleanup cannot release a newer lease',()=>{let f=fixture();f.run();f.run({resizeSession:'two',resizeOrder:2});f.run({lockOperation:'release',resizeOrder:1});assert.equal(f.root.style.getPropertyValue('overflow-y'),'hidden');f.run({lockOperation:'release',resizeOrder:2});assert.equal(f.root.style.getPropertyValue('overflow-y'),'')});
test('independent external axis survives while owned axis restores',()=>{let f=fixture();f.run();f.root.style.setProperty('overflow-x','auto','important');f.run({lockOperation:'release'});assert.equal(f.root.style.getPropertyValue('overflow-x'),'auto');assert.equal(f.root.style.getPropertyPriority('overflow-x'),'important');assert.equal(f.root.style.getPropertyValue('overflow-y'),'')});
test('adoption refreshes only externally changed axis baseline',()=>{let f=fixture();f.root.style.setProperty('overflow-y','scroll');f.run();f.root.style.setProperty('overflow-x','auto','important');f.run({resizeSession:'two',resizeOrder:2});f.run({lockOperation:'release',resizeOrder:2});assert.equal(f.root.style.getPropertyValue('overflow-x'),'auto');assert.equal(f.root.style.getPropertyPriority('overflow-x'),'important');assert.equal(f.root.style.getPropertyValue('overflow-y'),'scroll')});
test('a replacement root gets its own baseline',()=>{let f=fixture(),g=fixture();f.run();g.root.style.setProperty('overflow-y','auto');f.c.document.documentElement=g.root;f.run({resizeSession:'two',resizeOrder:2});f.run({lockOperation:'release',resizeOrder:2});assert.equal(g.root.style.getPropertyValue('overflow-y'),'auto')});
test('unit scale does not acquire a lock',()=>{let f=fixture();assert.equal(f.run({shouldLock:false}),true);assert.equal(f.root.style.getPropertyValue('overflow-y'),'')});
test('anchor-only lease restores browser anchoring at unit scale',()=>{let f=fixture();f.run({shouldLock:false,disableAnchor:true});assert.equal(f.root.style.getPropertyValue('overflow-anchor'),'none');assert.equal(f.root.style.getPropertyValue('overflow-y'),'');f.root.token='B';f.run({lockOperation:'release'});assert.equal(f.root.style.getPropertyValue('overflow-anchor'),'')});
test('anchor baseline priority and external changes survive cleanup',()=>{let f=fixture();f.root.style.setProperty('overflow-anchor','auto','important');f.run({disableAnchor:true});f.run({lockOperation:'release'});assert.equal(f.root.style.getPropertyValue('overflow-anchor'),'auto');assert.equal(f.root.style.getPropertyPriority('overflow-anchor'),'important')});
test('retirement bookkeeping remains constant size',()=>{let f=fixture();for(let i=1;i<1000;i++){f.run({resizeOrder:i});f.run({lockOperation:'release',resizeOrder:i})}assert.equal(f.c.window.__marginedNativeResizeRetiredOrder,999);assert.equal(f.c.window.__marginedNativeResizeScrollLock,undefined);assert.ok(Object.keys(f.c.window).length<=2)});
console.log(`${total-failed}/${total} passed`);process.exitCode=failed?1:0;
