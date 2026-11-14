#!/bin/zsh
# End-to-end demo: seed memory, heal a fresh copy of the broken demo, then do it again
# on another fresh copy of the same bug to show the stored fix being retrieved and reused.
# Needs: the data layer running (cd ragnarok/data && ./kit up), scripts/setup.sh done, Ollama reachable.
# Exit code 0 only if run 1 passed, run 2 passed by reusing a stored fix, and receipts verify.
# Small local models are not fully reliable: if run 1 gives up, re-run or raise FIXLOOP_MAX_TRIES.
# (Default model qwen2.5-coder:7b: 5 of 5 heals in testing; the old 3B default managed 3 of 13.)
set -uo pipefail
export PATH=$PATH:/opt/homebrew/bin:$HOME/.orbstack/bin
cd "$(dirname "$0")/.."
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p .work
uv run fixloop seed-demo || exit 1
for n in 1 2; do
  rm -rf .work/demo-run$n-$TS && cp -R examples/demo_median .work/demo-run$n-$TS
  echo "\n================ RUN $n (fresh copy of the broken demo) ================"
  uv run fixloop run .work/demo-run$n-$TS --test 'pytest -q -p no:cacheprovider' --max-tries ${FIXLOOP_MAX_TRIES:-5} \
    | tee .work/demo-run$n-$TS.log
done
echo "\n================ RECEIPTS ================"
uv run fixloop receipts --limit 10
uv run fixloop verify; VERIFY=$?
python3 - .work/demo-run1-$TS.log .work/demo-run2-$TS.log "$VERIFY" <<'PY'
import json, sys
def summary(path):
    for line in open(path):
        if line.startswith("[fixloop] summary "):
            return json.loads(line[len("[fixloop] summary "):])
    return {}
r1, r2 = summary(sys.argv[1]), summary(sys.argv[2])
ok1 = bool(r1.get("passed"))
ok2 = bool(r2.get("passed")) and r2.get("reused_fix_id") is not None
okv = sys.argv[3] == "0"
print(f"\nDEMO RESULT: run1 passed={ok1} (tries {r1.get('tries')}, healed={r1.get('healed')}); "
      f"run2 passed={bool(r2.get('passed'))} reused stored fix #{r2.get('reused_fix_id')} (tries {r2.get('tries')}); "
      f"receipts verify={okv}")
sys.exit(0 if (ok1 and ok2 and okv) else 1)
PY
