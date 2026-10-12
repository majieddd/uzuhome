#!/bin/bash
# Builds "dist/uzu Home.app" with swiftc (no Xcode project) and dist/UzuHome.zip for a release.
#   ./build.sh             release build in dist/
#   ./build.sh dev         build in dist/dev/, so a running copy is never in the way
#   ./build.sh --install   release build, then copy it to ~/Applications (quit the running app first)
# The uzu engine comes from engine/uzu (tools/build-engine.sh makes it). Without it the build stops, unless
# UZU_HOME_NO_ENGINE=1 (CI checks, which don't run a model).
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(tr -d ' \n' <VERSION)
OUT=dist
[[ ${1:-} == dev ]] && OUT=dist/dev
APP="$OUT/uzu Home.app"
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
if [[ ! -x engine/uzu && ${UZU_HOME_NO_ENGINE:-0} != 1 ]]; then
  echo "engine/uzu is missing: run tools/build-engine.sh first (or UZU_HOME_NO_ENGINE=1 for a build without it)" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/fonts" "$APP/Contents/Resources/backend/bin"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library \
  -o "$APP/Contents/MacOS/UzuHome" src/*.swift

# icon: assets/icon-1024.png (tools/make_icon.swift) -> AppIcon.icns
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp assets/fonts/*.ttf assets/fonts/OFL.txt "$APP/Contents/Resources/fonts/"
B="$APP/Contents/Resources/backend"
cp backend/bin/* "$B/bin/"
cp -R backend/lib backend/share backend/patches "$B/"
cp backend/install.sh backend/models.conf backend/config.env.default "$B/"
if [[ -x engine/uzu ]]; then
  mkdir -p "$B/engine"
  cp engine/uzu engine/VERSION "$B/engine/"
fi
find "$B" -name __pycache__ -prune -exec rm -rf {} +
# the app reinstalls its backend scripts when this stamp differs from the installed one
echo "$VERSION+$( (cd backend && cat bin/* lib/* patches/*; find share -type f -exec cat {} +) | shasum -a 256 | cut -c1-12)" >"$B/VERSION"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>uzu Home</string>
  <key>CFBundleDisplayName</key><string>uzu Home</string>
  <key>CFBundleIdentifier</key><string>io.github.majieddd.uzuhome</string>
  <key>CFBundleExecutable</key><string>UzuHome</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License. Unofficial; not affiliated with Mirai, the makers of uzu.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
(cd "$OUT" && rm -f UzuHome.zip && ditto -c -k --keepParent "uzu Home.app" UzuHome.zip)
echo "built $APP ($VERSION, build $BUILD$([[ -x engine/uzu ]] && echo ", uzu $(cat engine/VERSION)" || echo ", no engine"))"
echo "zip   $OUT/UzuHome.zip  sha256 $(shasum -a 256 "$OUT/UzuHome.zip" | cut -d' ' -f1)"

if [[ ${1:-} == --install ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/uzu Home.app"
  ditto "$APP" "$HOME/Applications/uzu Home.app"
  echo "installed ~/Applications/uzu Home.app"
fi
