#!/bin/bash
# 构建 BatchOCR.app 与 sample_tool
set -euo pipefail
cd "$(dirname "$0")"

APP="build/BatchOCR.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

echo "[1/3] 编译主程序（GUI + CLI）..."
swiftc -O -swift-version 5 Sources/main.swift -o "$APP/Contents/MacOS/BatchOCR"

echo "[2/3] 写入 Info.plist 并签名..."
cp resources/Info.plist "$APP/Contents/Info.plist"
if [ -f resources/AppIcon.icns ]; then
  cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force -s - "$APP" 2>/dev/null || true

echo "[3/3] 编译验证工具 sample_tool..."
swiftc -O -swift-version 5 tools/sample_tool.swift -o build/sample_tool

echo "完成：$APP"
