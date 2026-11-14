#!/bin/zsh
# One-time setup for fix-memory inside Ragnarok. The database is the data layer's ONE Postgres
# (start it with: cd ragnarok/data && ./kit up); fixloop reads the connection from data/.env.
# This builds the throwaway test-runner image and the Python env, then checks everything.
set -euo pipefail
export PATH=$PATH:/opt/homebrew/bin:$HOME/.orbstack/bin
cd "$(dirname "$0")/.."

docker build -q -t "${FIXLOOP_RUNNER_IMAGE:-ragnarok-brain-runner:local}" runner >/dev/null && echo "runner image ready"
uv sync -q && echo "python env ready"
uv run fixloop doctor
