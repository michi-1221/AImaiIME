#!/bin/bash
# 入力メソッドの .app をビルドする（インストールはしない）。
#   出力: ime/build/AImaiIME.app
set -euo pipefail

cd "$(dirname "$0")/.."
IME_DIR=$(pwd)

./scripts/fetch-deps.sh

swift build -c release --product AImaiIME
BIN_DIR=$(swift build -c release --show-bin-path)

APP="$IME_DIR/build/AImaiIME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp "$BIN_DIR/AImaiIME" "$APP/Contents/MacOS/AImaiIME"
ditto vendor/llama.xcframework/macos-arm64_x86_64/llama.framework "$APP/Contents/Frameworks/llama.framework"

cp Sources/AImaiIME/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

swift scripts/make-icon.swift "$APP/Contents/Resources/icon.tiff"
# 同梱する llama.cpp などのライセンス表示
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp ../LICENSE "$APP/Contents/Resources/LICENSE"

# アドホック署名（自分の Mac で使うだけなので Developer ID は不要）
codesign --force --sign - "$APP/Contents/Frameworks/llama.framework"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "ビルド完了: $APP"
