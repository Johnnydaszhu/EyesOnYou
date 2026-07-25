#!/usr/bin/env bash
# Build FlowLens.app (Release) and wrap it in a UDZO DMG under dist/.
#
# Usage:
#   ./scripts/build-dmg.sh              # version from App/FlowLens/Info.plist
#   ./scripts/build-dmg.sh 0.1.1        # override marketing version
#   VERSION=0.1.1 ./scripts/build-dmg.sh
#
# Env (optional):
#   CONFIGURATION         default Release
#   DERIVED_DATA          default <repo>/build/DerivedData
#   DIST_DIR              default <repo>/dist
#   CODE_SIGN_IDENTITY    default "-" (ad-hoc)
#   DEVELOPMENT_TEAM      Team ID when using a real signing identity
#   BUILD_NUMBER          CFBundleVersion (default 1)
#   NOTARIZE=1            submit DMG with notarytool (needs APPLE_ID / APPLE_TEAM_ID / APPLE_APP_SPECIFIC_PASSWORD)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
NOTARIZE="${NOTARIZE:-0}"

plist_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/App/FlowLens/Info.plist"
}

normalize_version() {
  local v="${1:-}"
  v="${v#v}"
  v="${v#V}"
  echo "$v"
}

if [[ -n "${1:-}" ]]; then
  VERSION="$(normalize_version "$1")"
elif [[ -n "${VERSION:-}" ]]; then
  VERSION="$(normalize_version "$VERSION")"
else
  VERSION="$(plist_version)"
fi

TAG="v${VERSION}"
DMG_NAME="FlowLens-${VERSION}.dmg"
STAGE="$DIST_DIR/dmg-stage"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing required tool: $1" >&2
    exit 1
  }
}

need xcodegen
need xcodebuild
need hdiutil
need ditto

echo "==> FlowLens DMG build"
echo "    version:       $VERSION  ($TAG)"
echo "    configuration: $CONFIGURATION"
echo "    sign identity: $CODE_SIGN_IDENTITY"
echo "    output:        $DIST_DIR/$DMG_NAME"

echo "==> xcodegen generate"
xcodegen generate

mkdir -p "$DIST_DIR" "$DERIVED_DATA"
rm -rf "$STAGE"
mkdir -p "$STAGE"

SIGN_ARGS=(
  "CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY"
  "CODE_SIGNING_ALLOWED=YES"
)
if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
  SIGN_ARGS+=("CODE_SIGNING_REQUIRED=NO")
else
  SIGN_ARGS+=("CODE_SIGNING_REQUIRED=YES")
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    SIGN_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
  fi
fi

echo "==> xcodebuild ($CONFIGURATION)"
xcodebuild \
  -project FlowLens.xcodeproj \
  -scheme FlowLens \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "platform=macOS" \
  "MARKETING_VERSION=$VERSION" \
  "CURRENT_PROJECT_VERSION=${BUILD_NUMBER:-1}" \
  "${SIGN_ARGS[@]}" \
  build

APP_PRODUCT="$DERIVED_DATA/Build/Products/$CONFIGURATION/FlowLens.app"
if [[ ! -d "$APP_PRODUCT" ]]; then
  echo "error: FlowLens.app not found at $APP_PRODUCT" >&2
  exit 1
fi

# Info.plist is static in-repo; stamp the marketing version onto the built bundle.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
  "$APP_PRODUCT/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" \
    "$APP_PRODUCT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" \
  "$APP_PRODUCT/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${BUILD_NUMBER:-1}" \
    "$APP_PRODUCT/Contents/Info.plist"

echo "==> stage DMG contents"
ditto "$APP_PRODUCT" "$STAGE/FlowLens.app"
ln -sf /Applications "$STAGE/Applications"

cat > "$STAGE/README.txt" <<EOF
FlowLens ${VERSION}

1. Drag FlowLens.app into Applications.
2. Launch FlowLens from Applications (or Spotlight).
3. System extension / filter features require a signed build and user approval.
   Ad-hoc CI builds run in demo-telemetry mode for UI development.

https://github.com/Johnnydaszhu/FlowLens
EOF

DMG_PATH="$DIST_DIR/$DMG_NAME"
rm -f "$DMG_PATH"

echo "==> create DMG"
hdiutil create \
  -volname "FlowLens ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG_PATH"

rm -rf "$DIST_DIR/FlowLens.app"
ditto "$APP_PRODUCT" "$DIST_DIR/FlowLens.app"

printf '%s\n' "$VERSION" > "$DIST_DIR/version.txt"
printf '%s\n' "$DMG_PATH" > "$DIST_DIR/dmg-path.txt"

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ -z "${APPLE_ID:-}" || -z "${APPLE_TEAM_ID:-}" || -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    echo "error: NOTARIZE=1 requires APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD" >&2
    exit 1
  fi
  echo "==> notarize DMG"
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG_PATH"
fi

rm -rf "$STAGE"

echo "==> done"
echo "    app: $DIST_DIR/FlowLens.app"
echo "    dmg: $DMG_PATH"
ls -lh "$DMG_PATH"
