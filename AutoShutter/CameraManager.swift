import Foundation
import AVFoundation
import Photos
import UIKit
import CoreLocation
import ImageIO

// MARK: - 相机模式

/// 相机模式（对齐 iPhone 原相机底部模式条）
enum CameraMode: String, CaseIterable, Identifiable {
    case photo = "照片"
    case video = "视频"

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

// MARK: - 定位状态

/// 照片地理位置记录状态（用于顶栏指示器）
enum LocationStatus {
    case unknown      // 未请求过
    case searching    // 已授权但还没拿到有效定位
    case ready        // 已拿到有效定位，照片会写入 GPS
    case denied       // 被拒绝/受限
}

// MARK: - 相机管理器

/// 相机管理器：负责 AVCaptureSession 的配置与运行，
/// 包含对焦、曝光（亮度）、变焦、闪光灯、前后摄像头切换、
/// 照片拍摄、视频录制、定时自动拍照、保存相册等功能。
@MainActor
final class CameraManager: NSObject, ObservableObject,
                           AVCapturePhotoCaptureDelegate,
                           AVCaptureFileOutputRecordingDelegate,
                           CLLocationManagerDelegate {

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
    /// 当前相机模式（照片/视频）
    @Published var currentMode: CameraMode = .photo
    /// 视频已录制时长（秒）
    @Published var recordingTime: TimeInterval = 0
    /// 手电筒是否打开（视频模式）
    @Published var isTorchOn = false
    /// 拍照音效是否静音
    @Published var isMuted = false
    /// 距离下一次自动拍照的剩余时间（秒，仅自动拍照运行时有效）
    @Published var secondsUntilNextCapture: Double = 0
    /// 照片地理位置记录状态
    @Published var locationStatus: LocationStatus = .unknown
    /// 实况照片（Live Photo）是否开启
    @Published var isLivePhotoEnabled = false
    /// Apple ProRAW 是否开启
    @Published var isRawEnabled = false

    // MARK: - 内部属性

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var currentCamera: AVCaptureDevice?
    private var captureTimer: Timer?
    private var recordTimer: Timer?
    /// 自动拍照下一次触发时间（用于倒计时显示）
    private var nextCaptureDate: Date?
    /// 倒计时刷新定时器
    private var countdownTimer: Timer?
    private let sessionQueue = DispatchQueue(label: "com.autoshutter.session")

    // MARK: - 定位（照片 GPS 写入）

    private let locationManager = CLLocationManager()
    /// 最近一次有效定位（写入照片 EXIF GPS）
    private var latestLocation: CLLocation?

    // MARK: - 实况照片（Live Photo）配对缓存

    /// 等待配对保存的实况照片：uniqueID → 静态照片数据
    private var pendingLiveStills: [Int64: Data] = [:]
    /// 等待配对保存的实况照片：uniqueID → 配套视频文件 URL
    private var pendingLiveMovies: [Int64: URL] = [:]
    /// 当前正在进行的实况拍摄 uniqueID 集合（用于区分普通照片）
    private var liveShotIDs: Set<Int64> = []
    /// 当前正在进行的 ProRAW 拍摄 uniqueID 集合（用于丢弃伴随的处理图，避免相册重复）
    private var rawShotIDs: Set<Int64> = []

    /// 镜头切换是否进行中（防止捏合手势连续触发重复切换导致 session 状态混乱）
    private var isSwitchingLens = false
    /// 切换期间挂起的最新目标变焦倍数（切换完成后一次性应用）
    private var pendingZoom: CGFloat?
    /// 缓存后置长焦原生等效倍数（configureSession 时更新，避免频繁查询设备）
    private var cachedTelephotoNativeZoom: CGFloat = 5.0

    /// 用于保存最近一张照片缩略图的回调
    var onPhotoCaptured: ((UIImage) -> Void)?

    /// 提供给预览层使用的 capture session
    var captureSession: AVCaptureSession { session }

    /// 设备支持的最大变焦倍数（限制在 15x 以内）
    var maxZoom: CGFloat {
        min(currentCamera?.maxAvailableVideoZoomFactor ?? 10.0, 15.0)
    }

    /// 是否支持实况照片
    var isLivePhotoSupported: Bool { photoOutput.isLivePhotoCaptureSupported }
    /// 是否支持 Apple ProRAW
    var isRawSupported: Bool { photoOutput.isAppleProRAWSupported }

    // MARK: - 权限与会话配置

    /// 请求相机权限并配置会话
    func requestPermissionAndConfigure() {
        setupLocation()
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

    // MARK: - 摄像头选择

    /// 根据变焦倍数和目标位置选择最合适的物理摄像头。
    /// iPhone 16 Pro 上：zoom >= 3.0x 优先使用长焦镜头，否则使用广角。
    /// 线程安全，允许后台队列调用。
    nonisolated private func bestCamera(for position: AVCaptureDevice.Position, zoom: CGFloat = 1.0) -> AVCaptureDevice? {
        let allTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInTelephotoCamera,
            .builtInWideAngleCamera,
            .builtInUltraWideCamera
        ]
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: allTypes,
            mediaType: .video,
            position: position
        )
        let devices = discoverySession.devices
        print("[Camera] 可用设备列表:")
        for device in devices {
            print("  - \(device.deviceType.rawValue): \(device.localizedName), zoom: \(String(format: "%.2f", device.minAvailableVideoZoomFactor))x ~ \(String(format: "%.2f", device.maxAvailableVideoZoomFactor))x")
        }

        // 计算长焦镜头的「原生等效变焦倍数」（以广角主摄为 1x 基准）。
        // 通过视场角(FOV)比例计算：iPhone 16 Pro 的 120mm 长焦 ≈ 5.0x，
        // iPhone 15 Pro 的 120mm 长焦 ≈ 3.0x。
        let teleNative = Self.telephotoNativeZoom(devices: devices)
        print("[Camera] 长焦镜头原生等效变焦: \(String(format: "%.1f", teleNative))x")

        // 长焦镜头选择（达到长焦原生倍数时切换，画质最佳）
        if zoom >= teleNative - 0.01 {
            if let telephoto = devices.first(where: { $0.deviceType == .builtInTelephotoCamera }) {
                print("[Camera] 选择长焦镜头: \(telephoto.localizedName)")
                return telephoto
            }
            if let triple = devices.first(where: { $0.deviceType == .builtInTripleCamera }) {
                print("[Camera] 选择三镜头虚拟设备: \(triple.localizedName)")
                return triple
            }
        }

        // 默认使用广角镜头（1x 主摄）
        if let wide = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            print("[Camera] 选择广角镜头: \(wide.localizedName)")
            return wide
        }

        return devices.first
    }

    /// 计算长焦镜头的原生等效变焦倍数（以广角主摄为 1x 基准）。
    /// 原理：长焦与主摄的水平视场角之比 ≈ 等效变焦倍数。
    /// 例如主摄 FOV 69°、长焦 FOV 14°，则 69/14 ≈ 5.0x。
    /// 找不到长焦或数据异常时返回默认 5.0（不影响无长焦机型：调用方仅在
    /// 找到长焦设备时才使用该值做镜头选择）。
    nonisolated private static func telephotoNativeZoom(devices: [AVCaptureDevice]) -> CGFloat {
        guard let tele = devices.first(where: { $0.deviceType == .builtInTelephotoCamera }),
              let wide = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) else {
            return 5.0
        }
        // videoFieldOfView 返回 Float，显式转为 CGFloat 以兼容各平台 SDK
        let wideFOV = CGFloat(wide.activeFormat.videoFieldOfView)
        let teleFOV = CGFloat(tele.activeFormat.videoFieldOfView)
        guard wideFOV > 0, teleFOV > 0, wideFOV > teleFOV else { return 5.0 }
        let ratio = wideFOV / teleFOV
        // 合理范围 2.0x ~ 10.0x，超出则视为异常数据
        return (2.0...10.0).contains(ratio) ? ratio : 5.0
    }

    /// 按位置查询长焦镜头的原生等效变焦倍数（便捷重载）
    nonisolated private static func telephotoNativeZoom(position: AVCaptureDevice.Position) -> CGFloat {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTelephotoCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return telephotoNativeZoom(devices: session.devices)
    }

    /// 在后台队列中配置 AVCaptureSession
    private func configureSession() {
        // 在主线程（MainActor）读取状态，避免 Sendable 闭包直接访问隔离属性
        let targetZoom = max(currentZoom, 1.0)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            // 1. 选择后置摄像头（根据当前变焦倍数选择合适镜头）
            guard let camera = self.bestCamera(for: .back, zoom: targetZoom) else {
                Task { @MainActor in self.errorMessage = "未找到后置摄像头。" }
                self.session.commitConfiguration()
                return
            }

            // 2. 创建输入
            var input: AVCaptureDeviceInput?
            do {
                let newInput = try AVCaptureDeviceInput(device: camera)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    input = newInput
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
                // 允许最高画质优先（启用多帧合成管线的前提）
                self.photoOutput.maxPhotoQualityPrioritization = .quality
                // 实况照片（Live Photo）输出能力：开启后按需在拍摄设置中附带 movie URL
                if self.photoOutput.isLivePhotoCaptureSupported {
                    self.photoOutput.isLivePhotoCaptureEnabled = true
                }
                // Apple ProRAW：会话配置时即启用。该开关仅「允许」输出 RAW，不改变普通拍照；
                // 必须在 capturePhoto 前启用，否则带 rawPixelFormatType 的拍摄设置会触发
                // NSInvalidArgumentException 闪退。运行中切换会重配置 pipeline，故一次性常开。
                if self.photoOutput.isAppleProRAWSupported {
                    self.photoOutput.isAppleProRAWEnabled = true
                }
            }

            // 4. 视频输出
            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }

            self.session.commitConfiguration()

            // 5. 回到主线程：记录设备状态、配置默认参数并启动会话
            Task { @MainActor in
                self.currentCamera = camera
                self.videoInput = input
                self.cachedTelephotoNativeZoom = Self.telephotoNativeZoom(position: .back)
                self.configureDeviceDefaults()
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning
                // 调试：打印实际使用的设备信息
                print("[Camera] 使用设备: \(camera.deviceType.rawValue), " +
                      "镜头: \(camera.localizedName), " +
                      "zoom范围: \(String(format: "%.2f", camera.minAvailableVideoZoomFactor))x ~ \(String(format: "%.2f", camera.maxAvailableVideoZoomFactor))x")
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

    /// 切换相机模式（照片 / 视频）
    func setMode(_ mode: CameraMode) {
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
        let targetZoom = currentZoom > 1.0 ? currentZoom : 1.0
        guard let newCamera = bestCamera(for: targetPosition, zoom: targetZoom) else {
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            // 仅移除当前实际存在的输入
            if self.session.inputs.contains(currentInput) {
                self.session.removeInput(currentInput)
            }
            do {
                let newInput = try AVCaptureDeviceInput(device: newCamera)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.session.commitConfiguration()
                    // 回到主线程更新设备状态
                    Task { @MainActor in
                        self.videoInput = newInput
                        self.currentCamera = newCamera
                        // 前置摄像头无闪光灯，自动切换为关闭
                        self.isUsingFrontCamera.toggle()
                        if self.isUsingFrontCamera {
                            self.flash = .off
                        }
                        self.setZoom(1.0)
                        self.exposureTargetBias = 0
                        self.setExposureTargetBias(0)
                    }
                } else {
                    if self.session.inputs.contains(currentInput) {
                        self.session.addInput(currentInput)
                    }
                    self.session.commitConfiguration()
                }
            } catch {
                if self.session.inputs.contains(currentInput) {
                    self.session.addInput(currentInput)
                }
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

    /// 设置「等效变焦倍数」（以广角主摄为 1x 基准，与原相机显示一致）。
    /// - 达到长焦原生倍数（如 5x）时自动切换到长焦镜头
    /// - 低于该倍数时使用广角主摄（数字变焦）
    /// - 在长焦镜头上，设备的 videoZoomFactor 需要除以长焦原生倍数换算
    /// - 使用滞回阈值（升到 teleNative 切长焦，降到 teleNative*0.95 才切回广角），
    ///   避免在边界附近反复切换
    /// - 切换进行中只挂起最新目标，切换完成后一次性应用，防止捏合手势
    ///   连续触发多个切换任务排队导致 AVCaptureSession 状态混乱崩溃
    func setZoom(_ zoom: CGFloat) {
        guard let camera = currentCamera else { return }
        let teleNative = isUsingFrontCamera ? 5.0 : cachedTelephotoNativeZoom

        let isTelephoto = camera.deviceType == .builtInTelephotoCamera
        let isWide = camera.deviceType == .builtInWideAngleCamera
        let isBack = !isUsingFrontCamera
        // 滞回阈值：仅后置的广角/长焦之间需要手动切换；
        // 前置与虚拟多摄设备（Triple/DualWide）跟随设备自动变焦，不强制切换
        let needsSwitch: Bool
        if isBack && isTelephoto {
            needsSwitch = zoom < teleNative * 0.95
        } else if isBack && isWide {
            needsSwitch = zoom >= teleNative
        } else {
            needsSwitch = false
        }

        // 需要切换镜头
        if needsSwitch {
            // 已在切换中：只记录最新目标，等待切换完成后再应用
            if isSwitchingLens {
                pendingZoom = zoom
                print("[Camera] 切换进行中，挂起目标 zoom \(String(format: "%.2f", zoom))x")
                return
            }
            isSwitchingLens = true
            pendingZoom = nil
            print("[Camera] 变焦 \(String(format: "%.2f", zoom))x 需要切换镜头，当前: \(camera.deviceType.rawValue)")
            switchToLens(zoom: zoom)
            return
        }

        // 同一镜头内直接设置 zoom
        applyZoom(camera, zoom: zoom, teleNative: teleNative)
    }

    /// 在当前设备上直接设置变焦倍数（长焦镜头需换算为设备系数）
    private func applyZoom(_ camera: AVCaptureDevice, zoom: CGFloat, teleNative: CGFloat) {
        let isTelephoto = camera.deviceType == .builtInTelephotoCamera
        let deviceFactor = isTelephoto ? zoom / teleNative : zoom
        let clamped = max(camera.minAvailableVideoZoomFactor,
                          min(deviceFactor, camera.maxAvailableVideoZoomFactor))
        // 显示用的等效倍数
        let displayZoom = isTelephoto ? clamped * teleNative : clamped
        sessionQueue.async {
            do {
                try camera.lockForConfiguration()
                camera.videoZoomFactor = clamped
                camera.unlockForConfiguration()
                Task { @MainActor in self.currentZoom = displayZoom }
                print("[Camera] 变焦设置为 \(String(format: "%.2f", displayZoom))x " +
                      "(设备系数 \(String(format: "%.2f", clamped))), 设备: \(camera.localizedName)")
            } catch {
                print("设置变焦失败：\(error)")
            }
        }
    }

    /// 切换到适合目标变焦倍数的物理镜头。
    /// 切换完成后回到主线程更新设备状态，并应用挂起的最新目标倍数。
    private func switchToLens(zoom: CGFloat) {
        guard let currentInput = videoInput else {
            isSwitchingLens = false
            return
        }
        let position: AVCaptureDevice.Position = isUsingFrontCamera ? .front : .back
        guard let newCamera = bestCamera(for: position, zoom: zoom) else {
            isSwitchingLens = false
            return
        }
        // 目标设备与当前相同（如无长焦机型 / 前置摄像头），无需切换，
        // 直接在当前设备上设置目标倍数（不走 setZoom 避免递归）
        if newCamera === currentCamera {
            isSwitchingLens = false
            applyZoom(newCamera, zoom: zoom, teleNative: isUsingFrontCamera ? 5.0 : cachedTelephotoNativeZoom)
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            // 仅移除当前实际存在的输入，避免重复移除导致 session 异常
            if self.session.inputs.contains(currentInput) {
                self.session.removeInput(currentInput)
            }
            do {
                let newInput = try AVCaptureDeviceInput(device: newCamera)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.session.commitConfiguration()

                    // 回到主线程更新设备状态，并应用目标倍数
                    Task { @MainActor in
                        self.videoInput = newInput
                        self.currentCamera = newCamera
                        let target = self.pendingZoom ?? zoom
                        self.pendingZoom = nil
                        self.isSwitchingLens = false
                        self.setZoom(target)
                        print("[Camera] 镜头切换完成: \(newCamera.localizedName)")
                    }
                } else {
                    // 添加失败：把原输入加回，保持会话有效
                    if self.session.inputs.contains(currentInput) {
                        self.session.addInput(currentInput)
                    }
                    self.session.commitConfiguration()
                    Task { @MainActor in
                        self.isSwitchingLens = false
                        self.setZoom(zoom)
                    }
                    print("[Camera] 无法添加新输入，回退到原设备")
                }
            } catch {
                // 创建输入失败：把原输入加回，保持会话有效
                if self.session.inputs.contains(currentInput) {
                    self.session.addInput(currentInput)
                }
                self.session.commitConfiguration()
                Task { @MainActor in
                    self.isSwitchingLens = false
                    self.setZoom(zoom)
                }
                print("[Camera] 切换镜头失败：\(error)")
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
        let turnOn = !isTorchOn
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try camera.lockForConfiguration()
                if turnOn {
                    try camera.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } else {
                    camera.torchMode = .off
                }
                camera.unlockForConfiguration()
                Task { @MainActor in self.isTorchOn = turnOn }
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

    /// 切换实况照片开关
    func toggleLivePhoto() {
        guard photoOutput.isLivePhotoCaptureSupported else {
            errorMessage = "此设备不支持实况照片。"
            return
        }
        isLivePhotoEnabled.toggle()
    }

    /// 切换 Apple ProRAW 开关
    func toggleRaw() {
        guard photoOutput.isAppleProRAWSupported else {
            errorMessage = "此设备不支持 Apple ProRAW。"
            return
        }
        isRawEnabled.toggle()
    }

    // MARK: - 拍照

    /// 挑选用于拍摄的 RAW 像素格式：优先 Apple ProRAW，设备不支持时退回 Bayer RAW
    private func preferredRawPixelFormatType() -> OSType? {
        let types = photoOutput.availableRawPhotoPixelFormatTypes
        return types.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } ?? types.first
    }

    /// 执行一次拍照
    func capturePhoto() {
        guard session.isRunning else { return }

        let settings: AVCapturePhotoSettings
        // Apple ProRAW（raw + HEIF 预览），优先于实况
        if isRawEnabled, photoOutput.isAppleProRAWSupported,
           let rawType = preferredRawPixelFormatType() {
            let processedFormat: [String: Any]? = photoOutput.availablePhotoCodecTypes.contains(.hevc)
                ? [AVVideoCodecKey: AVVideoCodecType.hevc]
                : nil
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawType, processedFormat: processedFormat)
            // 标记本次为 RAW 拍摄：委托会回调两次（DNG + 处理图），只保存 DNG
            rawShotIDs.insert(settings.uniqueID)
        } else if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.isHighResolutionPhotoEnabled = true
        // 最高画质优先：触发系统多帧合成与更深的图像处理管线
        if photoOutput.maxPhotoQualityPrioritization.rawValue >= AVCapturePhotoOutput.QualityPrioritization.quality.rawValue {
            settings.photoQualityPrioritization = .quality
        }
        // 静音时抑制系统内置快门音效（iOS 18+ 官方 API）。
        // 拍照时系统会自动播放快门声（隐私政策），此开关将其关闭；
        // 部分地区（如日/韩）法律要求快门声不可关闭，此时 isShutterSoundSuppressionSupported 为 false。
        // 注：该 API 为 iOS 18+，需 #available 守卫；iOS 17 设备保持默认播放快门声。
        if isMuted, #available(iOS 18.0, *), photoOutput.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = true
        }
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
        // 实况照片：附带 movie 文件 URL，等待 delegate 配对保存。
        // RAW 与实况互斥（RAW 优先），避免数据格式冲突。
        if isLivePhotoEnabled, photoOutput.isLivePhotoCaptureSupported, !isRawEnabled {
            let movieURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(settings.uniqueID)-live.mov")
            settings.livePhotoMovieFileURL = movieURL
            liveShotIDs.insert(settings.uniqueID)
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
        // 每轮自动拍照重新计数
        captureCount = 0
        // 防止屏幕息屏（保持常亮）
        UIApplication.shared.isIdleTimerDisabled = true
        // 立即拍第一张
        capturePhoto()
        // 调度后续拍摄（链式单次定时器，支持倒计时显示）
        scheduleNextCapture(after: interval)
    }

    /// 调度下一次自动拍照，并持续刷新倒计时
    private func scheduleNextCapture(after interval: TimeInterval) {
        nextCaptureDate = Date().addingTimeInterval(interval)
        // 先同步刷新一次倒计时，避免 UI 短暂显示旧值
        secondsUntilNextCapture = interval
        // 倒计时刷新（0.2s 粒度）
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let date = self.nextCaptureDate else { return }
                self.secondsUntilNextCapture = max(0, date.timeIntervalSinceNow)
            }
        }
        // 到点拍摄，然后调度下一轮
        captureTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isAutoCapturing else { return }
                self.capturePhoto()
                self.scheduleNextCapture(after: interval)
            }
        }
    }

    /// 停止自动定时拍照
    func stopAutoCapture() {
        captureTimer?.invalidate()
        captureTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        nextCaptureDate = nil
        secondsUntilNextCapture = 0
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

    // MARK: - 定位（照片 GPS 写入）

    /// 初始化定位：申请 When In Use 权限，已授权则开始更新
    private func setupLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else {
            applyLocationStatus(status)
        }
    }

    /// 根据授权状态更新 locationStatus 并启停更新
    private func applyLocationStatus(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            locationStatus = (latestLocation == nil) ? .searching : .ready
            locationManager.startUpdatingLocation()
        case .denied, .restricted:
            locationStatus = .denied
            locationManager.stopUpdatingLocation()
        case .notDetermined:
            locationStatus = .unknown
        @unknown default:
            locationStatus = .unknown
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.applyLocationStatus(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let ts = loc.timestamp.timeIntervalSinceNow
        let acc = loc.horizontalAccuracy
        Task { @MainActor in
            // 过滤过期或无效定位（负精度表示无效）
            if ts > -10 && acc >= 0 {
                self.latestLocation = loc
                self.locationStatus = .ready
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            print("[Location] 失败：\(error)")
        }
    }

    /// 由 CLLocation 生成 EXIF GPS 字典
    private func gpsDictionary(for location: CLLocation) -> [CFString: Any] {
        let coord = location.coordinate
        var dict: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(coord.latitude),
            kCGImagePropertyGPSLatitudeRef: coord.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(coord.longitude),
            kCGImagePropertyGPSLongitudeRef: coord.longitude >= 0 ? "E" : "W"
        ]
        if location.horizontalAccuracy >= 0 {
            dict[kCGImagePropertyGPSDOP] = location.horizontalAccuracy
            dict[kCGImagePropertyGPSHPositioningError] = location.horizontalAccuracy
        }
        if !location.altitude.isNaN {
            dict[kCGImagePropertyGPSAltitude] = abs(location.altitude)
            dict[kCGImagePropertyGPSAltitudeRef] = location.altitude < 0 ? 1 : 0
        }
        // 时间戳（UTC）
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss.SSS"
        dict[kCGImagePropertyGPSTimeStamp] = f.string(from: location.timestamp)
        f.dateFormat = "yyyy:MM:dd"
        dict[kCGImagePropertyGPSDateStamp] = f.string(from: location.timestamp)
        return dict
    }

    /// 将 GPS EXIF 注入照片数据（HEIF/JPEG），无定位或注入失败时返回原数据
    private func photoDataInjectingGPS(_ data: Data) -> Data {
        guard let location = latestLocation,
              location.timestamp.timeIntervalSinceNow > -300 else {
            return data
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            return data
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, type, 1, nil) else {
            return data
        }
        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImagePropertyGPSDictionary] = gpsDictionary(for: location) as Any
        CGImageDestinationAddImageFromSource(dest, source, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return data }
        return mutableData as Data
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil, let fileData = photo.fileDataRepresentation() else {
            Task { @MainActor in
                self.errorMessage = "拍照失败：\(error?.localizedDescription ?? "未知错误")"
            }
            return
        }
        let uniqueID = photo.resolvedSettings.uniqueID
        // fileDataRepresentation() 对 RAW 照片返回 DNG，对处理图返回 HEIF/JPEG
        let isRaw = photo.isRawPhoto
        // DNG 解码开销大，缩略图交给伴随的处理图更新
        let thumbnail = isRaw ? nil : UIImage(data: fileData)

        Task { @MainActor in
            if isRaw {
                // Apple ProRAW：保存 DNG，不注入 GPS（DNG 注入风险高）
                self.rawShotIDs.remove(uniqueID)
                self.captureCount += 1
                self.saveToPhotosLibrary(data: fileData)
            } else if self.rawShotIDs.contains(uniqueID) {
                // ProRAW 的伴随处理图：不保存，避免相册出现重复照片
                self.rawShotIDs.remove(uniqueID)
            } else if self.liveShotIDs.contains(uniqueID) {
                // 实况照片：缓存静态数据（注入 GPS），等视频回调后配对保存
                self.captureCount += 1
                self.pendingLiveStills[uniqueID] = self.photoDataInjectingGPS(fileData)
                self.tryFlushLivePhoto(uniqueID: uniqueID)
            } else {
                self.captureCount += 1
                self.saveToPhotosLibrary(data: self.photoDataInjectingGPS(fileData))
            }
            if let thumbnail {
                self.onPhotoCaptured?(thumbnail)
            }
            // 轻触反馈：自动拍照时也能感知已拍摄
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingLivePhotoToMovieFileAt movieFileURL: URL,
                                 duration: CMTime,
                                 photoDisplayTime: CMTime,
                                 resolvedSettings: AVCaptureResolvedPhotoSettings,
                                 error: Error?) {
        guard error == nil else {
            Task { @MainActor in
                self.errorMessage = "实况视频录制失败：\(error?.localizedDescription ?? "未知错误")"
                self.liveShotIDs.remove(resolvedSettings.uniqueID)
                self.pendingLiveStills.removeValue(forKey: resolvedSettings.uniqueID)
            }
            try? FileManager.default.removeItem(at: movieFileURL)
            return
        }
        let uniqueID = resolvedSettings.uniqueID
        Task { @MainActor in
            self.pendingLiveMovies[uniqueID] = movieFileURL
            self.tryFlushLivePhoto(uniqueID: uniqueID)
        }
    }

    /// 静态照片 + 视频都到位后，配对保存为实况照片
    private func tryFlushLivePhoto(uniqueID: Int64) {
        guard let still = pendingLiveStills[uniqueID],
              let movie = pendingLiveMovies[uniqueID] else { return }
        pendingLiveStills.removeValue(forKey: uniqueID)
        pendingLiveMovies.removeValue(forKey: uniqueID)
        liveShotIDs.remove(uniqueID)
        saveLivePhotoToLibrary(stillData: still, movieURL: movie)
    }

    private func saveLivePhotoToLibrary(stillData: Data, movieURL: URL) {
        requestPhotoAddPermission { [weak self] granted in
            guard granted else {
                Task { @MainActor in
                    self?.errorMessage = "未获得相册写入权限，实况照片未保存。"
                }
                try? FileManager.default.removeItem(at: movieURL)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: stillData, options: nil)
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: nil)
            } completionHandler: { success, error in
                if !success {
                    Task { @MainActor in
                        self?.errorMessage = "保存实况照片失败：\(error?.localizedDescription ?? "未知错误")"
                    }
                }
                try? FileManager.default.removeItem(at: movieURL)
            }
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
        countdownTimer?.invalidate()
        recordTimer?.invalidate()
        // 注意：不在此处访问 UIApplication（deinit 非 MainActor 隔离，
        // 常亮状态已在 stopAutoCapture() 中恢复）
        if session.isRunning {
            session.stopRunning()
        }
        locationManager.stopUpdatingLocation()
    }
}
