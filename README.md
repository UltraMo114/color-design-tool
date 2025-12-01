# Color Design Tool (Flutter)

A Flutter application for color science and color design workflows. It focuses on:

- Capturing colors from a display or real-world objects (camera + RAW pipeline).
- Exploring and composing colors in sCAM JCh and CIELAB spaces (Colorway).
- Managing a temporary 20-swatch buffer palette with persistence.
- Importing/exporting QTX color library files and searching with Delta E (dE).
- Delegating all color-space math and viewing-conditions logic to the separate core package `colordesign_tool_core`.
This repository contains only the Flutter UI layer and platform bridge code. The core color engine lives in the sibling Dart package `../colordesign_tool_core`.

---

## Features

### 1) Buffer Palette (Home)
Entry: `PaletteScreen` (see `lib/main.dart`).

- 5x4 grid (20 slots). Each slot stores a `ColorStimulus`.
- Tap a slot to inspect details: sCAM Iab, CIELAB Lab, and sRGB.
- App bar actions:
  - Camera Capture: jump to camera screen to sample colors from a Region of Interest (ROI).
  - Colorway: open the sCAM-based color plane tool for color exploration.
  - Import QTX: import colors from QTX/CXF files into the next empty slots.
  - Export QTX: export the current palette to a QTX file in the app documents folder.

### 2) Colorway (sCAM/JCh Planes)
Entry: `lib/screens/colorway_screen.dart`.

- Two picking modes in sCAM/JCh:
  - ab mode: fixed I (perceptual lightness-like); pick on the a-b plane.
  - L-C mode: pick on the J-C plane with a fixed hue.
- Display mapping toggle:
  - sRGB preset display model.
  - Calibrated model using a GOG profile loaded from `assets/display_gog_model.csv`.
- On each tap, the app computes JCh -> XYZ -> sRGB, shows JCh and sRGB HEX in a side panel, and lets you push the color into the next empty palette slot.
- Out-of-gamut swatches are shown in gray as a quick visual hint.

### 3) Camera Capture (Android)
Entry: `lib/screens/camera_capture_screen.dart`.

- Uses Android Camera2 via a `MethodChannel` bridge.
- Captures JPEG + RAW buffers; user draws an ROI on the preview.
- Native processor applies black/white level, white balance, and a 3x3 CCM to convert RAW ROI to XYZ.
- Flutter converts XYZ to Lab/sCAM (via `colordesign_tool_core`) and constructs a `ColorStimulus`.
- With a configurable Delta E threshold, either replaces the closest slot or pushes to the next empty slot. Palette is persisted after updates.
- Planned UI improvements and the ROI tooling are documented in `CAMERA_ROI_UI_PLAN.md`.
- Uses Android Camera2 via a `MethodChannel` bridge.
- Captures JPEG + RAW buffers; user draws an ROI on the preview.
- RAW pipeline: average ROI over RAW16 (black-level subtract, white-level normalize), apply per-capture WB, then a 3x3 CCM (from `COLOR_CORRECTION_TRANSFORM` or a default static matrix) to XYZ.
- JPEG pipeline: crop ROI from JPEG, average sRGB → inverse gamma → linear → sRGB→XYZ.
- Flutter converts XYZ to Lab/sCAM (via `colordesign_tool_core`) and constructs a `ColorStimulus`.
- With a configurable Delta E threshold, either replaces the closest slot or pushes to the next empty slot. Palette is persisted after updates.
- Metadata keys used by the native layer are centralized in `android/app/src/main/kotlin/com/example/color_design_tool/camera/MetadataKeys.kt`.

### 4) Display Calibration Helper
Entry: `lib/screens/display_calibration_screen.dart`.

- Loads 96 RGB patches from `assets/rgb96.csv` and shows them full-screen.
- Supports fixed screen brightness for consistent measurements.
- Produces a calibrated GOG model (CSV) that Colorway can use for the Calibrated mapping.

### 5) QTX Import/Export and Library Search

- Import: parse `.qtx`/`.cxf`/`.cxf3`/`.txt` via core I/O helpers and fill next empty slots.
- Export: write non-empty palette slots to a QTX file in the app documents folder.
- Search: `ColorLibraryService` loads preset QTX files from `../ColorDesignTool/preset_qtx`, computes CIELAB dE76 against a target, and returns matches sorted by distance.

---

## Architecture

- UI layer (this repo): Flutter widgets, routing, and platform channels.
- State layer (Providers): wraps palette state, persistence, and calls into the core engine.
- Core engine (`../colordesign_tool_core`): pure Dart package with models, algorithms, state, and I/O. No Flutter dependency.

For background and design notes, see `../docs`:
- `UI_Migration_Architecture.md`
- `Core_Migration_Architecture.md`
- `CodeDesignTool_Core_Documentation.md`
- `Work_Summary_2025-09-05.md`

---

## Requirements

- Dart SDK: `^3.8.1`
- Flutter packages used in this app:
  - `flutter`, `provider`, `vector_math`
  - `file_picker`, `path`, `path_provider`
  - `hive`, `hive_flutter`
  - local path dependency: `colordesign_tool_core` (at `../colordesign_tool_core`)

Platform notes:
- Android: camera + RAW pipeline currently implemented here.
- Desktop/Web: palette and Colorway work; camera features may be limited or unavailable.

---

## Quick Start

```bash
# Clone
git clone https://github.com/UltraMo114/color-design-tool-.git
cd color-design-tool-

# Ensure the sibling core package exists
#   ../colordesign_tool_core

# Install deps
flutter pub get

# Run on a connected Android device or emulator
flutter run
```

If you want the camera/RAW pipeline, use a real device with USB debugging enabled and grant camera/storage permissions.

---

## Project Layout (short)

```
lib/
  main.dart                   # Entry point; providers and PaletteScreen
  providers/
    palette_provider.dart     # Buffer palette state, dE matching, QTX import/export
  screens/
    colorway_screen.dart      # sCAM JCh / Lab plane tool
    camera_capture_screen.dart# Camera ROI capture and processing
    display_calibration_screen.dart # Display calibration helper
    color_library_search_screen.dart # QTX library dE search
  services/
    color_library_service.dart# Preset QTX loading and search
    native_camera_channel.dart# Flutter <-> Android Camera2 channel
    persistence.dart          # Palette persistence
assets/
  rgb96.csv                   # Display calibration patches
  display_gog_model.csv       # Example calibrated display model
```

---

## Known Limitations / Roadmap

- Camera/RAW pipeline is Android-first; other platforms may need alternative implementations.
- Absolute XYZ and luminance calibration are in progress; current focus is chromatic consistency.
- Colorway and camera UI are evolving (see `CAMERA_ROI_UI_PLAN.md`).
- The core package is local-only and not published on pub.dev.

---

## License

No public license is declared. All rights reserved. Contact the repository owner for usage inquiries.
---

## Requirements

- Dart SDK: `^3.8.1`
- Flutter packages used in this app:
  - `flutter`, `provider`, `vector_math`
  - `file_picker`, `path`, `path_provider`
  - `hive`, `hive_flutter`
  - local path dependency: `colordesign_tool_core` (at `../colordesign_tool_core`)

Platform notes:
- Android: camera + RAW pipeline currently implemented here.
- Desktop/Web: palette and Colorway work; camera features may be limited or unavailable.

---

## Quick Start

```bash
# Clone
git clone https://github.com/UltraMo114/color-design-tool-.git
cd color-design-tool-

# Ensure the sibling core package exists
#   ../colordesign_tool_core

# Install deps
flutter pub get

# Run on a connected Android device or emulator
flutter run
```

If you want the camera/RAW pipeline, use a real device with USB debugging enabled and grant camera/storage permissions.

---

## Project Layout (short)

```
lib/
  main.dart                   # Entry point; providers and PaletteScreen
  providers/
    palette_provider.dart     # Buffer palette state, dE matching, QTX import/export
  screens/
    colorway_screen.dart      # sCAM JCh / Lab plane tool
    camera_capture_screen.dart# Camera ROI capture and processing
    display_calibration_screen.dart # Display calibration helper
    color_library_search_screen.dart # QTX library dE search
  services/
    color_library_service.dart# Preset QTX loading and search
    native_camera_channel.dart# Flutter <-> Android Camera2 channel
    persistence.dart          # Palette persistence
assets/
  rgb96.csv                   # Display calibration patches
  display_gog_model.csv       # Example calibrated display model
```

---

## Known Limitations / Roadmap

- Camera/RAW pipeline is Android-first; other platforms may need alternative implementations.
- Absolute XYZ and luminance calibration are in progress; current focus is chromatic consistency.
- Colorway and camera UI are evolving (see `CAMERA_ROI_UI_PLAN.md`).
- The core package is local-only and not published on pub.dev.

---

## License

No public license is declared. All rights reserved. Contact the repository owner for usage inquiries.
