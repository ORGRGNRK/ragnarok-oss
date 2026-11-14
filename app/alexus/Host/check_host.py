#!/usr/bin/env python3
"""Private scratch fixtures only. No real hardware touches, agents, source updates or installs."""
import base64,hashlib,importlib.util,json,os,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('host',Path(__file__).with_name('alexus_host.py'));host=importlib.util.module_from_spec(spec);sys.modules[spec.name]=host;spec.loader.exec_module(host)
class HostChecks(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.home=self.root/'home';self.home.mkdir();(self.home/'Applications').mkdir()
  self.source=self.root/'source';(self.source/'Sources').mkdir(parents=True);(self.source/'Sources/Views.swift').write_text('before');(self.source/'Sources/Models.swift').write_text('model');(self.source/'check.sh').write_text('exit 0')
  self.state=self.root/'state';self.state.mkdir()
  self.patches=[patch.object(host,'HOME',self.home),patch.object(host,'SOURCE',self.source),patch.object(host,'STATE',self.state)]
  for p in self.patches:p.start()
 def tearDown(self):
  for p in reversed(self.patches):p.stop()
  self.tmp.cleanup()
 def fixture(self):
  rid='a'*24;folder=host.repair_path(rid);folder.mkdir(parents=True);candidate=folder/'candidate';host.copy_source(self.source,candidate)
  before=host.files(self.source);(candidate/'Sources/Views.swift').write_text('after');after=host.files(candidate)
  artifact=candidate/'build/Build/Products/Debug/ALEXUSMac.app';(artifact/'Contents/Resources').mkdir(parents=True);(artifact/'Contents/Resources/EnclaveAuthenticator').write_text('fixture');(artifact/'Contents/executable').write_text('fixture only')
  host.write(folder/'baseline.json',before);host.write(folder/'candidate-files.json',after);host.write(folder/'artifact-files.json',host.files(artifact));host.write(folder/'checks.json',{'result':'passed'});host.write(folder/'review.json',{'verdict':'approve'})
  host.write(folder/'state.json',{'id':rid,'created':host.now(),'status':'awaiting_owner','note':'fixture only','changed_files':['Sources/Views.swift'],'candidate_sha256':host.digest(after),'source_sha256':host.digest(before),'checks_sha256':'fixture'})
  return rid,folder,candidate
 def fake_command(self,args,*a,**kw):
  return (0,b'1) ABC "Apple Development: Fixture"\n') if args[:2]==['security','find-identity'] else (0,b'')
 def test_heimdall_observation_is_scoped_and_excludes_private_content(self):
  import subprocess
  project=self.source.parent/'heimdall';project.mkdir()
  subprocess.run(['git','init','-q',str(project)],check=True)
  (project/'tracked').write_text('original')
  subprocess.run(['git','-C',str(project),'add','.'],check=True)
  subprocess.run(['git','-C',str(project),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture'],check=True)
  (project/'private-secret-filename').write_text('private-secret-content')
  log=self.home/'.ragnarok/ragnarok-app-errors.jsonl';log.parent.mkdir();log.write_text('private-secret-log')
  (self.home/'Applications/Ragnarok.app').mkdir()
  result=host.heimdall_status()
  self.assertEqual(result['changed_entries'],1);self.assertRegex(result['revision'],r'^[0-9a-f]{40}$')
  self.assertTrue(result['app_present']);self.assertTrue(result['error_log_present'])
  self.assertNotIn('private-secret',json.dumps(result));self.assertEqual(result['runtime'],'Unverified')
 def test_missing_heimdall_keeps_git_state_unverified(self):
  result=host.heimdall_status()
  self.assertEqual(result['revision'],'Unverified');self.assertIsNone(result['changed_entries'])
  self.assertFalse(result['error_log_present'])
 def test_no_hardware_proof_no_source_change(self):
  rid,_,_=self.fixture()
  with patch.object(host,'authorize',side_effect=host.Closed('no hardware')):
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
  self.assertEqual((self.source/'Sources/Views.swift').read_text(),'before')
  self.assertFalse((self.home/'Applications/ALEXUS.app').exists())
 def test_false_authorization_fails_closed(self):
  rid,_,_=self.fixture()
  with patch.object(host,'authorize',return_value=False):
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
  self.assertEqual((self.source/'Sources/Views.swift').read_text(),'before')
 def test_expired_approval_rejected(self):
  rid,_,_=self.fixture()
  with patch.object(host,'authorize',return_value=True),patch.object(host.time,'time',side_effect=[1000,1200]):
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
  self.assertEqual((self.source/'Sources/Views.swift').read_text(),'before')
 def test_changed_source_rejects_before_authorization(self):
  rid,_,_=self.fixture();(self.source/'Sources/Views.swift').write_text('owner edit')
  with patch.object(host,'authorize') as auth:
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
   auth.assert_not_called()
  self.assertEqual((self.source/'Sources/Views.swift').read_text(),'owner edit')
 def test_candidate_swap_rejected(self):
  rid,_,candidate=self.fixture();(candidate/'Sources/Views.swift').write_text('swapped')
  with patch.object(host,'authorize') as auth:
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
   auth.assert_not_called()
 def test_revocation_blocks_apply(self):
  rid,_,_=self.fixture();host.write(self.state/'revoked',{'at':host.now()})
  with patch.object(host,'authorize') as auth:
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
   auth.assert_not_called()
 def test_revocation_after_auth_blocks_apply(self):
  rid,_,_=self.fixture()
  def revoked(*a):host.write(self.state/'revoked',{'at':host.now()})
  with patch.object(host,'authorize',side_effect=revoked):
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
  self.assertEqual((self.source/'Sources/Views.swift').read_text(),'before')
 def test_approval_consumed_and_cannot_replay(self):
  rid,folder,_=self.fixture()
  with patch.object(host,'authorize',return_value=True) as auth,patch.object(host,'command',side_effect=self.fake_command):
   host.apply(rid,'yubikey-primary');self.assertEqual(auth.call_count,1)
   self.assertEqual((self.source/'Sources/Views.swift').read_text(),'after')
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
   self.assertEqual(auth.call_count,1)
  self.assertTrue((self.home/'Applications/ALEXUS.app').exists())
  self.assertEqual(host.read(folder/'state.json')['status'],'applied')
 def test_hidden_artifact_payload_rejected(self):
  rid,folder,candidate=self.fixture();artifact=candidate/'build/Build/Products/Debug/ALEXUSMac.app'
  (artifact/'Contents/Resources/__pycache__').mkdir();(artifact/'Contents/Resources/__pycache__/unexpected.pyc').write_text('fixture payload')
  with patch.object(host,'authorize') as auth:
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
   auth.assert_not_called()
 def test_tampered_file_list_rejected(self):
  rid,folder,_=self.fixture();s=host.read(folder/'state.json');s['changed_files'].append('Host/alexus_host.py');host.write(folder/'state.json',s)
  with patch.object(host,'authorize') as auth:
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
   auth.assert_not_called()
 def test_missing_review_rejected(self):
  rid,folder,_=self.fixture();host.write(folder/'review.json',{'verdict':'reject'})
  with patch.object(host,'authorize') as auth:
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
   auth.assert_not_called()
 def test_symlink_source_rejected(self):
  (self.source/'Sources/sneaky').symlink_to(self.home)
  with self.assertRaises(host.Closed):host.files(self.source)
 def test_receipt_tamper_detected(self):
  host.receipt('fixture.one');host.receipt('fixture.two');rows=host.read(self.state/'receipts.json');self.assertTrue(host.valid_receipts(rows));rows[0]['action']='changed';self.assertFalse(host.valid_receipts(rows))
 def test_model_caches_and_git_metadata_are_not_promoted(self):
  rid='c'*24;folder=host.repair_path(rid);folder.mkdir(parents=True)
  host.write(folder/'request.json',{'instruction':'fixture UI change'})
  host.write(folder/'state.json',{'id':rid,'created':host.now(),'status':'queued','note':'fixture'})
  def fake_model(args,cwd,prompt,timeout=1200,**route):
   if 'workspace-write' in args:
    (cwd/'Sources/Views.swift').write_text('after')
    (cwd/'.git').mkdir(exist_ok=True);(cwd/'.git/config').write_text('malicious fixture config')
    (cwd/'Host/__pycache__').mkdir(parents=True);(cwd/'Host/__pycache__/evil.pyc').write_text('not executable fixture')
    (cwd/'build').mkdir();(cwd/'build/evil').write_text('untrusted cache')
   else:
    self.assertFalse((cwd/'Host/__pycache__/evil.pyc').exists())
    self.assertFalse((cwd/'build/evil').exists())
    host.write(Path(args[args.index('--output-last-message')+1]),{'verdict':'approve','reason':'fixture only'})
   return b''
  def fake_command(args,cwd=None,*a,**kw):
   if args[0]=='git' and cwd and (cwd/'.git/config').exists() and 'malicious' in (cwd/'.git/config').read_text():raise AssertionError('host executed Git in untrusted workspace')
   if args[0]=='/bin/zsh':
    artifact=cwd/'build/Build/Products/Debug/ALEXUSMac.app/Contents/Resources';artifact.mkdir(parents=True);(artifact/'fixture').write_text('fixture build')
   if args[0]=='xcrun':Path(args[args.index('-o')+1]).write_text('fixture helper')
   return 0,b'' if args[0]=='git' else b'fixture check output'
  with patch.object(host,'model',side_effect=fake_model),patch.object(host,'command',side_effect=fake_command):host.stage(rid)
  self.assertEqual((self.source/'Sources/Views.swift').read_text(),'before')
  self.assertEqual(host.read(folder/'state.json')['status'],'awaiting_owner')
  self.assertFalse((folder/'candidate/Host/__pycache__/evil.pyc').exists())
 def ios_fixture(self):
  rid,folder,candidate=self.fixture();cfg=host.config()
  cfg['ios_target']={'device_id':'fixture-device','udid':'fixture-udid','bundle_id':'co.rgnrk.alexus.ios','team_id':'FIXTURE'};host.write(self.state/'config.json',cfg)
  app=candidate/'build-device/Build/Products/Debug-iphoneos/ALEXUSiOS.app';app.mkdir(parents=True);(app/'binary').write_text('fixture iOS binary')
  host.write(folder/'ios-artifact-files.json',host.files(app));return rid,folder,candidate,app
 def test_selected_ios_artifact_required_before_authorization(self):
  rid,folder,_,_=self.ios_fixture();(folder/'ios-artifact-files.json').unlink()
  with patch.object(host,'authorize') as auth:
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
   auth.assert_not_called()
 def test_ios_artifact_swap_after_authorization_rejected(self):
  rid,_,_,app=self.ios_fixture()
  def swapped(*a):(app/'binary').write_text('swapped');return True
  with patch.object(host,'authorize',side_effect=swapped):
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
  self.assertEqual((self.source/'Sources/Views.swift').read_text(),'before')
 def test_ios_install_failure_restores_mac_and_source(self):
  rid,_,_,_=self.ios_fixture();old=self.home/'Applications/ALEXUS.app';old.mkdir();(old/'old-marker').write_text('previous')
  def failed(args,*a,**kw):
   if args[:5]==['xcrun','devicectl','device','install','app']:raise host.Closed('fixture install failure')
   return self.fake_command(args,*a,**kw)
  with patch.object(host,'authorize',return_value=True),patch.object(host,'command',side_effect=failed):
   with self.assertRaises(host.Closed):host.apply(rid,'yubikey-primary')
  self.assertEqual((self.source/'Sources/Views.swift').read_text(),'before');self.assertTrue((old/'old-marker').exists())
 def test_dual_authorization_binds_both_artifacts_and_target(self):
  rid,folder,_,_=self.ios_fixture();observed=[]
  def owner(manifest,*a):observed.append(manifest);return True
  with patch.object(host,'authorize',side_effect=owner),patch.object(host,'command',side_effect=self.fake_command):host.apply(rid,'yubikey-primary')
  self.assertEqual(observed[0]['ios_artifact_sha256'],host.digest(host.read(folder/'ios-artifact-files.json')))
  self.assertEqual(observed[0]['ios_target_sha256'],host.digest(host.config()['ios_target']))
 def test_real_p256_signature_rejects_changed_challenge(self):
  key=self.root/'key.pem';pub=self.root/'public.pem';message=self.root/'message';signature=self.root/'signature'
  message.write_bytes(b'fixture challenge')
  host.command(['/usr/bin/openssl','ecparam','-name','prime256v1','-genkey','-noout','-out',str(key)])
  host.command(['/usr/bin/openssl','pkey','-in',str(key),'-pubout','-out',str(pub)])
  host.command(['/usr/bin/openssl','dgst','-sha256','-sign',str(key),'-out',str(signature),str(message)])
  self.assertTrue(host.openssl_verify(pub.read_text(),signature.read_bytes(),b'fixture challenge'))
  self.assertFalse(host.openssl_verify(pub.read_text(),signature.read_bytes(),b'changed challenge'))
 def test_enclave_alone_cannot_authorize(self):
  manifest={'nonce':'fixture'};binding=host.digest(manifest)
  laptop=self.home/'.ragnarok/hardware/laptop';laptop.mkdir(parents=True);(laptop/'public.pem').write_text('fixture public')
  profile=self.home/'.alexus/keys/yubikey-primary';profile.mkdir(parents=True)
  for name,text in [('pubkey.pem','fixture public'),('rp_id.txt','alexus-core'),('credential_id.txt','fixture')]: (profile/name).write_text(text)
  raw=hashlib.sha256(b'alexus-core').digest()+b'\x01'+b'\x00'*4
  auth=base64.b64encode(b'\x58\x25'+raw).decode()
  assertion='\n'.join([base64.b64encode(bytes.fromhex(binding)).decode(),'alexus-core',auth,base64.b64encode(b'fake').decode()])
  def output(args,*a,**kw):
   if args[0].endswith('EnclaveAuthenticator'):return 0,json.dumps({'ok':True,'challenge':binding[:32],'signature':base64.b64encode(b'fake').decode()}).encode()
   if args[0].endswith('fido2-token'):return 0,b'/dev/fixture: Yubico fixture\n'
   return 0,assertion.encode()
  original_regular=host.regular
  with patch.object(host,'command',side_effect=output),patch.object(host,'regular',side_effect=lambda p: True if p.name=='EnclaveAuthenticator' else original_regular(p)),patch.object(host,'openssl_verify',side_effect=[True,False]):
   with self.assertRaises(host.Closed):host.authorize(manifest,'yubikey-primary',self.state)
  self.assertFalse((self.state/'owner-proof.json').exists())
 def test_bad_profile_fails_closed(self):
  with self.assertRaises(host.Closed):host.authorize({'nonce':'fixture'},'unknown',self.state)
 def test_bad_authenticator_data_rejected(self):
  for data in ['','AA==','AAAA']:
   with self.assertRaises((host.Closed,ValueError)):host.auth_data(data)
if __name__=='__main__':unittest.main(verbosity=2)
