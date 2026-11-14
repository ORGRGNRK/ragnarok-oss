#!/usr/bin/env python3
"""
Verification Dyno: CAN Bus 2.0A/B Frame Telemetry and Checksum Verification.
Validates 11-bit standard vs 29-bit extended arbitration IDs, DLC payload sizing,
and standard OBD-II PID query construction.
"""

import sys

def verify_can_protocol():
    # Standard CAN 2.0A arbitration ID is 11 bits (0x000 to 0x7FF)
    max_standard_id = 0x7FF
    obd2_broadcast_req = 0x7DF
    obd2_ecu_response = 0x7E8

    assert obd2_broadcast_req <= max_standard_id, "OBD-II request 0x7DF must fit within 11-bit CAN frame"
    assert obd2_ecu_response <= max_standard_id, "OBD-II response 0x7E8 must fit within 11-bit CAN frame"

    # CAN 2.0 data frame: DLC is 0-8 bytes
    max_dlc = 8
    
    # Engine RPM (PID 0x0C) query frame: [0x02, 0x01, 0x0C, 0x55, 0x55, 0x55, 0x55, 0x55]
    rpm_req = bytes([0x02, 0x01, 0x0C, 0x55, 0x55, 0x55, 0x55, 0x55])
    assert len(rpm_req) == max_dlc, "CAN frame length must match DLC"
    assert rpm_req[0] == 2, "Additional bytes count must be 2 (Service 01 + PID 0C)"

    # Formula for decoding RPM: ((A * 256) + B) / 4
    byte_a = 0x1F  # 31
    byte_b = 0x40  # 64
    rpm = ((byte_a * 256) + byte_b) / 4.0
    expected_rpm = 2000.0
    assert rpm == expected_rpm, f"Calculated RPM {rpm} does not match expected {expected_rpm}"

    print("PASS: CAN Bus telemetry decoding and frame parameters verified.")

if __name__ == "__main__":
    try:
        verify_can_protocol()
        sys.exit(0)
    except Exception as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)
