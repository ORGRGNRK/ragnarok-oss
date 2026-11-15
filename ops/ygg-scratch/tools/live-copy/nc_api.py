"""Tiny NocoDB client. Reads the token from ~/.config/yggdrasil-v2/secrets.env; never prints it."""
import os, json, urllib.request, urllib.error
F=os.environ.get("YGG_SECRETS") or os.path.expanduser("~/.config/yggdrasil-v2/secrets.env")  # YGG_SECRETS: staging override
ENV={}
for l in open(F):
    if "=" in l and not l.startswith("#"):
        k,v=l.rstrip("\n").split("=",1); ENV[k]=v
BASE=ENV["NOCODB_URL"]
def req(method,path,body=None,ok=(200,201)):
    h={"Content-Type":"application/json","xc-token":ENV["NOCODB_API_TOKEN"]}
    r=urllib.request.Request(BASE+path,data=json.dumps(body).encode() if body is not None else None,headers=h,method=method)
    try:
        with urllib.request.urlopen(r,timeout=120) as resp:
            raw=resp.read(); return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path} -> {e.code}: {e.read()[:600]!r}")
