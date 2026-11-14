#!/usr/bin/env python3
"""Copy Heimdall's existing app icon and shared presentation to both static sites. No creative edits."""
import hashlib
from pathlib import Path
import shutil
import subprocess

demos=Path(__file__).resolve().parent
icon=demos.parent/'Resources/AppIcon.png'
for site in ['hardware-proof','work-atlas']:
    dist=demos/site/'dist'
    shutil.copy2(demos/'brand.css',dist/'brand.css')
    shutil.copy2(icon,dist/'ragnarok.png')
    for name,size in [('ragnarok-mark.png',128),('ragnarok-favicon.png',32),('ragnarok-touch.png',180)]:
        subprocess.run(['sips','-z',str(size),str(size),str(icon),'--out',str(dist/name)],capture_output=True,check=True)
print('Copied the original 1024 px icon and three resized web versions to each site.')
print('Original icon SHA-256:',hashlib.sha256(icon.read_bytes()).hexdigest())
