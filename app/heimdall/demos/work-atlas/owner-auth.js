'use strict';
// Only non-secret challenge/credential data travels in the fragment; fragments are not sent to hosting.
const text=(id,value)=>{document.getElementById(id).textContent=value;};
const b64=bytes=>btoa(String.fromCharCode(...new Uint8Array(bytes)));
const bytes=text=>Uint8Array.from(atob(text),c=>c.charCodeAt(0));
const decode=text=>{let s=text.replace(/-/g,'+').replace(/_/g,'/');s+='='.repeat((4-s.length%4)%4);return JSON.parse(new TextDecoder().decode(bytes(s)));};
const encode=obj=>b64(new TextEncoder().encode(JSON.stringify(obj))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
let request=null,busy=false,lastFailure=null;
const safeFailure=error=>{
 const known=['NotAllowedError','NotSupportedError','SecurityError','InvalidStateError','AbortError','ConstraintError','TypeError','unavailable','external-required'];
 return known.includes(error?.name)?error.name:known.includes(error?.message)?error.message:'unknown';
};
const finish=(ok,proof,error)=>{
 const result={state:request.state,ok};if(proof)result.proof=proof;if(error)result.error=error;
 location.replace('alexus-owner://auth#'+encode(result));
};
try{
 if(location.hostname!=='work.example.com'||location.hash.length>12000)throw Error('domain');
 request=decode(location.hash.slice(1));
 if(request.v!==1||!['create','get'].includes(request.operation)||typeof request.state!=='string'||!/^[A-Za-z0-9-]{32,100}$/.test(request.state)||typeof request.challenge!=='string'||bytes(request.challenge).length!==32)throw Error('request');
 if(request.operation==='create'&&(!request.user_id||bytes(request.user_id).length!==32))throw Error('user');
 if(request.operation==='get'&&(!request.credential_id||bytes(request.credential_id).length<1||bytes(request.credential_id).length>1024))throw Error('credential');
 text('purpose',request.operation==='create'?'Enroll your external security key for this ALEXUS owner device. Approval on your enrolled Mac is still required.':'Authorize the exact challenge shown by your ALEXUS app. No source change is applied by this page.');
 text('status','Ready for your physical security key.');document.getElementById('authorize').disabled=false;document.getElementById('cancel').disabled=false;
}catch{request=null;text('status','No valid app request. Return to ALEXUS and start a new authorization.');}
document.getElementById('cancel').onclick=()=>{if(request)finish(false,null,lastFailure||'cancelled');};
document.getElementById('authorize').onclick=async()=>{
 if(!request||busy)return;busy=true;document.getElementById('authorize').disabled=true;
 try{
  if(!navigator.credentials||!window.PublicKeyCredential)throw Error('unavailable');
  const challenge=bytes(request.challenge);let credential;
  if(request.operation==='create'){
   credential=await navigator.credentials.create({publicKey:{challenge,rp:{id:'work.example.com',name:'ALEXUS owner'},user:{id:bytes(request.user_id),name:'Owner',displayName:'ALEXUS owner'},pubKeyCredParams:[{type:'public-key',alg:-7}],authenticatorSelection:{authenticatorAttachment:'cross-platform',residentKey:'discouraged',userVerification:'discouraged'},hints:['security-key'],attestation:'direct',timeout:90000}});
   if(credential.authenticatorAttachment&&credential.authenticatorAttachment!=='cross-platform')throw Error('external-required');
   finish(true,{credential_id:b64(credential.rawId),attestation:b64(credential.response.attestationObject),client_data:b64(credential.response.clientDataJSON)});
  }else{
   credential=await navigator.credentials.get({publicKey:{challenge,rpId:'work.example.com',allowCredentials:[{type:'public-key',id:bytes(request.credential_id),transports:['usb','nfc']}],userVerification:'discouraged',hints:['security-key'],timeout:90000}});
   if(credential.authenticatorAttachment&&credential.authenticatorAttachment!=='cross-platform')throw Error('external-required');
   finish(true,{credential_id:b64(credential.rawId),authenticator_data:b64(credential.response.authenticatorData),client_data:b64(credential.response.clientDataJSON),signature:b64(credential.response.signature)});
  }
 }catch(error){lastFailure=safeFailure(error);text('status','Security-key approval did not complete ('+lastFailure+'). Nothing was authorized. Use Cancel to return this error to ALEXUS, or try again.');busy=false;document.getElementById('authorize').disabled=false;}
};
