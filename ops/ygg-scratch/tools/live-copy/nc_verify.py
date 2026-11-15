#!/usr/bin/env python3
"""Read everything back from NocoDB and compare with schema_spec + packet files. Writes ~/Yggdrasil-v2/step3-verification.md"""
import json, hashlib, os, datetime, subprocess
from nc_api import req, BASE
from schema_spec import TABLES, LINKS, FORMULAS
G=os.path.expanduser("~/Yggdrasil-v2/genesis")
out=[]; fails=[]
def P(s=""): out.append(s)
def sha(s): return hashlib.sha256(s.encode("utf-8")).hexdigest()
def chk(ok,msg):
    if not ok: fails.append(msg)
    return "PASS" if ok else "FAIL"
now=datetime.datetime.now().astimezone()
health=req("GET","/api/v1/health")
ver=req("GET","/api/v1/version") if True else {}
bases=req("GET","/api/v2/meta/bases")["list"]
base=[b for b in bases if b["title"]=="Yggdrasil"][0]
T={t["title"]:t["id"] for t in req("GET",f"/api/v2/meta/bases/{base['id']}/tables")["list"]}
P("# Step 3 verification -- NocoDB read-back"); P()
P(f"Run: {now:%Y-%m-%d %H:%M} PT (America/Los_Angeles). Every value below was read back from NocoDB's API after writing, not taken from what was sent.")
P(f"NocoDB: {BASE} (health: {health.get('message')}; version {ver.get('currentVersion', ver)}). Base: \"Yggdrasil\". Other bases present: {[b['title'] for b in bases if b['title']!='Yggdrasil']}"); P()
P("## 1. Tables and fields"); P()
expected_counts={"Config":6,"RAGNAROK State":4,"Alexus Identity":112}
P("| Table | Fields expected | Fields found | Field check | Records | Expected | Count check |"); P("|---|---|---|---|---|---|---|")
detail=[]
for name,spec in TABLES.items():
    if name not in T:
        P(f"| {name} | | MISSING | {chk(False,'missing table '+name)} | | | |"); continue
    cols={c["title"]:c for c in req("GET",f"/api/v2/meta/tables/{T[name]}")["columns"]}
    exp=[(f,u,o) for f,u,o in spec]+[(c,"Links",None) for p,ch,c,pf in LINKS if ch==name]+[(pf,"Links",None) for p,ch,c,pf in LINKS if p==name]+[(f,"Formula",None) for f,_ in FORMULAS.get(name,[])]
    probs=[]
    for f,u,o in exp:
        c=cols.get(f)
        if not c: probs.append(f"missing {f}"); continue
        got=c["uidt"]
        if u=="Links":
            if got not in ("Links","LinkToAnotherRecord"): probs.append(f"{f}: {got}")
        elif got!=u: probs.append(f"{f}: type {got}, expected {u}")
        if u in ("SingleSelect","MultiSelect"):
            opts=[x["title"] for x in (c.get("colOptions") or {}).get("options",[])]
            if opts!=list(o): probs.append(f"{f}: options {opts}")
        if u=="Formula" and (c.get("colOptions") or {}).get("error"): probs.append(f"{f}: formula error")
        if isinstance(o,dict) and o.get("unique") and not (c.get("unique") or (c.get("meta") or {}).get("unique")):
            detail.append(f"- {name}.{f}: unique flag not reported by NocoDB (the MCP enforces it in code anyway).")
    sysf={"Id","CreatedAt","UpdatedAt","nc_created_by","nc_updated_by","nc_order"}
    fks=[t for t,c in cols.items() if c["uidt"]=="ForeignKey"]
    extra=[t for t,c in cols.items() if t not in {e[0] for e in exp} and not c.get("system") and t not in sysf and c["uidt"]!="ForeignKey"]
    if fks: detail.append(f"- {name}: {len(fks)} hidden ForeignKey column(s) NocoDB adds to hold its link fields ({len(fks)} link(s) on this side). Expected; not user fields.")
    if extra: probs.append(f"unexpected fields {extra}")
    n=req("GET",f"/api/v2/tables/{T[name]}/records/count")["count"]
    e=expected_counts.get(name,0)
    P(f"| {name} | {len(exp)} | {len([1 for f,_,_ in exp if f in cols])} | {chk(not probs,name+': '+'; '.join(probs))} | {n} | {e} | {chk(n==e,f'{name} count {n}!={e}')} |")
    if probs: detail+= [f"- {name}: {p}" for p in probs]
P(); P("Field-level notes: " + ("none -- every field exists with the expected type and select options in order." if not detail else "")); [P(d) for d in detail]
P(); P(f"Tables in base: {len(T)} (expected {len(TABLES)}). Not created on purpose: Momentum (replaced by PhoneGrader context). Extra tables: {[t for t in T if t not in TABLES] or 'none'}"); chk(len(T)==len(TABLES),"table count")
def allrows(t):
    rows=[];off=0
    while True:
        r=req("GET",f"/api/v2/tables/{T[t]}/records?limit=100&offset={off}")
        rows+=r["list"]; off+=len(r["list"])
        if r.get("pageInfo",{}).get("isLastPage",True) or not r["list"]: return rows
P(); P("## 2. Document hashes (Config and RAGNAROK State)"); P()
P("Three-way check: SHA-256 of the packet file on disk = Content Hash stored in NocoDB = SHA-256 of the Content read back."); P()
P("| Table | Doc Name | Version | Status | Packet file | File SHA-256 | Stored hash | Read-back content hash | Result |"); P("|---|---|---|---|---|---|---|---|---|")
files={"Ruleset":"ruleset.md","Boot":"commands/boot.md","Resume":"commands/resume.md","Save":"commands/save.md","Switch":"commands/switch.md","End":"commands/end.md","Foundation":"state/foundation.md","Schema":"state/schema-v1.9.md","Workflow":"state/workflow.md","The Burn Declaration":"state/burn-declaration.md"}
for t in ("Config","RAGNAROK State"):
    rows=allrows(t)
    for r in rows:
        fp=files.get(r["Doc Name"]); fh=sha(open(os.path.join(G,fp),encoding="utf-8").read()) if fp else None
        rh=sha(r["Content"] or ""); ok=fh==r["Content Hash"]==rh
        P(f"| {t} | {r['Doc Name']} | {r['Version']} | {r['Status']} | {fp} | `{fh[:16]}...` | `{(r['Content Hash'] or '')[:16]}...` | `{rh[:16]}...` | {chk(ok,'hash '+r['Doc Name'])} |")
    names=sorted(r["Doc Name"] for r in rows); chk(len(names)==len(set(names)),f"duplicate names in {t}")
P(); P("Full hashes (for the MCP's first read receipt):"); P("```")
for n,fp in files.items(): P(f"{sha(open(os.path.join(G,fp),encoding='utf-8').read())}  {n}  ({fp})")
P("```")
P(); P("## 3. Alexus Identity (112 entries, field-by-field against alexus-identity.json)"); P()
A={e["source_id"]:e for e in json.load(open(os.path.join(G,"alexus-identity.json")))["entries"]}
rows=allrows("Alexus Identity"); mism=[]
def same_time(a,b):
    if not a and not b: return True
    try:
        pa=datetime.datetime.fromisoformat(a.replace("Z","+00:00")); pb=datetime.datetime.fromisoformat(str(b).replace("Z","+00:00"))
        if pb.tzinfo is None: pb=pb.replace(tzinfo=datetime.timezone.utc)
        return pa==pb
    except Exception: return False
seen=set()
for r in rows:
    e=A.get(r["Source Id"]); seen.add(r["Source Id"])
    if not e: mism.append(f"row Id {r['Id']}: unknown Source Id"); continue
    for f in ("Entry Label","Session Date","Voice Entry","the owner's Voice","Restored From"):
        if (r.get(f) or "")!=(e[f] or ""): mism.append(f"{e['Entry Label'][:40]}: {f} differs")
    if not same_time(e["source_created_time"],r.get("Source Created Time")): mism.append(f"{e['Entry Label'][:40]}: Source Created Time {r.get('Source Created Time')!r}")
P(f"- Rows read back: {len(rows)}; entries in file: {len(A)}; every file entry present: {chk(seen==set(A),'alexus set mismatch')}")
P(f"- Fields compared per row: Entry Label, Session Date, Voice Entry, the owner's Voice, Restored From, Source Created Time (as an instant). Mismatches: {len(mism)} -- {chk(not mism,'alexus mismatches')}")
for m in mism[:20]: P(f"  - {m}")
dup=[r for r in rows if r["Entry Label"]=="2026-05-22 — /end Alexus"]
P(f"- Known duplicate label \"2026-05-22 — /end Alexus\": {len(dup)} rows kept, as decided (both differ in content).")
P(f"- Combined SHA-256 of all Voice Entry + the owner's Voice text, file vs read-back: {chk(sha(''.join(A[k]['Voice Entry']+(A[k][chr(67)+'hris'+chr(39)+'s Voice'] or '') for k in sorted(A)))==sha(''.join((r['Voice Entry'] or '')+(r[chr(67)+'hris'+chr(39)+'s Voice'] or '') for r in sorted(rows,key=lambda r:r['Source Id']))),'alexus combined hash')}")
P(); P("## 4. Service"); P()
def sh(c): return subprocess.run(c,shell=True,capture_output=True,text=True).stdout.strip()
P(f"- systemctl --user is-active nocodb: {sh('systemctl --user is-active nocodb')}; is-enabled: {sh('systemctl --user is-enabled nocodb')} (quadlet units report 'generated'; autostart comes from [Install] WantedBy=default.target -> symlink {sh('ls /run/user/$(id -u)/systemd/generator/default.target.wants/ | grep nocodb')})")
P(f"- Listening: {sh(chr(115)+'s -ltnH | grep :8080')}")
P(f"- Linger: {sh('loginctl show-user $USER -p Linger')}")
P(f"- Image: {sh('podman inspect nocodb --format {{.ImageName}}')} @ {sh('podman image inspect docker.io/nocodb/nocodb:latest --format {{.Digest}}')}")
P(f"- Data volume: ~/Yggdrasil-v2/nocodb-data ({sh('ls ~/Yggdrasil-v2/nocodb-data | tr chr(10) chr(32)'.replace('chr(10)',chr(39)+chr(92)+'n'+chr(39)).replace('chr(32)',chr(39)+' '+chr(39)))})")
P(); P("## Result"); P()
P("**ALL CHECKS PASSED.**" if not fails else "**FAILURES:**\n"+"\n".join("- "+f for f in fails))
open(os.path.expanduser("~/Yggdrasil-v2/step3-verification.md"),"w").write("\n".join(out)+"\n")
print("fails",len(fails)); [print(" ",f) for f in fails]
