import {verify,CONTRACT,checks} from './verify.js';
const $=id=>document.getElementById(id);
let bundle=null,token=null,local=false,live=null,renderID=0;
const msg=t=>{$('notice').textContent=t;$('notice').hidden=false;setTimeout(()=>$('notice').hidden=true,6500);};
const human=s=>s.replaceAll('_',' ').replaceAll('.',' / ');
const save=(obj,name)=>{const url=URL.createObjectURL(new Blob([JSON.stringify(obj,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
async function render(b,status) {
  const id=++renderID;bundle=b;$('export').disabled=!b;if(!b)return;
  const v=await verify(b);if(id!==renderID)return;
  $('mode').textContent=b.mode==='fixture'?'LABELED OFFLINE FIXTURE':'LIVE OPENAI EVIDENCE · ORIGIN UNATTESTED';
  $('state').textContent=human(status||(v.release_verified?'released':v.false_claims?'blocked':'review evidence')).toUpperCase();
  const intact=v.integrity;
  $('headline').textContent=!intact?'Evidence failed verification.':v.false_claims?'The AI claimed success. The checks said no.':v.release_verified?'Checks passed. Hardware signed.':v.checks_total?'The checks are in. Approval is separate.':'Authority starts with a physical action.';
  $('description').textContent=!intact?(v.errors||[]).join(', '):v.false_claims?'The injected proposal uses > instead of ≥ at the discount boundary. The host recomputes the result and blocks release.':v.release_verified?'This bundle contains a passing artifact and valid signatures under the included public keys. Confirm those fingerprints with the owner.':'The run stays gated until the required checks and hardware approvals are present.';
  $('metric-checks').textContent=intact?`${v.checks_passed} / ${v.checks_total}`:'INVALID';
  $('metric-false').textContent=intact?v.false_claims:'—';$('metric-false').className=v.false_claims?'fail':'';
  $('metric-release').textContent=v.release_verified?'SIGNED':'BLOCKED';$('metric-release').className=v.release_verified?'pass':'fail';
  $('checks').replaceChildren();
  let result=[];try{result=b.artifact?checks(b.artifact):[];}catch{}
  for(const c of result){const tr=document.createElement('tr');tr.className=c.passed?'':'failed';for(const [i,t]of[c.input,c.expected,c.actual,c.claimed?'PASS':'Unverified',c.passed?'PASS':'FAIL'].entries()){const td=document.createElement('td');td.textContent=t;if(i===4)td.className=c.passed?'pass':'fail';tr.append(td);}$('checks').append(tr);}
  if(!result.length){const tr=document.createElement('tr'),td=document.createElement('td');td.colSpan=5;td.textContent='No artifact to test yet.';tr.append(td);$('checks').append(tr);}
  $('verification').textContent=intact?`RECOMPUTED IN THIS BROWSER · Receipt chain valid · Run signature ${v.run_signature?'valid':'absent / invalid'} · Release signature ${v.release_signature?'valid':'absent / invalid'} · Key origin Unverified`:'INVALID BUNDLE · Do not rely on its claims.';
  for(const [name,done]of[['run',v.run_signature],['ai',b.events.some(e=>e.kind==='openai.response')],['check',v.checks_total>0&&v.checks_passed===v.checks_total],['seal',v.release_signature]])$('step-'+name).classList.toggle('done',!!done);
  $('timeline').replaceChildren();
  for(const e of b.events){const details=document.createElement('details');details.className='receipt';const summary=document.createElement('summary');for(const text of[String(e.seq+1).padStart(2,'0'),human(e.kind),e.at]){const s=document.createElement('span');s.textContent=text;summary.append(s);}const pre=document.createElement('pre');pre.textContent=JSON.stringify(e,null,2);details.append(summary,pre);$('timeline').append(details);}
  const proofs=b.events.filter(e=>e.kind.startsWith('hardware.')&&e.data.key_id);$('keys').hidden=!proofs.length;$('fingerprints').replaceChildren();
  for(const e of proofs){const p=document.createElement('p');p.textContent=e.data.method;const c=document.createElement('code');c.textContent=e.data.key_id;p.append(c);$('fingerprints').append(p);}
  if(local){$('authorize').disabled=status!=='awaiting_approval';$('seal').disabled=status!=='awaiting_seal';$('operator-status').textContent=human(status||'idle')+' · '+live?.model;}
}
async function post(path,body={}) {
  try{const r=await fetch('/api/'+path,{method:'POST',headers:{'Content-Type':'application/json','X-Lab-Token':token},body:JSON.stringify(body)});const d=await r.json();if(!r.ok)throw Error(d.error);live=d;await render(d.bundle,d.status);}catch(e){msg(e.message);}
}
$('fixture').onclick=async()=>{try{const r=await fetch('evidence.json',{cache:'no-store'});if(!r.ok)throw Error('Offline control unavailable. Generate it with proof.py fixture.');const b=await r.json();if(b.mode!=='fixture')throw Error('Expected a labeled fixture.');await render(b,'fixture blocked');}catch(e){msg(e.message);}};
$('import').onchange=async e=>{try{const f=e.target.files[0];if(!f)return;if(f.size>2000000)throw Error('Evidence exceeds 2 MB.');const b=JSON.parse(await f.text());await render(b,'imported evidence');}catch(e){msg('Import failed: '+e.message);}e.target.value='';};
$('export').onclick=()=>bundle&&save(bundle,'ragnarok-evidence-'+bundle.run_id+'.json');
$('create').onclick=()=>post('create',{scenario:$('scenario').value,model:$('model').value.trim()});$('authorize').onclick=()=>{msg('Touch the connected YubiKey when it flashes.');post('authorize');};$('seal').onclick=()=>{msg('Approve the native Touch ID prompt to sign this release.');post('seal');};$('stop').onclick=()=>post('stop');
async function poll(){try{const r=await fetch('/api/state',{cache:'no-store'});if(!r.ok)return;const d=await r.json();const old=live;live=d;if(d.bundle&&(d.bundle.head!==old?.bundle?.head||d.status!==old?.status))await render(d.bundle,d.status);}catch{}}
// A hosted reviewer never contacts localhost or asks for credentials.
if(location.hostname==='127.0.0.1'){
  try{const r=await fetch('/api/session');if(r.ok){token=(await r.json()).token;local=true;$('operator').hidden=false;$('connection').textContent='LOCAL OPERATOR';await poll();$('model').value=live?.model||'';setInterval(poll,1000);}}catch{}
}
