// Persistent sanitized catalog ingress; no code execution or model credentials.
const HEADERS={'X-Content-Type-Options':'nosniff','Cache-Control':'no-store'};
const json=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:{...HEADERS,'Content-Type':'application/json'}});
async function authorized(request,secret){
 if(!secret)return false;
 const hash=async s=>new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
 const [a,b]=await Promise.all([hash(request.headers.get('Authorization')||''),hash('Bearer '+secret)]);
 let diff=0;for(let i=0;i<a.length;i++)diff|=a[i]^b[i];return diff===0;
}
const safeText=value=>typeof value==='string'&&value.length<=12000&&!/(PRIVATE KEY|sk-proj-|ghp_|AKIA[A-Z0-9]{12}|credential_id|secure-enclave.reference|1Password|Emergency Kit)/.test(value);
function bounded(value,depth=0){
 if(depth>15)return false;
 if(typeof value==='string')return safeText(value);
 if(value===null||typeof value==='boolean')return true;
 if(typeof value==='number')return Number.isFinite(value);
 if(Array.isArray(value))return value.length<5000&&value.every(v=>bounded(v,depth+1));
 return value&&typeof value==='object'&&Object.keys(value).length<100&&Object.entries(value).every(([k,v])=>safeText(k)&&!['__proto__','constructor','prototype'].includes(k)&&bounded(v,depth+1));
}
function valid(payload,role){
 if(!bounded(payload)||payload.schema!=='ragnarok-sync:v1'||payload.role!==role||payload.runtime!=='Unverified')return false;
 if(Object.keys(payload).some(k=>!['schema','role','observed_at','counts','runtime','catalog'].includes(k)))return false;
 const time=Date.parse(payload.observed_at);
 if(!Number.isFinite(time)||Math.abs(Date.now()-time)>15*60*1000)return false;
 const c=payload.counts;
 if(!c||Object.keys(c).sort().join(',')!=='current,held,total'||!Object.values(c).every(n=>Number.isInteger(n)&&n>=0&&n<=1000)||c.current+c.held!==c.total)return false;
 if(role==='alexus')return !payload.catalog;
 const d=payload.catalog;
 if(!d||d.schema!==FALLBACK.schema||!d.main_project||d.main_project.project_title!=='ALEXUS')return false;
 if(Object.keys(d).sort().join(',')!==Object.keys(FALLBACK).sort().join(','))return false;
 if(!Array.isArray(d.projects)||d.projects.length!==FALLBACK.projects.length)return false;
 const pinned=new Map(FALLBACK.projects.map(p=>[p.id,p]));
 const ids=new Set();
 for(const p of d.projects){
  const old=pinned.get(p.id);
  if(!old||ids.has(p.id)||p.path!==old.path||p.runtime!=='Unverified'||p.kind!==old.kind)return false;
  ids.add(p.id);
  if(!Array.isArray(p.checks)||p.checks.some(c=>c.result==='passed'&&c.source_matches!==true))return false;
 }
 return true;
}
export default{async fetch(request,env){
 try{
  const url=new URL(request.url),path=url.pathname;
  if(path.startsWith('/api/sync/')&&request.method==='POST'){
   const role=path.slice('/api/sync/'.length);
   if(!['mac','alexus'].includes(role))return json({error:'not found'},404);
   if(!await authorized(request,role==='mac'?env.SYNC_MAC_TOKEN:env.SYNC_ALEXUS_TOKEN))return json({error:'unauthorized'},401);
   if(!env.BUCKET)return json({error:'storage unavailable'},503);
   const size=Number(request.headers.get('Content-Length'));
   if(!Number.isFinite(size)||size<1||size>2_000_000)return json({error:'size required'},413);
   const reader=request.body.getReader();let bytes=0;const parts=[];
   while(true){const {value,done}=await reader.read();if(done)break;bytes+=value.length;if(bytes>2_000_000){await reader.cancel();return json({error:'too large'},413);}parts.push(value);}
   const buffer=new Uint8Array(bytes);let pos=0;for(const part of parts){buffer.set(part,pos);pos+=part.length;}
   let payload;try{payload=JSON.parse(new TextDecoder().decode(buffer));}catch{return json({error:'invalid JSON'},400);}
   if(!valid(payload,role))return json({error:'invalid sanitized snapshot'},400);
   const previous=await env.BUCKET.get('sync/'+role+'.json');
   if(previous&&Date.parse((await previous.json()).observed_at)>=Date.parse(payload.observed_at))return json({error:'older snapshot'},409);
   await env.BUCKET.put('sync/'+role+'.json',JSON.stringify(payload),{httpMetadata:{contentType:'application/json'}});
   return json({stored:true,role,observed_at:payload.observed_at});
  }
  if(request.method!=='GET'&&request.method!=='HEAD')return json({error:'method not allowed'},405);
  if(path==='/api/sync/status'){
   const hosts={};for(const role of ['mac','alexus']){
    const object=env.BUCKET&&await env.BUCKET.get('sync/'+role+'.json');
    if(!object){hosts[role]={status:'Unverified',reason:'no heartbeat'};continue;}
    const d=await object.json();hosts[role]={observed_at:d.observed_at,counts:d.counts,status:Date.now()-Date.parse(d.observed_at)>15*60*1000?'Unverified: stale':'observed',runtime:'Unverified'};
   }
   return json({schema:'ragnarok-sync-status:v1',hosts});
  }
  if(path==='/api/catalog'||path==='/catalog.json'){
   const object=env.BUCKET&&await env.BUCKET.get('sync/mac.json');
   return json(object?(await object.json()).catalog:FALLBACK);
  }
  const asset=ASSETS[path==='/'?'/index.html':path];
  if(!asset)return json({error:'not found'},404);
  const bytes=Uint8Array.from(atob(asset.body),c=>c.charCodeAt(0));
  return new Response(request.method==='HEAD'?null:bytes,{headers:{'Content-Type':asset.type,'X-Content-Type-Options':'nosniff','Cache-Control':path.startsWith('/owner-auth')?'no-store':'no-cache','Referrer-Policy':'no-referrer','Content-Security-Policy':"default-src 'self'; img-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"}});
 }catch{return json({error:'request unavailable'},503);}
}};
