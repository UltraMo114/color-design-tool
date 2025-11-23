#!/usr/bin/env python3
"""
Compare two simple color pipelines for a recorded ROI row:
1) The current Kotlin-style pipeline (uses cam_to_xyz from ROI CSV).
2) A rawpy-style pipeline (uses cam_to_xyz derived from rawpy's color matrix).

Each step is plotted to separate PNGs so we can inspect how values evolve.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import Dict, List, Tuple

import matplotlib.pyplot as plt
import numpy as np
import rawpy  # type: ignore

from extract_ccm import color_matrix_from_rawpy

D50 = np.array([0.9642, 1.0, 0.8251], dtype=np.float64)
D65 = np.array([0.95047, 1.0, 1.08883], dtype=np.float64)

XYZ_TO_SRGB = np.array(
    [
        [3.2406, -1.5372, -0.4986],
        [-0.9689, 1.8758, 0.0415],
        [0.0557, -0.2040, 1.0570],
    ],
    dtype=np.float64,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare Kotlin vs rawpy pipelines for a ROI row.")
    parser.add_argument("--roi-csv", required=True, type=Path, help="ROI dump CSV path.")
    parser.add_argument("--row", type=int, default=0, help="Row index to analyze.")
    parser.add_argument("--dng", required=True, type=Path, help="Matching DNG file.")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("pipeline_plots"),
        help="Directory to save matplotlib figures.",
    )
    return parser.parse_args()


def load_row(csv_path: Path, index: int) -> Dict[str, float]:
    with csv_path.open(newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    if index < 0 or index >= len(rows):
        raise IndexError(f"Row {index} out of range (total {len(rows)})")
    row = rows[index]
    parsed: Dict[str, float] = {}
    for key, value in row.items():
        if value in ("", None):
            parsed[key] = float("nan")
            continue
        try:
            parsed[key] = float(value)
        except ValueError:
            # Keep strings (e.g., timestamps) untouched by skipping
            continue
    return parsed


def matrix_from_row(row: Dict[str, float], prefix: str) -> np.ndarray:
    values: List[float] = []
    for r in range(3):
        for c in range(3):
            key = f"{prefix}_m{r}{c}"
            if key not in row or np.isnan(row[key]):
                raise ValueError(f"Missing matrix entry {key}")
            values.append(row[key])
    return np.array(values, dtype=np.float64).reshape(3, 3)


def adapt_to_d65(xyz: np.ndarray) -> np.ndarray:
    if xyz.size != 3:
        raise ValueError("XYZ vector must have length 3")
    bradford = np.array(
        [
            [0.8951, 0.2664, -0.1614],
            [-0.7502, 1.7135, 0.0367],
            [0.0389, -0.0685, 1.0296],
        ],
        dtype=np.float64,
    )
    bradford_inv = np.array(
        [
            [0.9869929, -0.1470543, 0.1599627],
            [0.4323053, 0.5183603, 0.0492912],
            [-0.0085287, 0.0400428, 0.9684867],
        ],
        dtype=np.float64,
    )
    src_cone = bradford @ D50
    dst_cone = bradford @ D65
    scale = np.divide(dst_cone, src_cone, out=np.ones_like(dst_cone), where=src_cone != 0)
    cone = bradford @ xyz
    adapted = cone * scale
    return bradford_inv @ adapted


def linear_to_srgb(linear_rgb: np.ndarray) -> np.ndarray:
    def gamma_channel(v: float) -> float:
        if v <= 0.0:
            return 0.0
        if v <= 0.0031308:
            return 12.92 * v
        return 1.055 * (v ** (1.0 / 2.4)) - 0.055

    return np.array([gamma_channel(channel) for channel in linear_rgb])


def as_shot_neutral_from_wb(wb: np.ndarray) -> np.ndarray:
    neutral = np.divide(1.0, wb, out=np.ones_like(wb), where=wb != 0)
    neutral /= neutral[1]  # normalize to G component
    return neutral


def compute_pipeline(
    name: str,
    camera_rgb: np.ndarray,
    wb_gains: np.ndarray,
    cam_to_xyz: np.ndarray,
) -> List[Tuple[str, np.ndarray]]:
    steps: List[Tuple[str, np.ndarray]] = []
    steps.append(("camera_rgb", camera_rgb))
    balanced = camera_rgb * wb_gains
    steps.append(("white_balance", balanced))
    xyz = cam_to_xyz @ balanced
    steps.append(("xyz_d50", xyz))
    xyz_d65 = adapt_to_d65(xyz)
    steps.append(("xyz_d65", xyz_d65))
    linear_srgb = XYZ_TO_SRGB @ xyz_d65
    steps.append(("srgb_linear", linear_srgb))
    gamma_srgb = linear_to_srgb(linear_srgb)
    steps.append(("srgb_gamma", gamma_srgb))
    return steps


def save_plot(values: np.ndarray, labels: List[str], title: str, output_path: Path) -> None:
    fig, ax = plt.subplots(figsize=(4, 3))
    ax.bar(labels, values, color=["#d62728", "#2ca02c", "#1f77b4"])
    ax.set_title(title)
    ax.set_ylabel("Value")
    ax.axhline(0, color="black", linewidth=0.5)
    fig.tight_layout()
    fig.savefig(output_path)
    plt.close(fig)


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def run_pipeline(csv_path: Path, dng_path: Path, row_index: int, output_dir: Path) -> Path:
    ensure_dir(output_dir)
    row = load_row(csv_path, row_index)

    camera_rgb = np.array([row["raw_r"], row["raw_g"], row["raw_b"]], dtype=np.float64)
    wb_gains = np.array([row["wb_r_gain"], row["wb_g_gain"], row["wb_b_gain"]], dtype=np.float64)

    cam_to_xyz_kotlin = matrix_from_row(row, "cam_to_xyz")

    # Derive cam_to_xyz via rawpy matrix
    with rawpy.imread(str(dng_path)) as raw:
        xyz_to_cam_rawpy = color_matrix_from_rawpy(np.array(raw.color_matrix), raw.color_desc)
    cam_to_xyz_rawpy = np.linalg.inv(xyz_to_cam_rawpy)

    kotlin_steps = compute_pipeline("kotlin", camera_rgb, wb_gains, cam_to_xyz_kotlin)
    rawpy_steps = compute_pipeline("rawpy", camera_rgb, wb_gains, cam_to_xyz_rawpy)

    for step_name, values in kotlin_steps:
        output_path = output_dir / f"kotlin_{step_name}.png"
        labels = ["R", "G", "B"] if "srgb" in step_name or "white" in step_name or "camera" in step_name else ["X", "Y", "Z"]
        save_plot(values, labels, f"Kotlin - {step_name}", output_path)

    for step_name, values in rawpy_steps:
        output_path = output_dir / f"rawpy_{step_name}.png"
        labels = ["R", "G", "B"] if "srgb" in step_name or "white" in step_name or "camera" in step_name else ["X", "Y", "Z"]
        save_plot(values, labels, f"Rawpy - {step_name}", output_path)

    return output_dir


def main() -> None:
    args = parse_args()
    out_dir = run_pipeline(args.roi_csv, args.dng, args.row, args.output_dir)
    print(f"Plots saved to {out_dir}")


if __name__ == "__main__":
    main()
