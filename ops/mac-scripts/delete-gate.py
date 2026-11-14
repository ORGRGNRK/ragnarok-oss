#!/usr/bin/env python3
"""delete-gate: a Claude Code PreToolUse hook. Any tool call that deletes files needs the owner's hardware presence.

What counts as a delete (Bash): rm, rmdir, unlink, shred, srm, trash, truncate; mv onto /dev/null; find ... -delete / -exec rm; git rm (not --cached);
git clean -f; rsync --delete. It looks inside sudo/xargs/env/nohup/time/exec, `bash|sh|zsh -c "..."` and `ssh host "..."`.
MCP tools whose name says delete or trash count too (Airtable delete_records, Gmail trash_*, ...).

How it asks:
  - a YubiKey or the uTrust spare is plugged in -> notification + touch the key (alexus-core fido-auth.sh, verified signature)
  - otherwise -> Touch ID sheet from Ragnarok.app's EnclaveAuthenticator (Secure Enclave key, enrolled 2026-11-04),
    and the sheet names what is being deleted.
Approved -> exit 0 (Claude Code's normal permission rules still apply after this). Denied, timed out, or no way to ask ->
exit 2, the tool call is blocked and the reason goes back to the model. Fails CLOSED.

Not gated, on purpose: deletes whose every target is inside Claude Code's own scratch folder (/private/tmp/claude-501/...),
so a session cleaning its temp files doesn't train the owner to tap through the sheet.
Limits, said plainly: it reads command TEXT. A delete hidden in a script file, a python -c, or a variable it can't expand is
not seen unless the words above appear. Codex/other CLIs don't run Claude Code hooks.

Every decision is logged to ~/.ragnarok/heimdall-access.jsonl (Heimdall's access log) as method "delete-gate:...".
--check "<command>" prints whether a command would be gated, without asking (for testing).
"""
import json, os, re, shlex, subprocess, sys, secrets, datetime, time, hashlib, base64, tempfile

HOME = os.path.expanduser("~")
ACCESS_LOG = os.path.join(HOME, ".ragnarok/heimdall-access.jsonl")
ENCLAVE = os.path.join(HOME, "Applications/Ragnarok.app/Contents/Resources/EnclaveAuthenticator")
FIDO = os.path.join(HOME, "Developer/ragnarok/agents/alexus-core/bin/fido-auth.sh")
FIDO_TOKEN = "/opt/homebrew/bin/fido2-token"
SCRATCH = ("/private/tmp/claude-501/", "/tmp/claude-501/")

DELETERS = {"rm", "rmdir", "unlink", "shred", "srm", "trash", "truncate"}
WRAPPERS = {"sudo", "xargs", "env", "nohup", "time", "exec", "command", "doas", "caffeinate",
            "timeout", "nice", "ionice", "stdbuf", "setsid", "watch", "flock", "chronic", "parallel", "busybox"}
SHELLS = {"bash", "sh", "zsh", "dash"}
KEYWORDS = {"do", "then", "else", "elif", "if", "while", "until", "!", "{", "}"}
# After a wrapper we look for the first of these words, whatever options sit in between (sudo -u root rm, xargs -n 1 rm).
INNER = DELETERS | SHELLS | {"ssh", "find", "git", "rsync", "mv", "eval"}
GIT_OPTS_WITH_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
MAX_SHOWN = 130  # the Touch ID sheet cuts longer text, so anything longer is refused rather than half-shown
SEPS = {";", "&&", "||", "|", "&", "\n", "(", ")", "|&"}


def tokens(cmd):
    lx = shlex.shlex(cmd.replace("\n", " ; "), posix=True, punctuation_chars=";&|()")
    lx.whitespace_split = True
    lx.commenters = ""
    return list(lx)


def segments(toks):
    seg = []
    for t in toks:
        if t in SEPS or set(t) <= set(";&|()"):
            if seg:
                yield seg
            seg = []
        else:
            seg.append(t)
    if seg:
        yield seg


def scratch_only(targets):
    paths = [t for t in targets if not t.startswith("-")]

    def inside(p):
        if not os.path.isabs(p) or any(c in p for c in "$`"):
            return False
        return (os.path.realpath(p) + "/").startswith(SCRATCH)

    return bool(paths) and all(inside(p) for p in paths)


def seg_deletes(seg, depth=0):
    """Return a short description if this simple command deletes something, else None."""
    i = 0
    while i < len(seg) and (seg[i] in KEYWORDS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", seg[i])):
        i += 1  # FOO=bar prefixes and shell words like do/then/{
    if i >= len(seg):
        return None
    name, rest = os.path.basename(seg[i]), seg[i + 1:]
    if name in WRAPPERS:
        for j, word in enumerate(rest):
            if os.path.basename(word) in INNER:
                d = seg_deletes(rest[j:], depth)
                if d:
                    return d
        return None
    if name in DELETERS:
        return None if scratch_only(rest) else " ".join([name] + rest)
    if name == "eval" and rest and depth < 3:
        return deletes(" ".join(rest), depth + 1)
    if name in SHELLS and depth < 3:
        # -c, and combined forms like -lc
        j = next((x for x, r in enumerate(rest) if r.startswith("-") and not r.startswith("--") and "c" in r), None)
        if j is not None and j + 1 < len(rest):
            return deletes(rest[j + 1], depth + 1)
    if name == "ssh" and depth < 3:
        # ssh [opts] host command...: the remote command is whatever follows the first non-option word
        k, opts_with_arg = 0, set("bcDEeFIiJLlmOopQRSWw")
        while k < len(rest) and rest[k].startswith("-"):
            k += 2 if (len(rest[k]) == 2 and rest[k][1] in opts_with_arg) else 1
        if k + 1 < len(rest):
            d = deletes(" ".join(rest[k + 1:]), depth + 1)
            return f"on {rest[k]}: {d}" if d else None
    if name == "find" and ("-delete" in rest or any(rest[x] in ("-exec", "-execdir", "-ok") and x + 1 < len(rest)
                                                      and os.path.basename(rest[x + 1]) in DELETERS for x in range(len(rest)))):
        return " ".join(["find"] + rest)
    if name == "git" and rest:
        k = 0
        while k < len(rest) and rest[k].startswith("-"):
            k += 2 if rest[k] in GIT_OPTS_WITH_ARG else 1
        sub = rest[k:]
        if sub[:1] == ["rm"] and "--cached" not in sub:
            return " ".join(["git"] + rest)
        if sub[:1] == ["clean"] and any(r.startswith("-") and "f" in r.lstrip("-") or r == "--force" for r in sub[1:]):
            return " ".join(["git"] + rest)
    if name == "mv" and "/dev/null" in rest:
        return " ".join(["mv"] + rest)
    if name == "rsync" and any(r.startswith("--delete") or r == "--remove-source-files" for r in rest):
        return " ".join(["rsync"] + rest)
    return None


def deletes(cmd, depth=0):
    """Every delete in the command, joined, so the approval sheet shows all of them, not just the first."""
    found = []
    if depth < 3:
        # command substitutions run even inside double quotes; single-quoted text is literal, so drop it first
        visible = re.sub(r"'[^']*'", "''", cmd)
        for dollar, tick in re.findall(r"\$\((.*)\)|`([^`]*)`", visible):
            d = deletes(dollar or tick, depth + 1)
            if d:
                found.append(d)
    try:
        toks = tokens(cmd.replace("`", " ; "))
    except ValueError:
        # can't parse (unbalanced quotes): fall back to words, and err toward asking
        m = re.search(r"(?:^|[\s;&|(/])(rm|rmdir|unlink|shred|srm|trash|truncate)\s", cmd + " ")
        if m:
            found.append(cmd.strip())
    else:
        for seg in segments(toks):
            d = seg_deletes(seg, depth)
            if d:
                found.append(d)
    return " + ".join(dict.fromkeys(found)) or None


def log(method, ok, detail):
    rec = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "method": "delete-gate:" + method, "ok": ok, "detail": detail[:300]}
    try:
        os.makedirs(os.path.dirname(ACCESS_LOG), exist_ok=True)
        with open(ACCESS_LOG, "a") as f:
            f.write(json.dumps(rec) + "\n")
    except OSError:
        pass


def key_plugged():
    try:
        out = subprocess.run([FIDO_TOKEN, "-L"], capture_output=True, text=True, timeout=5).stdout
        return bool(out.strip())
    except Exception:
        return False


def notify(text):
    try:
        subprocess.run(["osascript", "-e", f"display notification {json.dumps(text)} with title \"Ragnarok delete gate\" sound name \"Funk\""],
                       timeout=5, capture_output=True)
    except Exception:
        pass


def ask(what):
    """Returns (approved, method, detail)."""
    if key_plugged() and os.access(FIDO, os.X_OK):
        notify("Touch your security key to allow: " + what[:120])
        try:
            r = subprocess.run([FIDO], capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            return False, "fido2", "no touch within 60s"
        ok = r.returncode == 0 and "AUTH_KEY_OK" in r.stdout
        label = r.stdout.strip().split(":")[-1] if ok else ""
        if ok or r.returncode != 3:
            return ok, "fido2:" + (label or "none"), "" if ok else (r.stderr.strip().splitlines() or ["failed"])[-1]
        # code 3 = plugged-in device isn't an enrolled key: fall through to Touch ID
    if not os.access(ENCLAVE, os.X_OK):
        return False, "none", f"no way to ask: {ENCLAVE} missing and no enrolled key plugged in"
    challenge = secrets.token_hex(16)
    reason = "allow deleting: " + what[:150]
    try:
        r = subprocess.run([ENCLAVE, "--challenge", challenge, "--reason", reason], capture_output=True, text=True, timeout=100)
        res = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else {}
    except Exception as e:
        return False, "touchid", f"authenticator failed: {e}"
    ok = r.returncode == 0 and res.get("ok") is True and res.get("challenge") == challenge and bool(res.get("signature"))
    return ok, "touchid", "" if ok else str(res.get("error") or f"exit {r.returncode}")


# ---- On Alexus (claude@alexus): no Touch ID or YubiKey here, so ask the Mac. ----
# The hook writes a request; gate-relay.py on the Mac shows Touch ID and the Secure Enclave signs the challenge;
# this side verifies the signature against the Mac's public key, kept where claude@ can read it but not change it.
# challenge = sha256(nonce + "\n" + what)[:32]: the Mac recomputes it before asking, so a request whose text was
# swapped is refused, and the signature only ever approves this exact delete.
ON_ALEXUS = sys.platform.startswith("linux") and os.uname().nodename.lower().startswith("alexus")
GATE_DIR = os.path.join(HOME, ".ragnarok/gate")
def _owner_home():
    """Home of whoever owns this repo checkout (the owner), even when an AI login runs the hook."""
    import pwd
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
    try:
        return pwd.getpwuid(os.stat(repo).st_uid).pw_dir
    except (OSError, KeyError):
        return HOME


MAC_PUBKEY = os.path.join(_owner_home(), ".ragnarok-gate/mac-enclave.pub.pem")
REMOTE_WAIT = 95


def challenge_for(nonce, what):
    return hashlib.sha256((nonce + "\n" + what).encode()).hexdigest()[:32]


def verify_sig(challenge, sig_b64):
    try:
        sig = base64.b64decode(sig_b64, validate=True)
    except Exception:
        return False
    with tempfile.TemporaryDirectory() as t:
        pf, sf = os.path.join(t, "p"), os.path.join(t, "s")
        open(pf, "wb").write(("ragnarok-chain:v1:" + challenge).encode())
        open(sf, "wb").write(sig)
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", MAC_PUBKEY, "-signature", sf, pf],
                           capture_output=True, text=True, timeout=10)
        return r.returncode == 0 and "Verified OK" in r.stdout


def ask_remote(what):
    if not os.path.isfile(MAC_PUBKEY):
        return False, "remote", f"no Mac public key at {MAC_PUBKEY}"
    req, resp = os.path.join(GATE_DIR, "req"), os.path.join(GATE_DIR, "resp")
    for d in (GATE_DIR, req, resp):
        os.makedirs(d, mode=0o700, exist_ok=True)
    rid, nonce = secrets.token_hex(8), secrets.token_hex(16)
    challenge = challenge_for(nonce, what)
    tmp = os.path.join(req, f".{rid}.tmp")
    with open(tmp, "w") as f:
        json.dump({"id": rid, "nonce": nonce, "challenge": challenge, "what": what,
                   "created": datetime.datetime.now(datetime.timezone.utc).isoformat()}, f)
    os.replace(tmp, os.path.join(req, rid + ".json"))
    rpath, deadline = os.path.join(resp, rid + ".json"), time.time() + REMOTE_WAIT
    try:
        while time.time() < deadline and not os.path.exists(rpath):
            time.sleep(0.5)
        if not os.path.exists(rpath):
            return False, "touchid-via-mac", "no answer from the Mac within 95s (is gate-relay running there?)"
        res = json.load(open(rpath))
    except Exception as e:
        return False, "touchid-via-mac", f"bad answer: {e}"
    finally:
        for p in (os.path.join(req, rid + ".json"), rpath):
            try:
                os.remove(p)
            except OSError:
                pass
    if not res.get("approved"):
        return False, "touchid-via-mac", str(res.get("error") or "denied on the Mac")
    if res.get("challenge") != challenge or not verify_sig(challenge, res.get("signature", "")):
        return False, "touchid-via-mac", "signature did not verify against the Mac's key"
    return True, "touchid-via-mac", ""


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        d = deletes(sys.argv[2])
        print(("GATED: " + d) if d else "not gated")
        return 0
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0  # not a hook payload; never wedge a tool call on our own parse error
    tool = data.get("tool_name", "")
    inp = data.get("tool_input") or {}
    what = None
    if tool == "Bash":
        what = deletes(str(inp.get("command", "")))
    elif tool.startswith("mcp__") and re.search(r"delete|trash", tool.split("__")[-1], re.I):
        what = f"{tool} {json.dumps(inp)[:120]}"
    if not what:
        return 0
    if len(what) > MAX_SHOWN:
        log("too-long", False, what)
        print(f"Delete blocked by the owner's hardware gate: it is {len(what)} characters and the Touch ID sheet can only show "
              f"{MAX_SHOWN}, so he could not see all of it. Nothing was deleted. Split it into smaller deletes.", file=sys.stderr)
        return 2
    ok, method, detail = ask_remote(what) if ON_ALEXUS else ask(what)
    log(method, ok, what + ("" if ok else f"  [{detail}]"))
    if ok:
        return 0
    print(f"Delete blocked by the owner's hardware gate ({method}: {detail}). Nothing was deleted. "
          f"Do not retry or work around it; tell the owner what you wanted to delete and why.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # Claude Code only blocks on exit 2, so any crash here would otherwise let the delete run
        print(f"Delete blocked: the hardware gate crashed ({e}). Nothing was deleted. Tell the owner.", file=sys.stderr)
        sys.exit(2)
