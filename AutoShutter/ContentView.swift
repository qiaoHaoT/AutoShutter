import SwiftUI
import AVFoundation

struct ContentView: View {

    @StateObject private var cameraManager = CameraManager()

    // 间隔时间（秒），可滑动调整
    @State private var intervalSeconds: Double = 5.0
    // 变焦滑块
    @State private var zoomSliderValue: CGFloat = 1.0
    // 亮度滑块
    @State private var exposureSliderValue: Float = 0.0
    // 最近拍摄的照片缩略图
    @State private var lastCapturedImage: UIImage?
    // 对焦位置标记
    @State private var focusPoint: CGPoint?
    @State private var showFocusRing = false

    // 缩放范围（按设备能力动态获取）
    private let minZoom: CGFloat = 1.0
    private var maxZoom: CGFloat {
        if let device = AVCaptureDevice.default(for: .video) {
            return min(device.maxAvailableVideoZoomFactor, 15.0)
        }
        return 10.0
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // 1. 相机预览
                if cameraManager.isSessionRunning {
                    cameraPreview(in: geometry)
                } else {
                    cameraNotRunningView
                }

                // 2. 顶部控制区
                VStack {
                    topControlBar
                    Spacer()
                }

                // 3. 底部控制区
                VStack {
                    Spacer()
                    if cameraManager.isSessionRunning {
                        bottomControlPanel(in: geometry)
                    }
                }
            }
            .onAppear {
                cameraManager.requestPermissionAndConfigure()
            }
            .alert("提示", isPresented: .constant(cameraManager.errorMessage != nil)) {
                Button("好的") {
                    cameraManager.errorMessage = nil
                }
            } message: {
                Text(cameraManager.errorMessage ?? "")
            }
        }
    }

    // MARK: - 相机预览

    @ViewBuilder
    private func cameraPreview(in geometry: GeometryProxy) -> some View {
        CameraPreviewView(session: cameraManager.captureSession)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .gesture(
                // 点击对焦
                TapGesture()
                    .onEnded { _ in
                        // 中心点对焦
                        let center = CGPoint(x: 0.5, y: 0.5)
                        cameraManager.focus(at: center)
                        withAnimation { focusPoint = CGPoint(x: geometry.size.width / 2,
                                                              y: geometry.size.height / 2) }
                        showFocusRingWithHaptic()
                    }
            )
            .gesture(
                // 双指缩放
                MagnificationGesture()
                    .onChanged { value in
                        let newZoom = min(max(zoomSliderValue * value, minZoom), maxZoom)
                        cameraManager.setZoom(newZoom)
                    }
                    .onEnded { value in
                        zoomSliderValue = min(max(zoomSliderValue * value, minZoom), maxZoom)
                    }
            )
            .overlay {
                if showFocusRing, let point = focusPoint {
                    FocusRingView()
                        .frame(width: 60, height: 60)
                        .position(point)
                        .transition(.opacity)
                }
            }
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

    // MARK: - 顶部控制栏

    private var topControlBar: some View {
        HStack {
            // 已拍张数
            VStack(alignment: .leading, spacing: 2) {
                Text("已拍")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(cameraManager.captureCount)")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            .padding(.leading, 20)

            Spacer()

            // 状态指示
            if cameraManager.isAutoCapturing {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(0.8)
                        .scaleEffect(showFocusRing ? 1.3 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(), value: showFocusRing)
                    Text("自动拍照中")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }

            // 运行状态
            VStack(alignment: .trailing, spacing: 2) {
                Text("间隔")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0f秒", intervalSeconds))
                    .font(.title3.bold())
                    .foregroundStyle(.white)
            }
            .padding(.trailing, 20)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial.opacity(0.8))
    }

    // MARK: - 底部控制面板

    @ViewBuilder
    private func bottomControlPanel(in geometry: GeometryProxy) -> some View {
        VStack(spacing: 16) {

            // 间隔时间设置（仅未自动拍照时显示）
            if !cameraManager.isAutoCapturing {
                intervalSlider
            }

            // 变焦 & 亮度控制
            if !cameraManager.isAutoCapturing {
                HStack(spacing: 30) {
                    // 变焦滑块
                    VStack(spacing: 4) {
                        HStack {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1fx", zoomSliderValue))
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        }
                        Slider(value: $zoomSliderValue, in: minZoom...maxZoom, step: 0.1)
                            .tint(.orange)
                            .frame(width: 120)
                            .onChange(of: zoomSliderValue) { _, newValue in
                                cameraManager.setZoom(newValue)
                            }
                    }

                    // 亮度（曝光）滑块
                    VStack(spacing: 4) {
                        HStack {
                            Image(systemName: cameraManager.exposureTargetBias > 0 ? "sun.max.fill" : "sun.min")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%+.1f", cameraManager.exposureTargetBias))
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        }
                        Slider(value: Binding(
                            get: { Double(cameraManager.exposureTargetBias) },
                            set: { cameraManager.setExposureTargetBias(Float($0)) }
                        ), in: -2.0...2.0, step: 0.1)
                            .tint(.yellow)
                            .frame(width: 120)
                    }
                }
                .padding(.horizontal, 20)
            }

            // 主操作按钮
            actionButtons

            // 最近拍摄的照片缩略图
            if let image = lastCapturedImage {
                HStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.3), lineWidth: 1))
                    Text("最近拍摄")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 24)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial.opacity(0.9))
                .shadow(color: .black.opacity(0.3), radius: 10, y: -2)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - 间隔时间滑块

    private var intervalSlider: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "timer")
                    .foregroundStyle(.secondary)
                Text("拍照间隔")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f 秒", intervalSeconds))
                    .font(.headline.bold())
                    .foregroundStyle(.white)
            }
            Slider(value: $intervalSeconds, in: 1...60, step: 1)
                .tint(.blue)
        }
    }

    // MARK: - 开始 / 结束按钮

    private var actionButtons: some View {
        HStack(spacing: 40) {
            // 开始按钮
            Button(action: startCapture) {
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(.green, lineWidth: 3)
                            .frame(width: 56, height: 56)
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    }
                    Text("开始")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
            }
            .disabled(cameraManager.isAutoCapturing)
            .opacity(cameraManager.isAutoCapturing ? 0.4 : 1.0)

            // 结束按钮
            Button(action: stopCapture) {
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(.red, lineWidth: 3)
                            .frame(width: 56, height: 56)
                        Image(systemName: "stop.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                    Text("结束")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }
            .disabled(!cameraManager.isAutoCapturing)
            .opacity(!cameraManager.isAutoCapturing ? 0.4 : 1.0)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 操作方法

    private func startCapture() {
        cameraManager.onPhotoCaptured = { image in
            lastCapturedImage = image
        }
        cameraManager.startAutoCapture(interval: intervalSeconds)
        triggerHaptic()
    }

    private func stopCapture() {
        cameraManager.stopAutoCapture()
        triggerHaptic()
    }

    private func showFocusRingWithHaptic() {
        triggerHaptic()
        withAnimation(.easeIn) { showFocusRing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut) { showFocusRing = false }
        }
    }

    private func triggerHaptic() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }
}

// MARK: - 对焦指示圆环

private struct FocusRingView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 30)
            .stroke(.yellow, lineWidth: 2)
            .background(
                RoundedRectangle(cornerRadius: 30)
                    .stroke(.yellow.opacity(0.3), lineWidth: 4)
            )
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
