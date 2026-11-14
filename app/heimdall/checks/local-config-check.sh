#!/bin/bash
# checks/local-config-check.sh — bin/local-config.sh with throwaway configs (good, bad, missing).
# Run from the repo folder: bash checks/local-config-check.sh   (prints PASS or FAIL lines; exit 1 on any FAIL)
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf '# t\nALEXUS_HOST = 10.9.8.7\nALEXUS_USER="tester"\nOLLAMA_URL=http://box.test:1/\nALEXUS_HOST=10.9.8.8\n' > "$T/good"
printf 'ALEXUS_HOST=-oProxyCommand=x\nALEXUS_USER=Root;rm\nOLLAMA_URL=file:///etc\nALEXUS_TAILSCALE=a b\n' > "$T/bad"
fail=0
check() { # conf expected
  local got; got=$(RAGNAROK_LOCAL_CONF="$T/$1" bash -c '. bin/local-config.sh; echo "$ALEXUS_SSH|$ALEXUS_TAILSCALE|$OLLAMA_URL"')
  if [ "$got" = "$2" ]; then echo "PASS $1"; else echo "FAIL $1: got $got want $2"; fail=1; fi
}
ME=$(id -un)
check good "tester@10.9.8.8|alexus|http://box.test:1"
check bad  "$ME@alexus.local|alexus|http://alexus.local:11434"
check none "$ME@alexus.local|alexus|http://alexus.local:11434"
exit $fail
