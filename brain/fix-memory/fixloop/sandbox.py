"""Run a test command inside a throwaway Docker/OrbStack container.

The project copy is mounted at /work, networking is disabled, and the container is removed
after every run (docker run --rm). Pass/fail is the command's exit code (0 = pass)."""
from __future__ import annotations

import subprocess
import uuid
from dataclasses import dataclass
from pathlib import Path

from .config import settings


@dataclass
class TestResult:
    exit_code: int
    output: str
    timed_out: bool = False

    @property
    def passed(self) -> bool:
        return self.exit_code == 0 and not self.timed_out


def run_tests(workdir: Path, test_cmd: str, image: str | None = None, timeout: int | None = None) -> TestResult:
    image = image or settings.runner_image
    timeout = timeout or settings.test_timeout
    name = f"fixloop-{uuid.uuid4().hex[:10]}"
    cmd = [
        "docker", "run", "--rm", "--name", name,
        "--network", "none", "--memory", "1g", "--cpus", "2",
        "-e", "PYTHONDONTWRITEBYTECODE=1",
        "-v", f"{workdir.resolve()}:/work", "-w", "/work",
        image, "sh", "-c", test_cmd,
    ]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return TestResult(p.returncode, (p.stdout or "") + (p.stderr or ""))
    except subprocess.TimeoutExpired as e:
        subprocess.run(["docker", "kill", name], capture_output=True)
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return TestResult(124, out + f"\n[fixloop] test command timed out after {timeout}s", timed_out=True)
