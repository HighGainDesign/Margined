#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-package}"
BUILD_DIR="${MARGINED_RELEASE_DIR:-/tmp/Margined-release-$(id -u)}"
IDENTITY="${MARGINED_SIGNING_IDENTITY:-Developer ID Application}"
TEAM_ID="${MARGINED_TEAM_ID:-$(security find-certificate -c "$IDENTITY" -p | openssl x509 -noout -subject -nameopt RFC2253 | sed -n 's/.*OU=\([^,]*\).*/\1/p')}"
[[ -n "$TEAM_ID" ]] || { echo 'Set MARGINED_TEAM_ID to the Developer ID signing team.' >&2; exit 1; }
PROFILE="${MARGINED_NOTARY_PROFILE:-Notarize}"
if [[ -n "${MARGINED_NOTARY_API_KEY_PATH:-}" ]]; then
  : "${MARGINED_NOTARY_API_KEY_ID:?Set the notarization API key ID.}"
  : "${MARGINED_NOTARY_ISSUER_ID:?Set the notarization API issuer ID.}"
  NOTARY_ARGS=(--key "$MARGINED_NOTARY_API_KEY_PATH" --key-id "$MARGINED_NOTARY_API_KEY_ID" --issuer "$MARGINED_NOTARY_ISSUER_ID")
else
  NOTARY_ARGS=(--keychain-profile "$PROFILE")
  if [[ -n "${MARGINED_NOTARY_KEYCHAIN:-}" ]]; then
    NOTARY_ARGS+=(--keychain "$MARGINED_NOTARY_KEYCHAIN")
  fi
fi
NOTARY_TIMEOUT="${MARGINED_NOTARY_TIMEOUT:-15m}"
APP="$BUILD_DIR/Build/Products/Release/Margined.app"
LOG="$BUILD_DIR/build.log"
mkdir -p "$BUILD_DIR" dist
xcodegen generate
xcodebuild -project Margined.xcodeproj -scheme Margined -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$BUILD_DIR" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS='--timestamp' \
  build >"$LOG" 2>&1 || { tail -80 "$LOG" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
for BUNDLE in "$APP" "$APP/Contents/PlugIns/MarginedQuickLook.appex"; do
  lipo -archs "$BUNDLE/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$BUNDLE/Contents/Info.plist")" | grep -q 'x86_64.*arm64\|arm64.*x86_64'
  codesign -d --entitlements - --xml "$BUNDLE" 2>/dev/null >"$BUILD_DIR/entitlements-check.plist"
  if /usr/libexec/PlistBuddy -c 'Print com.apple.security.get-task-allow' "$BUILD_DIR/entitlements-check.plist" >/dev/null 2>&1; then
    echo 'Release must not contain the debugger-attach entitlement.' >&2; exit 1
  fi
done
[[ "$MODE" != '--build-only' ]] || { echo "$APP"; exit 0; }
# Staple the app separately so it remains trusted after dragging out of the DMG.
if [[ "$MODE" != '--skip-notarize' ]]; then
  ditto -c -k --keepParent --norsrc "$APP" "$BUILD_DIR/Margined-notary.zip"
  xcrun notarytool submit "$BUILD_DIR/Margined-notary.zip" "${NOTARY_ARGS[@]}" --wait --timeout "$NOTARY_TIMEOUT"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi
STAGE="$BUILD_DIR/installer"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto --norsrc --noextattr "$APP" "$STAGE/Margined.app"
codesign --verify --deep --strict "$STAGE/Margined.app"
if [[ "$MODE" != '--skip-notarize' ]]; then xcrun stapler validate "$STAGE/Margined.app"; fi
ln -s /Applications "$STAGE/Applications"
DMG_PYTHON="${MARGINED_DMG_PYTHON:-python3}"
"$DMG_PYTHON" "$ROOT_DIR/script/package_dmg.py" "$STAGE"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$ROOT_DIR/dist/Margined-$VERSION.dmg"
hdiutil create -volname Margined -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
if [[ "$MODE" != '--skip-notarize' ]]; then
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait --timeout "$NOTARY_TIMEOUT"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type execute --verbose "$APP"
fi
(cd "$ROOT_DIR/dist"; shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
# Preserve the signed app as an archive, not another discoverable .app copy.
# Running apps from build/staging folders pollutes macOS's extension app list.
ditto -c -k --keepParent --norsrc "$APP" "$BUILD_DIR/Margined-signed-app.zip"
LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister'
pluginkit -r "$STAGE/Margined.app/Contents/PlugIns/MarginedQuickLook.appex" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$STAGE/Margined.app" >/dev/null 2>&1 || true
rm -rf "$STAGE"
if [[ "${MARGINED_KEEP_BUILD_APP:-0}" != '1' ]]; then
  pluginkit -r "$APP/Contents/PlugIns/MarginedQuickLook.appex" >/dev/null 2>&1 || true
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  rm -rf "$APP" "$BUILD_DIR/Build/Products/Release/MarginedQuickLook.appex"
  "$LSREGISTER" -gc
fi
echo "Ready: $DMG"
