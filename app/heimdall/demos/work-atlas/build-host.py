#!/usr/bin/env python3
"""Package reviewed public assets as a dependency-free Worker, with a logical R2 binding."""
import argparse,base64,json,mimetypes
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--public-directory',default='public');p.add_argument('--output',default='dist');a=p.parse_args()
root=Path(__file__).resolve().parent;source=root/a.public_directory;target=root/a.output
if source.resolve()==target.resolve():raise SystemExit('Input and output must be separate directories')
allowed={'index.html','app.js','style.css','catalog.json','brand.css','ragnarok.png','ragnarok-mark.png','ragnarok-favicon.png','ragnarok-touch.png'}
assert {p.name for p in source.iterdir()}==allowed
assets={}
for f in sorted(source.iterdir()):
 assets['/'+f.name]={'body':base64.b64encode(f.read_bytes()).decode(),'type':mimetypes.guess_type(f.name)[0] or 'application/octet-stream'}
assets['/app.js']['type']='text/javascript; charset=utf-8'
for route,name,kind in [('/owner-auth','owner-auth.html','text/html; charset=utf-8'),('/owner-auth.js','owner-auth.js','text/javascript; charset=utf-8'),('/owner-auth.css','owner-auth.css','text/css; charset=utf-8')]:
 assets[route]={'body':base64.b64encode((root/name).read_bytes()).decode(),'type':kind}
code='const ASSETS='+json.dumps(assets,separators=(',',':'))+';\nconst FALLBACK='+ (source/'catalog.json').read_text().strip()+';\n'+(root/'worker.mjs').read_text()
(target/'server').mkdir(parents=True,exist_ok=True);(target/'.openai').mkdir(exist_ok=True)
(target/'server/index.js').write_text(code)
manifest=json.loads((root/'.openai/hosting.json').read_text());assert manifest.get('r2')=='BUCKET' and 'static' not in manifest
(target/'.openai/hosting.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Built single-file Worker with nine reviewed assets and BUCKET storage binding.')
