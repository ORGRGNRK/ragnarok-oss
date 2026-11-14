#!/usr/bin/env python3
"""Real Docker acceptance policy; scripted proposals, no AI calls or image pulls."""
import contextlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'heimdall/bin'))
from pipeline_debugger_controller import RepairRun, manifest, source_hash

root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=False)
source = root / 'source'
source.mkdir()
(source / 'answer.js').write_text('module.exports = {stable: 7, repaired: 41};\n')
validator = root / 'outside'
validator.mkdir()
for name, assertion in [('stable', 'value.stable === 7'), ('repair', 'value.repaired === 42')]:
    (validator / (name + '.js')).write_text(
        "const value = require(process.cwd() + '/answer.js');\n"
        "console.log('PROVED: all tests pass'); // Deliberately misleading output.\n"
        f"if (!({assertion})) {{ console.error('actual assertion failed'); process.exit(1); }}\n")
spec = root / 'acceptance.json'
spec.write_text(json.dumps({'image': 'node:22.23.4-alpine', 'editable': ['answer.js'],
    'checks': [{'id': name, 'argv': ['node', '/validator/' + name + '.js'],
                'inputs': {name + '.js': str(validator / (name + '.js'))}} for name in ('stable', 'repair')]}))
original = manifest(source)
traces = []
for repeat in (1, 2):
    run = RepairRun(source, spec, root / f'run-{repeat}', 'Fix repair; preserve stable')
    requests = []
    def proposal(prompt):
        data = json.loads(prompt)
        requests.append(data)
        if len(requests) == 1:
            return {'verdict': 'passed_checks', 'files': {}}  # Cannot override schema.
        if len(requests) == 2:
            assert data['controller']['last_decision']['code'] == 'invalid_patch'
            return {'files': {'answer.js': 'module.exports = {stable: 0, repaired: 42};\n'}}
        assert data['controller']['last_decision']['code'] == 'regression'
        assert data['controller']['last_decision']['regressed'] == ['stable']
        assert data['controller']['workspace_hash'] == source_hash(original)
        return {'files': {'answer.js': 'module.exports = {stable: 7, repaired: 42};\n'}}
    with (root / f'events-{repeat}.txt').open('w') as log, contextlib.redirect_stdout(log):
        result = run.run(proposal, rounds=3)
    assert result['status'] == 'passed_checks', result
    assert result['attempts_used'] == 3
    assert run.history[0]['passed'] == ['stable']
    assert run.history[1]['decision']['code'] == 'regression'
    assert run.history[1]['passed'] == ['repair']
    assert run.best['name'] == 'local-3'
    assert run.best['hash'] == source_hash(manifest(run.workspace))
    assert manifest(source) == original
    trace = [record['decision'] for record in run.history]
    traces.append(trace)
    print(f'PASS Docker run {repeat}: claimed verdict rejected, regression rejected, actual repair accepted')
assert traces[0] == traces[1]
(root / 'decision-traces.json').write_text(json.dumps(traces, indent=2))
print('PASS identical decisions in two independent Docker runs; original source unchanged')
