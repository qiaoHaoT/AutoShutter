import Foundation
import AVFoundation
import Photos
import UIKit

/// 相机管理器：负责 AVCaptureSession 的配置与运行，
/// 包含对焦、曝光（亮度）、变焦、定时拍照、保存相册等功能。
@MainActor
final class CameraManager: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {

    // MARK: - 暴露给 UI 的状态

    /// 相机会话是否正在运行（预览是否已开启）
    @Published var isSessionRunning = false
    /// 自动拍照是否正在进行
    @Published var isAutoCapturing = false
    /// 已拍摄张数
    @Published var captureCount = 0
    /// 最近一次错误信息
    @Published var errorMessage: String?
    /// 当前变焦倍数
    @Published var currentZoom: CGFloat = 1.0
    /// 当前曝光补偿值（-2 ~ +2）
    @Published var exposureTargetBias: Float = 0.0

    // MARK: - 内部属性

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var backCamera: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var captureTimer: Timer?
    private let sessionQueue = DispatchQueue(label: "com.autoshutter.session")

    // 用于保存最近一张照片缩略图的回调
    var onPhotoCaptured: ((UIImage) -> Void)?

    // MARK: - 相机会话控制

    /// 请求相机权限并配置会话
    func requestPermissionAndConfigure() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureSession()
                } else {
                    Task { @MainActor in
                        self.errorMessage = "未获得相机权限，请在系统设置中授权。"
                    }
                }
            }
        case .denied, .restricted:
            errorMessage = "相机权限被拒绝，请前往系统设置 > AutoShutter 开启相机权限。"
        @unknown default:
            break
        }
    }

    /// 在后台队列中配置 AVCaptureSession
    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            // 1. 选择后置摄像头
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                Task { @MainActor in self.errorMessage = "未找到后置摄像头。" }
                self.session.commitConfiguration()
                return
            }
            self.backCamera = camera

            // 2. 创建输入
            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.videoInput = input
                }
            } catch {
                Task { @MainActor in self.errorMessage = "无法创建相机输入：\(error.localizedDescription)" }
                self.session.commitConfiguration()
                return
            }

            // 3. 创建输出
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                // 启用高分辨率
                self.photoOutput.isHighResolutionCaptureEnabled = true
            }

            self.session.commitConfiguration()

            // 4. 配置设备默认参数（对焦、曝光模式）
            self.configureDeviceDefaults()

            Task { @MainActor in
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning
            }
        }
    }

    /// 配置设备默认对焦和曝光模式
    private func configureDeviceDefaults() {
        guard let camera = backCamera else { return }
        do {
            try camera.lockForConfiguration()
            // 连续自动对焦
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            // 连续自动曝光
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            camera.unlockForConfiguration()
        } catch {
            print("配置设备默认参数失败：\(error)")
        }
    }

    /// 提供给预览层使用的 capture session
    var captureSession: AVCaptureSession {
        return session
    }

    // MARK: - 对焦控制

    /// 在指定预览坐标点对焦（点击屏幕对焦）
    func focus(at point: CGPoint) {
        guard let camera = backCamera else { return }
        sessionQueue.async {
            do {
                try camera.lockForConfiguration()
                if camera.isFocusPointOfInterestSupported {
                    camera.focusPointOfInterest = point
                }
                if camera.isExposurePointOfInterestSupported {
                    camera.exposurePointOfInterest = point
                }
                // 切换到单次自动对焦，对焦完成后切回连续
                if camera.isFocusModeSupported(.autoFocus) {
                    camera.focusMode = .autoFocus
                }
                if camera.isExposureModeSupported(.autoExpose) {
                    camera.exposureMode = .autoExpose
                }
                camera.unlockForConfiguration()
            } catch {
                print("对焦失败：\(error)")
            }
        }
    }

    // MARK: - 曝光（亮度）控制

    /// 设置曝光补偿值（-2 ~ +2）
    func setExposureTargetBias(_ bias: Float) {
        guard let camera = backCamera else { return }
        sessionQueue.async {
            do {
                try camera.lockForConfiguration()
                if camera.isExposureModeSupported(.custom) {
                    camera.setExposureTargetBias(bias, completionHandler: nil)
                    Task { @MainActor in self.exposureTargetBias = bias }
                }
                camera.unlockForConfiguration()
            } catch {
                print("设置曝光补偿失败：\(error)")
            }
        }
    }

    // MARK: - 变焦控制

    /// 设置变焦倍数（基于设备最小变焦的虚拟缩放）
    func setZoom(_ zoom: CGFloat) {
        guard let camera = backCamera else { return }
        let clamped = max(camera.minAvailableVideoZoomFactor,
                          min(zoom, camera.maxAvailableVideoZoomFactor))
        sessionQueue.async {
            do {
                try camera.lockForConfiguration()
                camera.videoZoomFactor = clamped
                Task { @MainActor in self.currentZoom = clamped }
                camera.unlockForConfiguration()
            } catch {
                print("设置变焦失败：\(error)")
            }
        }
    }

    // MARK: - 定时拍照

    /// 开始自动定时拍照
    /// - Parameter interval: 拍照间隔（秒）
    func startAutoCapture(interval: TimeInterval) {
        guard isSessionRunning else {
            errorMessage = "相机未启动，无法开始拍照。"
            return
        }
        isAutoCapturing = true
        // 防止屏幕息屏（保持常亮）
        UIApplication.shared.isIdleTimerDisabled = true
        // 立即拍第一张
        capturePhoto()
        // 设置定时器，按间隔拍照
        captureTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.capturePhoto()
            }
        }
    }

    /// 停止自动定时拍照
    func stopAutoCapture() {
        captureTimer?.invalidate()
        captureTimer = nil
        isAutoCapturing = false
        // 恢复屏幕自动息屏
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - 拍照

    /// 执行一次拍照
    func capturePhoto() {
        guard session.isRunning else { return }
        let settings = AVCapturePhotoSettings()
        settings.isHighResolutionPhotoEnabled = true
        // 闪光灯自动
        if photoOutput.supportedFlashModes.contains(.auto) {
            settings.flashMode = .auto
        }
        // 设置方向
        if let connection = photoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingPhoto photo: AVCapturePhoto,
                                  error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            Task { @MainActor in
                self.errorMessage = "拍照失败：\(error?.localizedDescription ?? "未知错误")"
            }
            return
        }

        Task { @MainActor in
            self.captureCount += 1
            self.onPhotoCaptured?(image)
            self.saveToPhotosLibrary(data: data)
        }
    }

    // MARK: - 保存到相册

    private func saveToPhotosLibrary(data: Data) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] newStatus in
                if newStatus == .authorized || newStatus == .limited {
                    self?.performSave(data: data)
                } else {
                    Task { @MainActor in
                        self?.errorMessage = "未获得相册写入权限，照片未保存。"
                    }
                }
            }
        } else if status == .authorized || status == .limited {
            performSave(data: data)
        } else {
            errorMessage = "未获得相册写入权限，请在系统设置中授权。"
        }
    }

    private func performSave(data: Data) {
        PHPhotoLibrary.shared().performChanges {
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: data, options: nil)
        } completionHandler: { success, error in
            if !success {
                Task { @MainActor in
                    self.errorMessage = "保存到相册失败：\(error?.localizedDescription ?? "未知错误")"
                }
            }
        }
    }

    // MARK: - 清理

    deinit {
        captureTimer?.invalidate()
        UIApplication.shared.isIdleTimerDisabled = false
        if session.isRunning {
            session.stopRunning()
        }
    }
}
