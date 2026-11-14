#!/usr/bin/env python3
"""Validate evidence boundaries and publication contents; does not run project source."""
import argparse
import hashlib
import json
from pathlib import Path
import re

root=Path(__file__).resolve().parent
parser=argparse.ArgumentParser();parser.add_argument('--public-directory',default='dist');args=parser.parse_args()
public=root/args.public_directory
data=json.loads((public/'catalog.json').read_text())
ids=[p['id'] for p in data['projects']]
assert len(ids)==len(set(ids)), 'duplicate project identity'
assert data['coverage']['local_catalog_entries']+data['coverage']['archive_catalog_entries']==len(ids)
assert data['coverage']['server_archive']['mount_verified_read_only'] is True
for p in data['projects']:
    assert p['runtime']=='Unverified', 'runtime promotion requires separate evidence'
    if p['kind']=='archive':
        assert not p['checks'] and p['archive_evidence']['contents_extracted'] is False
    for c in p['checks']:
        assert c['scope'] and c['command'] and c['files']
        assert c['result']!='passed' or c['source_matches'] is True
        for f in c['files']:
            assert re.fullmatch('[0-9a-f]{64}',f['sha256'])
assert sum(c['cases'] for p in data['projects'] for c in p['checks'] if c['result']=='passed')==data['coverage']['verification_cases']
allowed={'index.html','app.js','style.css','catalog.json','brand.css','ragnarok.png','ragnarok-mark.png','ragnarok-favicon.png','ragnarok-touch.png'}
assert {p.name for p in public.iterdir()}==allowed, 'unreviewed publication asset'
raw=(public/'catalog.json').read_text()
for forbidden in ['1Password','Emergency Kit','PRIVATE KEY','credential_id','secure-enclave.reference','KEYS AND SHIT','tblwkL3']:
    assert forbidden not in raw, 'private material in catalog'
assert not re.search(r'(?:sk-proj-|ghp_|AKIA)[A-Za-z0-9_-]{12,}',raw)
print(f"Validated {len(ids)} entries, scoped check records, archive boundaries and {len(allowed)} publication assets.")
