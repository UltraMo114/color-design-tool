#!/usr/bin/env python3
"""
Prototype pipeline that reproduces the RAW -> WB -> XYZ -> sRGB flow entirely in Python.

Given a DNG and an ROI dump CSV (created on-device), the script will:
1. Recompute RAW channel averages directly from the CFA plane.
2. Apply the recorded white-balance gains (or the DNG's camera_whitebalance).
3. Use the DNG color matrix to transform into XYZ.
4. Convert to sRGB (linear + gamma) so we can compare with JPEG output.
"""

from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Optional

import numpy as np
import rawpy  # type: ignore

XYZ_TO_SRGB = np.array(
    [
        [3.2406, -1.5372, -0.4986],
        [-0.9689, 1.8758, 0.0415],
        [0.0557, -0.2040, 1.0570],
    ],
    dtype=np.float64,
)


@dataclass
class RoiEntry:
    index: int
    normalized: Dict[str, float]
    raw_rect: Dict[str, int]
    raw_rgb: Dict[str, float]
    wb_gains: Dict[str, float]
    device_linear: Optional[Dict[str, float]] = None
    device_xyz: Optional[Dict[str, float]] = None
    rawpy_xyz: Optional[Dict[str, float]] = None
    rawpy_srgb: Optional[Dict[str, float]] = None

    @property
    def label(self) -> str:
        return (
            f"ROI#{self.index} "
            f"raw[{self.raw_rect['left']}:{self.raw_rect['right']},"
            f"{self.raw_rect['top']}:{self.raw_rect['bottom']}] "
            f"(norm {self.normalized})"
        )


@dataclass
class RoiComputation:
    roi_index: int
    raw_r: float
    raw_g: float
    raw_b: float
    wb_r: float
    wb_g: float
    wb_b: float
    xyz_x: float
    xyz_y: float
    xyz_z: float
    srgb_r: float
    srgb_g: float
    srgb_b: float


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
                wb_gains={
                    "r": _parse_float(row.get("wb_r_gain", "")),
                    "g": _parse_float(row.get("wb_g_gain", "")),
                    "b": _parse_float(row.get("wb_b_gain", "")),
                },
                device_linear={
                    "r": _parse_float(row.get("linear_r", "")),
                    "g": _parse_float(row.get("linear_g", "")),
                    "b": _parse_float(row.get("linear_b", "")),
                }
                if row.get("linear_r") is not None
                else None,
                device_xyz={
                    "x": _parse_float(row.get("xyz_x", "")),
                    "y": _parse_float(row.get("xyz_y", "")),
                    "z": _parse_float(row.get("xyz_z", "")),
                }
                if row.get("xyz_x") is not None
                else None,
                rawpy_xyz={
                    "x": _parse_float(row.get("rawpy_x", "")),
                    "y": _parse_float(row.get("rawpy_y", "")),
                    "z": _parse_float(row.get("rawpy_z", "")),
                }
                if row.get("rawpy_x") is not None
                else None,
                rawpy_srgb={
                    "r": _parse_float(row.get("rawpy_srgb_r", "")),
                    "g": _parse_float(row.get("rawpy_srgb_g", "")),
                    "b": _parse_float(row.get("rawpy_srgb_b", "")),
                }
                if row.get("rawpy_srgb_r") is not None
                else None,
            )
        )
    return entries


def get_cam2xyz_matrix(raw: rawpy.RawPy) -> np.ndarray | None:
    """
    Builds a 3x3 camera-to-XYZ matrix from the DNG color matrix.

    raw.color_matrix in libraw/rawpy is the DNG ColorMatrix tag collapsed
    to 3 x #cfa_channels and represents an XYZ->Camera transform
    (per DNG spec). We first collapse duplicate CFA channels (e.g. the two
    greens) into a 3x3 XYZ->Cam matrix and then invert it to obtain
    Cam->XYZ, which is what our pipeline expects.
    """
    xyz_to_cam = np.array(getattr(raw, "color_matrix", []), dtype=np.float64)
    if xyz_to_cam.size == 0:
        return None
    desc = raw.color_desc.decode("ascii")
    channels = []
    for target in "RGB":
        indices = [i for i, ch in enumerate(desc) if ch == target]
        if not indices:
            return None
        column = xyz_to_cam[:, indices].mean(axis=1)
        channels.append(column)
    xyz_to_cam_3x3 = np.stack(channels, axis=1)
    try:
        cam2xyz = np.linalg.inv(xyz_to_cam_3x3)
    except np.linalg.LinAlgError:
        return None
    return cam2xyz


def dump_color_matrices(raw: rawpy.RawPy, cam2xyz: np.ndarray, output_json: Path) -> None:
    payload: Dict[str, object] = {}
    color_matrix = np.array(getattr(raw, "color_matrix", []), dtype=np.float64)
    if color_matrix.size > 0:
        payload["color_matrix_xyz_to_cam"] = color_matrix.tolist()
    payload["cam_to_xyz_matrix"] = cam2xyz.tolist()
    try:
        payload["xyz_to_cam_matrix"] = np.linalg.inv(cam2xyz).tolist()
    except np.linalg.LinAlgError:
        payload["xyz_to_cam_matrix"] = None
    rgb_xyz = getattr(raw, "rgb_xyz_matrix", None)
    if rgb_xyz is not None:
        payload["rawpy_rgb_to_xyz"] = np.array(rgb_xyz, dtype=np.float64).tolist()
    payload["camera_whitebalance"] = list(raw.camera_whitebalance[:3])
    payload["color_desc"] = raw.color_desc.decode("ascii")
    output_json.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"Wrote matrix dump to {output_json}")


def compute_roi_means(raw: rawpy.RawPy, rect: Dict[str, int]) -> Dict[str, float]:
    """
    Mimics RawRoiProcessor: subtracts channel-specific black level, normalizes
    by white level, and averages per CFA channel within the ROI.
    """
    top, bottom = rect["top"], rect["bottom"]
    left, right = rect["left"], rect["right"]
    if bottom <= top or right <= left:
        raise ValueError(f"Invalid ROI rect: {rect}")

    raw_img = raw.raw_image_visible.astype(np.float64)
    raw_colors = raw.raw_colors_visible

    roi_img = raw_img[top:bottom, left:right]
    roi_colors = raw_colors[top:bottom, left:right]

    black_levels = raw.black_level_per_channel
    white_level = raw.white_level or np.max(roi_img)
    if white_level == 0:
        white_level = 1.0

    def avg_channel(indices: Iterable[int]) -> float:
        values = []
        for idx in indices:
            mask = roi_colors == idx
            if not np.any(mask):
                continue
            samples = roi_img[mask]
            corrected = np.clip(samples - black_levels[idx], 0, None) / white_level
            values.append(np.mean(corrected))
        if not values:
            return float("nan")
        return float(np.mean(values))

    # raw.color_desc order matches raw_colors channel indices
    desc = raw.color_desc.decode("ascii")
    r_indices = [i for i, ch in enumerate(desc) if ch == "R"]
    g_indices = [i for i, ch in enumerate(desc) if ch == "G"]
    b_indices = [i for i, ch in enumerate(desc) if ch == "B"]

    return {
        "r": avg_channel(r_indices),
        "g": avg_channel(g_indices),
        "b": avg_channel(b_indices),
    }


def linear_to_srgb(linear_rgb: np.ndarray) -> np.ndarray:
    linear_rgb = np.clip(linear_rgb, 0.0, None)
    threshold = 0.0031308
    srgb = np.where(
        linear_rgb <= threshold,
        linear_rgb * 12.92,
        1.055 * np.power(linear_rgb, 1 / 2.4) - 0.055,
    )
    return np.clip(srgb, 0.0, 1.0)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Reconstruct the RAW->WB->XYZ->sRGB pipeline for ROI dumps.",
    )
    parser.add_argument("--dng", required=True, type=Path, help="Path to the DNG.")
    parser.add_argument(
        "--roi-csv",
        required=True,
        type=Path,
        help="ROI dump CSV exported by the app.",
    )
    parser.add_argument(
        "--indices",
        type=int,
        nargs="*",
        help="Optional list of ROI indices to run (defaults to all).",
    )
    parser.add_argument(
        "--output-json",
        type=Path,
        help="Optional path to write computed ROI results as JSON.",
    )
    parser.add_argument(
        "--matrix-json",
        type=Path,
        help="Optional path to dump DNG color matrix details (includes inverse).",
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
                raise SystemExit(f"ROI index {idx} out of range (0..{len(entries) - 1}).")
            target_entries.append(entries[idx])
    else:
        target_entries = entries

    with rawpy.imread(str(args.dng)) as raw:
        cam2xyz = get_cam2xyz_matrix(raw)
        if cam2xyz is None:
            raise SystemExit("DNG does not expose color_matrix; cannot continue.")
        print("Camera color desc:", raw.color_desc)
        print("Camera -> XYZ matrix:\n", cam2xyz)
        print("Camera WB gains:", raw.camera_whitebalance[:3])
        print()
        if args.matrix_json:
            dump_color_matrices(raw, cam2xyz, args.matrix_json)

        computed: List[RoiComputation] = []
        for entry in target_entries:
            print("=" * 70)
            print(entry.label)
            roi_means = compute_roi_means(raw, entry.raw_rect)
            print("Recomputed RAW averages:", roi_means)
            wb = np.array(
                [
                    entry.wb_gains["r"],
                    entry.wb_gains["g"],
                    entry.wb_gains["b"],
                ],
                dtype=np.float64,
            )
            # Replace NaNs with camera defaults if necessary.
            if not np.all(np.isfinite(wb)):
                wb = np.array(raw.camera_whitebalance[:3], dtype=np.float64)
            camera_rgb = np.array(
                [roi_means["r"], roi_means["g"], roi_means["b"]], dtype=np.float64
            )
            balanced = camera_rgb * wb
            xyz = cam2xyz @ balanced
            srgb_linear = XYZ_TO_SRGB @ xyz
            srgb = linear_to_srgb(srgb_linear)
            srgb_uint8 = np.clip(np.round(srgb * 255), 0, 255).astype(int)

            print("WB gains used:", wb)
            print("WB-corrected camera RGB:", balanced)
            print("XYZ from matrix:", xyz)
            print("Linear sRGB:", srgb_linear)
            print("sRGB (gamma):", srgb)
            print("sRGB 0-255:", srgb_uint8)
            if entry.device_xyz:
                diff_xyz = xyz - np.array(
                    [
                        entry.device_xyz.get("x", np.nan),
                        entry.device_xyz.get("y", np.nan),
                        entry.device_xyz.get("z", np.nan),
                    ]
                )
                print("ΔXYZ vs device:", diff_xyz)
            if entry.rawpy_xyz:
                diff_rawpy = xyz - np.array(
                    [
                        entry.rawpy_xyz.get("x", np.nan),
                        entry.rawpy_xyz.get("y", np.nan),
                        entry.rawpy_xyz.get("z", np.nan),
                    ]
                )
                print("ΔXYZ vs rawpy column:", diff_rawpy)
            computed.append(
                RoiComputation(
                    roi_index=entry.index,
                    raw_r=camera_rgb[0],
                    raw_g=camera_rgb[1],
                    raw_b=camera_rgb[2],
                    wb_r=balanced[0],
                    wb_g=balanced[1],
                    wb_b=balanced[2],
                    xyz_x=xyz[0],
                    xyz_y=xyz[1],
                    xyz_z=xyz[2],
                    srgb_r=srgb[0],
                    srgb_g=srgb[1],
                    srgb_b=srgb[2],
                )
            )
            print("----")
    if args.output_json:
        payload = [asdict(result) for result in computed]
        args.output_json.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"Wrote {len(payload)} ROI computations to {args.output_json}")


if __name__ == "__main__":
    main()
