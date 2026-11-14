#!/usr/bin/env python3
"""Offline regression tests. All keys/approvals here are software fixtures, never hardware claims."""
import base64
import copy
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import proof

GOOD = {'threshold_cents': 10000, 'rate_bps': 1000, 'comparison': '>=', 'claimed_passes': list('0123456')}
BAD = dict(GOOD, comparison='>')


def rehash(b):
    head = '0'*64
    for i,e in enumerate(b['events']):
        e['seq'],e['prev'] = i,head
        e['hash'] = proof.digest({k:e[k] for k in ('seq','at','kind','data','prev')})
        head=e['hash']
    b['head']=head


class ProofTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory()
        cls.root=Path(cls.temp.name)
        cls.priv=cls.root/'key.pem'
        subprocess.run(['openssl','ecparam','-name','prime256v1','-genkey','-noout','-out',str(cls.priv)],check=True,capture_output=True)
        cls.public=subprocess.run(['openssl','pkey','-in',str(cls.priv),'-pubout'],check=True,capture_output=True,text=True).stdout

    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()

    def setUp(self):
        self.t=tempfile.TemporaryDirectory();self.lab=proof.Lab(self.t.name, 'fixture-model')

    def tearDown(self):
        self.lab.stop();self.t.cleanup()

    def sign(self,message):
        return base64.b64encode(subprocess.run(['openssl','dgst','-sha256','-sign',str(self.priv)],input=message,capture_output=True,check=True).stdout).decode()

    def software_proof(self,method,manifest):
        binding=proof.digest(manifest)
        p={'method':method,'manifest_sha256':binding,'public_key':self.public,'key_id':proof.public_id(self.public)}
        if method=='secure-enclave':
            p.update(challenge=binding[:32],signature=self.sign(('ragnarok-chain:v1:'+binding[:32]).encode()))
        else:
            rp='software-fixture.example'
            raw=hashlib.sha256(rp.encode()).digest()+b'\x01'+b'\x00'*4
            cb=b'\x58'+bytes([len(raw)])+raw
            p.update(rp_id=rp,assertion='\n'.join([base64.b64encode(bytes.fromhex(binding)).decode(),rp,
                base64.b64encode(cb).decode(),self.sign(raw+bytes.fromhex(binding))])+'\n')
        return p

    def released(self):
        l=self.lab;l.create()
        l.event('hardware.run_approved',self.software_proof('yubikey',proof.run_manifest(l.bundle)))
        l.event('openai.response',{'rule':GOOD,'response_id':'resp_software_fixture'})
        l.complete(copy.deepcopy(GOOD))
        l.event('hardware.release_approved',self.software_proof('secure-enclave',proof.seal_manifest(l.bundle,l.bundle['head'])))
        l.event('release.allowed',{'artifact_sha256':proof.digest(GOOD),'scope':'demo artifact only; no production deployment'})
        return copy.deepcopy(l.bundle)

    def test_frozen_boundary_catches_claim(self):
        r=proof.checks(BAD);self.assertEqual(sum(c['passed'] for c in r),6)
        self.assertEqual([(c['input'],c['actual']) for c in r if not c['passed']],[(10000,10000)])

    def test_good_rule_all_pass(self): self.assertTrue(all(c['passed'] for c in proof.checks(GOOD)))

    def test_fixture_cannot_release(self):
        self.lab.create('false-claim',fixture=True);v=proof.verify_bundle(self.lab.bundle)
        self.assertTrue(v['integrity']);self.assertEqual(v['false_claims'],1);self.assertFalse(v['release_verified'])

    def test_two_signatures_and_checks_verify_under_fixture_keys(self):
        v=proof.verify_bundle(self.released());self.assertTrue(v['integrity']);self.assertTrue(v['release_verified'])

    def test_javascript_verifier_agrees_on_signed_and_tampered_fixtures(self):
        b=self.released();bad=copy.deepcopy(b);bad['nonce']='replay'
        script=('import {verify} from '+json.dumps((proof.ROOT/'dist/verify.js').as_uri())+';'
                'let s="";for await(const chunk of process.stdin)s+=chunk;'
                'console.log(JSON.stringify(await Promise.all(JSON.parse(s).map(verify))));')
        r=subprocess.run(['node','--input-type=module','-e',script],input=json.dumps([b,bad]),capture_output=True,text=True,check=True)
        good,invalid=json.loads(r.stdout)
        self.assertTrue(good['release_verified']);self.assertFalse(invalid['release_verified'])

    def test_tamper_breaks_chain(self):
        b=self.released();b['events'][0]['data']['mode']='fixture';self.assertFalse(proof.verify_bundle(b)['integrity'])

    def test_rehashed_forged_checks_rejected(self):
        b=self.released();next(e for e in b['events'] if e['kind']=='host.checks')['data']['results'][0]['actual']=999
        rehash(b);self.assertFalse(proof.verify_bundle(b)['integrity'])

    def test_rehashed_artifact_change_rejected(self):
        b=self.released();b['artifact']['comparison']='>';rehash(b);self.assertFalse(proof.verify_bundle(b)['release_verified'])

    def test_replayed_run_signature_rejected(self):
        b=self.released();b['nonce']='different';self.assertFalse(proof.verify_bundle(b)['release_verified'])

    def test_replayed_release_signature_rejected(self):
        b=self.released();next(e for e in b['events'] if e['kind']=='hardware.release_approved')['data']['challenge']='0'*32
        rehash(b);self.assertFalse(proof.verify_bundle(b)['release_verified'])

    def test_wrong_public_pin_rejected(self):
        b=self.released();next(e for e in b['events'] if e['kind']=='hardware.run_approved')['data']['key_id']='0'*64
        rehash(b);self.assertFalse(proof.verify_bundle(b)['release_verified'])

    def test_changed_frozen_contract_rejected(self):
        b=self.released();b['contract']['cases'][3]['expected']=10000
        self.assertFalse(proof.verify_bundle(b)['integrity'])

    def test_revocation_prevents_release(self):
        b=self.released();b['events'].insert(-1,{'at':'fixture','kind':'operator.revoked','data':{}});rehash(b)
        self.assertFalse(proof.verify_bundle(b)['release_verified'])

    def test_release_requires_immediately_preceding_seal(self):
        b=self.released();b['events'].insert(-1,{'at':'fixture','kind':'something.changed','data':{}});rehash(b)
        self.assertFalse(proof.verify_bundle(b)['release_verified'])

    def test_production_cannot_skip_approval(self):
        self.lab.create()
        self.assertEqual(self.lab.status,'awaiting_approval')
        with self.assertRaises(ValueError):self.lab.launch('seal','secure-enclave')
        with self.assertRaises(ValueError):self.lab.launch('authorize','secure-enclave')

    def test_force_stop_kills_active_worker_and_revokes_completion(self):
        l=self.lab;l.create();epoch=l.epoch
        result=[]
        def worker():
            try:l.command([sys.executable,'-c','import time;time.sleep(30)'],epoch)
            except ValueError:result.append('stopped')
        t=threading.Thread(target=worker);t.start()
        deadline=time.monotonic()+5
        while l.child is None and time.monotonic()<deadline:time.sleep(.01)
        child=l.child;self.assertIsNotNone(child);l.stop();t.join(5)
        self.assertFalse(t.is_alive());self.assertIsNotNone(child.poll());self.assertNotEqual(epoch,l.epoch)
        self.assertEqual(l.status,'stopped');self.assertTrue(result)

    def test_late_hardware_completion_cannot_restart_stopped_run(self):
        l=self.lab;l.create();started=threading.Event();release=threading.Event()
        def hardware(*args):started.set();release.wait(5);return {}
        with mock.patch.object(l,'hardware',side_effect=hardware):
            l.launch('authorize','yubikey');self.assertTrue(started.wait(2));l.stop();release.set();time.sleep(.1)
        self.assertEqual(l.status,'stopped');self.assertFalse(any(e['kind']=='agent.started' for e in l.bundle['events']))

    def test_invalid_model_rule_not_executed(self):
        for r in [dict(GOOD, shell='rm'),dict(GOOD,rate_bps=True),dict(GOOD,comparison='exec'),dict(GOOD,claimed_passes=['unknown'])]:
            with self.assertRaises(ValueError):proof.valid_rule(r)

    def test_api_request_and_allowlisted_receipt(self):
        response={'status':'completed','id':'resp_fixture','model':'fixture-model','usage':{'input_tokens':5,'secret':'not-retained'},
                  'output':[{'type':'message','content':[{'type':'output_text','text':json.dumps(GOOD)}]}]}
        class Reply:
            headers={'x-request-id':'req_fixture'}
            def __enter__(self):return self
            def __exit__(self,*a):pass
            def read(self,*a):return json.dumps(response).encode()
        opener=mock.Mock();opener.open.return_value=Reply()
        with mock.patch.object(proof,'key',return_value='secret-fixture'),mock.patch.object(proof.urllib.request,'build_opener',return_value=opener):
            r=proof.api_call('fixture-model','repair')
        request=opener.open.call_args.args[0]
        self.assertEqual(request.full_url,'https://api.openai.com/v1/responses')
        self.assertFalse(json.loads(request.data)['store']);self.assertNotIn('secret-fixture',json.dumps(r));self.assertNotIn('secret',r['usage'])

    def test_http_csrf_host_and_export(self):
        server=proof.http.server.ThreadingHTTPServer(('127.0.0.1',0),proof.Handler);server.lab=self.lab
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        port=server.server_port
        def request(method,path,body=None,headers=None):
            c=http.client.HTTPConnection('127.0.0.1',port);c.request(method,path,body=body,headers=headers or {});r=c.getresponse();data=r.read();c.close();return r.status,data
        try:
            self.assertEqual(request('GET','/')[0],200)
            self.assertEqual(request('GET','/api/session',headers={'Host':'evil.example'})[0],403)
            self.assertEqual(request('POST','/api/create','{}')[0],403)
            headers={'Origin':'http://127.0.0.1:'+str(port),'X-Lab-Token':self.lab.token,'Content-Type':'application/json'}
            self.assertEqual(request('POST','/api/create',json.dumps({'fixture':True}),headers)[0],200)
            self.assertEqual(request('GET','/api/export')[0],200)
            for f in self.lab.runtime.rglob('*.json'):self.assertEqual(f.stat().st_mode&0o777,0o600)
        finally:server.shutdown();server.server_close();thread.join(2)


if __name__=='__main__':unittest.main(verbosity=2)
