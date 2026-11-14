/* Independent browser verification. No server assertions or external libraries. */
export const CONTRACT = {
  id: 'discount-cents-v1',
  task: 'Apply a 10 percent discount to totals of at least 10000 cents; round the discount down to whole cents.',
  cases: [0,1,9999,10000,10001,12345,25000].map((n,i)=>({id:String(i),input:n,expected:n-(n>=10000?Math.floor(n*1000/10000):0)})),
  allowed_artifact: 'Declarative rule only: threshold_cents, rate_bps, comparison. No code or shell tools.',
};
export function canonical(v) {
  const ascii=s=>JSON.stringify(s).replace(/[\u007f-\uffff]/g,c=>'\\u'+c.charCodeAt(0).toString(16).padStart(4,'0'));
  if (v===null || typeof v!=='object') return ascii(v);
  if(Array.isArray(v)) return '['+v.map(canonical).join(',')+']';
  return '{'+Object.keys(v).sort().map(k=>ascii(k)+':'+canonical(v[k])).join(',')+'}';
}
const bytes=s=>new TextEncoder().encode(s);
const hex=b=>Array.from(new Uint8Array(b),x=>x.toString(16).padStart(2,'0')).join('');
const b64=s=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
const fromhex=s=>Uint8Array.from(s.match(/../g)||[],x=>parseInt(x,16));
export const hash=async o=>hex(await crypto.subtle.digest('SHA-256',bytes(canonical(o))));
const concat=(a,b)=>new Uint8Array([...a,...b]);
const eq=(a,b)=>hex(a)===hex(b);
function derRaw(sig) {
  let p=0;
  if(sig[p++]!==48 || sig[p++]!==sig.length-2 || sig[p++]!==2) throw Error('signature_encoding');
  const rn=sig[p++], r=sig.slice(p,p+rn);p+=rn;
  if(sig[p++]!==2) throw Error('signature_encoding');
  const sn=sig[p++], s=sig.slice(p,p+sn);p+=sn;
  if(p!==sig.length || rn>33 || sn>33) throw Error('signature_encoding');
  const trim=a=>a.length===33&&a[0]===0?a.slice(1):a;
  const rr=trim(r),ss=trim(s);if(rr.length>32||ss.length>32)throw Error('signature_encoding');
  const out=new Uint8Array(64);out.set(rr,32-rr.length);out.set(ss,64-ss.length);return out;
}
function authBytes(encoded) {
  const b=b64(encoded);if(b[0]>>5!==2)throw Error('authenticator_encoding');
  const n=b[0]&31;let start=1,size=n;
  if(n>=24){const w=({24:1,25:2,26:4})[n];if(!w)throw Error('authenticator_encoding');start=1+w;size=0;for(let i=1;i<start;i++)size=size*256+b[i];}
  if(start+size!==b.length||size<37)throw Error('authenticator_length');return b.slice(start);
}
async function proofValid(p,m) {
  if(!p)return false;
  try {
    const binding=await hash(m);if(p.manifest_sha256!==binding)return false;
    const der=b64(p.public_key.replace(/-----[^-]+-----|\s/g,''));
    if(hex(await crypto.subtle.digest('SHA-256',der))!==p.key_id)return false;
    const key=await crypto.subtle.importKey('spki',der,{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
    let message,signature;
    if(p.method==='secure-enclave') {
      if(p.challenge!==binding.slice(0,32))return false;
      message=bytes('ragnarok-chain:v1:'+p.challenge);signature=b64(p.signature);
    } else if(p.method==='yubikey') {
      const lines=p.assertion.trim().split('\n');if(lines.length!==4||hex(b64(lines[0]))!==binding||lines[1]!==p.rp_id)return false;
      const raw=authBytes(lines[2]);
      if(!eq(raw.slice(0,32),new Uint8Array(await crypto.subtle.digest('SHA-256',bytes(lines[1]))))||!(raw[32]&1))return false;
      message=concat(raw,fromhex(binding));signature=b64(lines[3]);
    } else return false;
    return await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},key,derRaw(signature),message);
  } catch{return false;}
}
export function checks(rule) {
  const fields=['threshold_cents','rate_bps','comparison','claimed_passes'].sort();
  if(!rule || canonical(Object.keys(rule).sort())!==canonical(fields)
      || !Number.isInteger(rule.threshold_cents)||rule.threshold_cents<0||rule.threshold_cents>100000000
      || !Number.isInteger(rule.rate_bps)||rule.rate_bps<0||rule.rate_bps>10000
      || !['>=','>'].includes(rule.comparison)||!Array.isArray(rule.claimed_passes)
      || rule.claimed_passes.some(v=>!CONTRACT.cases.some(c=>c.id===v))) throw Error('invalid_rule');
  return CONTRACT.cases.map(c=>{
    const active=rule.comparison==='>='?c.input>=rule.threshold_cents:c.input>rule.threshold_cents;
    const actual=c.input-(active?Math.floor(c.input*rule.rate_bps/10000):0);
    return {...c,actual,passed:actual===c.expected,claimed:rule.claimed_passes.includes(c.id)};
  });
}
export async function verify(b) {
  try {
    if(b.schema!=='ragnarok-proof:v1'||canonical(b.contract)!==canonical(CONTRACT))throw Error('contract_mismatch');
    if(!Array.isArray(b.events)||!b.events.length||b.events.length>200)throw Error('invalid_events');
    let head='0'.repeat(64);
    for(let i=0;i<b.events.length;i++){
      const e=b.events[i],core={seq:e.seq,at:e.at,kind:e.kind,data:e.data,prev:e.prev};
      if(e.seq!==i||e.prev!==head||e.hash!==await hash(core))throw Error('receipt_chain_broken');head=e.hash;
    }
    if(head!==b.head)throw Error('head_mismatch');
    const result=b.artifact?checks(b.artifact):[];
    const observed=b.events.filter(e=>e.kind==='host.checks');
    if(b.artifact&&(observed.length!==1||canonical(observed[0].data)!==canonical({artifact_sha256:await hash(b.artifact),results:result})))throw Error('checks_missing_or_forged');
    const run=b.events.filter(e=>e.kind==='hardware.run_approved'),seal=b.events.filter(e=>e.kind==='hardware.release_approved');
    const rm={domain:b.schema,purpose:'authorize-run',run_id:b.run_id,nonce:b.nonce,contract_sha256:await hash(CONTRACT),scenario:b.scenario,model:b.requested_model,mode:b.mode};
    const runValid=run.length===1&&run[0].data.method==='yubikey'&&await proofValid(run[0].data,rm);
    const sm=seal.length===1?{domain:b.schema,purpose:'approve-release',run_id:b.run_id,head:seal[0].prev,artifact_sha256:await hash(b.artifact),contract_sha256:await hash(CONTRACT)}:null;
    const sealValid=!!b.artifact&&seal.length===1&&seal[0].data.method==='secure-enclave'&&await proofValid(seal[0].data,sm);
    const releases=b.events.filter(e=>e.kind==='release.allowed'),api=b.events.filter(e=>e.kind==='openai.response');
    const apiOK=api.length===1&&canonical(api[0].data.rule)===canonical(b.artifact)&&!!api[0].data.response_id;
    const allowed=result.length&&result.every(c=>c.passed)&&runValid&&sealValid&&b.mode==='live-openai'&&apiOK&&!b.events.some(e=>e.kind==='operator.revoked');
    if(releases.length&&(!allowed||releases.length!==1||releases[0]!==b.events.at(-1)||seal[0].seq!==releases[0].seq-1||run[0].seq>=api[0].seq||canonical(releases[0].data)!==canonical({artifact_sha256:await hash(b.artifact),scope:'demo artifact only; no production deployment'})))throw Error('unauthorized_release');
    return {integrity:true,run_signature:runValid,release_signature:sealValid,checks_passed:result.filter(c=>c.passed).length,
      checks_total:result.length,false_claims:result.filter(c=>c.claimed&&!c.passed).length,release_verified:!!(releases.length&&allowed),mode:b.mode,results:result};
  } catch(e){return {integrity:false,release_verified:false,errors:[e.message]};}
}
