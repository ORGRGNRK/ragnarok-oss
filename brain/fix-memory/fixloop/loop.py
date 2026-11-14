"""The self-healing loop: test -> (fail) embed error -> retrieve past fixes -> ask local model
-> apply edit -> test again ... -> on pass after failure, record error/cause/fix + receipt."""
from __future__ import annotations

import ast
import difflib
import json
import re
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import db, ollama
from .config import REPO_ROOT, settings
from .sandbox import run_tests

SKIP_DIRS = {".git", ".venv", "venv", "__pycache__", ".pytest_cache", "node_modules", ".mypy_cache"}
SOURCE_EXTS = {".py"}
MAX_SOURCE_CHARS = 24000
CANDIDATE_TEMPS = [0.2, 0.6, 0.9, 0.4, 0.8]

SYSTEM_PROMPT = """You are a careful Python developer fixing code so that failing tests pass.
Rules:
- Never edit test files. Fix the source code.
- Make the smallest change that fixes the failure. Keep everything else identical.
- Past fixes from memory, when shown, are for a very similar failure; reuse them if they fit.
Reply in exactly this format:
CAUSE: <one sentence explaining the bug>
FILE: <relative path of the file you changed>
```python
<the COMPLETE new contents of that file>
```
(Repeat FILE blocks only if more than one file must change.)"""


def is_test_file(rel: str) -> bool:
    p = Path(rel)
    return (
        p.name.startswith("test_") or p.name.endswith("_test.py") or p.name == "conftest.py"
        or any(part in ("tests", "test") for part in p.parts[:-1])
    )


def source_files(root: Path) -> list[str]:
    out = []
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root)
        if any(part in SKIP_DIRS for part in rel.parts) or not p.is_file():
            continue
        if p.suffix in SOURCE_EXTS:
            out.append(str(rel))
    return out


def normalize_error(output: str, workdir: Path | None = None) -> str:
    """Strip noise (paths, timings, addresses, pytest header) so similar failures embed similarly."""
    text = output
    if workdir is not None:
        text = text.replace(str(workdir.resolve()), "")
    text = text.replace("/work/", "")
    keep = []
    for line in text.splitlines():
        if re.match(r"^(platform |rootdir:|cachedir:|plugins:|collected \d+|configfile:)", line):
            continue
        keep.append(line)
    text = "\n".join(keep)
    text = re.sub(r"0x[0-9a-fA-F]+", "0x?", text)
    text = re.sub(r"in \d+\.\d+s", "in ?s", text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return text[-4000:]


def error_signature(error: str) -> str:
    """The lines that actually say what broke (pytest 'E' lines, FAILED/ERROR summary lines,
    exception lines). Embedding this instead of the whole log keeps unrelated failures in the
    same test file from all looking ~equally similar."""
    keep = []
    for line in error.splitlines():
        st = line.strip()
        if (st.startswith("E ") or st.startswith("FAILED ") or st.startswith("ERROR ")
                or re.match(r"^[A-Za-z_.]*(Error|Exception)\b", st)):
            if st not in keep:
                keep.append(st)
    return "\n".join(keep)[:2000] if keep else error[-1500:]


def parse_edits(reply: str, candidates: list[str]) -> tuple[str, dict[str, str]]:
    cause_m = re.search(r"CAUSE:\s*(.+)", reply)
    cause = cause_m.group(1).strip() if cause_m else ""
    edits: dict[str, str] = {}
    for m in re.finditer(r"FILE:\s*`?([^\s`]+)`?\s*\n+```[a-zA-Z0-9_+-]*\n(.*?)\n```", reply, re.S):
        edits[m.group(1).strip()] = m.group(2) + "\n"
    if not edits:
        blocks = re.findall(r"```[a-zA-Z0-9_+-]*\n(.*?)\n```", reply, re.S)
        non_test = [c for c in candidates if not is_test_file(c)]
        if len(blocks) == 1 and len(non_test) == 1:
            edits[non_test[0]] = blocks[0] + "\n"
    return cause, edits


def _top_level_defs(src: str) -> dict[str, tuple[int, int]]:
    tree = ast.parse(src)
    out = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            start = min([node.lineno] + [d.lineno for d in node.decorator_list])
            out[node.name] = (start, node.end_lineno)
    return out


def merge_partial(current: str, proposed: str) -> str:
    """Small models often return only the function they changed. If the proposed file is
    missing top-level functions/classes that exist now, splice the returned definitions into
    the current file instead of overwriting it (other code is kept as-is)."""
    try:
        cur_defs, new_defs = _top_level_defs(current), _top_level_defs(proposed)
    except SyntaxError:
        return proposed
    if not new_defs or set(cur_defs) <= set(new_defs):
        return proposed  # complete file (or nothing to splice): use as-is
    cur_lines, new_lines = current.splitlines(True), proposed.splitlines(True)
    # replace from the bottom up so earlier line numbers stay valid
    for name, (s, e) in sorted(cur_defs.items(), key=lambda kv: -kv[1][0]):
        if name in new_defs:
            ns, ne = new_defs[name]
            cur_lines[s - 1:e] = new_lines[ns - 1:ne]
    for name, (ns, ne) in new_defs.items():
        if name not in cur_defs:
            cur_lines += ["\n\n"] + new_lines[ns - 1:ne]
    return "".join(cur_lines)


def apply_edits(workdir: Path, edits: dict[str, str]) -> list[str]:
    applied, root = [], workdir.resolve()
    for rel, content in edits.items():
        rel = rel[2:] if rel.startswith("./") else rel
        target = (root / rel).resolve()
        if root not in target.parents:
            continue  # refuse paths outside the project
        if is_test_file(str(target.relative_to(root))):
            continue  # refuse to "fix" by editing tests
        if target.suffix not in SOURCE_EXTS:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            content = merge_partial(target.read_text(errors="replace"), content)
        target.write_text(content)
        applied.append(str(target.relative_to(root)))
    return applied


def make_diff(before: dict[str, str], after_root: Path) -> str:
    chunks = []
    for rel in sorted(set(before) | set(source_files(after_root))):
        a = before.get(rel, "")
        p = after_root / rel
        b = p.read_text() if p.exists() else ""
        if a != b:
            chunks.extend(difflib.unified_diff(a.splitlines(True), b.splitlines(True), f"a/{rel}", f"b/{rel}", n=1))
    return "".join(chunks)


def replay_diff(workdir: Path, diff: str) -> bool:
    """Apply a stored unified diff to the work copy with `patch`. Returns True if it applied."""
    if not diff.strip():
        return False
    with tempfile.NamedTemporaryFile("w", suffix=".diff", delete=False) as fh:
        fh.write(diff)
        path = fh.name
    try:
        p = subprocess.run(["patch", "-p1", "--forward", "--batch", "-s", "-r", "-", "-i", path],
                           cwd=workdir, capture_output=True, text=True, timeout=30)
        return p.returncode == 0
    finally:
        Path(path).unlink(missing_ok=True)


def badness(res) -> int:
    """Rough score for comparing failures: collection/import errors are worst, then failed count."""
    out = res.output
    if res.passed:
        return 0
    if "error during collection" in out or "errors during collection" in out or "SyntaxError" in out:
        return 10_000
    m = re.search(r"(\d+) failed", out)
    return int(m.group(1)) if m else 1_000


def snapshot(root: Path) -> dict[str, str]:
    return {rel: (root / rel).read_text(errors="replace") for rel in source_files(root)
            if not rel.startswith(".fixloop-")}


def restore(root: Path, snap: dict[str, str]) -> None:
    for rel in source_files(root):
        if rel not in snap and not is_test_file(rel):
            (root / rel).unlink()
    for rel, body in snap.items():
        (root / rel).write_text(body)


def build_prompt(test_cmd, error, fixes, workdir, history) -> str:
    parts = [f"Test command: {test_cmd}", "", "## Source files (tests are read-only and shown for reference)"]
    budget = MAX_SOURCE_CHARS
    rels = source_files(workdir)
    rels.sort(key=lambda r: (r not in error, is_test_file(r)))  # files named in the traceback first
    for rel in rels:
        body = (workdir / rel).read_text(errors="replace")
        if len(body) > budget:
            continue
        budget -= len(body)
        tag = " (TEST - do not edit)" if is_test_file(rel) else ""
        parts += [f"FILE: {rel}{tag}", "```python", body.rstrip("\n"), "```", ""]
    parts += ["## Current failing test output", error, ""]
    if history:
        parts.append("## Earlier attempts in this run that did NOT pass")
        for h in history:
            if h.get("noop"):
                what = "your reply did NOT change the code at all; you must change something different"
            elif h.get("worse"):
                what = "made it WORSE and was reverted"
            else:
                what = "still failing"
            parts.append(f"- try {h['try']}: cause guessed '{h.get('cause','')}', {what}")
        parts.append("")
    if fixes:
        parts.append("## Past fixes from memory for a very similar failure (verify they fit before reusing)")
        for i, f in enumerate(fixes, 1):
            parts += [f"### Past fix {i} (similarity {f['similarity']:.3f})",
                      "Failure was:", error_signature(f["error_text"]),
                      f"Cause: {f.get('cause') or '?'}", "Fix diff:", f["fix"], ""]
    return "\n".join(parts)


@dataclass
class RunReport:
    project: str
    test_cmd: str
    passed: bool = False
    tries: int = 0
    healed: bool = False
    retrievals: list = field(default_factory=list)
    attempts: list = field(default_factory=list)
    recorded: dict | None = None
    reused_fix_id: int | None = None
    changed_files: list = field(default_factory=list)


def run(project_dir: str, test_cmd: str, max_tries: int | None = None, image: str | None = None,
        record: bool = True, write_back: bool = True, use_memory: bool = True, log=print) -> RunReport:
    project = Path(project_dir).expanduser().resolve()
    max_tries = max_tries or settings.max_tries
    report = RunReport(project=str(project), test_cmd=test_cmd)

    work_base = REPO_ROOT / ".work"
    work_base.mkdir(exist_ok=True)
    workdir = work_base / f"{project.name}-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copytree(project, workdir, ignore=shutil.ignore_patterns(*SKIP_DIRS))
    original = {rel: (workdir / rel).read_text(errors="replace") for rel in source_files(workdir)}
    log(f"[fixloop] project={project} work copy={workdir}")
    log(f"[fixloop] coder={settings.coder_model} embed={settings.embed_model} ollama={settings.ollama_host}")

    first_error = None
    history: list[dict] = []
    last_cause = ""
    best = None  # (badness, snapshot, error) of the least-broken state seen so far
    for attempt in range(1, max_tries + 1):
        report.tries = attempt
        log(f"\n[fixloop] try {attempt}/{max_tries}: running tests in throwaway container ...")
        res = run_tests(workdir, test_cmd, image=image)
        log(f"[fixloop] exit code {res.exit_code} -> {'PASS' if res.passed else 'FAIL'}")
        report.attempts.append({"try": attempt, "exit_code": res.exit_code, "passed": res.passed})
        if res.passed:
            report.passed = True
            break
        error = normalize_error(res.output, workdir)
        if first_error is None:
            first_error = error
        score = badness(res)
        if best is not None and score > best[0]:
            log(f"[fixloop] that edit made things worse; reverting to the best version so far")
            restore(workdir, best[1])
            error = best[2]
            report.attempts[-1]["reverted"] = True
            if history:
                history[-1]["worse"] = True
        else:
            best = (score, snapshot(workdir), error)
        tail = "\n".join(error.splitlines()[-6:])
        log("[fixloop] failure tail:\n    " + tail.replace("\n", "\n    "))
        if attempt == max_tries:
            break

        fixes = []
        try:
            if use_memory:
                fixes = db.search_fixes(ollama.embed(error_signature(error), kind="query"), k=3)
        except Exception as e:  # retrieval is best-effort; the loop still runs without memory
            log(f"[fixloop] retrieval unavailable: {e}")
        top = fixes[0]["similarity"] if fixes else None
        given = [f for f in fixes if f["similarity"] >= settings.min_similarity]
        hit = bool(given)
        report.retrievals.append({"try": attempt, "hit": hit, "given_to_model": [f["id"] for f in given],
                                  "matches": [{"fix_id": f["id"], "source": f["source"],
                                               "similarity": round(float(f["similarity"]), 4),
                                               "cause": f["cause"]} for f in fixes]})
        log(f"[fixloop] retrieved {len(fixes)} past fix(es)" + (f"; top similarity {top:.3f} -> "
            + (f"MEMORY HIT ({len(given)} at/above {settings.min_similarity})" if hit else f"below {settings.min_similarity} gate, model works without memory") if fixes else ""))
        for f in fixes:
            mark = "->model" if f in given else "logged "
            log(f"    {mark} #{f['id']} [{f['source']}] sim={f['similarity']:.3f} cause: {(f['cause'] or '')[:90]}")

        prompt = build_prompt(test_cmd, error, given, workdir, history)
        (workdir / f".fixloop-try{attempt}-prompt.txt").write_text(prompt)
        base = snapshot(workdir)
        best_cand = None  # (badness, snapshot, cause, applied)
        # 1) Memory hit: replay the stored fix directly first (no model call needed if it works).
        replay_won = False
        for f in given:
            restore(workdir, base)
            if not replay_diff(workdir, f["fix"]) or snapshot(workdir) == base:
                log(f"    replay of stored fix #{f['id']}: did not apply cleanly")
                continue
            cres = run_tests(workdir, test_cmd, image=image)
            log(f"    replay of stored fix #{f['id']}: tests {'PASS' if cres.passed else 'fail'}")
            if cres.passed:
                best_cand = (0, snapshot(workdir), f.get("cause") or "", sorted(original))
                report.reused_fix_id = f["id"]
                replay_won = True
                break
        if not replay_won:
            restore(workdir, base)
        # 2) Otherwise (or if replay failed) ask the model for candidate edits.
        temps = [] if replay_won else CANDIDATE_TEMPS[: max(1, settings.candidates)]
        if temps:
            log(f"[fixloop] asking {settings.coder_model} for {len(temps)} candidate fix(es) ...")
        for ci, temperature in enumerate(temps, 1):
            restore(workdir, base)
            t0 = time.time()
            reply = ollama.chat(SYSTEM_PROMPT, prompt, temperature=temperature)
            (workdir / f".fixloop-try{attempt}-cand{ci}-reply.txt").write_text(reply)
            cause, edits = parse_edits(reply, list(original))
            applied = apply_edits(workdir, edits)
            if snapshot(workdir) == base:
                log(f"    cand {ci} (t={temperature}): {time.time()-t0:.0f}s, no actual code change")
                continue
            cres = run_tests(workdir, test_cmd, image=image)
            score = badness(cres)
            log(f"    cand {ci} (t={temperature}): {time.time()-t0:.0f}s, tests {'PASS' if cres.passed else 'fail'} "
                f"(score {score}); cause: {cause[:100] or '(none)'}")
            if best_cand is None or score < best_cand[0]:
                best_cand = (score, snapshot(workdir), cause, applied)
            if cres.passed:
                break
        if best_cand is None:
            restore(workdir, base)
            history.append({"try": attempt, "cause": "", "applied": [], "noop": True})
            report.attempts[-1].update({"model_cause": "", "applied": [], "noop": True})
            log("[fixloop] no candidate changed the code")
            continue
        restore(workdir, best_cand[1])
        history.append({"try": attempt, "cause": best_cand[2], "applied": best_cand[3]})
        report.attempts[-1].update({"model_cause": best_cand[2], "applied": best_cand[3]})
        last_cause = best_cand[2]
        log(f"[fixloop] keeping best candidate (score {best_cand[0]}): {best_cand[2][:120]}")

    if report.passed and first_error is not None:
        report.healed = True
        diff = make_diff(original, workdir)
        report.changed_files = [rel for rel in source_files(workdir) if original.get(rel) != (workdir / rel).read_text(errors="replace")]
        log(f"\n[fixloop] HEALED after {report.tries} tries. Change:\n{diff}")
        if record and report.reused_fix_id is not None:
            report.recorded = db.record_reuse(report.reused_fix_id, project=project.name,
                                              extra={"tries": report.tries, "test_cmd": test_cmd,
                                                     "embed_model_reported": ollama.reported["embed"]})
            log(f"[fixloop] healed by replaying stored fix #{report.reused_fix_id}; "
                f"write_log receipt #{report.recorded['receipt_seq']} {report.recorded['receipt_hash'][:16]}... (no duplicate fix row)")
        elif record:
            emb = ollama.embed(error_signature(first_error), kind="document")
            report.recorded = db.record_fix(
                source="loop", project=project.name, error_text=first_error,
                cause=last_cause or "(model gave no cause)", fix=diff, embedding=emb,
                extra={"tries": report.tries, "test_cmd": test_cmd, "coder_model": settings.coder_model,
                       "coder_model_reported": ollama.chat_models_reported()},
            )
            log(f"[fixloop] recorded fix #{report.recorded['fix_id']} write_log receipt #{report.recorded['receipt_seq']} {report.recorded['receipt_hash'][:16]}...")
        if write_back:
            for rel in report.changed_files:
                (project / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(workdir / rel, project / rel)
            log(f"[fixloop] wrote healed file(s) back to project: {report.changed_files}")
    elif report.passed:
        log("[fixloop] tests passed on the first try; nothing to heal or record.")
    else:
        log(f"\n[fixloop] GAVE UP after {report.tries} tries. Project left unchanged; last attempt is in {workdir}")

    (workdir / ".fixloop-report.json").write_text(json.dumps(report.__dict__, indent=2, default=str))
    return report
