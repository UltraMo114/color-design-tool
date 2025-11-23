# ColorWay Camera & Palette Notes

## 1. Dependencies

### Flutter / Dart
| Package | Purpose |
| --- | --- |
| `flutter`, `cupertino_icons` | UI framework |
| `provider` | State management (`PaletteProvider`) |
| `vector_math` | Lab/XYZ operations |
| `file_picker`, `path`, `path_provider` | Import/export QTX, path utilities |
| `colordesign_tool_core` (local) | Provides `ColorStimulus`, SCAM conversions, persistence helpers |

### Android / Kotlin
| Component | Purpose |
| --- | --- |
| `Camera2 API` | RAW + JPEG capture (`NativeCameraCaptureActivity`) |
| `ImageReader (JPEG, RAW_SENSOR)` | Dual-buffer outputs |
| `DngCreator` | Writes DNG with metadata |
| `RawRoiProcessor` | Reads RAW plane, applies black/white level, AsShotNeutral, color matrix |
| `MethodChannel` `color_camera` | Flutter ↔︎ Android bridge for `startCapture`, `processRoi` |

### Files / Storage
| Type | Location |
| --- | --- |
| Captured JPEG / DNG / RAW buffer | `getExternalFilesDir(Environment.DIRECTORY_PICTURES)/colorway_camera/` |
| Palette persistence | App documents via `PaletteStorage` (Hive-like JSON) |
| QTX import/export | Manual file dialog; stored under app doc dir |

## 2. Current I/O Pipelines

### Camera Capture → Palette
1. Flutter `CameraCaptureScreen` calls `startCapture`.
2. Android captures JPEG + DNG + RAW buffer, bundles metadata (strides, black level, color matrices).
3. User draws ROI -> Flutter calls `processRoi`.
4. `RawRoiProcessor` maps normalized ROI → raw pixels, averages RGGB, applies AsShotNeutral and color matrix to produce XYZ.
5. Flutter converts XYZ → Lab → `ColorStimulus`, checks ΔE threshold, overwrites nearest slot or pushes to next empty slot.
6. Palette grid + attribute card update immediately; data persisted to disk.

### QTX Import
1. File picker returns path.
2. `PaletteProvider.importQtx` uses `colordesign_tool_core` parser to read stimuli.
3. Colors are inserted sequentially into next empty buffer slots; persisted afterwards.

### QTX Export
1. Collect non-empty slots → `saveStimuliToQtx`.
2. File saved under app document directory, path surfaced via SnackBar.

## 3. Compute Walkthrough Example
```
// Given ROI normalized rect from Flutter
Raw plane -> clamp ROI (Rect)
           -> subtract black level, normalize by white level
           -> average RGGB channels per CFA pattern
           -> apply AsShotNeutral (RGB / neutral)
           -> multiply by color matrix (3×3) -> XYZ
Flutter    -> Vector3(x,y,z)
           -> lab = xyzToLab(...)
           -> stimulus = labToColorstimulus(lab: lab)
           -> PaletteProvider.add/replace slot
```

## 4. TODO / Future Pipeline Work
| Area | Description |
| --- | --- |
| Absolute XYZ | Incorporate DNG `ColorMatrix + ForwardMatrix + AsShotNeutral` via full spec (currently fallback to `colorCorrectionTransform`). Calibrate with exposure parameters for true luminance. |
| RAW demosaic | Current processor averages RGGB without demosaicing; investigate using NDK / libraw for improved detail / lens shading correction. |
| ROI UI upgrades | Implement ROI tool toggle (rectangle/point), ΔE slider UI, palette preview on capture screen (per `CAMERA_ROI_UI_PLAN.md`). |
| Palette attribute card extensions | Add viewing condition selector, manual overrides, and link back to Colorway screen. |
| Testing harness | Add integration tests for MethodChannel flows and palette persistence. |
