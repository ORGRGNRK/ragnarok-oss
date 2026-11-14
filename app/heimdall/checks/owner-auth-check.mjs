import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const source=await readFile(new URL('../demos/work-atlas/owner-auth.js',import.meta.url),'utf8');
const encode=x=>Buffer.from(JSON.stringify(x)).toString('base64url');
const fixture={v:1,state:'fixture-state-'.repeat(4),operation:'get',challenge:Buffer.alloc(32,1).toString('base64'),credential_id:Buffer.alloc(16,2).toString('base64')};
let checks=0;
async function test(request,{host='work.example.com',attachment='cross-platform'}={}){
 const nodes=new Map(['purpose','status','authorize','cancel'].map(n=>[n,{disabled:true,textContent:'',onclick:null}]));
 let options,callback;
 const credential={authenticatorAttachment:attachment,rawId:new Uint8Array([1,2]).buffer,response:{clientDataJSON:new TextEncoder().encode('fixture').buffer,authenticatorData:new Uint8Array(37).buffer,signature:new Uint8Array([3]).buffer,attestationObject:new Uint8Array([4]).buffer}};
 const context=vm.createContext({document:{getElementById:n=>nodes.get(n)},location:{hostname:host,hash:'#'+encode(request),replace:v=>{callback=v}},navigator:{credentials:{get:async o=>{options=o;return credential},create:async o=>{options=o;return credential}}},window:{PublicKeyCredential:class{}},TextEncoder,TextDecoder,Uint8Array,atob:s=>Buffer.from(s,'base64').toString('binary'),btoa:s=>Buffer.from(s,'binary').toString('base64')});
 vm.runInContext(source,context);
 if(!nodes.get('authorize').disabled)await nodes.get('authorize').onclick();
 return {nodes,options,callback};
}
let r=await test(fixture);assert(r.callback.startsWith('alexus-owner://auth#'));checks++;
let proof=JSON.parse(Buffer.from(r.callback.split('#')[1],'base64url'));assert.equal(proof.state,fixture.state);assert.equal(proof.ok,true);checks++;
assert.deepEqual(Array.from(r.options.publicKey.allowCredentials[0].transports),['usb','nfc']);checks++;
assert.equal(r.options.publicKey.rpId,'work.example.com');checks++;
r=await test({...fixture,operation:'create',user_id:Buffer.alloc(32).toString('base64')});assert.equal(r.options.publicKey.authenticatorSelection.authenticatorAttachment,'cross-platform');checks++;
r=await test(fixture,{host:'wrong.invalid'});assert(r.nodes.get('authorize').disabled);assert(!r.callback);checks++;
r=await test({...fixture,challenge:'invalid'});assert(r.nodes.get('authorize').disabled);checks++;
r=await test(fixture,{attachment:'platform'});assert(!r.callback);checks++;
console.log(checks+' browser-key fixture checks passed; no physical hardware or live WebAuthn operation tested.');
