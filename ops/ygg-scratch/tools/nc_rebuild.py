#!/usr/bin/env python3
"""Scratch only. Create one NocoDB base per project DB (external pg source, user ygg_app) and rebuild
field settings from live-field-meta.json (extracted from the 2026-10-27 03:15 nocodb backup dump):
titles, field types, select options+colors+order, date/currency/decimal meta, display field,
formulas, and same-DB links. Idempotent. Prints no secrets. Usage: nc_rebuild.py [--dry-run]"""
import sys, json, os
from nc_api import req, ENV
from split_map import BASES, NEW_COLS, EXTRA_OPTIONS, DROPPED_LINK_FKS
DRY="--dry-run" in sys.argv
HERE=os.path.dirname(os.path.abspath(__file__))
L=json.load(open(os.path.join(HERE,"live-field-meta.json")))
def jm(m):
    if isinstance(m,str):
        try: m=json.loads(m)
        except Exception: return {}
    return m or {}
live={}
for c in L["columns"]: live.setdefault(c["model"],[]).append(c)
LINKY={"Links","LinkToAnotherRecord","ForeignKey"}
def bases(): return {b["title"]:b for b in req("GET","/api/v2/meta/bases")["list"]}
def tables(bid): return {t["title"]:t for t in req("GET",f"/api/v2/meta/bases/{bid}/tables")["list"]}
def cols(tid): return req("GET",f"/api/v2/meta/tables/{tid}")["columns"]
log=[]
def say(*a): s=" ".join(str(x) for x in a); print(s); log.append(s)
have=bases()
for title,(db,tnames) in BASES.items():
    if title not in have:
        cfg={"client":"pg","connection":{"host":"pg","port":5432,"user":"ygg_app","password":ENV["YGG_APP_PASSWORD"],"database":db},"searchPath":["public"]}
        if not DRY: req("POST","/api/v2/meta/bases",{"title":title,"external":True,"sources":[{"type":"pg","config":cfg,"inflection_column":"none","inflection_table":"none"}]})
        say("created base",title,"->",db)
have=bases()
def patch(c,new,why):
    body=dict(c); body.pop("pv",None); body.update(new)  # never resend a stale display flag
    if DRY: say("  would patch",c["column_name"],why); return True
    try: req("PATCH",f"/api/v2/meta/columns/{c['id']}",body); say("  patched",c["column_name"],why); return True
    except Exception as e: say("  FAILED",c["column_name"],why,str(e)[:200]); return False
for title,(db,tnames) in BASES.items():
    bid=have[title]["id"]; T=tables(bid)
    for tn in tnames:
        if tn not in T: say("MISSING table",tn,"in",title); continue
        tid=T[tn]["id"]; say("table",title,"/",tn)
        lc={c["column_name"]:c for c in live.get(tn,[]) if c["column_name"] and c["uidt"] not in LINKY}
        for c in cols(tid):
            cn=c["column_name"]
            if cn in DROPPED_LINK_FKS: continue
            spec=None
            if cn in lc:
                l=lc[cn]; spec=dict(title=l["title"],uidt=l["uidt"],meta=jm(l["meta"]),options=[(o["title"],o["color"]) for o in (l["options"] or [])],pv=bool(l["pv"]))
                for extra in EXTRA_OPTIONS.get((tn,cn),[]):
                    if extra not in [o for o,_ in spec["options"]]: spec["options"].append((extra,None))
            elif cn in NEW_COLS.get(tn,{}):
                t2,u,opts=NEW_COLS[tn][cn]; spec=dict(title=t2,uidt=u,meta={},options=[(o,None) for o in (opts or [])],pv=False)
            if not spec: continue
            new={}
            if c["title"]!=spec["title"]: new["title"]=spec["title"]
            if c["uidt"]!=spec["uidt"]: new["uidt"]=spec["uidt"]
            want_meta={k:v for k,v in spec["meta"].items() if not k.startswith("defaultViewCol")}
            if want_meta and any(jm(c.get("meta")).get(k)!=v for k,v in want_meta.items()): new["meta"]={**jm(c.get("meta")),**want_meta}
            if spec["uidt"] in ("SingleSelect","MultiSelect"):
                cur=[(o["title"],o.get("color")) for o in ((c.get("colOptions") or {}).get("options") or [])]
                want=[o for o,_ in spec["options"]]
                if [o for o,_ in cur]!=want or any(col and dict(cur).get(o)!=col for o,col in spec["options"]):
                    new["colOptions"]={"options":[dict(title=o,order=i+1,**({"color":col} if col else {})) for i,(o,col) in enumerate(spec["options"])]}
            if new and c.get("system") and set(new)-{"title"}: new={k:v for k,v in new.items() if k=="title"}
            if new: patch(c,{**new,"uidt":new.get("uidt",c["uidt"])}," ".join(sorted(new)))
            if spec["pv"] and (not c.get("pv") or sum(1 for x in cols(tid) if x.get("pv"))>1):
                if DRY: say("  would set display",cn)
                else:
                    try: req("POST",f"/api/v2/meta/columns/{c['id']}/primary"); say("  display field",cn)
                    except Exception as e: say("  FAILED display",cn,str(e)[:200])
        # formulas (same table only)
        cur={c["title"] for c in cols(tid)}
        for l in live.get(tn,[]):
            if l["uidt"]=="Formula" and l["title"] not in cur:
                if DRY: say("  would add formula",l["title"]); continue
                try: req("POST",f"/api/v2/meta/tables/{tid}/columns",{"title":l["title"],"column_name":l["title"],"uidt":"Formula","formula_raw":l["formula"]}); say("  formula",l["title"])
                except Exception as e: say("  FAILED formula",l["title"],str(e)[:300])
    # same-DB links: rename auto-detected relations to live titles
    T=tables(bid)
    for tn in tnames:
        if tn not in T: continue
        for l in live.get(tn,[]):
            if l["uidt"] not in ("Links","LinkToAnotherRecord") or not l["relation"]: continue
            r=l["relation"]
            if r["related_model"] not in tnames: continue
            mine=[c for c in cols(T[tn]["id"]) if c["uidt"] in ("Links","LinkToAnotherRecord")]
            if any(c["title"]==l["title"] for c in mine): continue
            rel=T[r["related_model"]]["id"]
            cand=[c for c in mine if (c.get("colOptions") or {}).get("fk_related_model_id")==rel and (c.get("colOptions") or {}).get("type")==r["type"]]
            if len(cand)==1: patch(cand[0],{"title":l["title"]},f"link title -> {l['title']}")
            elif not cand and r["type"]=="bt":
                say("  no auto-detected relation for",tn,l["title"],"(creating from parent side is done on hm pass)")
            elif not cand and r["type"]=="hm":
                say("  no auto relation; creating",r["related_model"],"->",tn,l["title"])
                if not DRY:
                    try: req("POST",f"/api/v2/meta/tables/{T[tn]['id']}/columns",{"title":l["title"],"column_name":l["title"],"uidt":"Links","parentId":T[tn]["id"],"childId":rel,"type":"hm"})
                    except Exception as e: say("  FAILED link",str(e)[:300])
            else: say("  ambiguous link candidates",tn,l["title"],[c["title"] for c in cand])
open(os.path.join(HERE,"..","out","nc-rebuild.log"),"a").write("\n".join(log)+"\n")
