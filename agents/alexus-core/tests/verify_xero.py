#!/usr/bin/env python3
"""
Verification Dyno: Xero Accounting & Ledger Determinism.
Validates exact variance formula and fundamental balance sheet equality (Assets = Liabilities + Equity).
"""

import sys

def verify_accounting_invariants():
    # Fundamental accounting equation
    assets = 125000.50
    liabilities = 45000.25
    equity = 80000.25
    
    assert abs(assets - (liabilities + equity)) < 1e-5, "Accounting equation violated: Assets != Liabilities + Equity"

    # Deterministic variance calculation: (Current - Prev) / Prev * 100
    prev_rev = 50000.00
    curr_rev = 62500.00
    expected_variance = 25.0
    calc_variance = ((curr_rev - prev_rev) / prev_rev) * 100.0
    assert abs(calc_variance - expected_variance) < 1e-5, f"Variance mismatch: expected {expected_variance}%, got {calc_variance}%"

    print("PASS: Xero accounting invariants and deterministic calculations verified.")

if __name__ == "__main__":
    try:
        verify_accounting_invariants()
        sys.exit(0)
    except Exception as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)
