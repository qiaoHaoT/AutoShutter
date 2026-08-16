import Foundation
import AVFoundation
import Photos
import UIKit

// MARK: - 相机模式

/// 相机模式（对齐 iPhone 原相机底部模式条）
enum CameraMode: String, CaseIterable, Identifiable {
    case photo = "照片"
    case video = "视频"
    case pano = "全景"

    var id: String { rawValue }
}

// MARK: - 闪光灯设置

/// 闪光灯模式（点击按钮循环切换）
enum FlashSetting: Int, CaseIterable {
    case auto = 0, on, off

    var title: String {
        switch self {
        case .auto: return "自动"
        case .on:   return "打开"
        case .off:  return "关闭"
        }
    }

    var iconName: String {
        switch self {
        case .auto: return "bolt.badge.automatic"
        case .on:   return "bolt.fill"
        case .off:  return "bolt.slash"
        }
    }

    /// 循环到下一个模式
    var next: FlashSetting {
        FlashSetting(rawValue: (rawValue + 1) % FlashSetting.allCases.count) ?? .auto
    }
}

// MARK: - 相机管理器

/// 相机管理器：负责 AVCaptureSession 的配置与运行，
/// 包含对焦、曝光（亮度）、变焦、闪光灯、前后摄像头切换、
/// 照片拍摄、视频录制、定时自动拍照、保存相册等功能。
@MainActor
final class CameraManager: NSObject, ObservableObject,
                           AVCapturePhotoCaptureDelegate,
                           AVCaptureFileOutputRecordingDelegate {

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
    /// 当前闪光灯模式
    @Published var flash: FlashSetting = .auto
    /// 是否正在使用前置摄像头
    @Published var isUsingFrontCamera = false
    /// 是否正在录制视频
    @Published var isRecording = false
    /// 当前相机模式（照片/视频/全景）
    @Published var currentMode: CameraMode = .photo
    /// 视频已录制时长（秒）
    @Published var recordingTime: TimeInterval = 0
    /// 手电筒是否打开（视频模式）
    @Published var isTorchOn = false

    // MARK: - 内部属性

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var currentCamera: AVCaptureDevice?
    private var captureTimer: Timer?
    private var recordTimer: Timer?
    private let sessionQueue = DispatchQueue(label: "com.autoshutter.session")

    /// 用于保存最近一张照片缩略图的回调
    var onPhotoCaptured: ((UIImage) -> Void)?

    /// 提供给预览层使用的 capture session
    var captureSession: AVCaptureSession { session }

    /// 设备支持的最大变焦倍数（限制在 15x 以内）
    var maxZoom: CGFloat {
        min(currentCamera?.maxAvailableVideoZoomFactor ?? 10.0, 15.0)
    }

    // MARK: - 权限与会话配置

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
            self.currentCamera = camera

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

            // 3. 照片输出
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.isHighResolutionCaptureEnabled = true
            }

            // 4. 视频输出
            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }

            self.session.commitConfiguration()

            // 5. 配置设备默认参数（对焦、曝光模式）
            self.configureDeviceDefaults()

            Task { @MainActor in
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning
            }
        }
    }

    /// 配置设备默认对焦和曝光模式
    private func configureDeviceDefaults() {
        guard let camera = currentCamera else { return }
        do {
            try camera.lockForConfiguration()
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            camera.unlockForConfiguration()
        } catch {
            print("配置设备默认参数失败：\(error)")
        }
    }

    // MARK: - 模式切换

    /// 切换相机模式（照片 / 视频 / 全景）
    func setMode(_ mode: CameraMode) {
        guard mode != .pano else {
            errorMessage = "全景模式暂不支持，请使用照片或视频模式。"
            return
        }
        currentMode = mode
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if mode == .photo {
                self.session.sessionPreset = .photo
            } else {
                self.session.sessionPreset = .high
            }
            self.session.commitConfiguration()
        }
    }

    // MARK: - 前后摄像头切换

    /// 切换前后摄像头
    func switchCamera() {
        guard let currentInput = videoInput else { return }
        let targetPosition: AVCaptureDevice.Position = isUsingFrontCamera ? .back : .front
        guard let newCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: targetPosition) else {
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.removeInput(currentInput)
            do {
                let newInput = try AVCaptureDeviceInput(device: newCamera)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.videoInput = newInput
                    self.currentCamera = newCamera
                    self.session.commitConfiguration()
                    // 前置摄像头无闪光灯，自动切换为关闭
                    Task { @MainActor in
                        self.isUsingFrontCamera.toggle()
                        if self.isUsingFrontCamera {
                            self.flash = .off
                        }
                        self.setZoom(1.0)
                        self.exposureTargetBias = 0
                        self.setExposureTargetBias(0)
                    }
                } else {
                    self.session.addInput(currentInput)
                    self.session.commitConfiguration()
                }
            } catch {
                self.session.addInput(currentInput)
                self.session.commitConfiguration()
            }
        }
    }

    // MARK: - 对焦控制

    /// 在指定设备坐标点对焦（坐标 0~1，原点左下）
    func focus(at point: CGPoint) {
        guard let camera = currentCamera else { return }
        sessionQueue.async {
            do {
                try camera.lockForConfiguration()
                if camera.isFocusPointOfInterestSupported {
                    camera.focusPointOfInterest = point
                }
                if camera.isExposurePointOfInterestSupported {
                    camera.exposurePointOfInterest = point
                }
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
        guard let camera = currentCamera else { return }
        let clamped = min(2.0, max(-2.0, bias))
        sessionQueue.async {
            do {
                try camera.lockForConfiguration()
                if camera.isExposureModeSupported(.custom) {
                    camera.setExposureTargetBias(clamped, completionHandler: nil)
                    Task { @MainActor in self.exposureTargetBias = clamped }
                }
                camera.unlockForConfiguration()
            } catch {
                print("设置曝光补偿失败：\(error)")
            }
        }
    }

    // MARK: - 变焦控制

    /// 设置变焦倍数
    func setZoom(_ zoom: CGFloat) {
        guard let camera = currentCamera else { return }
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

    // MARK: - 闪光灯控制

    /// 照片模式：循环切换闪光灯模式
    func cycleFlash() {
        flash = flash.next
    }

    /// 视频模式：切换手电筒
    func toggleTorch() {
        guard let camera = currentCamera, camera.hasTorch else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try camera.lockForConfiguration()
                if self.isTorchOn {
                    camera.torchMode = .off
                } else {
                    try camera.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                }
                camera.unlockForConfiguration()
                Task { @MainActor in self.isTorchOn.toggle() }
            } catch {
                print("切换手电筒失败：\(error)")
            }
        }
    }

    /// 点击闪光灯按钮（按当前模式分发）
    func handleFlashButton() {
        if currentMode == .video {
            toggleTorch()
        } else {
            cycleFlash()
        }
    }

    // MARK: - 拍照

    /// 执行一次拍照
    func capturePhoto() {
        guard session.isRunning else { return }
        let settings = AVCapturePhotoSettings()
        settings.isHighResolutionPhotoEnabled = true
        // 闪光灯（前置摄像头无闪光灯）
        if isUsingFrontCamera {
            settings.flashMode = .off
        } else {
            switch flash {
            case .auto:
                if photoOutput.supportedFlashModes.contains(.auto) {
                    settings.flashMode = .auto
                }
            case .on:
                if photoOutput.supportedFlashModes.contains(.on) {
                    settings.flashMode = .on
                }
            case .off:
                if photoOutput.supportedFlashModes.contains(.off) {
                    settings.flashMode = .off
                }
            }
        }
        // 设置方向
        if let connection = photoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - 视频录制

    /// 开始或停止视频录制
    func toggleRecording() {
        guard currentMode == .video else { return }
        if isRecording {
            movieOutput.stopRecording()
            recordTimer?.invalidate()
            recordTimer = nil
            isRecording = false
        } else {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            if let connection = movieOutput.connection(with: .video) {
                connection.videoOrientation = .portrait
            }
            movieOutput.startRecording(to: url, recordingDelegate: self)
            isRecording = true
            recordingTime = 0
            recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.recordingTime += 0.1
                }
            }
        }
    }

    // MARK: - 定时自动拍照

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

    // MARK: - 保存到相册

    private func requestPhotoAddPermission(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                completion(newStatus == .authorized || newStatus == .limited)
            }
        case .authorized, .limited:
            completion(true)
        default:
            completion(false)
        }
    }

    private func saveToPhotosLibrary(data: Data) {
        requestPhotoAddPermission { [weak self] granted in
            guard granted else {
                Task { @MainActor in
                    self?.errorMessage = "未获得相册写入权限，照片未保存。"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                if !success {
                    Task { @MainActor in
                        self?.errorMessage = "保存到相册失败：\(error?.localizedDescription ?? "未知错误")"
                    }
                }
            }
        }
    }

    private func saveVideoToLibrary(url: URL) {
        requestPhotoAddPermission { [weak self] granted in
            guard granted else {
                Task { @MainActor in
                    self?.errorMessage = "未获得相册写入权限，视频未保存。"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { success, error in
                if !success {
                    Task { @MainActor in
                        self?.errorMessage = "保存视频失败：\(error?.localizedDescription ?? "未知错误")"
                    }
                }
                // 清理临时文件
                try? FileManager.default.removeItem(at: url)
            }
        }
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

    // MARK: - AVCaptureFileOutputRecordingDelegate

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        if let error {
            let nsError = error as NSError
            if nsError.code != AVError.Code.operationCancelled.rawValue {
                Task { @MainActor in
                    self.errorMessage = "录制失败：\(error.localizedDescription)"
                }
            }
            return
        }
        Task { @MainActor in
            self.saveVideoToLibrary(url: outputFileURL)
        }
    }

    // MARK: - 清理

    deinit {
        captureTimer?.invalidate()
        recordTimer?.invalidate()
        UIApplication.shared.isIdleTimerDisabled = false
        if session.isRunning {
            session.stopRunning()
        }
    }
}
