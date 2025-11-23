#!/usr/bin/env python3
"""
Diagnostics utility: render ROI color averages for the 4 orientation hypotheses.

Given a JPEG + ROI CSV, this script crops the ROI using rotations of
0/90/180/270 degrees relative to the upright JPEG, computes the mean sRGB
values, and renders a visualization so we can compare which rotation matches
the real patch.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
from PIL import Image, ImageDraw, ImageFont

THIS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = THIS_DIR.parent.parent
if str(PROJECT_ROOT) not in sys.path:
  sys.path.insert(0, str(PROJECT_ROOT))

from color_design_tool.tool.render_jpeg_roi import (  # type: ignore
    get_orientation,
    map_rect,
    rotate_image,
)


def parse_args() -> argparse.Namespace:
  parser = argparse.ArgumentParser(
      description="Visualize ROI colors for 4 orientation hypotheses.")
  parser.add_argument("--jpeg", required=True, type=Path,
                      help="Path to the captured JPEG.")
  parser.add_argument("--roi-csv", required=True, type=Path,
                      help="ROI CSV exported by the app.")
  parser.add_argument("--roi-index", type=int, default=0,
                      help="Row index to inspect (default 0).")
  parser.add_argument("--out", type=Path, default=None,
                      help="Optional output JPEG path.")
  return parser.parse_args()


def load_roi_row(csv_path: Path, index: int) -> Dict[str, str]:
  with csv_path.open(newline="", encoding="utf-8") as fh:
    rows = list(csv.DictReader(fh))
  if not rows:
    raise SystemExit("ROI CSV is empty.")
  if index < 0 or index >= len(rows):
    raise SystemExit(f"ROI index {index} out of range (0..{len(rows)-1}).")
  return rows[index]


def srgb_mean(image: Image.Image, bbox: Tuple[int, int, int, int]) -> np.ndarray:
  roi = image.crop(bbox)
  if roi.width <= 0 or roi.height <= 0:
    return np.zeros(3)
  srgb = np.asarray(roi).astype(np.float32) / 255.0
  return srgb.mean(axis=(0, 1))


def build_visualization(jpeg_path: Path, row: Dict[str, str],
                        roi_index: int, out_path: Path) -> None:
  orig_img = Image.open(jpeg_path)
  orientation_tag = get_orientation(orig_img)
  upright = rotate_image(orig_img, orientation_tag).convert("RGB")
  width, height = upright.size

  normalized = {
      "left": float(row["roi_left"]),
      "top": float(row["roi_top"]),
      "right": float(row["roi_right"]),
      "bottom": float(row["roi_bottom"]),
  }

  candidates = []
  for angle in (0, 90, 180, 270):
    bbox = map_rect(normalized, angle, width, height)
    mean = srgb_mean(upright, bbox)
    overlay = upright.copy()
    draw = ImageDraw.Draw(overlay)
    draw.rectangle(bbox, outline=(255, 100, 0), width=4)
    candidates.append({
        "angle": angle,
        "bbox": bbox,
        "mean": mean,
        "overlay": overlay,
    })

  font = ImageFont.load_default()

  def line_height() -> int:
    bbox = font.getbbox("Ag")
    return bbox[3] - bbox[1] + 2

  lh = line_height()
  preview_width = 340
  patch_size = (160, 120)
  padding = 30
  row_gap = 20
  text_gap = 6
  preview_gap = 20
  header_lines = [
      f"JPEG: {jpeg_path}",
      f"ROI CSV: {row['timestamp']} (row {roi_index})",
      f"JPEG orientation tag: {orientation_tag}, size: {width}x{height}px",
      f"Normalized ROI: left={normalized['left']:.4f}, top={normalized['top']:.4f}, "
      f"right={normalized['right']:.4f}, bottom={normalized['bottom']:.4f}",
  ]
  header_height = len(header_lines) * lh + padding

  canvas_width = padding * 2 + preview_width + preview_gap + patch_size[0]
  row_height = max(preview_width * upright.height // upright.width, patch_size[1]) + 2 * text_gap + lh * 3
  canvas_height = header_height + len(candidates) * row_height + (len(candidates) - 1) * row_gap

  canvas = Image.new("RGB", (canvas_width, canvas_height), (255, 255, 255))
  draw = ImageDraw.Draw(canvas)

  text_y = padding // 2
  for line in header_lines:
    draw.text((padding, text_y), line, fill=(0, 0, 0), font=font)
    text_y += lh

  base_y = header_height
  for idx, candidate in enumerate(candidates):
    overlay = candidate["overlay"]
    scale = min(preview_width / overlay.width, 1.0)
    preview_h = int(overlay.height * scale)
    preview_resized = overlay.resize((int(overlay.width * scale), preview_h),
                                     Image.LANCZOS)
    preview_box = (
        padding,
        base_y,
        padding + preview_resized.width,
        base_y + preview_resized.height,
    )
    canvas.paste(preview_resized, (preview_box[0], preview_box[1]))

    patch = Image.new("RGB", patch_size,
                      tuple(int(round(c * 255)) for c in candidate["mean"]))
    patch_x = padding + preview_width + preview_gap
    patch_y = base_y
    canvas.paste(patch, (patch_x, patch_y))
    draw.rectangle((patch_x, patch_y,
                    patch_x + patch_size[0], patch_y + patch_size[1]),
                   outline=(0, 0, 0), width=2)

    text_lines = [
      f"Angle {candidate['angle']}°",
      f"BBox px: L{candidate['bbox'][0]}-{candidate['bbox'][2]}, "
      f"T{candidate['bbox'][1]}-{candidate['bbox'][3]}",
      f"Avg sRGB: [{candidate['mean'][0]:.4f}, "
      f"{candidate['mean'][1]:.4f}, {candidate['mean'][2]:.4f}]",
    ]
    ty = patch_y + patch_size[1] + text_gap
    for line in text_lines:
      draw.text((patch_x, ty), line, fill=(0, 0, 0), font=font)
      ty += lh

    base_y += row_height + row_gap

  out_path.parent.mkdir(parents=True, exist_ok=True)
  canvas.save(out_path, quality=95)
  print("Saved orientation diagnostics to", out_path)
  for c in candidates:
    print(f"Angle {c['angle']:3d}° -> mean sRGB {c['mean']}, bbox {c['bbox']}")


def main() -> None:
  args = parse_args()
  row = load_roi_row(args.roi_csv, args.roi_index)
  out_path = args.out or args.roi_csv.with_stem(
      args.roi_csv.stem + f"_roi_orientation_{args.roi_index}")
  out_path = out_path.with_suffix(".jpg")
  build_visualization(args.jpeg, row, args.roi_index, out_path)


if __name__ == "__main__":
  main()
