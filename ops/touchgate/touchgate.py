#!/usr/bin/env python3
"""TouchGate: block destructive agent commands until a human approves with Touch ID.

This is a Claude Code PreToolUse hook. It reads the hook payload on stdin.
Approved commands exit 0. A denial, a timeout, or no way to ask exits 2 and
tells the agent not to retry or work around the block. The hook fails closed.

It reads command text. A delete hidden in a script file can slip past.
Linux approval is planned; until then a non-macOS machine is denied.
"""

import base64
import datetime
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
import tempfile

DEFAULT_ALLOW_PATHS = (
    "node_modules",
    "dist",
    "build",
    ".next",
    "__pycache__",
    "/tmp",
)
DELETERS = {"rm", "rmdir", "unlink", "shred", "srm", "trash"}
WRAPPERS = {"sudo", "xargs", "env", "nohup", "time", "exec", "command", "doas", "caffeinate"}
SHELLS = {"bash", "sh", "zsh", "dash", "ash"}
SQL_CLIENTS = {"psql", "mysql", "mariadb", "sqlite3"}
SQL_TEXT_FLAGS = {"-c", "-e", "--command", "--execute"}
SQL_VALUE_FLAGS = {
    "-h", "-H", "-p", "-P", "-u", "-U", "-d", "-D", "-S", "-W",
    "--host", "--port", "--user", "--database", "--password", "--socket",
}
SEPS = {";", "&&", "||", "|", "&", "\n", "(", ")", "|&"}
WRAPPER_TAKES_ARG = {
    "sudo": {
        "-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U",
        "--user", "--group", "--host", "--prompt", "--close-from", "--chdir",
        "--role", "--type", "--other-user", "--command-timeout",
    },
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"},
    "xargs": {
        "-I", "-a", "-E", "-e", "-L", "-n", "-P", "-s", "-d",
        "--max-args", "--max-chars", "--max-procs", "--delimiter",
        "--arg-file", "--replace", "--eof",
    },
    "doas": {"-u", "-C", "-a"},
    "caffeinate": {"-t"},
    "time": {"-f", "-o"},
}
GIT_TAKES_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"}
SSH_WITH_ARG = set("bcDEeFIiJLlmOopQRSWw")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
HEREDOC = re.compile(
    r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1[ \t]*\n(.*?)\n[ \t]*\2[ \t]*(?:\n|$)",
    re.S,
)
PAYLOAD_PREFIX = b"touchgate:v1:"


def default_config():
    return {"allow_paths": list(DEFAULT_ALLOW_PATHS), "extra_patterns": []}


def config_path():
    return os.path.join(os.path.expanduser("~"), ".touchgate.json")


def auth_path():
    return os.path.join(os.path.expanduser("~"), ".touchgate", "bin", "touchgate-auth")


def pubkey_path():
    return os.path.join(os.path.expanduser("~"), ".touchgate", "enclave", "public.pem")


def log_path():
    return os.path.join(os.path.expanduser("~"), ".touchgate", "log.jsonl")


def load_config(path=None):
    """Load ~/.touchgate.json. A missing or broken file keeps the defaults."""
    cfg = default_config()
    path = config_path() if path is None else path
    if not path or not os.path.isfile(path):
        return cfg
    try:
        with open(path, encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, json.JSONDecodeError, UnicodeError):
        return cfg
    if not isinstance(raw, dict):
        return cfg
    allow = raw.get("allow_paths", None)
    if isinstance(allow, list) and all(isinstance(item, str) for item in allow):
        cfg["allow_paths"] = allow
    patterns = raw.get("extra_patterns", None)
    if isinstance(patterns, list):
        compiled = []
        for pattern in patterns:
            if not isinstance(pattern, str):
                continue
            try:
                re.compile(pattern)
            except re.error:
                continue
            compiled.append(pattern)
        cfg["extra_patterns"] = compiled
    return cfg


def clip(text, limit=180):
    text = " ".join(str(text).split())
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."


def display_path(path):
    home = os.path.expanduser("~")
    prefix = home.rstrip("/") + "/"
    if path.startswith(prefix):
        return "~/" + path[len(prefix):]
    return path


def _norm(path):
    return os.path.normpath(os.path.expanduser(path.strip()))


def _variants(path):
    found = {path}
    if path == "/tmp" or path.startswith("/tmp/"):
        found.add("/private" + path)
    if path == "/private/tmp" or path.startswith("/private/tmp/"):
        found.add(path[len("/private"):])
    return found


def path_allowed(path, allow):
    """True when every normalized form of path sits inside the allowlist."""
    if not isinstance(path, str):
        return False
    raw = path.strip()
    if raw == "" or raw in {".", "..", "/", "*", "~", "./", "../"}:
        return False
    if any(ch in raw for ch in ("\n", "\x00")):
        return False
    normalized = _norm(raw)
    if normalized in {".", "..", "/", "~"} or ".." in normalized.split("/"):
        return False
    variants = _variants(normalized)
    components = set()
    for variant in variants:
        components.update(part for part in variant.split("/") if part not in ("", "."))
    for entry in allow:
        if not isinstance(entry, str):
            continue
        item = entry.strip().rstrip("/")
        if not item:
            continue
        if item.startswith("/") or item.startswith("~"):
            root = _norm(item)
            roots = _variants(root)
            for variant in variants:
                if any(variant == one or variant.startswith(one + "/") for one in roots):
                    return True
            continue
        if "/" not in item and "\\" not in item:
            if item in components:
                return True
            continue
        relative = os.path.normpath(item)
        for variant in variants:
            if variant == relative or variant.startswith(relative + "/") or variant.endswith("/" + relative):
                return True
    return False


def all_allowed(paths, allow):
    return bool(paths) and all(path_allowed(path, allow) for path in paths)


def sql_is_destructive(sql):
    """DROP, TRUNCATE, or DELETE FROM with no WHERE. Comments and quotes are ignored."""
    if not isinstance(sql, str) or not sql.strip():
        return False
    text = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    text = re.sub(r"--[^\n]*", " ", text)
    text = re.sub(r"'(?:''|[^'])*'", "''", text)
    text = re.sub(r'"(?:[^"\\]|\\.)*"', '""', text)
    for statement in text.split(";"):
        body = statement.strip()
        if not body:
            continue
        if re.search(r"(?i)\bDROP\b", body) or re.search(r"(?i)\bTRUNCATE\b", body):
            return True
        if re.search(r"(?i)\bDELETE\s+FROM\b", body) and not re.search(r"(?i)\bWHERE\b", body):
            return True
    return False


def extract_heredocs(cmd):
    """Return (command with heredoc bodies removed, list of (quoted, body))."""
    bodies = []

    def replacer(match):
        quoted = bool(match.group(1))
        bodies.append((quoted, match.group(3)))
        return " "

    return HEREDOC.sub(replacer, cmd), bodies


def _take_subst(cmd, index):
    if cmd[index] == "`":
        end = cmd.find("`", index + 1)
        if end == -1:
            return cmd[index + 1:], len(cmd)
        return cmd[index + 1:end], end + 1
    depth = 0
    cursor = index + 1
    while cursor < len(cmd):
        char = cmd[cursor]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return cmd[index + 2:cursor], cursor + 1
        cursor += 1
    return cmd[index + 2:], len(cmd)


def peel_substitutions(cmd):
    """Surface text that the shell will execute from $() and backticks.

    Single quotes suppress substitution. Double quotes do not. The returned
    string is still only the command text; nothing is executed here.
    """
    out = []
    index = 0
    length = len(cmd)
    while index < length:
        char = cmd[index]
        if char == "'":
            end = cmd.find("'", index + 1)
            if end == -1:
                out.append(cmd[index:])
                break
            out.append(cmd[index:end + 1])
            index = end + 1
            continue
        if char == '"':
            out.append(char)
            index += 1
            while index < length and cmd[index] != '"':
                if cmd[index] == "\\" and index + 1 < length:
                    out.append(cmd[index:index + 2])
                    index += 2
                    continue
                if cmd.startswith("$(", index) or cmd[index] == "`":
                    body, index = _take_subst(cmd, index)
                    # Close the quote so the substituted command is parsed, then reopen it.
                    out.append('" ; ' + body + ' ; "')
                    continue
                out.append(cmd[index])
                index += 1
            if index < length and cmd[index] == '"':
                out.append('"')
                index += 1
            continue
        if cmd.startswith("$(", index) or cmd[index] == "`":
            body, index = _take_subst(cmd, index)
            out.append(" ; " + body + " ; ")
            continue
        out.append(char)
        index += 1
    return "".join(out)


def tokens(cmd):
    lexer = shlex.shlex(cmd.replace("\n", " ; "), posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    return list(lexer)


def is_sep(token):
    return token in SEPS or bool(token) and set(token) <= set(";&|()")


def segments(toks):
    current = []
    for token in toks:
        if is_sep(token):
            if current:
                yield current
            current = []
        else:
            current.append(token)
    if current:
        yield current


def is_redir(token):
    return re.match(r"^\d*(?:>>?|&>)", token) is not None or re.match(r"^\d*>&\d*$", token) is not None


def drop_redirs(seg):
    return [token for token in seg if not is_redir(token)]


def operands(rest):
    found = []
    ended = False
    for arg in rest:
        if not ended and arg == "--":
            ended = True
            continue
        if not ended and arg.startswith("-"):
            continue
        found.append(arg)
    return found


def skip_to_command(seg):
    """Return the index of the real command after assignments and thin wrappers."""
    index = 0
    via_xargs = False
    while index < len(seg) and ASSIGN.match(seg[index]):
        index += 1
    while index < len(seg) and os.path.basename(seg[index]) in WRAPPERS:
        name = os.path.basename(seg[index])
        if name == "xargs":
            via_xargs = True
        index += 1
        takes = WRAPPER_TAKES_ARG.get(name, set())
        while index < len(seg):
            arg = seg[index]
            if arg == "--":
                index += 1
                break
            if name in {"sudo", "env", "doas"} and ASSIGN.match(arg):
                index += 1
                continue
            if arg.startswith("-"):
                head = arg.split("=", 1)[0]
                if head in takes and "=" not in arg:
                    index += 2
                else:
                    index += 1
                continue
            break
        while index < len(seg) and ASSIGN.match(seg[index]):
            index += 1
    return index, via_xargs


def shell_script(rest):
    """Return the string passed to sh -c / bash -lc, if any."""
    index = 0
    while index < len(rest):
        arg = rest[index]
        if arg in {"-c", "--command"}:
            return rest[index + 1] if index + 1 < len(rest) else None
        if arg.startswith("-") and not arg.startswith("--") and "c" in arg[1:]:
            return rest[index + 1] if index + 1 < len(rest) else None
        if arg.startswith("-"):
            index += 1
            continue
        return None
    return None


def ssh_remote(rest):
    index = 0
    while index < len(rest):
        arg = rest[index]
        if arg == "--":
            index += 1
            break
        if not arg.startswith("-"):
            break
        if arg.startswith("--"):
            index += 1
            continue
        takes = any(char in SSH_WITH_ARG for char in arg[1:])
        index += 2 if takes else 1
    if index >= len(rest):
        return None
    remote = rest[index + 1:]
    if not remote:
        return None
    return rest[index], " ".join(remote)


def short_has(flag, letter):
    return flag.startswith("-") and not flag.startswith("--") and letter in flag[1:]


def git_child(rest):
    index = 0
    while index < len(rest):
        arg = rest[index]
        if arg == "--":
            return None, rest[index + 1:]
        head = arg.split("=", 1)[0]
        if head in GIT_TAKES_ARG and "=" not in arg:
            index += 2
            continue
        if arg.startswith("-"):
            index += 1
            continue
        return arg, rest[index + 1:]
    return None, []


def git_push_forced(args):
    for arg in args:
        if arg in {"-f", "--force", "--force-with-lease", "--force-if-includes"} or arg.startswith("--force"):
            return True
        if short_has(arg, "f"):
            return True
        if not arg.startswith("-") and arg.startswith("+"):
            return True
    return False


def git_clean_forced(args):
    dry = False
    forced = False
    for arg in args:
        if arg in {"-n", "--dry-run"} or short_has(arg, "n"):
            dry = True
        if arg == "--force" or arg == "-f" or short_has(arg, "f"):
            forced = True
    return forced and not dry


def find_starts(rest):
    paths = []
    for arg in rest:
        if arg.startswith("-") or arg in {"(", ")", "!", ","}:
            break
        paths.append(arg)
    return paths


def find_deletes(rest):
    if "-delete" in rest:
        return True
    for index, arg in enumerate(rest):
        if arg in {"-exec", "-execdir", "-ok"} and index + 1 < len(rest):
            if os.path.basename(rest[index + 1]) in DELETERS:
                return True
    return False


def sql_texts(rest):
    texts = []
    index = 0
    while index < len(rest):
        arg = rest[index]
        if arg == "--":
            texts.extend(rest[index + 1:])
            break
        head, eq, tail = arg.partition("=")
        if head in SQL_TEXT_FLAGS:
            if eq:
                texts.append(tail)
            elif index + 1 < len(rest):
                texts.append(rest[index + 1])
                index += 2
                continue
            index += 1
            continue
        if arg.startswith("-"):
            if head in SQL_VALUE_FLAGS and not eq:
                index += 2
                continue
            index += 1
            continue
        texts.append(arg)
        index += 1
    return texts


def has_phrase(args, phrase):
    width = len(phrase)
    for index in range(len(args) - width + 1):
        if args[index:index + width] == phrase:
            return True
    return False


def fallback_scan(cmd):
    """Unparseable text: ask if a destructive command word is visible."""
    pattern = (
        r"(?:^|&&|\|\||;|\||\n|\()\s*"
        r"(?:(?:sudo|env|xargs|nohup|time|exec|command|doas)\s+)*"
        r"(rm|rmdir|unlink|shred|srm|trash|git|rsync|find|psql|mysql|mariadb|"
        r"sqlite3|terraform|kubectl|docker|aws|gcloud|railway|fly|flyctl|heroku)\b"
    )
    if re.search(pattern, cmd):
        return clip(cmd)
    return None


def seg_deletes(seg, allow, heredocs, prev_text, depth):
    seg = drop_redirs(seg)
    if not seg or "--help" in seg:
        return None
    index, via_xargs = skip_to_command(seg)
    if index >= len(seg):
        return None
    name = os.path.basename(seg[index])
    rest = seg[index + 1:]
    shown = " ".join(seg)

    if name in SHELLS and depth < 4:
        script = shell_script(rest)
        if script is not None:
            return describe_builtin(script, allow, heredocs, depth + 1)

    if name == "ssh" and depth < 4:
        remote = ssh_remote(rest)
        if remote:
            host, command = remote
            found = describe_builtin(command, allow, [], depth + 1)
            return clip(f"on {host}: {found}") if found else None

    if name in DELETERS:
        # xargs feeds paths from stdin, so the text cannot prove they are safe.
        if via_xargs:
            return clip(shown)
        paths = operands(rest)
        if not paths or all_allowed(paths, allow):
            return None
        return clip(shown)

    if name == "find" and find_deletes(rest):
        paths = find_starts(rest) or ["."]
        if all_allowed(paths, allow):
            return None
        return clip(shown)

    if name == "git":
        sub, args = git_child(rest)
        if sub == "rm" and "--cached" not in rest:
            paths = operands(args)
            if paths and not all_allowed(paths, allow):
                return clip(shown)
        elif sub == "clean" and git_clean_forced(args):
            paths = operands(args)
            if not (paths and all_allowed(paths, allow)):
                return clip(shown)
        elif sub == "push" and git_push_forced(args):
            return clip(shown)
        elif sub == "reset" and "--hard" in args:
            return clip(shown)

    if name == "rsync" and any(arg == "--remove-source-files" or arg.startswith("--delete") for arg in rest):
        paths = operands(rest)
        if not (paths and all(path_allowed(path, allow) and ":" not in path for path in paths)):
            return clip(shown)

    if name in SQL_CLIENTS:
        pieces = list(sql_texts(rest))
        if prev_text:
            pieces.append(prev_text)
        for piece in pieces:
            if sql_is_destructive(piece):
                return clip(f"{shown} :: {piece}")
        for _quoted, body in heredocs or []:
            if sql_is_destructive(body):
                return clip(f"{shown} << {body}")

    if name == "terraform":
        sub, args = git_child(rest)
        if sub == "destroy" or (sub == "apply" and any(arg in {"-destroy", "--destroy"} for arg in rest)):
            return clip(shown)

    if name == "kubectl" and "delete" in rest:
        return clip(shown)

    if name == "docker" and (has_phrase(rest, ["volume", "rm"]) or has_phrase(rest, ["volume", "remove"]) or has_phrase(rest, ["system", "prune"])):
        return clip(shown)

    if name == "aws" and (has_phrase(rest, ["s3", "rm"]) or has_phrase(rest, ["s3", "rb"])):
        return clip(shown)

    if name == "gcloud" and "delete" in [arg for arg in rest if not arg.startswith("-")]:
        return clip(shown)

    if name == "railway" and any(arg in {"delete", "destroy", "down"} for arg in rest if not arg.startswith("-")):
        return clip(shown)

    if name in {"fly", "flyctl"} and any(arg in {"delete", "destroy"} for arg in rest if not arg.startswith("-")):
        return clip(shown)

    if name == "heroku":
        for arg in rest:
            if arg == "destroy" or arg.endswith(":destroy") or arg == "pg:reset" or arg.startswith("pg:reset"):
                return clip(shown)
    return None


def describe_builtin(cmd, allow, inherited_heredocs=None, depth=0):
    if depth > 4 or not str(cmd).strip():
        return None
    peeled, heredocs = extract_heredocs(str(cmd))
    if inherited_heredocs:
        heredocs = list(inherited_heredocs) + heredocs
    executable = peel_substitutions(peeled)
    # Unquoted heredocs still expand substitutions. Scan those bodies too.
    for quoted, body in heredocs:
        if not quoted:
            executable += "\n; " + peel_substitutions(body)
    try:
        toks = tokens(executable)
    except ValueError:
        return fallback_scan(str(cmd))
    prev = None
    for seg in segments(toks):
        found = seg_deletes(seg, allow, heredocs, prev, depth)
        if found:
            return found
        prev = " ".join(seg)
    if heredocs and any(os.path.basename(part) in SQL_CLIENTS for part in toks):
        if any(sql_is_destructive(body) for _quoted, body in heredocs):
            return clip(cmd)
    return None


def describe(cmd, config=None):
    """Return a short label when cmd is destructive, else None."""
    config = default_config() if config is None else config
    text = "" if cmd is None else str(cmd)
    if not text.strip():
        return None
    for pattern in config.get("extra_patterns") or []:
        try:
            if re.search(pattern, text):
                return clip(text)
        except re.error:
            continue
    return describe_builtin(text, config.get("allow_paths") or [])


def mcp_target(tool_name):
    if not isinstance(tool_name, str) or not tool_name.startswith("mcp__"):
        return None
    leaf = tool_name.split("__")[-1]
    if re.search(r"(?i)(delete|destroy|trash|(?<![A-Za-z])drop(?![A-Za-z]))", leaf):
        return tool_name
    return None


def gated_action(payload, config=None):
    if not isinstance(payload, dict):
        return None
    config = default_config() if config is None else config
    tool = str(payload.get("tool_name") or "")
    raw_input = payload.get("tool_input") or {}
    tool_input = raw_input if isinstance(raw_input, dict) else {}
    if tool in {"Bash", "bash"}:
        return describe(str(tool_input.get("command") or ""), config)
    mcp = mcp_target(tool)
    if mcp:
        preview = json.dumps(tool_input, default=str)[:80]
        return clip(f"{mcp} {preview}")
    return None


def verify_signature(challenge, signature_b64, public_key):
    try:
        signature = base64.b64decode(signature_b64, validate=True)
    except (ValueError, TypeError):
        return False
    if not signature or not os.path.isfile(public_key):
        return False
    try:
        with tempfile.TemporaryDirectory(prefix="touchgate-") as directory:
            payload = os.path.join(directory, "payload")
            sig_path = os.path.join(directory, "sig")
            with open(payload, "wb") as handle:
                handle.write(PAYLOAD_PREFIX + str(challenge).encode())
            with open(sig_path, "wb") as handle:
                handle.write(signature)
            result = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", public_key, "-signature", sig_path, payload],
                capture_output=True,
                text=True,
                timeout=10,
            )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and "Verified OK" in (result.stdout or "")


def ask(what, helper, public_key, timeout):
    """Ask the Touch ID helper. Any failure is a denial."""
    if not helper or not os.path.isfile(helper) or not os.access(helper, os.X_OK):
        shown = display_path(helper or auth_path())
        return False, "none", (
            f"no way to ask: {shown} is missing or not executable. "
            "Run install.sh on a Mac with Touch ID. Linux support is planned."
        )
    challenge = secrets.token_hex(16)
    reason = clip(f"TouchGate: approve destructive command: {what}", 180)
    try:
        result = subprocess.run(
            [helper, "--challenge", challenge, "--reason", reason],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False, "touchid", "no approval within the time limit"
    except OSError as exc:
        return False, "touchid", f"could not run the approval helper: {exc}"
    parsed = {}
    if result.stdout and result.stdout.strip():
        try:
            parsed = json.loads(result.stdout.strip().splitlines()[-1])
        except json.JSONDecodeError:
            return False, "touchid", "approval helper returned unreadable output"
    if result.returncode != 0 or parsed.get("ok") is not True:
        return False, "touchid", str(parsed.get("error") or f"exit {result.returncode}")
    if parsed.get("challenge") != challenge or not parsed.get("signature"):
        return False, "touchid", "approval did not match this command"
    if not verify_signature(challenge, parsed.get("signature"), public_key):
        return False, "touchid", "signature did not verify"
    return True, "touchid", ""


def log_decision(record, path):
    try:
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, mode=0o700, exist_ok=True)
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
        return


def block_message(method, detail):
    why = method if not detail else f"{method}: {detail}"
    return (
        f"TouchGate blocked this destructive command ({why}). "
        "Nothing was run. Do not retry or work around it. "
        "Tell the human what you wanted to run and why, and let them approve it with Touch ID."
    )


def run_hook(payload, *, config=None, auth=None, pubkey=None, log_file=None, platform=None, ask_timeout=100, approver=None):
    """Return the process exit code for one hook payload."""
    config = load_config() if config is None else config
    what = gated_action(payload, config)
    if not what:
        return 0
    host = sys.platform if platform is None else platform
    if approver is not None:
        ok, method, detail = approver(what)
    elif host != "darwin":
        ok, method, detail = (
            False,
            "not-macos",
            "Touch ID approval is macOS-only. Linux support is planned.",
        )
    else:
        ok, method, detail = ask(
            what,
            auth_path() if auth is None else auth,
            pubkey_path() if pubkey is None else pubkey,
            ask_timeout,
        )
    log_decision(
        {
            "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "approved": bool(ok),
            "method": method,
            "detail": detail[:300],
            "command": what[:500],
        },
        log_path() if log_file is None else log_file,
    )
    if ok:
        return 0
    print(block_message(method, detail), file=sys.stderr)
    return 2


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] == "--check":
        command = args[1] if len(args) == 2 else " ".join(args[1:])
        found = describe(command, load_config())
        print(("GATED: " + found) if found else "not gated")
        return 0
    # Claude Code treats exit 1 as non-blocking, so an uncaught crash here would
    # let the command run. Anything unexpected has to end as a deny.
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise ValueError("payload is not a JSON object")
        return run_hook(payload)
    except Exception as exc:  # pylint: disable=broad-except
        print(block_message("error", "the hook could not read this request: " + type(exc).__name__), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
