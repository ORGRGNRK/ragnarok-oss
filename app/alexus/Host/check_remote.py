#!/usr/bin/env python3
"""Ephemeral software-key protocol fixtures. Does not claim hardware enrollment or touch real keys."""
import base64,hashlib,importlib.util,json,secrets,sys,tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch

def load(name,file):
 spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(file));module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module);return module
H=load('remote_fixture_host','alexus_host.py');R=load('remote_fixture','remote_host.py');R.H=H

def cbor(value):
 def head(major,n):
  if n<24:return bytes([(major<<5)|n])
  if n<256:return bytes([(major<<5)|24,n])
  return bytes([(major<<5)|25])+n.to_bytes(2,'big')
 if isinstance(value,int):return head(0,value) if value>=0 else head(1,-1-value)
 if isinstance(value,bytes):return head(2,len(value))+value
 if isinstance(value,str):raw=value.encode();return head(3,len(raw))+raw
 if isinstance(value,dict):return head(5,len(value))+b''.join(cbor(k)+cbor(v) for k,v in value.items())
 raise ValueError('fixture value')

class RemoteChecks(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.state=self.root/'state';self.state.mkdir();self.home=self.root/'home';self.home.mkdir();self.source=self.root/'source';self.source.mkdir();(self.source/'check.sh').write_text('exit 0')
  self.patches=[patch.object(H,'STATE',self.state),patch.object(H,'HOME',self.home),patch.object(H,'SOURCE',self.source),patch.object(R,'server_config',return_value={'certificate_sha256':'a'*64})]
  for p in self.patches:p.start()
  self.keys={}
  for name in ['phone','external']:
   private=self.root/(name+'.key');public=self.root/(name+'.pem')
   H.command(['/usr/bin/openssl','ecparam','-name','prime256v1','-genkey','-noout','-out',str(private)])
   H.command(['/usr/bin/openssl','pkey','-in',str(private),'-pubout','-out',str(public)])
   _,der=H.command(['/usr/bin/openssl','pkey','-pubin','-in',str(public),'-outform','DER'])
   self.keys[name]=(private,public.read_text(),der)
  self.bootstrap='fixture-bootstrap';self.device_token='fixture-device-token';self.challenge=secrets.token_bytes(32);self.credential=secrets.token_bytes(16)
  H.write(R.area()/'bootstrap.json',{'token_sha256':hashlib.sha256(self.bootstrap.encode()).hexdigest(),'expires_unix':int(time.time())+300,'challenge':R.b64(self.challenge)})
 def tearDown(self):
  for p in reversed(self.patches):p.stop()
  self.tmp.cleanup()
 def client(self,challenge,kind='webauthn.get',origin=None):return json.dumps({'type':kind,'challenge':base64.urlsafe_b64encode(challenge).decode().rstrip('='),'origin':origin or 'https://'+R.RP,'crossOrigin':False},separators=(',',':')).encode()
 def sign(self,name,message):
  source=self.root/'message';signature=self.root/'signature';source.write_bytes(message)
  H.command(['/usr/bin/openssl','dgst','-sha256','-sign',str(self.keys[name][0]),'-out',str(signature),str(source)])
  return R.b64(signature.read_bytes())
 def assertion(self,challenge,origin=None):
  client=self.client(challenge,origin=origin);auth=hashlib.sha256(R.RP.encode()).digest()+b'\x01'+b'\x00'*4
  return {'client_data':R.b64(client),'authenticator_data':R.b64(auth),'credential_id':R.b64(self.credential),'signature':self.sign('external',auth+hashlib.sha256(client).digest())}
 def prepare(self):
  point=self.keys['external'][2][-65:];key={1:2,3:-7,-1:1,-2:point[1:33],-3:point[33:]}
  auth=hashlib.sha256(R.RP.encode()).digest()+b'\x41'+b'\x00'*4+b'\x00'*16+len(self.credential).to_bytes(2,'big')+self.credential+cbor(key)
  request={'client_data':R.b64(self.client(self.challenge,'webauthn.create')),'attestation':R.b64(cbor({'fmt':'none','attStmt':{},'authData':auth})),'device_public_der':R.b64(self.keys['phone'][2]),'device_token_sha256':hashlib.sha256(self.device_token.encode()).hexdigest()}
  return R.pair_prepare(request,self.bootstrap)
 def submit(self):
  p=self.prepare();message=base64.b64decode(p['message_b64']);challenge=base64.b64decode(p['challenge_b64'])
  R.pair_submit({'id':p['id'],'enclave_signature':self.sign('phone',message),'external':self.assertion(challenge)},self.bootstrap)
  return p
 def approved(self):
  p=self.submit()
  with patch.object(H,'authorize',return_value=True):R.pair_approve(p['id'],'yubikey-primary')
  return H.read(R.device_path(p['id']))
 def remote_manifest(self,device):
  rid='b'*24;folder=H.repair_path(rid);folder.mkdir(parents=True)
  m={'schema':'alexus-repair:v1','repair_id':rid,'owner_device_id':device['id'],'nonce':secrets.token_hex(32),'expires_unix':int(time.time())+150,'authorization_epoch':H.epoch(),'receipt_head_sha256':H.receipt_head()}
  H.write(folder/'remote-pending.json',{'manifest':m,'status':'pending'})
  proof={'enclave_signature':self.sign('phone',H.canonical(m)),'external':self.assertion(bytes.fromhex(H.digest(m)))}
  return folder,m,proof
 def test_two_phone_proofs_still_need_existing_owner(self):
  p=self.submit();self.assertEqual(H.read(R.device_path(p['id']))['status'],'pending')
  with self.assertRaises(H.Closed):R.device(self.device_token)
  with patch.object(H,'authorize',return_value=False):
   with self.assertRaises(H.Closed):R.pair_approve(p['id'],'yubikey-primary')
  self.assertEqual(H.read(R.device_path(p['id']))['status'],'pending')
 def test_owner_approval_enables_paired_device(self):
  d=self.approved();self.assertEqual(R.device(self.device_token)['id'],d['id'])
 def test_expired_link_rejected(self):
  boot=H.read(R.area()/'bootstrap.json');boot['expires_unix']=0;H.write(R.area()/'bootstrap.json',boot)
  with self.assertRaises(H.Closed):self.prepare()
 def test_wrong_bootstrap_token_rejected(self):
  with self.assertRaises(H.Closed):R.bootstrap('wrong')
 def test_wrong_webauthn_origin_rejected(self):
  d=self.approved();challenge=secrets.token_bytes(32)
  with self.assertRaises(H.Closed):R.assertion(self.assertion(challenge,origin='https://wrong.invalid'),d['external_key'],challenge)
 def test_fresh_dual_proof_consumed_once(self):
  d=self.approved();folder,m,proof=self.remote_manifest(d)
  self.assertTrue(R.verify_remote(m,proof,folder));self.assertFalse(R.verify_remote(m,proof,folder))
 def test_only_phone_signature_is_not_enough(self):
  d=self.approved();folder,m,proof=self.remote_manifest(d);proof['external']['signature']=R.b64(b'invalid')
  self.assertFalse(R.verify_remote(m,proof,folder));self.assertEqual(H.read(folder/'remote-pending.json')['status'],'pending')
 def test_stop_invalidates_old_proof_after_resume(self):
  d=self.approved();folder,m,proof=self.remote_manifest(d);H.main({'command':'stop'});(self.state/'revoked').unlink()
  self.assertFalse(R.verify_remote(m,proof,folder))
 def test_device_revocation_blocks_valid_proof(self):
  d=self.approved();folder,m,proof=self.remote_manifest(d);d['status']='revoked';H.write(R.device_path(d['id']),d)
  self.assertFalse(R.verify_remote(m,proof,folder))
 def test_changed_manifest_rejected(self):
  d=self.approved();folder,m,proof=self.remote_manifest(d);m['nonce']='changed';self.assertFalse(R.verify_remote(m,proof,folder))
 def test_expired_repair_proof_rejected(self):
  d=self.approved();folder,m,proof=self.remote_manifest(d);m['expires_unix']=0;H.write(folder/'remote-pending.json',{'manifest':m,'status':'pending'});self.assertFalse(R.verify_remote(m,proof,folder))
 def test_cbor_bounds_and_duplicate_keys(self):
  for raw in [b'\x9f',b'\xa2\x01\x01\x01\x02',b'\x59\xff\xff']:
   with self.assertRaises(H.Closed):R.cbor(raw)
if __name__=='__main__':unittest.main(verbosity=2)
