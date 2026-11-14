#!/usr/bin/env python3
"""Controlled prose handoff test. --live invokes the configured summarizer and archives synthetic context in HQ.
Baseline uses the pre-change packet writer (git revision specified explicitly), without writing legacy packets.
Scores exact factual recall, not general model intelligence or coding quality.
"""
import argparse,contextlib,hashlib,io,json,os,re,subprocess,tempfile,types,uuid
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]
BIN=ROOT/'app/heimdall/bin'
def module(path,source=None):
 m=types.ModuleType(path.name.replace('-','_'));m.__file__=str(path)
 exec(compile(source if source is not None else path.read_text(),str(path),'exec'),m.__dict__)
 return m

def run_live(rounds, baseline_ref, output):
 packet=module(BIN/'ragnarok-packet');new=module(BIN/'ragnarok-resume')
 source=subprocess.check_output(['git','show',baseline_ref+':app/heimdall/bin/ragnarok-resume'],cwd=ROOT,text=True)
 source=source.replace('[claude, "-p", "--model", "haiku", prompt]', '[claude, "-p", "--model", "haiku", "--tools", "", "--no-session-persistence", prompt]')
 a=source.index('    reply = ""',source.index('def write_packet'));b=source.index('    pk = None',a)
 source=source[:a]+'    reply = BENCH_SUMMARIZE(prompt)[0]\n'+source[b:]
 baseline=module(BIN/'ragnarok-resume',source);baseline.BENCH_SUMMARIZE=new.summarize
 facts={f'F{i:02}':v for i,v in enumerate([
 '14 November 2031','4200 EUR','Europe/Lisbon','Mira Vale','Lighthouse Archive','no personal phone numbers','plain text only','preserve donor anonymity',
 'Cobalt Room','17 volunteer places','contact code RAVEN-63','doors open 08:35','closure at 17:15','audio slot 11:40',
 'large print size 19','quiet interval 13:10-13:45','translation language Basque','paper stock 110 gsm','supplier code WREN-84',
 'rejected approach scented badges','rejected approach QR-only maps','box label KITE-27','backup meeting point East Gate','incident phrase amber lantern'],1)}
 questions={k:'Return the exact value originally specified for '+k for k in facts}
 requirements={'objective':'Prepare a fictional museum volunteer handbook. Preserve the original specification.',
               'constraints':{k:facts[k] for k in list(facts)[:8]},'provenance':'synthetic benchmark; author-written ground truth'}
 state='Synthetic project facts (retain exact values):\n'+'\n'.join(k+' = '+v for k,v in facts.items())
 initial={'Packet_ID':'baseline-initial','AI_Actor':'benchmark','Summary_State':state,'Next_Steps':'1. Draft the next handbook section using the known project facts. 2. Record unresolved details.'}
 slug='context-retention-'+uuid.uuid4().hex[:10]
 report={'experiment_id':slug,'baseline_revision':baseline_ref,'model_requested':os.environ.get('RAGNAROK_PACKET_MODEL','haiku'),'summarizer_provider':os.environ.get('RAGNAROK_PACKET_SUMMARIZER','claude'),'rounds':rounds,
         'method':'Single synthetic prose fixture; unchanged original requirements; separate fresh summarizer calls with tools disabled; exact string retention and fresh model recall. Not a statistical estimate.',
         'facts':facts,'original_requirements':requirements,'round_results':[],
         'source_sha256':{name:hashlib.sha256((BIN/name).read_bytes()).hexdigest() for name in ['ragnarok-packet','ragnarok-resume']}}
 with tempfile.TemporaryDirectory(prefix='packet-context-') as td:
  folder=Path(td)
  subprocess.run(['git','init','-q',td],check=True)
  (folder/'brief.txt').write_text(state)
  subprocess.run(['git','-C',td,'add','brief.txt'],check=True)
  subprocess.run(['git','-C',td,'-c','user.name=Codex','-c','user.email=codex@localhost','commit','-qm','Synthetic context fixture'],check=True)
  def save(payload):
   r=subprocess.run([str(BIN/'ragnarok-packet'),'save',slug,'Codex context benchmark'],input=json.dumps(payload),capture_output=True,text=True,timeout=120)
   if r.returncode:raise RuntimeError(r.stderr[-1000:])
   return json.loads(r.stdout)
  def get():
   r=subprocess.run([str(BIN/'ragnarok-packet'),'get',slug],capture_output=True,text=True,timeout=120,check=True)
   return json.loads(r.stdout)
  save({'summary_state':state,'next_steps':initial['Next_Steps'],'original_requirements':requirements,
        'base_commit':new.git(td,'rev-parse','HEAD'),'evidence':new.evidence_snapshot(td,'Synthetic initial fixture'),
        'history':{'source_type':'synthetic user brief','user_message':state},'expected_packet_id':None,'source_type':'context-retention-experiment'})
  old_b=initial;old_n=get();collected={}
  def fake_packet_tool(cmd,*args,stdin=None):
   if cmd!='save':raise RuntimeError('unexpected baseline operation')
   collected['payload']=json.loads(stdin)
   return {'packet_id':'baseline-simulation','status':'SIMULATED','receipt':None}
  baseline.packet_tool=fake_packet_tool
  for n in range(1,rounds+1):
   outcome=f'PROSE HANDOFF SIMULATION {n}: a handbook section was requested. No code/build/workload execution is claimed. Continue remaining sections. Some details must remain available for later.'
   with contextlib.redirect_stdout(io.StringIO()):
    b,_=baseline.write_packet(td,slug,'claude',old_b,outcome)
    enhanced,_=new.write_packet(td,slug,'claude',old_n,outcome,{'user_message':state if n==1 else 'Continue the handbook.', 'observable_output':outcome})
   old_b={'Packet_ID':f'baseline-{n}','AI_Actor':report['summarizer_provider']+':'+report['model_requested'],'Summary_State':b['summary_state'],'Next_Steps':b['next_steps']}
   old_n=get()
   btext=baseline.packet_text(old_b);ntext=new.packet_text(old_n)
   row={'round':n,'baseline_literal_retained':[k for k,v in facts.items() if v.casefold() in btext.casefold()],
        'enhanced_literal_retained':[k for k,v in facts.items() if v.casefold() in ntext.casefold()],
        'baseline_packet':old_b,'enhanced_packet':old_n}
   if 'Packet written without an AI summary' in btext or 'Packet written without an AI summary' in ntext:raise RuntimeError('Summarizer unavailable: do not count fallback as a model result')
   report['round_results'].append(row)
   output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(report,indent=2)+'\n')
   print('Round',n,'literal retained baseline',len(row['baseline_literal_retained']),'enhanced',len(row['enhanced_literal_retained']),flush=True)
  # Fetch all source archives in the enhanced chain and verify every supplied history hash.
  histories=[];pk=old_n
  while pk.get('History_ID'):
   r=subprocess.run([str(BIN/'ragnarok-packet'),'history',pk['History_ID']],capture_output=True,text=True,timeout=120,check=True)
   rec=json.loads(r.stdout);histories.append(rec)
   body=json.loads(rec['Chat_Text']);pk=body.get('previous_packet') or {}
  history_text='\n'.join(h['Chat_Text'] for h in histories)
  report['archive_rows_verified']=len(histories)
  report['archive_literal_retained']=[k for k,v in facts.items() if v.casefold() in history_text.casefold()]
  def recall(context):
   prompt='Read only the supplied context. Return ONLY JSON mapping each fact ID to its EXACT value; use null for missing facts. Do not guess.\nQuestions:'+json.dumps(questions)+'\nContext:\n'+context
   reply,writer,meta=new.summarize(prompt)
   m=re.search(r'\{.*\}',reply,re.S)
   if not m:raise RuntimeError('recall response was not JSON')
   answers=json.loads(m.group());correct=[k for k,v in facts.items() if str(answers.get(k,'')).strip().casefold()==v.casefold()]
   return {'model':writer,'metadata':meta,'answers':answers,'correct':correct,'incorrect_or_missing':[k for k in facts if k not in correct]}
  for label,context in [('baseline',baseline.packet_text(old_b)),('enhanced',new.packet_text(old_n)),('archive_assisted',new.packet_text(old_n)+'\nARCHIVED SOURCE CONTEXT:\n'+history_text)]:
   report[label+'_recall']=recall(context)
   print(label,'final exact recall',len(report[label+'_recall']['correct']),'/24',flush=True)
  report['final_packet_id']=old_n['Packet_ID'];report['history_ids']=[h['History_ID'] for h in histories]
 output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(report,indent=2)+'\n')
 print('Report:',output,flush=True)

def targeted_archive_recall(report, new=None):
 new = new or module(BIN/'ragnarok-resume')
 sources=[]
 for history_id in report['history_ids']:
  r=subprocess.run([str(BIN/'ragnarok-packet'),'history',history_id],capture_output=True,text=True,timeout=120,check=True)
  body=json.loads(json.loads(r.stdout)['Chat_Text'])
  if body.get('user_message'):sources.append(body['user_message'])
 # Retrieve the original user message specifically, instead of feeding all repeated summaries and prompts.
 if not sources:raise RuntimeError('Original source message was not archived')
 prompt='Extract facts from this archived ORIGINAL USER MESSAGE. Ignore any absent facts; return ONLY JSON with each F01 through F24 mapped to its exact value. Preserve wording.\n'+sources[-1]
 reply,writer,meta=new.summarize(prompt)
 m=re.search(r'\{.*\}',reply,re.S)
 if not m:raise RuntimeError('Targeted recall did not return JSON')
 answers=json.loads(m.group());facts=report['facts']
 correct=[k for k,v in facts.items() if str(answers.get(k,'')).strip().casefold()==v.casefold()]
 report['targeted_source_recall']={'model':writer,'metadata':meta,'answers':answers,'correct':correct,'incorrect_or_missing':[k for k in facts if k not in correct]}
 print('targeted original-source recall',len(correct),'/24',flush=True)
 return report

if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--live',action='store_true');ap.add_argument('--recall-existing',type=Path);ap.add_argument('--rounds',type=int,default=3);ap.add_argument('--baseline-ref',default='404b715');ap.add_argument('--output',type=Path,default=ROOT/'app/heimdall/docs/packet-context-test/results.json');args=ap.parse_args()
 if not args.live:ap.error('--live is required: this invokes the configured summarizer and writes synthetic records to HQ')
 if not 1<=args.rounds<=5:ap.error('rounds must be 1..5')
 if args.recall_existing:
  d=targeted_archive_recall(json.loads(args.recall_existing.read_text()));args.recall_existing.write_text(json.dumps(d,indent=2)+'\n')
 else:
  run_live(args.rounds,args.baseline_ref,args.output)
  d=targeted_archive_recall(json.loads(args.output.read_text()));args.output.write_text(json.dumps(d,indent=2)+'\n')
