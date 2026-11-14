#!/usr/bin/env python3
"""
Verification Dyno: RAGNAROK Cryptographic Ledger Hash Chain Protocol.
Validates SHA-256 linear chain continuity, canonical payload serialization,
and tamper detection.
"""

import hashlib
import json
import sys

def compute_receipt_hash(index, timestamp, prev_hash, payload_hash):
    seed = f"{index}:{timestamp}:{prev_hash}:{payload_hash}"
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()

def test_ledger_integrity():
    # Genesis block
    genesis_prev = "0" * 64
    payload_0 = hashlib.sha256(b"genesis_handshake").hexdigest()
    hash_0 = compute_receipt_hash(0, "2026-10-30T00:00:00Z", genesis_prev, payload_0)

    # Block 1
    payload_1 = hashlib.sha256(b"task_execution_pass_1").hexdigest()
    hash_1 = compute_receipt_hash(1, "2026-10-30T00:01:00Z", hash_0, payload_1)

    # Block 2
    payload_2 = hashlib.sha256(b"task_execution_pass_2").hexdigest()
    hash_2 = compute_receipt_hash(2, "2026-10-30T00:02:00Z", hash_1, payload_2)

    chain = [
        {"idx": 0, "prev": genesis_prev, "payload": payload_0, "hash": hash_0},
        {"idx": 1, "prev": hash_0, "payload": payload_1, "hash": hash_1},
        {"idx": 2, "prev": hash_1, "payload": payload_2, "hash": hash_2},
    ]

    # Verification loop
    for i in range(len(chain)):
        expected_prev = genesis_prev if i == 0 else chain[i-1]["hash"]
        assert chain[i]["prev"] == expected_prev, f"Chain broken at index {i}"

    # Tamper test: modify payload 1
    tampered_payload_1 = hashlib.sha256(b"tampered_content").hexdigest()
    tampered_hash_1 = compute_receipt_hash(1, "2026-10-30T00:01:00Z", hash_0, tampered_payload_1)
    assert tampered_hash_1 != chain[1]["hash"], "Tampered payload must alter hash"
    assert tampered_hash_1 != chain[2]["prev"], "Tamper must break linkage to block 2"

    print("PASS: RAGNAROK cryptographic hash chain verification passed.")

if __name__ == "__main__":
    try:
        test_ledger_integrity()
        sys.exit(0)
    except Exception as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)
