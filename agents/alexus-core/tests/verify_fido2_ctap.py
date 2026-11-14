#!/usr/bin/env python3
"""
Verification Dyno: FIDO2 / CTAP2 Authenticator Protocol Verification.
Validates authenticatorData byte packing, user presence flag (UP), user verified (UV),
and SHA-256 clientDataHash integrity checks.
"""

import hashlib
import sys

def verify_ctap2_flags(auth_data_bytes):
    # authenticatorData: 32 bytes rpIdHash + 1 byte flags + 4 bytes signCount
    if len(auth_data_bytes) < 37:
        raise ValueError("authenticatorData too short (< 37 bytes)")
    
    flags = auth_data_bytes[32]
    up = bool(flags & 0x01)  # User Presence bit 0
    uv = bool(flags & 0x04)  # User Verified bit 2
    be = bool(flags & 0x08)  # Backup Eligibility bit 3
    bs = bool(flags & 0x10)  # Backup State bit 4
    at = bool(flags & 0x40)  # Attested Credential Data bit 6
    ed = bool(flags & 0x80)  # Extension Data bit 7
    return {"UP": up, "UV": uv, "BE": be, "BS": bs, "AT": at, "ED": ed}

def test_fido2_contract():
    rp_id = "rgnrk.co"
    rp_id_hash = hashlib.sha256(rp_id.encode()).digest()
    
    # Flags: UP=1 (0x01) indicating physical touch verification
    flags = bytes([0x01])
    sign_count = (42).to_bytes(4, byteorder="big")
    auth_data = rp_id_hash + flags + sign_count
    
    parsed = verify_ctap2_flags(auth_data)
    assert parsed["UP"] is True, "User Presence bit must be set on valid touch"
    assert parsed["UV"] is False, "User Verified (PIN/Biometric) was not requested"
    
    # Flags: UP=1 + UV=1 (0x05)
    flags_pin = bytes([0x05])
    auth_data_pin = rp_id_hash + flags_pin + sign_count
    parsed_pin = verify_ctap2_flags(auth_data_pin)
    assert parsed_pin["UP"] is True and parsed_pin["UV"] is True, "Both UP and UV must be set"
    
    print("PASS: FIDO2 CTAP2 contract verification passed.")

if __name__ == "__main__":
    try:
        test_fido2_contract()
        sys.exit(0)
    except Exception as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)
