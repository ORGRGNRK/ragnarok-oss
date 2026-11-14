#!/usr/bin/env python3
"""Brain router: pick a cartridge for a question, then ask the local model with that cartridge's rules.

    python3 brain/router.py "How should I grade an iPhone with cracked glass?"
    python3 brain/router.py --dry-run "..."     # show the choice and the prompt; do not call the model

Settings: BRAIN_OLLAMA_HOST (default http://127.0.0.1:11434; must be this machine or your LAN),
BRAIN_CHAT_MODEL (default llama3.2:3b), BRAIN_EMBED_MODEL (default nomic-embed-text).

What it does NOT do: it does not check the answer, it does not write anywhere, and it keeps no
record. The answer is a PROPOSAL from a small local model following UNVERIFIED rules; read it as such.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lookup"))
import lookup  # noqa: E402

CHAT_MODEL = os.environ.get("BRAIN_CHAT_MODEL", "llama3.2:3b")


def build_prompt(question: str, cartridge: dict | None) -> tuple[str, str]:
    if cartridge is None:
        system = ("You are a careful assistant. No specialist rules apply to this question. "
                  "Answer briefly. If you are not sure, say so plainly.")
        return system, question
    rules = "\n".join(f"- {r}" for r in cartridge.get("knowledge_rules", []))
    system = (f"You are helping with: {cartridge.get('domain', cartridge['id'])}.\n"
              f"Use these rules. They are UNVERIFIED (not checked against a real source), so if your answer "
              f"depends on one, say which rule and that it is unverified. If the rules do not cover the "
              f"question, say so instead of guessing.\nRules:\n{rules}")
    return system, question


def ask(system: str, question: str) -> str:
    res = lookup.post_json("/api/chat", {"model": CHAT_MODEL, "stream": False, "options": {"temperature": 0.2},
                                         "messages": [{"role": "system", "content": system},
                                                      {"role": "user", "content": question}]}, timeout=300)
    return res["message"]["content"].strip()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Pick a cartridge and ask the local model.")
    ap.add_argument("question", nargs="+")
    ap.add_argument("--dry-run", action="store_true", help="show the cartridge choice and prompt only")
    a = ap.parse_args(argv)
    question = " ".join(a.question)
    p = lookup.pick(question, lookup.load_cartridges())
    c = p.chosen
    if c:
        print(f"cartridge: {c['id']} ({p.reason}){'; close: ' + ', '.join(p.close) if p.close else ''}")
        print(f"WARNING ({c.get('status', 'UNVERIFIED')}): {c.get('warning', '')}")
    else:
        print(f"cartridge: none ({p.reason}); asking the model without specialist rules")
    system, user = build_prompt(question, c)
    if a.dry_run:
        print("\n--- system prompt ---\n" + system + "\n--- question ---\n" + user)
        return 0
    answer = ask(system, user)
    print(f"\nPROPOSAL from {CHAT_MODEL} at {lookup.ollama_host()} (not checked; verify before acting):\n")
    print(answer)
    return 0


if __name__ == "__main__":
    sys.exit(main())
