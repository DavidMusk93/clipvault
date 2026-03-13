#!/bin/bash

echo "========================================="
echo "  📋 ClipFlow - 快速开始指南"
echo "========================================="
echo ""

# 检查 Xcode
if [ -d "/Applications/Xcode.app" ]; then
    echo "✅ Xcode 已安装"
else
    echo "⚠️  未检测到 Xcode.app"
    echo ""
    echo "请从 App Store 安装 Xcode，或运行："
    echo "  xcode-select --install"
    echo ""
fi

# 检查项目文件
if [ -f "ClipFlow.xcodeproj/project.pbxproj" ]; then
    echo "✅ 项目文件存在"
else
    echo "❌ 项目文件缺失"
    exit 1
fi

echo ""
echo "========================================="
echo "  🚀 运行方式"
echo "========================================="
echo ""
echo "方式 1: 双击打开（最简单）"
echo "  直接双击 ClipFlow.xcodeproj 文件"
echo ""
echo "方式 2: 使用 open 命令"
echo "  open ClipFlow.xcodeproj"
echo ""
echo "方式 3: 使用 run.sh"
echo "  ./run.sh"
echo ""
echo "========================================="
echo "  在 Xcode 中："
echo "  1. 选择顶部的 'My Mac' 目标"
echo "  2. 点击 ▶️ 按钮，或按 Cmd+R"
echo "========================================="
echo ""

# 询问是否打开项目
read -p "是否现在打开项目？(y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    open ClipFlow.xcodeproj
    echo "✅ 项目已在 Xcode 中打开！"
fi
