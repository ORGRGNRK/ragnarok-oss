#!/usr/bin/env python3
"""Private Mac repair coordinator. Only fresh dual-hardware proof permits application."""
import base64,contextlib,datetime,fcntl,hashlib,json,os,plistlib,re,secrets,shutil,signal,subprocess,sys,tempfile,time
from pathlib import Path
sys.dont_write_bytecode=True
HOME=Path.home();STATE=Path(os.environ.get('ALEXUS_STATE',HOME/'.alexus/app'))
SOURCE=Path(os.environ.get('ALEXUS_SOURCE_ROOT',Path(__file__).resolve().parents[1])).resolve()
ALLOWED={'Sources/Views.swift','Sources/Models.swift'}
EXCLUDE={'build','build-device','.build','.git','.DS_Store','__pycache__'}
PROFILES={'yubikey-primary','utrust-spare'}
class Closed(Exception):pass

def canonical(x):return json.dumps(x,sort_keys=True,separators=(',',':'),ensure_ascii=True).encode()
def digest(x):return hashlib.sha256(canonical(x)).hexdigest()
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')
def write(path,data):
 path=Path(path);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
 fd,tmp=tempfile.mkstemp(dir=path.parent)
 try:
  with os.fdopen(fd,'wb') as f:f.write(canonical(data));f.flush();os.fsync(f.fileno())
  os.chmod(tmp,0o600);os.replace(tmp,path)
 finally:
  if os.path.exists(tmp):os.unlink(tmp)

def read(path):return json.loads(Path(path).read_text())
def regular(path):return path.is_file() and not path.is_symlink()
def files(root,artifact=False):
 result={}
 for d,dirs,names in os.walk(root,followlinks=False):
  p=Path(d)
  if any((p/n).is_symlink() for n in dirs+names):raise Closed('symlink in source')
  if not artifact:dirs[:]=[n for n in dirs if n not in EXCLUDE and not n.endswith('.xcodeproj')]
  for name in names:
   if artifact or name not in EXCLUDE and not name.endswith('.pyc'):
    f=p/name;result[str(f.relative_to(root))]=hashlib.sha256(f.read_bytes()).hexdigest()
 return result

def command(args,cwd=None,input=None,timeout=120,check=True,extra_env=None):
 p=subprocess.Popen(args,cwd=cwd,env=dict(os.environ,**(extra_env or {}),ALEXUS_SOURCE_ROOT=str(SOURCE)),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
 start=time.monotonic()
 # communicate in bounded slices allows the independent force-stop command to revoke this operation.
 try:
  first=True
  while True:
   if (STATE/'revoked').exists():raise Closed('stopped')
   if time.monotonic()-start>timeout:raise Closed('operation timed out')
   try:out,err=p.communicate(input=input if first else None,timeout=.2);break
   except subprocess.TimeoutExpired:first=False
  if check and p.returncode:raise Closed('subprocess did not pass')
  return p.returncode,out
 finally:
  try:os.killpg(p.pid,signal.SIGKILL)
  except ProcessLookupError:pass
  p.communicate()

def epoch():
 path=STATE/'epoch.json'
 if not path.exists():write(path,{'value':secrets.token_hex(32)})
 return read(path)['value']

def remote_module():
 import importlib.util
 spec=importlib.util.spec_from_file_location('alexus_remote',Path(__file__).with_name('remote_host.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);module.H=sys.modules[__name__];return module

def receipt(action,rid=''):
 with (STATE/'receipt.lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX);_append_receipt(action,rid)

def _append_receipt(action,rid=''):
 path=STATE/'receipts.json';rows=read(path) if path.exists() else []
 if not valid_receipts(rows):raise Closed('receipt chain invalid')
 row={'sequence':len(rows)+1,'timestamp':now(),'action':action,'repair_id':rid,'previous_hash':rows[-1]['hash'] if rows else '0'*64}
 row['hash']=digest(row);rows.append(row);write(path,rows)

def valid_receipts(rows):
 previous='0'*64
 for i,row in enumerate(rows):
  body={k:v for k,v in row.items() if k!='hash'}
  if row.get('sequence')!=i+1 or row.get('previous_hash')!=previous or row.get('hash')!=digest(body):return False
  previous=row['hash']
 return True

def receipt_head():
 rows=read(STATE/'receipts.json') if (STATE/'receipts.json').exists() else []
 if not valid_receipts(rows):raise Closed('receipt chain invalid')
 return rows[-1]['hash'] if rows else '0'*64

def receipt_prefix_valid(value):
 rows=read(STATE/'receipts.json') if (STATE/'receipts.json').exists() else []
 return valid_receipts(rows) and (value=='0'*64 or any(r['hash']==value for r in rows))

def profile_keys():
 values={}
 for name in sorted(PROFILES):
  p=HOME/'.alexus/keys'/name/'pubkey.pem'
  if regular(p):values[name]=hashlib.sha256(p.read_bytes()).hexdigest()
 p=HOME/'.ragnarok/hardware/laptop/public.pem'
 if regular(p):values['enclave']=hashlib.sha256(p.read_bytes()).hexdigest()
 return values

def config():
 path=STATE/'config.json'
 if not path.exists():
  # Reuse the owner's existing enrollment; presence alone never authorizes a repair.
  write(path,{'schema':1,'source':str(SOURCE),'keys':profile_keys(),'check_sha256':hashlib.sha256((SOURCE/'check.sh').read_bytes()).hexdigest(),'max_stages_per_day':3})
 c=read(path)
 if c.get('source')!=str(SOURCE):raise Closed('source enrollment changed')
 return c

def repair_path(rid):
 if not re.fullmatch('[0-9a-f]{24}',rid):raise Closed('invalid repair id')
 return STATE/'repairs'/rid

def heimdall_status():
 # Fixed sibling project only. Never expose filenames, messages or raw Git/log output.
 root=SOURCE.parent/'heimdall'
 result={'name':'Heimdall / Ragnarok','source':str(root),'observed_at':now(),'revision':'Unverified','changed_entries':None,
         'app_present':(HOME/'Applications/Ragnarok.app').is_dir(),'error_log_present':False,'error_log_updated_at':None,'runtime':'Unverified'}
 if root.is_dir():
  def git(*args):
   p=subprocess.run(['git','--no-optional-locks','-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null',*args],cwd=root,capture_output=True,timeout=5)
   if p.returncode:raise ValueError('Git observation unavailable')
   return p.stdout
  try:
   revision=git('rev-parse','--verify','HEAD').decode().strip()
   if re.fullmatch('[0-9a-f]{40,64}',revision):result['revision']=revision
   entries=git('status','--porcelain=v1','-z','--untracked-files=all','--','.').split(b'\0')
   # Rename/copy entries contain a second path field; count status records only.
   count=0;skip=False
   for entry in entries:
    if skip:skip=False;continue
    if not entry:continue
    count+=1;skip=b'R' in entry[:2] or b'C' in entry[:2]
   result['changed_entries']=count
  except (OSError,ValueError,subprocess.SubprocessError):pass
 log=HOME/'.ragnarok/ragnarok-app-errors.jsonl'
 try:
  if regular(log):
   result['error_log_present']=True
   result['error_log_updated_at']=datetime.datetime.fromtimestamp(log.stat().st_mtime,datetime.timezone.utc).isoformat(timespec='seconds')
 except OSError:pass
 return result

def status():
 c=config();repairs=[]
 for p in sorted((STATE/'repairs').glob('*/state.json'),reverse=True):
  item=read(p);repairs.append({k:v for k,v in item.items() if k in {'id','status','created','note','changed_files','candidate_sha256'}})
 rows=read(STATE/'receipts.json') if (STATE/'receipts.json').exists() else []
 agents=[]
 for p in sorted((HOME/'.ragnarok/agents').glob('*/state.json'),key=lambda p:p.stat().st_mtime,reverse=True)[:30]:
  try:
   a=read(p);clean=lambda v:re.sub('[^a-zA-Z0-9_. -]','',str(v))[:80]
   actor=a.get('who','Unverified');phase=a.get('status','Unverified')
   agents.append({'id':clean(p.parent.name),'who':actor if actor in {'claude','grok','codex','muse','antigravity','argon'} else 'Unverified','status':phase if phase in {'running','working','planning','verifying','reviewing','done','finished','failed','stopped','blocked','queued','starting','needs_you','dead_end'} else 'Unverified'})
  except (ValueError,OSError):continue
 return {'schema':'alexus-host:v1','repairs':repairs[:100],'receipts':rows[-100:],'agents':agents,'heimdall':heimdall_status(),
         'enclave_enrolled':'enclave' in c['keys'],'external_profiles':[n for n in sorted(PROFILES) if n in c['keys']],
         'automation':'Stage-only watcher installed' if (STATE/'watcher.json').exists() else 'Manual staging; automatic application is disabled',
         'receipt_integrity':'Valid local hash chain' if valid_receipts(rows) else 'Unverified: chain invalid'}

def queue(instruction,kind='owner-request',provider='codex',selected_model=''):
 instruction=str(instruction).strip()
 if not instruction or len(instruction)>5000:raise Closed('invalid request')
 if len(list((STATE/'repairs').glob('*/state.json')))>=100:raise Closed('repair queue full')
 rid=secrets.token_hex(12);folder=repair_path(rid)
 if provider not in {'codex','mac','alexus'}:raise Closed('invalid repair provider')
 if provider!='codex':
  chat=chat_module()
  if selected_model not in chat.models(provider):raise Closed('repair model not discovered')
 write(folder/'request.json',{'instruction':instruction,'kind':kind,'provider':provider,'model':selected_model})
 write(folder/'state.json',{'id':rid,'created':now(),'status':'queued','note':'Queued for an isolated candidate. No application authorized.'})
 receipt('repair.queued',rid);return {'message':'Repair queued. No source or app has changed.','id':rid}

def set_state(folder,status,note,**extra):
 s=read(folder/'state.json');s.update(status=status,note=note,**extra);write(folder/'state.json',s)

def copy_source(root,target):
 shutil.copytree(root,target,ignore=shutil.ignore_patterns('build','build-device','.build','.git','*.xcodeproj','__pycache__','.DS_Store'))

def chat_module():
 import importlib.util
 spec=importlib.util.spec_from_file_location('alexus_chat',Path(__file__).with_name('chat_host.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);module.H=sys.modules[__name__];return module

def model(args,cwd,prompt,timeout=1200,provider='codex',selected_model=''):
 if provider in {'mac','alexus'}:
  if not re.fullmatch(r'[A-Za-z0-9_./:@-]{1,160}',selected_model):raise Closed('invalid local model')
  return chat_module().repair_model(args,cwd,prompt,provider,selected_model)
 if provider!='codex':raise Closed('invalid provider')
 binary=shutil.which('codex')
 if not binary:raise Closed('Codex unavailable')
 return command([binary,'exec','--ignore-user-config','--ephemeral','--color','never','-c','approval_policy="never"',*args,'-'],cwd,prompt.encode(),timeout)[1]

def stage(rid):
 c=config();folder=repair_path(rid);s=read(folder/'state.json')
 if s['status']!='queued':raise Closed('repair is not queued')
 if hashlib.sha256((SOURCE/'check.sh').read_bytes()).hexdigest()!=c['check_sha256']:raise Closed('verification harness changed')
 _,dirty=command(['git','-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null','status','--porcelain','--untracked-files=all','--',str(SOURCE)],SOURCE)
 if dirty.strip():raise Closed('ALEXUS source has uncommitted changes')
 today=datetime.date.today().isoformat()
 recent=[p for p in (STATE/'repairs').glob('*/stage-start.json') if read(p).get('date')==today]
 if len(recent)>=c['max_stages_per_day']:raise Closed('daily stage limit reached')
 if len(list((STATE/'repairs').glob('*/candidate')))>=4:raise Closed('retained candidate capacity reached')
 build_number=str(c.get('next_build_number',2));c['next_build_number']=int(build_number)+1;write(STATE/'config.json',c)
 baseline=files(SOURCE);snapshot=folder/'baseline-source';workspace=folder/'agent-workspace';candidate=folder/'candidate'
 copy_source(SOURCE,snapshot)
 if files(snapshot)!=baseline:raise Closed('source changed while snapshotting')
 copy_source(snapshot,workspace);write(folder/'baseline.json',baseline);write(folder/'stage-start.json',{'date':today})
 set_state(folder,'implementing','Selected model is editing an isolated workspace.');receipt('repair.staging',rid)
 git_prefix=['git','-c','core.hooksPath=/dev/null','-c','core.fsmonitor=false','-c','core.attributesFile=/dev/null']
 command(git_prefix+['init','-q'],workspace);command(git_prefix+['add','.'],workspace)
 command(git_prefix+['-c','user.name=ALEXUS stage','-c','user.email=stage@invalid','commit','-qm','frozen baseline'],workspace)
 request_record=read(folder/'request.json');request=request_record['instruction']
 route={'provider':request_record.get('provider','codex'),'selected_model':request_record.get('model','')}
 model(['--sandbox','workspace-write'],workspace,'Implement this owner request in the isolated ALEXUS workspace. Change only Sources/Views.swift and Sources/Models.swift. Do not edit authorization, policy, host, tests, build scripts, git metadata or other files. Do not install, apply, launch or send messages. Unknown runtime claims remain Unverified. Request:\n'+request,**route)
 after=files(workspace);changed=sorted(k for k in set(baseline)|set(after) if baseline.get(k)!=after.get(k))
 if not changed:raise Closed('no candidate change')
 if not set(changed)<=ALLOWED or not set(baseline)<=set(after):raise Closed('candidate exceeded allowed files')
 # Only allowlisted source bytes cross into a separate verifier folder. Agent-built caches,
 # bytecode, Git metadata and generated projects never reach trusted verification.
 proposed={rel:(workspace/rel).read_bytes() for rel in changed}
 if any(hashlib.sha256(data).hexdigest()!=after[rel] for rel,data in proposed.items()):raise Closed('proposal changed while capturing')
 copy_source(snapshot,candidate)
 command(git_prefix+['init','-q'],candidate);command(git_prefix+['add','.'],candidate)
 command(git_prefix+['-c','user.name=ALEXUS stage','-c','user.email=stage@invalid','commit','-qm','frozen baseline'],candidate)
 for rel,data in proposed.items():(candidate/rel).write_bytes(data)
 if files(candidate)!=after:raise Closed('verification candidate differs from captured proposal')
 set_state(folder,'verifying','Frozen Mac/iOS build and core checks running.',changed_files=changed)
 # The generator and check harness remain byte-identical to the frozen baseline.
 _,out=command(['/bin/zsh',str(candidate/'check.sh')],candidate,timeout=900,extra_env={'ALEXUS_BUILD_NUMBER':build_number})
 checks_hash=hashlib.sha256(out).hexdigest();write(folder/'checks.json',{'result':'passed','scope':'Mac core tests plus macOS/iOS simulator builds. Physical behavior and incident resolution Unverified.','output_sha256':checks_hash})
 if c.get('ios_target'):
  target=c['ios_target']
  _,ios_output=command(['xcodebuild','-project','ALEXUS.xcodeproj','-scheme','ALEXUSiOS','-configuration','Debug','-derivedDataPath','build-device','-destination','generic/platform=iOS','-allowProvisioningUpdates','ALEXUS_CANONICAL_SOURCE_ROOT='+str(SOURCE),'CURRENT_PROJECT_VERSION='+build_number,'build'],candidate,timeout=900)
  ios_app=candidate/'build-device/Build/Products/Debug-iphoneos/ALEXUSiOS.app'
  command(['codesign','--verify','--strict',str(ios_app)])
  _,entitlements=command(['codesign','-d','--entitlements',':-',str(ios_app)])
  ent=plistlib.loads(entitlements)
  if ent.get('application-identifier')!=target['team_id']+'.'+target['bundle_id']:raise Closed('iOS signing identity mismatch')
  _,profile=command(['security','cms','-D','-i',str(ios_app/'embedded.mobileprovision')])
  if target['udid'] not in plistlib.loads(profile).get('ProvisionedDevices',[]):raise Closed('selected iOS device not provisioned')
  write(folder/'ios-artifact-files.json',files(ios_app,artifact=True));write(folder/'ios-checks.json',{'result':'passed','output_sha256':hashlib.sha256(ios_output).hexdigest(),'build_number':build_number})
 _,diff=command(git_prefix+['diff','--no-ext-diff','--no-textconv','--','Sources/Views.swift','Sources/Models.swift'],candidate)
 (folder/'candidate.diff').write_bytes(diff);os.chmod(folder/'candidate.diff',0o600)
 schema={'type':'object','properties':{'verdict':{'type':'string','enum':['approve','reject']},'reason':{'type':'string'}},'required':['verdict','reason'],'additionalProperties':False}
 write(folder/'review-schema.json',schema)
 set_state(folder,'reviewing','Independent read-only model review.');receipt('repair.checks_passed',rid)
 model(['--sandbox','read-only','--output-schema',str(folder/'review-schema.json'),'--output-last-message',str(folder/'review.json')],candidate,'Independently review the staged diff for this request. Try to refute its correctness, evidence claims and safety. Do not modify files or approve hardware actions. Reject unsupported success claims. Owner request:\n'+request,**route)
 review=read(folder/'review.json')
 if review.get('verdict')!='approve':raise Closed('independent review rejected candidate')
 # Reject any edits that happened during checking/review.
 if files(candidate)!=after:raise Closed('candidate changed during verification')
 artifact=candidate/'build/Build/Products/Debug/ALEXUSMac.app'
 if not artifact.is_dir():raise Closed('tested Mac artifact missing')
 # Compile the trusted Enclave helper; it is not model-editable.
 command(['xcrun','swiftc',str(candidate/'Host/EnclaveAuthenticator.swift'),'-o',str(artifact/'Contents/Resources/EnclaveAuthenticator'),'-framework','CryptoKit','-framework','Security','-framework','LocalAuthentication'],candidate)
 artifact_files=files(artifact,artifact=True)
 write(folder/'candidate-files.json',after);write(folder/'artifact-files.json',artifact_files)
 set_state(folder,'awaiting_owner','Checks and review passed. Fresh dual-hardware authorization required; runtime Unverified.',candidate_sha256=digest(after),source_sha256=digest(baseline),checks_sha256=checks_hash,changed_files=changed)
 set_state(folder,'awaiting_owner','Checks and review passed. Fresh dual-hardware authorization required; runtime Unverified.',targets=['macOS','selected iOS device'] if c.get('ios_target') else ['macOS'])
 receipt('repair.awaiting_owner',rid)
 return {'message':'Candidate is tested and reviewed. Inspect its diff before fresh dual-key approval.'}

def openssl_verify(public,signature,message):
 with tempfile.TemporaryDirectory() as d:
  p=Path(d);(p/'public').write_text(public);(p/'signature').write_bytes(signature);(p/'message').write_bytes(message)
  code,_=command(['/usr/bin/openssl','dgst','-sha256','-verify',str(p/'public'),'-signature',str(p/'signature'),str(p/'message')],check=False)
  return code==0

def auth_data(encoded):
 raw=base64.b64decode(encoded,validate=True)
 if not raw or raw[0]>>5!=2:raise Closed('invalid authenticator data')
 n=raw[0]&31
 if n<24:size,start=n,1
 elif n in (24,25,26):width={24:1,25:2,26:4}[n];size,start=int.from_bytes(raw[1:1+width],'big'),1+width
 else:raise Closed('invalid authenticator encoding')
 if len(raw)!=start+size or size<37:raise Closed('invalid authenticator length')
 return raw[start:]

def authorize(manifest,profile,folder):
 c=config();current=profile_keys()
 if profile not in PROFILES or any(c['keys'].get(k)!=current.get(k) or not current.get(k) for k in ['enclave',profile]):raise Closed('owner key enrollment missing or changed')
 binding=digest(manifest);helper=Path(__file__).resolve().with_name('EnclaveAuthenticator')
 if not regular(helper):raise Closed('trusted Enclave helper unavailable')
 _,out=command([str(helper),'--challenge',binding[:32]],timeout=100)
 proof= json.loads(out)
 public=(HOME/'.ragnarok/hardware/laptop/public.pem').read_text()
 if not proof.get('ok') or proof.get('challenge')!=binding[:32] or not openssl_verify(public,base64.b64decode(proof['signature'],validate=True),('ragnarok-chain:v1:'+binding[:32]).encode()):raise Closed('fresh Enclave proof invalid')
 keydir=HOME/'.alexus/keys'/profile
 rp=(keydir/'rp_id.txt').read_text().strip();credential=(keydir/'credential_id.txt').read_text().strip()
 if any('\n' in s or '\0' in s for s in [rp,credential]) or not rp or not credential:raise Closed('invalid enrolled profile')
 _,devices=command(['/opt/homebrew/bin/fido2-token','-L'])
 entries=[line.split(': ',1)[0] for line in devices.decode().splitlines() if ': ' in line]
 # Match the owner-selected physical key class; do not fall back to a different profile.
 needle=r'yubi|0x1050' if profile=='yubikey-primary' else r'utrust|identiv'
 hint_path=keydir/'device_info.txt';hint=hint_path.read_text().strip().split(': ',1)[-1] if regular(hint_path) else ''
 selected=[line.split(': ',1)[0] for line in devices.decode().splitlines() if hint and line.split(': ',1)[-1]==hint]
 if not selected:selected=[line.split(': ',1)[0] for line in devices.decode().splitlines() if re.search(needle,line,re.I)]
 if not selected and len(entries)==1:selected=entries
 if len(selected)!=1:raise Closed('selected hardware key not uniquely connected')
 inp=(base64.b64encode(bytes.fromhex(binding)).decode()+'\n'+rp+'\n'+credential+'\n').encode()
 _,out=command(['/opt/homebrew/bin/fido2-assert','-G','-p','-t','pin=false',selected[0]],input=inp,timeout=100)
 lines=out.decode().splitlines()
 if len(lines)<4 or base64.b64decode(lines[0],validate=True)!=bytes.fromhex(binding) or lines[1]!=rp:raise Closed('FIDO challenge mismatch')
 raw=auth_data(lines[2]);external_public=(keydir/'pubkey.pem').read_text()
 if raw[:32]!=hashlib.sha256(rp.encode()).digest() or not raw[32]&1 or not openssl_verify(external_public,base64.b64decode(lines[3],validate=True),raw+bytes.fromhex(binding)):raise Closed('fresh external-key proof invalid')
 write(folder/'owner-proof.json',{'manifest':manifest,'enclave':proof,'external_profile':profile,'assertion':'\n'.join(lines[:4]),'enclave_public_sha256':current['enclave'],'external_public_sha256':current[profile]})
 return True

def deployment_fields(folder):
 target=config().get('ios_target');path=folder/'ios-artifact-files.json'
 if target and not path.exists():raise Closed('selected iOS artifact was not verified')
 if path.exists() and not target:raise Closed('iOS deployment target changed')
 return {'ios_artifact_sha256':digest(read(path)) if target else '', 'ios_target_sha256':digest(target) if target else ''}

def apply(rid,profile,remote=None):
 folder=repair_path(rid);s=read(folder/'state.json');candidate=folder/'candidate'
 if s['status']!='awaiting_owner':raise Closed('repair is not awaiting owner')
 baseline=read(folder/'baseline.json');after=read(folder/'candidate-files.json')
 changed=sorted(k for k in set(baseline)|set(after) if baseline.get(k)!=after.get(k))
 if not changed or changed!=s.get('changed_files') or not set(changed)<=ALLOWED or digest(after)!=s.get('candidate_sha256') or digest(baseline)!=s.get('source_sha256'):raise Closed('candidate manifest inconsistent')
 if read(folder/'checks.json').get('result')!='passed' or read(folder/'review.json').get('verdict')!='approve':raise Closed('verification or review missing')
 artifact=candidate/'build/Build/Products/Debug/ALEXUSMac.app'
 approval_epoch=epoch()
 def unchanged():
  if epoch()!=approval_epoch or (STATE/'revoked').exists() or files(SOURCE)!=baseline or files(candidate)!=after or files(artifact,artifact=True)!=read(folder/'artifact-files.json'):raise Closed('source, candidate, artifact or authorization epoch changed')
 unchanged()
 target=config().get('ios_target');deployment=deployment_fields(folder)
 ios_app=candidate/'build-device/Build/Products/Debug-iphoneos/ALEXUSiOS.app'
 if target and files(ios_app,artifact=True)!=read(folder/'ios-artifact-files.json'):raise Closed('iOS artifact changed')
 manifest={'schema':'alexus-repair:v1','repair_id':rid,'candidate_sha256':digest(after),'source_sha256':digest(baseline),'checks_sha256':s['checks_sha256'],'artifact_sha256':digest(read(folder/'artifact-files.json')),'nonce':secrets.token_hex(32),'expires_unix':int(time.time())+150,'action':'apply-source-and-install-selected-targets','authorization_epoch':approval_epoch,'receipt_head_sha256':receipt_head(),**deployment}
 if remote is not None:
  supplied=remote['manifest']
  for key in ['schema','repair_id','candidate_sha256','source_sha256','checks_sha256','artifact_sha256','action','authorization_epoch','ios_artifact_sha256','ios_target_sha256']:
   if supplied.get(key)!=manifest[key]:raise Closed('remote approval binding changed')
  if not isinstance(supplied.get('expires_unix'),int) or supplied['expires_unix']>time.time()+180:raise Closed('remote expiration invalid')
  manifest=supplied
 receipt('repair.approval_requested',rid)
 granted=remote_module().verify_remote(manifest,remote['proof'],folder) if remote is not None else authorize(manifest,profile,folder)
 if not granted or not receipt_prefix_valid(manifest.get('receipt_head_sha256')):raise Closed('dual hardware authorization or receipt binding not granted')
 if time.time()>=manifest['expires_unix']:raise Closed('approval expired')
 unchanged()
 if target and (files(ios_app,artifact=True)!=read(folder/'ios-artifact-files.json') or deployment_fields(folder)!=deployment):raise Closed('iOS artifact or deployment target changed')
 # Authorization is consumed before the first mutation. A retry requires another pair of signatures.
 set_state(folder,'applying','Fresh owner proofs consumed.');receipt('repair.owner_authorized',rid)
 _,identities=command(['security','find-identity','-v','-p','codesigning'])
 matches=re.findall(r'"(Apple Development:[^"]+)"',identities.decode())
 if len(matches)!=1:raise Closed('unambiguous development signing identity required')
 command(['codesign','--force','--sign',matches[0],str(artifact/'Contents/Resources/EnclaveAuthenticator')])
 command(['codesign','--force','--sign',matches[0],str(artifact)])
 command(['codesign','--verify','--strict',str(artifact)])
 if (STATE/'revoked').exists() or time.time()>=manifest['expires_unix']:raise Closed('approval revoked or expired')
 backup=folder/'source-before';backup.mkdir(mode=0o700)
 for rel in s['changed_files']:
  dest=backup/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(SOURCE/rel,dest)
 destination=HOME/'Applications/ALEXUS.app';pending=HOME/'Applications'/('ALEXUS.pending-'+rid+'.app')
 shutil.copytree(artifact,pending)
 previous=HOME/'Applications'/('ALEXUS.previous-'+rid+'.app')
 if (STATE/'revoked').exists() or time.time()>=manifest['expires_unix']:
  shutil.rmtree(pending);raise Closed('approval revoked or expired')
 try:
  for rel in s['changed_files']:
   if rel not in ALLOWED:raise Closed('change outside repair policy')
   data=(candidate/rel).read_bytes();fd,tmp=tempfile.mkstemp(dir=(SOURCE/rel).parent)
   with os.fdopen(fd,'wb') as f:f.write(data)
   os.replace(tmp,SOURCE/rel)
  if destination.exists():os.rename(destination,previous)
  os.rename(pending,destination)
  if target:
   command(['xcrun','devicectl','device','install','app','--device',target['device_id'],'--timeout','60',str(ios_app)],timeout=70)
   receipt('repair.ios_installed',rid)
 except BaseException:
  for rel in s['changed_files']:shutil.copy2(backup/rel,SOURCE/rel)
  if destination.exists():os.rename(destination,HOME/'Applications'/('ALEXUS.held-'+rid+'.app'))
  if previous.exists():os.rename(previous,destination)
  if target:set_state(folder,'needs_owner','Mac transaction restored. iOS deployment outcome is Unverified; inspect the device before another attempt.',deployment_uncertain=True)
  raise
 # Commit only this app's changed files; unrelated staged work is excluded.
 paths=[str(SOURCE/rel) for rel in s['changed_files']]
 commit_code,_=command(['git','-c','core.hooksPath=/dev/null','-c','core.fsmonitor=false','-c','user.name=ALEXUS owner-approved','-c','user.email=owner-approved@invalid','commit','--only','-m','Apply hardware-authorized ALEXUS repair '+rid,'--',*paths],SOURCE,check=False)
 set_state(folder,'applied','Owner-authorized source and signed Mac build installed. Relaunch to use it; runtime Unverified.'+(' Source commit needs owner attention.' if commit_code else ''))
 receipt('repair.applied',rid)
 if target:
  code,_=command(['xcrun','devicectl','device','process','launch','--device',target['device_id'],target['bundle_id']],timeout=30,check=False)
  receipt('repair.ios_launched' if code==0 else 'repair.ios_launch_unverified',rid)
 return {'message':'Repair applied after both fresh hardware proofs. Previous app retained; relaunch ALEXUS to use the new build.'}

def watch():
 config()
 if (STATE/'revoked').exists():return {'message':'Watcher paused by force stop.'}
 seen_path=STATE/'crash-seen.json';seen=read(seen_path) if seen_path.exists() else {'after':time.time()}
 reports=HOME/'Library/Logs/DiagnosticReports'
 fresh=[p for p in reports.glob('ALEXUS*.ips') if p.stat().st_mtime>seen['after']]
 if fresh:
  queue('Investigate an observed ALEXUS crash. No unsanitized crash report has been supplied. Inspect the app source and existing checks; if the cause cannot be established, do not invent it. Stage only a justified change.',kind='crash-observed')
 write(seen_path,{'after':time.time()})
 pending=[p for p in sorted((STATE/'repairs').glob('*/state.json')) if read(p).get('status')=='queued']
 if pending:
  rid=read(pending[0])['id']
  try:return stage(rid)
  except Exception:
   set_state(repair_path(rid),'needs_owner','Staging did not pass. Runtime cause remains Unverified; no application authorized.')
   receipt('repair.held',rid)
 return {'message':'Stage-only watcher checked the bounded queue.'}

def main(request):
 cmd=request.get('command','status')
 if cmd in {'deployments_list','deployment_get','deployment_start','deployment_stop','deployment_resume'}:
  import importlib.util
  spec=importlib.util.spec_from_file_location('alexus_deployments',Path(__file__).with_name('deployment_host.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
  return module.dispatch(request,sys.modules[__name__])
 if cmd in {'chat_models','chat_list','chat_get','chat_send','chat_stop'}:
  return chat_module().dispatch(request,sys.modules[__name__])
 if cmd=='stop':
  write(STATE/'revoked',{'at':now()});write(STATE/'epoch.json',{'value':secrets.token_hex(32)})
  try:receipt('owner.stop_requested')
  except Exception:pass
  return {'message':'Stopped and revoked pending work. Completed changes cannot be recalled.'}
 with (STATE/'host.lock').open('a') as lock:
  try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  except BlockingIOError:
   if cmd=='status':return status()
   raise Closed('another repair operation is active')
  if cmd=='status':return status()
  if cmd in {'pairing_start','pairing_list','pairing_approve','pairing_revoke'}:return remote_module().dispatch(request,sys.modules[__name__])
  if cmd=='watch':return watch()
  if cmd=='report_error':
   code=request.get('code','unknown')
   if code not in {'catalog-unavailable','host-unavailable','catalog-invalid','ui-invariant'}:code='unknown'
   receipt('app.error.'+code)
   if code=='ui-invariant':queue('Investigate a reported UI invariant failure. The cause is Unverified; do not invent one.',kind='app-error')
   return {'message':'Scrubbed error code recorded; raw error and request data excluded.'}
  if cmd=='queue':
   if (STATE/'revoked').exists():(STATE/'revoked').unlink()
   return queue(request.get('instruction',''),provider=request.get('provider','codex'),selected_model=request.get('model',''))
  rid=request.get('id','');folder=repair_path(rid)
  if cmd=='diff':return {'message':'Inspect the staged diff.','diff':(folder/'candidate.diff').read_text()[:100000]}
  if cmd in ['stage','apply','remote_apply']:
   try:
    if cmd=='stage':return stage(rid)
    if cmd=='remote_apply':return apply(rid,'',remote={'manifest':request['remote_manifest'],'proof':request['remote_proof']})
    return apply(rid,request.get('profile',''))
   except BaseException:
    if read(folder/'state.json').get('deployment_uncertain'):pass
    elif cmd in {'apply','remote_apply'} and read(folder/'state.json')['status']=='awaiting_owner':
     set_state(folder,'awaiting_owner','Approval attempt held or revoked. A new challenge and both fresh proofs are required.')
    else:set_state(folder,'needs_owner','Operation did not pass or was revoked. No success was inferred. Inspect locally; a new candidate needs fresh authorization.')
    receipt('repair.held',rid);raise
  raise Closed('unknown command')
if __name__=='__main__':
 os.umask(0o077);STATE.mkdir(parents=True,exist_ok=True,mode=0o700)
 try:
  raw=sys.stdin.buffer.read(20000);request=json.loads(raw or '{}');result=main(request);print(json.dumps(result))
 except Exception:
  print(json.dumps({'message':'Operation held. No authorization was inferred.','error':'held'}));sys.exit(1)
