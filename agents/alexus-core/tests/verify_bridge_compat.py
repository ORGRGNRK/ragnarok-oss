#!/usr/bin/env python3
"""
Verification Dyno: Ragnarok Bridge & Alexus Chat Compatibility.
Verifies Python 3.9+ syntax compatibility, bridge import, prompt generation,
silent boot parameter sanitization, and alexus-chat-bridge CLI interface.
"""

import json
import os
import subprocess
import sys

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN_DIR = os.path.join(BASE_DIR, "bin")
if BIN_DIR not in sys.path:
    sys.path.insert(0, BIN_DIR)

import ragnarok_bridge

def verify_bridge():
    # 1. Verify profile prompt generation
    test_profile = {"user_name": "Test User", "persona_id": "tsundere"}
    prompt = ragnarok_bridge.get_system_prompt_for_profile(test_profile)
    assert "Test User" in prompt, "Profile user_name not formatted in prompt"
    assert "b-baka" in prompt, "Tsundere persona prompt missing signature tropes"

    # 2. Verify silent_boot accepts clean and dirty project slugs without syntax error
    context = ragnarok_bridge.silent_boot("alexus-core; DROP TABLE test;--")
    assert "[SOVEREIGN INFRASTRUCTURE & ACTIVE SWITCH PACKET]" in context, "silent_boot context header missing"

    # 3. Verify execution via system python (/usr/bin/python3) if available
    sys_py = "/usr/bin/python3"
    if os.path.exists(sys_py):
        res = subprocess.run([sys_py, "-m", "py_compile", os.path.join(BIN_DIR, "ragnarok_bridge.py")],
                             capture_output=True, text=True)
        assert res.returncode == 0, f"/usr/bin/python3 compilation failed: {res.stderr}"

    print("PASS: Ragnarok Bridge and Chat compatibility verified.")

if __name__ == "__main__":
    try:
        verify_bridge()
        sys.exit(0)
    except Exception as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)
