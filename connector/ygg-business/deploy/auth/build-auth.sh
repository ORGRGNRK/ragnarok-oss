#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if command -v swiftc >/dev/null 2>&1; then
  swiftc auth_gate.swift -o auth-gate
  chmod +x auth-gate
  echo "✅ Compiled Apple Secure Enclave & Touch ID gatekeeper binary: deploy/auth/auth-gate"
else
  echo "⚠️ swiftc not found; skipping Apple Touch ID native binary compilation."
fi
