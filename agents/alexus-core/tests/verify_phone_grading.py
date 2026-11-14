#!/usr/bin/env python3
"""
Verification Dyno: Secondary Phone Hardware & Wholesale Grading Rubric.
Tests domain grading logic against Atlas / wholesale resale calibration standards.
"""

import sys

def grade_device(obs):
    """
    Evaluates phone observations against wholesale grading rubric:
    A: Mint / Like New. OEM, no visible wear at arm's length.
    B: OEM, no cracks anywhere, light micro-scratches on close inspection.
    C: Cracked front glass allowed IF display panel (OLED/LCD) is healthy.
    D: Bad screen (touch issues, spots, burn-in, or aftermarket panel) OR heavy frame wear.
    F: Dead / no power, water damage, shattered/unreadable screen.
    """
    categories = {}

    # Category 1: Screen glass & display panel
    if obs.get("no_power") or obs.get("water_damage") or obs.get("screen_shattered_unreadable"):
        categories["screen"] = "F"
    elif obs.get("aftermarket_screen"):
        # Aftermarket screen is automatic bad screen (D) regardless of appearance
        categories["screen"] = "D"
    elif obs.get("touch_issues") or obs.get("burn_in") or obs.get("major_display_spots"):
        categories["screen"] = "D"
    elif obs.get("front_glass_cracked"):
        # Single most common miscalibration: cracked glass + healthy display is a C, NOT an F!
        categories["screen"] = "C"
    elif obs.get("micro_scratches_glass"):
        categories["screen"] = "B"
    else:
        categories["screen"] = "A"

    # Category 2: Housing / Frame
    if obs.get("heavy_bend") or obs.get("housing_missing_parts"):
        categories["housing"] = "F"
    elif obs.get("heavy_frame_gouges") or obs.get("frame_lift_swollen_battery"):
        categories["housing"] = "D"
    elif obs.get("moderate_housing_wear"):
        categories["housing"] = "C"
    elif obs.get("minor_housing_wear"):
        categories["housing"] = "B"
    else:
        categories["housing"] = "A"

    # Category 3: Battery & Functional checklist
    battery_health = obs.get("battery_health", 100)
    battery_grade = "A"
    if battery_health < 80:
        # Battery below 80% shows 'Service' warning and caps grade at C
        battery_grade = "C"
    categories["battery"] = battery_grade

    # Rollup: overall grade is lowest category (with C cosmetic tolerance)
    grade_order = ["F", "D", "C", "B", "A"]
    worst_idx = min(grade_order.index(g) for g in categories.values())
    overall = grade_order[worst_idx]

    return overall, categories

def test_rubric_calibration():
    # Test 1: Pristine OEM device -> Grade A
    g1, _ = grade_device({"battery_health": 95})
    assert g1 == "A", f"Expected A, got {g1}"

    # Test 2: Cracked front glass with healthy display -> MUST be Grade C (NOT F)
    g2, c2 = grade_device({"front_glass_cracked": True, "battery_health": 88})
    assert g2 == "C", f"Calibration error: Cracked glass + healthy display must be C, got {g2}"
    assert c2["screen"] == "C"

    # Test 3: Aftermarket panel -> MUST be Grade D regardless of appearance
    g3, _ = grade_device({"aftermarket_screen": True, "battery_health": 92})
    assert g3 == "D", f"Aftermarket screen must grade D, got {g3}"

    # Test 4: Battery health < 80% -> Caps grade at C
    g4, _ = grade_device({"battery_health": 74})
    assert g4 == "C", f"Battery < 80% must cap grade at C, got {g4}"

    # Test 5: Water damage / dead phone -> Automatic F
    g5, _ = grade_device({"water_damage": True, "battery_health": 100})
    assert g5 == "F", f"Water damage must result in F, got {g5}"

    # Test 6: Burn-in on OLED panel -> Grade D
    g6, _ = grade_device({"burn_in": True, "battery_health": 90})
    assert g6 == "D", f"Burn-in must grade D, got {g6}"

    print("PASS: Phone grading wholesale calibration tests passed (7/7 assertions verified).")

if __name__ == "__main__":
    try:
        test_rubric_calibration()
        sys.exit(0)
    except AssertionError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)
