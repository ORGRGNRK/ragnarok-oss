#!/usr/bin/env python3
"""Morning-and-hourly drafter for the Proved plan.

Reads today's checklist, collects the last 24 hours of git and agent outcomes,
and asks the local Alexus model for a post plus two outreach drafts. Writes
~/.ragnarok/plan-daemon/queue/<date>-<kind>.md and appends every action to
~/.ragnarok/plan-daemon/log.jsonl. Notifies the owner so they can run approve.py.

This process does not post and does not tick the checklist. A public post
happens only when approve.py's hardware gate succeeds.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import evidence
import model
from journal import log_action
from paths import queue_dir
from plan_api import PlanClient, load_token
from queue_file import render_queue, split_queue

DEFAULT_REPOS = (
    Path.home() / "Developer" / "ragnarok",
    Path.home() / "Developer" / "proved-plan",
)


def notify_ready(message: str, spawn=None) -> None:
    spawn = subprocess.run if spawn is None else spawn
    script = "display notification %s with title %s" % (json.dumps(message), json.dumps("Proved plan"))
    try:
        spawn(["osascript", "-e", script], capture_output=True, text=True, timeout=5)
    except Exception:
        return


def local_day(now: datetime) -> str:
    if now.tzinfo is None:
        now = now.astimezone()
    else:
        now = now.astimezone()
    return now.strftime("%Y-%m-%d")


class Config(object):
    def __init__(
        self,
        home: Path,
        now: datetime = None,
        repos=None,
        agents_dir: Path = None,
        client=None,
        model_post=None,
        git_run=None,
        notify=None,
        api_base: str = None,
        token: str = None,
    ):
        self.home = Path(home)
        self.now = now or datetime.now().astimezone()
        self.repos = tuple(DEFAULT_REPOS if repos is None else repos)
        self.agents_dir = Path.home() / ".ragnarok" / "agents" if agents_dir is None else Path(agents_dir)
        self.client = client
        self.model_post = model_post
        self.git_run = subprocess.run if git_run is None else git_run
        self.notify = notify_ready if notify is None else notify
        self.api_base = api_base or os.environ.get("PLAN_API_BASE", "https://plan.rgnrk.co")
        self.token = load_token() if token is None else token


def _queue_names(day: str):
    return ("%s-post.md" % day, "%s-outreach-1.md" % day, "%s-outreach-2.md" % day)


def _write_queue(directory: Path, day: str, drafts: dict, source: str):
    directory.mkdir(parents=True, exist_ok=True)
    bodies = {
        "%s-post.md" % day: drafts["post"],
        "%s-outreach-1.md" % day: drafts["outreach"][0],
        "%s-outreach-2.md" % day: drafts["outreach"][1],
    }
    written = []
    for name, body in bodies.items():
        path = directory / name
        path.write_text(render_queue(name, source, day, body), encoding="utf-8")
        written.append(str(path))
    return written


def _queued(directory: Path, name: str):
    path = directory / name
    if not path.is_file():
        return None
    try:
        return split_queue(path.read_text(encoding="utf-8"))
    except OSError:
        return None


def _all_source(directory: Path, names, source: str) -> bool:
    """True when every file exists, is this source, and has a non-empty body."""
    for name in names:
        found = _queued(directory, name)
        if found is None:
            return False
        got, body = found
        if got != source or not body.strip():
            return False
    return True


def _notify(cfg: Config, home: Path, day: str, message: str) -> None:
    try:
        cfg.notify(message)
        log_action(home, "notify", day=day)
    except Exception as exc:
        log_action(home, "notify", day=day, ok=False, error=str(exc)[:300])


def run(cfg: Config) -> dict:
    home = cfg.home
    day = local_day(cfg.now)
    log_action(home, "start", day=day)
    directory = queue_dir(home)
    names = _queue_names(day)
    files = [str(directory / name) for name in names]

    # State is read on every run, including the quiet hours after a real draft.
    client = cfg.client
    if client is None:
        client = PlanClient(cfg.api_base, cfg.token)
    state = None
    try:
        state = client.state(day)
        log_action(home, "api_state", day=day, ok=True)
    except Exception as exc:
        log_action(home, "api_state", day=day, ok=False, error=str(exc)[:300])

    if _all_source(directory, names, "model"):
        log_action(home, "skip", reason="drafts already queued", day=day)
        return {"drafted": False, "day": day, "files": files, "source": "model", "state": state}

    facts = evidence.collect(cfg.now, cfg.repos, cfg.agents_dir, cfg.git_run)
    log_action(home, "evidence", chars=len(facts))
    try:
        raw = model.chat(facts, post=cfg.model_post)
        drafts = model.require_human_outreach(model.parse_draft(raw), facts)
        log_action(home, "model", ok=True)
        files = _write_queue(directory, day, drafts, "model")
        for path in files:
            log_action(home, "queue_write", file=Path(path).name, source="model")
        _notify(
            cfg,
            home,
            day,
            "Draft ready (%s). Approve it in Terminal before anything goes out." % day,
        )
        return {"drafted": True, "day": day, "files": files, "source": "model", "state": state}
    except Exception as exc:
        log_action(home, "model", ok=False, error=str(exc)[:300])
        # A fallback set stays put so a still-down model does not notify every hour.
        # The files stay source: fallback, so the next hour tries the model again.
        if _all_source(directory, names, "fallback"):
            log_action(home, "skip", reason="fallback already queued", day=day)
            return {"drafted": False, "day": day, "files": files, "source": "fallback", "state": state}
        drafts = model.fallback_draft(facts)
        files = _write_queue(directory, day, drafts, "fallback")
        for path in files:
            log_action(home, "queue_write", file=Path(path).name, source="fallback")
        _notify(
            cfg,
            home,
            day,
            "Local model did not answer (%s). Notes will be retried. Nothing is ready to approve." % day,
        )
        return {"drafted": True, "day": day, "files": files, "source": "fallback", "state": state}


def main(argv=None) -> int:
    del argv
    home = Path.home()
    try:
        run(Config(home=home))
    except Exception as exc:
        try:
            log_action(home, "error", error=str(exc)[:500])
        except Exception:
            print(exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
