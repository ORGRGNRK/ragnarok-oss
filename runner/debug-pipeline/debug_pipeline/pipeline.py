"""One ticket, one container, one change at a time.

The repair step reuses pipeline_debugger_controller (file replacements, frozen
checks). The round cap matches ragnarok-heal: 4 tries, then stop. The receipt
log is written here, on the host. The worker can read a read-only copy.
"""
import difflib
import hashlib
import importlib.util
import io
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tarfile
from pathlib import Path

from debug_pipeline.docker_plan import assert_safe, plan_create, plan_disconnect, plan_exec
from debug_pipeline.prompt import POINTER, build_prompt, clip, failure_excerpt
from debug_pipeline.receipt import ReceiptLog
from debug_pipeline.scrub import SecretSurvived, load_redactor, scrub, scrub_bytes, survives

ALPHABET = set("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build"}
MAX_ROUNDS = 4
TEST_TIMEOUT = 60
VALIDATOR_CHANGED = "validator changed during the test"
VALIDATOR_CHANGED_CODE = -2
_SHOWN_LIMIT = 4000


def _shown_test_output(stdout, stderr, code, limit=_SHOWN_LIMIT):
    """Text a failed test hands back. Stderr wins. A traceback keeps its tail.
    A passing test keeps the start of its output."""
    if isinstance(stdout, bytes):
        stdout = stdout.decode("utf-8", "replace")
    if isinstance(stderr, bytes):
        stderr = stderr.decode("utf-8", "replace")
    stdout = stdout or ""
    stderr = stderr or ""
    if code == 0:
        return (stdout + stderr)[:limit]
    marker = "Traceback (most recent call last):"
    if stderr.strip() and marker not in stderr and marker in stdout:
        body = stdout
    else:
        body = stderr if stderr.strip() else stdout
    if len(body) <= limit:
        return body
    return body[-limit:].lstrip("\n")
# Customer processes share uid 65534 with the entrypoint. Stop every pid except
# pid 1 and this shell, then leave them stopped so the tmpfs tar is stable.
FREEZE_PROCESSES = r"""set -eu
self=$$
pass=0
while [ "$pass" -lt 5 ]; do
  hit=0
  for entry in /proc/[0-9]*; do
    pid=${entry#/proc/}
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$pid" -eq 1 ] || [ "$pid" -eq "$self" ]; then
      continue
    fi
    rest=$(sed -n 's/.*) //p' "/proc/$pid/stat" 2>/dev/null || true)
    state=${rest%% *}
    case "$state" in
      T|t) continue ;;
    esac
    if kill -STOP "$pid" 2>/dev/null; then
      hit=1
    fi
  done
  if [ "$hit" -eq 0 ]; then
    exit 0
  fi
  pass=$((pass + 1))
done
echo "container processes were still running" >&2
exit 1
"""


def repo_root():
    return Path(__file__).resolve().parents[3]


def valid_ticket(ticket):
    return isinstance(ticket, str) and len(ticket) == 6 and set(ticket) <= ALPHABET


def load_controller(repo):
    path = repo / "app" / "heimdall" / "bin" / "pipeline_debugger_controller.py"
    spec = importlib.util.spec_from_file_location("pipeline_debugger_controller", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Fence:
    """Refuses a host write outside the run's own folders."""

    def __init__(self, roots):
        self.roots = [Path(r).resolve() for r in roots]

    def allow(self, path):
        path = Path(path).resolve()
        if any(path == root or root in path.parents for root in self.roots):
            return path
        raise PermissionError(f"refusing to write outside the run folders: {path}")


class FolderTicketStore:
    """Local stand-in for the ticket site. Keys look like intake:<ms>:<TICKET>.

    This never talks to Cloudflare.
    """

    def __init__(self, root, fence=None):
        self.root = Path(root)
        self.fence = fence
        self.root.mkdir(parents=True, exist_ok=True)

    def intake_name(self, ticket):
        if not self.root.exists():
            return None
        for path in sorted(self.root.iterdir()):
            parts = path.name.split(":")
            if len(parts) >= 3 and parts[0] == "intake" and parts[-1].removesuffix(".json") == ticket:
                return path.name
        return None

    def has_ticket(self, ticket):
        return self.intake_name(ticket) is not None

    def attach(self, ticket, record):
        if not self.has_ticket(ticket):
            raise LookupError(f"no local ticket {ticket}")
        path = self.root / f"debug-attach:{ticket}.json"
        if self.fence is not None:
            self.fence.allow(path)
        path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return path


def is_test_path(name):
    path = Path(name)
    if path.name.startswith("test_") or path.name.endswith("_test.py"):
        return True
    return "tests" in path.parts


def is_validator_path(name):
    """Files that decide the verdict. check.py and package.json are included.

    is_test_path does not match those names. They still must not be editable.
    """
    if Path(name).name in {"check.py", "package.json"}:
        return True
    return is_test_path(name)


def _mode_bits(mode):
    return mode & 0o777


def _frozen_mode(mode):
    """Keep the executable bit and drop the write bits."""
    mode = _mode_bits(mode) & ~0o222
    if mode & 0o111:
        return mode | 0o555
    return mode | 0o444


def _safe_rel(name):
    rel = Path(name)
    if not name or rel.is_absolute() or ".." in rel.parts:
        raise ValueError("path rejected")
    return name


# Longest first so "&&" is not read as two "&" operators.
_SHELL_OPS = ("&&", "||", ";;", ">>", "<<", ">&", "<&", ">", "<", ";", "|", "&", "(", ")")
_ENTRY_SUFFIXES = {
    ".js", ".mjs", ".cjs", ".py", ".sh", ".bash", ".rb", ".php", ".ts", ".tsx", ".jsx",
}


def _op_at(text, index):
    for op in _SHELL_OPS:
        if text.startswith(op, index):
            return op
    return None


def _shell_spans(command):
    """Split a command into words and operators. Operators stay operators.

    Command substitution and backslashes are rejected instead of being quoted
    into a different command.
    """
    spans = []
    index = 0
    length = len(command)
    while index < length:
        char = command[index]
        if char in " \t":
            index += 1
            continue
        if char in "\n\r`$\\" or command.startswith("$(", index):
            raise ValueError("test command is not supported")
        op = _op_at(command, index)
        if op:
            spans.append(("op", index, index + len(op), op))
            index += len(op)
            continue
        if char in "'\"":
            start = index
            quote = char
            index += 1
            buf = []
            while index < length and command[index] != quote:
                if command[index] in "\n\r`$\\":
                    raise ValueError("test command is not supported")
                buf.append(command[index])
                index += 1
            if index >= length or command[index] != quote:
                raise ValueError("test command could not be frozen")
            index += 1
            spans.append(("word", start, index, "".join(buf)))
            continue
        start = index
        buf = []
        while index < length and command[index] not in " \t\n\r'\"" and _op_at(command, index) is None:
            if command[index] in "`$\\":
                raise ValueError("test command is not supported")
            buf.append(command[index])
            index += 1
        if index == start:
            raise ValueError("test command is not supported")
        spans.append(("word", start, index, "".join(buf)))
    return spans


def _rel_token(text):
    if text.startswith("./"):
        return text[2:]
    return text


def command_file_tokens(command, names):
    found = []
    known = set(names)
    for kind, _start, _end, text in _shell_spans(command):
        if kind != "word":
            continue
        rel = _rel_token(text)
        if rel in known and rel not in found:
            found.append(rel)
    return found


def _command_start(spans, index):
    return index == 0 or spans[index - 1][0] == "op"


def _pkg_span_end(spans, index):
    """End index of an npm/yarn/pnpm test command starting at spans[index]."""
    if not _command_start(spans, index) or spans[index][0] != "word":
        return None
    words = []
    cursor = index
    while cursor < len(spans) and spans[cursor][0] == "word" and len(words) < 3:
        words.append(spans[cursor][3])
        cursor += 1
    if not words or words[0] not in {"npm", "yarn", "pnpm"}:
        return None
    if len(words) >= 2 and words[1] == "test":
        return index + 2
    if len(words) >= 3 and words[1] == "run" and words[2] == "test":
        return index + 3
    return None


def _command_has_package_test(command):
    spans = _shell_spans(command)
    return any(_pkg_span_end(spans, index) is not None for index in range(len(spans)))


def _looks_like_entry(token):
    if not token or token.startswith("-"):
        return False
    if "/" in token:
        return True
    return Path(token).suffix.lower() in _ENTRY_SUFFIXES


def script_entry_files(script, names):
    """Files a package test script runs. Missing entry files are not left writable."""
    found = []
    known = set(names)
    for kind, _start, _end, text in _shell_spans(script):
        if kind != "word":
            continue
        rel = _rel_token(text)
        if rel in known:
            if rel not in found:
                found.append(rel)
        elif _looks_like_entry(rel):
            raise ValueError("package.json test script is not frozen")
    return found


def _package_test_script(package):
    if not package:
        return None
    try:
        meta = json.loads(package.decode("utf-8"))
    except (UnicodeError, ValueError):
        return None
    scripts = meta.get("scripts") if isinstance(meta, dict) else None
    if not isinstance(scripts, dict):
        return None
    script = scripts.get("test")
    if not isinstance(script, str) or not script.strip():
        return None
    return script.strip()


def _rewrite_shell(command, rel_to_abs, package_script):
    """Rewrite file words. Operators and the spacing around them stay as written."""
    spans = _shell_spans(command)
    if package_script is not None and not any(kind == "op" for kind, _s, _e, _t in spans):
        return _rewrite_shell(package_script, rel_to_abs, None)
    out = []
    last = 0
    index = 0
    while index < len(spans):
        if package_script is not None:
            end = _pkg_span_end(spans, index)
            if end is not None:
                start = spans[index][1]
                stop = spans[end - 1][2]
                out.append(command[last:start])
                out.append(_rewrite_shell(package_script, rel_to_abs, None))
                last = stop
                index = end
                continue
        kind, start, stop, text = spans[index]
        out.append(command[last:start])
        if kind == "word" and _rel_token(text) in rel_to_abs:
            out.append(shlex.quote(rel_to_abs[_rel_token(text)]))
        else:
            out.append(command[start:stop])
        last = stop
        index += 1
    out.append(command[last:])
    return "".join(out)


def rewrite_command(command, rel_to_abs, package, locked):
    """Point the check at the frozen copies. Never leave a locked relative path."""
    text = command.strip()
    if not text:
        raise ValueError("test command could not be frozen")
    script = None
    if _command_has_package_test(text):
        script = _package_test_script(package)
        if script is None:
            raise ValueError("package.json test script is not frozen")
    rewritten = _rewrite_shell(text, rel_to_abs, script)
    for kind, _start, _end, token in _shell_spans(rewritten):
        if kind != "word":
            continue
        if _rel_token(token) in locked:
            raise ValueError("test command still names a writable file")
        if ".." in Path(token).parts:
            raise ValueError("test command is not supported")
    return rewritten


# A runner that searches the working directory would execute the writable copies.
_DISCOVERY_WORDS = {
    "discover", "unittest", "pytest", "py.test", "nose", "nose2",
    "jest", "vitest", "mocha",
}


def _word_names_frozen(token, rel_to_abs):
    if _rel_token(token) in rel_to_abs:
        return True
    return token in rel_to_abs.values()


def _runs_from_validator(command, rel_to_abs):
    """True when the command can load checks by walking a directory."""
    words = [text for kind, _s, _e, text in _shell_spans(command) if kind == "word"]
    lowered = {word.lower() for word in words}
    if lowered & _DISCOVERY_WORDS:
        return True
    if "--test" in lowered and (
        lowered & {"node", "nodejs"} or any(word.endswith("/node") for word in lowered)
    ):
        return True
    if "go" in lowered and "test" in lowered:
        return True
    return not any(_word_names_frozen(word, rel_to_abs) for word in words)


def _root_at(token, customer):
    """Index of an absolute customer path inside one shell word, or -1."""
    customer = str(customer).rstrip("/")
    if not customer or customer == "/":
        return -1
    start = 0
    while True:
        idx = token.find(customer, start)
        if idx < 0:
            return -1
        end = idx + len(customer)
        if end == len(token) or token[end] == "/":
            if idx == 0:
                return 0
            before = token[idx - 1]
            head = token[:idx]
            if before in "=/" or (
                head.startswith("-") and "/" not in head and head[1:].replace("-", "").isalnum()
            ):
                return idx
        start = idx + 1


def _swap_root(token, customer, validator):
    customer = str(customer).rstrip("/")
    validator = str(validator).rstrip("/")
    idx = _root_at(token, customer)
    if idx < 0:
        return token
    return token[:idx] + validator + token[idx + len(customer):]


def _mentions_tree(token, customer):
    return _root_at(token, customer) >= 0


def _retarget_tree(command, customer, validator):
    spans = _shell_spans(command)
    out = []
    last = 0
    for kind, start, stop, text in spans:
        out.append(command[last:start])
        if kind == "word":
            swapped = _swap_root(text, customer, validator)
            out.append(shlex.quote(swapped) if swapped != text else command[start:stop])
        else:
            out.append(command[start:stop])
        last = stop
    out.append(command[last:])
    return "".join(out)


def _command_names_tree(command, customer):
    for kind, _start, _end, text in _shell_spans(command):
        if kind == "word" and (_mentions_tree(text, customer) or ".." in Path(text).parts):
            return True
    return False


def _entry_script(customer_root, rewritten, start_root):
    customer = shlex.quote(str(customer_root))
    start = shlex.quote(str(start_root))
    return (
        "#!/bin/sh\n"
        "set -eu\n"
        f"export PYTHONPATH={customer}\n"
        f"export NODE_PATH={customer}\n"
        f"cd {start}\n"
        f"exec sh -c {shlex.quote(rewritten)}\n"
    )


def build_frozen_validator(file_map, command, customer_root, validator_root):
    """Copy the check out of the writable tree and point the command at it.

    file_map is rel -> (bytes, mode). The returned payload includes run-frozen.sh.
    """
    names = set(file_map)
    locked = {name for name in names if is_validator_path(name)}
    for rel in command_file_tokens(command, names):
        _safe_rel(rel)
        locked.add(rel)
    package = file_map["package.json"][0] if "package.json" in names else b""
    if _command_has_package_test(command):
        script = _package_test_script(package)
        if script is None:
            raise ValueError("package.json test script is not frozen")
        for rel in script_entry_files(script, names):
            _safe_rel(rel)
            locked.add(rel)
    root = Path(validator_root)
    rel_to_abs = {rel: str(root / rel) for rel in locked}
    rewritten = rewrite_command(command, rel_to_abs, package, locked)
    if _runs_from_validator(rewritten, rel_to_abs):
        rewritten = _retarget_tree(rewritten, customer_root, validator_root)
        if _command_names_tree(rewritten, customer_root):
            raise ValueError("test command still names the writable tree")
        start = validator_root
    else:
        start = customer_root
    payload = {}
    for rel in sorted(locked):
        _safe_rel(rel)
        data, mode = file_map[rel]
        payload[rel] = (data, _frozen_mode(mode))
    script = _entry_script(customer_root, rewritten, start).encode("utf-8")
    payload["run-frozen.sh"] = (script, 0o555)
    return locked, payload


def _validator_digest(items):
    digest = hashlib.sha256()
    for rel, data, mode in sorted(items, key=lambda row: row[0]):
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        digest.update(f"{_mode_bits(mode):03o}".encode("ascii"))
        digest.update(b"\0")
        digest.update(data)
        digest.update(b"\0")
    return digest.hexdigest()


def is_git_url(source):
    text = str(source)
    return "://" in text or text.startswith("git@")


def check_git_url(source):
    if source.startswith("git@") or source.startswith("ssh:") or source.startswith("file:"):
        raise ValueError("only https git URLs are accepted")
    if not source.startswith("https://"):
        raise ValueError("only https git URLs are accepted")
    authority = source.split("://", 1)[1].split("/", 1)[0]
    if "@" in authority:
        raise ValueError("git URL must not carry a password")


class _ApplyShim:
    def __init__(self, editable):
        self.spec = {"editable": editable}

    def event(self, kind, **data):
        return None


def apply_one(controller, proposal, workspace, editable, locked=()):
    if not isinstance(proposal, dict):
        raise ValueError("model output must be a JSON object")
    if set(proposal) == {"edits"}:
        edits = proposal["edits"]
        if not isinstance(edits, list) or len(edits) != 1 or not isinstance(edits[0], dict):
            raise ValueError("one change at a time")
        paths = [edits[0].get("path", "")]
    elif set(proposal) == {"files"}:
        files = proposal["files"]
        if not isinstance(files, dict) or len(files) != 1:
            raise ValueError("one change at a time")
        paths = list(files)
    else:
        raise ValueError("model output must be one edit or one file")
    frozen = set(locked)
    for name in paths:
        if not isinstance(name, str):
            raise ValueError("path rejected")
        rel = Path(name)
        if (
            not name
            or rel.is_absolute()
            or ".." in rel.parts
            or is_validator_path(name)
            or name in frozen
        ):
            raise ValueError("path rejected")
        if not controller.allowed(rel):
            raise ValueError("path rejected")
    controller.RepairRun._apply_to(_ApplyShim(editable), proposal, Path(workspace))


def validate_model_edit(controller, proposal, preview_dir, locked, fence=None):
    """Accept a model edit only after it applies on a copy of the scrubbed preview."""
    if not isinstance(proposal, dict):
        raise ValueError("model output must be a JSON object")
    preview_dir = Path(preview_dir)
    frozen = set(locked or ())
    editable = []
    for path in iter_source_files(preview_dir):
        rel = path.relative_to(preview_dir).as_posix()
        if rel.startswith("receipt/") or rel in frozen or is_validator_path(rel):
            continue
        editable.append(rel)
    stage = preview_dir.parent / (
        "model-stage-" + hashlib.sha256(os.urandom(8)).hexdigest()[:8]
    )
    if fence is not None:
        fence.allow(stage)
    stage.mkdir()
    try:
        for rel in editable:
            dest = stage / rel
            if fence is not None:
                fence.allow(dest)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes((preview_dir / rel).read_bytes())
        apply_one(controller, proposal, stage, editable, frozen)
    finally:
        _force_rmtree(stage)
    return proposal


def change_id(proposal):
    blob = json.dumps(proposal, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def describe(proposal):
    if isinstance(proposal, dict) and set(proposal) == {"edits"} and proposal["edits"]:
        edit = proposal["edits"][0]
        return f"edit {edit.get('path', '')} {clip(str(edit.get('old', '')), 40)} -> {clip(str(edit.get('new', '')), 40)}"
    if isinstance(proposal, dict) and set(proposal) == {"files"} and proposal["files"]:
        return "replace " + next(iter(proposal["files"]))
    return "empty proposal"


def _force_rmtree(path):
    """Remove a work tree even after the receipt copy was made read-only."""
    path = Path(path)
    if not path.exists():
        return
    for root, dirs, files in os.walk(path, topdown=True):
        try:
            os.chmod(root, 0o755)
        except OSError:
            pass
        for name in files:
            try:
                os.chmod(Path(root) / name, 0o644)
            except OSError:
                pass
    shutil.rmtree(path, ignore_errors=True)


def _plain_name(name):
    while name.startswith("./"):
        name = name[2:]
    return name.lstrip("/")


def _is_tmpfs_path(name):
    return any(name == root or name.startswith(root + "/") for root in ("work", "tmp", "validator"))


def _files_from_tar(blob):
    found = []
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:") as tar:
        for member in tar.getmembers():
            name = _plain_name(member.name)
            if not name or not member.isfile():
                continue
            if any(part in SKIP_DIRS for part in Path(name).parts):
                continue
            handle = tar.extractfile(member)
            if handle is None:
                continue
            found.append((name, handle.read(), _mode_bits(member.mode)))
    return found


def _tar_from_files(files):
    """files maps a relative path to (bytes, mode). The mode is kept.

    TarInfo defaults to 0644. An executable source file has to stay executable
    or a test script cannot be run after pull_local or pull_git.
    """
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as tar:
        for rel in sorted(files):
            _safe_rel(rel)
            data, mode = files[rel]
            info = tarfile.TarInfo(rel)
            info.size = len(data)
            info.mode = _mode_bits(mode)
            info.mtime = 0
            tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def split_source_items(items, redact, keep_secrets):
    """Return scrubbed previews and the bytes that belong inside the container.

    Raw values are placed in the container payload only when keep_secrets is set.
    The preview bytes are always scrubbed.
    """
    count = 0
    files = 0
    scrubbed = {}
    preview = {}
    payload = {}
    items = list(items)
    register = getattr(redact, "register", None)
    if register is not None:
        for rel, data, _mode in items:
            register(rel, data)
    for rel, data, mode in items:
        _safe_rel(rel)
        if len(data) > 4 * 1024 * 1024:
            raise ValueError("source file is too large")
        cleaned, found, text = scrub_bytes(redact, data, name=rel)
        count += found
        files += 1
        scrubbed[rel] = text
        preview[rel] = cleaned
        kept = data if keep_secrets else cleaned
        payload[rel] = (kept, _mode_bits(mode))
    return files, count, scrubbed, preview, payload


def merge_stopped_container(dest, export_bytes, tmpfs_bytes):
    """Overlay the live tmpfs onto a docker export of the stopped container.

    docker export misses tmpfs, which is where /work and /tmp live. The export
    still holds the image filesystem, including anything installed into it.
    """
    with tarfile.open(dest, "w") as out:
        def add_from(blob, skip_tmpfs):
            with tarfile.open(fileobj=io.BytesIO(blob), mode="r:") as src:
                for member in src.getmembers():
                    name = _plain_name(member.name)
                    if not name:
                        continue
                    if skip_tmpfs and _is_tmpfs_path(name):
                        continue
                    info = tarfile.TarInfo(name)
                    info.mode = member.mode
                    info.mtime = member.mtime
                    if member.issym() or member.islnk():
                        info.type = member.type
                        info.linkname = member.linkname
                        out.addfile(info)
                        continue
                    if not member.isfile():
                        info.type = tarfile.DIRTYPE
                        out.addfile(info)
                        continue
                    handle = src.extractfile(member)
                    data = handle.read() if handle else b""
                    info.size = len(data)
                    out.addfile(info, io.BytesIO(data))

        add_from(export_bytes, True)
        add_from(tmpfs_bytes, False)


INSIDE_APPLY = r"""
import json, sys
from pathlib import Path
req = json.load(sys.stdin)
rel = Path(req.get("path") or "")
if not req.get("path") or rel.is_absolute() or ".." in rel.parts:
    sys.exit(3)
target = Path("/work") / rel
if req.get("op") == "edit":
    text = target.read_text(encoding="utf-8")
    old, new = req.get("old"), req.get("new")
    if not isinstance(old, str) or not old or not isinstance(new, str) or text.count(old) != 1:
        sys.exit(2)
    target.write_text(text.replace(old, new, 1), encoding="utf-8")
elif req.get("op") == "file":
    text = req.get("text")
    if not isinstance(text, str):
        sys.exit(2)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
else:
    sys.exit(3)
"""

RESTORE_WORK = r"""
import json, os, sys
from pathlib import Path
spec = json.load(sys.stdin)
if not isinstance(spec, dict):
    sys.exit(2)
root = Path("/work")
keep = set(spec)
for dirpath, _dirs, filenames in os.walk(root):
    for name in filenames:
        path = Path(dirpath) / name
        rel = path.relative_to(root).as_posix()
        if rel not in keep:
            path.unlink()
for rel, text in spec.items():
    dest = root / rel
    if Path(rel).is_absolute() or ".." in Path(rel).parts or not isinstance(text, str):
        sys.exit(3)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text, encoding="utf-8")
"""


def iter_source_files(root):
    root = Path(root)
    for directory, dirs, files in os.walk(root, followlinks=False):
        base = Path(directory)
        dirs[:] = sorted(name for name in dirs if name not in SKIP_DIRS and not (base / name).is_symlink())
        for name in sorted(files):
            path = base / name
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"symlink or special file rejected: {path.name}")
            yield path


class FakeRunner:
    """Stand-in for a container. The test runs in a temp folder, not in Docker.

    self.work is the scrubbed preview the worker reads. self.container_root is
    the stand-in container. Raw values are written only there, and only when
    the test was told to keep them. The README says this is not Docker.
    """

    name = "fake"

    def __init__(self, work, fence):
        self.work = Path(work)
        self.fence = fence
        self.fence.allow(self.work)
        self.work.mkdir(parents=True, exist_ok=True)
        self.container_root = self.work.parent / "container"
        self.fence.allow(self.container_root)
        self.container_root.mkdir(parents=True, exist_ok=True)
        self.network = False
        self.receipt_copy = self.work / "receipt" / "receipt.jsonl"
        self.validator_root = self.work.parent / "validator"
        self.locked_paths = set()
        self.frozen_cmd = ""
        self.validator_count = 0
        self.validator_digest = ""

    def store_scrubbed(self, rel, cleaned):
        dest = self.work / rel
        self.fence.allow(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(cleaned)

    def write_container(self, rel, data, mode=0o644):
        dest = self.container_root / rel
        self.fence.allow(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        os.chmod(dest, _mode_bits(mode))

    def pull_local(self, source, redact, keep_secrets):
        items = []
        for path in iter_source_files(source):
            rel = path.relative_to(source).as_posix()
            items.append((rel, path.read_bytes(), path.stat().st_mode & 0o777))
        files, count, scrubbed, preview, payload = split_source_items(items, redact, keep_secrets)
        for rel, cleaned in preview.items():
            self.store_scrubbed(rel, cleaned)
        for rel, (data, mode) in payload.items():
            self.write_container(rel, data, mode)
        self.original = scrubbed
        return files, count

    def restore_original(self):
        """Put the scrubbed source back after a failed local model, before another model tries."""
        originals = dict(getattr(self, "original", {}) or {})
        self._drop_extra(self.container_root, originals)
        self._drop_extra(self.work, originals, skip_prefix="receipt/")
        for rel, text in originals.items():
            data = text.encode("utf-8")
            self.store_scrubbed(rel, data)
            self.write_container(rel, data)

    def _drop_extra(self, root, keep, skip_prefix=""):
        if not root.exists():
            return
        for path in list(iter_source_files(root)):
            rel = path.relative_to(root).as_posix()
            if skip_prefix and rel.startswith(skip_prefix):
                continue
            if rel not in keep:
                path.unlink()

    def preview_secret_hits(self, redact):
        hits = 0
        if not self.work.exists():
            return 0
        for path in iter_source_files(self.work):
            rel = path.relative_to(self.work).as_posix()
            if rel.startswith("receipt/"):
                continue
            _cleaned, found, _text = scrub_bytes(redact, path.read_bytes(), name=rel)
            hits += found
        return hits

    def refresh_receipt(self, host_log):
        folder = self.receipt_copy.parent
        self.fence.allow(folder)
        folder.mkdir(parents=True, exist_ok=True)
        os.chmod(folder, 0o755)
        if self.receipt_copy.exists():
            os.chmod(self.receipt_copy, 0o644)
        data = Path(host_log).read_bytes()
        self.fence.allow(self.receipt_copy)
        self.receipt_copy.write_bytes(data)
        os.chmod(self.receipt_copy, 0o444)
        os.chmod(folder, 0o555)

    def read_text(self, rel):
        path = (self.work / rel).resolve()
        if self.work.resolve() not in path.parents and path != self.work.resolve():
            raise ValueError("path rejected")
        return path.read_text(encoding="utf-8", errors="replace")

    def _validate(self, controller, proposal, editable):
        stage = self.work.parent / ("stage-" + hashlib.sha256(os.urandom(8)).hexdigest()[:8])
        self.fence.allow(stage)
        stage.mkdir()
        try:
            for path in iter_source_files(self.work):
                rel = path.relative_to(self.work).as_posix()
                if rel.startswith("receipt/"):
                    continue
                dest = stage / rel
                self.fence.allow(dest)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(path.read_bytes())
            apply_one(controller, proposal, stage, editable, self.locked_paths)
        finally:
            _force_rmtree(stage)

    def _apply_inside(self, proposal):
        if set(proposal) == {"edits"}:
            edit = proposal["edits"][0]
            target = self.container_root / edit["path"]
            text = target.read_text(encoding="utf-8")
            old, new = edit["old"], edit["new"]
            if text.count(old) != 1:
                raise ValueError("Each old string must match exactly once")
            target.write_text(text.replace(old, new, 1), encoding="utf-8")
            return
        name, text = next(iter(proposal["files"].items()))
        target = self.container_root / name
        self.fence.allow(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def _refresh_preview(self, redact):
        for path in iter_source_files(self.container_root):
            rel = path.relative_to(self.container_root).as_posix()
            cleaned, _found, _text = scrub_bytes(redact, path.read_bytes(), name=rel)
            self.store_scrubbed(rel, cleaned)

    def apply_change(self, controller, proposal, editable, redact):
        self._validate(controller, proposal, editable)
        self._apply_inside(proposal)
        self._refresh_preview(redact)

    def _container_files(self):
        found = {}
        for path in iter_source_files(self.container_root):
            rel = path.relative_to(self.container_root).as_posix()
            found[rel] = (path.read_bytes(), path.stat().st_mode & 0o777)
        return found

    def _read_validator_items(self):
        found = []
        if self.validator_root is None or not self.validator_root.exists():
            return found
        for path in iter_source_files(self.validator_root):
            rel = path.relative_to(self.validator_root).as_posix()
            found.append((rel, path.read_bytes(), path.stat().st_mode & 0o777))
        return found

    def _install_validator_tree(self, payload):
        self.fence.allow(self.validator_root)
        if self.validator_root.exists():
            _force_rmtree(self.validator_root)
        self.validator_root.mkdir()
        for rel, (data, mode) in payload.items():
            dest = self.validator_root / rel
            self.fence.allow(dest)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            os.chmod(dest, _mode_bits(mode))
        for dirpath, _dirs, _files in os.walk(self.validator_root, topdown=False):
            os.chmod(dirpath, 0o555)

    def freeze_validator(self, command):
        """Copy the check next to the stand-in container, not inside it."""
        if self.frozen_cmd:
            return
        locked, payload = build_frozen_validator(
            self._container_files(),
            command,
            str(self.container_root),
            str(self.validator_root),
        )
        self._install_validator_tree(payload)
        items = self._read_validator_items()
        if "run-frozen.sh" not in {rel for rel, _data, _mode in items}:
            raise RuntimeError("frozen validator was not installed")
        self.locked_paths = set(locked)
        self.frozen_cmd = str(self.validator_root / "run-frozen.sh")
        self.validator_count = len(locked)
        self.validator_digest = _validator_digest(items)

    def _validator_intact(self):
        if not self.validator_digest:
            return False
        return _validator_digest(self._read_validator_items()) == self.validator_digest

    def run_test(self, command):
        if not self.frozen_cmd:
            self.freeze_validator(command)
        if not self._validator_intact():
            return VALIDATOR_CHANGED_CODE, VALIDATOR_CHANGED
        py_dir = os.path.dirname(sys.executable)
        env = {
            "PATH": py_dir + ":/usr/bin:/bin:/usr/local/bin",
            "HOME": "/tmp",
            "LANG": "C.UTF-8",
            "TMPDIR": "/tmp",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONPATH": str(self.container_root),
        }
        try:
            done = subprocess.run(
                [self.frozen_cmd],
                cwd=self.container_root,
                env=env,
                capture_output=True,
                timeout=TEST_TIMEOUT,
                stdin=subprocess.DEVNULL,
            )
        except subprocess.TimeoutExpired as err:
            partial = _shown_test_output(err.stdout or b"", err.stderr or b"", 1)
            return None, "timed out" + ("\n" + partial if partial else "")
        if not self._validator_intact():
            return VALIDATOR_CHANGED_CODE, VALIDATOR_CHANGED
        return done.returncode, _shown_test_output(done.stdout, done.stderr, done.returncode)

    def snapshot_text(self, redact):
        found = {}
        for path in iter_source_files(self.container_root):
            rel = path.relative_to(self.container_root).as_posix()
            _raw, _count, text = scrub_bytes(redact, path.read_bytes(), name=rel)
            found[rel] = text
        return found

    def export_filesystem(self, dest):
        self.fence.allow(dest)
        with tarfile.open(dest, "w") as tar:
            for path in iter_source_files(self.container_root):
                rel = path.relative_to(self.container_root).as_posix()
                tar.add(path, arcname=rel, recursive=False)

    def destroy(self):
        _force_rmtree(self.container_root)
        _force_rmtree(self.validator_root)
        _force_rmtree(self.work)


def _docker(args, timeout, check=True, input_bytes=None):
    try:
        done = subprocess.run(args, input=input_bytes, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as err:
        raise RuntimeError("docker command timed out") from err
    except OSError as err:
        raise RuntimeError("docker command failed: " + str(err)) from err
    if check and done.returncode != 0:
        err = (done.stderr or done.stdout or b"").decode("utf-8", "replace")[:400]
        raise RuntimeError(err.strip() or f"docker exited {done.returncode}")
    return done


def docker_up():
    try:
        done = subprocess.run(["docker", "info"], capture_output=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return done.returncode == 0


def prepare_receipt_image(base):
    """Local image with an empty /receipt so the read-only log file can be mounted.

    python:3.12-slim has no /receipt, and a file mount needs that directory.
    The prep container has no customer code, no host mounts, and no network.
    """
    ident = _docker(["docker", "image", "inspect", "--format", "{{.Id}}", base], 60, check=False)
    if ident.returncode != 0:
        _docker(["docker", "pull", base], 300)
        ident = _docker(["docker", "image", "inspect", "--format", "{{.Id}}", base], 60)
    image_id = ident.stdout.decode().strip()
    if image_id.startswith("sha256:"):
        image_id = image_id.split(":", 1)[1]
    image_id = image_id[:12]
    if len(image_id) < 12:
        raise RuntimeError("could not read the container image id")
    tag = "debug-pipeline-receipt:" + image_id
    have = _docker(["docker", "image", "inspect", tag], 30, check=False)
    if have.returncode == 0:
        return tag
    name = "dbg-prep-" + image_id
    subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=30)
    try:
        _docker(
            [
                "docker", "run", "--name", name, "--network", "none",
                "--user", "root", "--entrypoint", "/bin/mkdir",
                base, "-p", "/receipt",
            ],
            180,
        )
        _docker(["docker", "commit", name, tag], 180)
    finally:
        try:
            subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            pass
    return tag


class DockerBox:
    """Real container. The host keeps a scrubbed preview and nothing raw.

    Validated replacements are applied inside the container. The check runs
    from /validator, a root-owned tmpfs the customer user cannot write.
    The archive freezes every other process, then reads tmpfs, then stops
    the container and exports it.
    """

    name = "docker"

    def __init__(self, mirror, container, image, receipt_file, keep_network):
        self.mirror = mirror
        self.container = container
        self.image = image
        self.receipt_file = str(Path(receipt_file).resolve())
        self.keep_network = keep_network
        self.started = False
        self.bridged = False
        self.locked_paths = set()
        self.frozen_cmd = ""
        self.validator_count = 0
        self.validator_digest = ""

    @property
    def work(self):
        return self.mirror.work

    @property
    def receipt_copy(self):
        return self.mirror.receipt_copy

    @property
    def original(self):
        return self.mirror.original

    def refresh_receipt(self, host_log):
        self.mirror.refresh_receipt(host_log)

    def read_text(self, rel):
        return self.mirror.read_text(rel)

    def preview_secret_hits(self, redact):
        return self.mirror.preview_secret_hits(redact)

    def _remember_preview(self, scrubbed, preview):
        for rel, cleaned in preview.items():
            self.mirror.store_scrubbed(rel, cleaned)
        self.mirror.original = scrubbed

    def snapshot_text(self, redact):
        done = self._run(
            plan_exec(self.container, ["tar", "-cf", "-", "-C", "/work", "."]),
            timeout=180,
        )
        found = {}
        for rel, data, _mode in _files_from_tar(done.stdout):
            _cleaned, _count, text = scrub_bytes(redact, data, name=rel)
            found[rel] = text
        return found

    def pull_local(self, source, redact, keep_secrets):
        items = []
        for path in iter_source_files(source):
            items.append((
                path.relative_to(source).as_posix(),
                path.read_bytes(),
                path.stat().st_mode & 0o777,
            ))
        files, count, scrubbed, preview, payload = split_source_items(items, redact, keep_secrets)
        self._remember_preview(scrubbed, preview)
        self._extract_payload(payload)
        return files, count

    def _extract_payload(self, payload):
        # -p keeps the executable bit. Without it, tar applies umask and a
        # 0755 script can land without its execute bit.
        self._run(
            plan_exec(self.container, ["tar", "-x", "-p", "-f", "-", "-C", "/work"]),
            input_bytes=_tar_from_files(payload),
        )

    def _run(self, args, timeout=120, check=True, input_bytes=None):
        return _docker(args, timeout, check=check, input_bytes=input_bytes)

    def start(self, bridged):
        prepared = prepare_receipt_image(self.image)
        args = plan_create(self.container, prepared, self.receipt_file, bridged)
        assert_safe(args)
        self._run(args, timeout=300)
        self.started = True
        self.bridged = bridged
        probe = self._run(plan_exec(self.container, ["sh", "-c", "command -v tar"]), check=False)
        if probe.returncode != 0:
            raise RuntimeError("image is missing tar, so the source was not copied in")

    def pull_git(self, url, redact, keep_secrets):
        check_git_url(url)
        probe = self._run(plan_exec(self.container, ["sh", "-c", "command -v git"]), check=False)
        if probe.returncode != 0:
            raise RuntimeError("image has no git, so the source was not pulled")
        clone = plan_exec(self.container, ["git", "clone", "--depth", "1", url, "/tmp/src"])
        name_at = clone.index(self.container)
        clone = clone[:name_at] + ["-e", "GIT_TERMINAL_PROMPT=0"] + clone[name_at:]
        self._run(clone, timeout=180)
        packed = self._run(
            plan_exec(self.container, ["tar", "-cf", "-", "-C", "/tmp/src", "."]),
            timeout=180,
        )
        self._run(plan_exec(self.container, ["rm", "-rf", "/tmp/src"]), check=False)
        files, count, scrubbed, preview, payload = split_source_items(
            _files_from_tar(packed.stdout), redact, keep_secrets
        )
        self._remember_preview(scrubbed, preview)
        self._extract_payload(payload)
        return files, count

    def network_off(self):
        if self.keep_network or not self.bridged:
            return True
        done = self._run(plan_disconnect(self.container), check=False, timeout=30)
        return done.returncode == 0

    def _apply_inside(self, proposal):
        if set(proposal) == {"edits"}:
            edit = proposal["edits"][0]
            payload = {"op": "edit", "path": edit["path"], "old": edit["old"], "new": edit["new"]}
        else:
            name, text = next(iter(proposal["files"].items()))
            payload = {"op": "file", "path": name, "text": text}
        done = self._run(
            plan_exec(self.container, ["python3", "-c", INSIDE_APPLY]),
            input_bytes=json.dumps(payload).encode("utf-8"),
            check=False,
        )
        if done.returncode != 0:
            raise ValueError("container rejected the change")

    def _refresh_preview(self, redact):
        done = self._run(
            plan_exec(self.container, ["tar", "-cf", "-", "-C", "/work", "."]),
            timeout=180,
        )
        for rel, data, _mode in _files_from_tar(done.stdout):
            cleaned, _found, _text = scrub_bytes(redact, data, name=rel)
            self.mirror.store_scrubbed(rel, cleaned)

    def apply_change(self, controller, proposal, editable, redact):
        self.mirror.locked_paths = set(self.locked_paths)
        self.mirror._validate(controller, proposal, editable)
        self._apply_inside(proposal)
        self._refresh_preview(redact)

    def restore_original(self):
        """Put the scrubbed source back inside the container before the fallback model."""
        originals = dict(self.original or {})
        done = self._run(
            plan_exec(self.container, ["python3", "-c", RESTORE_WORK]),
            input_bytes=json.dumps(originals).encode("utf-8"),
            check=False,
        )
        if done.returncode != 0:
            raise RuntimeError("could not restore the source before the fallback")
        for rel, text in originals.items():
            self.mirror.store_scrubbed(rel, text.encode("utf-8"))
        self.mirror._drop_extra(self.mirror.work, originals, skip_prefix="receipt/")

    def _read_validator_items(self):
        done = self._run(
            plan_exec(self.container, ["tar", "-cf", "-", "-C", "/validator", "."]),
            timeout=60,
        )
        return _files_from_tar(done.stdout)

    def freeze_validator(self, command):
        """Install the check on the root-owned /validator tmpfs, not under /work."""
        if self.frozen_cmd:
            return
        done = self._run(
            plan_exec(self.container, ["tar", "-cf", "-", "-C", "/work", "."]),
            timeout=180,
        )
        file_map = {rel: (data, mode) for rel, data, mode in _files_from_tar(done.stdout)}
        locked, payload = build_frozen_validator(file_map, command, "/work", "/validator")
        self._run(
            [
                "docker", "exec", "-i", "-u", "root", self.container,
                "tar", "-x", "-p", "-f", "-", "-C", "/validator",
            ],
            input_bytes=_tar_from_files(payload),
        )
        self._run(
            ["docker", "exec", "-u", "root", self.container, "chmod", "-R", "a-w", "/validator"],
            timeout=60,
        )
        items = self._read_validator_items()
        if "run-frozen.sh" not in {rel for rel, _data, _mode in items}:
            raise RuntimeError("frozen validator was not installed")
        self.locked_paths = set(locked)
        self.mirror.locked_paths = set(locked)
        self.frozen_cmd = "/validator/run-frozen.sh"
        self.validator_count = len(locked)
        self.validator_digest = _validator_digest(items)

    def _validator_intact(self):
        if not self.validator_digest:
            return False
        return _validator_digest(self._read_validator_items()) == self.validator_digest

    def run_test(self, command):
        if not self.frozen_cmd:
            self.freeze_validator(command)
        if not self._validator_intact():
            return VALIDATOR_CHANGED_CODE, VALIDATOR_CHANGED
        try:
            done = self._run(
                plan_exec(self.container, [self.frozen_cmd]),
                check=False,
                timeout=TEST_TIMEOUT,
            )
        except RuntimeError as err:
            if "timed out" in str(err):
                return None, "timed out"
            raise
        if not self._validator_intact():
            return VALIDATOR_CHANGED_CODE, VALIDATOR_CHANGED
        return done.returncode, _shown_test_output(done.stdout, done.stderr, done.returncode)

    def export_filesystem(self, dest):
        # SIGSTOP every customer process before reading tmpfs. docker pause
        # would freeze the tar exec as well, so pid 1 (sleep) stays running.
        frozen = self._run(
            plan_exec(self.container, ["sh", "-c", FREEZE_PROCESSES]),
            timeout=60,
            check=False,
        )
        if frozen.returncode != 0:
            raise RuntimeError("could not freeze container processes before capture")
        tmpfs = self._run(
            plan_exec(self.container, ["tar", "-cf", "-", "-C", "/", "work", "tmp", "validator"]),
            timeout=180,
        )
        self._run(["docker", "stop", self.container], timeout=60)
        exported = self._run(["docker", "export", self.container], timeout=180)
        self.mirror.fence.allow(dest)
        merge_stopped_container(dest, exported.stdout, tmpfs.stdout)

    def destroy(self):
        try:
            subprocess.run(["docker", "rm", "-f", self.container], capture_output=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            pass
        self.started = False
        self.mirror.destroy()


def _diff(before, after):
    chunks = []
    for name in sorted(set(before) | set(after)):
        old = before.get(name, "").splitlines(keepends=True)
        new = after.get(name, "").splitlines(keepends=True)
        chunks.extend(difflib.unified_diff(old, new, fromfile="a/" + name, tofile="b/" + name))
    return "".join(chunks) if chunks else "no changes\n"


def _pack(dest, members, fence):
    fence.allow(dest)
    with tarfile.open(dest, "w") as tar:
        for name, data in members.items():
            if not isinstance(data, bytes):
                data = data.encode("utf-8")
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))


def _sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _actor():
    host = socket.gethostname().split(".")[0] or "mac"
    return f"debug-pipeline@{host}"


def _check_result(code):
    if code is None:
        return {"id": "test", "status": "timed_out", "exit": None, "signal": None}
    return {
        "id": "test",
        "status": "succeeded" if code == 0 else "failed",
        "exit": code,
        "signal": None,
    }


def _notes(scrubbed):
    notes = []
    for name, text in sorted(scrubbed.items()):
        for line in text.splitlines():
            if "[REDACTED]" in line:
                notes.append(clip(f"{name}: {line.strip()}", 100))
                break
        if len(notes) >= 3:
            break
    return notes


class Pipeline:
    def __init__(self, redact, controller, fence, log, runner, worker, test, rounds, keep_secrets):
        self.redact = redact
        self.controller = controller
        self.fence = fence
        self.log = log
        self.runner = runner
        self.worker = worker
        self.test = test
        self.rounds = rounds
        self.keep_secrets = keep_secrets
        self.prompts = []
        self.shown = []
        self.worker_calls = 0
        self.tripped = False
        self.stop_reason = ""
        self.failure = ""
        self.output = ""

    def note(self, status, cmd):
        cleaned, _count = scrub(self.redact, cmd)
        if survives(self.redact, cleaned):
            cleaned = "secret shape survived; run stopped"
            status = "FAILED"
            self.tripped = True
            self.stop_reason = cleaned
        self.log.append("Action", status, "/work", cleaned)
        return cleaned

    def show(self, text, where):
        cleaned, _count = scrub(self.redact, text)
        if survives(self.redact, cleaned):
            self.tripped = True
            self.stop_reason = "secret shape survived; run stopped"
            self.note("FAILED", "secret shape survived; run stopped")
            raise SecretSurvived(where)
        self.shown.append(cleaned)
        return cleaned

    def run_fix(self, scrubbed_preview):
        seen = set()
        attempts = []
        notes = _notes(scrubbed_preview)
        for round_n in range(1, self.rounds + 1):
            if self.tripped:
                return "FAILED"
            self.runner.refresh_receipt(self.log.path)
            before = hashlib.sha256(self.runner.receipt_copy.read_bytes()).hexdigest()
            prompt = build_prompt(
                self.test, round_n, attempts, notes, failure=self.failure, output=self.output,
            )
            prompt = self.show(prompt, "the worker prompt")
            if POINTER not in prompt and (round_n >= 2 or attempts):
                self.note("FAILED", "worker prompt dropped the receipt pointer; run stopped")
                return "FAILED"
            self.prompts.append(prompt)
            view = _View(self)
            self.worker_calls += 1
            try:
                proposal = self.worker(prompt, view)
            except SecretSurvived:
                return "FAILED"
            except (ValueError, OSError) as err:
                self.note("FAILED", "reject proposal: " + clip(str(err), 120))
                attempts.append({
                    "round": round_n,
                    "what": "rejected change",
                    "where": clip(str(err), 60),
                })
                continue
            after = hashlib.sha256(self.runner.receipt_copy.read_bytes()).hexdigest()
            if after != before:
                self.note("FAILED", "worker changed the receipt; run stopped")
                return "FAILED"
            if not isinstance(proposal, dict):
                self.note("FAILED", f"round {round_n} worker returned no change")
                continue
            blob = json.dumps(proposal, sort_keys=True)
            if survives(self.redact, blob):
                self.note("FAILED", "secret shape survived; run stopped")
                return "FAILED"
            cid = change_id(proposal)
            if cid in seen:
                self.note("FAILED", "repeat: identical change already tried")
                attempts.append({
                    "round": round_n,
                    "what": "the same change as an earlier round",
                    "where": "not applied",
                })
                continue
            what = self.show(describe(proposal), "the change summary")
            try:
                locked = set(getattr(self.runner, "locked_paths", ()))
                editable = [
                    name for name in scrubbed_preview
                    if name not in locked and not is_validator_path(name)
                ]
                self.runner.apply_change(self.controller, proposal, editable, self.redact)
            except (ValueError, OSError) as err:
                self.note("FAILED", "reject proposal: " + clip(str(err), 120))
                attempts.append({
                    "round": round_n,
                    "what": "rejected change",
                    "where": clip(str(err), 60),
                })
                continue
            seen.add(cid)
            self.note("OK", f"round {round_n} change: {what}")
            code, out = self.runner.run_test(self.test)
            if code == VALIDATOR_CHANGED_CODE:
                self.note("FAILED", "validator changed during the test; run stopped")
                return "FAILED"
            where, excerpt = _failure_view(code, out, self.redact)
            if survives(self.redact, where) or survives(self.redact, excerpt):
                self.note("FAILED", "secret shape survived in test output; run stopped")
                return "FAILED"
            status = "OK" if code == 0 else "FAILED"
            self.note(status, f"retest: {clip(self.test, 80)} {where}")
            if code != 0 and excerpt:
                self.note("FAILED", "test output:\n" + excerpt)
                if self.tripped:
                    return "FAILED"
            decision = self.controller.decide_checks(["test"], [_check_result(code)], retained=[], baseline=False)
            if code == 0 and decision["outcome"] == "accept":
                return "OK"
            self.failure = where
            self.output = excerpt
            attempts.append({"round": round_n, "what": what, "where": where})
        return "FAILED"


class _View:
    def __init__(self, pipeline):
        self.pipeline = pipeline

    def read_text(self, rel):
        return self.pipeline.show(self.pipeline.runner.read_text(rel), "a source file")

    def read_receipt(self):
        return self.pipeline.show(self.pipeline.runner.receipt_copy.read_text(encoding="utf-8"), "the receipt copy")

    @property
    def receipt_path(self):
        return "/receipt/receipt.jsonl"

    @property
    def receipt_copy(self):
        return self.pipeline.runner.receipt_copy


def _where(code, out, redact):
    if code is None:
        return "timed out"
    last = ""
    for line in (out or "").splitlines():
        if line.strip():
            last = line.strip()
    cleaned, _count = scrub(redact, last)
    return f"exit {code}: {clip(cleaned, 60)}"


def _failure_view(code, out, redact):
    """Short status line, plus the scrubbed traceback or output tail. A passing test has no tail."""
    where = _where(code, out, redact)
    if code == 0:
        return where, ""
    excerpt, _count = scrub(redact, failure_excerpt(out))
    return where, excerpt


def _baseline_decision(controller, code):
    return controller.decide_checks(["test"], [_check_result(code)], baseline=True)


def _log_tool_failure(log, redact, result, err):
    text = " ".join(str(err).split())
    cleaned, _count = scrub(redact, text)
    if survives(redact, cleaned):
        log.append("Action", "FAILED", "/work", "secret shape survived; run stopped")
        result["result"] = "FAILED"
        return
    log.append("Action", "NOT VERIFIED", "/work", clip(cleaned, 180) or "docker command failed")
    result["result"] = "NOT VERIFIED"


def _grok_fallback(outcome, pipe, runner, controller, worker, log, where, excerpt):
    """If the local model did not fix the test, restore the source and try Grok once."""
    if outcome == "OK" or pipe.tripped:
        return outcome
    from debug_pipeline.workers import grok_fallback_worker, is_local_model

    if not is_local_model(worker):
        return outcome
    fallback = grok_fallback_worker()
    if fallback is None:
        log.append("Action", "FAILED", "/work", "local model failed; grok fallback has no login")
        return outcome
    log.append("Action", "FAILED", "/work", "local model failed; falling back to grok-4.7")
    runner.restore_original()
    fallback.bind(runner, controller)
    pipe.worker = fallback
    pipe.failure = where
    pipe.output = excerpt
    outcome = pipe.run_fix(runner.original)
    if pipe.tripped:
        return "FAILED"
    return outcome


def _finish(result, ticket, out_dir, fence, log, store, runner, redact, controller,
            worker, test, rounds, keep_secrets, files, count, network, runner_name):
    runner.archive_keeps_secrets = keep_secrets
    result["scrubbed"] = count
    noun = "value" if count == 1 else "values"
    log.append("Action", "OK", "/work", f"pull source into container files={files}")
    log.append("Action", "OK", "/work", f"scrubbed {count} secret {noun} on intake")
    if network:
        log.append("Action", "OK", "/work", "network left on because the run asked for it")
    else:
        log.append("Action", "OK", "/work", "network off after pull")
    if keep_secrets:
        log.append("Action", "OK", "/work", "secrets left in the container because the test needs them")
    else:
        log.append("Action", "OK", "/work", "container copy scrubbed before the test")
    result["preview_secret_hits"] = runner.preview_secret_hits(redact)
    if result["preview_secret_hits"]:
        log.append("Action", "FAILED", "/work", "secret shape survived; run stopped")
        result["result"] = "FAILED"
        return result
    runner.freeze_validator(test)
    log.append(
        "Action", "OK", "/work",
        f"validator frozen outside the customer tree files={runner.validator_count}",
    )
    code, out = runner.run_test(test)
    if code == VALIDATOR_CHANGED_CODE:
        log.append("Action", "FAILED", "/work", "validator changed during the test; run stopped")
        result["result"] = "FAILED"
        return result
    where, excerpt = _failure_view(code, out, redact)
    if survives(redact, where) or survives(redact, excerpt):
        log.append("Action", "FAILED", "/work", "secret shape survived in test output; run stopped")
        result["result"] = "FAILED"
        return result
    decision = _baseline_decision(controller, code)
    if code == 0 and decision["gates"]["acceptance"]:
        log.append("Action", "NOT VERIFIED", "/work", f"baseline test passed: nothing to fix ({where})")
        result["result"] = "NOT VERIFIED"
        _seal(result, ticket, out_dir, fence, log, runner, redact, store, "NOT VERIFIED", count, runner_name)
        return result
    if code is None:
        log.append("Action", "NOT VERIFIED", "/work", f"baseline test: {clip(test, 80)} {where}")
        if excerpt:
            log.append("Action", "NOT VERIFIED", "/work", "test output:\n" + excerpt)
        result["result"] = "NOT VERIFIED"
        return result
    log.append("Action", "FAILED", "/work", f"baseline test: {clip(test, 80)} {where}")
    if excerpt:
        log.append("Action", "FAILED", "/work", "test output:\n" + excerpt)
    if worker is None:
        log.append("Action", "NOT VERIFIED", "/work", "no worker configured; baseline recorded; nothing was changed")
        result["result"] = "NOT VERIFIED"
        _seal(result, ticket, out_dir, fence, log, runner, redact, store, "NOT VERIFIED", count, runner_name)
        return result
    bind = getattr(worker, "bind", None)
    if callable(bind):
        bind(runner, controller)
    pipe = Pipeline(redact, controller, fence, log, runner, worker, test, rounds, keep_secrets)
    pipe.failure = where
    pipe.output = excerpt
    outcome = pipe.run_fix(runner.original)
    outcome = _grok_fallback(
        outcome, pipe, runner, controller, worker, log, where, excerpt,
    )
    result["prompts"] = pipe.prompts
    result["shown"] = pipe.shown
    result["worker_calls"] = pipe.worker_calls
    if pipe.tripped:
        outcome = "FAILED"
    result["result"] = outcome
    log.append("Action", outcome if outcome in ("OK", "FAILED") else "NOT VERIFIED", "/work", f"result: {outcome}")
    _seal(result, ticket, out_dir, fence, log, runner, redact, store, outcome, count, runner_name)
    return result


def run(ticket, source, test, out_dir, store_dir, runner_name="fake", worker=None,
        rounds=MAX_ROUNDS, keep_secrets=False, network=False, image="python:3.12-slim"):
    if not valid_ticket(ticket):
        raise ValueError("ticket must be 6 characters from the ticket alphabet")
    if not test or not isinstance(test, str):
        raise ValueError("a test command is required")
    rounds = MAX_ROUNDS if not isinstance(rounds, int) or not 1 <= rounds <= MAX_ROUNDS else rounds
    repo = repo_root()
    redact = load_redactor(repo)
    controller = load_controller(repo)
    out_dir = Path(out_dir).expanduser()
    store_dir = Path(store_dir).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)
    store_dir.mkdir(parents=True, exist_ok=True)
    # resolve() drops the /tmp and /var symlinks so the controller's stage has
    # no symlink parent. The work tree stays inside the archive folder.
    out_dir = out_dir.resolve()
    store_dir = store_dir.resolve()
    parent = out_dir / (
        "debug-pipeline-work-" + hashlib.sha256(os.urandom(8)).hexdigest()[:12]
    )
    parent.mkdir(parents=True)
    fence = Fence([out_dir, store_dir])
    store = FolderTicketStore(store_dir, fence)
    log = ReceiptLog(out_dir / "receipt.jsonl", _actor(), fence)
    result = {
        "result": "NOT VERIFIED",
        "receipt": log.path,
        "archive": None,
        "sha256": None,
        "head_hash": None,
        "prompts": [],
        "shown": [],
        "scrubbed": 0,
        "worker_calls": 0,
        "runner": runner_name,
        "ticket_record": None,
    }
    fake = None
    docker = None
    try:
        if not store.has_ticket(ticket):
            log.append("Action", "NOT VERIFIED", "/work", "no such ticket in the local store")
            return result
        if runner_name == "docker":
            if not docker_up():
                log.append("Action", "NOT VERIFIED", "/work", "Docker is not running")
                result["result"] = "NOT VERIFIED"
                return result
            git = is_git_url(source)
            if git:
                check_git_url(str(source))
            token = hashlib.sha256(os.urandom(8)).hexdigest()[:8]
            docker = DockerBox(
                FakeRunner(parent / "work", fence),
                "dbg-" + ticket.lower() + "-" + token,
                image,
                log.path,
                network,
            )
            try:
                docker.start(bridged=bool(network) or git)
                log.append("Action", "OK", "/work", "start container runner=docker")
                if git:
                    files, count = docker.pull_git(str(source), redact, keep_secrets)
                else:
                    source_path = Path(source)
                    if not source_path.is_dir():
                        log.append("Action", "NOT VERIFIED", "/work", "source folder is missing")
                        return result
                    files, count = docker.pull_local(source_path, redact, keep_secrets)
                if not docker.network_off():
                    log.append("Action", "NOT VERIFIED", "/work", "could not turn the network off after pull")
                    result["result"] = "NOT VERIFIED"
                    return result
                _finish(
                    result, ticket, out_dir, fence, log, store, docker, redact, controller,
                    worker, test, rounds, keep_secrets, files, count, network, "docker",
                )
            except ValueError:
                raise
            except (RuntimeError, OSError, subprocess.TimeoutExpired, tarfile.TarError) as err:
                _log_tool_failure(log, redact, result, err)
            return result
        if runner_name != "fake":
            log.append("Action", "NOT VERIFIED", "/work", "unknown runner")
            return result
        fake = FakeRunner(parent / "work", fence)
        log.append("Action", "OK", "/work", "start container runner=fake")
        if is_git_url(source):
            check_git_url(source)
            log.append("Action", "NOT VERIFIED", "/work", "fake runner does not fetch from the network")
            result["result"] = "NOT VERIFIED"
            return result
        source = Path(source)
        if not source.is_dir():
            log.append("Action", "NOT VERIFIED", "/work", "source folder is missing")
            return result
        files, count = fake.pull_local(source, redact, keep_secrets)
        _finish(
            result, ticket, out_dir, fence, log, store, fake, redact, controller,
            worker, test, rounds, keep_secrets, files, count, network, "fake",
        )
        return result
    finally:
        if fake is not None:
            fake.destroy()
        if docker is not None:
            docker.destroy()
        _force_rmtree(parent)


def _seal(result, ticket, out_dir, fence, log, runner, redact, store, outcome, count, runner_name):
    hits = runner.preview_secret_hits(redact)
    result["preview_secret_hits"] = hits
    if hits:
        log.append("Action", "FAILED", "/work", "secret shape survived; run stopped")
        result["result"] = "FAILED"
        return
    after = runner.snapshot_text(redact)
    diff = _diff(runner.original, after)
    if survives(redact, diff) or survives(redact, log.text()):
        log.append("Action", "FAILED", "/work", "secret shape survived; run stopped")
        result["result"] = "FAILED"
        return
    log.append("Action", "OK", "/work", f"pack archive {ticket}.tar")
    if survives(redact, log.text()):
        result["result"] = "FAILED"
        return
    head = log.head()
    report = (
        f"Result: {outcome}\n"
        f"Scrubbed values: {count}\n"
        f"Head hash: {head}\n"
        f"Runner: {runner_name}\n"
    )
    if survives(redact, report):
        log.append("Action", "FAILED", "/work", "secret shape survived; run stopped")
        result["result"] = "FAILED"
        return
    fs_path = out_dir / "filesystem.tar"
    runner.export_filesystem(fs_path)
    archive = out_dir / f"{ticket}.tar"
    if not getattr(runner, "archive_keeps_secrets", False):
        with tarfile.open(fs_path) as snapshot:
            for member in snapshot:
                if not member.isfile():
                    continue
                # The read-only image is infrastructure, not customer intake.
                # Only these tmpfs trees can hold customer writes on Docker.
                # The fake export contains only the customer tree.
                name = _plain_name(member.name)
                if runner_name == "docker" and not _is_tmpfs_path(name):
                    continue
                handle = snapshot.extractfile(member)
                data = handle.read()
                _cleaned, hits, _text = scrub_bytes(redact, data, name=name)
                if survives(redact, name) or hits:
                    log.append("Action", "FAILED", "/work", "secret shape survived in archive filesystem; run stopped")
                    result["result"] = "FAILED"
                    fs_path.unlink(missing_ok=True)
                    return
    _pack(archive, {
        "filesystem.tar": fs_path.read_bytes(),
        "receipt.jsonl": log.text(),
        "diff.patch": diff,
        "head.hash": head + "\n",
        "report.txt": report,
    }, fence)
    fs_path.unlink(missing_ok=True)
    digest = _sha256(archive)
    side = out_dir / f"{ticket}.tar.sha256"
    fence.allow(side)
    side.write_text(f"{digest}  {ticket}.tar\n", encoding="utf-8")
    record = {
        "ticket": ticket,
        "archive": str(archive.resolve()),
        "sha256": digest,
        "result": outcome,
        "head_hash": head,
    }
    written = store.attach(ticket, record)
    result.update(archive=archive, sha256=digest, head_hash=head, ticket_record=written, result=outcome)
