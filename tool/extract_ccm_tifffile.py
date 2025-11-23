#!/usr/bin/env python3
"""
Read ColorMatrix tags directly from a DNG via tifffile and reproduce the
RGBG collapsing logic used by rawpy. Useful for validating our eventual
Kotlin port without depending on libraw.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Iterable, Optional

import numpy as np
import tifffile

from extract_ccm import color_matrix_from_rawpy


TAG_COLOR_MATRIX1 = 50721
TAG_COLOR_MATRIX2 = 50722
TAG_CFA_PLANE_COLOR = 50710

COLOR_CODES = {
    0: "R",
    1: "G",
    2: "B",
    3: "C",
    4: "M",
    5: "Y",
    6: "W",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Extract CCM via tifffile.")
    parser.add_argument("--dng", required=True, type=Path, help="Path to DNG file.")
    parser.add_argument(
        "--compare-rawpy",
        action="store_true",
        help="Compare against rawpy's cam_to_xyz matrix for verification.",
    )
    return parser.parse_args()


def find_tag(pages: Iterable[tifffile.TiffPage], tag_id: int) -> Optional[tifffile.TiffTag]:
    for page in pages:
        tag = page.tags.get(tag_id)
        if tag is not None:
            return tag
    return None


def tag_values(tag: tifffile.TiffTag | None) -> Optional[np.ndarray]:
    if tag is None:
        return None
    value = tag.value
    if isinstance(value, (bytes, bytearray)):
        array = np.frombuffer(value, dtype=np.uint8)
    elif isinstance(value, np.ndarray):
        array = value
    else:
        array = np.array(value)
    array = np.asarray(array, dtype=np.float64)
    if tag.dtype in (5, 10) and array.size % 2 == 0:
        reshaped = array.reshape(-1, 2)
        numerators = reshaped[:, 0]
        denominators = reshaped[:, 1]
        denominators[denominators == 0] = 1.0
        return numerators / denominators
    return array


def matrix_from_tag(tag: tifffile.TiffTag | None) -> Optional[np.ndarray]:
    values = tag_values(tag)
    if values is None or values.size == 0:
        return None
    rows = 3
    cols = values.size // rows
    if cols == 0:
        return None
    return values.reshape(rows, cols)


def color_desc_from_tag(tag: tifffile.TiffTag | None) -> Optional[str]:
    values = tag_values(tag)
    if values is None or values.size == 0:
        return None
    letters = [COLOR_CODES.get(int(round(code)), "?") for code in values]
    if any(letter == "?" for letter in letters):
        return None
    return "".join(letters)


def summarize(name: str, matrix: Optional[np.ndarray]) -> None:
    print(f"\n{name}:")
    if matrix is None:
        print("  (missing)")
        return
    for row in matrix:
        print("  ", "  ".join(f"{value: .6f}" for value in row))


def main() -> None:
    args = parse_args()
    # Disable enum conversion for Orientation tag (274) since some DNGs use
    # non-standard values (e.g., 9) that cause tifffile to raise ValueError.
    tifffile.tifffile.TIFF.TAG_ENUM.pop(274, None)
    with tifffile.TiffFile(str(args.dng)) as tif:
        tag_matrix1 = find_tag(tif.pages, TAG_COLOR_MATRIX1)
        tag_matrix2 = find_tag(tif.pages, TAG_COLOR_MATRIX2)
        tag_cfa = find_tag(tif.pages, TAG_CFA_PLANE_COLOR)

        color_desc = color_desc_from_tag(tag_cfa) or "RGBG"
        print(f"Detected color_desc: {color_desc}")

        def collapse(tag: tifffile.TiffTag | None) -> Optional[np.ndarray]:
            matrix = matrix_from_tag(tag)
            if matrix is None:
                return None
            return color_matrix_from_rawpy(matrix, color_desc.encode("ascii"))

        collapsed1 = collapse(tag_matrix1)
        collapsed2 = collapse(tag_matrix2)

        summarize("tifffile_colorMatrix1_collapsed", collapsed1)
        summarize("tifffile_colorMatrix2_collapsed", collapsed2)

        if args.compare_rawpy:
            import rawpy  # type: ignore

            with rawpy.imread(str(args.dng)) as raw:
                rawpy_matrix = color_matrix_from_rawpy(np.array(raw.color_matrix), raw.color_desc)
                summarize("rawpy_xyz_to_cam", rawpy_matrix)


if __name__ == "__main__":
    main()
