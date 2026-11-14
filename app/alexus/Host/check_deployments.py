#!/usr/bin/env python3
"""Scratch deployment checkpoints, ordering, revocation and private API boundaries."""
import importlib.util,json,pathlib,sys,tempfile,unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).parent
def load(name,file):
 spec=importlib.util.spec_from_file_location(name,ROOT/file);m=importlib.util.module_from_spec(spec);sys.modules[name]=m;spec.loader.exec_module(m);return m
H=load('deployment_fixture_host','alexus_host.py');D=load('deployment_fixture','deployment_host.py');C=load('deployment_fixture_chat','chat_host.py');D.H=H;C.H=H
class Checks(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name);self.state=self.root/'state';self.state.mkdir();self.source=self.root/'alexus';self.source.mkdir();self.project=self.root/'heimdall';self.project.mkdir();(self.source/'check.sh').write_text('exit 0')
  self.patches=[patch.object(H,'STATE',self.state),patch.object(H,'SOURCE',self.source),patch.object(D,'chat',return_value=C),patch.object(C,'scrub',side_effect=str),patch.object(C,'models',return_value=['fixture'])]
  for p in self.patches:p.start()
 def tearDown(self):
  for p in reversed(self.patches):p.stop()
  self.tmp.cleanup()
 def start(self,steps='First step\nSecond step',**extra):
  with patch.object(D.subprocess,'Popen'):
   return D.dispatch({'command':'deployment_start','kind':'inspect','project':'heimdall','provider':'alexus','model':'fixture','steps':steps,**extra},H)
 def fake_run(self,cid):
  d=H.read(C.path(cid));d['actions'].append({'tool':'shell','result':'observed','output_sha256':'fixture'});d.update(status='done');H.write(C.path(cid),d)
 def test_success_is_sequential_with_new_evidence_each_step(self):
  d=self.start();calls=[]
  def run(cid):calls.append(len(H.read(C.path(cid))['messages']));self.fake_run(cid)
  with patch.object(C,'run',side_effect=run):D.run(d['id'])
  result=H.read(D.path(d['id']));self.assertEqual(calls,[1,1]);self.assertEqual(result['status'],'done');self.assertEqual([s['status'] for s in result['steps']],['evidence collected']*2)
  self.assertEqual([s['observations'] for s in result['steps']],[1,1]);self.assertFalse((self.state/'repairs').exists())
 def test_model_claim_without_host_evidence_stops_later_step(self):
  d=self.start()
  def claimed(cid):data=H.read(C.path(cid));data.update(status='done');H.write(C.path(cid),data)
  with patch.object(C,'run',side_effect=claimed) as run:D.run(d['id']);self.assertEqual(run.call_count,1)
  result=H.read(D.path(d['id']));self.assertEqual(result['status'],'held');self.assertEqual(result['steps'][1]['status'],'pending')
 def test_failure_prevents_next_step(self):
  d=self.start()
  with patch.object(C,'run',side_effect=RuntimeError('fixture')) as run:D.run(d['id']);self.assertEqual(run.call_count,1)
  self.assertEqual(H.read(D.path(d['id']))['status'],'held')
 def test_revocation_between_steps_prevents_next_release(self):
  d=self.start()
  def revoked(cid):self.fake_run(cid);H.write(self.state/'epoch.json',{'value':'revoked'})
  with patch.object(C,'run',side_effect=revoked) as run:D.run(d['id']);self.assertEqual(run.call_count,1)
  self.assertEqual(H.read(D.path(d['id']))['status'],'held')
 def test_stop_before_worker_prevents_any_model_call(self):
  d=self.start();D.dispatch({'command':'deployment_stop','id':d['id']},H)
  with patch.object(C,'run') as run:D.run(d['id']);run.assert_not_called()
 def test_changed_spec_held(self):
  d=self.start();d['spec']['steps']=['changed'];H.write(D.path(d['id']),d)
  with patch.object(C,'run') as run:
   with self.assertRaises(H.Closed):D.run(d['id'])
   run.assert_not_called()
 def test_checkpoints_do_not_reexecute_completed_steps(self):
  d=self.start()
  with patch.object(C,'run',side_effect=self.fake_run):D.run(d['id'])
  with patch.object(C,'run') as run:D.run(d['id']);run.assert_not_called()
 def test_duplicate_active_deployment_rejected(self):
  self.start()
  with self.assertRaises(H.Closed):self.start()
 def test_resume_is_bounded_and_does_not_repeat_verified_steps(self):
  d=self.start();calls=[]
  def first(cid):
   calls.append(cid)
   if len(calls)==1:self.fake_run(cid)
   else:raise RuntimeError('transient fixture')
  with patch.object(C,'run',side_effect=first):D.run(d['id'])
  self.assertEqual(H.read(D.path(d['id']))['steps'][0]['status'],'evidence collected')
  with patch.object(D.subprocess,'Popen'):D.dispatch({'command':'deployment_resume','id':d['id']},H)
  with patch.object(C,'run',side_effect=self.fake_run) as run:D.run(d['id']);self.assertEqual(run.call_count,1)
  self.assertEqual(H.read(D.path(d['id']))['status'],'done')
 def test_explicit_stop_cannot_be_resumed(self):
  d=self.start();D.dispatch({'command':'deployment_stop','id':d['id']},H)
  with self.assertRaises(H.Closed):D.dispatch({'command':'deployment_resume','id':d['id']},H)
 def test_unknown_project_and_live_heimdall_repair_denied(self):
  for obj in [{'project':'other'},{'project':'heimdall','kind':'repair'}]:
   with self.assertRaises(H.Closed):self.start(**obj)
 def test_repair_dispatches_existing_frozen_pipeline(self):
  with patch.object(H,'main',return_value={'id':'c'*24}) as main:
   H.write(H.repair_path('c'*24)/'state.json',{'status':'queued'})
   result=self.start(kind='repair',project='alexus')
   self.assertEqual(result['repair_id'],'c'*24);self.assertEqual(main.call_args.args[0]['command'],'queue');self.assertEqual([s['title'] for s in result['steps']],['implement','verify','review'])
 def test_unpaired_and_pending_devices_cannot_deploy(self):
  R=load('deploy_remote_fixture','remote_host.py');R.H=H
  with self.assertRaises(H.Closed):R.api('/v1/deployments','POST','invalid',{'command':'deployment_start'})
  import hashlib
  for status in ['pending','revoked']:
   H.write(R.area()/'devices'/('a'*24+'.json'),{'id':'a'*24,'status':status,'token_sha256':hashlib.sha256(b'fixture-token').hexdigest()})
   with self.assertRaises(H.Closed):R.api('/v1/deployments','POST','fixture-token',{'command':'deployment_start'})
 def test_changed_handoff_does_not_release_next_step(self):
  d=self.start();original=D.guard
  def corrupt(data):
   if data['steps'][0]['status']=='evidence collected':H.write(D.folder()/data['id']/'step-0.json',[{'role':'tool','content':'tampered'}])
   return original(data)
  with patch.object(C,'run',side_effect=self.fake_run) as run,patch.object(D,'guard',side_effect=corrupt):D.run(d['id']);self.assertEqual(run.call_count,1)
  self.assertEqual(H.read(D.path(d['id']))['status'],'held')
 def test_arbitrary_remote_commands_not_forwarded(self):
  R=load('deploy_remote_command_fixture','remote_host.py');R.H=H
  with patch.object(R,'device',return_value={'id':'fixture'}),patch.object(H,'main') as main:
   with self.assertRaises(H.Closed):R.api('/v1/deployments','POST','fixture',{'command':'apply','id':'a'*24})
   main.assert_not_called()
if __name__=='__main__':unittest.main(verbosity=2)
