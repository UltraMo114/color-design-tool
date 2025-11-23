#!/usr/bin/env python3
"""
Render a comparison chart for the ROI color pipeline with ROI overlay preview.

The left column visualizes the raw pipeline (sensor average -> white balance
-> CCM/XYZ), while the right column shows the JPEG pipeline
(sRGB average -> degamma -> sRGB->XYZ). Each cell displays a color patch along
with the corresponding numeric values. The top preview shows the JPEG with
the selected ROI rectangle.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path
from typing import Dict, Iterable, Tuple

import numpy as np
# Ensure project root on sys.path for sibling imports when executed as a script.
THIS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = THIS_DIR.parent.parent
if str(PROJECT_ROOT) not in sys.path:
  sys.path.insert(0, str(PROJECT_ROOT))

from PIL import Image, ImageDraw, ImageFont

from color_design_tool.tool.render_jpeg_roi import (  # type: ignore
    get_orientation,
    map_rect,
    rotate_image,
)


SRGB_TO_XYZ = np.array([
    [0.4124564, 0.3575761, 0.1804375],
    [0.2126729, 0.7151522, 0.0721750],
    [0.0193339, 0.1191920, 0.9503041],
], dtype=np.float64)
XYZ_TO_SRGB = np.linalg.inv(SRGB_TO_XYZ)


def parse_args() -> argparse.Namespace:
  parser = argparse.ArgumentParser(
      description="Visualize raw vs JPEG ROI color pipeline.")
  parser.add_argument("--jpeg", required=True, type=Path,
                      help="Path to the corresponding JPEG for ROI overlay.")
  parser.add_argument("--roi-csv", required=True, type=Path,
                      help="ROI dump CSV exported by the app.")
  parser.add_argument("--roi-index", type=int, default=0,
                      help="ROI index (row) to visualize, default 0.")
  parser.add_argument("--roi-rotation", type=int, default=0,
                      choices=(0, 90, 180, 270),
                      help="Extra rotation (degrees) applied to ROI "
                      "coordinates relative to the upright JPEG. Default 0.")
  parser.add_argument("--jpeg-source", choices=("csv", "image"), default="image",
                      help="Where to read JPEG pipeline averages from. "
                      "'image' recomputes using the JPEG pixels (default).")
  parser.add_argument("--out", type=Path, default=None,
                      help="Optional output JPEG for the visualization.")
  return parser.parse_args()


def load_roi_row(csv_path: Path, index: int) -> Dict[str, str]:
  with csv_path.open(newline="", encoding="utf-8") as fh:
    rows = list(csv.DictReader(fh))
  if not rows:
    raise SystemExit("ROI CSV is empty.")
  if index < 0 or index >= len(rows):
    raise SystemExit(f"ROI index {index} out of range (0..{len(rows) - 1}).")
  return rows[index]


def srgb_to_linear(value: np.ndarray) -> np.ndarray:
  threshold = 0.04045
  return np.where(value <= threshold, value / 12.92,
                  ((value + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(value: np.ndarray) -> np.ndarray:
  return np.where(value <= 0.0031308, value * 12.92,
                  1.055 * (value ** (1 / 2.4)) - 0.055)


def xyz_to_linear_rgb(xyz: np.ndarray) -> np.ndarray:
  return XYZ_TO_SRGB @ xyz


def clamp01(values: np.ndarray) -> np.ndarray:
  return np.clip(values, 0.0, 1.0)


def linear_rgb_to_uint8(linear_rgb: np.ndarray) -> Tuple[int, int, int]:
  srgb = clamp01(linear_to_srgb(clamp01(linear_rgb)))
  return tuple(int(round(c * 255)) for c in srgb)


def fmt_triplet(values: Iterable[float]) -> str:
  return "[" + ", ".join(f"{v:.4f}" for v in values) + "]"


def create_roi_overlay(jpeg_path: Path, normalized: Dict[str, float],
                       roi_rotation: int) -> tuple[Image.Image,
                                                   tuple[int, int, int, int],
                                                   int, tuple[int, int]]:
  orig_img = Image.open(jpeg_path)
  orientation_tag = get_orientation(orig_img)
  upright = rotate_image(orig_img, orientation_tag).convert("RGB")
  width, height = upright.size
  bbox = map_rect(normalized, roi_rotation % 360, width, height)
  overlay = upright.copy()
  outline_width = max(4, min(width, height) // 150)
  draw = ImageDraw.Draw(overlay)
  draw.rectangle(bbox, outline=(255, 80, 0), width=outline_width)
  return overlay, bbox, orientation_tag, (width, height)


def srgb_mean(image: Image.Image, bbox: tuple[int, int, int, int]) -> np.ndarray:
  roi = image.crop(bbox)
  if roi.width <= 0 or roi.height <= 0:
    return np.zeros(3)
  srgb = np.asarray(roi).astype(np.float32) / 255.0
  return srgb.mean(axis=(0, 1))


def build_visualization(row: Dict[str, str], out_path: Path, jpeg_path: Path,
                        roi_rotation: int, jpeg_source: str) -> None:
  normalized = {
      "left": float(row["roi_left"]),
      "top": float(row["roi_top"]),
      "right": float(row["roi_right"]),
      "bottom": float(row["roi_bottom"]),
  }
  roi_overlay, bbox, orientation_tag, img_size = create_roi_overlay(
      jpeg_path, normalized, roi_rotation)

  raw_rgb = np.array([
      float(row["raw_r"]),
      float(row["raw_g"]),
      float(row["raw_b"]),
  ])
  wb_linear_rgb = np.array([
      float(row["linear_r"]),
      float(row["linear_g"]),
      float(row["linear_b"]),
  ])
  raw_xyz = np.array([
      float(row["xyz_x"]),
      float(row["xyz_y"]),
      float(row["xyz_z"]),
  ])
  raw_ccm_linear = clamp01(xyz_to_linear_rgb(raw_xyz))

  if jpeg_source == "image":
    jpeg_srgb = srgb_mean(roi_overlay, bbox)
    jpeg_source_label = "JPEG avg RGB (from image)"
  else:
    jpeg_srgb = np.array([
        float(row["jpeg_srgb_r"]),
        float(row["jpeg_srgb_g"]),
        float(row["jpeg_srgb_b"]),
    ])
    jpeg_source_label = "JPEG avg RGB (CSV)"
  jpeg_linear = clamp01(srgb_to_linear(jpeg_srgb))
  jpeg_xyz = SRGB_TO_XYZ @ jpeg_linear
  jpeg_xyz_linear = clamp01(xyz_to_linear_rgb(jpeg_xyz))

  stage_rows = [
      {
          "label": "Stage 1",
          "raw": {
              "title": "Raw avg RGB (sensor)",
              "linear_rgb": clamp01(raw_rgb),
              "lines": [
                  f"Raw RGB avg: {fmt_triplet(raw_rgb)}",
              ],
          },
          "jpeg": {
              "title": jpeg_source_label,
              "linear_rgb": jpeg_linear,
              "lines": [
                  f"JPEG sRGB avg: {fmt_triplet(jpeg_srgb)}",
              ],
          },
      },
      {
          "label": "Stage 2",
          "raw": {
              "title": "After white balance",
              "linear_rgb": clamp01(wb_linear_rgb),
              "lines": [
                  f"WB linear RGB: {fmt_triplet(wb_linear_rgb)}",
                  f"WB gains: [{row['wb_r_gain']}, "
                  f"{row['wb_g_gain']}, {row['wb_b_gain']}]",
              ],
          },
          "jpeg": {
              "title": "Degamma (linear)",
              "linear_rgb": jpeg_linear,
              "lines": [
                  f"Linear RGB: {fmt_triplet(jpeg_linear)}",
              ],
          },
      },
      {
          "label": "Stage 3",
          "raw": {
              "title": "CCM -> XYZ -> sRGB",
              "linear_rgb": raw_ccm_linear,
              "lines": [
                  f"XYZ (raw path): {fmt_triplet(raw_xyz)}",
                  f"Linear sRGB: {fmt_triplet(raw_ccm_linear)}",
              ],
          },
          "jpeg": {
              "title": "sRGB -> XYZ",
              "linear_rgb": jpeg_xyz_linear,
              "lines": [
                  f"XYZ (JPEG path): {fmt_triplet(jpeg_xyz)}",
                  f"Linear sRGB (back): {fmt_triplet(jpeg_xyz_linear)}",
              ],
          },
      },
  ]

  patch_w, patch_h = 240, 140
  padding = 40
  col_gap = 80
  row_gap = 80
  label_w = 90
  header_h = 40
  preview_gap = 40
  preview_text_spacing = 6

  preview_text_lines = [
      f"ROI preview (rotation {roi_rotation}° relative to upright JPEG)",
      f"JPEG orientation tag: {orientation_tag}, size: {img_size[0]}x{img_size[1]} px",
      f"ROI bbox px: L{bbox[0]}-{bbox[2]}, T{bbox[1]}-{bbox[3]} "
      f"({bbox[2] - bbox[0]}x{bbox[3] - bbox[1]})",
  ]

  font = ImageFont.load_default()

  def line_height() -> int:
    bbox = font.getbbox("Ag")
    return bbox[3] - bbox[1] + 2

  lh = line_height()

  width = padding * 2 + label_w + patch_w * 2 + col_gap
  max_preview_w = width - padding * 2
  max_preview_h = 380
  scale = min(max_preview_w / roi_overlay.width,
              max_preview_h / roi_overlay.height, 1.0)
  if scale < 1.0:
    preview_image = roi_overlay.resize(
        (int(roi_overlay.width * scale), int(roi_overlay.height * scale)),
        Image.LANCZOS)
  else:
    preview_image = roi_overlay
  preview_height = preview_image.height
  preview_text_height = preview_text_spacing + len(preview_text_lines) * lh

  stage_area_height = header_h + len(stage_rows) * patch_h \
      + (len(stage_rows) - 1) * row_gap

  raw_final_xyz = raw_xyz
  jpeg_final_xyz = jpeg_xyz
  delta_xyz = raw_final_xyz - jpeg_final_xyz
  raw_final_linear = raw_ccm_linear
  delta_linear_rgb = raw_final_linear - jpeg_linear
  summary_lines = [
      f"Final XYZ (raw path): {fmt_triplet(raw_final_xyz)}",
      f"Final XYZ (JPEG path): {fmt_triplet(jpeg_final_xyz)}",
      f"Delta XYZ (raw - JPEG): {fmt_triplet(delta_xyz)}",
      f"Delta linear sRGB (raw - JPEG): {fmt_triplet(delta_linear_rgb)}",
  ]
  summary_height = len(summary_lines) * lh + 20

  height = padding + preview_height + preview_text_height + preview_gap \
      + stage_area_height + summary_height + padding

  canvas = Image.new("RGB", (width, height), (255, 255, 255))
  draw = ImageDraw.Draw(canvas)

  preview_x = padding + (max_preview_w - preview_image.width) // 2
  preview_y = padding
  canvas.paste(preview_image, (preview_x, preview_y))
  text_y = preview_y + preview_height + preview_text_spacing
  for line in preview_text_lines:
    draw.text((padding, text_y), line, fill=(0, 0, 0), font=font)
    text_y += lh

  header_y = preview_y + preview_height + preview_text_height + preview_gap
  raw_col_x = padding + label_w
  jpeg_col_x = raw_col_x + patch_w + col_gap

  draw.text((raw_col_x, header_y), "RAW PIPELINE",
            fill=(0, 0, 0), font=font)
  draw.text((jpeg_col_x, header_y), "JPEG PIPELINE",
            fill=(0, 0, 0), font=font)

  base_y = header_y + header_h
  last_stage_bottom = base_y

  for idx, stage in enumerate(stage_rows):
    y = base_y + idx * (patch_h + row_gap)
    label_text = stage["label"]
    draw.text((padding, y + patch_h // 2 - lh), label_text,
              fill=(0, 0, 0), font=font)

    for column_x, key in ((raw_col_x, "raw"), (jpeg_col_x, "jpeg")):
      info = stage[key]
      color = linear_rgb_to_uint8(info["linear_rgb"])
      patch_box = (column_x, y, column_x + patch_w, y + patch_h)
      draw.rectangle(patch_box, fill=color, outline=(0, 0, 0), width=2)

      text_y = y + patch_h + 4
      draw.text((column_x, text_y), info["title"], fill=(0, 0, 0), font=font)
      text_y += lh
      for line in info["lines"]:
        draw.text((column_x, text_y), line, fill=(0, 0, 0), font=font)
        text_y += lh

    last_stage_bottom = y + patch_h

  summary_y = last_stage_bottom + 30
  summary_x = padding
  for line in summary_lines:
    draw.text((summary_x, summary_y), line, fill=(0, 0, 0), font=font)
    summary_y += lh

  out_path.parent.mkdir(parents=True, exist_ok=True)
  canvas.save(out_path, quality=95)
  print(f"Saved visualization to {out_path}")


def main() -> None:
  args = parse_args()
  row = load_roi_row(args.roi_csv, args.roi_index)
  out_path = args.out or args.roi_csv.with_stem(
      args.roi_csv.stem + "_color_pipeline")
  out_path = out_path.with_suffix(".jpg")
  build_visualization(row, out_path, args.jpeg, args.roi_rotation,
                      args.jpeg_source)


if __name__ == "__main__":
  main()
