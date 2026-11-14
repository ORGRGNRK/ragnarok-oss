#!/usr/bin/env python3
"""Scratch fixtures: tools are host-authorized, models cannot write or approve."""
import importlib.util,json,pathlib,sys,tempfile,unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).parent
spec=importlib.util.spec_from_file_location('chat_test_host',ROOT/'alexus_host.py');H=importlib.util.module_from_spec(spec);sys.modules[spec.name]=H;spec.loader.exec_module(H)
spec=importlib.util.spec_from_file_location('chat_test',ROOT/'chat_host.py');C=importlib.util.module_from_spec(spec);spec.loader.exec_module(C);C.H=H
class ChatChecks(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name);self.source=self.root/'alexus';self.source.mkdir();self.project=self.root/'heimdall';self.project.mkdir();self.state=self.root/'state';self.state.mkdir()
  self.patches=[patch.object(H,'SOURCE',self.source),patch.object(H,'STATE',self.state),patch.object(C,'scrub',side_effect=lambda x:str(x))]
  for p in self.patches:p.start()
 def tearDown(self):
  for p in reversed(self.patches):p.stop()
  self.tmp.cleanup()
 def fixture(self):
  sid='b'*24;d={'id':sid,'provider':'mac','model':'fixture','project':'heimdall','status':'working','epoch':H.epoch(),'actions':[],'messages':[{'role':'user','content':'fixture'}]};H.write(C.path(sid),d);return sid
 def test_read_file_reports_exact_subset(self):
  (self.project/'source.swift').write_text('one\ntwo\nthree\n')
  d=json.loads(C.tool(self.project,'read_file',{'path':'source.swift','start_line':2,'line_count':1}))
  self.assertEqual((d['start_line'],d['end_line'],d['total_lines'],d['text']),(2,2,3,'two'))
 def test_private_and_escaped_paths_denied(self):
  for name in ['../alexus/file','/etc/passwd','.env','keys/private.pem','secret.txt','logs/errors.jsonl']:
   with self.assertRaises(H.Closed):C.safe_file(self.project,name)
 def test_symlink_denied(self):
  (self.project/'link').symlink_to('/etc/passwd')
  with self.assertRaises(H.Closed):C.safe_file(self.project,'link')
 def test_shell_injection_and_writes_denied(self):
  for cmd in ['ls; touch bad','rm -rf .','git push','echo hi > file','curl example.com','python3 -c pass']:
   with self.assertRaises(H.Closed):C.tool(self.project,'shell',{'command':cmd})
  self.assertEqual(list(self.project.iterdir()),[])
 def test_real_sandboxed_command(self):
  result=json.loads(C.tool(self.project,'shell',{'command':'pwd'}))
  self.assertEqual(result['exit_code'],0);self.assertEqual(pathlib.Path(result['output'].strip()).resolve(),self.project.resolve())
 def test_global_stop_prevents_model_call(self):
  sid=self.fixture();H.write(self.state/'revoked',{})
  with patch.object(C,'request') as request:C.run(sid);request.assert_not_called()
  self.assertEqual(H.read(C.path(sid))['status'],'held')
 def test_epoch_change_prevents_tools(self):
  sid=self.fixture()
  def response(*a,**kw):
   H.write(self.state/'epoch.json',{'value':'new-epoch'})
   return {'message':{'role':'assistant','content':'','tool_calls':[{'function':{'name':'shell','arguments':{'command':'pwd'}}}]}}
  with patch.object(C,'request',side_effect=response),patch.object(C,'tool') as tool:C.run(sid);tool.assert_not_called()
 def test_model_tools_and_final_remain_separate(self):
  sid=self.fixture();responses=[{'message':{'role':'assistant','content':'Inspecting','tool_calls':[{'function':{'name':'shell','arguments':{'command':'pwd'}}}]}},{'message':{'role':'assistant','content':'Model claim'}}]
  with patch.object(C,'request',side_effect=responses):C.run(sid)
  state=H.read(C.path(sid));self.assertEqual(state['status'],'done');self.assertEqual(state['actions'][0]['result'],'observed');self.assertEqual([m['role'] for m in state['messages']],['user','assistant','tool','assistant'])
  rows=H.read(self.state/'receipts.json');self.assertNotIn('Model claim',json.dumps(rows));self.assertTrue(H.valid_receipts(rows))
 def test_unknown_tool_does_not_execute(self):
  sid=self.fixture();responses=[{'message':{'role':'assistant','content':'','tool_calls':[{'function':{'name':'apply','arguments':{}}}]}},{'message':{'role':'assistant','content':'Unverified'}}]
  with patch.object(C,'request',side_effect=responses):C.run(sid)
  self.assertEqual(H.read(C.path(sid))['actions'][0]['result'],'held');self.assertFalse((self.state/'repairs').exists())
 def test_exact_text_tool_envelope_still_requires_host_execution(self):
  sid=self.fixture();responses=[{'message':{'role':'assistant','content':json.dumps({'name':'shell','arguments':{'command':'pwd'}})}},{'message':{'role':'assistant','content':'Unverified'}}]
  with patch.object(C,'request',side_effect=responses),patch.object(C,'tool',return_value='actual host result') as tool:C.run(sid);tool.assert_called_once()
  self.assertEqual(H.read(C.path(sid))['messages'][2]['content'],'actual host result')
 def test_local_repair_routes_model_without_cloud_fallback(self):
  with patch.object(H,'chat_module',return_value=C),patch.object(C,'repair_model',return_value=b'fixture') as local,patch.object(H,'command') as command:
   H.model(['--sandbox','read-only'],self.source,'fixture',provider='mac',selected_model='fixture-model')
   self.assertEqual(local.call_args.args[-2:],('mac','fixture-model'));command.assert_not_called()
 def test_local_stage_cannot_write_host_or_live_source(self):
  response={'message':{'content':json.dumps({'name':'write_source','arguments':{'path':'Host/alexus_host.py','content':'bad'}})}}
  with patch.object(C,'request',return_value=response):
   with self.assertRaises(H.Closed):C.repair_model(['--sandbox','workspace-write'],self.source,'fixture','mac','fixture')
  self.assertFalse((self.source/'Host').exists())
 def test_readonly_review_cannot_use_staged_write_tool(self):
  response={'message':{'content':json.dumps({'name':'write_source','arguments':{'path':'Sources/Views.swift','content':'bad'}})}}
  with patch.object(C,'request',return_value=response):
   with self.assertRaises(H.Closed):C.repair_model(['--sandbox','read-only'],self.source,'fixture','mac','fixture')
 def test_unavailable_local_repair_model_not_queued(self):
  with patch.object(H,'chat_module',return_value=C),patch.object(C,'models',return_value=[]):
   with self.assertRaises(H.Closed):H.queue('fixture change',provider='mac',selected_model='missing')
  self.assertFalse(list((self.state/'repairs').glob('*/state.json')))
 def test_redirect_refused(self):
  with self.assertRaises(H.Closed):C.NoRedirect().redirect_request(None,None,302,'',{},'http://other')
 def test_structured_action_is_executed_by_host(self):
  sid=self.fixture();responses=[{'message':{'role':'assistant','content':json.dumps({'action':'shell','command':'pwd','text':'Inspecting'})}},{'message':{'role':'assistant','content':json.dumps({'action':'answer','text':'Unverified runtime'})}}]
  with patch.object(C,'request',side_effect=responses),patch.object(C,'tool',return_value='host evidence') as tool:C.run(sid);tool.assert_called_once_with(self.project.resolve(),'shell',{'command':'pwd'})
  self.assertEqual(H.read(C.path(sid))['messages'][-1]['content'],'Unverified runtime')
 def test_unpaired_remote_chat_denied(self):
  spec=importlib.util.spec_from_file_location('chat_remote',ROOT/'remote_host.py');R=importlib.util.module_from_spec(spec);spec.loader.exec_module(R);R.H=H
  with self.assertRaises(H.Closed):R.api('/v1/chat','POST','invalid',{'command':'chat_models'})
 def test_trace_records_feedback_and_stop_without_receipt_content(self):
  sid=self.fixture();responses=[{'message':{'role':'assistant','content':json.dumps({'action':'shell','command':'pwd','text':'Inspecting'})}},{'message':{'role':'assistant','content':json.dumps({'action':'answer','text':'finished fixture'})}}]
  with patch.object(C,'request',side_effect=responses),patch.object(C,'tool',return_value='fixture tool result'):C.run(sid)
  files=list((self.state/'chat-traces').glob('*.json'));self.assertEqual(len(files),1)
  trace=H.read(files[0]);events=trace['events'];self.assertEqual([e['event'] for e in events],['started','context','model.request','model.response','tool.request','tool.result','model.request','model.response','finished'])
  feedback=events[6]['data']['payload']['messages'][-1]
  self.assertEqual(feedback['role']['text'],'tool');self.assertEqual(feedback['content']['text'],'fixture tool result')
  self.assertEqual(events[-1]['data']['stop_reason']['text'],'model_answer')
  self.assertEqual(files[0].stat().st_mode & 0o777,0o600)
  self.assertEqual(files[0].parent.stat().st_mode & 0o777,0o700)
  self.assertNotIn('fixture tool result',(self.state/'receipts.json').read_text())
 def test_trace_scrubs_nested_values_and_keys(self):
  with patch.object(C,'scrub',side_effect=lambda v:str(v).replace('SECRET','[redacted]')):
   trace=C.DiagnosticTrace('a'*24);trace.emit('fixture',{'SECRET':{'nested':['SECRET']}})
  text=trace.file.read_text();self.assertNotIn('SECRET',text);self.assertIn('[redacted]',text)
 def test_trace_bounds_storage_and_marks_omission(self):
  with patch.object(C,'TRACE_BYTES',1800),patch.object(C,'TRACE_FILES',2):
   for _ in range(4):
    trace=C.DiagnosticTrace('a'*24);trace.emit('large',{'value':'x'*5000})
    self.assertLessEqual(trace.file.stat().st_size,1800)
    self.assertGreater(H.read(trace.file)['dropped_events'],0)
   self.assertEqual(len(list(trace.root.glob('*.json'))),2)
 def test_trace_model_failure_records_type_not_error_payload(self):
  sid=self.fixture()
  with patch.object(C,'request',side_effect=RuntimeError('PRIVATE ERROR PAYLOAD')):C.run(sid)
  trace=H.read(next((self.state/'chat-traces').glob('*.json')))
  self.assertEqual(trace['events'][-1]['data']['stop_reason']['text'],'held:RuntimeError')
  self.assertNotIn('PRIVATE ERROR PAYLOAD',json.dumps(trace))
 def test_trace_repetition_stops_at_step_budget(self):
  sid=self.fixture();response={'message':{'role':'assistant','content':json.dumps({'action':'shell','command':'pwd','text':'Inspecting'})}}
  with patch.object(C,'request',return_value=response),patch.object(C,'tool',return_value='fixture'):C.run(sid)
  trace=H.read(next((self.state/'chat-traces').glob('*.json')))
  self.assertEqual(trace['events'][-1]['data']['stop_reason']['text'],'six_step_budget')
  self.assertEqual(sum(e['event']=='model.request' for e in trace['events']),6)
 def test_trace_symlink_directory_denied(self):
  outside=self.root/'outside';outside.mkdir();(self.state/'chat-traces').symlink_to(outside)
  with self.assertRaises(H.Closed):C.DiagnosticTrace('a'*24)
  self.assertEqual(list(outside.iterdir()),[])
if __name__=='__main__':unittest.main(verbosity=2)
