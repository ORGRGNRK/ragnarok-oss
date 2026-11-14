#!/usr/bin/env python3
"""Exercise mixed runner/debugger records without a model or the real run store."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

runner = Path(__file__).resolve().parents[1] / 'bin/ragnarok-agent'
with tempfile.TemporaryDirectory(prefix='agent-list-check-') as folder:
    root = Path(folder)
    def record(rid, state, modified):
        path = root / rid / 'state.json'
        path.parent.mkdir()
        path.write_text(json.dumps(state))
        os.utime(path, (modified, modified))

    record('agent-old', {'id': 'agent-old', 'task': 'inspect older failure',
                        'status': 'completed', 'verdict': 'needs_you'}, 100)
    record('20261105-new', {'id': '20261105-new', 'name': 'Newest real run',
                           'status': 'done', 'who': 'codex', 'tools': 3,
                           'started': '2026-11-05T18:00:00-0800'}, 200)
    record('20261104-legacy', {'id': '20261104-legacy', 'name': 'Legacy Claude run',
                              'status': 'done', 'started': '2026-11-04T18:00:00-0800'}, 300)
    record('agent-empty', {'id': 'agent-empty', 'tools': None}, 50)
    record('invalid-array', ['not a run'], 400)
    record('invalid-object', {'unexpected': True}, 400)
    result = subprocess.run([str(runner), 'list'], capture_output=True, text=True,
                            env=dict(os.environ, RAGNAROK_AGENTS_DIR=folder), timeout=10)
    assert result.returncode == 0, result.stderr
    lines = result.stdout.splitlines()
    assert len(lines) == 4, lines
    assert [line.split()[0] for line in lines] == [
        '20261105-new', '20261104-legacy', 'agent-old', 'agent-empty'], lines
    assert 'Unverified' in lines[2] and 'inspect older failure' in lines[2], lines[2]
    assert 'claude' in lines[1], lines[1]
    assert 'agent-empty' in lines[3], lines[3]
    assert len(list(root.glob('*/state.json'))) == 6, 'listing changed the run store'
    # Compile the actual Swift reader independently of the UI and private state.
    source = (runner.parents[1] / 'Sources/Heimdall/Agents.swift').read_text()
    model = source.split('struct AgentRun:', 1)[1].split('\n@MainActor', 1)[0]
    harness = root / 'main.swift'
    harness.write_text('import Foundation\nstruct AgentRun:' + model + r'''
let directory = CommandLine.arguments[1]
let runs = AgentRun.latest(in: directory)
precondition(runs.map(\.id) == ["20261105-new", "20261104-legacy", "agent-old", "agent-empty"])
precondition(runs[2].agent == "Unverified")
precondition(runs[1].agent == "claude")
precondition(AgentRun.latest(in: directory, limit: 1).map(\.id) == ["20261105-new"])
precondition(AgentRun.latest(in: directory, limit: 0).isEmpty)
precondition(AgentRun.latest(in: directory + "/missing").isEmpty)
print("PASS Swift reader orders before limiting and preserves legacy attribution")
''')
    binary = root / 'reader-check'
    subprocess.run(['swiftc', str(harness), '-o', str(binary)], check=True, timeout=60)
    subprocess.run([str(binary), folder], check=True, timeout=10)
print('PASS mixed run schemas, newest-first order, missing metadata, invalid records, read-only listing')
