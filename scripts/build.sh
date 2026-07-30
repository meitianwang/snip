#!/bin/bash
# 构建 Snip.app（无需 Xcode，仅需 Command Line Tools）
set -e
cd "$(dirname "$0")/.."

echo "▸ 编译 (release)…"
swift build -c release

APP="build/Snip.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Snip "$APP/Contents/MacOS/Snip"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ Ad-hoc 签名…"
codesign --force --sign - "$APP"

echo "✅ 构建完成: $(pwd)/$APP"
echo "   运行: open $APP"
