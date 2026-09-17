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
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "-X main.version=$VERSION" -o bin/tsmux-arm64 .
GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "-X main.version=$VERSION" -o bin/tsmux-amd64 .
lipo -create -output bin/tsmux bin/tsmux-arm64 bin/tsmux-amd64
rm -f bin/tsmux-arm64 bin/tsmux-amd64

echo "==> building menu bar app"
(cd macos && swift build -c release --arch arm64 --arch x86_64)

# Ask SwiftPM where it put the product rather than hardcoding a path: the
# layout moved between toolchains, and a stale binary left at the old path
# meant the copy below silently shipped an old build for hours.
APP_BIN=$(cd macos && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/TSMuxMenu
if [ ! -x "$APP_BIN" ]; then
  echo "swift build reported no product at $APP_BIN" >&2
  exit 1
fi
newest_src=$(find macos/Sources macos/Package.swift -type f -newer "$APP_BIN" -print -quit)
if [ -n "$newest_src" ]; then
  echo "$APP_BIN is older than $newest_src — the build did not pick up changes" >&2
  exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$APP_BIN" "$APP/Contents/MacOS/TSMux"

# The icon is generated from the same geometry as the menu bar mark, so the
# two cannot drift apart and no binary asset is checked in.
ICONSET=$(mktemp -d)/AppIcon.iconset
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION#v}</string>
  <key>CFBundleVersion</key><string>${VERSION#v}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# The floor is declared in two places — this plist and the binary's own
# LC_BUILD_VERSION — with nothing tying them together. When they disagree the
# app passes Launch Services and dies in dyld, and because it is LSUIElement
# the user sees nothing happen at all.
plist_floor=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
binary_floor=$(otool -l "$APP/Contents/MacOS/TSMux" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
if [ "$plist_floor" != "$binary_floor" ]; then
  echo "Info.plist says macOS $plist_floor but the binary is built for $binary_floor" >&2
  exit 1
fi
echo "==> floor: macOS $plist_floor (plist and binary agree)"

echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/tsmux"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "built $APP ($VERSION)"
