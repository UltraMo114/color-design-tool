# Color Design Tool (Flutter)

Color Design Tool 是一个面向色彩科学与工业测色场景的 Flutter 应用，用于：

- 从显示器或实物采集颜色（相机 + RAW 管线）；
- 在 sCAM JCh / CIELAB 空间中浏览和设计色彩组合（Colorway）；
- 管理临时 20 色调色板（Buffer Palette），支持持久化；
- 与 QTX 色彩库文件进行导入 / 导出以及 ΔE 匹配搜索；
- 依托独立的核心引擎 package colordesign_tool_core 完成所有色彩空间和观看条件计算。

该仓库只包含 Flutter UI 层和与平台相关的桥接代码，核心色彩引擎位于同级目录的 Dart 包 colordesign_tool_core/ 中。

---

## 功能概览

### 1. Buffer Palette 主界面

入口是 PaletteScreen（见 lib/main.dart）：

- 20 格 5×4 调色板网格：
  - 每个格子存储一个 ColorStimulus（来自核心库）。
  - 支持点击选择，查看详细属性（sCAM Iab、CIELAB Lab、sRGB）。
- 顶部工具栏：
  - **Camera Capture**：进入相机采样界面，从实物 ROI 采集颜色。
  - **Colorway**：进入色彩平面设计器，在 sCAM 空间中探索色彩。
  - **Import QTX**：从 QTX / CXF 文件导入色库到当前 Palette。
  - **Export QTX**：将当前 Palette 导出为 QTX 文件。

### 2. Colorway 色彩平面

入口：ColorwayScreen（lib/screens/colorway_screen.dart）。主要功能：

- 提供两种模式在 sCAM / JCh 空间中选色：
  - **ab 模式**：固定 I（类似感知亮度），在 a–b 平面上取色；
  - **L-C 模式**：在 J–C（亮度–色度）平面上取色，并固定 hue；
- 支持切换显示映射：
  - sRGB 预设显示模型；
  - Calibrated：使用经过 GOG 标定的显示模型（来自 CSV）。
- 每次点击平面：
  - 计算对应的 JCh / XYZ / sRGB；
  - 在右下角 _ScamPanel 展示该点的 JCh 参数与 sRGB HEX；
- 点击 **Push** 按钮：
  - 将当前选中的颜色转换为 ColorStimulus；
  - 通过 PaletteProvider.addStimulusToNextEmpty 推入下一个空的 Palette 槽位。

### 3. Camera Capture 相机采样

入口：CameraCaptureScreen（lib/screens/camera_capture_screen.dart）。主要流程：

1. 使用 Android 原生 Camera2 管线采集 JPEG + RAW（通过 NativeCameraChannel MethodChannel 与 Kotlin 交互）。
2. 用户在预览图上选择 ROI（矩形 / 单点模式，规划见 CAMERA_ROI_UI_PLAN.md）。
3. 原生层 RawRoiProcessor：
   - 从 RAW 缓冲区中截取 ROI；
   - 做黑电平 / 白电平校正与白平衡；
   - 使用 3×3 CCM（可来自 ROI 目录中的自定义 CSV）转换到 XYZ；
4. Flutter 端：
   - 使用 colordesign_tool_core 的工具函数将 XYZ 转换为 Lab / sCAM；
   - 构造 ColorStimulus，并使用 ΔE 阈值与当前 Palette 匹配：
     - 若附近存在相近色（ΔE <= 阈值），覆盖对应槽位；
     - 否则写入下一个空槽；
   - 结果立刻反映在 Palette 主界面，并持久化。

当前实现细节与 TODO 可参考 PROJECT_DEPLOYMENT_NOTES.md 和 CAMERA_ROI_UI_PLAN.md。

### 4. Display Calibration 显示器标定辅助

入口：DisplayCalibrationScreen（lib/screens/display_calibration_screen.dart）。

- 从 ssets/rgb96.csv 加载一组预定义 RGB 打点（96 patch）；
- 在全屏依次显示这些色块，配合固定亮度模式；
- 用于配合外部仪器，对显示设备进行 GOG / 色度标定；
- 标定后生成的显示模型数据（如 display_gog_model.csv）供 Colorway 等界面使用。

### 5. QTX 色库导入 / 导出与搜索

依赖 colordesign_tool_core 的 qtx_parser.dart 和 ColorLibraryService：

- **导入到 Palette**：
  - 从文件选择器中选择 .qtx / .cxf / .cxf3 / .txt 文件；
  - 使用 createStimuliFromQtx 解析为若干 ColorStimulus；
  - 按顺序填入 Palette 中下一批空槽，自动持久化。
- **Palette 导出为 QTX**：
  - 收集当前 Palette 中所有非空槽位的 ColorStimulus；
  - 通过 saveStimuliToQtx 写入 app 文档目录下的 QTX 文件；
  - 在 UI 中通过 SnackBar 提示导出路径 / 文件名。
- **色库搜索**（ColorLibrarySearchScreen）：
  - 从 ../ColorDesignTool/preset_qtx 路径加载多个预置 QTX 文件；
  - 将目标颜色与库中颜色在 CIELAB 空间中计算 ΔE76；
  - 返回阈值内的匹配列表，并按 ΔE 升序排序展示。

---

## 核心架构

### 分层设计

整体架构遵循 UI 与业务逻辑分离原则：

- **UI 层**（本仓库）：所有 Flutter Widgets、路由与平台通道；
- **状态管理层**（PaletteProvider 等 Provider）：
  - 封装 Palette 状态与持久化；
  - 调用核心引擎 colordesign_tool_core 的 API；
- **核心引擎层**（外部 package colordesign_tool_core）：
  - 不依赖 Flutter，仅包含模型、算法、状态和 I/O；
  - 提供 ColorStimulus、JCh / Lab / sRGB 工厂函数、色彩和谐度计算、QTX 解析等能力。

更多细节可参考同级目录 ../docs：

- UI_Migration_Architecture.md
- Core_Migration_Architecture.md
- CodeDesignTool_Core_Documentation.md
- Work_Summary_2025-09-05.md

---

## 开发环境与依赖

### Flutter / Dart

- Dart SDK: ^3.8.1
- 主要依赖：
  - lutter
  - provider
  - ector_math
  - ile_picker
  - hive / hive_flutter
  - path / path_provider
  - 本地 package：colordesign_tool_core（路径：../colordesign_tool_core）

### 平台要求

- **Android**：当前相机与 RAW 管线在 Android 平台实现；
- **桌面 / Web**：核心调色板和 Colorway 功能可以在支持 Flutter 的其他平台上运行，但相机相关功能可能不可用或需要替代实现。

---

## 快速开始

### 1. 克隆与依赖安装

`ash
# 克隆仓库
git clone https://github.com/UltraMo114/color-design-tool-.git
cd color-design-tool

# 确保同级目录存在核心引擎包
#   ../colordesign_tool_core

# 获取依赖
flutter pub get
`

### 2. 运行应用

`ash
# 运行到已连接的 Android 设备或模拟器
flutter run
`

若需要使用相机/RAW 功能，请在真实设备上开启 USB 调试并授予相机与存储权限。

### 3. 目录结构（简略）

`	ext
lib/
  main.dart                   # 入口，PaletteScreen + Provider 注入
  providers/
    palette_provider.dart     # Buffer Palette 状态管理 + ΔE 匹配 + QTX 导入/导出
  screens/
    colorway_screen.dart      # sCAM JCh / Lab 平面设计器
    camera_capture_screen.dart# 相机采样与 ROI 处理
    display_calibration_screen.dart # 显示器校准模式
    color_library_search_screen.dart # QTX 色库 ΔE 搜索
  services/
    color_library_service.dart# 预置 QTX 库加载与搜索
    native_camera_channel.dart# Flutter ↔︎ Android Camera2 通道
    persistence.dart          # Palette 持久化
assets/
  rgb96.csv                   # 显示器校准用 RGB patch 集
  display_gog_model.csv       # 显示器 GOG 标定结果（示例）
`

---

## 已知限制 & TODO

- 相机与 RAW 管线目前仅在 Android 测试通过，其他平台需要替代实现或关闭相关入口。
- 绝对 XYZ / 亮度的精确标定仍在进行中，当前主要关注色度和相对一致性。
- Colorway 与 Camera Capture UI 仍在迭代中，详见 CAMERA_ROI_UI_PLAN.md 中的后续工作项。
- 没有公开发布到 pub.dev，colordesign_tool_core 以本地路径依赖的形式存在。

---

## 许可证

本项目暂未声明公开许可证，默认保留所有权利。若需在其他项目中使用或引用，请先联系仓库所有者。
