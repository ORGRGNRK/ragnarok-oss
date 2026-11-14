#!/usr/bin/env python3
"""Isolated daemon regressions: fake AI, real scratch git worktrees; no live model or service."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

FILE = Path(__file__).resolve().parents[1]/'bin/ragnarok-doctor'
loader=importlib.machinery.SourceFileLoader('doctor',str(FILE))
spec=importlib.util.spec_from_loader(loader.name,loader)
m=importlib.util.module_from_spec(spec)
loader.exec_module(m)


class DoctorTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='doctor-check-')
        self.root=Path(self.temp.name)
        self.repo=self.root/'repo';self.app=self.repo/'app/heimdall'
        self.app.mkdir(parents=True)
        self.source=self.root/'app-errors.jsonl'
        self.c=m.defaults()
        self.c.update(project=str(self.app),source=str(self.source),support=str(self.root/'support'),settle_seconds=1,auto_install=False,notify=False)
        self.d=m.Doctor(self.root/'state',self.c,scrub=lambda text:text.replace('throwaway-secret','[hidden]'))
    def tearDown(self):
        self.d.db.close();self.temp.cleanup()
    def event(self,**kw):
        return dict(level='error',area='fixture',message='operation failed',**kw)
    def add(self,e=None):
        self.d.ingest(json.dumps(e or self.event())+'\n')
        return self.d.status()[0]['id']
    def incident(self,iid):
        return dict(self.d.db.execute('select * from incidents where id=?',(iid,)).fetchone())
    def git(self,*args):
        return subprocess.run(['git',*args],cwd=self.repo,capture_output=True,text=True,check=True).stdout.strip()
    def setup_repo(self):
        self.git('init','-q');self.git('config','user.name','fixture');self.git('config','user.email','fixture@example.test')
        (self.repo/'.gitignore').write_text('build/\n__pycache__/\n')
        (self.app/'bug.py').write_text('broken\n')
        (self.app/'checks').mkdir()
        script=self.app/'make-app.sh'
        script.write_text('#!/bin/sh\nset -e\nmkdir -p build/Heimdall.app/Contents/MacOS\nprintf "#!/bin/sh\\necho SELFTEST PASS\\n" > build/Heimdall.app/Contents/MacOS/Heimdall\nchmod +x build/Heimdall.app/Contents/MacOS/Heimdall\n')
        script.chmod(0o755)
        self.git('add','.');self.git('commit','-qm','fixture baseline')
    def fake_model(self, iid, phase, cwd, *args, **kw):
        self.phases.append(phase)
        if phase=='diagnosis':
            return {'decision':'repair','file':'bug.py','line':1,'reason':'fixture source defect'}
        if phase=='repair':
            (cwd/'bug.py').write_text('fixed\n')
            (cwd/'checks').mkdir(exist_ok=True)
            (cwd/'checks'/('doctor_'+iid+'.py')).write_text('from pathlib import Path\nassert Path("bug.py").read_text().strip()=="fixed"\n')
            return {'summary':'fixture fix'}
        return {'verdict':self.review,'reason':'fixture independent review'}
    def run_fixture(self,severity='medium',review='approve'):
        self.setup_repo();iid=self.add(self.event(severity=severity));self.phases=[];self.review=review
        with patch.object(self.d,'model',side_effect=self.fake_model):
            self.d.repair(self.incident(iid))
        return iid,self.incident(iid)

    def test_dedupe_scrub_and_restart(self):
        iid=self.add(self.event(message2='ignored',actor='codex'))
        # message2 is ignored; unsupported fields do not enter incident data.
        self.add(self.event(actor='codex'));self.assertEqual(self.incident(iid)['occurrences'],2)
        self.assertNotIn('message2',self.incident(iid)['event'])
        self.d.ingest(json.dumps({'message':'throwaway-secret','area':'other','level':'error'})+'\n')
        self.assertNotIn('throwaway-secret',str(self.d.db.execute('select event from incidents').fetchall()))
        second=m.Doctor(self.root/'state',self.c,scrub=lambda s:s)
        self.assertEqual(len(second.status()),2);second.db.close()
    def test_classification_and_priority(self):
        self.assertEqual(m.classify({'area':'uncaught-exception'})[0],'critical')
        self.assertEqual(m.classify({'area':'uncaught-exception','severity':'low'})[0],'critical')
        self.assertEqual(m.classify({'severity':'nonsense','level':'error'})[0],'Unverified')
        low=self.add(self.event(severity='low'))
        self.add(self.event(severity='critical'))
        self.assertEqual(self.incident(low)['severity'],'critical')
        with self.d.lock:
            self.d.db.execute("update incidents set first_seen='2020-01-01T00:00:00+00:00'");self.d.db.commit()
        self.assertEqual(self.d.next_incident()['id'],low)
    def test_unknown_and_recursive_errors_do_not_dispatch(self):
        iid=self.add({'message':'no evidence'})
        self.assertEqual(self.incident(iid)['status'],'needs_attention')
        self.add(self.event(origin='repair-daemon'))
        self.assertIsNone(self.d.next_incident())
    def test_tail_skips_history_handles_partial_rotation_and_restart(self):
        self.source.write_text(json.dumps(self.event())+'\n');self.d.tail();self.assertEqual(len(self.d.status()),0)
        with self.source.open('a') as f:f.write('{"message":"partial","level":"error"')
        self.d.tail();self.assertEqual(len(self.d.status()),0)
        with self.source.open('a') as f:f.write('}\n')
        self.source.rename(str(self.source)+'.1')
        self.source.write_text(json.dumps(self.event())+'\n');self.d.tail()
        self.assertEqual(len(self.d.status()),2)
        self.d.tail();self.assertTrue(all(r['occurrences']==1 for r in self.d.status()))
    def test_first_event_after_missing_source_is_not_skipped(self):
        self.d.tail();self.assertIn('missing',self.d.meta('source_health'))
        self.source.write_text(json.dumps(self.event())+'\n');self.d.tail()
        self.assertEqual(len(self.d.status()),1)
    def test_dirty_tree_blocks_without_a_model_call(self):
        self.setup_repo();(self.app/'bug.py').write_text('user unsaved edit\n');iid=self.add()
        with patch.object(self.d,'model') as model:
            self.d.repair(self.incident(iid));model.assert_not_called()
        self.assertEqual(self.incident(iid)['status'],'waiting_for_clean_tree')
        self.assertEqual(self.incident(iid)['attempts'],0)
    def test_existing_install_preserves_rollback_without_a_model_call(self):
        self.setup_repo();support=Path(self.c['support']);support.mkdir();(support/'update-ready').write_text('pending')
        iid=self.add()
        with patch.object(self.d,'model') as model:
            self.d.repair(self.incident(iid));model.assert_not_called()
        self.assertEqual(self.incident(iid)['status'],'waiting_for_clean_tree')
    def test_rate_limit_survives_restart(self):
        self.c['max_model_calls_per_hour']=1;self.d.reserve_call('a','diagnosis')
        with self.assertRaises(RuntimeError):self.d.reserve_call('a','repair')
        self.assertEqual(self.d.db.execute('select count(*) from calls').fetchone()[0],1)
    def test_restart_continues_an_interrupted_repair(self):
        iid=self.add();self.d.state(iid,'repairing');self.d.recover()
        self.assertEqual(self.incident(iid)['status'],'queued')
        self.d.db.execute("update incidents set first_seen='2020-01-01T00:00:00+00:00'");self.d.db.commit()
        self.assertEqual(self.d.next_incident()['id'], iid)
    def test_restart_stops_after_the_attempt_limit(self):
        iid=self.add();self.d.state(iid,'repairing')
        self.d.db.execute('update incidents set attempts=? where id=?', (self.c['max_attempts'], iid));self.d.db.commit()
        self.d.recover()
        self.assertEqual(self.incident(iid)['status'],'needs_attention');self.assertIsNone(self.d.next_incident())
    def test_worker_crash_retries_without_a_person(self):
        self.setup_repo();iid=self.add()
        with patch.object(self.d,'model',side_effect=RuntimeError('process failed at diagnosis')):
            self.d.repair(self.incident(iid))
        row=self.incident(iid)
        self.assertEqual(row['status'],'queued',row)
        self.assertEqual(row['attempts'],1)
        self.assertEqual((self.app/'bug.py').read_text(),'broken\n')
    def test_codex_is_the_last_fallback_by_default(self):
        for route in m.defaults()['routes'].values():
            self.assertEqual(route['agents'],['grok','claude','codex'])
            self.assertNotIn('agent',route)
    def test_old_single_agent_config_and_bad_chains(self):
        self.c['routes']['low']={'agent':'muse','model':'','review_model':'','second_review':False}
        self.assertEqual(m.validate_config(self.c)['routes']['low']['agents'],['muse'])
        for bad in ([],['grok','grok'],['gpt'],'codex'):
            self.c['routes']['low']={'agents':bad,'model':'','review_model':'','second_review':False}
            with self.assertRaises(ValueError):m.validate_config(self.c)
    def test_model_name_stays_with_its_own_agent(self):
        chain=['grok','claude','codex']
        self.assertEqual([m.model_for('g-1',a,chain) for a in chain],['g-1','',''])
        self.assertEqual([m.model_for({'codex':'c-1'},a,chain) for a in chain],['','','c-1'])
    def chain_fixture(self,fails,severity='medium'):
        """Run a whole repair where the agents in `fails` crash; returns (row, [(phase, agent)...])."""
        self.setup_repo();iid=self.add(self.event(severity=severity));self.phases=[];self.review='approve';asked=[]
        def model(iid,phase,cwd,*a,**kw):
            asked.append((phase,kw['agent']))
            if kw['agent'] in fails:
                if phase=='repair':(cwd/'bug.py').write_text('half made by '+kw['agent']+'\n');(cwd/'junk.txt').write_text('x')
                raise RuntimeError('process failed at '+phase)
            return self.fake_model(iid,phase,cwd,*a,**kw)
        with patch.object(self.d,'model',side_effect=model):self.d.repair(self.incident(iid))
        return self.incident(iid),asked
    def test_first_agent_does_all_the_work_when_it_answers(self):
        row,asked=self.chain_fixture(())
        self.assertEqual(row['status'],'applied_unverified',row)
        self.assertEqual(asked,[('diagnosis','grok'),('repair','grok')])
    def test_codex_runs_only_after_grok_and_claude_fail(self):
        row,asked=self.chain_fixture(('grok','claude'),'critical')
        self.assertEqual(row['status'],'applied_unverified',row)
        # each failed once, was not asked again, and codex finished every phase
        self.assertEqual(asked,[('diagnosis','grok'),('diagnosis','claude'),('diagnosis','codex'),
                                ('repair','codex'),('review','codex')])
        self.assertEqual(self.git('log','-1','--format=%an'),'codex doctor')
        self.assertTrue(row['branch'].startswith('doctor/'))
        notes=[r[0] for r in self.d.db.execute('select note from history where incident=? order by rowid',(row['id'],))]
        for phase in ('diagnosis','repair','review'):self.assertIn('codex made the '+phase,notes)
        self.assertIn('grok gave no usable diagnosis; trying claude',notes)
    def test_fallback_starts_from_clean_source_not_a_half_made_change(self):
        self.setup_repo();iid=self.add();self.phases=[];self.review='approve';seen=[]
        def model(iid,phase,cwd,*a,**kw):
            if phase=='repair':
                seen.append(((cwd/'bug.py').read_text(),(cwd/'junk.txt').exists()))
                if kw['agent']=='grok':
                    (cwd/'bug.py').write_text('half made\n');(cwd/'junk.txt').write_text('x')
                    raise RuntimeError('process interrupted or timed out')
            return self.fake_model(iid,phase,cwd,*a,**kw)
        with patch.object(self.d,'model',side_effect=model):self.d.repair(self.incident(iid))
        self.assertEqual(seen,[('broken\n',False),('broken\n',False)])
        self.assertEqual(self.incident(iid)['status'],'applied_unverified')
        self.assertFalse((self.app/'junk.txt').exists())
    def test_a_refused_change_does_not_switch_agents(self):
        self.setup_repo();iid=self.add();asked=[]
        def model(iid,phase,cwd,*a,**kw):
            asked.append(kw['agent']);raise RuntimeError('read-only call edited the worktree')
        with patch.object(self.d,'model',side_effect=model):self.d.repair(self.incident(iid))
        self.assertEqual(asked,['grok']);self.assertEqual(self.incident(iid)['status'],'failed')
    def test_every_agent_failing_queues_another_attempt(self):
        row,asked=self.chain_fixture(('grok','claude','codex'))
        self.assertEqual([a for _,a in asked],['grok','claude','codex'])
        self.assertEqual(row['status'],'queued',row)
        self.assertEqual((self.app/'bug.py').read_text(),'broken\n')
    def test_read_only_check_allows_the_staged_patch_but_not_an_edit(self):
        # real model(), fake CLI: at review time the tested patch is already staged in the worktree
        self.setup_repo();(self.app/'bug.py').write_text('fixed\n');self.git('add','-A')
        props={'verdict':{'type':'string','enum':['approve','reject','Unverified']},'reason':{'type':'string'}}
        answer=json.dumps({'verdict':'approve','reason':'fixture'})
        with patch.object(self.d,'command',return_value=answer):
            self.assertEqual(self.d.model('fixture','review',self.app,'p',props,agent='claude')['verdict'],'approve')
        def edits(*a,**kw):
            (self.app/'bug.py').write_text('reviewer edit\n');return answer
        with patch.object(self.d,'command',side_effect=edits):
            with self.assertRaises(RuntimeError):self.d.model('fixture','review',self.app,'p',props,agent='claude')
    def test_critical_policy_cannot_disable_review(self):
        self.c['routes']['critical']['second_review']=False
        with self.assertRaises(ValueError):m.validate_config(self.c)
    def test_before_after_build_and_merge(self):
        iid,row=self.run_fixture()
        self.assertEqual(row['status'],'applied_unverified',row)
        self.assertEqual((self.app/'bug.py').read_text(),'fixed\n')
        self.assertEqual(self.phases,['diagnosis','repair'])
        self.assertIn('regression-before.log',[p.name for p in (self.d.home/'incidents'/iid).iterdir()])
    def test_critical_second_review_approves_before_merge(self):
        _,row=self.run_fixture('critical')
        self.assertEqual(row['status'],'applied_unverified',row)
        self.assertEqual(self.phases,['diagnosis','repair','review'])
    def test_critical_reject_does_not_merge_or_install(self):
        _,row=self.run_fixture('critical','reject')
        self.assertEqual(row['status'],'review_rejected',row)
        self.assertEqual((self.app/'bug.py').read_text(),'broken\n')
    def test_critical_unverified_does_not_merge(self):
        _,row=self.run_fixture('critical','Unverified')
        self.assertEqual(row['status'],'review_rejected',row)
        self.assertEqual((self.app/'bug.py').read_text(),'broken\n')
    def test_protected_test_edit_is_rejected(self):
        self.setup_repo();iid=self.add();self.phases=[];self.review='approve'
        original=self.fake_model
        def bad(iid,phase,cwd,*a,**kw):
            r=original(iid,phase,cwd,*a,**kw)
            if phase=='repair':(cwd/'make-app.sh').write_text('#!/bin/sh\nexit 0\n')
            return r
        with patch.object(self.d,'model',side_effect=bad):self.d.repair(self.incident(iid))
        self.assertEqual(self.incident(iid)['status'],'failed')
        self.assertEqual((self.app/'bug.py').read_text(),'broken\n')
    def test_no_code_diagnosis_does_not_repair(self):
        self.setup_repo();iid=self.add()
        with patch.object(self.d,'model',return_value={'decision':'no_code_change','file':'Unverified','line':0,'reason':'transient service'}) as model:
            self.d.repair(self.incident(iid));self.assertEqual(model.call_count,1)
        self.assertEqual(self.incident(iid)['status'],'no_code_change')
        self.assertEqual((self.app/'bug.py').read_text(),'broken\n')
    def test_budget_waits_before_starting_a_model(self):
        self.setup_repo();iid=self.add();self.c['max_model_calls_per_hour']=1
        with patch.object(self.d,'model') as model:
            self.d.repair(self.incident(iid));model.assert_not_called()
        self.assertEqual(self.incident(iid)['status'],'waiting_for_budget')
        self.assertEqual(self.incident(iid)['attempts'],0)
    def test_critical_escalation_during_repair_gets_review(self):
        self.setup_repo();iid=self.add();self.phases=[];self.review='approve'
        original=self.fake_model
        def escalate(iid,phase,cwd,*a,**kw):
            result=original(iid,phase,cwd,*a,**kw)
            if phase=='repair':self.add(self.event(severity='critical'))
            return result
        with patch.object(self.d,'model',side_effect=escalate):self.d.repair(self.incident(iid))
        self.assertIn('review',self.phases)
        self.assertEqual(self.incident(iid)['status'],'applied_unverified')
    def test_already_passing_regression_prevents_merge(self):
        self.setup_repo();iid=self.add();self.phases=[];self.review='approve'
        original=self.fake_model
        def fake(iid,phase,cwd,*a,**kw):
            result=original(iid,phase,cwd,*a,**kw)
            if phase=='repair':(cwd/'checks'/('doctor_'+iid+'.py')).write_text('pass\n')
            return result
        with patch.object(self.d,'model',side_effect=fake):self.d.repair(self.incident(iid))
        self.assertEqual(self.incident(iid)['status'],'failed')
        self.assertEqual((self.app/'bug.py').read_text(),'broken\n')
    def test_outside_app_edit_prevents_merge(self):
        self.setup_repo();iid=self.add();self.phases=[];self.review='approve'
        original=self.fake_model
        def outside(iid,phase,cwd,*a,**kw):
            result=original(iid,phase,cwd,*a,**kw)
            if phase=='repair':(cwd.parent.parent/'outside.txt').write_text('should not be included')
            return result
        with patch.object(self.d,'model',side_effect=outside):self.d.repair(self.incident(iid))
        self.assertEqual(self.incident(iid)['status'],'failed')
        self.assertEqual((self.app/'bug.py').read_text(),'broken\n')
    def test_changed_original_head_retains_tested_branch(self):
        self.setup_repo();iid=self.add();self.phases=[];self.review='approve'
        original=self.d.command
        def change_head(args,cwd,iid,phase,*a,**kw):
            result=original(args,cwd,iid,phase,*a,**kw)
            if phase=='selftest':
                (self.repo/'concurrent.txt').write_text('other work')
                self.git('add','concurrent.txt');self.git('commit','-qm','concurrent work')
            return result
        with patch.object(self.d,'model',side_effect=self.fake_model),patch.object(self.d,'command',side_effect=change_head):
            self.d.repair(self.incident(iid))
        self.assertEqual(self.incident(iid)['status'],'tested_branch')
        self.assertEqual((self.app/'bug.py').read_text(),'broken\n')
    def test_install_verifies_build_stamp_and_waits_for_restart(self):
        self.setup_repo();iid=self.add(self.event(severity='critical'));self.phases=[];self.review='approve'
        self.c['auto_install']=True;self.c['installed_app']=str(self.root/'installed.app')
        original=self.d.command
        def install(args,cwd,iid,phase,*a,**kw):
            if phase=='install':
                self.assertEqual(self.phases[-1],'review')
                f=Path(self.c['installed_app'])/'Contents/Resources/commit';f.parent.mkdir(parents=True)
                f.write_text(self.d.git(['rev-parse','--short','HEAD'],cwd=cwd))
                return ''
            return original(args,cwd,iid,phase,*a,**kw)
        with patch.object(self.d,'model',side_effect=self.fake_model),patch.object(self.d,'command',side_effect=install):
            self.d.repair(self.incident(iid))
        self.assertEqual(self.incident(iid)['status'],'installed_unverified')
        self.assertTrue((Path(self.c['support'])/'update-ready').exists())
    def test_model_timeout_and_failure_do_not_accept_result(self):
        with self.assertRaises(RuntimeError):
            self.d.command(['/bin/sleep','5'],self.app,'fixture','timeout',timeout=0.1)
        with self.assertRaises(RuntimeError):
            self.d.command(['/bin/sh','-c','exit 2'],self.app,'fixture','failure')
    def test_capacity_stops_new_ai_work(self):
        self.setup_repo();iid=self.add();self.c['max_worktrees']=1
        (self.d.home/'worktrees/retained').mkdir(parents=True)
        with patch.object(self.d,'model') as model:
            self.d.repair(self.incident(iid));model.assert_not_called()
        self.assertEqual(self.incident(iid)['status'],'waiting_for_capacity')
    def test_queue_capacity_is_visible_and_bounded(self):
        self.c['max_incidents']=1;self.add()
        self.add(dict(message='different incident',level='error',area='another'))
        self.assertEqual(len(self.d.status()),1);self.assertEqual(self.d.meta('queue_overflow'),1)
    def test_validation_source_mutation_prevents_merge(self):
        self.setup_repo();iid=self.add();self.phases=[];self.review='approve'
        original=self.fake_model
        def mutate(iid,phase,cwd,*a,**kw):
            result=original(iid,phase,cwd,*a,**kw)
            if phase=='repair':
                test=cwd/'checks'/('doctor_'+iid+'.py')
                test.write_text('from pathlib import Path\np=Path("bug.py")\nassert p.read_text().strip()=="fixed"\np.write_text("not the staged patch\\n")\n')
            return result
        with patch.object(self.d,'model',side_effect=mutate):self.d.repair(self.incident(iid))
        self.assertEqual(self.incident(iid)['status'],'failed')
        self.assertEqual((self.app/'bug.py').read_text(),'broken\n')
    def test_large_rotation_drains_all_batches_before_switch(self):
        self.source.write_text('');self.d.tail()
        event=json.dumps(self.event(extra='ignored',padding='ignored')).replace('operation failed','x'*150000)+'\n'
        self.source.write_text(event*9)
        self.source.rename(str(self.source)+'.1')
        self.source.write_text(json.dumps(dict(area='new',level='error',message='new file'))+'\n')
        for _ in range(5):self.d.tail()
        self.assertEqual(sum(r['occurrences'] for r in self.d.status()),10)
        self.assertEqual(len(self.d.status()),2)
        self.assertIsNone(self.d.meta('source_gap'))
    def test_recovery_kills_term_ignoring_worker_before_scheduling(self):
        child=subprocess.Popen(['/bin/sh','-c','trap "" TERM; sleep 30'],start_new_session=True)
        try:
            time.sleep(0.1)
            start=subprocess.run(['ps','-p',str(child.pid),'-o','lstart='],capture_output=True,text=True).stdout.strip()
            self.d.meta('active_child',{'pid':child.pid,'started':start})
            self.d.recover()
            self.assertIsNotNone(child.poll())
            self.assertEqual(self.d.meta('active_child'),{})
        finally:
            if child.poll() is None:
                import signal
                os.killpg(child.pid,signal.SIGKILL)
            child.wait()
    def test_recovery_waits_for_descendant_after_leader_exits(self):
        child=subprocess.Popen(['/bin/sh','-c','trap "exit 0" TERM; (trap "" TERM; exec sleep 30) & wait'],start_new_session=True)
        try:
            time.sleep(0.2)
            start=subprocess.run(['ps','-p',str(child.pid),'-o','lstart='],capture_output=True,text=True).stdout.strip()
            members=m.group_members(child.pid)
            self.assertGreaterEqual(len(members),2)
            self.d.meta('active_child',{'pid':child.pid,'started':start,'members':members})
            self.d.recover()
            self.assertEqual(m.group_members(child.pid),{})
            self.assertEqual(self.d.meta('active_child'),{})
        finally:
            import signal
            if m.group_members(child.pid):
                try:os.killpg(child.pid,signal.SIGKILL)
                except ProcessLookupError:pass
            child.wait()
    def test_unverifiable_orphan_group_blocks_restart(self):
        self.d.meta('active_child',{'pid':999999,'started':'old start','members':{}})
        with patch.object(m,'group_members',return_value={'888888':'different process'}):
            with self.assertRaises(RuntimeError):self.d.recover()
        self.assertTrue(self.d.meta('active_child'))
    def test_unregistered_child_cannot_begin_work(self):
        marker=self.root/'must-not-exist'
        original=self.d.meta
        def reject_registration(key,value=None):
            if key=='active_child':raise RuntimeError('fixture DB failure')
            return original(key,value)
        import sys
        with patch.object(self.d,'meta',side_effect=reject_registration):
            with self.assertRaises(RuntimeError):
                self.d.command([sys.executable,'-c','from pathlib import Path;Path('+repr(str(marker))+').write_text("bad")'],
                               self.app,'fixture','startup')
        self.assertFalse(marker.exists())
    def test_post_release_monitor_failure_stops_worker(self):
        original=m.group_members;calls=0
        def fail_once(pgid):
            nonlocal calls
            calls+=1
            if calls==2:raise RuntimeError('fixture monitoring failure after release')
            return original(pgid)
        with patch.object(m,'group_members',side_effect=fail_once):
            with self.assertRaises(RuntimeError):
                self.d.command(['/bin/sleep','30'],self.app,'fixture','monitor')
        tracked=self.d.meta('active_child')
        self.assertTrue(tracked)
        self.assertEqual(m.group_members(tracked['pid']),{})
        self.d.recover();self.assertEqual(self.d.meta('active_child'),{})
    def test_scheduler_does_not_overwrite_uncertain_worker(self):
        iid=self.add();self.d.db.execute("update incidents set first_seen='2020-01-01T00:00:00+00:00'");self.d.db.commit()
        launched=[];recovered=[]
        def repair(job):
            launched.append(job['id']);self.d.meta('active_child',{'pid':999999,'started':'fixture'})
            self.d.state(job['id'],'failed','fixture interrupted worker')
        def recover():
            recovered.append(True)
            if len(recovered)>1:
                self.d.stop.set();raise RuntimeError('old worker Unverified')
        with patch.object(self.d,'tail'),patch.object(self.d,'repair',side_effect=repair),patch.object(self.d,'recover',side_effect=recover):
            self.d.run()
        self.assertEqual(launched,[iid]);self.assertEqual(len(recovered),2)
        self.assertTrue(self.d.meta('active_child'))
    def test_state_files_private(self):
        self.assertEqual((self.d.home.stat().st_mode&0o777),0o700)
        self.assertEqual(((self.d.home/'queue.sqlite3').stat().st_mode&0o777),0o600)


if __name__=='__main__':
    os.umask(0o077)
    unittest.main(verbosity=2)
