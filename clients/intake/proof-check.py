#!/usr/bin/env python3
"""Prove Intake from this Mac. Reads URL and TOKEN from ~/.ragnarok/intake.env.

Bytes go out with curl. The token is never printed. Test rows are tagged test and archived.
"""
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import urllib.parse
import uuid
from pathlib import Path

PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000a49444154789c63000100000500010d0a2db40000000049454e44ae426082"
)
ROOT = Path(__file__).resolve().parents[2]


def scrub(text):
    return re.sub(r"[0-9a-fA-F]{32,}", "[hex]", str(text))


def fail(msg):
    sys.stderr.write(scrub(msg).rstrip() + "\n")
    raise SystemExit(1)


def read_env(path):
    out = {}
    file = Path(path)
    if not file.is_file():
        return out
    for raw in file.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        val = val.strip().strip('"').strip("'")
        out[key.strip()] = val
    return out


def conf():
    kv = read_env(os.environ.get("RAGNAROK_INTAKE_CONF") or str(Path.home() / ".ragnarok" / "intake.env"))
    url = kv.get("URL", "").rstrip("/")
    token = kv.get("TOKEN", "")
    if not url or not token:
        fail("missing URL or TOKEN")
    if token in url:
        fail("token is in the URL")
    return url, token


def curl(method, path, token=None, headers=None, data=None, timeout=60, header_sink=None):
    base, real = conf()
    url = base + path
    tmp = tempfile.mkdtemp(prefix="intake-proof-")
    try:
        out = os.path.join(tmp, "body")
        hdr = os.path.join(tmp, "hdr")
        cfg_path = os.path.join(tmp, "curl.cfg")
        lines = [
            "silent",
            "show-error",
            "max-time = %d" % int(timeout),
            'output = "%s"' % out,
            'dump-header = "%s"' % hdr,
            'url = "%s"' % url,
            'request = "%s"' % method,
            'write-out = "%{http_code}"',
        ]
        if token:
            lines.append('header = "Authorization: Bearer %s"' % token)
        for key, value in (headers or {}).items():
            lines.append('header = "%s: %s"' % (key, value))
        if data is not None:
            body = os.path.join(tmp, "req")
            with open(body, "wb") as handle:
                handle.write(data)
            lines.append('data-binary = "@%s"' % body)
        with open(cfg_path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
        os.chmod(cfg_path, 0o600)
        proc = subprocess.run(["curl", "--config", cfg_path], capture_output=True)
        code_s = proc.stdout.decode("ascii", "replace").strip()
        code = int(code_s) if code_s.isdigit() else 0
        blob = Path(out).read_bytes() if os.path.exists(out) else b""
        err = proc.stderr.decode("utf-8", "replace")
        if real and real in blob.decode("utf-8", "replace"):
            fail("response contained the token")
        if real and real in err:
            fail("curl error contained the token")
        if header_sink is not None and os.path.exists(hdr):
            header_sink.append(Path(hdr).read_text(encoding="iso-8859-1", errors="replace"))
        return code, blob, err
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def archive(item_id, token):
    code, body, err = curl("POST", "/intake/items/%s/archive" % item_id, token=token, data=b"")
    if code != 200:
        fail("archive %s failed HTTP %s %s" % (item_id, code, err or body[:200]))
    payload = json.loads(body.decode())
    if payload.get("archived") is not True or payload.get("erased") is not False:
        fail("archive did not keep the row")


def created(body):
    payload = json.loads(body.decode())
    if "id" not in payload or "sha256" not in payload:
        fail("store response missing id or sha256")
    return payload


def no_token():
    base, token = conf()
    code, body, _ = curl("GET", "/health", token=None)
    if code != 200 or b'"ok":true' not in body.replace(b" ", b""):
        fail("health without a token was %s" % code)
    code, body, _ = curl("POST", "/intake/items", token=None, headers={"Content-Type": "application/json"}, data=b'{"body":"nope","sender":"proof"}')
    if code != 401:
        fail("POST without a token was %s" % code)
    if token.encode() in body:
        fail("POST refusal echoed the token")
    code, body, _ = curl("GET", "/intake/items", token=None)
    if code != 401:
        fail("GET without a token was %s" % code)
    if token.encode() in body:
        fail("GET refusal echoed the token")
    wrong = "x" * 64
    code, body, _ = curl("GET", "/intake/items", token=wrong)
    if code != 401:
        fail("wrong token was %s" % code)
    if wrong.encode() in body or token.encode() in body:
        fail("wrong-token refusal echoed a token")
    print("no-token refused")


def text():
    _, token = conf()
    words = "intake proof text " + uuid.uuid4().hex
    raw = words.encode()
    expect = hashlib.sha256(raw).hexdigest()
    payload = json.dumps({"kind": "text", "body": words, "title": "proof text", "sender": "proof", "tags": "test", "source_machine": "proof"}).encode()
    code, body, err = curl("POST", "/intake/items", token=token, headers={"Content-Type": "application/json"}, data=payload)
    if code != 201:
        fail("text store HTTP %s %s" % (code, err or body[:300]))
    item = created(body)
    if item.get("sha256") != expect or item.get("kind") != "text":
        fail("text sha or kind mismatch")
    code, got, _ = curl("GET", "/intake/items/%s" % item["id"], token=token)
    if code != 200:
        fail("text get HTTP %s" % code)
    back = json.loads(got.decode())
    if back.get("sha256") != expect or back.get("body") != words:
        fail("text came back different")
    code, content, _ = curl("GET", "/intake/items/%s/content" % item["id"], token=token)
    if code != 200 or hashlib.sha256(content).hexdigest() != expect:
        fail("text bytes came back different")
    archive(item["id"], token)
    print("text ok", expect)


def photo():
    _, token = conf()
    expect = hashlib.sha256(PNG).hexdigest()
    code, body, err = curl("POST", "/intake/items", token=token, headers={
        "Content-Type": "image/png",
        "X-Intake-Filename": "proof.png",
        "X-Intake-Kind": "photo",
        "X-Intake-Sender": "proof",
        "X-Intake-Tags": "test",
        "X-Intake-Title": "proof photo",
        "X-Intake-Mime": "image/png",
    }, data=PNG)
    if code != 201:
        fail("photo store HTTP %s %s" % (code, err or body[:300]))
    item = created(body)
    if item.get("sha256") != expect or item.get("kind") != "photo":
        fail("photo sha or kind mismatch")
    code, content, _ = curl("GET", "/intake/items/%s/content" % item["id"], token=token)
    if code != 200 or hashlib.sha256(content).hexdigest() != expect or content != PNG:
        fail("photo bytes came back different")
    archive(item["id"], token)
    print("photo ok", expect)


def file_item():
    _, token = conf()
    raw = ("intake proof file " + uuid.uuid4().hex + "\n").encode()
    expect = hashlib.sha256(raw).hexdigest()
    code, body, err = curl("POST", "/intake/items", token=token, headers={
        "Content-Type": "text/plain",
        "X-Intake-Filename": "proof.txt",
        "X-Intake-Kind": "file",
        "X-Intake-Sender": "proof",
        "X-Intake-Tags": "test",
        "X-Intake-Title": "proof file",
    }, data=raw)
    if code != 201:
        fail("file store HTTP %s %s" % (code, err or body[:300]))
    item = created(body)
    if item.get("sha256") != expect or item.get("kind") != "file":
        fail("file sha or kind mismatch")
    code, content, _ = curl("GET", "/intake/items/%s/content" % item["id"], token=token)
    if code != 200 or hashlib.sha256(content).hexdigest() != expect:
        fail("file bytes came back different")
    archive(item["id"], token)
    print("file ok", expect)


def dedup():
    _, token = conf()
    raw = os.urandom(64)
    expect = hashlib.sha256(raw).hexdigest()
    headers = {
        "Content-Type": "application/octet-stream",
        "X-Intake-Filename": "proof-dedup.bin",
        "X-Intake-Kind": "file",
        "X-Intake-Sender": "proof",
        "X-Intake-Tags": "test",
        "X-Intake-Title": "proof dedup",
    }
    code, body, err = curl("POST", "/intake/items", token=token, headers=headers, data=raw)
    if code != 201:
        fail("dedup first HTTP %s %s" % (code, err or body[:200]))
    first = created(body)
    code, body, err = curl("POST", "/intake/items", token=token, headers=headers, data=raw)
    if code != 201:
        fail("dedup second HTTP %s %s" % (code, err or body[:200]))
    second = created(body)
    if first.get("sha256") != expect or second.get("sha256") != expect:
        fail("dedup sha mismatch")
    if first.get("id") == second.get("id"):
        fail("dedup reused the row")
    if second.get("blob_new") is not False or second.get("blob_copies") != 1:
        fail("dedup stored another copy")
    code, info, _ = curl("GET", "/intake/sha/" + expect, token=token)
    if code != 200:
        fail("sha lookup HTTP %s" % code)
    meta = json.loads(info.decode())
    if meta.get("bytes") != len(raw) or meta.get("copies") != 1 or meta.get("sha256") != expect:
        fail("one copy was not %s bytes" % len(raw))
    archive(first["id"], token)
    archive(second["id"], token)
    print("dedup ok", expect)


def search():
    _, token = conf()
    mark = "intakeproofsearch" + uuid.uuid4().hex
    payload = json.dumps({"kind": "text", "body": "find me " + mark, "title": mark, "sender": "proof", "tags": "test"}).encode()
    code, body, err = curl("POST", "/intake/items", token=token, headers={"Content-Type": "application/json"}, data=payload)
    if code != 201:
        fail("search store HTTP %s %s" % (code, err or body[:200]))
    item = created(body)
    code, listed, _ = curl("GET", "/intake/items?q=" + mark, token=token)
    if code != 200:
        fail("search HTTP %s" % code)
    rows = json.loads(listed.decode()).get("items") or []
    if not any(row.get("id") == item["id"] and mark in (row.get("title") or "") for row in rows):
        fail("search did not find the text")
    archive(item["id"], token)
    print("search ok", item["id"])


def mcp_messages(token, messages):
    raw = json.dumps(messages).encode()
    return curl("POST", "/mcp", token=token, headers={
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }, data=raw, timeout=60)


def mcp_result(body):
    text = body.decode("utf-8", "replace")
    if text.lstrip().startswith("{") or text.lstrip().startswith("["):
        return json.loads(text)
    data = []
    for line in text.splitlines():
        if line.startswith("data:"):
            data.append(line[5:].strip())
    if not data:
        fail("mcp reply was not json")
    return json.loads(data[-1])


def mcp():
    _, token = conf()
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "proof", "version": "0"}}}
    code, body, err = mcp_messages(token, init)
    if code != 200:
        fail("mcp initialize HTTP %s %s" % (code, err or scrub(body[:300])))
    words = "intake proof mcp " + uuid.uuid4().hex
    expect = hashlib.sha256(words.encode()).hexdigest()
    listing = {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
    call = {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
        "name": "ingest", "arguments": {"actor": "proof", "title": "proof mcp", "body": words, "tags": "test", "sender": "proof"}}}
    code, body, err = mcp_messages(token, [listing, call])
    if code != 200:
        code, body, err = mcp_messages(token, listing)
        if code != 200:
            fail("mcp tools/list HTTP %s %s" % (code, err or scrub(body[:300])))
        listed = mcp_result(body)
        code, body, err = mcp_messages(token, call)
        if code != 200:
            fail("mcp ingest HTTP %s %s" % (code, err or scrub(body[:300])))
        called = mcp_result(body)
    else:
        payload = mcp_result(body)
        if isinstance(payload, list) and len(payload) >= 2:
            listed, called = payload[0], payload[1]
        else:
            fail("mcp batch was not two replies")
    names = [tool.get("name") for tool in (listed.get("result") or {}).get("tools") or []]
    if "ingest" not in names or "search" not in names:
        fail("mcp tools missing ingest or search: " + ",".join(names))
    dumped = json.dumps(called)
    if expect not in dumped:
        fail("mcp ingest sha missing")
    found = re.search(r'"id"\s*:\s*(\d+)', dumped)
    if not found:
        found = re.search(r"Intake #(\d+)", dumped)
    if not found:
        fail("mcp ingest had no id")
    archive(int(found.group(1)), token)
    print("mcp ok", expect)


def traversal():
    _, token = conf()
    code, body, _ = curl("POST", "/intake/items", token=token, headers={
        "Content-Type": "application/octet-stream",
        "X-Intake-Filename": "../etc/passwd",
        "X-Intake-Sender": "proof",
        "X-Intake-Kind": "file",
    }, data=b"not-stored")
    if code == 201:
        fail("traversal filename was stored")
    if code != 400:
        fail("traversal HTTP %s" % code)
    if b"not allowed" not in body.lower() and b"filename" not in body.lower():
        fail("traversal error was unclear")
    print("traversal refused")


def disk():
    _, token = conf()
    code, body, err = curl("GET", "/intake/disk", token=token)
    if code != 200:
        fail("disk HTTP %s %s" % (code, err or body[:200]))
    if b"seagate" in body.lower():
        fail("disk report names the Seagate disk")
    payload = json.loads(body.decode())
    path = str(payload.get("path") or "")
    if not (path.startswith("/home/") and path.endswith("/Developer/ragnarok/clients/intake")):
        fail("blob path is " + path)
    free = int(payload.get("free_bytes") or 0)
    if free <= 10 * 1024 * 1024 * 1024:
        fail("free space %s is at or under the floor" % free)
    print("disk ok", path)


def clients():
    home = Path.home()
    ts = read_env(home / ".ragnarok" / "local.conf").get("ALEXUS_TAILSCALE") or "alexus"   # the intake address host
    claude = json.loads((home / ".claude.json").read_text())
    servers = claude.get("mcpServers") or {}
    for name in ("intake", "ygg-business", "ragnarok-hq"):
        if name not in servers:
            fail("claude missing " + name)
    url = str((servers["intake"] or {}).get("url") or "")
    if ts not in url or not url.endswith("/mcp"):
        fail("claude intake url")
    auth = str(((servers["intake"] or {}).get("headers") or {}).get("Authorization") or "")
    if not auth.startswith("Bearer ") or len(auth) < 40:
        fail("claude intake has no bearer token")
    grok = (home / ".grok" / "config.toml").read_text()
    if "[mcp_servers.intake]" not in grok:
        fail("grok missing intake")
    if "[cli]" not in grok:
        fail("grok lost [cli]")
    if ts not in grok:
        fail("grok intake url")
    codex = (home / ".codex" / "config.toml").read_text()
    for name in ("[mcp_servers.intake]", "[mcp_servers.node_repl]", "[mcp_servers.ygg-business-docker]"):
        if name not in codex:
            fail("codex missing " + name)
    if ts not in codex or "Authorization" not in codex:
        fail("codex intake url or auth")
    muse = json.loads((home / ".config" / "muse" / "settings.json").read_text())
    if muse.get("schema_version") != 1 or "tui" not in muse:
        fail("muse settings lost schema_version or tui")
    entry = (muse.get("mcp_servers") or {}).get("intake") or {}
    if entry.get("transport") != "streamable_http":
        fail("muse intake transport")
    if ts not in str(entry.get("url") or "") or not str(entry.get("url") or "").endswith("/mcp"):
        fail("muse intake url")
    muse_auth = str((entry.get("headers") or {}).get("Authorization") or "")
    if not muse_auth.startswith("Bearer ") or len(muse_auth) < 40:
        fail("muse intake has no bearer token")
    print("clients ok")


def load_cli():
    import importlib.util
    from importlib.machinery import SourceFileLoader
    path = ROOT / "app" / "heimdall" / "bin" / "ragnarok-intake"
    loader = SourceFileLoader("ragnarok_intake", str(path))
    spec = importlib.util.spec_from_loader("ragnarok_intake", loader)
    if spec is None:
        fail("could not load the Intake CLI")
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def cli_send(script, token, path, kind):
    proc = subprocess.run(
        [sys.executable, str(script), "--tag", "test", "--title", "proof cli " + kind, "--sender", "proof", str(path)],
        capture_output=True, text=True)
    out = proc.stdout + "\n" + proc.stderr
    if token in out:
        fail("cli printed the token")
    if proc.returncode != 0:
        fail("cli %s without --kind exit %s %s" % (kind, proc.returncode, scrub(out)[:400]))
    found = re.search(r"sha256:\s*([0-9a-f]{64})", proc.stdout)
    ident = re.search(r"id:\s*(\d+)", proc.stdout)
    got_kind = re.search(r"^kind:\s*(\S+)", proc.stdout, re.M)
    expect = hashlib.sha256(path.read_bytes()).hexdigest()
    if not found or found.group(1) != expect or not ident or not got_kind or got_kind.group(1) != kind:
        fail("cli %s without --kind mismatch %s" % (kind, scrub(proc.stdout)[:300]))
    archive(int(ident.group(1)), token)


def cli_kind():
    """A file or photo with no --kind used to crash on mime.lowercased()."""
    mod = load_cli()
    got = (
        mod.kind_for("shot.png", "image/png"),
        mod.kind_for("shot.jpg", "application/octet-stream"),
        mod.kind_for("shot.heic", ""),
        mod.kind_for("notes.txt", "text/plain"),
        mod.kind_for("notes.txt", None),
    )
    if got != ("photo", "photo", "photo", "file", "file"):
        fail("kind_for returned %s" % (got,))
    _, token = conf()
    script = ROOT / "app" / "heimdall" / "bin" / "ragnarok-intake"
    tmp = tempfile.mkdtemp(prefix="intake-cli-kind-")
    try:
        photo = Path(tmp) / "proof-shot.png"
        photo.write_bytes(PNG)
        plain = Path(tmp) / "proof-note.txt"
        plain.write_bytes(("intake proof cli file " + uuid.uuid4().hex + "\n").encode())
        cli_send(script, token, photo, "photo")
        cli_send(script, token, plain, "file")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("cli-kind ok")


def cli_args(extra):
    return [sys.executable, str(ROOT / "app" / "heimdall" / "bin" / "ragnarok-intake"), "--tag", "test", "--sender", "proof"] + extra


def stored_text(proc, token, words):
    out = proc.stdout + "\n" + proc.stderr
    if token in out:
        fail("cli printed the token")
    if proc.returncode != 0:
        fail("cli text exit %s %s" % (proc.returncode, scrub(out)[:400]))
    found = re.search(r"sha256:\s*([0-9a-f]{64})", proc.stdout)
    ident = re.search(r"id:\s*(\d+)", proc.stdout)
    got_kind = re.search(r"^kind:\s*(\S+)", proc.stdout, re.M)
    expect = hashlib.sha256(words.encode()).hexdigest()
    if not found or found.group(1) != expect or not ident or not got_kind or got_kind.group(1) != "text":
        fail("cli text mismatch %s" % scrub(proc.stdout)[:300])
    archive(int(ident.group(1)), token)


def cli_text():
    """A sentence with a URL is text. --kind text is text even when it looks like a path."""
    _, token = conf()
    mark = uuid.uuid4().hex
    words = "check https://example.com/a tomorrow " + mark
    stored_text(subprocess.run(cli_args([words]), capture_output=True, text=True), token, words)
    pathish = "notes/not-really-there-" + mark + ".md"
    stored_text(subprocess.run(cli_args(["--kind", "text", pathish]), capture_output=True, text=True), token, pathish)
    url = "https://example.com/intake-proof/" + mark
    stored_text(subprocess.run(cli_args([url]), capture_output=True, text=True), token, url)
    missing = subprocess.run(cli_args(["notes/missing-intake-proof.md"]), capture_output=True, text=True)
    if missing.returncode == 0 or "No file" not in (missing.stdout + missing.stderr):
        fail("a missing path was not refused")
    print("cli-text ok")


def header_map(raw):
    out = {}
    for line in raw.splitlines():
        if ":" not in line:
            continue
        key, val = line.split(":", 1)
        out[key.strip().lower()] = val.strip()
    return out


def filename_from_headers(raw):
    headers = header_map(raw)
    for key in ("x-intake-filename-utf8", "content-disposition"):
        match = re.search(r"UTF-8''([^;\s]+)", headers.get(key, ""), re.I)
        if match:
            return urllib.parse.unquote(match.group(1))
    return ""


def expect_download(item_id, token, filename, raw_bytes):
    sink = []
    code, body, err = curl("GET", "/intake/items/%s/content" % item_id, token=token, header_sink=sink)
    if code != 200:
        fail("download HTTP %s %s" % (code, scrub(err or body[:240])))
    if body != raw_bytes:
        fail("download bytes differ for %s" % filename)
    got = filename_from_headers(sink[0] if sink else "")
    if got != filename:
        fail("download name %r wanted %r" % (got, filename))
    code, meta, _ = curl("GET", "/intake/items/%s" % item_id, token=token)
    if code != 200:
        fail("item get HTTP %s" % code)
    item = json.loads(meta.decode())
    if item.get("original_filename") != filename or item.get("sha256") != hashlib.sha256(raw_bytes).hexdigest():
        fail("record name or sha mismatch")
    archive(item_id, token)


def cli_name():
    """A non-Latin-1 filename must store, come back whole, and download without a 500."""
    _, token = conf()
    tmp = tempfile.mkdtemp(prefix="intake-cli-name-")
    try:
        names = {
            "写真.png": PNG,
            "Screenshot 4.18.00\u202fPM.png": b"narrow name proof\n",
        }
        for name, raw in names.items():
            path = Path(tmp) / name
            path.write_bytes(raw)
            proc = subprocess.run(cli_args([str(path)]), capture_output=True, text=True)
            out = proc.stdout + "\n" + proc.stderr
            if token in out:
                fail("cli printed the token")
            if proc.returncode != 0:
                fail("cli name exit %s %s" % (proc.returncode, scrub(out)[:400]))
            ident = re.search(r"id:\s*(\d+)", proc.stdout)
            found = re.search(r"sha256:\s*([0-9a-f]{64})", proc.stdout)
            if not ident or not found or found.group(1) != hashlib.sha256(raw).hexdigest():
                fail("cli name sha %s" % scrub(proc.stdout)[:300])
            expect_download(int(ident.group(1)), token, name, raw)
        words = "json name " + uuid.uuid4().hex
        payload = json.dumps({
            "kind": "file", "filename": "写真.png", "body": words, "sender": "proof", "tags": "test", "title": "json name",
        }).encode()
        code, body, err = curl("POST", "/intake/items", token=token, headers={"Content-Type": "application/json"}, data=payload)
        if code != 201:
            fail("json name HTTP %s %s" % (code, err or body[:300]))
        item = created(body)
        if item.get("original_filename") != "写真.png":
            fail("json stored name %r" % item.get("original_filename"))
        expect_download(int(item["id"]), token, "写真.png", words.encode())
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("cli-name ok")


def tab_safe():
    """Safe files open. A script or app is only shown in Finder, and the copy is quarantined."""
    src = (ROOT / "app" / "heimdall" / "Sources" / "Heimdall" / "Intake.swift").read_text(encoding="utf-8")
    if "NSWorkspace.shared.open" not in src:
        fail("the Intake tab does not open a stored file")
    if "activateFileViewerSelecting" not in src:
        fail("a risky file is not revealed in Finder")
    if "com.apple.quarantine" not in src:
        fail("an opened copy is not marked as downloaded data")
    if "func openPlan" not in src:
        fail("open has no type check")
    print("tab-safe ok")


def json_file():
    """A .json file is the file. Its contents are not request fields."""
    _, token = conf()
    raw = b'{"body":"not the file","sender":"proof","kind":"text","title":"hijack"}\n'
    tmp = tempfile.mkdtemp(prefix="intake-json-file-")
    item_id = None
    try:
        path = Path(tmp) / "critic.json"
        path.write_bytes(raw)
        proc = subprocess.run(cli_args([str(path)]), capture_output=True, text=True)
        out = proc.stdout + "\n" + proc.stderr
        if token in out:
            fail("cli printed the token")
        if proc.returncode != 0:
            fail("json file exit %s %s" % (proc.returncode, scrub(out)[:400]))
        found = re.search(r"sha256:\s*([0-9a-f]{64})", proc.stdout)
        ident = re.search(r"id:\s*(\d+)", proc.stdout)
        got_kind = re.search(r"^kind:\s*(\S+)", proc.stdout, re.M)
        if ident:
            item_id = int(ident.group(1))
        expect = hashlib.sha256(raw).hexdigest()
        if not found or found.group(1) != expect or item_id is None or not got_kind or got_kind.group(1) != "file":
            fail("json file stored as fields %s" % scrub(proc.stdout)[:300])
        expect_download(item_id, token, "critic.json", raw)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        if item_id is not None:
            archive(item_id, token)
    print("json-file ok")


def search_chars():
    """A search for AT&T and c++ comes back whole."""
    _, token = conf()
    words = "AT&T c++ =x " + uuid.uuid4().hex
    payload = json.dumps({
        "kind": "text", "body": words, "title": words, "sender": "proof", "tags": "test",
    }).encode()
    code, body, err = curl("POST", "/intake/items", token=token, headers={"Content-Type": "application/json"}, data=payload)
    if code != 201:
        fail("search-chars store HTTP %s %s" % (code, err or body[:300]))
    item = created(body)
    try:
        q = urllib.parse.urlencode({"q": words, "limit": "20"})
        code, got, err = curl("GET", "/intake/items?" + q, token=token)
        if code != 200:
            fail("search-chars HTTP %s %s" % (code, err or got[:300]))
        rows = json.loads(got.decode()).get("items") or []
        if not any(row.get("id") == item["id"] or (row.get("title") == words) for row in rows):
            fail("search-chars missed the item")
    finally:
        archive(int(item["id"]), token)
    print("search-chars ok")


def cli():
    _, token = conf()
    words = "intake proof cli " + uuid.uuid4().hex
    expect = hashlib.sha256(words.encode()).hexdigest()
    script = ROOT / "app" / "heimdall" / "bin" / "ragnarok-intake"
    proc = subprocess.run([sys.executable, str(script), "--tag", "test", "--title", "proof cli", "--sender", "proof", words], capture_output=True, text=True)
    out = proc.stdout + "\n" + proc.stderr
    if token in out:
        fail("cli printed the token")
    if proc.returncode != 0:
        fail("cli exit %s %s" % (proc.returncode, scrub(out)[:400]))
    found = re.search(r"sha256:\s*([0-9a-f]{64})", proc.stdout)
    ident = re.search(r"id:\s*(\d+)", proc.stdout)
    if not found or found.group(1) != expect or not ident:
        fail("cli sha mismatch")
    archive(int(ident.group(1)), token)
    print("cli ok", expect)


def lan_closed():
    url, _ = conf()
    code, body, _ = curl("GET", "/health", token=None, timeout=20)
    if code != 200:
        fail("tailscale health %s" % code)
    host = "alexus.local"
    local = read_env(Path.home() / ".ragnarok" / "local.conf")
    if local.get("ALEXUS_HOST"):
        host = local["ALEXUS_HOST"]
    port = int(url.rsplit(":", 1)[-1])
    try:
        sock = socket.create_connection((host, 22), 5)
        sock.close()
    except OSError as exc:
        fail("home address did not answer on port 22 (%s)" % exc.__class__.__name__)
    try:
        sock = socket.create_connection((host, port), 5)
        sock.close()
    except OSError:
        print("lan closed", host, port)
        return
    fail("intake port is open on the home-network address")


MODES = {
    "no-token": no_token,
    "text": text,
    "photo": photo,
    "file": file_item,
    "dedup": dedup,
    "search": search,
    "mcp": mcp,
    "traversal": traversal,
    "disk": disk,
    "clients": clients,
    "cli": cli,
    "cli-kind": cli_kind,
    "cli-text": cli_text,
    "cli-name": cli_name,
    "tab-safe": tab_safe,
    "json-file": json_file,
    "search-chars": search_chars,
    "lan-closed": lan_closed,
}


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in MODES:
        fail("usage: proof-check.py " + "|".join(MODES))
    try:
        MODES[sys.argv[1]]()
    except SystemExit:
        raise
    except Exception as exc:
        fail("%s %s" % (exc.__class__.__name__, str(exc)[:300]))


if __name__ == "__main__":
    main()
