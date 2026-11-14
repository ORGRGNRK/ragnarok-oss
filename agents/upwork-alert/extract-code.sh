#!/bin/bash
# Usage: extract-code.sh <file>  (file: "Subject: ..." line 1, "From: ..." line 2, body after)
# Prints "VERIFY<TAB><code or empty>" if the email looks like a verification / login code email, else nothing.
/usr/bin/python3 - "$1" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()[:4000]
subj = t.splitlines()[0] if t else ""
low = t.lower()
keys = ["verification code", "verify your", "security code", "login code", "sign-in code", "sign in code",
        "one-time code", "one time code", "one-time passcode", "passcode", "confirm your email",
        "confirmation code", "2-step", "two-step", "two-factor", "2fa", "otp", "magic link", "secure link"]
if not any(k in low for k in keys):
    sys.exit(0)
code = ""
m = re.search(r"(?:code|passcode|otp)[^A-Za-z0-9]{0,40}([A-Z0-9]{4,8}|\d{3}[- ]\d{3})\b", t, re.I)
if m and re.search(r"\d", m.group(1)):
    code = m.group(1)
else:
    m = re.search(r"(?<![\d$.,])(\d{6})(?![\d,])", t)
    if m: code = m.group(1)
print("VERIFY\t" + code)
PY
