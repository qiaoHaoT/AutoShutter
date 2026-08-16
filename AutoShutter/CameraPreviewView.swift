import SwiftUI
import AVFoundation

/// 相机预览视图：将 AVCaptureVideoPreviewLayer 包装为 SwiftUI 可用的 UIViewRepresentable，
/// 内置 UIKit 手势（单击对焦 / 单指滑动 / 双指捏合变焦），交互对齐 iPhone 原相机。
struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession

    /// 单击（视图坐标点）
    var onTap: ((CGPoint) -> Void)?
    /// 单指滑动开始
    var onPanBegan: ((CGPoint) -> Void)?
    /// 单指滑动中（位置 + 位移）
    var onPanChanged: ((CGPoint, CGSize) -> Void)?
    /// 单指滑动结束（位移）
    var onPanEnded: ((CGSize) -> Void)?
    /// 双指捏合中（相对缩放值，从 1.0 起）
    var onPinchChanged: ((CGFloat) -> Void)?
    /// 双指捏合结束
    var onPinchEnded: (() -> Void)?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        // 初始方向设为竖屏
        if let connection = view.videoPreviewLayer.connection {
            connection.videoOrientation = .portrait
        }
        view.onTap = onTap
        view.onPanBegan = onPanBegan
        view.onPanChanged = onPanChanged
        view.onPanEnded = onPanEnded
        view.onPinchChanged = onPinchChanged
        view.onPinchEnded = onPinchEnded
        view.setupGestures()
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // 确保会话已连接
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
        uiView.onTap = onTap
        uiView.onPanBegan = onPanBegan
        uiView.onPanChanged = onPanChanged
        uiView.onPanEnded = onPanEnded
        uiView.onPinchChanged = onPinchChanged
        uiView.onPinchEnded = onPinchEnded
    }
}

/// 自定义 UIView，持有 AVCaptureVideoPreviewLayer 并处理手势
final class PreviewUIView: UIView {

    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }

    var onTap: ((CGPoint) -> Void)?
    var onPanBegan: ((CGPoint) -> Void)?
    var onPanChanged: ((CGPoint, CGSize) -> Void)?
    var onPanEnded: ((CGSize) -> Void)?
    var onPinchChanged: ((CGFloat) -> Void)?
    var onPinchEnded: (() -> Void)?

    private var pinchActive = false

    func setupGestures() {
        // 单击对焦
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        // 单指滑动（切模式 / 切摄像头 / 调曝光）
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        // 双指捏合变焦
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
    }

    // MARK: - 手势处理

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        onTap?(g.location(in: self))
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        if pinchActive { return }
        let location = g.location(in: self)
        let translation = g.translation(in: self)
        switch g.state {
        case .began:
            onPanBegan?(location)
        case .changed:
            onPanChanged?(location, CGSize(width: translation.x, height: translation.y))
        case .ended, .cancelled:
            onPanEnded?(CGSize(width: translation.x, height: translation.y))
        default:
            break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchActive = true
        case .changed:
            onPinchChanged?(g.scale)
        case .ended, .cancelled:
            pinchActive = false
            onPinchEnded?()
        default:
            break
        }
    }
}

// MARK: - 手势共存

extension PreviewUIView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // 捏合与滑动可以同时识别（捏合时 pan 会因双指被忽略）
        return (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer)
            || (gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer)
    }
}
