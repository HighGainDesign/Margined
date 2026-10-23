#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Margined"
BUNDLE_ID="design.highgain.margined"
SIGNING_IDENTITY="${MARGINED_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ { print $2; exit }')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')"
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
BUILD_DIR="${MARGINED_BUILD_DIR:-/tmp/Margined-build-$(id -u)}"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"
cd "$ROOT_DIR"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
# XCTest uses ad-hoc signing. Recreate the two product bundles so Xcode cannot
# keep a stale embedded extension when switching back to a developer identity.
rm -rf "$APP_BUNDLE" "$BUILD_DIR/Build/Products/Debug/MarginedQuickLook.appex"
xcodegen generate
xcodebuild -project Margined.xcodeproj -scheme Margined -configuration Debug -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" build >build.log 2>&1 || {
  tail -80 build.log >&2
  exit 1
}
case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "Margined built and launched: $APP_BUNDLE" ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
