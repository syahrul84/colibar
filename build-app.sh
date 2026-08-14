#!/bin/bash
# Builds Colibar.app from the SwiftPM package and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Colibar"
APP_BUNDLE="$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release --product "$APP_NAME"

BINARY=".build/release/$APP_NAME"
[ -x "$BINARY" ] || { echo "error: $BINARY not found" >&2; exit 1; }

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundle (menu bar mark etc.) — Bundle.module finds it in
# Contents/Resources at runtime.
cp -R ".build/release/Colibar_Colibar.bundle" "$APP_BUNDLE/Contents/Resources/"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP_BUNDLE"

echo "==> done: $PWD/$APP_BUNDLE"

# ./build-app.sh install — also install to /Applications. Running the app
# from inside ~/Documents makes macOS TCC re-assess the bundle on every
# rebuild, which can wedge file access at launch; /Applications avoids that.
#
# ./build-app.sh run — install AND launch by exec'ing the binary directly.
# `open` routes through LaunchServices, and Gatekeeper re-assesses every
# freshly ad-hoc-signed build — which can stall the launch for minutes.
# Direct exec skips that path entirely; use this for the dev loop.
# (A paid-program Developer ID + notarization is the real fix if this app
# is ever distributed.)
if [ "${1:-}" = "install" ] || [ "${1:-}" = "run" ]; then
  echo "==> installing to /Applications/$APP_BUNDLE"
  rm -rf "/Applications/$APP_BUNDLE"
  ditto "$APP_BUNDLE" "/Applications/$APP_BUNDLE"
  echo "==> installed"
fi
if [ "${1:-}" = "run" ]; then
  pkill -9 -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  sleep 0.5
  nohup "/Applications/$APP_BUNDLE/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 &
  echo "==> launched (direct exec)"
fi

# ./build-app.sh package — zip the bundle for a GitHub release. The in-app
# updater downloads the release's .zip asset, so every release needs one.
if [ "${1:-}" = "package" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")
  ZIP="$APP_NAME-v$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"
  echo "==> packaged: $PWD/$ZIP (attach to the v$VERSION GitHub release)"
fi
