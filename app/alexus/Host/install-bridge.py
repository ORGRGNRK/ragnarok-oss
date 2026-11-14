#!/usr/bin/env python3
"""Install a private, token-authenticated, pinned-TLS phone bridge. No devices are auto-approved."""
import os,plistlib,subprocess,sys
from pathlib import Path
home=Path.home();app=home/'Applications/ALEXUS.app';script=app/'Contents/Resources/remote_host.py'
if not script.is_file():raise SystemExit('Install the current Mac app first.')
label='co.rgnrk.alexus.owner-bridge';unit=home/'Library/LaunchAgents'/f'{label}.plist';state=home/'.alexus/app';state.mkdir(parents=True,exist_ok=True,mode=0o700)
for name in ['bridge.log','bridge-error.log']:
 fd=os.open(state/name,os.O_CREAT|os.O_APPEND|os.O_WRONLY,0o600);os.close(fd)
data={'Label':label,'ProgramArguments':[sys.executable,'-I','-B',str(script)],'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':15,
      'EnvironmentVariables':{'ALEXUS_SOURCE_ROOT':str(Path(__file__).resolve().parents[1]),'ALEXUS_BUNDLE':str(app),'PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'},
      'StandardOutPath':str(state/'bridge.log'),'StandardErrorPath':str(state/'bridge-error.log')}
unit.write_bytes(plistlib.dumps(data));unit.chmod(0o600)
subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(unit)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(unit)],check=True)
print('Installed private TLS bridge on port 8849. No device has been paired or given editing authority.')
