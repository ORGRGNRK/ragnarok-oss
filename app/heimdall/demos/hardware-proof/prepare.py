#!/usr/bin/env python3
"""Build the native helper and deterministic reviewer assets. Never enrolls or prompts for hardware."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile
import proof

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--native', action='store_true', help='Compile and sign the native helper on macOS')
a = p.parse_args()
root = Path(__file__).resolve().parent
if a.native:
    helper = root/'.runtime/ChainAuthenticator'
    helper.parent.mkdir(exist_ok=True, mode=0o700)
    subprocess.run(['xcrun', 'swiftc', str(root/'native/ChainAuthenticator.swift'), '-o', str(helper)], check=True)
    identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, check=True)
    found = re.search(r'([A-F0-9]{40}) "Apple Development:', identities.stdout)
    identity = os.getenv('RAGNAROK_SIGN_IDENTITY') or (found.group(1) if found else '-')
    subprocess.run(['codesign', '--force', '--timestamp=none', '--identifier', 'co.rgnrk.heimdall.chain-auth',
                    '-s', identity, str(helper)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(helper)], check=True)
    print('Native helper compiled and signature checked. Hardware signing remains Unverified until a touch.')
with tempfile.TemporaryDirectory() as t:
    lab = proof.Lab(t)
    lab.create('false-claim', fixture=True)
    (root/'dist/evidence.json').write_bytes(proof.canonical(lab.bundle))
with zipfile.ZipFile(root/'dist/reviewer.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for name in ['proof.py', 'prepare.py', 'verify_test.py', 'README.md', 'native/ChainAuthenticator.swift',
                 'dist/verify.js', 'dist/index.html', 'dist/app.js', 'dist/style.css', 'dist/brand.css',
                 'dist/ragnarok.png', 'dist/ragnarok-mark.png', 'dist/ragnarok-favicon.png',
                 'dist/ragnarok-touch.png', 'dist/evidence.json']:
        if (root/name).is_file(): z.write(root/name, name)
print('Labeled offline control and reviewer kit generated. No credentials or private key references included.')
