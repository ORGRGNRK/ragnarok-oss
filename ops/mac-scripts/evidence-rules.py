#!/usr/bin/env python3
"""UserPromptSubmit hook: put the evidence rules in front of every turn.

R-16: a rule that only lives in prose gets skipped. On 10-24 the video
description filled gaps between frames as fact even though boot carried
R-09/R-11/R-14. This hook makes the rules arrive with each prompt.

Static text only. No database reads, no network, no state. The 10-23
retirement came from bad memory content riding along in per-turn context,
so nothing dynamic goes in here.
"""
import json
import os
import sys

RULES = """EVIDENCE RULES (R-09 / R-11 / R-14), every answer:
- Describe only what was actually examined. Name the subset: "looked at 5 of 8 frames", "read lines 1-200".
- Unknown stays unknown. Never fill a gap with a likely value, motion, cause or detail.
- Mark inference as inference ("probably", "not checked"). Keep it separate from what was seen.
- Before describing a file, image, video or log, examine all of what was extracted or say what was skipped.
- If a claim has no tool output behind it this session, check it or label it unverified.
- Real-world facts that change by time or place (prices, what a store/shop/service takes or pays, fees, policies, laws, hours, availability, current versions/events) need a WebSearch BEFORE you state or suggest them, even inside a list of options. No search: leave it out or say "not checked"."""


def main():
    if os.environ.get("EVIDENCE_AUDIT_INNER"):
        return
    try:
        json.load(sys.stdin)
    except Exception:
        pass
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": RULES,
        }
    }))


if __name__ == "__main__":
    main()
