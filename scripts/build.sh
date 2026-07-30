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

echo "▸ 签名…"
# 优先用本机固定证书（重建不丢屏幕录制权限），没有则退回 ad-hoc
IDENTITY="Snip Dev Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "  (未找到 $IDENTITY，使用 ad-hoc 签名，重建后需重新授权)"
    codesign --force --sign - "$APP"
fi

echo "✅ 构建完成: $(pwd)/$APP"
echo "   运行: open $APP"
