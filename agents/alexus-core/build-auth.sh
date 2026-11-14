#!/usr/bin/env bash
set -e
mkdir -p bin
swiftc -O src/auth_gate.swift -o bin/auth-gate
echo "✅ Compiled native Apple Secure Enclave & Touch ID gatekeeper binary: bin/auth-gate"
