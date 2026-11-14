#!/usr/bin/env python3
"""Edit Heimdall through a provider API instead of a CLI.

    heimdall-api-edit.py <anthropic|openai|xai|gemini> <folder> "<instruction>"

Key: macOS keychain item with service "heimdall-api-<provider>" (account: anything), e.g.
    security add-generic-password -s heimdall-api-anthropic -a "$USER" -w
(type the key at the prompt; it is never put on the command line or in a file).
Model: ~/.ragnarok/heimdall-api.json, e.g. {"openai": {"model": "..."}}; anthropic defaults to claude-opus-5-5.
The model gets the app's source and returns whole replacement files as JSON; only paths inside the folder are written.
Normally run by bin/heimdall-edit on a clean staging copy (which must then build and pass its self-test).
Every returned path is checked before anything is written; files with uncommitted changes are never overwritten.
"""
import json, os, pathlib, shutil, subprocess, sys, urllib.error, urllib.request

ENDPOINTS = {
    "anthropic": "https://api.anthropic.com/v1/messages",
    "openai": "https://api.openai.com/v1/chat/completions",
    "xai": "https://api.x.ai/v1/chat/completions",
    "gemini": "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
}
DEFAULT_MODEL = {"anthropic": "claude-opus-5-5"}


def receipt(provider, action, target):
    """One Mac receipt per file written (connector/ygg-business/hooks/mac-receipts), like Claude Code's hook.
    Fail-open and detached: a missing node or a down database never stops the edit."""
    home = pathlib.Path.home()
    node, js = shutil.which("node"), home / "Developer/ygg-mcp-business/hooks/mac-receipts/receipt.mjs"
    if not (node and js.exists()):
        return
    try:
        subprocess.Popen([str(node), str(js), "log", "--actor", f"Heimdall API ({provider})",
                          "--cmd", f"write_file {target} (contents not logged)", "--action", action, "--ref", str(target)],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ENDPOINTS:
        die(__doc__)
    provider, folder, instruction = sys.argv[1], pathlib.Path(sys.argv[2]).resolve(), sys.argv[3]
    # G4: the folder must be the Heimdall source
    if not folder.is_dir() or not (folder / "Package.swift").is_file() or not (folder / "Sources").is_dir():
        die(f"{folder} isn't the Heimdall source folder (no Package.swift / Sources)")
    r = subprocess.run(["security", "find-generic-password", "-s", f"heimdall-api-{provider}", "-w"],
                       capture_output=True, text=True)
    key = r.stdout.strip()
    if r.returncode != 0 or not key:
        die(f"no API key in the keychain for {provider} (service heimdall-api-{provider})")
    try:
        cfg = json.loads((pathlib.Path.home() / ".ragnarok/heimdall-api.json").read_text())
    except (OSError, ValueError):
        cfg = {}
    entry = cfg.get(provider) if isinstance(cfg, dict) else None
    model = (entry.get("model") if isinstance(entry, dict) else None) or DEFAULT_MODEL.get(provider)
    if not isinstance(model, str):
        model = None
    if not model:
        die(f"no model set for {provider}: add {{\"{provider}\": {{\"model\": \"...\"}}}} to ~/.ragnarok/heimdall-api.json")

    files = [f for f in ["AGENTS.md", "Package.swift", "make-app.sh"] if (folder / f).is_file()] + sorted(
        str(p.relative_to(folder)) for p in (folder / "Sources").rglob("*.swift"))
    source = "\n\n".join(f"=== {f} ===\n{(folder / f).read_text(errors='replace')}" for f in files)
    system = ("You edit a SwiftUI macOS app. Reply with ONLY a JSON object: "
              '{"files": [{"path": "relative/path", "content": "entire new file"}], "summary": "one line"}. '
              "Include only files you change. Keep it compiling. Keep the unlock gate (FIDO2 key or Touch ID, no "
              "password fallback). Never add code that prints or logs secrets.")
    user = f"Change to make: {instruction}\n\nCurrent source:\n{source}"

    if provider == "anthropic":
        body = {"model": model, "max_tokens": 32000, "system": system, "messages": [{"role": "user", "content": user}]}
        headers = {"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"}
    else:
        body = {"model": model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
        headers = {"authorization": f"Bearer {key}", "content-type": "application/json"}
    req = urllib.request.Request(ENDPOINTS[provider], data=json.dumps(body).encode(), headers=headers)
    print(f"asking {provider} ({model})…", flush=True)
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        die(f"{provider} API error {e.code}: {e.read().decode(errors='replace')[:500]}")
    except (urllib.error.URLError, TimeoutError, OSError) as e:   # G1
        die(f"couldn't reach {provider}: {getattr(e, 'reason', None) or e}")
    except ValueError:
        die(f"{provider} sent back something that isn't JSON")
    try:
        text = (data["content"][0]["text"] if provider == "anthropic" else data["choices"][0]["message"]["content"]).strip()
    except (KeyError, IndexError, TypeError, AttributeError):
        die(f"unexpected reply shape from {provider}: {json.dumps(data)[:300]}")
    if text.startswith("```"):
        text = text.split("\n", 1)[1].rsplit("```", 1)[0]
    try:
        reply = json.loads(text)
    except ValueError:
        die("the model did not return JSON:\n" + text[:1000])
    if not isinstance(reply, dict) or not isinstance(reply.get("files", []), list):
        die("the model's JSON isn't {\"files\": [...], \"summary\": ...}")
    # G2: check EVERY file first; nothing is written unless all of them are fine
    plan = []
    for f in reply.get("files", []):
        if not isinstance(f, dict) or not isinstance(f.get("path"), str) or not isinstance(f.get("content"), str):
            die(f"bad file entry from the model (needs a path and text content): {str(f)[:200]}; nothing was written")
        target = (folder / f["path"]).resolve()
        if folder not in target.parents:
            die(f"refused path outside the app folder: {f['path']}; nothing was written")
        if target.is_dir():
            die(f"refused: {f['path']} is a folder, not a file; nothing was written")
        p = target.parent
        while p != folder:   # a parent that is a file (AGENTS.md/x.swift) can't hold a file
            if p.exists() and not p.is_dir():
                die(f"refused: {f['path']} would go inside {p.relative_to(folder)}, which is a file; nothing was written")
            p = p.parent
        if any(t == target for _, t, _ in plan):
            die(f"the model sent {f['path']} twice; nothing was written")
        plan.append((f["path"], target, f["content"]))
    # G3: never overwrite uncommitted work in those files
    st = subprocess.run(["git", "-C", str(folder), "status", "--porcelain", "--"] + [str(t) for _, t, _ in plan],
                        capture_output=True, text=True)
    if st.returncode == 0 and st.stdout.strip():
        die("these files have uncommitted changes, so nothing was written (use bin/heimdall-edit, which works on a "
            "staging copy):\n" + st.stdout.rstrip())
    # G2: every file is written to a temp name next to it first; the real names change only when all writes worked
    staged = []
    try:
        for rel, target, content in plan:
            target.parent.mkdir(parents=True, exist_ok=True)
            tmp = target.with_name(f".{target.name}.api-edit-{os.getpid()}")
            tmp.write_text(content)
            if target.exists():
                os.chmod(tmp, target.stat().st_mode & 0o7777)
            staged.append((rel, target, tmp, target.exists()))
    except OSError as e:
        for _, _, tmp, _ in staged:
            tmp.unlink(missing_ok=True)
        die(f"couldn't write the change ({e}); nothing was written")
    for rel, target, tmp, existed in staged:
        os.replace(tmp, target)
        receipt(provider, "Updated" if existed else "Created", target)
        print(f"wrote {rel}", flush=True)
    print(str(reply.get("summary", "")), flush=True)


if __name__ == "__main__":
    main()
