#!/usr/bin/env python3
"""Real Docker gates. Uses installed images only; no model calls in these checks."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import time
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'heimdall/bin'))
from pipeline_debugger_controller import CommandRunner,DockerExecutor
root=Path(sys.argv[1]).resolve();root.mkdir(parents=True,exist_ok=False)
source=root/'source';source.mkdir();(source/'answer.js').write_text('module.exports = () => 41;\n')
validator=root/'validator';validator.mkdir()
script=validator/'check.js';script.write_text('''const fs=require('node:fs');const assert=require('node:assert/strict');
for (const p of ['/var/run/docker.sock','/source/.git','/root/.ssh']) assert(!fs.existsSync(p),p);
for (const p of ['/source/escaped','/validator/escaped']) { let denied=false;try{fs.writeFileSync(p,'bad')}catch(e){denied=true}assert(denied,p) }
console.log('readonly mounts and excluded host endpoints checked');
''')
runner=CommandRunner();executor=DockerExecutor(runner,'node:22.23.4-alpine','pipeline-gate-'+str(os.getpid()));executor.prepare()
result=executor.run(source,validator,['node','/validator/check.js'],10)
(root/'isolation.json').write_text(json.dumps(result,indent=2));assert result['status']=='succeeded',result
print('PASS real Docker readonly mounts and absent host endpoints')
result=executor.run(source,validator,['node','-e','setTimeout(()=>{},60000)'],.3)
(root/'timeout.json').write_text(json.dumps(result,indent=2));assert result['status']=='timed_out',result
print('PASS real Docker command timeout')
sleep=validator/'sleep.js';sleep.write_text('setTimeout(()=>{},60000);')
spec=root/'acceptance.json';spec.write_text(json.dumps({'image':'node:22.23.4-alpine','checks':[{'id':'slow','argv':['node','/validator/sleep.js'],'inputs':{'sleep.js':str(sleep)}}]}))
engine=Path(__file__).resolve().parents[2]/'heimdall/bin/heimdall-debugger.py'
with (root/'cancel-output.txt').open('w') as log:
 p=subprocess.Popen([sys.executable,str(engine),'repair','fixture','--cwd',str(source),'--acceptance',str(spec),'--evidence',str(root/'cancel-run'),'--provider','ollama','--model','fixture-model'],stdout=log,stderr=log)
 for _ in range(100):
  found=subprocess.run(['docker','ps','--filter','label=pipeline-debugger.run','--format','{{.Names}}'],capture_output=True,text=True,timeout=5).stdout
  if 'pipeline-' in found:break
  if p.poll() is not None:raise AssertionError('controller exited before cancellation')
  time.sleep(.1)
 else:raise AssertionError('container did not start')
 p.terminate();p.wait(timeout=20)
result=json.loads((root/'cancel-run/result.json').read_text());assert result['status']=='cancelled',result
print('PASS SIGTERM records cancelled run')
remaining=subprocess.run(['docker','ps','-a','--filter','label=pipeline-debugger.run','--format','{{.Names}}'],capture_output=True,text=True,timeout=5).stdout
assert not remaining,remaining
assert (source/'answer.js').read_text()=='module.exports = () => 41;\n'
print('PASS no run-owned containers remain and original source unchanged')
