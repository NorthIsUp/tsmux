#!/usr/bin/env bash
# Assemble TSMux.app: the Swift menu bar front end with the tsmux CLI bundled
# inside it, so the app and the daemon are always the same build.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="${1:-$ROOT/bin/TSMux.app}"
# VERSION file is the single source of truth, shared with the release workflow.
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

echo "==> building tsmux (universal)"
mkdir -p bin
GOOS=darwin GOARCH=arm64 go build -ldflags "-X main.version=$VERSION" -o bin/tsmux-arm64 .
GOOS=darwin GOARCH=amd64 go build -ldflags "-X main.version=$VERSION" -o bin/tsmux-amd64 .
lipo -create -output bin/tsmux bin/tsmux-arm64 bin/tsmux-amd64
rm -f bin/tsmux-arm64 bin/tsmux-amd64

echo "==> building menu bar app"
(cd macos && swift build -c release --arch arm64 --arch x86_64)

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp macos/.build/apple/Products/Release/TSMuxMenu "$APP/Contents/MacOS/TSMux"
cp bin/tsmux "$APP/Contents/Resources/tsmux"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TSMux</string>
  <key>CFBundleDisplayName</key><string>TSMux</string>
  <key>CFBundleIdentifier</key><string>dev.northisup.tsmux.menu</string>
  <key>CFBundleExecutable</key><string>TSMux</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION#v}</string>
  <key>CFBundleVersion</key><string>${VERSION#v}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/tsmux"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "built $APP ($VERSION)"
