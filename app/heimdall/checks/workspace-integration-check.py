#!/usr/bin/env python3
"""Verify the built workspace's private-host wiring, without reading private state."""
import ast
import hashlib
import plistlib
import subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[1]
companion = root.parent / 'alexus'
app = root / 'build/Heimdall.app'
resources = app / 'Contents/Resources'
with (app / 'Contents/Info.plist').open('rb') as handle:
    info = plistlib.load(handle)
assert Path(info['ALEXUSSourceRoot']).resolve() == companion.resolve()
for name in ('alexus_host', 'chat_host', 'remote_host', 'deployment_host'):
    original = (companion / f'Host/{name}.py').read_bytes()
    bundled = (resources / f'{name}.py').read_bytes()
    assert hashlib.sha256(original).digest() == hashlib.sha256(bundled).digest(), name
for name in ('Foundation.json', 'Ragnarok.png'):
    assert (resources / name).read_bytes() == (companion / 'Resources' / name).read_bytes()
assert (resources / 'EnclaveAuthenticator').is_file()
subprocess.run(['codesign', '--verify', '--strict', str(resources / 'EnclaveAuthenticator')], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
# Existing host policy remains scoped to companion source and the companion app.
host = (resources / 'alexus_host.py').read_text()
assert "ALLOWED={'Sources/Views.swift','Sources/Models.swift'}" in host
apply = next(node for node in ast.parse(host).body if isinstance(node, ast.FunctionDef) and node.name == 'apply')
install_destination = next(node.value for node in ast.walk(apply)
    if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'destination' for t in node.targets))
assert ast.unparse(install_destination) == "HOME / 'Applications/ALEXUS.app'"
print('PASS shared host/resource bytes, original source root, signed helper/app and companion repair scope')
