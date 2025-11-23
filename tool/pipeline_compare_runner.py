#!/usr/bin/env python3
"""
Auto-run pipeline_compare on the latest snapshot without CLI arguments.
"""

from __future__ import annotations

import datetime
from pathlib import Path

from pipeline_compare import run_pipeline


def find_latest_snapshot(root: Path) -> Path:
    candidates = [p for p in root.iterdir() if p.is_dir() and p.name.startswith("snapshot_")]
    if not candidates:
        raise FileNotFoundError(f"No snapshot directories found under {root}")
    return max(candidates, key=lambda p: p.stat().st_mtime)


def find_latest_file(folder: Path, pattern: str, recursive: bool = False) -> Path:
    files = list(folder.rglob(pattern) if recursive else folder.glob(pattern))
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    if not files:
        raise FileNotFoundError(f"No files matching {pattern} under {folder}")
    return files[0]


def main() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    snapshot_root = repo_root / "storage" / "debug"
    snapshot = find_latest_snapshot(snapshot_root)

    csv_folder = snapshot / "documents" / "roi_exports"
    csv_path = find_latest_file(csv_folder, "*.csv")

    dng_folder = snapshot / "Pictures"
    dng_path = find_latest_file(dng_folder, "*.dng", recursive=True)

    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = snapshot / f"pipeline_plots_{timestamp}"

    run_pipeline(csv_path, dng_path, 0, output_dir)
    print(f"Plots saved to {output_dir}")


if __name__ == "__main__":
    main()
