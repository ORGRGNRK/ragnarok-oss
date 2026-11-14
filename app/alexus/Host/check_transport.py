#!/usr/bin/env python3
"""Native URLSession against an ephemeral loopback TLS server, using synthetic bootstrap data."""
import base64,hashlib,json,os,plistlib,secrets,socket,ssl,subprocess,sys,tempfile,time
from pathlib import Path
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as temp:
 folder=Path(temp);state=folder/'state';(state/'remote').mkdir(parents=True);source=folder/'source';source.mkdir();(source/'check.sh').write_text('exit 0')
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 token=secrets.token_urlsafe(32)
 (state/'remote/bootstrap.json').write_text(json.dumps({'token_sha256':hashlib.sha256(token.encode()).hexdigest(),'expires_unix':int(time.time())+300,'challenge':base64.b64encode(secrets.token_bytes(32)).decode()}))
 env=dict(os.environ,ALEXUS_STATE=str(state),ALEXUS_SOURCE_ROOT=str(source),ALEXUS_BRIDGE_BIND='127.0.0.1',ALEXUS_BRIDGE_PORT=str(port),ALEXUS_TLS_FIXTURE_DIAGNOSTICS='1')
 diagnostic=(folder/'tls-errors.log').open('wb')
 server=subprocess.Popen([os.environ.get('ALEXUS_TLS_PYTHON',sys.executable),'-I',str(root/'Host/remote_host.py')],env=env,stdout=subprocess.DEVNULL,stderr=diagnostic,start_new_session=True)
 try:
  for _ in range(100):
   if server.poll() is not None:raise RuntimeError('fixture TLS server exited')
   if (state/'remote/server.json').exists():
    try:
     with socket.create_connection(('127.0.0.1',port),timeout=.1):break
    except OSError:pass
   time.sleep(.05)
  meta=json.loads((state/'remote/server.json').read_text());meta.update(endpoint=f'https://127.0.0.1:{port}',rp='work.example.com',pairing_token='',pairing_expires_unix=0)
  bundle=folder/'TransportProbe.app';(bundle/'Contents/MacOS').mkdir(parents=True)
  (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'co.rgnrk.alexus.transport-fixture','CFBundleExecutable':'TransportProbe','CFBundlePackageType':'APPL','CFBundleVersion':'1'}))
  binary=bundle/'Contents/MacOS/TransportProbe'
  result=subprocess.run(['xcrun','swiftc','-D','ALEXUS_TRANSPORT_FIXTURE','-parse-as-library',str(root/'Sources/OwnerDevice.swift'),str(root/'Host/TransportProbe.swift'),'-o',str(binary),'-framework','AuthenticationServices','-framework','LocalAuthentication','-framework','Security','-framework','CryptoKit'],capture_output=True,timeout=120)
  if result.returncode:raise RuntimeError('native probe did not compile')
  result=subprocess.run([str(binary)],input=json.dumps({'link':meta,'token':token}).encode(),capture_output=True,timeout=90)
  if result.returncode:
   diagnostic.flush();raise RuntimeError('native pinning probe failed: '+result.stdout.decode().strip()+'; '+(folder/'tls-errors.log').read_text()[-1000:])
  print(result.stdout.decode().strip())
 finally:
  server.terminate()
  try:server.wait(timeout=5)
  except subprocess.TimeoutExpired:server.kill();server.wait()
