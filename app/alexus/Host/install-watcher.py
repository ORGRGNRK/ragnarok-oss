#!/usr/bin/env python3
"""Install the owner's stage-only Mac watcher. Does not grant apply authority."""
import json,os,plistlib,subprocess,sys
from pathlib import Path
home=Path.home();state=home/'.alexus/app';state.mkdir(parents=True,exist_ok=True,mode=0o700)
app=home/'Applications/ALEXUS.app';script=app/'Contents/Resources/alexus_host.py'
source=Path(__file__).resolve().parents[1]
if not script.is_file():raise SystemExit('Install the Mac app before its watcher.')
# Wrapper uses a fixed command; no shell interpolation of queue contents.
wrapper=state/'watch.py'
wrapper.write_text('import subprocess\nsubprocess.run('+repr([sys.executable,'-I','-B',str(script)])+',input=b\'{"command":"watch"}\',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n');wrapper.chmod(0o700)
label='co.rgnrk.alexus.repair-stage';unit=home/'Library/LaunchAgents'/f'{label}.plist'
data={'Label':label,'ProgramArguments':[sys.executable,'-I','-B',str(wrapper)],'RunAtLoad':True,'StartInterval':60,
      'EnvironmentVariables':{'ALEXUS_SOURCE_ROOT':str(source),'ALEXUS_BUNDLE':str(app),'PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'}}
unit.write_bytes(plistlib.dumps(data));unit.chmod(0o600)
subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(unit)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(unit)],check=True)
(state/'watcher.json').write_text(json.dumps({'role':'stage-only','interval_seconds':60,'apply_authority':False})+'\n');(state/'watcher.json').chmod(0o600)
print('Installed stage-only watcher. Every application still requires both fresh hardware proofs.')
