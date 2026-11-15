"""Scratch NocoDB client. Signs in with NC_ADMIN_EMAIL/NC_ADMIN_PASSWORD from ../.env and uses the
session JWT (xc-auth). Stores no token, prints no secret."""
import os, json, urllib.request, urllib.error
HERE=os.path.dirname(os.path.abspath(__file__))
ENV={}
for l in open(os.path.join(HERE,"..",".env")):
    if "=" in l and not l.startswith("#"):
        k,v=l.rstrip("\n").split("=",1); ENV[k]=v
BASE=f"http://127.0.0.1:{ENV.get('YGG_NC_PORT','8091')}"
def _raw(method,path,body=None,h=None):
    r=urllib.request.Request(BASE+path,data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type":"application/json",**(h or {})},method=method)
    try:
        with urllib.request.urlopen(r,timeout=120) as resp:
            raw=resp.read(); return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path} -> {e.code}: {e.read()[:600]!r}")
_tok=None
def token():
    global _tok
    if not _tok: _tok=_raw("POST","/api/v1/auth/user/signin",{"email":ENV["NC_ADMIN_EMAIL"],"password":ENV["NC_ADMIN_PASSWORD"]})["token"]
    return _tok
def req(method,path,body=None): return _raw(method,path,body,{"xc-auth":token()})
