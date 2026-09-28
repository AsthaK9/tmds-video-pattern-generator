#!/usr/bin/env python3
"""
frame_to_png.py

Independent golden reference model and verification script for the TMDS Video Pattern Generator.
Tasks:
  1. Implements vectorized NumPy golden models for patterns 0..3:
       - Pattern 0: Standard 8 Color Bars
       - Pattern 1: Horizontal Gradient ramp
       - Pattern 2: Checkerboard
       - Pattern 3: Configurable Solid RGB (0x00E5FF)
  2. Reads simulation-generated ASCII PPM frames from out/frame_sel<N>.ppm.
  3. Compares decoded frames against NumPy golden model (pixel-for-pixel exact match).
  4. Saves PNG images (out/frame_sel<N>.png) and generates a 2x2 montage (out/montage.png).
  5. Returns exit code 0 on 100% match, non-zero on failure.
"""

import os
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

H_ACTIVE = 64
V_ACTIVE = 48
SQUARE_SIZE = 8
OUT_DIR = "out"

def generate_golden_pattern(pat_num, h=H_ACTIVE, v=V_ACTIVE, sq=SQUARE_SIZE):
    """Generates vectorized golden RGB image array of shape (v, h, 3), dtype=uint8."""
    xs = np.arange(h, dtype=np.int32)
    ys = np.arange(v, dtype=np.int32)
    X, Y = np.meshgrid(xs, ys)

    if pat_num == 0:
        # 8 Color Bars
        bar_w = h // 8
        bar_idx = np.clip(X // bar_w, 0, 7)
        palette = np.array([
            [255, 255, 255], # White
            [255, 255,   0], # Yellow
            [  0, 255, 255], # Cyan
            [  0, 255,   0], # Green
            [255,   0, 255], # Magenta
            [255,   0,   0], # Red
            [  0,   0, 255], # Blue
            [  0,   0,   0]  # Black
        ], dtype=np.uint8)
        img = palette[bar_idx]
        return img

    elif pat_num == 1:
        # Horizontal Gradient
        grad = ((X * 255) // (h - 1)).astype(np.uint8)
        img = np.stack([grad, grad, grad], axis=-1)
        return img

    elif pat_num == 2:
        # Checkerboard
        check = (((X // sq) ^ (Y // sq)) & 1).astype(np.uint8) * 255
        img = np.stack([check, check, check], axis=-1)
        return img

    elif pat_num == 3:
        # Solid Color (Cyan/Aqua: 0x00E5FF -> R=0, G=229, B=255)
        solid = np.zeros((v, h, 3), dtype=np.uint8)
        solid[:, :, 0] = 0x00
        solid[:, :, 1] = 0xE5
        solid[:, :, 2] = 0xFF
        return solid

    else:
        raise ValueError(f"Unknown pattern index {pat_num}")

def read_ppm(ppm_path):
    """Parses standard ASCII P3 PPM file into NumPy array (H, W, 3)."""
    with open(ppm_path, "r") as f:
        tokens = f.read().split()

    if not tokens or tokens[0] != "P3":
        raise ValueError(f"Invalid PPM header in {ppm_path}")

    width = int(tokens[1])
    height = int(tokens[2])
    max_val = int(tokens[3])

    pixel_data = [int(v) for v in tokens[4:]]
    arr = np.array(pixel_data, dtype=np.uint8).reshape((height, width, 3))
    return arr

def main():
    print("=" * 60)
    print("TMDS Video Pattern Golden Model & Image Verification")
    print("=" * 60)

    total_mismatches = 0
    png_images = []
    pattern_names = [
        "Color Bars (Pat 0)",
        "Horizontal Gradient (Pat 1)",
        "Checkerboard (Pat 2)",
        "Solid Color (Pat 3)"
    ]

    for p in range(4):
        ppm_file = os.path.join(OUT_DIR, f"frame_sel{p}.ppm")
        png_file = os.path.join(OUT_DIR, f"frame_sel{p}.png")

        if not os.path.exists(ppm_file):
            print(f"[FAIL] Missing simulation PPM file: {ppm_file}")
            sys.exit(1)

        actual_img = read_ppm(ppm_file)
        golden_img = generate_golden_pattern(p)

        # Check shape
        if actual_img.shape != golden_img.shape:
            print(f"[FAIL] Shape mismatch for pattern {p}: actual {actual_img.shape} vs golden {golden_img.shape}")
            sys.exit(1)

        # Compare pixel by pixel
        diff = np.any(actual_img != golden_img, axis=-1)
        mismatch_count = int(np.sum(diff))
        total_mismatches += mismatch_count

        if mismatch_count == 0:
            print(f"[PASS] {pattern_names[p]}: Exact golden match (0 mismatches across {H_ACTIVE*V_ACTIVE} pixels)")
        else:
            print(f"[FAIL] {pattern_names[p]}: {mismatch_count} pixel mismatches detected!")

        # Save individual PNG
        pil_img = Image.fromarray(actual_img)
        pil_img.save(png_file)
        png_images.append(pil_img)

    # Generate 2x2 Montage with 4x upscale for crisp visibility
    scale = 4
    scaled_w = H_ACTIVE * scale
    scaled_h = V_ACTIVE * scale
    header_h = 24
    cell_w = scaled_w
    cell_h = scaled_h + header_h

    montage_w = cell_w * 2 + 16
    montage_h = cell_h * 2 + 16
    montage = Image.new("RGB", (montage_w, montage_h), color=(30, 30, 30))
    draw = ImageDraw.Draw(montage)

    coords = [(8, 8), (cell_w + 12, 8), (8, cell_h + 12), (cell_w + 12, cell_h + 12)]

    for idx, (img, name) in enumerate(zip(png_images, pattern_names)):
        cx, cy = coords[idx]
        draw.text((cx + 4, cy + 4), name, fill=(220, 220, 220))
        resample_mode = Image.Resampling.NEAREST if hasattr(Image, 'Resampling') else Image.NEAREST
        scaled_img = img.resize((scaled_w, scaled_h), resample_mode)
        montage.paste(scaled_img, (cx, cy + header_h))

    montage_path = os.path.join(OUT_DIR, "montage.png")
    montage.save(montage_path)
    print("-" * 60)
    print(f"[INFO] 2x2 montage saved successfully to {montage_path}")
    print(f"[INFO] Summary: Total pixel mismatches across all patterns = {total_mismatches}")
    print("=" * 60)

    if total_mismatches == 0:
        print("[ALL GOLDEN CHECKS PASSED]")
        sys.exit(0)
    else:
        print("[GOLDEN VERIFICATION FAILED]")
        sys.exit(1)

if __name__ == "__main__":
    main()
