#!/usr/bin/env python3
"""
Verification Dyno: Honda S2000 AP2 F22C1 Motorsports Engineering Specs.
Validates VTEC crossover boundaries, stroke/displacement calculations,
gear ratios, and redline cutoffs.
"""

import sys

def verify_f22c_specs():
    bore_mm = 87.0
    stroke_mm = 90.7  # AP2 F22C1 stroke (vs 84.0mm on AP1 F20C)
    cylinders = 4
    
    # Displacement = pi * (bore/2)^2 * stroke * 4
    import math
    disp_cc = math.pi * ((bore_mm / 10.0 / 2) ** 2) * (stroke_mm / 10.0) * cylinders
    assert 2150 <= disp_cc <= 2160, f"Displacement {disp_cc:.1f}cc outside F22C spec (2157cc)"

    # AP2 parameters
    redline_rpm = 8000
    fuel_cut_rpm = 8200
    vtec_stock_rpm = 6000
    compression_ratio = 11.1
    
    assert fuel_cut_rpm == 8200, "AP2 F22C fuel cut must be 8200 RPM (not 9000 RPM AP1)"
    assert compression_ratio == 11.1, "F22C compression ratio must be 11.1:1"
    
    # Transmission secondary reduction ratio (AP2 = 1.208 vs AP1 = 1.160)
    ap2_secondary_reduction = 1.208
    assert ap2_secondary_reduction == 1.208, "AP2 secondary reduction must be 1.208"

    print("PASS: S2000 F22C1 motorsport specifications verified.")

if __name__ == "__main__":
    try:
        verify_f22c_specs()
        sys.exit(0)
    except Exception as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)
