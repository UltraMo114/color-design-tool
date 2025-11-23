#!/usr/bin/env python3
"""
Extract and compare the various Color Correction Matrices (CCM) available
in a DNG snapshot. The script reproduces rawpy's matrix collapsing logic
so we can port the same math into Kotlin.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import Dict, Iterable, List, Sequence

import numpy as np
import rawpy  # type: ignore


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Inspect CCM sources for a snapshot.")
    parser.add_argument("--dng", required=True, type=Path, help="Path to the DNG file.")
    parser.add_argument(
        "--csv",
        type=Path,
        help="ROI dump CSV path (to read the matrices recorded by the app).",
    )
    parser.add_argument(
        "--csv-row",
        type=int,
        default=0,
        help="ROI row index to inspect in the CSV (default: 0).",
    )
    return parser.parse_args()


def load_csv_row(csv_path: Path, index: int) -> Dict[str, str] | None:
    if not csv_path:
        return None
    with csv_path.open(newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    if not rows or index < 0 or index >= len(rows):
        return None
    return rows[index]


def matrix_from_row(row: Dict[str, str], prefix: str, rows: int, cols: int) -> np.ndarray | None:
    values: List[float] = []
    for r in range(rows):
        for c in range(cols):
            key = f"{prefix}_m{r}{c}"
            raw = row.get(key, "")
            if not raw:
                return None
            values.append(float(raw))
    return np.array(values, dtype=np.float64).reshape(rows, cols)


def color_matrix_from_rawpy(color_matrix: np.ndarray, color_desc: bytes) -> np.ndarray:
    """
    Collapse the DNG color matrix (3 x #channels) into a 3x3 XYZ->Cam matrix
    by averaging duplicate channels (typically the two greens).
    """
    desc = color_desc.decode("ascii")
    collapsed: List[np.ndarray] = []
    for target in "RGB":
        indices = [i for i, ch in enumerate(desc) if ch == target]
        if not indices:
            raise ValueError(f"Color '{target}' missing in color_desc '{desc}'")
        channel = color_matrix[:, indices].mean(axis=1)
        collapsed.append(channel)
    return np.stack(collapsed, axis=1)


def summarize(name: str, matrix: np.ndarray | None) -> None:
    print(f"\n{name}:")
    if matrix is None:
        print("  (missing)")
        return
    for row in matrix:
        print("  ", "  ".join(f"{value: .6f}" for value in row))


def main() -> None:
    args = parse_args()

    row = load_csv_row(args.csv, args.csv_row) if args.csv else None
    with rawpy.imread(str(args.dng)) as raw:
        rawpy_matrix = color_matrix_from_rawpy(np.array(raw.color_matrix), raw.color_desc)
        rawpy_cam_to_xyz = rawpy_matrix.T
        rawpy_xyz_to_cam = rawpy_matrix

    matrices: Dict[str, np.ndarray | None] = {
        "rawpy_cam_to_xyz": rawpy_cam_to_xyz,
        "rawpy_xyz_to_cam": rawpy_xyz_to_cam,
    }
    if row:
        matrices["app_cam_to_xyz"] = matrix_from_row(row, "cam_to_xyz", 3, 3)
        matrices["app_xyz_to_cam"] = matrix_from_row(row, "xyz_to_cam", 3, 3)
        matrices["colorMatrix1"] = matrix_from_row(row, "color_matrix1", 3, 4)
        matrices["colorMatrix2"] = matrix_from_row(row, "color_matrix2", 3, 4)
        matrices["colorMatrixRaw"] = matrix_from_row(row, "color_matrix_raw", 3, 3)
        matrices["colorCorrectionTransform"] = matrix_from_row(row, "color_correction", 3, 3)
        matrices["forwardMatrix1"] = matrix_from_row(row, "forward_matrix1", 3, 4)
        matrices["forwardMatrix2"] = matrix_from_row(row, "forward_matrix2", 3, 4)

    for name, matrix in matrices.items():
        summarize(name, matrix)


if __name__ == "__main__":
    main()
