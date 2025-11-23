#!/usr/bin/env python3
"""
Utility script to compare ROI dumps from CameraCaptureScreen with data derived
directly from the captured DNG using rawpy. This helps validate the RAW→RGB→XYZ
pipeline whenever the on-device averages look suspicious.
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Sequence

import numpy as np

try:
    import rawpy  # type: ignore
except ImportError as exc:  # pragma: no cover - helper script
    raise SystemExit(
        "rawpy is required. Install it via `pip install rawpy`."
    ) from exc


@dataclass
class RoiEntry:
    index: int
    normalized: Dict[str, float]
    raw_rect: Dict[str, int]
    raw_rgb: Dict[str, float]
    linear_rgb: Dict[str, float]
    xyz: Dict[str, float]
    wb_gains: Dict[str, float]

    @property
    def label(self) -> str:
        return f"ROI#{self.index}: raw[{self.raw_rect['left']}:{self.raw_rect['right']}," \
            f"{self.raw_rect['top']}:{self.raw_rect['bottom']}]"


def _parse_float(value: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return float("nan")


def load_roi_entries(csv_path: Path) -> List[RoiEntry]:
    with csv_path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        rows = list(reader)
    entries: List[RoiEntry] = []
    for idx, row in enumerate(rows):
        entries.append(
            RoiEntry(
                index=idx,
                normalized={
                    "left": _parse_float(row.get("roi_left", "")),
                    "top": _parse_float(row.get("roi_top", "")),
                    "right": _parse_float(row.get("roi_right", "")),
                    "bottom": _parse_float(row.get("roi_bottom", "")),
                },
                raw_rect={
                    "left": int(float(row.get("raw_left", 0) or 0)),
                    "top": int(float(row.get("raw_top", 0) or 0)),
                    "right": int(float(row.get("raw_right", 0) or 0)),
                    "bottom": int(float(row.get("raw_bottom", 0) or 0)),
                },
                raw_rgb={
                    "r": _parse_float(row.get("raw_r", "")),
                    "g": _parse_float(row.get("raw_g", "")),
                    "b": _parse_float(row.get("raw_b", "")),
                },
                linear_rgb={
                    "r": _parse_float(row.get("linear_r", "")),
                    "g": _parse_float(row.get("linear_g", "")),
                    "b": _parse_float(row.get("linear_b", "")),
                },
                xyz={
                    "x": _parse_float(row.get("xyz_x", "")),
                    "y": _parse_float(row.get("xyz_y", "")),
                    "z": _parse_float(row.get("xyz_z", "")),
                },
                wb_gains={
                    "r": _parse_float(row.get("wb_r_gain", "")),
                    "g": _parse_float(row.get("wb_g_gain", "")),
                    "b": _parse_float(row.get("wb_b_gain", "")),
                },
            )
        )
    return entries


def channel_name_map(raw: rawpy.RawPy) -> Dict[int, str]:
    """Map channel indices reported by rawpy to RGB letters."""
    desc = raw.color_desc.decode("ascii")
    mapping = {}
    for idx, letter in enumerate(desc):
        if letter == "G":
            # rawpy exposes two green channels; treat them both as "G".
            mapping[idx] = "G"
        else:
            mapping[idx] = letter
    return mapping


def channel_black_levels(raw: rawpy.RawPy) -> Dict[int, float]:
    """Return the black level for each CFA index."""
    blacks = raw.black_level_per_channel
    mapping = {}
    # There can be up to 4 values (RGGB). Fall back to the first entry.
    for idx in range(len(raw.color_desc)):
        mapping[idx] = float(blacks[idx] if idx < len(blacks) else blacks[0])
    return mapping


def compute_roi_means(
    raw: rawpy.RawPy,
    rect: Dict[str, int],
) -> Dict[str, float]:
    """Compute normalized averages per RGB channel within the ROI."""
    top, bottom = rect["top"], rect["bottom"]
    left, right = rect["left"], rect["right"]
    if bottom <= top or right <= left:
        raise ValueError(f"Invalid ROI rect: {rect}")

    raw_img = raw.raw_image_visible.astype(np.float64)
    raw_colors = raw.raw_colors_visible
    roi_img = raw_img[top:bottom, left:right]
    roi_colors = raw_colors[top:bottom, left:right]

    black_levels = channel_black_levels(raw)
    white_level = float(raw.white_level or roi_img.max())
    denom = max(1.0, white_level)
    channel_map = channel_name_map(raw)

    accumulator: Dict[str, List[float]] = {"R": [], "G": [], "B": []}
    for channel_idx, rgb_letter in channel_map.items():
        mask = roi_colors == channel_idx
        if not np.any(mask):
            continue
        values = roi_img[mask]
        corrected = np.clip(values - black_levels[channel_idx], 0, None) / denom
        accumulator[rgb_letter].append(float(np.mean(corrected)))

    # Average the two green channels if necessary.
    means = {
        "r": float(np.mean(accumulator["R"])) if accumulator["R"] else float("nan"),
        "g": float(np.mean(accumulator["G"])) if accumulator["G"] else float("nan"),
        "b": float(np.mean(accumulator["B"])) if accumulator["B"] else float("nan"),
    }
    return means


def compare(entry: RoiEntry, measured: Dict[str, float]) -> Dict[str, float]:
    return {
        channel: measured[channel] - entry.raw_rgb[channel]
        for channel in ("r", "g", "b")
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Compare ROI dumps with values computed from a DNG.",
    )
    parser.add_argument(
        "--dng",
        required=True,
        type=Path,
        help="Path to the DNG produced by NativeCameraCaptureActivity.",
    )
    parser.add_argument(
        "--roi-csv",
        required=True,
        type=Path,
        help="CSV exported via CameraCaptureScreen ROI dump.",
    )
    parser.add_argument(
        "--indices",
        type=int,
        nargs="*",
        help="Optional list of ROI indices to inspect (defaults to all).",
    )
    args = parser.parse_args()

    entries = load_roi_entries(args.roi_csv)
    if not entries:
        raise SystemExit("No ROI rows found in CSV.")

    target_entries: Sequence[RoiEntry]
    if args.indices:
        target_entries = []
        for idx in args.indices:
            if idx < 0 or idx >= len(entries):
                raise SystemExit(f"ROI index {idx} out of range (0..{len(entries)-1}).")
            target_entries.append(entries[idx])
    else:
        target_entries = entries

    print(f"Loaded {len(entries)} ROI rows; evaluating {len(target_entries)} entries.")
    print(f"Opening DNG: {args.dng}")
    with rawpy.imread(str(args.dng)) as raw:
        print("Camera color info:")
        print(f"  Color desc: {raw.color_desc.decode('ascii')}")
        print(f"  White level: {raw.white_level}")
        print(f"  Black levels: {raw.black_level_per_channel}")
        print(f"  RGB→XYZ matrix:\n{raw.rgb_xyz_matrix}")

        for entry in target_entries:
            measured = compute_roi_means(raw, entry.raw_rect)
            diffs = compare(entry, measured)
            print("=" * 60)
            print(entry.label)
            print(f"  Logged raw RGB : {entry.raw_rgb}")
            print(f"  rawpy raw RGB  : {measured}")
            print(f"  Difference     : {diffs}")
            print(f"  Logged WB gains: {entry.wb_gains}")
            print(f"  Logged XYZ     : {entry.xyz}")


if __name__ == "__main__":
    main()
