#!/usr/bin/env python3
"""validate.py - check a conveyor task JSON against task.schema.json.

  python3 validate.py <task.json> [--minimal] [--render]

Exit 0 = valid, 1 = invalid, 2 = usage / IO error.
Uses the `jsonschema` package when importable (e.g. from ./.venv), else a
small built-in checker for exactly the keywords task.schema.json uses.
--minimal forces the built-in checker. --render prints the task as a belt
markdown file to stdout (writes nothing anywhere).
Pure code: no model, no network, no database.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA_PATH = os.path.join(HERE, "task.schema.json")


# ---------------------------------------------------------------- built-in checker
TYPES = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}


def _type_ok(v, t):
    if t == "integer":
        return isinstance(v, int) and not isinstance(v, bool)
    if t == "number":
        return isinstance(v, (int, float)) and not isinstance(v, bool)
    return isinstance(v, TYPES[t])


def minimal_errors(v, s, path="$"):
    errs = []
    if "const" in s and v != s["const"]:
        errs.append("%s: must be %r" % (path, s["const"]))
    if "enum" in s and v not in s["enum"]:
        errs.append("%s: %r not one of %s" % (path, v, s["enum"]))
    if "type" in s:
        ts = s["type"] if isinstance(s["type"], list) else [s["type"]]
        if not any(_type_ok(v, t) for t in ts):
            return errs + ["%s: expected type %s" % (path, "/".join(ts))]
    if isinstance(v, str):
        if len(v) < s.get("minLength", 0):
            errs.append("%s: shorter than %d" % (path, s["minLength"]))
        if "maxLength" in s and len(v) > s["maxLength"]:
            errs.append("%s: longer than %d" % (path, s["maxLength"]))
        if "pattern" in s and not re.search(s["pattern"], v):
            errs.append("%s: does not match %s" % (path, s["pattern"]))
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        if "minimum" in s and v < s["minimum"]:
            errs.append("%s: below %s" % (path, s["minimum"]))
        if "maximum" in s and v > s["maximum"]:
            errs.append("%s: above %s" % (path, s["maximum"]))
    if isinstance(v, list):
        if len(v) < s.get("minItems", 0):
            errs.append("%s: fewer than %d items" % (path, s["minItems"]))
        if "maxItems" in s and len(v) > s["maxItems"]:
            errs.append("%s: more than %d items" % (path, s["maxItems"]))
        if "items" in s:
            for i, x in enumerate(v):
                errs += minimal_errors(x, s["items"], "%s[%d]" % (path, i))
    if isinstance(v, dict):
        props = s.get("properties", {})
        for k in s.get("required", []):
            if k not in v:
                errs.append("%s: missing required '%s'" % (path, k))
        for k, x in v.items():
            if k in props:
                errs += minimal_errors(x, props[k], "%s.%s" % (path, k))
            elif s.get("additionalProperties") is False:
                errs.append("%s: unexpected field '%s'" % (path, k))
    return errs


def schema_errors(task, schema, force_minimal):
    if not force_minimal:
        try:
            import jsonschema
            v = jsonschema.Draft202012Validator(schema)
            out = []
            for e in sorted(v.iter_errors(task), key=lambda e: list(e.path)):
                p = "$" + "".join("[%d]" % x if isinstance(x, int) else ".%s" % x for x in e.path)
                out.append("%s: %s" % (p, e.message))
            from importlib.metadata import version
            return "jsonschema " + version("jsonschema"), out
        except ImportError:
            pass
    return "built-in minimal checker", minimal_errors(task, schema)


# ---------------------------------------------------------------- rules a schema can't say
def rule_errors(t):
    """Cross-field rules. Kept out of the schema so the schema stays inside what
    llama.cpp's grammar converter understands."""
    errs = []
    checks = t["acceptance"]["checks"]
    human = [c for c in checks if c["verify"].strip() == "HUMAN"]
    if len(human) > 1:
        errs.append("acceptance: at most ONE HUMAN check (conveyor-tap ticks every HUMAN box on approve)")
    for c in checks:
        for k in ("verify", "expect"):
            x = c.get(k)
            if x is not None and ("\n" in x or " :: " in x):
                errs.append("check %r: %s must be one line without ' :: ' (conveyor-check grammar)" % (c["claim"], k))
    if len(checks) - len(human) < 1:
        errs.append("acceptance: needs at least one command check (the coder needs a test)")
    paths = [f["path"] for f in t["files_to_touch"]] + t["constraints"]["write_scope"]
    for p in paths:
        if ".." in p.split("/"):
            errs.append("path %r: '..' is not allowed, paths stay under root" % p)
    scope = t["constraints"]["write_scope"]
    for f in t["files_to_touch"]:
        if f["action"] in ("create", "edit") and not any(
                f["path"] == w or f["path"].startswith(w.rstrip("/") + "/") for w in scope):
            errs.append("files_to_touch %r is %s but not inside write_scope" % (f["path"], f["action"]))
    writes = sum(1 for f in t["files_to_touch"] if f["action"] != "read")
    if writes > t["limits"]["max_files_changed"]:
        errs.append("limits: %d files to create/edit but max_files_changed is %d"
                    % (writes, t["limits"]["max_files_changed"]))
    if t["id"] in t["depends_on"]:
        errs.append("depends_on: a task cannot depend on itself")
    return errs


# ---------------------------------------------------------------- belt markdown
def render(t):
    pv = t["provenance"]
    out = ["# %s" % t["title"], "",
           "queued: %s" % pv["proposed_at"],
           "by: %s (%s)" % (pv["proposed_by"], pv["source"]),
           "task-id: %s" % t["id"], "project: %s" % t["project"], "root: %s" % t["root"]]
    if pv.get("approved_by"):
        out.append("approved-by: %s" % pv["approved_by"])
    if t["depends_on"]:
        out.append("depends-on: %s" % " ".join(t["depends_on"]))
    out += ["", "Goal: %s" % t["goal"], ""]
    if pv.get("ask"):
        out += ["The owner's words: %s" % pv["ask"], ""]
    out.append("Files:")
    out += ["- %s %s%s" % (f["action"], f["path"], (" - " + f["why"]) if f.get("why") else "")
            for f in t["files_to_touch"]]
    out += ["", "Do:"] + ["%d. %s" % (i, s) for i, s in enumerate(t["steps"], 1)]
    c = t["constraints"]
    out += ["", "Rules:", "- network: %s" % c["network"], "- secrets: none",
            "- write only: %s" % ", ".join(c["write_scope"])]
    out += ["- %s" % n for n in c.get("notes", [])]
    lim = t["limits"]
    out += ["- size: at most %d file(s), %d changed lines" % (lim["max_files_changed"], lim["max_lines_changed"])]
    out += ["", "Done means: %s" % t["acceptance"]["expected_result"], "", "## Legs: 0", "", "## Checklist"]
    for ch in t["acceptance"]["checks"]:
        verify = ch["verify"] if ch["verify"] == "HUMAN" else "cd %s && %s" % (t["root"], ch["verify"])
        line = "- [ ] %s :: verify: %s" % (ch["claim"], verify)
        if ch.get("expect"):
            line += " :: expect: %s" % ch["expect"]
        out.append(line)
    return "\n".join(out) + "\n"


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    if len(args) != 1 or flags - {"--minimal", "--render"}:
        sys.stderr.write(__doc__)
        return 2
    try:
        with open(SCHEMA_PATH) as f:
            schema = json.load(f)
        with open(args[0]) as f:
            task = json.load(f)
    except (OSError, ValueError) as e:
        print("INVALID (could not read/parse): %s" % e)
        return 2 if isinstance(e, OSError) else 1
    engine, errs = schema_errors(task, schema, "--minimal" in flags)
    if not errs:
        errs = rule_errors(task)   # only meaningful once the shape is right
    if errs:
        print("INVALID %s [%s]" % (args[0], engine))
        for e in errs:
            print("  - " + e)
        return 1
    print("VALID %s [%s]" % (args[0], engine))
    if "--render" in flags:
        sys.stdout.write("\n" + render(task))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
