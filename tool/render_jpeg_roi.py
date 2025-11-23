#!/usr/bin/env python3
"""
Render JPEG ROI visualization and average color statistics.

Usage:
  python render_jpeg_roi.py --jpeg <path/to/jpeg> --roi-csv <roi_dump.csv> \
         [--roi-index 0] [--out out.jpg]
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import Dict

import numpy as np
from PIL import ExifTags, Image, ImageDraw, ImageFont


def parse_args() -> argparse.Namespace:
  parser = argparse.ArgumentParser(description="Visualize ROI on captured JPEG.")
  parser.add_argument("--jpeg", required=True, type=Path, help="Path to JPEG file.")
  parser.add_argument("--roi-csv", required=True, type=Path,
                      help="ROI dump CSV exported by the app.")
  parser.add_argument("--roi-index", type=int, default=0,
                      help="ROI index (row) to visualize, default 0.")
  parser.add_argument("--out", type=Path, default=None,
                      help="Optional output path for visualization JPEG.")
  return parser.parse_args()


def load_roi_row(csv_path: Path, index: int) -> Dict[str, str]:
  with csv_path.open(newline="", encoding="utf-8") as fh:
    reader = list(csv.DictReader(fh))
  if not reader:
    raise SystemExit("ROI CSV is empty.")
  if index < 0 or index >= len(reader):
    raise SystemExit(f"ROI index {index} out of range (0..{len(reader)-1}).")
  return reader[index]


def get_orientation(img: Image.Image) -> int:
  if hasattr(img, "_getexif"):
    exif = img._getexif()  # type: ignore[attr-defined]
    if isinstance(exif, dict):
      return exif.get(274, 0)  # 274 = Orientation
  return 0


def rotate_image(img: Image.Image, orientation: int) -> Image.Image:
  if orientation == 3:
    return img.rotate(180, expand=True)
  if orientation == 6:
    return img.rotate(270, expand=True)
  if orientation == 8:
    return img.rotate(90, expand=True)
  return img


def rotate_point(point: tuple[float, float], orientation: int) -> tuple[float, float]:
  x, y = point
  orientation = (orientation % 360 + 360) % 360
  if orientation == 90:
    return (1.0 - y, x)
  if orientation == 180:
    return (1.0 - x, 1.0 - y)
  if orientation == 270:
    return (y, 1.0 - x)
  return (x, y)


def rotate_rect(normalized: Dict[str, float], orientation: int) -> Dict[str, float]:
  points = [
      (normalized["left"], normalized["top"]),
      (normalized["right"], normalized["top"]),
      (normalized["left"], normalized["bottom"]),
      (normalized["right"], normalized["bottom"]),
  ]
  rotated = [rotate_point(p, orientation) for p in points]
  min_x = min(p[0] for p in rotated)
  max_x = max(p[0] for p in rotated)
  min_y = min(p[1] for p in rotated)
  max_y = max(p[1] for p in rotated)
  return {
      "left": min(max(min_x, 0.0), 1.0),
      "right": min(max(max_x, 0.0), 1.0),
      "top": min(max(min_y, 0.0), 1.0),
      "bottom": min(max(max_y, 0.0), 1.0),
  }


def map_rect(rotated: Dict[str, float], width: int, height: int) -> tuple[int, int, int, int]:
  left = int(rotated["left"] * width)
  right = int(rotated["right"] * width)
  top = int(rotated["top"] * height)
  bottom = int(rotated["bottom"] * height)
  left = max(0, min(left, width))
  right = max(left + 1, min(right, width))
  top = max(0, min(top, height))
  bottom = max(top + 1, min(bottom, height))
  return left, top, right, bottom


def srgb_to_linear(value: np.ndarray) -> np.ndarray:
  threshold = 0.04045
  return np.where(value <= threshold, value / 12.92,
                  ((value + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(value: np.ndarray) -> np.ndarray:
  return np.where(value <= 0.0031308, value * 12.92,
                  1.055 * (value ** (1 / 2.4)) - 0.055)


def main() -> None:
  args = parse_args()
  row = load_roi_row(args.roi_csv, args.roi_index)
  normalized = {
      "left": float(row["roi_left"]),
      "top": float(row["roi_top"]),
      "right": float(row["roi_right"]),
      "bottom": float(row["roi_bottom"]),
  }

  orig_img = Image.open(args.jpeg)
  orientation_tag = get_orientation(orig_img)
  orig_img = orig_img.convert("RGB")
  orientation_deg = {
      3: 180,
      6: 270,
      8: 90,
  }.get(orientation_tag, 0)
  width, height = orig_img.size

  rotated = rotate_rect(normalized, orientation_deg)
  left, top, right, bottom = map_rect(rotated, width, height)
  bbox = (left, top, right, bottom)

  roi = orig_img.crop(bbox)
  srgb = np.asarray(roi).astype(np.float32) / 255.0
  avg_srgb_gamma = srgb.mean(axis=(0, 1))
  avg_linear = srgb_to_linear(avg_srgb_gamma)
  display_rgb = tuple(np.clip((avg_srgb_gamma * 255).round().astype(int), 0, 255))

  overlay = orig_img.copy()
  draw = ImageDraw.Draw(overlay)
  draw.rectangle(bbox, outline=(255, 165, 0), width=6)

  padding = 20
  patch_w, patch_h = 320, 200
  out_width = overlay.width + patch_w + padding * 2
  out_height = max(overlay.height, patch_h + padding * 2)
  canvas = Image.new("RGB", (out_width, out_height), (255, 255, 255))
  canvas.paste(overlay, (padding, padding))
  patch_x = overlay.width + padding * 2
  patch_y = padding
  patch = Image.new("RGB", (patch_w, patch_h), display_rgb)
  canvas.paste(patch, (patch_x, patch_y))
  draw_canvas = ImageDraw.Draw(canvas)
  draw_canvas.rectangle((patch_x, patch_y, patch_x + patch_w, patch_y + patch_h),
                        outline=(0, 0, 0), width=2)

  font = ImageFont.load_default()
  lines = [
      f"ROI bbox px: {left}:{right}, {top}:{bottom}",
      f"Avg sRGB gamma (0-255): {(avg_srgb_gamma * 255).round(2)}",
      f"Avg linear RGB: {avg_linear}",
  ]
  text_y = patch_y + patch_h + 8
  for line in lines:
    draw_canvas.text((patch_x, text_y), line, fill=(0, 0, 0), font=font)
    text_y += font.getbbox(line)[3] - font.getbbox(line)[1] + 4

  out_path = args.out or args.jpeg.with_stem(args.jpeg.stem + "_roi_vis")
  out_path = out_path.with_suffix(".jpg")
  out_path.parent.mkdir(parents=True, exist_ok=True)
  canvas.save(out_path, quality=95)

  print(f"Saved visualization to {out_path}")
  print("Average sRGB gamma (0-255):", (avg_srgb_gamma * 255).round(2))
  print("Average linear RGB:", avg_linear)


if __name__ == "__main__":
  main()
