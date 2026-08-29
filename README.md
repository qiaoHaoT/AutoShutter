# 自动快门 AutoShutter

一款 iOS 自动定时拍照 App，相机界面与交互对齐 iPhone 内置原相机，支持自定义间隔时间自动拍照。

## 功能说明

### 相机功能（对齐 iPhone 原相机）
- **大圆形快门**：白色圆形快门按钮，按下有缩放动画；视频模式为红色快门
- **点击对焦**：单击画面任意位置自动对焦，显示黄色对焦框
- **曝光调节**：对焦后按住对焦框附近上下拖动，出现小太阳图标调节曝光（-2 ~ +2 EV）
- **双指捏合变焦**：捏合屏幕显示变焦环刻度，支持设备最大变焦倍数
- **1x 变焦切换**：快门上方倍数按钮，点击在 1x 与上次倍数间切换
- **前后摄像头切换**：右下角翻转按钮，或**上下滑动屏幕**快速切换
- **左右滑动切模式**：照片 / 视频 模式条，横滑切换
- **闪光灯 / 手电筒**：左上角按钮，照片模式循环 自动/开/关，视频模式切换手电筒
- **网格线**：顶栏按钮开启九宫格构图辅助线（开启后黄色高亮）
- **水平仪**：手机竖立时（屏幕大致朝前）显示 iPhone 原相机风格的水平参考线——中心一条短虚线 + 一条随 roll 偏移/旋转的长实线，roll ≈ 0 时两者重合变黄并震动提示
- **拍照音效**：拍照时系统自动播放快门声；顶栏扬声器按钮可静音（iOS 18 快门声抑制 API；部分地区法律要求快门声不可关闭）
- **自动拍照倒计时**：自动拍照时预览区顶部显示下一张倒计时，最后 3 秒大数字提醒
- **视频录制**：视频模式下点击红色快门开始/停止录制，自动保存到相册
- **最近照片缩略图**：左下角实时显示最新拍摄的照片
- **屏幕常亮**：拍照期间防止屏幕自动息屏

### 自动拍照功能（浮动面板）
- **⏱ 小按钮**：右上角点击弹出自动拍照操作面板，不遮挡构图
- **间隔设置**：1~60 秒滑块调节
- **开始 / 结束**：面板内绿色「开始」红色「结束」按钮
- **实时状态**：面板内显示运行状态与已拍张数

## 系统要求

- iOS 18.1.1 及以上版本
- Xcode 16.0+（构建用）
- 支持 iPhone / iPad

## 技术说明

> **关于"打开原生相机 App"的限制**
>
> iOS 系统采用严格的沙盒机制，第三方 App **无法控制其他 App 的 UI 操作**（如点击原生相机 App 的快门按钮）。因此本方案采用在 App 内集成 AVFoundation 相机预览的方式，用户可以在本 App 内完成焦距、亮度调整并自动拍照，体验更流畅且符合 App Store 审核要求。

## 项目结构

```
AutoShutter/
├── project.yml                      # XcodeGen 项目配置
├── AutoShutter/
│   ├── AutoShutterApp.swift          # App 入口
│   ├── ContentView.swift             # 主界面（UI + 交互逻辑）
│   ├── CameraManager.swift           # 相机管理（AVFoundation 封装）
│   ├── CameraPreviewView.swift       # 相机预览视图（UIViewRepresentable）
│   ├── Info.plist                    # 权限与配置
│   └── Assets.xcassets/              # 图标与颜色资源
│       ├── AppIcon.appiconset/
│       ├── AccentColor.colorset/
│       └── Contents.json
└── README.md
```

## 构建方法

### 方法一：使用 XcodeGen（推荐）

```bash
# 安装 XcodeGen（如果尚未安装）
brew install xcodegen

# 进入项目目录
cd AutoShutter

# 生成 Xcode 工程
xcodegen generate

# 打开工程
open AutoShutter.xcodeproj
```

### 方法二：手动在 Xcode 中创建

1. 打开 Xcode → Create a new Xcode project
2. 选择 **App** 模板
3. 填写：
   - Product Name: `AutoShutter`
   - Bundle Identifier: `com.autoshutter.app`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Minimum Deployments: **iOS 18.1**
4. 将 `AutoShutter/` 目录下的 4 个 `.swift` 文件拖入项目
5. 将 `Info.plist` 中的权限描述添加到项目的 Info 设置中
6. 确保 `Assets.xcassets` 已导入

## 需要配置的权限

在 Xcode 的 Target → Info 中确认以下权限已添加：

| Key                                 | 说明     |
| ----------------------------------- | ------ |
| `NSCameraUsageDescription`          | 相机使用说明 |
| `NSPhotoLibraryAddUsageDescription` | 相册写入说明 |

## 使用方法

1. 打开 App，首次使用会请求 **相机** 和 **相册** 权限，请点击「允许」
2. 相机界面与 iPhone 原相机一致：
   - 单击画面 → 对焦（黄色对焦框）
   - 按住对焦框上下拖动 → 调节曝光（小太阳）
   - 双指捏合 → 变焦
   - 上下滑动 → 切换前后摄像头
   - 左右滑动 → 切换照片/视频模式
3. 需要自动拍照时，点击右上角 **⏱ 按钮** 弹出操作面板
4. 在面板中设置 **拍照间隔**（1~60秒），点击 **「开始」** → 立即拍第一张，然后按间隔循环拍摄
5. 点击 **「结束」** → 停止自动拍照
6. 所有照片已自动保存到系统相册

## 核心代码说明

### CameraManager.swift

- `AVCaptureSession` 配置后置/前置广角摄像头
- `AVCapturePhotoOutput` 处理拍照和图片输出
- `AVCaptureMovieFileOutput` 处理视频录制
- `focus(at:)` 点击对焦（设备坐标）
- `setExposureTargetBias(_:)` 曝光补偿（亮度调节）
- `setZoom(_:)` 变焦控制
- `switchCamera()` 前后摄像头切换
- `cycleFlash()` / `toggleTorch()` 闪光灯 / 手电筒
- `startAutoCapture(interval:)` 启动定时拍照（立即拍第一张 + 链式单次定时器循环）
- `secondsUntilNextCapture` 倒计时剩余时间（自动拍照运行时供 UI 显示）
- `isShutterSoundSuppressionEnabled`（iOS 18+）静音时抑制系统快门声（`isMuted` 控制）
- `stopAutoCapture()` 停止定时拍照
- 照片/视频通过 `PHAssetCreationRequest` 保存到相册

### ContentView.swift

- SwiftUI 主界面，对齐 iPhone 原相机布局：顶部控制栏 + 底部模式条/快门/翻转按钮
- 对焦框 + 小太阳曝光调节、变焦环、快门按压动画
- 右上角 ⏱ 浮动面板：间隔设置 + 开始/结束
- 倒计时提示：顶部胶囊 + 最后 3 秒大数字（`countdownOverlay`）
- 网格线（`GridView`）、水平仪（`LevelIndicatorView` + `LevelMonitor`，CoreMotion 重力监测俯拍姿态）
- 磨砂玻璃材质（`.ultraThinMaterial`）

### CameraPreviewView.swift

- `UIViewRepresentable` 包装 `AVCaptureVideoPreviewLayer`
- 内置 UIKit 手势：单击对焦、单指滑动（切模式/切摄像头/调曝光）、双指捏合变焦
- 通过闭包回调与 SwiftUI 层交互

## 后续可扩展功能

- [x] 前后摄像头切换
- [x] 闪光灯模式选择（自动/开/关）
- [x] 拍照倒计时提示
- [x] 后台保活（屏幕常亮）
- [x] 拍照音效
- [x] 网格线 / 水平仪

## 生成 IPA 安装包

### 方式一：GitHub Actions 云端编译（推荐，无需本地安装 Xcode）

1. 在 GitHub 创建一个新仓库（如 `AutoShutter`）
2. 将本项目所有文件推送到该仓库
3. GitHub Actions 会自动触发编译（`.github/workflows/build-ipa.yml`）
4. 编译完成后，在仓库的 **Actions** 标签页找到对应的运行记录
5. 在运行记录底部的 **Artifacts** 区域下载 `AutoShutter-IPA` 压缩包
6. 解压后得到 `AutoShutter-unsigned.ipa`

> 也可以在 GitHub 仓库页面点击 **Actions** → **Build iOS IPA** → **Run workflow** 手动触发

### 方式二：本地编译（需安装 Xcode 16+）

```bash
# 进入项目目录
cd AutoShutter

# 一键编译（使用脚本）
./scripts/build-local.sh

# 或手动执行：
# 1. 生成项目
xcodegen generate

# 2. 编译 archive（无签名）
xcodebuild archive \
    -project AutoShutter.xcodeproj \
    -scheme AutoShutter \
    -archivePath build/AutoShutter.xcarchive \
    -sdk iphoneos \
    -configuration Release \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO

# 3. 打包 IPA
mkdir -p build/Payload
cp -r build/AutoShutter.xcarchive/Products/Applications/AutoShutter.app build/Payload/
cd build && zip -r AutoShutter-unsigned.ipa Payload/
```

### 将 IPA 安装到 iPhone

生成的 IPA 是未签名的，需要通过以下方式之一安装：

**方法 A：使用 Xcode 直接安装（推荐）**
1. 用 USB 连接 iPhone 到 Mac
2. 在 Xcode 中打开 `Window → Devices and Simulators`
3. 将 `.ipa` 拖入设备列表
4. 在 iPhone 上信任开发者证书（设置 → 通用 → VPN与设备管理）

**方法 B：使用 Sideloadly（Windows/Mac 通用）**
1. 下载 [Sideloadly](https://sideloadly.io/)
2. 用 Apple ID 签名安装 IPA
3. 在 iPhone 上信任开发者证书

**方法 C：使用 AltStore**
1. 在 Mac 上安装 [AltServer](https://altstore.io/)
2. 通过 AltStore 安装 IPA
3. 每 7 天需重新签名（免费 Apple ID 限制）

> 注意：免费 Apple ID 签名的 App 有效期为 7 天，需定期重新签名。付费开发者账号（$99/年）可签名 1 年。
