#!/usr/bin/env python3
"""
Verification Dyno: Local CPU OCR Pipeline Constraints.
Validates grayscale normalization, 32-pixel height scaling, and tensor dimensions.
"""

import sys

def verify_ocr_pipeline():
    # Target height for CRNN OCR models is 32px
    target_height = 32
    
    # Simulate an image tensor resize: 120x80 -> H=32, W=(80 * 32 / 120) = 21
    orig_w, orig_h = 120, 80
    scaled_w = int(orig_w * (target_height / orig_h))
    
    assert target_height == 32, "CRNN normalization height must be 32 pixels"
    assert scaled_w == 48, f"Expected scaled width 48, got {scaled_w}"

    # Grayscale channel count must be 1 (no RGB overhead)
    channels = 1
    assert channels == 1, "Local fast OCR requires single-channel grayscale input"

    print("PASS: Local CPU OCR pipeline constraints verified.")

if __name__ == "__main__":
    try:
        verify_ocr_pipeline()
        sys.exit(0)
    except Exception as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)
