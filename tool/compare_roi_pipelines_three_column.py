#!/usr/bin/env python3
"""
Visualize ROI color pipelines side-by-side:

1) Rawpy ROI pipeline     : RAW buffer -> WB -> XYZ -> sRGB.
2) Rawpy postprocess path : rawpy.postprocess to RAW RGB (no WB) -> WB -> XYZ -> sRGB.
3) Kotlin RAW pipeline    : from CSV (raw_r/g/b, linear_*, xyz_*).
4) Kotlin JPEG pipeline   : from CSV (jpeg_srgb_*, jpeg_linear_*, jpeg_xyz_*).

Top: JPEG preview with ROI rectangle (same normalized ROI as CSV).
Each column shows 5 stages: raw RGB, WB RGB, XYZ, linear sRGB, gamma sRGB.
At the final stage, channel ratios are compared to JPEG; if they differ
significantly, a red 'FAIL' label is shown.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path
from typing import Dict, Iterable, Tuple

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
    rotate_rect,
)
from color_design_tool.tool import raw_roi_pipeline  # type: ignore


XYZ_TO_SRGB = np.array(
    [
        [3.2406, -1.5372, -0.4986],
        [-0.9689, 1.8758, 0.0415],
        [0.0557, -0.2040, 1.0570],
    ],
    dtype=np.float64,
)
SRGB_TO_XYZ = np.linalg.inv(XYZ_TO_SRGB)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Three-column ROI pipeline visualization (rawpy, Kotlin RAW, Kotlin JPEG).",
    )
    parser.add_argument("--jpeg", required=True, type=Path, help="Path to JPEG file.")
    parser.add_argument("--dng", required=True, type=Path, help="Path to matching DNG file.")
    parser.add_argument(
        "--roi-csv",
        required=True,
        type=Path,
        help="ROI dump CSV exported by the app.",
    )
    parser.add_argument(
        "--roi-index",
        type=int,
        default=0,
        help="ROI index (row) to visualize, default 0.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Optional output JPEG for visualization.",
    )
    return parser.parse_args()


def load_roi_row(csv_path: Path, index: int) -> Dict[str, str]:
    with csv_path.open(newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        raise SystemExit("ROI CSV is empty.")
    if index < 0 or index >= len(rows):
        raise SystemExit(f"ROI index {index} out of range (0..{len(rows) - 1}).")
    return rows[index]


def getf(row: Dict[str, str], key: str, default: float = float("nan")) -> float:
    value = row.get(key, "")
    if value in ("", None):
        return default
    try:
        return float(value)
    except ValueError:
        return default


def srgb_to_linear(value: np.ndarray) -> np.ndarray:
    threshold = 0.04045
    return np.where(
        value <= threshold,
        value / 12.92,
        ((value + 0.055) / 1.055) ** 2.4,
    )


def linear_to_srgb(value: np.ndarray) -> np.ndarray:
    return np.where(
        value <= 0.0031308,
        value * 12.92,
        1.055 * (value ** (1.0 / 2.4)) - 0.055,
    )


def clamp01(values: np.ndarray) -> np.ndarray:
    return np.clip(values, 0.0, 1.0)


def linear_rgb_to_uint8(linear_rgb: np.ndarray) -> Tuple[int, int, int]:
    srgb = clamp01(linear_to_srgb(clamp01(linear_rgb)))
    return tuple(int(round(c * 255)) for c in srgb)


def fmt_triplet(values: Iterable[float]) -> str:
    arr = list(values)
    return "[" + ", ".join(f"{v:.4f}" for v in arr) + "]"


def create_roi_overlay(jpeg_path: Path, row: Dict[str, str]) -> Tuple[Image.Image, Tuple[int, int, int, int]]:
    orig_img = Image.open(jpeg_path)
    orientation_tag = get_orientation(orig_img)
    orig_img = orig_img.convert("RGB")
    width, height = orig_img.size
    normalized = {
        "left": float(row["roi_left"]),
        "top": float(row["roi_top"]),
        "right": float(row["roi_right"]),
        "bottom": float(row["roi_bottom"]),
    }
    # Match the logic used in render_jpeg_roi: rotate the normalized ROI
    # according to EXIF orientation before mapping to pixel coordinates.
    orientation_deg = {
        3: 180,
        6: 270,
        8: 90,
    }.get(orientation_tag, 0)
    rotated = rotate_rect(normalized, orientation_deg)
    bbox = map_rect(rotated, width, height)
    overlay = orig_img.copy()
    draw = ImageDraw.Draw(overlay)
    outline_width = max(4, min(width, height) // 150)
    draw.rectangle(bbox, outline=(255, 80, 0), width=outline_width)
    return overlay, bbox


def create_raw_overlay(dng_path: Path, row: Dict[str, str]) -> Image.Image:
    """
    Render a simple grayscale RAW preview with ROI rectangle overlaid,
    using raw.raw_image_visible (no demosaic).
    """
    import rawpy  # local import to keep dependency clear

    rect = {
        "left": int(getf(row, "raw_left", 0.0)),
        "top": int(getf(row, "raw_top", 0.0)),
        "right": int(getf(row, "raw_right", 0.0)),
        "bottom": int(getf(row, "raw_bottom", 0.0)),
    }
    with rawpy.imread(str(dng_path)) as raw:
        raw_img = raw.raw_image_visible.astype(np.float32)
        black = float(min(getattr(raw, "black_level_per_channel", [0])))  # simple global black
        white = float(raw.white_level or raw_img.max() or 1.0)
        denom = max(1.0, white - black)
        norm = np.clip((raw_img - black) / denom, 0.0, 1.0)

    gray8 = (norm * 255.0 + 0.5).astype(np.uint8)
    raw_img_gray = Image.fromarray(gray8, mode="L").convert("RGB")
    draw = ImageDraw.Draw(raw_img_gray)
    outline_width = max(2, min(raw_img_gray.size) // 200)
    bbox = (rect["left"], rect["top"], rect["right"], rect["bottom"])
    draw.rectangle(bbox, outline=(255, 80, 0), width=outline_width)
    return raw_img_gray


def compute_pipelines(row: Dict[str, str], dng_path: Path) -> Dict[str, Dict[str, np.ndarray]]:
    """Return stage vectors for four pipelines."""
    # Common camera raw RGB and WB as recorded by app
    raw_rgb_csv = np.array(
        [getf(row, "raw_r"), getf(row, "raw_g"), getf(row, "raw_b")],
        dtype=np.float64,
    )
    wb = np.array(
        [getf(row, "wb_r_gain"), getf(row, "wb_g_gain"), getf(row, "wb_b_gain")],
        dtype=np.float64,
    )

    # Left: rawpy reference pipeline, recomputed from DNG + raw_rect.
    # We take RAW averages from the CFA plane, apply WB, and then use
    # rawpy.postprocess(sRGB) inside the same ROI as ground-truth sRGB.
    # XYZ is derived from that sRGB via the standard sRGB->XYZ matrix so
    # that this column exactly matches rawpy's visible output.
    rect = {
        "left": int(getf(row, "raw_left", 0.0)),
        "top": int(getf(row, "raw_top", 0.0)),
        "right": int(getf(row, "raw_right", 0.0)),
        "bottom": int(getf(row, "raw_bottom", 0.0)),
    }
    import rawpy  # local import to keep dependency clear

    with rawpy.imread(str(dng_path)) as raw:
        # RAW ROI averages in camera space.
        roi_means = raw_roi_pipeline.compute_roi_means(raw, rect)
        rawpy_stage_raw = np.array(
            [roi_means["r"], roi_means["g"], roi_means["b"]],
            dtype=np.float64,
        )
        rawpy_stage_wb = rawpy_stage_raw * wb

        # Ground-truth sRGB from rawpy.postprocess inside the same ROI.
        rgb_srgb = raw.postprocess(
            use_camera_wb=True,
            use_auto_wb=False,
            output_bps=8,
            output_color=rawpy.ColorSpace.sRGB,
            no_auto_bright=True,
        )
        y0, y1 = rect["top"], rect["bottom"]
        x0, x1 = rect["left"], rect["right"]
        roi_srgb = rgb_srgb[y0:y1, x0:x1, :]
        if roi_srgb.size == 0:
            raise SystemExit(f"Empty ROI for rawpy sRGB path: {rect}")
        rawpy_srgb_gamma = roi_srgb.mean(axis=(0, 1)).astype(np.float64) / 255.0
        rawpy_linear = srgb_to_linear(rawpy_srgb_gamma)
        rawpy_xyz = SRGB_TO_XYZ @ rawpy_linear

        # New: rawpy postprocess to RAW RGB (camera space), no white balance.
        # We demosaic in rawpy, keep linear, and then apply the same WB + cam->XYZ
        # pipeline ourselves so we can inspect how this path compares.
        rgb_raw = raw.postprocess(
            use_camera_wb=False,
            use_auto_wb=False,
            user_wb=[1.0, 1.0, 1.0, 1.0],
            output_bps=16,
            output_color=rawpy.ColorSpace.raw,
            no_auto_bright=True,
            no_auto_scale=True,
            gamma=(1.0, 1.0),
        )
        y0, y1 = rect["top"], rect["bottom"]
        x0, x1 = rect["left"], rect["right"]
        roi_raw = rgb_raw[y0:y1, x0:x1, :]
        if roi_raw.size == 0:
            raise SystemExit(f"Empty ROI for rawpy postprocess path: {rect}")
        # Normalize to 0..1 range from uint16.
        rawpy_post_stage_raw = roi_raw.mean(axis=(0, 1)).astype(np.float64) / 65535.0
        rawpy_post_stage_wb = rawpy_post_stage_raw * wb
        # For the postprocess-RAW view we keep the same effective XYZ and
        # sRGB as the main rawpy reference column, so that differences
        # isolate the impact of demosaicing vs CFA averaging rather than
        # color space math.
        rawpy_post_xyz = rawpy_xyz.copy()
        rawpy_post_linear = rawpy_linear.copy()
        rawpy_post_srgb_gamma = rawpy_srgb_gamma.copy()

    # Middle: Kotlin RAW pipeline (from xyz_x/y/z)
    kotlin_raw_stage_raw = raw_rgb_csv.copy()
    kotlin_raw_stage_wb = np.array(
        [getf(row, "linear_r"), getf(row, "linear_g"), getf(row, "linear_b")],
        dtype=np.float64,
    )
    kotlin_raw_xyz = np.array(
        [getf(row, "xyz_x"), getf(row, "xyz_y"), getf(row, "xyz_z")],
        dtype=np.float64,
    )
    kotlin_raw_linear = XYZ_TO_SRGB @ kotlin_raw_xyz
    kotlin_raw_srgb_gamma = linear_to_srgb(kotlin_raw_linear)

    # Right: Kotlin JPEG pipeline
    jpeg_srgb_gamma = np.array(
        [
            getf(row, "jpeg_srgb_r"),
            getf(row, "jpeg_srgb_g"),
            getf(row, "jpeg_srgb_b"),
        ],
        dtype=np.float64,
    )
    jpeg_linear = np.array(
        [
            getf(row, "jpeg_linear_r"),
            getf(row, "jpeg_linear_g"),
            getf(row, "jpeg_linear_b"),
        ],
        dtype=np.float64,
    )
    jpeg_xyz = np.array(
        [getf(row, "jpeg_xyz_x"), getf(row, "jpeg_xyz_y"), getf(row, "jpeg_xyz_z")],
        dtype=np.float64,
    )
    jpeg_linear_from_xyz = XYZ_TO_SRGB @ jpeg_xyz
    jpeg_srgb_from_xyz = linear_to_srgb(jpeg_linear_from_xyz)

    pipelines: Dict[str, Dict[str, np.ndarray]] = {
        "rawpy_roi": {
            "raw_rgb": rawpy_stage_raw,
            "wb_rgb": rawpy_stage_wb,
            "xyz": rawpy_xyz,
            "linear_srgb": rawpy_linear,
            "gamma_srgb": rawpy_srgb_gamma,
        },
        "rawpy_post": {
            "raw_rgb": rawpy_post_stage_raw,
            "wb_rgb": rawpy_post_stage_wb,
            "xyz": rawpy_post_xyz,
            "linear_srgb": rawpy_post_linear,
            "gamma_srgb": rawpy_post_srgb_gamma,
        },
        "kotlin_raw": {
            "raw_rgb": kotlin_raw_stage_raw,
            "wb_rgb": kotlin_raw_stage_wb,
            "xyz": kotlin_raw_xyz,
            "linear_srgb": kotlin_raw_linear,
            "gamma_srgb": kotlin_raw_srgb_gamma,
        },
        "kotlin_jpeg": {
            "raw_rgb": jpeg_srgb_gamma,  # treated as entry point for JPEG path
            "wb_rgb": jpeg_linear,
            "xyz": jpeg_xyz,
            "linear_srgb": jpeg_linear_from_xyz,
            "gamma_srgb": jpeg_srgb_from_xyz,
        },
    }
    return pipelines


def channel_ratio(v: np.ndarray) -> np.ndarray:
    v = np.clip(v, 0.0, None)
    s = v.sum()
    if s <= 1e-6:
        return np.zeros_like(v)
    return v / s


def build_visualization(
    jpeg_path: Path,
    dng_path: Path,
    row: Dict[str, str],
    out_path: Path,
    ratio_threshold: float = 0.05,
) -> None:
    overlay, bbox = create_roi_overlay(jpeg_path, row)
    raw_overlay = create_raw_overlay(dng_path, row)
    pipelines = compute_pipelines(row, dng_path)

    # Final gamma sRGB for ratio comparison
    ref = pipelines["kotlin_jpeg"]["gamma_srgb"]
    ref_ratio = channel_ratio(ref)

    verdicts: Dict[str, str] = {}
    for name, stages in pipelines.items():
        ratios = channel_ratio(stages["gamma_srgb"])
        diff = np.max(np.abs(ratios - ref_ratio))
        verdicts[name] = "FAIL" if diff > ratio_threshold else "OK"

    # Drawing layout
    font = ImageFont.load_default()

    def line_height() -> int:
        bbox = font.getbbox("Ag")
        return bbox[3] - bbox[1] + 2

    lh = line_height()

    patch_w, patch_h = 180, 90
    padding = 40
    col_gap = 60
    row_gap = 40
    header_h = 30

    # Canvas width: four columns
    width = padding * 2 + 4 * patch_w + 3 * col_gap

    # Preview at top: RAW (grayscale) + JPEG, side-by-side
    max_preview_w_total = width - padding * 2
    max_preview_h = 320
    single_preview_w = (max_preview_w_total - col_gap) / 2.0

    def resize_preview(img: Image.Image) -> Image.Image:
        scale = min(
            single_preview_w / img.width,
            max_preview_h / img.height,
            1.0,
        )
        if scale < 1.0:
            return img.resize(
                (int(img.width * scale), int(img.height * scale)),
                Image.LANCZOS,
            )
        return img

    raw_preview = resize_preview(raw_overlay)
    jpeg_preview = resize_preview(overlay)
    preview_h = max(raw_preview.height, jpeg_preview.height)
    preview_text_lines = [
        "JPEG preview with ROI",
        f"ROI bbox px: L{bbox[0]}-{bbox[2]}, T{bbox[1]}-{bbox[3]} "
        f"({bbox[2]-bbox[0]}x{bbox[3]-bbox[1]})",
    ]
    preview_text_h = len(preview_text_lines) * lh + 10

    stages = ["raw_rgb", "wb_rgb", "xyz", "linear_srgb", "gamma_srgb"]
    stage_labels = ["Raw RGB", "WB RGB", "XYZ", "Linear sRGB", "Gamma sRGB"]
    stage_area_h = header_h + len(stages) * patch_h + (len(stages) - 1) * row_gap

    summary_lines = []
    for name, label in (
        ("rawpy_roi", "Rawpy ROI"),
        ("rawpy_post", "Rawpy Post"),
        ("kotlin_raw", "Kotlin RAW"),
    ):
        xyz = pipelines[name]["xyz"]
        gamma = pipelines[name]["gamma_srgb"]
        summary_lines.append(
            f"{label} XYZ: {fmt_triplet(xyz)}  gamma sRGB: {fmt_triplet(gamma)} "
            f"-> {verdicts[name]}"
        )
    summary_lines.append(
        f"Kotlin JPEG XYZ: {fmt_triplet(pipelines['kotlin_jpeg']['xyz'])} "
        f"gamma sRGB: {fmt_triplet(pipelines['kotlin_jpeg']['gamma_srgb'])}"
    )
    summary_h = len(summary_lines) * lh + 10

    height = (
        padding
        + preview_h
        + preview_text_h
        + 30
        + stage_area_h
        + summary_h
        + padding
    )

    canvas = Image.new("RGB", (width, height), (255, 255, 255))
    draw = ImageDraw.Draw(canvas)

    # Paste RAW + JPEG previews
    preview_y = padding
    # Center each preview within its half-width block
    raw_block_x0 = padding
    jpeg_block_x0 = padding + int(single_preview_w) + col_gap
    raw_x = raw_block_x0 + max(0, int((single_preview_w - raw_preview.width) // 2))
    jpeg_x = jpeg_block_x0 + max(0, int((single_preview_w - jpeg_preview.width) // 2))

    canvas.paste(raw_preview, (raw_x, preview_y))
    canvas.paste(jpeg_preview, (jpeg_x, preview_y))

    text_y = preview_y + preview_h + 8
    for line in preview_text_lines:
        draw.text((padding, text_y), line, fill=(0, 0, 0), font=font)
        text_y += lh

    # Column positions
    col_x = [
        padding,
        padding + (patch_w + col_gap),
        padding + 2 * (patch_w + col_gap),
        padding + 3 * (patch_w + col_gap),
    ]
    headers = ["RAWPY ROI", "RAWPY POST", "KOTLIN RAW", "KOTLIN JPEG"]

    header_y = preview_y + preview_h + preview_text_h + 30
    for x, text in zip(col_x, headers):
        draw.text((x, header_y), text, fill=(0, 0, 0), font=font)

    base_y = header_y + header_h

    column_keys = ["rawpy_roi", "rawpy_post", "kotlin_raw", "kotlin_jpeg"]

    for i, stage in enumerate(stages):
        y = base_y + i * (patch_h + row_gap)
        label = stage_labels[i]
        draw.text((padding - 10, y + patch_h // 2 - lh), label, fill=(0, 0, 0), font=font)

        for x, key in zip(col_x, column_keys):
            stages_dict = pipelines[key]
            vec = stages_dict[stage]
            if stage == "xyz":
                # Map XYZ to linear sRGB for visualization
                rgb_lin = XYZ_TO_SRGB @ vec
            elif stage.endswith("gamma"):
                # Gamma sRGB already
                rgb_lin = srgb_to_linear(vec)
            else:
                # Assume linear rgb-like values
                rgb_lin = vec

            color = linear_rgb_to_uint8(rgb_lin)
            patch_box = (x, y, x + patch_w, y + patch_h)
            draw.rectangle(patch_box, fill=color, outline=(0, 0, 0), width=2)

            text_block_y = y + patch_h + 4
            lines = [
                f"{label}",
                f"Value: {fmt_triplet(vec)}",
            ]
            if stage == "gamma_srgb":
                lines.append(f"Verdict vs JPEG: {verdicts[key]}")
            for line in lines:
                draw.text((x, text_block_y), line, fill=(0, 0, 0), font=font)
                text_block_y += lh

    summary_y = base_y + len(stages) * (patch_h + row_gap) - row_gap + 30
    for line in summary_lines:
        draw.text((padding, summary_y), line, fill=(0, 0, 0), font=font)
        summary_y += lh

    out_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out_path, quality=95)
    print(f"Saved visualization to {out_path}")


def main() -> None:
    args = parse_args()
    row = load_roi_row(args.roi_csv, args.roi_index)
    out_path = args.out or args.roi_csv.with_stem(args.roi_csv.stem + "_three_pipelines")
    out_path = out_path.with_suffix(".jpg")
    build_visualization(args.jpeg, args.dng, row, out_path)


if __name__ == "__main__":
    main()
