#!/usr/bin/env python3
"""Private, pinned-TLS owner-device bridge. Public Sites never receive private control traffic."""
import base64,datetime,hashlib,http.server,importlib.util,json,os,re,secrets,socket,ssl,subprocess,sys,time
from pathlib import Path
sys.dont_write_bytecode=True
RP='work.example.com';MAX=2_000_000
H=None

def b64(data):return base64.b64encode(data).decode()
def decode(value,maximum=MAX):
 if not isinstance(value,str) or len(value)>maximum*2:raise H.Closed('invalid encoding')
 raw=base64.b64decode(value,validate=True)
 if len(raw)>maximum:raise H.Closed('oversized proof')
 return raw

def pem(der):return '-----BEGIN PUBLIC KEY-----\n'+'\n'.join(b64(der)[i:i+64] for i in range(0,len(b64(der)),64))+'\n-----END PUBLIC KEY-----\n'
def p256_der(point):
 if len(point)!=65 or point[0]!=4:raise H.Closed('invalid P256 point')
 return bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d030107034200')+point

def cbor(raw,offset=0,depth=0):
 if depth>8 or offset>=len(raw):raise H.Closed('invalid CBOR')
 first=raw[offset];offset+=1;major,n=first>>5,first&31
 if n in (24,25,26,27):
  width={24:1,25:2,26:4,27:8}[n]
  if offset+width>len(raw):raise H.Closed('truncated CBOR')
  n=int.from_bytes(raw[offset:offset+width],'big');offset+=width
 elif n>=28:raise H.Closed('indefinite CBOR denied')
 if major==0:return n,offset
 if major==1:return -1-n,offset
 if major in (2,3):
  if n>MAX or offset+n>len(raw):raise H.Closed('CBOR length')
  v=raw[offset:offset+n];return (v if major==2 else v.decode()),offset+n
 if major in (4,5):
  if n>100:raise H.Closed('CBOR collection')
  v=[] if major==4 else {}
  for _ in range(n):
   item,offset=cbor(raw,offset,depth+1)
   if major==4:v.append(item)
   else:
    if not isinstance(item,(str,int)) or item in v:raise H.Closed('duplicate CBOR key')
    value,offset=cbor(raw,offset,depth+1);v[item]=value
  return v,offset
 if major==7 and n in (20,21,22):return {20:False,21:True,22:None}[n],offset
 raise H.Closed('unsupported CBOR')

def client_data(encoded,challenge,kind):
 raw=decode(encoded,12000);data=json.loads(raw)
 expected=base64.urlsafe_b64encode(challenge).decode().rstrip('=')
 if data.get('type')!=kind or data.get('challenge')!=expected or data.get('origin')!='https://'+RP or data.get('crossOrigin',False):raise H.Closed('WebAuthn binding mismatch')
 return raw

def registration(obj,challenge):
 client_data(obj['client_data'],challenge,'webauthn.create')
 raw=decode(obj['attestation']);att,end=cbor(raw)
 if end!=len(raw) or not isinstance(att,dict):raise H.Closed('invalid attestation envelope')
 auth=att.get('authData',b'')
 if not isinstance(auth,bytes) or len(auth)<55 or auth[:32]!=hashlib.sha256(RP.encode()).digest() or not auth[32]&1 or not auth[32]&64:raise H.Closed('invalid registration authenticator data')
 size=int.from_bytes(auth[53:55],'big')
 if size<1 or size>1024 or 55+size>=len(auth):raise H.Closed('credential length')
 credential=auth[55:55+size];key,_=cbor(auth,55+size)
 if not isinstance(key,dict) or key.get(1)!=2 or key.get(3)!=-7 or key.get(-1)!=1:raise H.Closed('P256 credential required')
 x,y=key.get(-2),key.get(-3)
 if not isinstance(x,bytes) or not isinstance(y,bytes) or len(x)!=32 or len(y)!=32:raise H.Closed('invalid credential point')
 return {'credential_id':b64(credential),'public_pem':pem(p256_der(b'\x04'+x+y)),'rp':RP}

def assertion(obj,key,challenge):
 client=client_data(obj['client_data'],challenge,'webauthn.get');auth=decode(obj['authenticator_data'],12000)
 if len(auth)<37 or auth[:32]!=hashlib.sha256(RP.encode()).digest() or not auth[32]&1 or decode(obj['credential_id'],1024)!=decode(key['credential_id'],1024):return False
 return H.openssl_verify(key['public_pem'],decode(obj['signature'],1024),auth+hashlib.sha256(client).digest())

def area():return H.STATE/'remote'
def device_path(identifier):
 if not re.fullmatch('[0-9a-f]{24}',identifier):raise H.Closed('invalid device id')
 return area()/'devices'/f'{identifier}.json'

def server_config():
 folder=area();folder.mkdir(parents=True,exist_ok=True,mode=0o700);meta=folder/'server.json'
 if not meta.exists():
  key=folder/'tls-key.pem';cert=folder/'tls-cert.pem'
  # No key material is put on command lines or returned to the app.
  if key.exists() or cert.exists():raise H.Closed('incomplete TLS enrollment preserved')
  name=subprocess.run(['/usr/sbin/scutil','--get','LocalHostName'],capture_output=True,text=True).stdout.strip()
  if not re.fullmatch('[A-Za-z0-9-]+',name):raise H.Closed('local host name unavailable')
  certificate_config=folder/'tls-request.cnf'
  certificate_config.write_text('[req]\ndistinguished_name=subject\nx509_extensions=server\nprompt=no\n[subject]\nCN='+name+'.local\n[server]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:'+name+'.local,DNS:localhost,IP:127.0.0.1\n')
  certificate_config.chmod(0o600)
  result=subprocess.run(['/usr/bin/openssl','req','-x509','-sha256','-newkey','rsa:3072','-nodes','-days','90','-keyout',str(key),'-out',str(cert),'-config',str(certificate_config)],capture_output=True,timeout=30)
  if result.returncode:raise H.Closed('TLS generation failed')
  key.chmod(0o600);cert.chmod(0o600)
  der=ssl.PEM_cert_to_DER_cert(cert.read_text())
  name=subprocess.run(['/usr/sbin/scutil','--get','LocalHostName'],capture_output=True,text=True).stdout.strip()
  if not re.fullmatch('[A-Za-z0-9-]+',name):raise H.Closed('local host name unavailable')
  H.write(meta,{'schema':'alexus-bridge:v1','endpoint':'https://'+name+'.local:8849','certificate_sha256':hashlib.sha256(der).hexdigest(),'certificate_expires_unix':int(time.time())+89*86400})
 return H.read(meta)

def pairing_start():
 meta=server_config();link={**meta,'pairing_token':secrets.token_urlsafe(48),'pairing_expires_unix':int(time.time())+300,'rp':RP}
 H.write(area()/'bootstrap.json',{'token_sha256':hashlib.sha256(link['pairing_token'].encode()).hexdigest(),'expires_unix':link['pairing_expires_unix'],'challenge':b64(secrets.token_bytes(32))})
 export=H.STATE/'ALEXUS-pairing.json';H.write(export,link)
 return {'message':'Private pairing file created for five minutes. Import it on your iPhone, then approve the pending device on this Mac.','pairing_file':str(export)}

def bootstrap(token):
 data=H.read(area()/'bootstrap.json')
 if time.time()>=data['expires_unix'] or not secrets.compare_digest(data['token_sha256'],hashlib.sha256(token.encode()).hexdigest()):raise H.Closed('pairing link expired or invalid')
 return data

def device(token,allow_pending=False):
 hashed=hashlib.sha256(token.encode()).hexdigest()
 for p in (area()/'devices').glob('*.json'):
  d=H.read(p)
  if secrets.compare_digest(d.get('token_sha256',''),hashed) and (d.get('status')=='approved' or allow_pending and d.get('status')=='pending'):
   return d
 raise H.Closed('device not paired')

def pair_prepare(obj,token):
 boot=bootstrap(token);credential=registration(obj,decode(boot['challenge'],32));der=decode(obj['device_public_der'],128)
 # Exactly one P256 SPKI; no algorithm substitution.
 if len(der)!=91 or not der.startswith(bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d03010703420004')):raise H.Closed('P256 device key required')
 token_hash=obj.get('device_token_sha256','')
 if not re.fullmatch('[0-9a-f]{64}',token_hash):raise H.Closed('invalid device token binding')
 existing=[p for p in (area()/'devices').glob('*.json') if H.read(p).get('status')=='approved' or H.read(p).get('manifest',{}).get('expires_unix',0)>time.time()]
 if len(existing)>=8:raise H.Closed('paired device limit')
 identifier=secrets.token_hex(12)
 manifest={'schema':'alexus-pair:v1','id':identifier,'device_public_sha256':hashlib.sha256(der).hexdigest(),'external_public_sha256':hashlib.sha256(credential['public_pem'].encode()).hexdigest(),'device_token_sha256':token_hash,'server_certificate_sha256':server_config()['certificate_sha256'],'nonce':secrets.token_hex(32),'expires_unix':int(time.time())+300}
 record={'id':identifier,'status':'proving','device_public_pem':pem(der),'external_key':credential,'token_sha256':token_hash,'manifest':manifest,'created':H.now()}
 H.write(device_path(identifier),record)
 return {'id':identifier,'manifest':manifest,'message_b64':b64(H.canonical(manifest)),'challenge_b64':b64(bytes.fromhex(H.digest(manifest)))}

def pair_submit(obj,token):
 bootstrap(token);d=H.read(device_path(obj['id']));manifest=d['manifest']
 if d['status']!='proving' or time.time()>=manifest['expires_unix']:raise H.Closed('pairing proof expired')
 message=H.canonical(manifest)
 if not H.openssl_verify(d['device_public_pem'],decode(obj['enclave_signature'],1024),message) or not assertion(obj['external'],d['external_key'],bytes.fromhex(H.digest(manifest))):raise H.Closed('both new-device proofs required')
 d['status']='pending';H.write(device_path(d['id']),d);H.receipt('device.pending_owner',d['id'])
 return {'message':'Phone proofs verified. Approval on the enrolled Mac is still required.','status':'pending'}

def pair_approve(identifier,profile):
 d=H.read(device_path(identifier))
 if d['status']!='pending' or time.time()>=d['manifest']['expires_unix']:raise H.Closed('device enrollment expired')
 manifest={'schema':'alexus-pair-owner:v1','device':d['manifest'],'nonce':secrets.token_hex(32),'expires_unix':int(time.time())+150,'action':'pair-owner-device'}
 folder=area()/'approvals'/identifier;folder.mkdir(parents=True,exist_ok=True,mode=0o700)
 if not H.authorize(manifest,profile,folder) or time.time()>=manifest['expires_unix'] or (H.STATE/'revoked').exists():raise H.Closed('fresh existing-owner approval required')
 d['status']='approved';d['approved_at']=H.now();H.write(device_path(identifier),d);H.receipt('device.owner_approved',identifier)
 return {'message':'Device paired after both fresh existing-owner proofs. Every repair still requires fresh phone Enclave and external-key proofs.'}

def list_devices():
 return [{'id':d['id'],'status':d['status'],'fingerprint':d['manifest']['device_public_sha256']} for p in (area()/'devices').glob('*.json') for d in [H.read(p)] if d['status'] in ['pending','approved']]

def prepare_remote(rid,d):
 folder=H.repair_path(rid);s=H.read(folder/'state.json')
 if s['status']!='awaiting_owner':raise H.Closed('repair not awaiting owner')
 baseline=H.read(folder/'baseline.json');after=H.read(folder/'candidate-files.json')
 artifact=folder/'candidate/build/Build/Products/Debug/ALEXUSMac.app'
 if H.files(H.SOURCE)!=baseline or H.files(folder/'candidate')!=after or H.files(artifact,artifact=True)!=H.read(folder/'artifact-files.json'):raise H.Closed('candidate changed')
 manifest={'schema':'alexus-repair:v1','repair_id':rid,'candidate_sha256':H.digest(after),'source_sha256':H.digest(baseline),'checks_sha256':s['checks_sha256'],'artifact_sha256':H.digest(H.read(folder/'artifact-files.json')),'nonce':secrets.token_hex(32),'expires_unix':int(time.time())+150,'action':'apply-source-and-install-selected-targets','owner_device_id':d['id'],'authorization_epoch':H.epoch(),'receipt_head_sha256':H.receipt_head(),**H.deployment_fields(folder)}
 H.write(folder/'remote-pending.json',{'manifest':manifest,'status':'pending'})
 return {'id':rid,'manifest':manifest,'message_b64':b64(H.canonical(manifest)),'challenge_b64':b64(bytes.fromhex(H.digest(manifest))),'credential_id':d['external_key']['credential_id'],'rp':RP}

def verify_remote(manifest,proof,folder):
 pending=H.read(folder/'remote-pending.json');d=H.read(device_path(manifest['owner_device_id']))
 if not H.receipt_prefix_valid(manifest.get('receipt_head_sha256')) or (H.STATE/'revoked').exists() or manifest.get('authorization_epoch')!=H.epoch() or pending.get('status')!='pending' or pending.get('manifest')!=manifest or d.get('status')!='approved' or time.time()>=manifest['expires_unix']:return False
 if not H.openssl_verify(d['device_public_pem'],decode(proof['enclave_signature'],1024),H.canonical(manifest)) or not assertion(proof['external'],d['external_key'],bytes.fromhex(H.digest(manifest))):return False
 pending['status']='consumed';H.write(folder/'remote-pending.json',pending)
 H.write(folder/'remote-owner-proof.json',{'manifest':manifest,'device':d['id'],'enclave_signature':proof['enclave_signature'],'external':proof['external']})
 return True

def dispatch(request,host):
 global H;H=host
 cmd=request.get('command')
 if cmd=='pairing_start':return pairing_start()
 if cmd=='pairing_list':return {'devices':list_devices(),'message':'Owner device enrollments.'}
 if cmd=='pairing_approve':return pair_approve(request.get('id',''),request.get('profile',''))
 if cmd=='pairing_revoke':
  p=device_path(request.get('id',''));d=H.read(p);d['status']='revoked';H.write(p,d);H.receipt('device.revoked',d['id']);return {'message':'Device revoked. Pending repair proofs from it will be rejected.'}
 raise H.Closed('unknown pairing operation')

def api(path,method,token,obj):
 if path=='/v1/pairing/challenge' and method=='GET':return {'challenge_b64':bootstrap(token)['challenge'],'rp':RP}
 if path=='/v1/pairing/prepare' and method=='POST':return pair_prepare(obj,token)
 if path=='/v1/pairing/submit' and method=='POST':return pair_submit(obj,token)
 d=device(token,allow_pending=path=='/v1/pairing/status')
 if path=='/v1/pairing/status':return {'id':d['id'],'status':d['status']}
 if path=='/v1/status' and method=='GET':return H.main({'command':'status'})
 if path=='/v1/deployments' and method=='POST':
  if obj.get('command') not in {'deployments_list','deployment_get','deployment_start','deployment_stop','deployment_resume'}:raise H.Closed('invalid deployment command')
  return H.main({k:obj[k] for k in ('command','id','kind','project','provider','model','steps') if k in obj})
 if path=='/v1/chat' and method=='POST':
  if obj.get('command') not in {'chat_models','chat_list','chat_get','chat_send','chat_stop'}:raise H.Closed('invalid chat command')
  return H.main({k:obj[k] for k in ('command','id','provider','model','project','text') if k in obj})
 if path=='/v1/report-error' and method=='POST':return H.main({'command':'report_error','code':obj.get('code','unknown')})
 if path=='/v1/queue' and method=='POST':return H.main({'command':'queue','instruction':obj.get('instruction',''),'provider':obj.get('provider','codex'),'model':obj.get('model','')})
 if path=='/v1/stop' and method=='POST':return H.main({'command':'stop'})
 match=re.fullmatch('/v1/repairs/([0-9a-f]{24})/(diff|challenge|apply)',path)
 if not match:raise H.Closed('unknown endpoint')
 rid,action=match.groups()
 if action=='diff' and method=='GET':return H.main({'command':'diff','id':rid})
 if action=='challenge' and method=='POST':return prepare_remote(rid,d)
 if action=='apply' and method=='POST':
  pending=H.read(H.repair_path(rid)/'remote-pending.json');manifest=pending['manifest']
  if manifest.get('owner_device_id')!=d['id']:raise H.Closed('wrong device')
  return H.main({'command':'remote_apply','id':rid,'remote_manifest':manifest,'remote_proof':obj})
 raise H.Closed('invalid method')

def serve(host):
 global H;H=host;H.STATE.mkdir(parents=True,exist_ok=True,mode=0o700);server_config()
 class Handler(http.server.BaseHTTPRequestHandler):
  def log_message(self,*args):pass
  def handle_request(self):
   try:
    auth=self.headers.get('Authorization','')
    if not auth.startswith('Bearer '):raise H.Closed('unauthorized')
    n=int(self.headers.get('Content-Length','0'))
    if n<0 or n>MAX:raise H.Closed('too large')
    body=self.rfile.read(n) if n else b'{}';obj=json.loads(body)
    result=api(self.path,self.command,auth[7:],obj);code=200
   except Exception:result={'error':'held','message':'Private operation not authorized or unavailable.'};code=403
   data=json.dumps(result,separators=(',',':')).encode();self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store');self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(data)
  do_GET=handle_request;do_POST=handle_request
 context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.minimum_version=ssl.TLSVersion.TLSv1_3;context.set_ciphers('ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256');context.set_alpn_protocols(['http/1.1']);context.load_cert_chain(area()/'tls-cert.pem',area()/'tls-key.pem')
 class Server(http.server.ThreadingHTTPServer):
  daemon_threads=True
  def get_request(self):
   client,address=super().get_request();client.settimeout(15)
   try:return context.wrap_socket(client,server_side=True),address
   except BaseException as error:
    if os.environ.get('ALEXUS_TLS_FIXTURE_DIAGNOSTICS')=='1':print('TLS fixture server: '+type(error).__name__+' '+str(getattr(error,'reason','')),file=sys.stderr,flush=True)
    client.close();raise
 bind=os.environ.get('ALEXUS_BRIDGE_BIND','0.0.0.0');port=int(os.environ.get('ALEXUS_BRIDGE_PORT','8849'))
 if bind not in {'0.0.0.0','127.0.0.1'} or not 1024<=port<=65535:raise H.Closed('invalid listener')
 server=Server((bind,port),Handler);server.serve_forever()
if __name__=='__main__':
 os.umask(0o077)
 spec=importlib.util.spec_from_file_location('alexus_host',Path(__file__).with_name('alexus_host.py'));host=importlib.util.module_from_spec(spec);sys.modules[spec.name]=host;spec.loader.exec_module(host);serve(host)
