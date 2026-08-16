import SwiftUI
import AVFoundation

/// 相机预览视图：将 AVCaptureVideoPreviewLayer 包装为 SwiftUI 可用的 UIViewRepresentable
struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        // 初始方向设为竖屏
        if let connection = view.videoPreviewLayer.connection {
            connection.videoOrientation = .portrait
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // 确保会话已连接
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
    }
}

/// 自定义 UIView，持有 AVCaptureVideoPreviewLayer
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
}
