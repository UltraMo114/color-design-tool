# Camera Capture UI & Pipeline Update Plan

## 1. 目标概述
- 将 `CameraCaptureScreen` 打造成可连续取色的工作面板：用户无需返回 Colorway 页面即可完成多次 ROI 捕获。
- 引入 `ΔE` 阈值匹配：当测得颜色与现有 Buffer Palette 某一色块相近时自动覆盖；否则写入下一个空槽。
- 支持两种 ROI 工具（矩形 / 单点滴管），满足快速采样需求。
- 在相机页直接展示当前 Palette 以及最近一次测色信息，方便比对与调试。

## 2. UI 布局调整
### 顶部
- 保持现有 `AppBar(title + Capture 按钮)`，按需增加处理状态提示（如正在捕获/正在处理）。

### 预览区域
- Texture/JPEG 缩略图保持不变。
- 叠加 ROI 工具按钮（ToggleButtons 或 SegmentedControl）：
  - `Rectangle`：沿用拖拽矩形的交互。
  - `Spot`：单击即生成固定大小（如 5% 宽 × 5% 高）的 ROI，可选“自动确认”模式。

### 底部面板
1. **ROI 控件栏**
   - 工具切换（矩形 / 单点）。
   - `ΔE` 滑杆（范围 0–5，默认 1.5），旁边显示 `ΔE ≤ X.X`。
2. **信息卡**
   - JPEG / DNG / RAW buffer 路径。
   - Metadata 摘要（raw 尺寸、CFA、白电平等）。
   - 最近一次 XYZ / RawRect。
3. **Palette Grid**
   - 复用 `_MiniPalette`（5×4），可点击高亮。
   - 视图中标识当前匹配/覆盖的槽位。
4. **操作按钮**
   - `Confirm ROI & Process` 显示 loading 状态。
   - 提示信息改为 SnackBar（“Matched slot #3 (ΔE 1.2)” 或 “Added to slot #5”）。

## 3. 交互逻辑
1. **捕获**
   - `Capture` 返回 JPEG+DNG+RAW；界面 reset ROI、清空最近一次结果。
2. **ROI**
   - 矩形模式：拖动-确认。
   - 单点模式：点击即生成固定 ROI，可配置“自动确认”触发。
3. **ΔE 匹配**
   - `_confirmRoi` 流程：
     1. 调 JNI `processRoi` 获得 XYZ。
     2. 转 Lab → `PaletteProvider.findClosestByDeltaE`。
     3. 若 ΔE ≤ slider，则调用 `replaceColorAt(slot, stimulus)`；否则 `addStimulusToNextEmpty`。
     4. 若 palette 已满，则提示“Remove a swatch…”。
4. **反馈**
   - 更新 `_lastXyz`/`_lastRawRect`；
   - SnackBar 显示结果；Palette grid 高亮被覆盖/新增的槽位。

## 4. PaletteProvider 扩展
```dart
class PaletteProvider extends ChangeNotifier {
  PaletteMatch? findClosestByDeltaE(Vector3 lab, double threshold);
  void replaceColorAt(int position, ColorStimulus stimulus);
}

class PaletteMatch {
  final int index;
  final double deltaE;
}
```
- `findClosestByDeltaE` 使用 ΔE76（`sqrt(dl² + da² + db²)`）。
- `replaceColorAt` 更新 buffer + 持久化 + `notifyListeners()`。

## 5. 实施步骤
1. **数据层**：完成 `PaletteProvider` 的 ΔE/替换接口（若尚未合入）。
2. **UI**：在 `CameraCaptureScreen` 中完成工具栏、滑杆、Palette grid、loading button。
3. **逻辑**：实现 `RoiToolMode`、单点 ROI、`_confirmRoi(autoTriggered)`、ΔE 匹配/覆盖。
4. **测试**：
   - 多次捕获 / 连续 ROI；
   - Palette 满/空的提示；
   - ΔE slider 边界值；
   - 单点模式自动确认与普通确认流程。

## 6. 后续展望
- 若需要绝对 XYZ，对接曝光标定或色卡校准。
- Palette grid 可扩展为“点击查看详情 / 删除”的迷你面板。
- 支持批量导出相机捕获记录，便于实验室验证。
