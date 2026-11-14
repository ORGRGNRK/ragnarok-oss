#!/usr/bin/env python3
"""Scratch repositories served over a loopback-only git daemon; no real repo mutations."""
import importlib.machinery,importlib.util,os,socket,subprocess,tempfile,time,unittest
from pathlib import Path
loader=importlib.machinery.SourceFileLoader('ragnarok_sync',str(Path(__file__).resolve().parents[1]/'bin/ragnarok-sync'))
spec=importlib.util.spec_from_loader(loader.name,loader);sync=importlib.util.module_from_spec(spec);loader.exec_module(sync)
def git(path,*args):
 p=subprocess.run(['git',*args],cwd=path,text=True,capture_output=True)
 if p.returncode:raise AssertionError('scratch git failed: '+str(args))
 return p.stdout.strip()
class SyncChecks(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
  git(self.root,'init','--bare','central.git')
  self.a=self.root/'a';git(self.root,'clone',str(self.root/'central.git'),str(self.a))
  for p in [self.a]:git(p,'config','user.name','Fixture');git(p,'config','user.email','fixture@invalid')
  (self.a/'file.txt').write_text('one');git(self.a,'add','.');git(self.a,'commit','-m','one');git(self.a,'push','origin','HEAD:main')
  git(self.root/'central.git','symbolic-ref','HEAD','refs/heads/main')
  with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
  self.server=subprocess.Popen(['git','daemon','--reuseaddr','--export-all','--enable=receive-pack','--listen=127.0.0.1','--port='+str(port),'--base-path='+str(self.root),str(self.root)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  for _ in range(50):
   try:
    with socket.create_connection(('127.0.0.1',port),timeout=.1):break
   except OSError:time.sleep(.02)
  self.url='git://127.0.0.1:'+str(port)+'/central.git'
  self.b=self.root/'b';git(self.root,'clone',self.url,str(self.b))
  git(self.b,'config','user.name','Fixture');git(self.b,'config','user.email','fixture@invalid')
  git(self.a,'branch','-m','main');git(self.a,'remote','set-url','origin',self.url);git(self.a,'branch','--set-upstream-to=origin/main')
  self.entry=sync.enroll(self.b)
 def tearDown(self):self.server.terminate();self.server.wait();self.tmp.cleanup()
 def commit(self,p,text):
  (p/'file.txt').write_text(text);git(p,'add','file.txt');git(p,'commit','-m',text)
 def test_current(self):self.assertEqual(sync.sync_repo(self.entry)['reason'],'unchanged')
 def test_pull_fast_forward(self):
  self.commit(self.a,'two');git(self.a,'push');self.assertEqual(sync.sync_repo(self.entry)['reason'],'fast-forwarded');self.assertEqual((self.b/'file.txt').read_text(),'two')
 def test_push_clean_commit(self):
  self.commit(self.b,'two');self.assertEqual(sync.sync_repo(self.entry)['reason'],'pushed');git(self.a,'fetch');self.assertEqual(git(self.b,'rev-parse','HEAD'),git(self.a,'rev-parse','origin/main'))
 def test_dirty_held(self):
  (self.b/'untracked').write_text('keep');before=git(self.b,'rev-parse','HEAD');self.assertEqual(sync.sync_repo(self.entry)['reason'],'dirty');self.assertEqual(git(self.b,'rev-parse','HEAD'),before);self.assertTrue((self.b/'untracked').exists())
 def test_diverged_held(self):
  self.commit(self.a,'A');git(self.a,'push');self.commit(self.b,'B');before=git(self.b,'rev-parse','HEAD');self.assertEqual(sync.sync_repo(self.entry)['reason'],'diverged');self.assertEqual(git(self.b,'rev-parse','HEAD'),before)
 def test_no_upstream_held(self):
  e=dict(self.entry,remote=None,ref=None);self.assertEqual(sync.sync_repo(e)['reason'],'no-upstream')
 def test_destination_change_held(self):
  git(self.b,'remote','set-url','origin',self.url+'/different');self.assertEqual(sync.sync_repo(self.entry)['reason'],'destination-changed')
 def test_hooks_disabled(self):
  marker=self.root/'hook-ran';hook=self.b/'.git/hooks/post-merge';hook.write_text('#!/bin/sh\ntouch "'+str(marker)+'"\n');hook.chmod(0o700)
  self.commit(self.a,'two');git(self.a,'push');self.assertEqual(sync.sync_repo(self.entry)['reason'],'fast-forwarded');self.assertFalse(marker.exists())
 def test_hidden_index_flag_held(self):
  git(self.b,'update-index','--assume-unchanged','file.txt');self.assertEqual(sync.sync_repo(self.entry)['reason'],'hidden-index-flags')
 def test_custom_filter_held(self):
  (self.a/'.gitattributes').write_text('file.txt filter=fixture\n');git(self.a,'add','.');git(self.a,'commit','-m','filter');git(self.a,'push');self.assertEqual(sync.sync_repo(self.entry)['reason'],'custom-checkout')
class CatalogChecks(unittest.TestCase):
 def test_changed_generator_is_not_executed(self):
  import json
  from unittest.mock import patch
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);script=root/'generator.py';marker=root/'executed'
   script.write_text('from pathlib import Path\nPath('+repr(str(marker))+').touch()\n')
   cfg={'role':'mac','repositories':[],'catalog':str(script),'catalog_sha256':'wrong'}
   (root/'config.json').write_text(json.dumps(cfg))
   with patch.object(sync,'STATE',root),patch.object(sync,'publish',return_value='fixture: no network'):
    sync.once()
   self.assertFalse(marker.exists())
   self.assertEqual(json.loads((root/'status.json').read_text())['catalog'],'Unverified: refresh failed')
if __name__=='__main__':unittest.main(verbosity=2)
