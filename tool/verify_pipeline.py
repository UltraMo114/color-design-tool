import json
from pathlib import Path
from typing import Optional

import cv2
import matplotlib.pyplot as plt
import numpy as np
import rawpy


ILLUMINANT_INFO = {
    0: ("Unknown", None),
    1: ("Daylight", 5500.0),
    2: ("Fluorescent", 4200.0),
    3: ("Tungsten", 2850.0),
    4: ("Flash", 6000.0),
    9: ("Fine Weather", 5500.0),
    10: ("Cloudy", 6500.0),
    11: ("Shade", 7500.0),
    12: ("Daylight Fluorescent", 6500.0),
    13: ("Day White Fluorescent", 7000.0),
    14: ("Cool White Fluorescent", 4200.0),
    15: ("White Fluorescent", 3500.0),
    16: ("Warm White Fluorescent", 3000.0),
    17: ("Standard Light A", 2856.0),
    18: ("Standard Light B", 4874.0),
    19: ("Standard Light C", 6774.0),
    20: ("D55", 5500.0),
    21: ("D65", 6504.0),
    22: ("D75", 7500.0),
    23: ("D50", 5003.0),
    24: ("ISO Studio Tungsten", 3200.0),
    255: ("Other", None),
}


def find_metadata_file(directory: Path) -> Optional[Path]:
    direct = directory / "metadata.json"
    if direct.exists():
        return direct
    candidates = sorted(directory.glob("*_metadata.json"))
    if candidates:
        return candidates[0]
    return None


def locate_data_dir(base_dir: Path) -> Path:
    """Return a directory that holds metadata.json and a DNG file."""

    def has_required_files(directory: Path) -> bool:
        metadata_ok = find_metadata_file(directory) is not None
        has_dng = any(directory.glob("*.dng")) or any(directory.glob("*.DNG"))
        return metadata_ok and has_dng

    def score_candidate(directory: Path, metadata_path: Path) -> tuple[int, float]:
        name = metadata_path.name
        score = 0
        if name.endswith("_metadata.json"):
            score += 10
        meta_stem = name
        if meta_stem.lower().endswith("_metadata.json"):
            meta_stem = meta_stem[: -len("_metadata.json")]
        meta_stem = Path(meta_stem).stem.lower()
        dng_stems = {p.stem.lower() for p in directory.glob("*.dng")}
        dng_stems.update(p.stem.lower() for p in directory.glob("*.DNG"))
        if meta_stem in dng_stems:
            score += 20
        dir_str = str(directory).lower()
        if "pipeline" in dir_str:
            score += 5
        if "debug" in dir_str:
            score += 1
        mtime = metadata_path.stat().st_mtime
        return score, mtime

    if has_required_files(base_dir):
        return base_dir

    search_roots = [base_dir]
    storage_dir = base_dir / "storage"
    if storage_dir.exists():
        search_roots.append(storage_dir)

    candidates: list[tuple[int, float, Path]] = []
    metadata_patterns = ["metadata.json", "*_metadata.json"]
    for root in search_roots:
        for pattern in metadata_patterns:
            for metadata_path in root.rglob(pattern):
                candidate = metadata_path.parent
                if has_required_files(candidate):
                    score, mtime = score_candidate(candidate, metadata_path)
                    candidates.append((score, mtime, candidate))

    if candidates:
        candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
        best = candidates[0][2]
        print(f"Selected data directory: {best}")
        return best

    raise FileNotFoundError(
        "Could not locate a debug capture folder containing metadata.json and *.dng. "
        "Place verify_pipeline.py next to the capture or run it from that folder."
    )


def illuminant_entry(value: Optional[int]) -> Optional[tuple[str, float]]:
    if value is None:
        return None
    entry = ILLUMINANT_INFO.get(int(value))
    if entry is None:
        return None
    name, cct = entry
    if cct is None:
        return None
    return name, cct


def calibration_illuminant(metadata: dict, index: int) -> Optional[tuple[str, float]]:
    keys = [
        f"calibrationIlluminant{index}",
        f"referenceIlluminant{index}",
        f"sensorReferenceIlluminant{index}",
    ]
    for key in keys:
        info = illuminant_entry(metadata.get(key))
        if info is not None:
            return info
    return None


def infer_color_plane_count(metadata: dict) -> int:
    values = metadata.get("colorMatrix1")
    if values is None:
        raise ValueError("colorMatrix1 is required to infer color plane count.")
    arr = np.asarray(values, dtype=np.float64).reshape(-1)
    if arr.size % 3 != 0:
        raise ValueError("colorMatrix1 does not have a multiple of 3 entries.")
    return arr.size // 3


def matrix_from_metadata(metadata: dict, key: str, rows: int, cols: int) -> Optional[np.ndarray]:
    values = metadata.get(key)
    if values is None:
        return None
    arr = np.asarray(values, dtype=np.float64).reshape(-1)
    if arr.size != rows * cols:
        return None
    return arr.reshape(rows, cols)


def get_analog_balance(metadata: dict, color_planes: int) -> np.ndarray:
    values = metadata.get("analogBalance") or metadata.get("AnalogBalance")
    diag = np.ones(color_planes, dtype=np.float64)
    if values:
        arr = np.asarray(values, dtype=np.float64).reshape(-1)
        count = min(color_planes, arr.size)
        diag[:count] = arr[:count]
    return np.diag(diag)


def get_camera_neutral(metadata: dict, color_planes: int) -> np.ndarray:
    values = metadata.get("asShotNeutral")
    if not values or len(values) < color_planes:
        raise ValueError("asShotNeutral is missing or has insufficient entries.")
    arr = np.asarray(values[:color_planes], dtype=np.float64)
    return arr


def xy_to_cct(x: float, y: float) -> Optional[float]:
    denom = 0.1858 - y
    if abs(denom) < 1e-9:
        return None
    n = (x - 0.3320) / denom
    cct = 449.0 * n**3 + 3525.0 * n**2 + 6823.3 * n + 5520.33
    if cct <= 0:
        return None
    return float(cct)


def camera_neutral_to_xy(camera_neutral: list[float], color_matrix: list[list[float]]) -> Optional[tuple[float, float]]:
    if len(camera_neutral) < 3:
        return None
    cam = np.asarray(camera_neutral[:3], dtype=np.float64)
    matrix = np.asarray(color_matrix, dtype=np.float64)
    try:
        xyz = np.linalg.solve(matrix, cam)
    except np.linalg.LinAlgError:
        return None
    denom = np.sum(xyz)
    if abs(denom) < 1e-9:
        return None
    xyz = xyz / denom
    x, y = float(xyz[0]), float(xyz[1])
    if x <= 0 or y <= 0:
        return None
    return x, y


def gather_calibration_sets(metadata: dict) -> tuple[int, list[dict]]:
    color_planes = infer_color_plane_count(metadata)
    calibrations = []
    for idx in (1, 2, 3):
        cm = matrix_from_metadata(metadata, f"colorMatrix{idx}", color_planes, 3)
        if cm is None:
            continue
        illuminant = calibration_illuminant(metadata, idx)
        if illuminant is None:
            continue
        name, cct = illuminant
        cc = matrix_from_metadata(metadata, f"cameraCalibration{idx}", color_planes, color_planes)
        if cc is None:
            cc = np.eye(color_planes, dtype=np.float64)
        rm = matrix_from_metadata(metadata, f"reductionMatrix{idx}", 3, color_planes)
        fm = matrix_from_metadata(metadata, f"forwardMatrix{idx}", 3, color_planes)
        calibrations.append(
            {
                "index": idx,
                "name": name,
                "cct": cct,
                "color_matrix": cm,
                "camera_calibration": cc,
                "reduction_matrix": rm,
                "forward_matrix": fm,
            }
        )
    if not calibrations:
        raise ValueError("No calibration matrices with illuminant data were found.")
    calibrations.sort(key=lambda entry: entry["cct"])
    return color_planes, calibrations


def blend_matrices(low: Optional[np.ndarray], high: Optional[np.ndarray], weight: float) -> Optional[np.ndarray]:
    if low is None and high is None:
        return None
    if high is None or np.isclose(weight, 0.0):
        return np.array(low, dtype=np.float64) if low is not None else None
    if low is None or np.isclose(weight, 1.0):
        return np.array(high, dtype=np.float64) if high is not None else None
    return (1.0 - weight) * low + weight * high


def select_calibration_pair(calibrations: list[dict], cct: Optional[float]) -> tuple[dict, dict, float]:
    if len(calibrations) == 1 or cct is None:
        return calibrations[0], calibrations[0], 0.0
    if cct <= calibrations[0]["cct"]:
        return calibrations[0], calibrations[0], 0.0
    if cct >= calibrations[-1]["cct"]:
        return calibrations[-1], calibrations[-1], 0.0
    for idx in range(len(calibrations) - 1):
        low = calibrations[idx]
        high = calibrations[idx + 1]
        if low["cct"] <= cct <= high["cct"]:
            denom = (1.0 / high["cct"]) - (1.0 / low["cct"])
            if abs(denom) < 1e-9:
                weight = 0.0
            else:
                weight = ((1.0 / cct) - (1.0 / low["cct"])) / denom
            return low, high, float(np.clip(weight, 0.0, 1.0))
    return calibrations[-2], calibrations[-1], 1.0


def interpolate_color_matrices(metadata: dict) -> tuple[str, list[list[float]], dict]:
    color_planes, calibrations = gather_calibration_sets(metadata)
    analog_balance = get_analog_balance(metadata, color_planes)
    camera_neutral = get_camera_neutral(metadata, color_planes)

    initial_xy = None
    for cal in calibrations:
        initial_xy = camera_neutral_to_xy(camera_neutral.tolist(), cal["color_matrix"].tolist())
        if initial_xy is not None:
            break
    if initial_xy is None:
        initial_xy = (0.3127, 0.3290)
    xy = np.asarray(initial_xy, dtype=np.float64)

    final_low = calibrations[0]
    final_high = calibrations[-1]
    final_weight = 0.0
    cct_estimate = None
    for _ in range(10):
        cct_estimate = xy_to_cct(float(xy[0]), float(xy[1]))
        low, high, weight = select_calibration_pair(calibrations, cct_estimate)
        color_matrix = blend_matrices(low["color_matrix"], high["color_matrix"], weight)
        camera_calibration = blend_matrices(low["camera_calibration"], high["camera_calibration"], weight)
        if color_matrix is None or camera_calibration is None:
            raise ValueError("Unable to blend calibration matrices.")
        xyz_to_camera = analog_balance @ camera_calibration @ color_matrix
        pseudo_inv = np.linalg.pinv(xyz_to_camera)
        xyz = pseudo_inv @ camera_neutral
        denom = np.sum(xyz)
        if abs(denom) < 1e-9:
            break
        new_xy = np.asarray([xyz[0] / denom, xyz[1] / denom], dtype=np.float64)
        final_low, final_high, final_weight = low, high, float(weight)
        if np.linalg.norm(new_xy - xy) < 1e-6:
            xy = new_xy
            break
        xy = new_xy

    blended_matrix = blend_matrices(final_low["color_matrix"], final_high["color_matrix"], final_weight)
    if blended_matrix is None:
        raise ValueError("Failed to compute interpolated color matrix.")
    info = {
        "white_cct": cct_estimate,
        "low_temp": final_low["cct"],
        "high_temp": final_high["cct"],
        "low_name": final_low["name"],
        "high_name": final_high["name"],
        "weight": final_weight,
    }
    return "colorMatrix_interpolated", blended_matrix.tolist(), info


def reshape_matrix(values) -> Optional[list[list[float]]]:
    if values is None:
        return None
    arr = np.asarray(values, dtype=np.float32).reshape(-1)
    if arr.size != 9:
        return None
    reshaped = arr.reshape(3, 3)
    return [[float(val) for val in row] for row in reshaped]


def ensure_black_level_list(values) -> list[float]:
    if values is None:
        return [0.0, 0.0, 0.0, 0.0]
    if isinstance(values, (int, float)):
        return [float(values)] * 4
    result = list(values)
    if len(result) == 1:
        result *= 4
    if len(result) < 4:
        result = (result * 4)[:4]
    return [float(v) for v in result[:4]]


def wb_gains_from_as_shot(as_shot) -> Optional[dict]:
    if not as_shot or len(as_shot) < 3:
        return None
    safe = [max(float(v), 1e-6) for v in as_shot[:3]]
    inv = [1.0 / v for v in safe]
    g = inv[1]
    return {"r": inv[0], "g": g, "b": inv[2], "gEven": g, "gOdd": g}


def compute_wb_gains(metadata: dict) -> dict:
    from_as_shot = wb_gains_from_as_shot(metadata.get("asShotNeutral"))
    if from_as_shot is not None:
        return from_as_shot
    wb = metadata.get("wbGains")
    if wb:
        return wb
    cc_gains = metadata.get("colorCorrectionGains")
    if cc_gains and len(cc_gains) >= 4:
        r, g_even, g_odd, b = [float(v) for v in cc_gains[:4]]
        g = 0.5 * (g_even + g_odd)
        return {"r": r, "g": g, "b": b, "gEven": g_even, "gOdd": g_odd}
    return {"r": 1.0, "g": 1.0, "b": 1.0, "gEven": 1.0, "gOdd": 1.0}


def normalize_metadata(metadata: dict) -> dict:
    normalized = {}
    width = metadata.get("width") or metadata.get("rawWidth") or metadata.get("activeArrayWidth")
    height = metadata.get("height") or metadata.get("rawHeight") or metadata.get("activeArrayHeight")
    if width:
        normalized["width"] = int(width)
    if height:
        normalized["height"] = int(height)
    normalized["whiteLevel"] = float(metadata.get("whiteLevel", 1023))
    normalized["blackLevel"] = ensure_black_level_list(metadata.get("blackLevel") or metadata.get("blackLevelPattern"))
    normalized["wbGains"] = compute_wb_gains(metadata)
    return normalized


def collect_ccm_variants(metadata: dict) -> list[tuple[str, list[list[float]]]]:
    if "ccm" in metadata:
        return [("ccm", metadata["ccm"])]
    ccm_keys = [
        "colorCorrectionTransform",
        "colorMatrix1",
        "colorMatrix2",
        "forwardMatrix1",
        "forwardMatrix2",
        "sensorColorTransform1",
        "sensorColorTransform2",
        "sensorForwardMatrix1",
        "sensorForwardMatrix2",
        "sensorCalibrationTransform1",
        "sensorCalibrationTransform2",
    ]
    variants = []
    seen = set()
    for key in ccm_keys:
        matrix = reshape_matrix(metadata.get(key))
        if matrix is None:
            continue
        flat = tuple(val for row in matrix for val in row)
        if flat in seen:
            continue
        seen.add(flat)
        variants.append((key, matrix))
    if not variants:
        raise ValueError("No CCM matrices found in metadata.")
    return variants


def load_metadata(metadata_path: Path) -> dict:
    with metadata_path.open("r", encoding="utf-8") as fp:
        return json.load(fp)


def find_dng_file(data_dir: Path) -> Path:
    dng_candidates = sorted(
        list(data_dir.glob("*.dng")) + list(data_dir.glob("*.DNG"))
    )
    if not dng_candidates:
        raise FileNotFoundError(f"No DNG file found in {data_dir}")
    if len(dng_candidates) > 1:
        print(f"Multiple DNG files found, using {dng_candidates[0].name}")
    return dng_candidates[0]


def subtract_black_level(raw: np.ndarray, black_levels: list, white_level: float) -> np.ndarray:
    black_avg = float(np.mean(np.asarray(black_levels, dtype=np.float32)))
    denom = max(white_level - black_avg, 1e-6)
    normalized = (raw - black_avg) / denom
    return np.clip(normalized, 0.0, 1.0)


def interpolate_plane(values: np.ndarray, mask: np.ndarray) -> np.ndarray:
    kernel = np.array([[1, 2, 1], [2, 4, 2], [1, 2, 1]], dtype=np.float32)
    filtered = cv2.filter2D(values, -1, kernel, borderType=cv2.BORDER_REFLECT)
    weights = cv2.filter2D(mask.astype(np.float32), -1, kernel, borderType=cv2.BORDER_REFLECT)
    weights = np.maximum(weights, 1e-6)
    return filtered / weights


def demosaic_bilinear(mosaic: np.ndarray, pattern: str = "RGGB") -> np.ndarray:
    h, w = mosaic.shape
    pattern = pattern.upper()
    if len(pattern) != 4 or any(ch not in "RGB" for ch in pattern):
        raise ValueError(f"Unsupported CFA pattern: {pattern}")

    pattern_grid = np.array(list(pattern)).reshape(2, 2)
    masks = {color: np.zeros((h, w), dtype=bool) for color in "RGB"}
    for row in range(2):
        for col in range(2):
            color = pattern_grid[row, col]
            masks[color][row::2, col::2] = True

    channels = []
    for key in ("R", "G", "B"):
        samples = np.zeros_like(mosaic, dtype=np.float32)
        samples[masks[key]] = mosaic[masks[key]]
        interpolated = interpolate_plane(samples, masks[key])
        filled = np.where(masks[key], samples, interpolated)
        channels.append(filled)

    rgb = np.stack(channels, axis=-1)
    return np.clip(rgb, 0.0, 1.0)


def apply_white_balance(rgb: np.ndarray, wb_gains: dict) -> np.ndarray:
    gains = {k: float(v) for k, v in wb_gains.items()}
    r_gain = gains.get("r", 1.0)
    g_gain = gains.get("g", (gains.get("gEven", 1.0) + gains.get("gOdd", 1.0)) * 0.5)
    b_gain = gains.get("b", 1.0)
    gain_vec = np.array([r_gain, g_gain, b_gain], dtype=np.float32)
    return rgb * gain_vec


def apply_ccm(rgb: np.ndarray, ccm: list) -> np.ndarray:
    matrix = np.asarray(ccm, dtype=np.float32)
    reshaped = rgb.reshape(-1, 3)
    corrected = reshaped @ matrix.T
    return corrected.reshape(rgb.shape)


def apply_gamma(rgb: np.ndarray, gamma: float = 2.2) -> np.ndarray:
    rgb_clipped = np.clip(rgb, 0.0, 1.0)
    inv_gamma = 1.0 / gamma
    return rgb_clipped ** inv_gamma


def sanitize_color_desc(color_desc_raw) -> str:
    if isinstance(color_desc_raw, bytes):
        color_desc = color_desc_raw.decode("ascii", errors="ignore")
    else:
        color_desc = str(color_desc_raw)
    filtered = "".join(ch for ch in color_desc if ch.upper() in {"R", "G", "B"})
    return filtered or "RGBG"


def load_dng_mosaic(dng_path: Path) -> tuple[np.ndarray, str]:
    with rawpy.imread(str(dng_path)) as raw:
        mosaic = raw.raw_image_visible.astype(np.float32)
        color_desc = sanitize_color_desc(raw.color_desc)
        pattern_indices = raw.raw_pattern
        pattern_chars = []
        for idx in pattern_indices.flatten():
            if idx >= len(color_desc):
                raise ValueError(f"CFA pattern index {idx} out of range for color desc '{color_desc}'")
            pattern_chars.append(color_desc[idx])
        pattern = "".join(pattern_chars).upper()

    return mosaic, pattern


def prepare_base_images(dng_path: Path, metadata: dict) -> tuple[np.ndarray, np.ndarray]:
    mosaic, pattern = load_dng_mosaic(dng_path)
    height, width = mosaic.shape
    meta_width = int(metadata.get("width", width))
    meta_height = int(metadata.get("height", height))
    if (meta_height, meta_width) != (height, width):
        print(
            f"Warning: metadata dimensions ({meta_width}x{meta_height}) "
            f"do not match DNG ({width}x{height}); using DNG size."
        )
    normalized = subtract_black_level(mosaic, metadata["blackLevel"], metadata["whiteLevel"])
    stage_black = demosaic_bilinear(normalized, pattern=pattern)
    stage_wb = np.clip(apply_white_balance(stage_black, metadata["wbGains"]), 0.0, 1.0)
    print(f"Using WB gains: {metadata['wbGains']}")
    return stage_black, stage_wb


def build_stages_for_ccm(stage_black: np.ndarray, stage_wb: np.ndarray, ccm: list, label: str) -> list:
    stage_ccm = np.clip(apply_ccm(stage_wb, ccm), 0.0, 1.0)
    stage_gamma = apply_gamma(stage_ccm)
    return [
        ("Black Level", stage_black),
        ("White Balance", stage_wb),
        (f"CCM ({label})", stage_ccm),
        (f"Gamma ({label})", stage_gamma),
    ]


def plot_stages(stages: list, title: Optional[str] = None) -> None:
    titles = [name for name, _ in stages]
    images = [np.clip(img, 0.0, 1.0) for _, img in stages]
    fig, axes = plt.subplots(1, len(images), figsize=(4 * len(images), 4))
    if len(images) == 1:
        axes = [axes]
    for ax, title, img in zip(axes, titles, images):
        ax.imshow(img)
        ax.set_title(title)
        ax.axis("off")
    fig.suptitle(title or "Full Image ISP Stages")
    plt.tight_layout()
    plt.show()


def plot_ccm_comparison(first_img: np.ndarray, second_img: np.ndarray, info: Optional[dict] = None) -> None:
    diff = np.clip(np.abs(first_img - second_img) * 4.0, 0.0, 1.0)
    fig, axes = plt.subplots(1, 3, figsize=(12, 4))
    axes[0].imshow(np.clip(first_img, 0.0, 1.0))
    axes[0].set_title("Gamma (ColorMatrix1)")
    axes[0].axis("off")
    axes[1].imshow(np.clip(second_img, 0.0, 1.0))
    axes[1].set_title("Gamma (Interpolated)")
    axes[1].axis("off")
    axes[2].imshow(diff)
    axes[2].set_title("Abs Diff x4")
    axes[2].axis("off")
    if info:
        white_cct = info.get("white_cct")
        if white_cct is not None:
            white_text = f"AWB~{white_cct:.0f}K"
        else:
            white_text = "AWB~N/A"
        fig.suptitle(
            f"Interpolated CCM weight={info.get('weight', 0.0):.3f} | "
            f"{white_text} between {info.get('low_name', '?')}({info.get('low_temp', 0):.0f}K) "
            f"and {info.get('high_name', '?')}({info.get('high_temp', 0):.0f}K)"
        )
    plt.tight_layout()
    plt.show()


def slugify(name: str) -> str:
    safe = "".join(ch if ch.isalnum() or ch in ("-", "_") else "_" for ch in name)
    return safe.strip("_").lower() or "ccm"


def save_stage_images(stages: list, output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    for name, img in stages:
        clipped = np.clip(img, 0.0, 1.0)
        img_uint8 = (clipped * 255.0).round().astype(np.uint8)
        bgr = cv2.cvtColor(img_uint8, cv2.COLOR_RGB2BGR)
        slug = name.lower().replace(" ", "_")
        out_path = output_dir / f"stage_{slug}.png"
        cv2.imwrite(str(out_path), bgr)
        print(f"Saved {out_path}")


def main() -> None:
    base_dir = Path(__file__).resolve().parent
    data_dir = locate_data_dir(base_dir)
    print(f"Using data directory: {data_dir}")

    metadata_path = find_metadata_file(data_dir)
    if metadata_path is None:
        raise FileNotFoundError(f"No metadata file found in {data_dir}")
    raw_metadata = load_metadata(metadata_path)
    proc_metadata = normalize_metadata(raw_metadata)
    dng_path = find_dng_file(data_dir)
    print(f"Using DNG file: {dng_path.name}")
    stage_black, stage_wb = prepare_base_images(dng_path, proc_metadata)
    ccm_variants = collect_ccm_variants(raw_metadata)
    interpolation_info = None
    try:
        interp_label, interp_matrix, interpolation_info = interpolate_color_matrices(raw_metadata)
        if all(label != interp_label for label, _ in ccm_variants):
            ccm_variants.append((interp_label, interp_matrix))
        print(
            f"Interpolated CCM computed using weight={interpolation_info['weight']:.3f} "
            f"for AWB~{interpolation_info['white_cct']:.0f}K."
        )
    except ValueError as exc:
        print(f"Unable to compute interpolated CCM: {exc}")
    output_root = data_dir / "pipeline_outputs_full_frame"
    comparison_images = {}
    for label, ccm in ccm_variants:
        print(f"Processing CCM: {label}")
        stages = build_stages_for_ccm(stage_black, stage_wb, ccm, label)
        save_stage_images(stages, output_root / slugify(label))
        if label in {"colorMatrix1", "colorMatrix_interpolated"}:
            plot_stages(stages, title=f"{label} ISP Stages")
            comparison_images[label] = stages[-1][1]
    if interpolation_info and {"colorMatrix1", "colorMatrix_interpolated"} <= comparison_images.keys():
        plot_ccm_comparison(
            comparison_images["colorMatrix1"], comparison_images["colorMatrix_interpolated"], interpolation_info
        )


if __name__ == "__main__":
    main()
