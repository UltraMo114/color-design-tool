#!/usr/bin/env python3
"""
Render full rawpy image and draw the ROI rectangle from a CSV row.
Used to visually inspect whether rawpy's pipeline behaves reasonably inside the ROI.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import Dict

import matplotlib.pyplot as plt
import numpy as np
import rawpy  # type: ignore


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Show rawpy render with ROI rectangle overlay.")
    parser.add_argument("--dng", required=True, type=Path, help="Path to DNG file.")
    parser.add_argument("--roi-csv", required=True, type=Path, help="ROI CSV for this capture.")
    parser.add_argument("--row", type=int, default=0, help="ROI row index (default: 0).")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("rawpy_roi_overlay.png"),
        help="Output PNG path.",
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
            continue
        try:
            parsed[key] = float(value)
        except ValueError:
            parsed[key] = value  # e.g., timestamp
    return parsed


def main() -> None:
    args = parse_args()
    row = load_row(args.roi_csv, args.row)

    with rawpy.imread(str(args.dng)) as raw:
        rgb = raw.postprocess(
            use_camera_wb=True,
            no_auto_bright=True,
            output_bps=8,
            output_color=rawpy.ColorSpace.sRGB,
        )

    h, w, _ = rgb.shape
    # Use the actual RAW buffer ROI coordinates as recorded by the app.
    # These are the pixel coordinates that RawRoiProcessor accumulates over.
    try:
        x0 = int(row["raw_left"])
        y0 = int(row["raw_top"])
        x1 = int(row["raw_right"])
        y1 = int(row["raw_bottom"])
    except KeyError as exc:
        raise SystemExit(f"Missing raw_* fields in CSV row: {exc}") from exc

    # Compute mean RGB inside ROI for sanity
    roi_region = rgb[y0:y1, x0:x1, :]
    roi_mean = roi_region.mean(axis=(0, 1))
    print("ROI mean (rawpy sRGB):", roi_mean)

    fig, ax = plt.subplots(figsize=(6, 6))
    ax.imshow(rgb)
    rect = plt.Rectangle(
        (x0, y0),
        x1 - x0,
        y1 - y0,
        fill=False,
        edgecolor="red",
        linewidth=2.0,
    )
    ax.add_patch(rect)
    ax.set_title(f"rawpy render with ROI (row {args.row})")
    ax.axis("off")
    fig.tight_layout()
    fig.savefig(args.output, dpi=150)
    plt.close(fig)
    print(f"Saved overlay to {args.output}")


if __name__ == "__main__":
    main()
