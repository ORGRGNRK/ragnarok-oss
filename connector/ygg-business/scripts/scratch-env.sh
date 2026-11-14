#!/usr/bin/env bash
# Run a command with the scratch Business database URLs in its environment.
#   ./scripts/scratch-env.sh npm test
# Reads ~/Developer/ygg-scratch/.env (or $YGG_SCRATCH_ENV) inside this process only.
# Never prints, logs or writes a secret: the URLs exist only in the child's env.
set -euo pipefail
ENV_FILE="${YGG_SCRATCH_ENV:-$HOME/Developer/ygg-scratch/.env}"
[ -r "$ENV_FILE" ] || { echo "scratch-env: cannot read $ENV_FILE" >&2; exit 2; }

set +x
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# Percent-encode inside node and hand the result straight to the variable.
build_url() { # $1 = role, $2 = name of the variable holding its secret
  ROLE="$1" SECRET_VAR="$2" node -e '
    const e = process.env, s = e[e.SECRET_VAR];
    if (!s || !e.YGG_PG_PORT) process.exit(3);
    process.stdout.write("postgresql://" + e.ROLE + ":" + encodeURIComponent(s) + "@127.0.0.1:" + e.YGG_PG_PORT + "/ygg_business");'
}
BUSINESS_READ_DATABASE_URL="$(build_url ygg_read YGG_READ_PASSWORD)" || { echo "scratch-env: read credentials missing in env file" >&2; exit 2; }
BUSINESS_APP_DATABASE_URL="$(build_url ygg_app YGG_APP_PASSWORD)" || { echo "scratch-env: app credentials missing in env file" >&2; exit 2; }
export BUSINESS_READ_DATABASE_URL BUSINESS_APP_DATABASE_URL

# Drop every raw variable from the env file so the child sees only the two URLs.
for v in $(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$ENV_FILE"); do unset "$v"; done

exec "$@"
