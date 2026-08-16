#!/bin/bash
#
# AutoShutter 一键推送脚本
# 使用方法: ./push-to-github.sh <你的GitHub用户名>
# 示例:    ./push-to-github.sh qiaohaoting
#

set -e

# 检查参数
if [ -z "$1" ]; then
    echo "用法: ./push-to-github.sh <你的GitHub用户名>"
    echo "示例: ./push-to-github.sh qiaohaoting"
    exit 1
fi

USERNAME="$1"
REPO_NAME="AutoShutter"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$PROJECT_DIR"

# 设置 remote
if git remote get-url origin >/dev/null 2>&1; then
    echo "更新 remote 地址..."
    git remote set-url origin "https://github.com/$USERNAME/$REPO_NAME.git"
else
    echo "添加 remote..."
    git remote add origin "https://github.com/$USERNAME/$REPO_NAME.git"
fi

echo ""
echo "=========================================="
echo "  准备推送到 GitHub"
echo "=========================================="
echo "仓库地址: https://github.com/$USERNAME/$REPO_NAME"
echo "分支: main"
echo "文件数: $(git ls-files | wc -l | tr -d ' ')"
echo ""
echo "即将执行: git push -u origin main"
echo ""

# 推送
git push -u origin main

if [ $? -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "  推送成功！"
    "=========================================="
    echo ""
    echo "下一步:"
    echo "1. 打开 https://github.com/$USERNAME/$REPO_NAME/actions"
    echo "2. 等待编译完成（约 5~10 分钟）"
    echo "3. 点击最新的运行记录 → 底部 Artifacts → 下载 AutoShutter-IPA"
    echo ""
else
    echo ""
    echo "推送失败。请检查:"
    echo "- 是否已在 GitHub 创建仓库: https://github.com/new"
    echo "- 仓库名是否为: $REPO_NAME"
    echo "- 仓库可见性选 Private 或 Public 均可"
    echo "- 不要勾选 Add README / .gitignore / license（避免冲突）"
    exit 1
fi
