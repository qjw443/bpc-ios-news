#!/usr/bin/env bash
# 在 macOS 上本地出「未签名 IPA」。用法：bash scripts/build_unsigned_ipa.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ios"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo ">> 安装 xcodegen ..."
  brew install xcodegen
fi

echo ">> 生成工程"
xcodegen generate

echo ">> 编译（关闭签名）"
rm -rf build Payload BPCNews-unsigned.ipa
xcodebuild \
  -project BPCNews.xcodeproj \
  -scheme BPCNews \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  build

APP="build/Build/Products/Release-iphoneos/BPCNews.app"
if [ ! -d "$APP" ]; then
  echo "!! 没找到 .app，检查编译输出"; find build -name "*.app" -maxdepth 6; exit 1
fi

echo ">> 打包"
mkdir -p Payload
cp -R "$APP" Payload/
zip -qry BPCNews-unsigned.ipa Payload

echo ">> 产物"
ls -lh BPCNews-unsigned.ipa
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist" || true
/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$APP/Info.plist" || true
