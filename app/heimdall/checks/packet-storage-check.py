#!/usr/bin/env python3
"""Non-destructive integration checks, using uniquely named synthetic projects in HQ."""
import contextlib,hashlib,io,json,subprocess,tempfile,types,uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];BIN=ROOT/'app/heimdall/bin'
def module(name):
 p=BIN/name;m=types.ModuleType(name);m.__file__=str(p);exec(compile(p.read_text(),str(p),'exec'),m.__dict__);return m
P=module('ragnarok-packet');R=module('ragnarok-resume');checks=[]
def check(name,condition):
 checks.append({'name':name,'pass':bool(condition)});print(('PASS ' if condition else 'FAIL ')+name,flush=True)
 if not condition:raise AssertionError(name)
def call(name,**args):
 h=P.HQ('Codex storage check')
 try:
  with contextlib.redirect_stderr(io.StringIO()):
   try:return h.tool(name,**args)
   except SystemExit:return {'refused':True}
 finally:h.close()
def rows(table,slug):return call('list_records',table=table,filter={'Project_Slug':slug},limit=1000)['records']
slug='packet-storage-test-'+uuid.uuid4().hex[:10]
req=json.dumps({'objective':'synthetic storage verification','constraints':['keep original']})
payload=dict(project_slug=slug,expected_packet_id=None,packet_id='TEST-'+uuid.uuid4().hex,summary_state='Synthetic fixture',next_steps='1. Preserve fixture.',original_requirements=req,evidence_json='{}',base_commit='',history_text=' \n'+json.dumps({'chat':'A synthetic retained message.'})+'\n ',source_type='storage-integration-test')
a=call('replace_switch_packet',**payload);check('initial atomic save',a.get('status')=='CONFIRMED')
initial=rows('Switch_Packets',slug)[0];n=len(rows('Packet_Chat_History',slug))
# A duplicate packet ID fails AFTER history insertion and superseding, exercising real rollback.
b=call('replace_switch_packet',**{**payload,'expected_packet_id':payload['packet_id']})
check('injected duplicate packet failure refused',b.get('refused'))
check('failed transaction preserves active target',rows('Switch_Packets',slug)[0]['Resume_Target'] is True)
check('failed transaction rolls back new history',len(rows('Packet_Chat_History',slug))==n)
def compete(i):return call('replace_switch_packet',**{**payload,'expected_packet_id':payload['packet_id'],'packet_id':'TEST-'+uuid.uuid4().hex,'summary_state':f'Synthetic competing writer {i}'})
with ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(compete,[1,2]))
check('one concurrent writer wins; stale writer refused',sum(r.get('status')=='CONFIRMED' for r in results)==1 and sum(bool(r.get('refused')) for r in results)==1)
packets=rows('Switch_Packets',slug);active=[p for p in packets if p['Resume_Target']]
check('exactly one active packet after concurrency',len(active)==1)
c=call('update_records',table='Switch_Packets',records=[{'Id':active[0]['Id'],'Original_Requirements':'changed'}])
check('database rejects original-requirement changes',c.get('refused'))
history=rows('Packet_Chat_History',slug)[0]
c=call('update_records',table='Packet_Chat_History',records=[{'Id':history['Id'],'Chat_Text':'changed'}])
check('database rejects archive edits',c.get('refused'))
check('archive preserves leading and trailing whitespace',history['Chat_Text']==payload['history_text'])
check('archived bytes match stored SHA256',hashlib.sha256(history['Chat_Text'].encode()).hexdigest()==history['Chat_SHA256'])
with contextlib.redirect_stderr(io.StringIO()):
 try:P.save(slug,'Codex storage check',{'summary_state':'x'*20001,'next_steps':'next'});rejected=False
 except SystemExit:rejected=True
check('oversized summary rejected without silent truncation',rejected)
with tempfile.TemporaryDirectory() as folder:
 f=Path(folder)/'fact.txt';f.write_text('before')
 pk={'Evidence_JSON':json.dumps({'files':[{'path':'fact.txt','sha256':hashlib.sha256(b'before').hexdigest()}]})}
 R.check_packet_evidence(folder,pk);f.write_text('after')
 with contextlib.redirect_stderr(io.StringIO()):
  try:R.check_packet_evidence(folder,pk);rejected=False
  except SystemExit:rejected=True
 check('resume rejects changed evidence bytes',rejected)
check('receipt chains remain intact',call('verify_receipts')['intact'])
out=ROOT/'app/heimdall/docs/packet-context-test/storage-checks.json';out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps({'project_slug':slug,'checks':checks},indent=2)+'\n')
print('Saved',out,flush=True)
