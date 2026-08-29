import SwiftUI
import AVFoundation
import CoreMotion

// MARK: - 主界面

/// 主界面：相机界面与 iPhone 内置相机一致
/// - 大圆形快门 / 视频红色快门
/// - 底部模式条（照片 / 视频）
/// - 单击对焦 + 小太阳调曝光
/// - 双指捏合变焦（变焦环）
/// - 1x / 2x / 5x 变焦预设按钮
/// - 竖滑切换前后摄像头 / 横滑切换模式
/// - 闪光灯 / 手电筒控制
/// - 网格线 / 俯拍水平仪 / 拍照音效开关
/// - 自动拍照浮动面板（点击 ⏱ 弹出）+ 拍照倒计时提示
@MainActor
struct ContentView: View {

    @StateObject private var cameraManager = CameraManager()

    // 自动拍照
    @State private var intervalSeconds: Double = 5.0
    @State private var showAutoPanel = false
    @State private var lastCapturedImage: UIImage?

    // 对焦 / 曝光
    @State private var focusPoint: CGPoint?
    @State private var showFocusUI = false
    @State private var isExposureAdjusting = false
    @State private var exposureStartBias: Float = 0
    @State private var exposureDragOffset: CGFloat = 0
    @State private var panBeganNearFocus = false

    // 变焦
    @State private var showZoomRing = false
    @State private var zoomBase: CGFloat = 1.0
    @State private var displayedZoom: CGFloat = 1.0

    // 快门按压动画
    @State private var shutterPressed = false

    // 相机预览区域的实际尺寸（用于坐标转换）
    @State private var previewSize: CGSize = .zero

    // 网格线 / 水平仪
    @State private var showGrid = false
    @StateObject private var levelMonitor = LevelMonitor()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // 主布局：顶部栏 + 相机预览 + 底部控制（VStack 分隔，不重叠）
                VStack(spacing: 0) {
                    // 1. 顶部栏
                    topBar
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    // 2. 自动拍照面板（展开时位于顶部栏下方）
                    if showAutoPanel {
                        autoCapturePanel
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer().frame(height: 8)
                    }

                    // 3. 相机预览区域（占据中间剩余空间，不延伸到按钮区）
                    ZStack {
                        if cameraManager.isSessionRunning {
                            cameraPreview
                        } else {
                            cameraNotRunningView
                        }

                        // 网格线（九宫格构图辅助）
                        if showGrid {
                            GridView()
                        }

                        // 水平仪（iPhone 原相机水平模式：手机竖立时显示两条竖线，对齐变黄）
                        if levelMonitor.isUpright {
                            LevelIndicatorView(offset: levelMonitor.tiltOffset,
                                               rotationAngle: levelMonitor.rotationAngle,
                                               isLevel: levelMonitor.isLevel)
                                .transition(.opacity)
                        }

                        // 对焦框 + 小太阳（仅在预览区域内）
                        focusOverlay

                        // 变焦环（仅在预览区域内）
                        if showZoomRing {
                            ZoomRingView(zoom: displayedZoom)
                        }

                        // 自动拍照倒计时提示
                        if cameraManager.isAutoCapturing {
                            countdownOverlay
                        }

                        // 获取预览区域尺寸
                        GeometryReader { previewGeo in
                            Color.clear
                                .onAppear {
                                    previewSize = previewGeo.size
                                }
                                .onChange(of: previewGeo.size) { _, newSize in
                                    previewSize = newSize
                                }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    // 4. 底部控制区
                    bottomControls
                        .padding(.bottom, geometry.safeAreaInsets.bottom > 0 ? 8 : 20)
                }
            }
            .onAppear {
                cameraManager.requestPermissionAndConfigure()
                levelMonitor.start()
            }
            .onDisappear {
                levelMonitor.stop()
            }
            .alert("提示", isPresented: Binding(
                get: { cameraManager.errorMessage != nil },
                set: { if !$0 { cameraManager.errorMessage = nil } }
            )) {
                Button("好的") { cameraManager.errorMessage = nil }
            } message: {
                Text(cameraManager.errorMessage ?? "")
            }
            .statusBarHidden(true)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - 相机预览

    private var cameraPreview: some View {
        CameraPreviewView(
            session: cameraManager.captureSession,
            onTap: { handleTap($0) },
            onPanBegan: { handlePanBegan($0) },
            onPanChanged: { handlePanChanged($1) },
            onPanEnded: { handlePanEnded($0) },
            onPinchChanged: { handlePinchChanged($0) },
            onPinchEnded: { handlePinchEnded() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var cameraNotRunningView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            Text("正在启动相机…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 顶部栏

    private var topBar: some View {
        HStack {
            // 闪光灯 / 手电筒
            Button {
                cameraManager.handleFlashButton()
                haptic(.light)
            } label: {
                Image(systemName: flashIconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            .disabled(cameraManager.isUsingFrontCamera && cameraManager.currentMode == .photo)

            // 网格线开关
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showGrid.toggle() }
                haptic(.light)
            } label: {
                Image(systemName: "grid")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(showGrid ? .yellow : .white)
                    .frame(width: 40, height: 40)
            }

            // 拍照音效开关
            Button {
                cameraManager.isMuted.toggle()
                haptic(.light)
            } label: {
                Image(systemName: cameraManager.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(cameraManager.isMuted ? .white.opacity(0.5) : .white)
                    .frame(width: 40, height: 40)
            }

            Spacer()

            // 视频录制指示
            if cameraManager.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text(recordingTimeText)
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            // 自动拍照面板按钮
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    showAutoPanel.toggle()
                }
                haptic(.light)
            } label: {
                Image(systemName: "timer")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            .disabled(cameraManager.isRecording)
        }
    }

    private var flashIconName: String {
        if cameraManager.currentMode == .video {
            return cameraManager.isTorchOn ? "bolt.fill" : "bolt.slash"
        }
        return cameraManager.flash.iconName
    }

    private var recordingTimeText: String {
        let seconds = Int(cameraManager.recordingTime)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - 自动拍照浮动面板

    private var autoCapturePanel: some View {
        VStack(spacing: 14) {
            HStack {
                Label("自动拍照", systemImage: "timer")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showAutoPanel = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.bold())
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.15), in: Circle())
                }
            }

            // 间隔时间设置
            VStack(spacing: 6) {
                HStack {
                    Text("拍照间隔")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(String(format: "%.0f 秒", intervalSeconds))
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                Slider(value: $intervalSeconds, in: 1...60, step: 1)
                    .tint(.orange)
            }

            // 状态
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(cameraManager.isAutoCapturing ? .red : .green)
                        .frame(width: 8, height: 8)
                    Text(cameraManager.isAutoCapturing ? "自动拍照中" : "已就绪")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Text("已拍 \(cameraManager.captureCount) 张")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }

            // 开始 / 结束
            HStack(spacing: 24) {
                Button(action: startAutoCapture) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("开始")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 10)
                    .background(Color.green, in: Capsule())
                }
                .disabled(cameraManager.isAutoCapturing)
                .opacity(cameraManager.isAutoCapturing ? 0.4 : 1.0)

                Button(action: {
                    cameraManager.stopAutoCapture()
                    haptic(.medium)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                        Text("结束")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 10)
                    .background(Color.red, in: Capsule())
                }
                .disabled(!cameraManager.isAutoCapturing)
                .opacity(cameraManager.isAutoCapturing ? 1.0 : 0.4)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .padding(.horizontal, 24)
    }

    // MARK: - 自动拍照倒计时提示

    /// 自动拍照运行时：顶部常驻倒计时胶囊 + 最后 3 秒大数字提醒
    private var countdownOverlay: some View {
        let remaining = cameraManager.secondsUntilNextCapture
        let countNumber = Int(ceil(remaining))
        return ZStack {
            // 顶部常驻：下一张倒计时胶囊
            VStack {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.footnote.bold())
                    Text(remaining >= 1
                         ? String(format: "下一张 %.0f 秒", ceil(remaining))
                         : "即将拍摄…")
                        .font(.footnote.bold())
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
                .padding(.top, 12)

                Spacer()
            }

            // 最后 3 秒：大数字提醒（间隔过短时不再放大字号干扰构图）
            if remaining > 0.01, remaining <= 3.2, intervalSeconds > 3.05 {
                Text("\(max(1, countNumber))")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .id(max(1, countNumber))
                    .transition(.scale(scale: 1.5).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: max(1, countNumber))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: - 底部控制区

    /// 常用变焦预设（原相机风格：1x / 2x / 5x）
    private let zoomPresets: [CGFloat] = [1.0, 2.0, 5.0]

    private var bottomControls: some View {
        VStack(spacing: 0) {
            // 1. 变焦预设按钮（1x / 2x / 5x）
            zoomPresetBar
                .padding(.bottom, 12)

            // 2. 模式条（照片 / 视频）
            modeBar
                .padding(.bottom, 16)

            // 3. 工具行：缩略图 / 快门 / 翻转
            HStack(alignment: .center, spacing: 0) {
                thumbnailButton
                Spacer()
                shutterButton
                Spacer()
                flipButton
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 12)
        .padding(.horizontal, 0)
    }

    /// 变焦预设按钮组（原相机风格）
    /// - 点击直接切换到该焦距
    /// - 当前处于某个预设时，该按钮白色高亮
    /// - 捏合到非预设值（如 3.4x）时，最近的按钮显示实际值
    private var zoomPresetBar: some View {
        HStack(spacing: 24) {
            ForEach(zoomPresets, id: \.self) { preset in
                zoomPresetButton(preset)
            }
        }
    }

    private func zoomPresetButton(_ preset: CGFloat) -> some View {
        let current = cameraManager.currentZoom
        let isExact = abs(current - preset) < 0.15
        let isNearest = zoomPresets.min(by: { abs($0 - current) < abs($1 - current) }) == preset
        // 非预设值时，最近的按钮显示实际倍数（如 3.4x）
        let text = (isNearest && !isExact) ? formatZoom(current) : formatZoom(preset)
        // 当前生效的按钮白色高亮（黑字），其余半透明白底白字
        let isHighlighted = isExact || isNearest

        return Button {
            selectZoomPreset(preset)
        } label: {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isHighlighted ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    isHighlighted ? Color.white : Color.white.opacity(0.22),
                    in: Capsule()
                )
        }
        .animation(.easeInOut(duration: 0.15), value: cameraManager.currentZoom)
    }

    private func formatZoom(_ zoom: CGFloat) -> String {
        zoom.rounded() == zoom
            ? String(format: "%.0fx", zoom)
            : String(format: "%.1fx", zoom)
    }

    /// 切换到预设焦距
    private func selectZoomPreset(_ preset: CGFloat) {
        cameraManager.setZoom(preset)
        displayedZoom = preset
        zoomBase = preset
        haptic(.light)
    }

    /// 模式条：照片 / 视频
    private var modeBar: some View {
        HStack(spacing: 46) {
            ForEach(CameraMode.allCases) { mode in
                let isSelected = cameraManager.currentMode == mode
                Button {
                    selectMode(mode)
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.5))
                        .padding(.vertical, 6)
                }
            }
        }
    }

    /// 最近拍摄缩略图
    private var thumbnailButton: some View {
        Group {
            if let image = lastCapturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.4), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.2))
                    .frame(width: 44, height: 44)
            }
        }
    }

    /// 前后摄像头切换按钮
    private var flipButton: some View {
        Button {
            cameraManager.switchCamera()
            haptic(.light)
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
    }

    /// 快门按钮（照片：白色大圆；视频：红色圆角矩形）
    private var shutterButton: some View {
        Button(action: tapShutter) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 78, height: 78)

                if cameraManager.currentMode == .video {
                    RoundedRectangle(cornerRadius: shutterPressed ? 10 : 8)
                        .fill(.red)
                        .frame(width: cameraManager.isRecording ? 34 : 56,
                               height: cameraManager.isRecording ? 34 : 56)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6),
                                   value: cameraManager.isRecording)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                        .scaleEffect(shutterPressed ? 0.82 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6),
                                   value: shutterPressed)
                }
            }
            .frame(width: 84, height: 84)
            .contentShape(Circle())
        }
        .buttonStyle(ShutterButtonStyle(
            onPressed: { shutterPressed = true },
            onReleased: { shutterPressed = false }
        ))
    }

    // MARK: - 对焦框 + 小太阳

    @ViewBuilder
    private var focusOverlay: some View {
        if showFocusUI, let point = focusPoint {
            ZStack {
                FocusBoxView()
                    .frame(width: 72, height: 72)

                // 小太阳
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: 46, y: -34 + exposureDragOffset)

                // 曝光值标签（调节时显示）
                if isExposureAdjusting {
                    Text(String(format: "EV %+.1f", cameraManager.exposureTargetBias))
                        .font(.caption.bold())
                        .monospacedDigit()
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                        .offset(x: 46, y: -70 + exposureDragOffset)
                }
            }
            .position(point)
            .transition(.scale(scale: 1.4).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }

    // MARK: - 操作方法

    /// 点击对焦
    private func handleTap(_ location: CGPoint) {
        guard cameraManager.isSessionRunning else { return }
        cameraManager.focus(at: convertToDevicePoint(location))
        withAnimation(.easeIn(duration: 0.12)) {
            focusPoint = location
            showFocusUI = true
        }
        haptic(.light)
    }

    /// 视图坐标 → 设备坐标（0~1，y 翻转）
    private func convertToDevicePoint(_ point: CGPoint) -> CGPoint {
        guard previewSize.width > 0, previewSize.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return CGPoint(x: point.x / previewSize.width, y: 1 - point.y / previewSize.height)
    }

    /// 滑动开始：判断是否从对焦框附近开始（用于曝光调节）
    private func handlePanBegan(_ location: CGPoint) {
        panBeganNearFocus = false
        guard showFocusUI, let point = focusPoint else { return }
        let dx = location.x - point.x
        let dy = location.y - point.y
        panBeganNearFocus = (dx * dx + dy * dy) < (100 * 100)
    }

    /// 滑动中：从对焦框附近垂直拖动 → 调节曝光
    private func handlePanChanged(_ translation: CGSize) {
        if panBeganNearFocus && !isExposureAdjusting
            && abs(translation.height) > 14
            && abs(translation.height) > abs(translation.width) {
            isExposureAdjusting = true
            exposureStartBias = cameraManager.exposureTargetBias
        }
        if isExposureAdjusting {
            let delta = Float(-translation.height / 90.0)
            let newBias = min(2.0, max(-2.0, exposureStartBias + delta))
            cameraManager.setExposureTargetBias(newBias)
            exposureDragOffset = translation.height
        }
    }

    /// 滑动结束：横滑切模式 / 竖滑切摄像头
    private func handlePanEnded(_ translation: CGSize) {
        defer {
            isExposureAdjusting = false
            exposureDragOffset = 0
        }
        if isExposureAdjusting { return }
        if panBeganNearFocus { return }

        let dx = translation.width
        let dy = translation.height
        if abs(dx) > 60 && abs(dx) > abs(dy) {
            // 横滑切换模式
            switchMode(direction: dx > 0 ? -1 : 1)
        } else if abs(dy) > 60 {
            // 竖滑切换摄像头
            cameraManager.switchCamera()
            haptic(.medium)
        }
    }

    /// 捏合变焦中
    private func handlePinchChanged(_ scale: CGFloat) {
        let newZoom = min(max(zoomBase * scale, 1.0), cameraManager.maxZoom)
        cameraManager.setZoom(newZoom)
        displayedZoom = newZoom
        if !showZoomRing {
            withAnimation(.easeOut(duration: 0.12)) { showZoomRing = true }
        }
    }

    /// 捏合结束
    private func handlePinchEnded() {
        zoomBase = displayedZoom
        withAnimation(.easeOut(duration: 0.15)) { showZoomRing = false }
    }

    /// 选择模式
    private func selectMode(_ mode: CameraMode) {
        if cameraManager.isRecording {
            cameraManager.toggleRecording()
        }
        cameraManager.setMode(mode)
        haptic(.light)
    }

    /// 横滑切换模式
    private func switchMode(direction: Int) {
        let modes = CameraMode.allCases
        guard let index = modes.firstIndex(of: cameraManager.currentMode) else { return }
        let newIndex = min(max(index + direction, 0), modes.count - 1)
        selectMode(modes[newIndex])
    }

    /// 点击快门
    private func tapShutter() {
        guard cameraManager.isSessionRunning else { return }
        if cameraManager.currentMode == .video {
            cameraManager.toggleRecording()
        } else {
            cameraManager.onPhotoCaptured = { image in
                lastCapturedImage = image
            }
            cameraManager.capturePhoto()
            haptic(.medium)
        }
    }

    /// 开始自动拍照
    private func startAutoCapture() {
        cameraManager.onPhotoCaptured = { image in
            lastCapturedImage = image
        }
        cameraManager.startAutoCapture(interval: intervalSeconds)
        haptic(.medium)
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - 快门按钮样式（按压动画）

private struct ShutterButtonStyle: ButtonStyle {
    var onPressed: () -> Void
    var onReleased: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { onPressed() } else { onReleased() }
            }
    }
}

// MARK: - 对焦框

private struct FocusBoxView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .stroke(.yellow, lineWidth: 2)
    }
}

// MARK: - 变焦环

private struct ZoomRingView: View {
    let zoom: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: 3)
                .frame(width: 190, height: 190)

            // 刻度
            ForEach(0..<36, id: \.self) { index in
                Rectangle()
                    .fill(.white)
                    .frame(width: index % 6 == 0 ? 2.5 : 1,
                           height: index % 6 == 0 ? 14 : 7)
                    .offset(y: -91)
                    .rotationEffect(.degrees(Double(index) * 10))
                    .opacity(0.9)
            }

            Text(String(format: "%.1fx", zoom))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.4), radius: 8)
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

// MARK: - 网格线（九宫格构图辅助）

private struct GridView: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                // 两条竖线（1/3、2/3）
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                }
                // 两条横线（1/3、2/3）
                for i in 1...2 {
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 水平仪（iPhone 原相机水平模式）

/// iPhone 原相机"水平"模式水平仪：
/// - 中心固定一条**短虚线**作为水平参考
/// - 一条**长实线**根据手机 roll 偏移 + 旋转，对齐时变黄（与 iOS 原相机一致）
private struct LevelIndicatorView: View {
    /// 实线中心相对屏幕中心的偏移（pt）
    let offset: CGSize
    /// 实线旋转角度（度，SwiftUI 顺时针为正）
    let rotationAngle: Double
    /// 是否已对齐水平
    let isLevel: Bool

    var body: some View {
        ZStack {
            // 固定虚线（水平参考，对齐时淡出）
            VerticalLineShape()
                .stroke(.white.opacity(isLevel ? 0 : 0.75),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5]))
                .frame(width: 2, height: 70)
                .animation(.easeOut(duration: 0.15), value: isLevel)

            // 移动实线（随倾斜偏移 + 旋转，对齐时变黄）
            VerticalLineShape()
                .stroke(isLevel ? .yellow : .white, lineWidth: 2.5)
                .frame(width: 2, height: 320)
                .rotationEffect(.degrees(rotationAngle))
                .offset(offset)
                .shadow(color: isLevel ? .yellow.opacity(0.4) : .clear, radius: 4)
                .animation(.easeOut(duration: 0.08), value: offset)
                .animation(.easeOut(duration: 0.08), value: rotationAngle)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 竖直一条线 Shape（frame 多大线就多长）
private struct VerticalLineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

// MARK: - 水平仪姿态监测

/// 监测设备姿态，驱动 iPhone 原相机"水平"模式水平仪。
/// - isUpright：手机处于竖握 / 横握（含倒立）任一姿态，且屏幕大致朝前/后（非俯拍/仰拍）
/// - tiltOffset：实线相对屏幕中心的偏移（pt），由相对水平姿态的 roll 换算
/// - rotationAngle：实线旋转角度（度，顺时针为正）
/// - isLevel：已对齐水平（相对 roll ≈ 0），UI 变黄并触发一次触觉反馈
@MainActor
final class LevelMonitor: ObservableObject {

    @Published var tiltOffset: CGSize = .zero
    @Published var rotationAngle: Double = 0
    @Published var isUpright = false
    @Published var isLevel = false

    private let motion = CMMotionManager()
    /// 重力 → 屏幕 pt 偏移换算系数
    private let offsetScale: CGFloat = 280
    /// 偏移上限（pt）
    private let maxOffset: CGFloat = 120
    /// 重力 → 旋转角度换算系数（度）
    private let rotationScale: Double = 35
    /// 判定水平的 roll 角阈值（度）
    private let levelDegreeThreshold: Double = 1.5
    /// 显示阈值：|gravity.z| 超过此值视为俯拍/仰拍，隐藏水平仪
    private let uprightGZThreshold: Double = 0.4
    /// 是否已触发过水平触觉反馈（避免连续震动）
    private var levelHapticFired = false

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] motionData, _ in
            guard let gravity = motionData?.gravity else { return }
            let gx = gravity.x
            let gy = gravity.y
            let gz = gravity.z
            Task { @MainActor in
                self?.handleGravity(x: gx, y: gy, z: gz)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    private func handleGravity(x: Double, y: Double, z: Double) {
        // 显示判定：只看屏幕朝向（大致朝前/后即可），竖握 / 横握 / 倒立都显示
        let active = abs(z) < uprightGZThreshold
        isUpright = active
        guard active else {
            tiltOffset = .zero
            rotationAngle = 0
            isLevel = false
            levelHapticFired = false
            return
        }
        // 姿态角（portrait 基准 0°）：竖握水平 0°，横握 ±90°，倒立 180°
        let theta = atan2(x, -y) * 180.0 / .pi
        // 取最近的标准姿态（0° / ±90° / 180°）作为"水平"基准，
        // 使竖握与横握都能以各自基准判定水平
        let baseline = (theta / 90.0).rounded() * 90.0
        // 相对基准的 roll 偏差（度，∈ [-45°, 45°]），再换算为等效重力分量
        let rollDeg = theta - baseline
        let gxEquivalent = sin(rollDeg * .pi / 180.0)
        // 偏移：右倾 → 实线向右偏移，模拟原相机的"重力摆"效果
        let dx = CGFloat(gxEquivalent) * offsetScale
        tiltOffset = CGSize(
            width: min(max(dx, -maxOffset), maxOffset),
            height: 0
        )
        // 旋转：与偏移同向（小角度近似），使实线倾斜显示当前姿态
        rotationAngle = gxEquivalent * rotationScale
        // 水平判定
        let leveled = abs(rollDeg) < levelDegreeThreshold
        isLevel = leveled
        if leveled, !levelHapticFired {
            levelHapticFired = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if !leveled {
            levelHapticFired = false
        }
    }
}

// MARK: - 预览

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
