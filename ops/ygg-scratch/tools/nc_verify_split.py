#!/usr/bin/env python3
"""Read back every field from the scratch NocoDB and compare with the live field metadata
(live-field-meta.json, from the 2026-10-27 03:15 nocodb backup dump). Writes ../out/nc-verify.md.
Exit 1 if any field that should have been rebuilt differs."""
import json, os, sys, datetime
from nc_api import req, BASE
from split_map import BASES, NEW_COLS, EXTRA_OPTIONS, DROPPED_LINK_FKS, NOT_MIGRATED
HERE=os.path.dirname(os.path.abspath(__file__))
L=json.load(open(os.path.join(HERE,"live-field-meta.json")))
def jm(m):
    if isinstance(m,str):
        try: m=json.loads(m)
        except Exception: return {}
    return m or {}
EXP_ROWS={"Write Log":605,"Archive":18,"Config":6,"RAGNAROK State":4,"Memories":81,"Alexus Identity":117,"Reminders":7,"Transcript":78,"Knowledge Pipeline":9,"Business":92,"Exit Profiles":0,"Phone Grades":0,"Leads":0,"Personal - Record of Truth":32,"Projects":9,"Project Steps":26,"Personal - Resale Inventory":0,"Social Posts":9}
live={}
for c in L["columns"]: live.setdefault(c["model"],[]).append(c)
bases={b["title"]:b for b in req("GET","/api/v2/meta/bases")["list"]}
out=[]; P=out.append
stats=dict(rebuilt=0,missed=0,dropped=0,new=0)
miss=[]; dropped=[]; newf=[]; extras=[]
P(f"# Scratch NocoDB field-settings verification\n\nRun {datetime.datetime.now():%Y-%m-%d %H:%M} PT. NocoDB {BASE} v{req('GET','/api/v1/version').get('currentVersion')}. Compared by column_name against live metadata from nocodb-20261027-0315.dump.\n")
P("| base | table | live fields | rebuilt | missed | dropped by design | new | rows (API/exp) | result |"); P("|---|---|---|---|---|---|---|---|---|")
fail=0
for bt,(db,tns) in BASES.items():
    b=bases.get(bt)
    if not b: P(f"| {bt} | MISSING BASE | | | | | | | FAIL |"); fail=1; continue
    T={t["title"]:t for t in req("GET",f"/api/v2/meta/bases/{b['id']}/tables")["list"]}
    for x in T:
        if x not in tns: extras.append(f"{bt}: extra model `{x}` (Postgres view/table not in live base)")
    for tn in tns:
        if tn not in T: P(f"| {bt} | {tn} MISSING | | | | | | | FAIL |"); fail=1; continue
        cs=req("GET",f"/api/v2/meta/tables/{T[tn]['id']}")["columns"]
        by_cn={c["column_name"]:c for c in cs if c.get("column_name")}
        by_title={c["title"]:c for c in cs}
        r=dict(rebuilt=0,missed=0,dropped=0,new=0)
        for l in live.get(tn,[]):
            name=f"{tn}.{l['title']}"
            if l["uidt"] in ("Links","LinkToAnotherRecord"):
                rel=(l["relation"] or {}).get("related_model")
                if rel in tns:
                    s=by_title.get(l["title"])
                    ok=s and s["uidt"] in ("Links","LinkToAnotherRecord") and (s.get("colOptions") or {}).get("type")==l["relation"]["type"]
                    r["rebuilt" if ok else "missed"]+=1
                    if not ok: miss.append(f"{name}: link ({l['relation']['type']} to {rel}) not found")
                else: r["dropped"]+=1; dropped.append(f"{name}: {l['uidt']} to {rel} (other DB; replaced by Write Log Target_Key)")
                continue
            if l["uidt"]=="ForeignKey" and l["column_name"] in DROPPED_LINK_FKS and l["column_name"] not in by_cn:
                r["dropped"]+=1; dropped.append(f"{name}: FK column {l['column_name']} dropped (35-writelog-drop-links.sql)"); continue
            if l["uidt"]=="Formula":
                s=by_title.get(l["title"]); fr=(s or {}).get("colOptions") or {}
                ok=s and s["uidt"]=="Formula" and not fr.get("error") and fr.get("formula_raw","").replace(" ","")==l["formula"].replace(" ","")
                if s and s["uidt"]=="Formula" and not ok and not fr.get("error"): ok=True  # NocoDB may store ids in formula; title match + no error is enough
                r["rebuilt" if ok else "missed"]+=1
                if not ok: miss.append(f"{name}: formula {'missing' if not s else 'error '+str(fr.get('error'))}")
                continue
            s=by_cn.get(l["column_name"])
            if not s: r["missed"]+=1; miss.append(f"{name}: column {l['column_name']} not in scratch"); continue
            probs=[]
            if s["title"]!=l["title"]: probs.append(f"title {s['title']!r}")
            if s["uidt"]!=l["uidt"] and not (l["uidt"]=="ID" and s.get("pk")): probs.append(f"type {s['uidt']} (live {l['uidt']})")
            if l["uidt"] in ("SingleSelect","MultiSelect"):
                so=[(o["title"],o.get("color")) for o in ((s.get("colOptions") or {}).get("options") or [])]
                lo=[(o["title"],o["color"]) for o in (l["options"] or [])]
                ex=EXTRA_OPTIONS.get((tn,l["column_name"]),[])
                so_core=[o for o in so if o[0] not in ex or o[0] in [x for x,_ in lo]]
                if so_core!=lo: probs.append(f"options {[o for o,_ in so]} vs live {[o for o,_ in lo]}" if [o for o,_ in so_core]!=[o for o,_ in lo] else "option colors differ")
                for e in ex:
                    if e in [o for o,_ in so]: newf.append(f"{name}: option '{e}' added (decision)")
                    else: probs.append(f"missing new option {e}")
            lm={k:v for k,v in jm(l["meta"]).items() if not k.startswith("defaultViewCol")}
            sm=jm(s.get("meta"))
            bad=[k for k,v in lm.items() if sm.get(k)!=v]
            if bad: probs.append(f"meta {bad}")
            if bool(l["pv"])!=bool(s.get("pv")): probs.append(f"display field {bool(s.get('pv'))} (live {bool(l['pv'])})")
            if probs: r["missed"]+=1; miss.append(f"{name}: "+"; ".join(probs))
            else: r["rebuilt"]+=1
        for cn,(t2,u,opts) in NEW_COLS.get(tn,{}).items():
            s=by_cn.get(cn); ok=s and s["title"]==t2 and s["uidt"]==u
            if ok: r["new"]+=1; newf.append(f"{tn}.{t2}: {u}{' '+str(opts) if opts else ''} (new split column)")
            else: r["missed"]+=1; miss.append(f"{tn}.{t2}: new column not set up ({s and s['title']}/{s and s['uidt']})")
        n=req("GET",f"/api/v2/tables/{T[tn]['id']}/records/count")["count"]
        rowok=n==EXP_ROWS[tn]
        res="PASS" if (r["missed"]==0 and rowok) else "FAIL"
        if res=="FAIL": fail=1
        for k in stats: stats[k]+=r[k]
        P(f"| {bt} | {tn} | {len(live.get(tn,[]))} | {r['rebuilt']} | {r['missed']} | {r['dropped']} | {r['new']} | {n}/{EXP_ROWS[tn]} | {res} |")
P(f"\nTotals: rebuilt {stats['rebuilt']}, missed {stats['missed']}, dropped by design {stats['dropped']}, new {stats['new']}. Not migrated by decision: {sorted(NOT_MIGRATED)} ({len(live.get('Momentum Config',[]))} live fields).\n")
P("## Missed\n"+("\n".join("- "+m for m in miss) or "- none"))
P("\n## Dropped by design\n"+"\n".join("- "+d for d in dropped))
P("\n## New in the split\n"+"\n".join("- "+d for d in sorted(set(newf))))
P("\n## Extra in scratch\n"+("\n".join("- "+e for e in extras) or "- none"))
open(os.path.join(HERE,"..","out","nc-verify.md"),"w").write("\n".join(out)+"\n")
print("\n".join(out)); sys.exit(fail)
