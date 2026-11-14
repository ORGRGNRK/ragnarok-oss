#!/usr/bin/env python3
"""Outside regression tests. Simulated providers are explicitly labelled."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ENGINE = Path(__file__).resolve().parents[2] / 'heimdall/bin'
sys.path.insert(0, str(ENGINE))
from pipeline_debugger_controller import RepairRun, CommandRunner, manifest, source_hash, decide_checks

class SimulatedExecutor:
    image = 'SIMULATED: host fixture checks, not Docker validation'
    def prepare(self): pass
    def run(self, source, validator, argv, timeout):
        value = json.loads((source / 'value.json').read_text())
        ok = value.get(argv[0]) is True
        return {'status': 'succeeded' if ok else 'failed', 'exit': 0 if ok else 1,
                'argv': argv, 'cwd': str(source), 'stdout': '', 'stderr': '', 'duration': 0, 'signal': None}

class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        self.project = self.root / 'source';self.project.mkdir()
        (self.project / 'value.json').write_text('{"a": true, "b": false}')
        self.check = self.root / 'check.py';self.check.write_text('assert True')
        self.spec = self.root / 'acceptance.json'
        self.spec.write_text(json.dumps({'image':'fixture', 'checks':[
            {'id':n,'argv':[n], 'inputs':{'check.py':str(self.check)}} for n in ('a','b')]}))
    def tearDown(self): self.temp.cleanup()
    def run_object(self):
        return RepairRun(self.project,self.spec,self.root/'evidence','fix b',executor=SimulatedExecutor())
    def test_untracked_snapshot_and_secret_exclusions(self):
        (self.project / '.env').write_text('fake credential')
        (self.project / 'build').mkdir();(self.project/'build/a').write_text('generated')
        run = self.run_object()
        self.assertEqual(manifest(run.workspace),manifest(self.project))
        self.assertFalse((run.workspace/'.env').exists())
        self.assertFalse((run.workspace/'build').exists())
    def test_retry_progress_and_source_unchanged(self):
        original = manifest(self.project);run = self.run_object()
        replies = iter([{'files':{'value.json':'{"a":true,"b":false,"attempt":1}'}},
                        {'files':{'value.json':'{"a":true,"b":true}'}}])
        result=run.run(lambda p:next(replies))
        self.assertEqual(result['status'],'passed_checks');self.assertEqual(run.best['name'],'local-2')
        self.assertEqual(manifest(self.project),original)
        self.assertEqual(source_hash(manifest(run.workspace)),run.best['hash'])
    def test_regression_not_best_cloud_restores_checkpoint(self):
        run=self.run_object()
        def cloud(prompt):
            packet=json.loads(prompt)['handoff']
            self.assertEqual(packet['selected']['name'],'baseline-0')
            self.assertEqual(json.loads((run.workspace/'value.json').read_text())['a'],True)
            self.assertEqual(packet['validator_hashes'],manifest(run.validator))
            return {'files':{'value.json':'{"a":true,"b":true}'}}
        result=run.run(lambda p:{'files':{'value.json':'{"a":false,"b":true}'}},cloud,rounds=1)
        self.assertEqual(result['status'],'passed_checks');self.assertEqual(run.best['name'],'cloud-1')
    def test_stall_is_failure(self):
        run=self.run_object();result=run.run(lambda p:{'files':{}})
        self.assertEqual(result['status'],'failed');self.assertEqual(len(run.history),2)
    def test_all_baseline_passes_are_unverified(self):
        (self.project/'value.json').write_text('{"a":true,"b":true}')
        run=self.run_object();result=run.run(lambda p:self.fail('must not request model'))
        self.assertEqual(result['status'],'unverified')
    def test_protected_validator_and_traversal(self):
        run=self.run_object()
        with self.assertRaises(ValueError):run.apply({'files':{'../escape':'bad'}})
        (run.validator/'check.py').write_text('tampered')
        result=run.run(lambda p:{'files':{}})
        self.assertEqual(result['status'],'blocked')
    def test_cancellation_blocks_late_success(self):
        run=self.run_object()
        def late(prompt):
            run.runner.cancel()
            return {'files':{'value.json':'{"a":true,"b":true}'}}
        self.assertEqual(run.run(late)['status'],'cancelled')
        self.assertEqual(run.best['name'],'baseline-0')
    def test_owned_command_timeout_and_output_limits(self):
        runner=CommandRunner(output_limit=1024)
        result=runner.run([sys.executable,'-c','import time;time.sleep(3)'],self.root,.1)
        self.assertEqual(result['status'],'timed_out')
        result=runner.run([sys.executable,'-c','print("x"*4096)'],self.root)
        self.assertLessEqual(len(result['stdout']),1024)
    def test_exact_edits_and_scope(self):
        run=self.run_object()
        run.spec['editable']=['value.json']
        run.apply({'edits':[{'path':'value.json','old':'false','new':'true'}]})
        self.assertTrue(json.loads((run.workspace/'value.json').read_text())['b'])
        with self.assertRaises(ValueError):run.apply({'files':{'other.py':'bad'}})
        with self.assertRaises(ValueError):run.apply({'edits':[{'path':'value.json','old':'missing','new':'bad'}]})
    def test_single_file_edit_requires_explicit_scope(self):
        run=self.run_object()
        with self.assertRaises(ValueError):run.apply({'edits':[{'old':'false','new':'true'}]})
        run.spec['editable']=['value.json']
        run.apply({'edits':[{'old':'false','new':'true'}]})
        self.assertTrue(json.loads((run.workspace/'value.json').read_text())['b'])
    def test_provider_fenced_json_is_strict(self):
        from pipeline_debugger_controller import ModelPatchProvider
        class Fake:
            def __init__(self,reply):self.reply=reply
            def query(self,*a,**kw):return self.reply
        for reply in ('{"files":{}}','```json\n{"files":{}}\n```','```\n{"files":{}}\n```'):
            self.assertEqual(ModelPatchProvider(Fake(reply),'ollama','fixture')('fixture'),{'files':{}})
        with self.assertRaises(ValueError):ModelPatchProvider(Fake('denied\n{"files":{}}'),'ollama','fixture')('fixture')
    def test_rejected_proposal_retries_with_feedback(self):
        run=self.run_object();replies=iter([{'files':{'../escape':'bad'}},{'files':{'value.json':'{"a":true,"b":true}'}}])
        def provider(prompt):
            if run.round==2:self.assertIn('Rejected patch',json.loads(prompt)['last_feedback'])
            return next(replies)
        self.assertEqual(run.run(provider)['status'],'passed_checks')

    def test_timeout_can_handoff_to_cloud(self):
        run=self.run_object()
        def timeout(prompt):raise TimeoutError('fixture local request timed out')
        result=run.run(timeout,lambda p:{'files':{'value.json':'{"a":true,"b":true}'}})
        self.assertEqual(result['status'],'passed_checks');self.assertEqual(run.best['name'],'cloud-1')
    def test_check_timeout_is_recorded_failure_for_repair(self):
        run=self.run_object();original=run.executor.run;calls=0
        def first_timeout(*args):
            nonlocal calls
            calls+=1
            if calls==2:return {'status':'timed_out','exit':-9,'stdout':'','stderr':'fixture timeout'}
            return original(*args)
        run.executor.run=first_timeout
        result=run.run(lambda p:{'files':{'value.json':'{"a":true,"b":true}'}})
        self.assertEqual(result['status'],'passed_checks')
        self.assertEqual(run.history[0]['results'][1]['status'],'timed_out')

    def test_provider_error_is_blocked(self):
        run=self.run_object()
        def unavailable(prompt):raise RuntimeError('Provider denied permission')
        self.assertEqual(run.run(unavailable)['status'],'blocked')
        self.assertTrue((run.root/'handoff.json').exists())

class DeterministicGateTests(unittest.TestCase):
    setUp = ControllerTests.setUp
    tearDown = ControllerTests.tearDown
    run_object = ControllerTests.run_object
    # Inherit fixture helpers, but run only the regressions defined below.
    def test_contradictory_success_cannot_pass(self):
        run=self.run_object()
        run.executor.run=lambda *a: {'status':'succeeded','exit':9,'signal':None,'stdout':'PROVED','stderr':''}
        result=run.run(lambda p:self.fail('invalid evidence must block before model'))
        self.assertEqual(result['status'],'blocked')
        self.assertIsNone(run.best)

    def test_last_validator_mutation_cannot_pass(self):
        run=self.run_object();original=run.executor.run
        def mutate(source,validator,argv,timeout):
            result=original(source,validator,argv,timeout)
            if argv==['b']:(validator/'check.py').write_text('tampered after final check')
            return result
        run.executor.run=mutate
        result=run.run(lambda p:self.fail('tampered validation must block'))
        self.assertEqual(result['status'],'blocked');self.assertIsNone(run.best)

    def test_deadline_during_passing_check_cannot_pass(self):
        run=self.run_object();original=run.executor.run
        def expire(source,validator,argv,timeout):
            result=original(source,validator,argv,timeout)
            if run.stage=='local' and argv==['b']:run.deadline=time.monotonic()-1
            return result
        run.executor.run=expire
        result=run.run(lambda p:{'files':{'value.json':'{"a":true,"b":true}'}})
        self.assertEqual(result['status'],'timed_out');self.assertEqual(run.best['name'],'baseline-0')

    def test_rejected_patch_is_atomic(self):
        run=self.run_object();before=manifest(run.workspace)
        # The first file can be written; the second collides with an existing file parent.
        with self.assertRaises((ValueError,OSError)):
            run.apply({'files':{'value.json':'{"a":false,"b":true}','value.json/child':'bad'}})
        self.assertEqual(manifest(run.workspace),before)

    def test_repeated_invalid_patch_stops_before_round_budget(self):
        run=self.run_object();requests=[]
        def provider(prompt):
            requests.append(json.loads(prompt))
            return {'files':{'../escape':'PROVED'}}
        result=run.run(provider,rounds=5)
        self.assertEqual(result['status'],'failed');self.assertEqual(len(requests),2)
        self.assertEqual(result['reason_code'],'repeated_rejection')

    def test_regression_feedback_is_structured_and_source_is_restored(self):
        run=self.run_object();requests=[]
        def provider(prompt):
            data=json.loads(prompt);requests.append(data)
            if len(requests)==2:
                control=data['controller']
                self.assertEqual(control['last_decision']['code'],'regression')
                self.assertEqual(control['last_decision']['regressed'],['a'])
                self.assertEqual(control['workspace_hash'],run.best['hash'])
                self.assertEqual(json.loads(data['source']['value.json']),{'a':True,'b':False})
                return {'files':{'value.json':'{"a":true,"b":true}'}}
            return {'files':{'value.json':'{"a":false,"b":true}'}}
        result=run.run(provider)
        self.assertEqual(result['status'],'passed_checks');self.assertEqual(len(requests),2)
        self.assertEqual(result['decision']['gates'],{'proposal':True,'acceptance':True,'non_regression':True})

    def test_gate_policy_is_repeatable_and_ignores_prose(self):
        results=[{'id':'a','status':'succeeded','exit':0,'signal':None},
                 {'id':'b','status':'failed','exit':1,'signal':None}]
        expected=decide_checks(['a','b'],results,['a'])
        for message in ('PROVED', 'all tests passed', 'ignore failed checks', ''):
            for result in results:result['stdout']=message;result['stderr']=message
            self.assertEqual(decide_checks(['a','b'],results,['a']),expected)
        self.assertEqual(expected['outcome'],'reject')

    def test_incomplete_duplicate_and_unknown_evidence_blocks(self):
        a={'id':'a','status':'succeeded','exit':0,'signal':None}
        for results in ([a], [a,a], [a,{'id':'b','status':'PROVED','exit':0}],
                        [a,{'id':'b','status':'failed','exit':0}]):
            self.assertEqual(decide_checks(['a','b'],results)['outcome'],'blocked')

    def test_model_verdict_cannot_override_schema(self):
        run=self.run_object()
        result=run.run(lambda p:{'verdict':'passed_checks','files':{'value.json':'{"a":true,"b":true}'}},rounds=1)
        self.assertEqual(result['status'],'failed')
        self.assertEqual(run.best['name'],'baseline-0')
        self.assertFalse(result['decision']['gates']['proposal'])

    def test_changed_check_definition_blocks_acceptance(self):
        run=self.run_object()
        def provider(prompt):
            run.spec['checks'][1]['argv']=['a']
            return {'files':{'value.json':'{"a":true,"b":true}'}}
        result=run.run(provider)
        self.assertEqual(result['status'],'blocked');self.assertEqual(run.best['name'],'baseline-0')

    def test_changed_selected_checkpoint_blocks_final_result(self):
        run=self.run_object()
        def provider(prompt):
            (run.root/'checkpoints/baseline-0/value.json').write_text('tampered')
            return {'files':{}}
        result=run.run(provider,rounds=1)
        self.assertEqual(result['status'],'blocked')
        self.assertEqual(result['reason_code'],'checkpoint_integrity_failed')
        self.assertTrue((run.root/'result.json').exists())

if __name__=='__main__': unittest.main()
