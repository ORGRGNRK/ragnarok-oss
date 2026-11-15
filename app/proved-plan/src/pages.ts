import { escapeHtml as e } from './http';
import type { Plan } from './plan';

const STYLE = `
:root{color-scheme:light dark;--bg:#f6f5f2;--card:#fff;--ink:#1d1d1f;--mute:#6e6e73;--line:#e3e1dc;--accent:#2d6a4f;--warn:#b42318}
@media (prefers-color-scheme:dark){:root{--bg:#141414;--card:#1e1e1f;--ink:#f2f2f2;--mute:#a1a1a6;--line:#333;--accent:#52b788;--warn:#f97066}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;-webkit-text-size-adjust:100%}
main{max-width:760px;margin:0 auto;padding:16px 14px calc(40px + env(safe-area-inset-bottom))}
h1{font-size:1.45rem;margin:.4em 0 .2em}
h2{font-size:1.05rem;margin:0 0 .6em;display:flex;justify-content:space-between;gap:8px;align-items:baseline}
h2 small{color:var(--mute);font-weight:500;font-size:.85rem}
p.lead{color:var(--mute);margin:.2em 0 1em;font-size:.92rem}
section{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;margin:12px 0}
ul{list-style:none;margin:0;padding:0}
li label{display:flex;gap:12px;align-items:flex-start;padding:10px 4px;border-top:1px solid var(--line);cursor:pointer;min-height:44px}
li:first-child label{border-top:0}
input[type=checkbox]{width:24px;height:24px;flex:0 0 24px;margin:0;accent-color:var(--accent)}
li .id{color:var(--mute);font-variant-numeric:tabular-nums;min-width:2.4em;font-size:.85rem;padding-top:2px}
li input:checked ~ .txt{color:var(--mute);text-decoration:line-through}
.detail{display:block;color:var(--mute);font-size:.85rem}
.nums{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}
@media (max-width:420px){.nums{grid-template-columns:repeat(2,1fr)}}
.nums label{display:flex;flex-direction:column;font-size:.85rem;color:var(--mute);gap:4px;text-transform:capitalize}
.nums input{font:inherit;font-size:1.1rem;padding:10px;border:1px solid var(--line);border-radius:10px;background:var(--bg);color:var(--ink);width:100%}
button{font:inherit;font-weight:600;border:0;border-radius:12px;padding:12px 18px;background:var(--accent);color:#fff;cursor:pointer;min-height:44px}
button.ghost{background:transparent;color:var(--mute);border:1px solid var(--line)}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-top:12px}
.status{color:var(--mute);font-size:.85rem}
.status.err{color:var(--warn)}
.bar{height:6px;background:var(--line);border-radius:3px;overflow:hidden;margin:4px 0 10px}
.bar i{display:block;height:100%;background:var(--accent);width:0}
header{display:flex;justify-content:space-between;align-items:center;gap:10px}
.login{max-width:420px;margin:12vh auto 0;text-align:center}
.login input[type=password]{font:inherit;width:100%;padding:12px;border:1px solid var(--line);border-radius:10px;background:var(--bg);color:var(--ink);margin:8px 0}
`;

const B64_JS = `
const b2u=b=>btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');
const u2b=s=>Uint8Array.from(atob(s.replace(/-/g,'+').replace(/_/g,'/')+'==='.slice((s.length+3)%4)),c=>c.charCodeAt(0));
async function post(path,body){const r=await fetch(path,{method:'POST',headers:{'content-type':'application/json'},credentials:'same-origin',body:JSON.stringify(body||{})});let j={};try{j=await r.json()}catch{}if(!r.ok||j.ok===false)throw new Error(j.error||('HTTP '+r.status));return j}
`;

function shell(title: string, nonce: string, body: string, script: string): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>${e(title)}</title>
<style nonce="${nonce}">${STYLE}</style></head>
<body><main>${body}</main>
<script nonce="${nonce}">${B64_JS}${script}</script>
</body></html>`;
}

/** The only page shown without a session. Contains nothing from the plan. */
export function loginPage(nonce: string, hasCredential: boolean): string {
  const setup = hasCredential
    ? ''
    : `<section id="setup"><h2>First-time setup</h2>
<p class="lead">No passkey is registered yet. Enter the setup token to register this device's passkey (Touch ID / Face ID). This works once.</p>
<input id="token" type="password" autocomplete="off" placeholder="Setup token" aria-label="Setup token">
<button id="register">Register passkey</button></section>`;
  const body = `<div class="login"><h1>Private</h1>
<p class="lead">Sign in with your passkey.</p>
${hasCredential ? '<button id="login">Sign in with passkey</button>' : ''}
${setup}
<p id="status" class="status" role="status"></p></div>`;
  const script = `
const st=document.getElementById('status');
const say=(m,err)=>{st.textContent=m;st.className='status'+(err?' err':'')};
if(!window.PublicKeyCredential)say('This browser does not support passkeys.',true);
const lb=document.getElementById('login');
if(lb)lb.onclick=async()=>{try{say('Waiting for your passkey…');
 const r=await post('/auth/login/options');const o=r.options;
 const pk={...o,challenge:u2b(o.challenge),allowCredentials:(o.allowCredentials||[]).map(c=>({...c,id:u2b(c.id)}))};
 const c=await navigator.credentials.get({publicKey:pk});
 const resp={id:c.id,rawId:b2u(c.rawId),type:c.type,authenticatorAttachment:c.authenticatorAttachment,clientExtensionResults:c.getClientExtensionResults(),
  response:{clientDataJSON:b2u(c.response.clientDataJSON),authenticatorData:b2u(c.response.authenticatorData),signature:b2u(c.response.signature),userHandle:c.response.userHandle?b2u(c.response.userHandle):undefined}};
 await post('/auth/login/verify',{flowId:r.flowId,response:resp});location.replace('/');
}catch(err){say(err.message||String(err),true)}};
const rb=document.getElementById('register');
if(rb)rb.onclick=async()=>{const ti=document.getElementById('token');const token=ti.value.trim();if(!token){say('Enter the setup token.',true);return}
 try{say('Waiting for Touch ID / Face ID…');
 const r=await post('/auth/register/options',{token});const o=r.options;
 const pk={...o,challenge:u2b(o.challenge),user:{...o.user,id:u2b(o.user.id)},excludeCredentials:(o.excludeCredentials||[]).map(c=>({...c,id:u2b(c.id)}))};
 const c=await navigator.credentials.create({publicKey:pk});
 const resp={id:c.id,rawId:b2u(c.rawId),type:c.type,authenticatorAttachment:c.authenticatorAttachment,clientExtensionResults:c.getClientExtensionResults(),
  response:{clientDataJSON:b2u(c.response.clientDataJSON),attestationObject:b2u(c.response.attestationObject),transports:c.response.getTransports?c.response.getTransports():[]}};
 await post('/auth/register/verify',{token,flowId:r.flowId,response:resp});ti.value='';location.replace('/');
}catch(err){say(err.message||String(err),true)}};
`;
  return shell('Sign in', nonce, body, script);
}

/** The checklist, shown only with a valid session. */
export function appPage(nonce: string, plan: Plan, tasks: Record<string, boolean>): string {
  const total = plan.weeks.reduce((n, w) => n + w.tasks.length, 0);
  const done = plan.weeks.reduce((n, w) => n + w.tasks.filter((t) => tasks[t.id]).length, 0);

  const rhythm = plan.rhythm
    .map(
      (r) => `<li><label><input type="checkbox" data-rhythm="${e(r.id)}"><span class="txt"><b>${e(r.label)}</b>` +
        `${r.detail ? `<span class="detail">${e(r.detail)}</span>` : ''}</span></label></li>`,
    )
    .join('');

  const numbers = plan.numbers
    .map((n) => `<label>${e(n)}<input type="number" inputmode="numeric" min="0" step="1" data-num="${e(n)}" placeholder="0"></label>`)
    .join('');

  const weeks = plan.weeks
    .map((w) => {
      const wd = w.tasks.filter((t) => tasks[t.id]).length;
      const items = w.tasks
        .map(
          (t) => `<li><label><input type="checkbox" data-task="${e(t.id)}"${tasks[t.id] ? ' checked' : ''}>` +
            `<span class="id">${e(t.id)}</span><span class="txt">${e(t.text)}</span></label></li>`,
        )
        .join('');
      return `<section class="week"><h2>${e(w.title)} <small data-week-count>${wd}/${w.tasks.length}</small></h2>` +
        `<div class="bar"><i></i></div><ul>${items}</ul></section>`;
    })
    .join('');

  const body = `<header><h1>${e(plan.title || 'Plan')}</h1><button class="ghost" id="logout">Sign out</button></header>
<p class="lead">${e(plan.intro)}</p>
<section id="rhythm"><h2>Daily rhythm <small id="today"></small></h2><ul>${rhythm}</ul></section>
<section id="numbers"><h2>Today's numbers <small id="numstatus" class="status"></small></h2><div class="nums">${numbers}</div>
<div class="row"><button id="savenums">Save numbers</button></div></section>
<section><h2>28 days <small id="overall">${done}/${total} done</small></h2>
<div class="bar"><i id="overallbar"></i></div></section>
${weeks}
<p id="status" class="status" role="status"></p>`;

  const script = `
const st=document.getElementById('status');
const say=(m,err)=>{st.textContent=m;st.className='status'+(err?' err':'')};
const localDay=()=>{const d=new Date();return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0')};
let day=localDay();
const fail=r=>{if(r&&r.message&&/401|session/i.test(r.message))location.replace('/');say(r.message||String(r),true)};
function counts(){let all=0,dn=0;document.querySelectorAll('section.week').forEach(s=>{const b=s.querySelectorAll('[data-task]');const c=[...b].filter(x=>x.checked).length;all+=b.length;dn+=c;s.querySelector('[data-week-count]').textContent=c+'/'+b.length;s.querySelector('.bar i').style.width=(b.length?Math.round(c/b.length*100):0)+'%'});
 document.getElementById('overall').textContent=dn+'/'+all+' done';document.getElementById('overallbar').style.width=(all?Math.round(dn/all*100):0)+'%'}
async function load(){day=localDay();document.getElementById('today').textContent=day;
 const r=await fetch('/api/state?day='+day,{credentials:'same-origin'});if(r.status===401){location.replace('/');return}
 const s=await r.json();
 document.querySelectorAll('[data-task]').forEach(b=>b.checked=!!s.tasks[b.dataset.task]);
 document.querySelectorAll('[data-rhythm]').forEach(b=>b.checked=!!s.rhythm[b.dataset.rhythm]);
 document.querySelectorAll('[data-num]').forEach(i=>i.value=s.numbers[i.dataset.num]??'');counts()}
document.querySelectorAll('[data-task]').forEach(b=>b.onchange=async()=>{counts();try{await post('/api/task',{id:b.dataset.task,done:b.checked});say('Saved')}catch(r){b.checked=!b.checked;counts();fail(r)}});
document.querySelectorAll('[data-rhythm]').forEach(b=>b.onchange=async()=>{try{await post('/api/rhythm',{day,id:b.dataset.rhythm,done:b.checked});say('Saved')}catch(r){b.checked=!b.checked;fail(r)}});
const ns=document.getElementById('numstatus');
async function saveNums(){const numbers={};for(const i of document.querySelectorAll('[data-num]')){if(i.value==='')continue;const v=Number(i.value);if(!Number.isInteger(v)||v<0){ns.textContent=i.dataset.num+': whole number';ns.className='status err';return}numbers[i.dataset.num]=v}
 try{await post('/api/numbers',{day,numbers});ns.textContent='saved';ns.className='status'}catch(r){ns.textContent='not saved';ns.className='status err';fail(r)}}
document.getElementById('savenums').onclick=saveNums;
document.querySelectorAll('[data-num]').forEach(i=>i.onchange=saveNums);
document.getElementById('logout').onclick=async()=>{try{await post('/auth/logout')}catch{}location.replace('/')};
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')load().catch(fail)});
counts();
load().catch(fail);
`;
  return shell(plan.title || 'Plan', nonce, body, script);
}
