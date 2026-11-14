"""Settings come from environment variables, then brain/fix-memory/.env (optional, FIXLOOP_* only),
then the data layer's settings file (ragnarok/data/.env) for the database connection.

Ragnarok has ONE Postgres per project: fix-memory's tables live in the data layer's database
(data/db/brain.sql) and fixloop connects with the AI's read/write login (MCP_DB_USER), which can
read and ADD fixes but never change or delete them. Every added fix gets a hash-chained write_log
receipt from the database itself."""
from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

REPO_ROOT = Path(__file__).resolve().parent.parent          # ragnarok/brain/fix-memory
DATA_ENV = REPO_ROOT.parent.parent / "data" / ".env"         # ragnarok/data/.env


def _read_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip()
    return out


for k, v in _read_env(Path(os.environ.get("FIXLOOP_ENV_FILE", REPO_ROOT / ".env"))).items():
    if k.startswith("FIXLOOP_"):
        os.environ.setdefault(k, v)

# Database: explicit FIXLOOP_PG_* wins; otherwise the data layer's settings (KIT_ENV_FILE lets a
# throwaway test stack point here too).
_data = _read_env(Path(os.environ.get("KIT_ENV_FILE", DATA_ENV)))
_DB_DEFAULTS = {
    "FIXLOOP_PG_HOST": "127.0.0.1",
    "FIXLOOP_PG_PORT": _data.get("POSTGRES_PORT", "5491"),
    "FIXLOOP_PG_DB": _data.get("POSTGRES_DB", "clientdata"),
    "FIXLOOP_PG_USER": _data.get("MCP_DB_USER", "kit_mcp"),
    "FIXLOOP_PG_PASSWORD": _data.get("MCP_DB_PASSWORD", ""),
}
for k, v in _DB_DEFAULTS.items():
    os.environ.setdefault(k, v)


def is_local_url(url: str) -> bool:
    """Only this machine, a private LAN address (e.g. the alexus box) or Docker's host alias."""
    host = (urlparse(url).hostname or "").lower()
    if host in ("localhost", "host.docker.internal") or host.endswith(".local"):
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return ip.is_loopback or ip.is_private


@dataclass(frozen=True)
class Settings:
    pg_host: str = os.environ["FIXLOOP_PG_HOST"]
    pg_port: int = int(os.environ["FIXLOOP_PG_PORT"])
    pg_db: str = os.environ["FIXLOOP_PG_DB"]
    pg_user: str = os.environ["FIXLOOP_PG_USER"]
    pg_password: str = os.environ["FIXLOOP_PG_PASSWORD"]
    ollama_host: str = os.environ.get("FIXLOOP_OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")
    coder_model: str = os.environ.get("FIXLOOP_CODER_MODEL", "qwen2.5-coder:7b")
    embed_model: str = os.environ.get("FIXLOOP_EMBED_MODEL", "nomic-embed-text")
    runner_image: str = os.environ.get("FIXLOOP_RUNNER_IMAGE", "ragnarok-brain-runner:local")
    max_tries: int = int(os.environ.get("FIXLOOP_MAX_TRIES", "5"))
    # Only past fixes at/above this cosine similarity are given to the model (all top-3 are logged).
    min_similarity: float = float(os.environ.get("FIXLOOP_MIN_SIMILARITY", "0.97"))
    # Candidate edits sampled per try (each one is tested in its own throwaway container).
    candidates: int = int(os.environ.get("FIXLOOP_CANDIDATES", "3"))
    test_timeout: int = int(os.environ.get("FIXLOOP_TEST_TIMEOUT", "300"))
    # Who receipts say made the change (write_log.actor).
    actor: str = os.environ.get("FIXLOOP_ACTOR", "fixloop")

    def conninfo(self) -> str:
        return (
            f"host={self.pg_host} port={self.pg_port} dbname={self.pg_db} "
            f"user={self.pg_user} password={self.pg_password} application_name=ragnarok-brain-fixloop"
        )


settings = Settings()
if not is_local_url(settings.ollama_host):
    raise SystemExit(f"FIXLOOP_OLLAMA_HOST must be a local or LAN address (no cloud AI); got {settings.ollama_host!r}")
