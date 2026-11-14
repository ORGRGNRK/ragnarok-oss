#!/usr/bin/env bash
# local-api.sh — the local seat over an OpenAI-compatible API, proven against
# a stub server (python http.server returning canned chat-completions JSON).
# NO MODEL IS CALLED. The stub plays a model on another machine: first reply
# asks for two tool calls (write the output file; dump the environment), the
# second reply is the answer. It records whether the Bearer key arrived, never
# the key itself.
#
# ASSERTION COUNT IS ASSERTED, as in portable.sh.
set -u
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$PKG/conveyor-run.sh"
PASS=0; FAIL=0
EXPECTED=15
if [ "$(uname -s)" = Darwin ] && command -v brew >/dev/null 2>&1; then
  bp="$(brew --prefix)"
  for d in "$bp/bin" "$bp/opt/flock/bin" "$bp/opt/gnu-sed/libexec/gnubin" "$bp/opt/coreutils/libexec/gnubin"; do
    [ -d "$d" ] && PATH="$d:$PATH"
  done; export PATH
fi
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

S="$(mktemp -d "${TMPDIR:-/tmp}/local-api-test.XXXXXX")"
SRV_PID=""
trap '[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$S"' EXIT
KEY="sk-test-$(date +%s)-$$-do-not-leak"
FAKEHOME="$S/home"; mkdir -p "$FAKEHOME/bin"

# The verifier stays a stub claude, so only the driver leg is the local seat.
cat > "$FAKEHOME/bin/claude" <<'SEAT'
#!/usr/bin/env bash
jq -nc --arg t "CONFIRMED: the output file says hello
VERDICT: pass" '{type:"result",subtype:"success",is_error:false,result:$t}'
SEAT
chmod +x "$FAKEHOME/bin/claude"

cat > "$S/server.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
S, KEY = sys.argv[1], sys.argv[2]
def mode():
    try: return open(os.path.join(S, "mode")).read().strip()
    except OSError: return "ok"
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path == "/v1/models":
            self.send(200, {"object": "list", "data": [{"id": "stub-coder", "object": "model"}]})
        else: self.send(404, {})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        with open(os.path.join(S, "auth"), "a") as f:
            f.write("bearer-ok\n" if self.headers.get("Authorization") == "Bearer " + KEY else "bearer-missing\n")
        with open(os.path.join(S, "models"), "a") as f: f.write(body.get("model", "") + "\n")
        if mode() == "down500": return self.send(500, {"error": "boom"})
        msgs = body["messages"]
        prompt = msgs[0]["content"]
        out = prompt.split("OUTFILE=")[1].split()[0]
        if msgs[-1]["role"] == "tool":
            msg = {"role": "assistant", "content": "Wrote the file.\nRESULT: done"}
        else:
            msg = {"role": "assistant", "content": None, "tool_calls": [
                {"id": "c1", "type": "function", "function": {"name": "write_file",
                    "arguments": json.dumps({"path": out, "content": "hello\n"})}},
                {"id": "c2", "type": "function", "function": {"name": "bash",
                    "arguments": json.dumps({"command": "env > " + os.path.join(S, "toolenv")})}}]}
        # "model": the name the server says served the request (differs from the one asked for, on purpose)
        self.send(200, {"id": "x", "object": "chat.completion", "model": body.get("model", "") + "-served",
                        "choices": [{"index": 0, "message": msg, "finish_reason": "stop"}]})
HTTPServer(("127.0.0.1", int(sys.argv[3])), H).serve_forever()
PY
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
BASE="http://127.0.0.1:$PORT/v1"

newroot() { R="$S/$1"; mkdir -p "$R"/{queue,running,verify,human,done,failed,logs}
  cat > "$R/queue/t.md" <<T
# t

Want: write the word hello into OUTFILE=$S/$1.out

## Checklist
- [ ] the output file says hello :: verify: grep -qx hello $S/$1.out
T
}
belt() { # extra env...; one runner invocation
  env -u CREW_ACTOR -u CONVEYOR_SELF -u CONVEYOR_SELF_SNAPSHOT \
      HOME="$FAKEHOME" CONVEYOR_ROOT="$R" CONVEYOR_STANDALONE=1 CONVEYOR_CLAUDE="$FAKEHOME/bin/claude" \
      CONVEYOR_DRIVER_SEAT=local CONVEYOR_VERIFIER_SEAT=claude CONVEYOR_LOCAL_BASE_URL="$BASE" \
      CONVEYOR_LOCAL_MODEL=stub-coder CONVEYOR_LOCAL_API_KEY="$KEY" "$@" bash "$RUN" >> "$R/belt.out" 2>&1
}

echo "-- A. no server: the belt refuses to start and says where it looked"
newroot nosrv; belt
grep -q "local seat selected but $BASE/models did not answer" "$R/belt.out" && ok "names the unreachable URL" || bad "belt.out: $(cat "$R/belt.out")"
[ -f "$R/queue/t.md" ] && ok "the task was not touched" || bad "task moved"

python3 "$S/server.py" "$S" "$KEY" "$PORT" & SRV_PID=$!
for i in $(seq 50); do curl -fsS -m 1 "$BASE/models" >/dev/null 2>&1 && break; sleep 0.1; done

echo "-- B. a model the server does not have is refused"
newroot nomodel; belt CONVEYOR_LOCAL_MODEL=not-there
grep -q "does not serve not-there" "$R/belt.out" && ok "names the missing model" || bad "belt.out: $(cat "$R/belt.out")"

echo "-- C. a working server: tools run, the task reaches done/"
newroot good; belt; belt; belt
[ -f "$R/done/t.md" ] && ok "task filed in done/" || bad "task at: $(cd "$R" && ls -d */t.md)"
[ "$(cat "$S/good.out" 2>/dev/null)" = hello ] && ok "the model's write_file call really wrote the file" || bad "output file missing"
grep -q 'driver leg (local seat)' "$R"/logs/*.log && ok "the leg log names the local seat" || bad "no local-seat leg log"
grep -q '"type":"tool_use"' "$R"/logs/*.jsonl && ok "tool calls are in the live-view stream (.jsonl)" || bad "no tool_use in jsonl"
[ "$(sort -u "$S/auth")" = bearer-ok ] && ok "every request carried the API key" || bad "auth: $(sort -u "$S/auth" | tr '\n' ' ')"
[ "$(sort -u "$S/models")" = stub-coder ] && ok "requests named CONVEYOR_LOCAL_MODEL" || bad "models: $(sort -u "$S/models")"
grep -q '"seat":"driver","model_reported":"stub-coder-served"' "$R/logs/receipts.jsonl" \
  && ok "the driver receipt records the model the API reported (model_reported), not the configured name" || bad "receipts: $(cat "$R/logs/receipts.jsonl")"
grep -q '"seat":"verifier","model_reported":null' "$R/logs/receipts.jsonl" \
  && ok "a seat whose output reports no model gets model_reported null" || bad "receipts: $(cat "$R/logs/receipts.jsonl")"
if grep -rqF -- "$KEY" "$R"; then bad "the API key leaked into the belt folder"; else ok "the API key appears nowhere in the belt folder (logs, task, receipts)"; fi
if grep -qF -- "$KEY" "$S/toolenv" 2>/dev/null || [ ! -s "$S/toolenv" ]; then bad "the key reached a command the model ran (or no env dump)"
else ok "commands the model runs do not get the API key"; fi

echo "-- D. a server error is a seat crash: refunded, back in queue/"
newroot err; echo down500 > "$S/mode"; belt
[ -f "$R/queue/t.md" ] && grep -q '^## Leg [0-9]* — seat crash' "$R/queue/t.md" && ok "task back in queue/ with a seat-crash note" || bad "task at: $(cd "$R" && ls -d */t.md)"
if grep -rqF -- "$KEY" "$R"; then bad "the key leaked on the error path"; else ok "no key on the error path either"; fi
rm -f "$S/mode"

RAN=$((PASS+FAIL))
printf '\nlocal-api.sh: %s passed, %s failed (%s/%s assertions ran)\n' "$PASS" "$FAIL" "$RAN" "$EXPECTED"
[ "$RAN" -eq "$EXPECTED" ] || { printf 'ASSERTION COUNT WRONG — some check never ran.\n'; exit 1; }
[ "$FAIL" -eq 0 ]
