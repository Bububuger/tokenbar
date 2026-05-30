# Mascot Download Animation Implementation

**Created**: 2026-05-31  
**Status**: ✅ Implemented (Pending Manual QA)  
**Priority**: Medium  
**Estimated Effort**: 4-6 hours  
**Actual Effort**: ~2 hours  
**Implementation Report**: [2026-05-31-mascot-animation-report.md](./2026-05-31-mascot-animation-report.md)

## Overview

为 TokenBar 的版本更新下载流程添加吉祥物动画效果,提升用户体验。当用户点击"下载更新"后,吉祥物会从静态挥手状态过渡到动态下载状态,并在下载完成后恢复静态状态。

## Current State

### Existing Infrastructure
- ✅ `UpdateChecker.swift` — 版本检测逻辑已完成
- ✅ `AppUpdateDownloader.swift` — 下载器已实现,支持进度回调
- ✅ `ContentView.swift` — UI 已集成 `@Published updateDownloadState`
- ✅ 吉祥物静态资源 `docs/assets/mascot-wave.png` 已存在

### Missing Components
- ❌ 下载过程中的吉祥物动画视图
- ❌ 下载进度的视觉反馈(进度条/百分比)
- ❌ 状态切换的过渡动画
- ❌ 下载完成/失败的视觉提示

## Design Specification

### 1. Visual States

#### State 1: Idle (静态挥手)
- **触发条件**: 无更新 / 更新检测中 / 下载完成后
- **视觉元素**:
  - 吉祥物图片: `mascot-wave.png`
  - 尺寸: 120×120 pt
  - 位置: 更新提示卡片左侧
  - 动画: 无 (或轻微呼吸效果 scale 0.98-1.02)

#### State 2: Downloading (下载中)
- **触发条件**: `updateDownloadState == .downloading(progress)`
- **视觉元素**:
  - 吉祥物图片: 保持 `mascot-wave.png` (或新增 `mascot-downloading.png`)
  - 动画效果:
    - **方案 A (简单)**: 旋转动画 (360° 循环,2秒/圈)
    - **方案 B (推荐)**: 上下浮动 + 轻微旋转 (±5°,1.5秒周期)
    - **方案 C (高级)**: 帧动画序列 (需要多张图片)
  - 进度指示器:
    - 环形进度条包裹吉祥物 (SwiftUI `ProgressView` 或自定义 `Circle` stroke)
    - 颜色: `.accentColor` (跟随系统主题)
    - 粗细: 4 pt
  - 百分比文本:
    - 位置: 吉祥物下方
    - 字体: `.caption.monospacedDigit()`
    - 格式: "42%"

#### State 3: Completed (下载完成)
- **触发条件**: `updateDownloadState == .completed(localURL)`
- **视觉元素**:
  - 吉祥物: 恢复静态挥手
  - 过渡动画: 弹跳效果 (scale 1.0 → 1.15 → 1.0,0.5秒)
  - 成功提示: 绿色勾选图标叠加在吉祥物右上角
  - 按钮变化: "下载更新" → "安装更新" (打开 Finder)

#### State 4: Failed (下载失败)
- **触发条件**: `updateDownloadState == .failed(message)`
- **视觉元素**:
  - 吉祥物: 恢复静态挥手
  - 失败提示: 红色警告图标叠加在吉祥物右上角
  - 错误信息: 显示在吉祥物下方 (`.caption` 红色文本)
  - 按钮变化: "重试下载"

### 2. Animation Specifications

#### 过渡动画时序
```
Idle → Downloading:
  - Duration: 0.3s
  - Curve: .easeInOut
  - Effects: 
    - 进度环从 0% 淡入
    - 吉祥物开始浮动/旋转

Downloading → Completed:
  - Duration: 0.5s
  - Curve: .spring(response: 0.5, dampingFraction: 0.6)
  - Effects:
    - 进度环淡出
    - 吉祥物弹跳
    - 成功图标从 scale(0) 弹出

Downloading → Failed:
  - Duration: 0.4s
  - Curve: .easeOut
  - Effects:
    - 进度环淡出
    - 吉祥物轻微抖动 (shake)
    - 失败图标淡入
```

#### 循环动画参数 (Downloading 状态)
```swift
// 方案 B (推荐)
Animation.easeInOut(duration: 1.5)
  .repeatForever(autoreverses: true)

// 浮动: offset(y: -8 to +8)
// 旋转: rotationEffect(-5° to +5°)
```

### 3. Layout Structure

```
UpdateNotificationCard
├── HStack
│   ├── MascotDownloadView (NEW)
│   │   ├── ZStack
│   │   │   ├── Image("mascot-wave")
│   │   │   ├── CircularProgressView (conditional)
│   │   │   └── StatusBadge (conditional)
│   │   └── Text (percentage, conditional)
│   └── VStack
│       ├── Text("发现新版本 v1.2.3")
│       ├── Text("更新说明...")
│       └── Button("下载更新" / "安装更新" / "重试")
```

## Implementation Plan

### Phase 1: Core Components (2h)
1. **创建 `MascotDownloadView.swift`**
   - 输入: `updateDownloadState: AppUpdateDownloader.DownloadState`
   - 输出: 根据状态渲染不同视觉效果的 View
   - 位置: `Sources/TokenBar/Views/Components/MascotDownloadView.swift`

2. **实现状态映射逻辑**
   ```swift
   private var mascotState: MascotState {
     switch updateDownloadState {
     case .idle: return .idle
     case .downloading: return .downloading
     case .completed: return .completed
     case .failed: return .failed
     }
   }
   ```

3. **实现静态布局**
   - 吉祥物图片加载
   - 进度环占位
   - 状态图标占位

### Phase 2: Animations (2h)
1. **实现下载中循环动画**
   - 浮动效果 (`offset` modifier)
   - 旋转效果 (`rotationEffect` modifier)
   - 进度环绘制 (`Circle().trim(from:to:)`)

2. **实现状态切换动画**
   - Idle → Downloading 淡入
   - Downloading → Completed 弹跳
   - Downloading → Failed 抖动

3. **添加进度文本动画**
   - 百分比数字平滑过渡 (`AnimatableModifier`)

### Phase 3: Integration (1h)
1. **集成到 `ContentView.swift`**
   - 替换现有的更新提示 UI
   - 传递 `updateDownloadState` 绑定

2. **测试状态切换**
   - 手动触发各状态验证动画

### Phase 4: Polish (1h)
1. **适配暗色模式**
   - 进度环颜色适配
   - 状态图标颜色适配

2. **添加辅助功能支持**
   - VoiceOver 标签
   - 动画减弱模式支持 (`@Environment(\.accessibilityReduceMotion)`)

3. **性能优化**
   - 避免不必要的重绘
   - 使用 `drawingGroup()` 优化复杂动画

## Acceptance Criteria

### Functional Requirements
- [ ] **FR-1**: 点击"下载更新"后,吉祥物立即进入下载动画状态
- [ ] **FR-2**: 下载进度实时反映在环形进度条上 (0-100%)
- [ ] **FR-3**: 下载进度百分比文本实时更新,精确到整数
- [ ] **FR-4**: 下载完成后,吉祥物播放弹跳动画,并显示绿色成功图标
- [ ] **FR-5**: 下载失败后,吉祥物播放抖动动画,并显示红色失败图标
- [ ] **FR-6**: 失败状态下显示错误信息文本
- [ ] **FR-7**: 按钮文本根据状态变化: "下载更新" → "下载中..." → "安装更新" / "重试下载"

### Visual Requirements
- [ ] **VR-1**: 吉祥物尺寸为 120×120 pt,清晰无模糊
- [ ] **VR-2**: 下载动画流畅,帧率 ≥ 30 FPS
- [ ] **VR-3**: 进度环粗细为 4 pt,颜色为系统 accent color
- [ ] **VR-4**: 状态图标尺寸为 24×24 pt,位于吉祥物右上角
- [ ] **VR-5**: 百分比文本使用等宽数字字体,避免跳动
- [ ] **VR-6**: 所有动画支持暗色模式,颜色对比度符合 WCAG AA 标准

### Animation Requirements
- [ ] **AR-1**: Idle → Downloading 过渡时长 0.3s,使用 easeInOut 曲线
- [ ] **AR-2**: 下载中浮动动画周期 1.5s,振幅 ±8 pt
- [ ] **AR-3**: 下载中旋转动画周期 1.5s,角度 ±5°
- [ ] **AR-4**: Downloading → Completed 弹跳动画时长 0.5s,使用 spring 曲线
- [ ] **AR-5**: Downloading → Failed 抖动动画时长 0.4s,使用 easeOut 曲线
- [ ] **AR-6**: 启用"减弱动画"辅助功能时,所有装饰性动画自动禁用

### Performance Requirements
- [ ] **PR-1**: 下载动画运行时 CPU 占用 < 5%
- [ ] **PR-2**: 内存占用增量 < 10 MB
- [ ] **PR-3**: 状态切换响应延迟 < 100ms

### Accessibility Requirements
- [ ] **AC-1**: 吉祥物视图提供 VoiceOver 标签,描述当前状态
- [ ] **AC-2**: 进度变化通过 VoiceOver 实时播报 (每 10% 播报一次)
- [ ] **AC-3**: 启用"减弱动画"时,保留状态切换但移除循环动画
- [ ] **AC-4**: 颜色对比度符合 WCAG AA 标准 (4.5:1)

## Testing Plan

### Manual Testing
1. **正常流程测试**
   - 启动 TokenBar → 触发更新检测 → 点击"下载更新" → 观察动画 → 等待下载完成 → 验证完成状态

2. **边界条件测试**
   - 下载速度极快 (< 1秒完成)
   - 下载速度极慢 (模拟网络限速)
   - 下载中途取消 (如果支持)
   - 下载失败 (断网测试)

3. **视觉回归测试**
   - 浅色模式 vs 暗色模式
   - 不同窗口尺寸
   - 不同系统 accent color

### Automated Testing (Optional)
```swift
// Sources/TokenBarTests/MascotDownloadViewTests.swift
func testStateTransitions() {
  let view = MascotDownloadView(state: .idle)
  // 验证初始状态渲染
  
  view.state = .downloading(progress: 0.5)
  // 验证下载状态渲染
  
  view.state = .completed(localURL: URL(fileURLWithPath: "/tmp/test.dmg"))
  // 验证完成状态渲染
}
```

## Risks & Mitigations

### Risk 1: 动画性能问题
- **影响**: 低端设备上动画卡顿
- **缓解**: 
  - 使用 `drawingGroup()` 优化渲染
  - 提供"简化动画"选项
  - 在 M1 Mac 和 Intel Mac 上分别测试

### Risk 2: 吉祥物图片资源缺失
- **影响**: 无法显示吉祥物
- **缓解**:
  - 提供 fallback 占位符 (SF Symbol `figure.wave`)
  - 在 Asset Catalog 中正确配置图片

### Risk 3: 状态同步延迟
- **影响**: 动画与实际下载进度不同步
- **缓解**:
  - 使用 `@Published` 确保状态实时更新
  - 添加日志验证状态变化时序

## Future Enhancements

1. **多帧动画序列** (v2.0)
   - 设计 3-5 帧的吉祥物下载动作
   - 使用 `AnimatedImage` 或 GIF

2. **音效反馈** (v2.0)
   - 下载完成播放提示音
   - 支持静音模式

3. **自定义吉祥物** (v3.0)
   - 允许用户上传自定义吉祥物图片
   - 提供多套预设主题

4. **下载速度显示** (v2.0)
   - 在百分比下方显示 "2.3 MB/s"
   - 显示剩余时间 "还需 30 秒"

## References

- 现有代码: `Sources/TokenBarCore/Services/AppUpdateDownloader.swift`
- 设计资源: `docs/assets/mascot-wave.png`
- SwiftUI 动画文档: https://developer.apple.com/documentation/swiftui/animation
- 辅助功能指南: https://developer.apple.com/design/human-interface-guidelines/accessibility

---

**Next Steps**:
1. Review this plan with stakeholders
2. Confirm animation style preference (方案 A/B/C)
3. Verify mascot asset availability
4. Create implementation branch: `feature/mascot-download-animation`
5. Begin Phase 1 implementation
