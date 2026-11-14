#!/usr/bin/env python3
"""Check that speculative AI findings cannot silently become accepted logging work."""
import copy
import importlib.machinery
import importlib.util
from pathlib import Path

path = Path(__file__).resolve().parents[1] / 'bin/ragnarok-logging-audit'
loader = importlib.machinery.SourceFileLoader('logging_audit', str(path))
spec = importlib.util.spec_from_loader(loader.name, loader)
audit = importlib.util.module_from_spec(spec)
loader.exec_module(audit)
coverage = [{'file': 'Sources/Heimdall/Test.swift', 'ranges': [[10, 20]]}]
f = dict(id='A1', file=coverage[0]['file'], line=12, domain='process', observed='catch returns nil',
         impact='Unverified', decision='Log', reason='Lost error', safe_fields=['exit_code'],
         verification='Inject a launch failure; check one sanitized event')
first = audit.validate({'findings': [copy.deepcopy(f)]}, coverage)
assert first[0]['decision'] == 'Unverified'
missing = audit.validate({'findings': []}, coverage, first)
assert missing[0]['decision'] == 'Unverified'
assert audit.validate({'findings': [f]}, coverage, first)[0]['decision'] == 'Log'
for altered in [dict(f, line=21), dict(f, file='../../private'), dict(f, decision='Verified'), dict(f, observed='')]:
    try:
        audit.validate({'findings': [altered]}, coverage)
    except ValueError:
        pass
    else:
        raise AssertionError('invalid evidence accepted')
for altered in [dict(f, line=13), dict(f, id='NEW')]:
    try:
        audit.validate({'findings': [altered]}, coverage, first)
    except ValueError:
        pass
    else:
        raise AssertionError('verifier invented a candidate or changed its location')
print('PASS: speculative, omitted, invalid and invented findings handled')

# Verify that the saved prompts, decisions and display survive the two-pass pipeline.
import contextlib
import io
import json
import sys
import tempfile
from unittest.mock import patch

with tempfile.TemporaryDirectory() as tmp:
    dest = Path(tmp) / 'audit'
    responses = [
        {'findings': [copy.deepcopy(f)], 'limitations': ['unknown']},
        {'findings': [], 'limitations': ['unknown']},
    ]
    with patch.object(audit, 'snapshot', return_value=({}, 'numbered fixture evidence', coverage)), \
         patch.object(audit, 'ask', side_effect=responses) as ask, \
         patch.object(sys, 'argv', ['audit', '--output', str(dest)]), \
         contextlib.redirect_stdout(io.StringIO()):
        audit.main()
    assert ask.call_count == 2
    assert 'Unverified' in ask.call_args_list[1].args[0]
    assert json.loads((dest / 'verified.json').read_text())['findings'][0]['decision'] == 'Unverified'
    assert 'unknown' not in (dest / 'report.md').read_text().lower()
    assert (dest.stat().st_mode & 0o777) == 0o700
    assert all((p.stat().st_mode & 0o777) == 0o600 for p in dest.iterdir())
print('PASS: two-pass prompts, omitted findings, Unverified display and private artifacts')
