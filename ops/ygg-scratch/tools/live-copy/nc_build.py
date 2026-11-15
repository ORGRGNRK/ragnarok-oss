#!/usr/bin/env python3
"""Build base "Yggdrasil" and its tables from schema_spec.py. Idempotent."""
import json, sys
from nc_api import req
import os as _os
BASE_TITLE=_os.environ.get("YGG_BASE_TITLE","Yggdrasil")
from schema_spec import TABLES, LINKS, FORMULAS
def colbody(name,uidt,opt):
    c={"title":name,"column_name":name,"uidt":uidt}
    if uidt in ("SingleSelect","MultiSelect"):
        c["colOptions"]={"options":[{"title":o,"order":i+1} for i,o in enumerate(opt)]}
    if uidt=="Date": c["meta"]={"date_format":"YYYY-MM-DD"}
    if uidt=="DateTime": c["meta"]={"date_format":"YYYY-MM-DD","time_format":"HH:mm","is12hrFormat":False}
    if uidt=="Currency": c["meta"]={"currency_locale":"en-US","currency_code":"USD"}
    if uidt=="Decimal": c["meta"]={"precision":2}
    if isinstance(opt,dict) and opt.get("unique"): c["unique"]=True
    return c
bases=req("GET","/api/v2/meta/bases")["list"]
base=next((b for b in bases if b["title"]==BASE_TITLE),None) or req("POST","/api/v2/meta/bases",{"title":BASE_TITLE})
bid=base["id"]; print("base",base["title"])
def tables(): return {t["title"]:t for t in req("GET",f"/api/v2/meta/bases/{bid}/tables")["list"]}
have=tables()
for name,cols in TABLES.items():
    if name in have: print("exists",name); continue
    body={"table_name":name,"title":name,"columns":[{"column_name":"id","title":"Id","uidt":"ID"}]+[colbody(*c) for c in cols]}
    req("POST",f"/api/v2/meta/bases/{bid}/tables",body); print("created",name)
have=tables()
def cols(tid): return req("GET",f"/api/v2/meta/tables/{tid}")["columns"]
for parent,child,child_field,parent_field in LINKS:
    pid=have[parent]["id"]; cid=have[child]["id"]
    if any(c["title"]==child_field for c in cols(cid)): print("link exists",child_field); continue
    before={c["id"] for c in cols(cid)}
    req("POST",f"/api/v2/meta/tables/{pid}/columns",{"title":parent_field,"column_name":parent_field,"uidt":"Links","parentId":pid,"childId":cid,"type":"hm"})
    new=[c for c in cols(cid) if c["id"] not in before and c["uidt"] in ("LinkToAnotherRecord","Links")]
    if len(new)==1:
        c=new[0]; c2=dict(c); c2["title"]=child_field
        req("PATCH",f"/api/v2/meta/columns/{c['id']}",c2)
    print("link",parent,"->",child,"inverse new:",[c["title"] for c in new])
for t,fs in FORMULAS.items():
    tid=have[t]["id"]
    for name,f in fs:
        if any(c["title"]==name for c in cols(tid)): continue
        req("POST",f"/api/v2/meta/tables/{tid}/columns",{"title":name,"column_name":name,"uidt":"Formula","formula_raw":f}); print("formula",t,name)
