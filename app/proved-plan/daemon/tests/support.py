"""Shared fixtures. Imported by the test modules; not a test itself."""
from __future__ import annotations

import sys
from pathlib import Path

DAEMON = Path(__file__).resolve().parents[1]
if str(DAEMON) not in sys.path:
    sys.path.insert(0, str(DAEMON))
