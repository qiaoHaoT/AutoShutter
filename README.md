# 自动快门 AutoShutter

一款 iOS 自动定时拍照 App，支持自定义间隔时间、对焦、曝光（亮度）和变焦调节。

## 功能说明

- **间隔定时拍照**：设置 1~60 秒的间隔时间，自动连续拍摄
- **开始/结束按钮**：点击「开始」启动自动拍照，点击「结束」停止
- **相机预览**：App 内直接显示相机实时画面
- **对焦**：点击屏幕中心进行自动对焦
- **变焦**：滑动条或双指缩放调整焦距
- **亮度调节**：曝光补偿滑块（-2 ~ +2 EV）
- **自动保存**：拍摄的照片自动保存到系统相册
- **拍照计数**：实时显示已拍摄张数

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
2. 在底部设置 **拍照间隔**（1~60秒，拖动滑块）
3. 根据需要调节 **变焦** 和 **亮度** 滑块
4. 点击屏幕可触发对焦
5. 点击 **「开始」** 按钮 → 自动拍照开始，立即拍第一张，然后按间隔时间继续拍摄
6. 点击 **「结束」** 按钮 → 停止自动拍照
7. 所有照片已自动保存到系统相册

## 核心代码说明

### CameraManager.swift

- `AVCaptureSession` 配置后置广角摄像头
- `AVCapturePhotoOutput` 处理拍照和图片输出
- `focus(at:)` 点击对焦
- `setExposureTargetBias(_:)` 曝光补偿（亮度调节）
- `setZoom(_:)` 变焦控制
- `startAutoCapture(interval:)` 启动定时拍照（立即拍第一张 + Timer 循环）
- `stopAutoCapture()` 停止定时拍照
- 照片通过 `PHAssetCreationRequest` 保存到相册

### ContentView.swift

- SwiftUI 主界面，使用 `.ultraThinMaterial` 磨砂玻璃效果
- 底部面板：间隔滑块、变焦滑块、亮度滑块、开始/结束按钮
- 顶部栏：已拍张数、运行状态、间隔时间
- 手势：点击对焦 + 双指缩放

## 后续可扩展功能

- [x] 前后摄像头切换
- [ ] 闪光灯模式选择（自动/开/关）
- [ ] 拍照倒计时提示
- [x] 照片分辨率选择
- [ ] 视频录制定时
- [x] 后台保活（屏幕常亮）
- [ ] 拍照音效

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
