#!/bin/bash
# 本地编译脚本 — 需要安装 Xcode 16+
# 用法: ./scripts/build-local.sh

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

echo "=== AutoShutter 本地编译 ==="
echo "项目目录: $PROJECT_DIR"
echo ""

# 1. 检查 Xcode
if ! command -v xcodebuild &>/dev/null; then
    echo "错误: 未找到 xcodebuild，请确认已安装完整版 Xcode"
    exit 1
fi

XCODE_VERSION=$(xcodebuild -version | head -1)
echo "Xcode: $XCODE_VERSION"
echo ""

# 2. 生成项目（如果有 xcodegen）
if command -v xcodegen &>/dev/null; then
    echo "使用 XcodeGen 生成项目..."
    xcodegen generate
else
    echo "提示: 未安装 XcodeGen，使用已有的 .xcodeproj"
    if [ ! -d "AutoShutter.xcodeproj" ]; then
        echo "错误: 未找到 AutoShutter.xcodeproj"
        echo "请安装 XcodeGen: brew install xcodegen"
        exit 1
    fi
fi

# 3. 编译 Archive（无签名）
echo ""
echo "编译 Archive..."
xcodebuild archive \
    -project AutoShutter.xcodeproj \
    -scheme AutoShutter \
    -archivePath build/AutoShutter.xcarchive \
    -sdk iphoneos \
    -configuration Release \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    IPHONEOS_DEPLOYMENT_TARGET=17.0

# 4. 打包 IPA
echo ""
echo "打包 IPA..."
mkdir -p build/Payload
cp -r build/AutoShutter.xcarchive/Products/Applications/AutoShutter.app build/Payload/
cd build
rm -f AutoShutter-unsigned.ipa
zip -r AutoShutter-unsigned.ipa Payload/

echo ""
echo "✓ 编译完成!"
echo "IPA 文件: $PROJECT_DIR/build/AutoShutter-unsigned.ipa"
ls -lh AutoShutter-unsigned.ipa
