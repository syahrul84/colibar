#!/bin/bash
# Sign an .app with the Developer ID certificate, send it to Apple's notary
# service, staple the ticket, and zip it for a GitHub release. A notarized app
# opens normally on other Macs, with no right-click → Open step.
#
#   scripts/notarize.sh <path/to/App.app> <path/to/output.zip> <entitlements>
#
# One-time setup:
#   1. Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application
#      (team: Syahrul Farhan Rabain, 3UZAQDJ7T4).
#   2. Make an app-specific password at account.apple.com, then run:
#        xcrun notarytool store-credentials ginlabs-notary \
#          --apple-id syahrul.farhan@gmail.com --team-id 3UZAQDJ7T4
#      (it asks for that password and keeps it in your keychain).
set -euo pipefail

APP="$1"; ZIP="$2"; ENTITLEMENTS="$3"
PROFILE="${NOTARY_PROFILE:-ginlabs-notary}"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application: .*\(3UZAQDJ7T4\)/ {print $2; exit}')
if [ -z "$IDENTITY" ]; then
  echo "error: no 'Developer ID Application' certificate for team 3UZAQDJ7T4 in the keychain." >&2
  echo "       Create one in Xcode → Settings → Accounts → Manage Certificates." >&2
  exit 1
fi

echo "==> signing with $IDENTITY (hardened runtime)"
# Sign nested Mach-O files first (inside-out), then the app itself. No --deep:
# it is deprecated for signing and skips entitlements on nested code.
find "$APP/Contents" -type f ! -path "*/Contents/MacOS/*" -print0 \
  | while IFS= read -r -d '' f; do
      if file -b "$f" | grep -q "Mach-O"; then
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$f"
      fi
    done
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "==> sending to Apple's notary service (usually 1–5 minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --timeout 30m

echo "==> stapling the ticket and re-zipping"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
echo "==> notarized: $ZIP"
