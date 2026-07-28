#!/usr/bin/env bash
# Build (optional) a DMG and publish it to GitHub Releases.
#
# Usage:
#   ./scripts/publish-release.sh                 # build + publish Info.plist version
#   ./scripts/publish-release.sh 0.1.1           # build + publish v0.1.1
#   ./scripts/publish-release.sh --skip-build    # upload existing dist/EyesOnYou-*.dmg
#   ./scripts/publish-release.sh --draft 0.1.1
#
# Requires: gh (authenticated), and build-dmg.sh prerequisites unless --skip-build.
#
# On CI, GITHUB_REF=refs/tags/vX.Y.Z selects the version automatically.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST_DIR="${DIST_DIR:-$ROOT/dist}"
SKIP_BUILD=0
DRAFT=0
PRERELEASE=0
VERSION_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    --draft) DRAFT=1; shift ;;
    --prerelease) PRERELEASE=1; shift ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      VERSION_ARG="$1"
      shift
      ;;
  esac
done

normalize_version() {
  local v="${1:-}"
  v="${v#v}"
  v="${v#V}"
  echo "$v"
}

resolve_version() {
  if [[ -n "$VERSION_ARG" ]]; then
    normalize_version "$VERSION_ARG"
    return
  fi
  if [[ -n "${VERSION:-}" ]]; then
    normalize_version "$VERSION"
    return
  fi
  if [[ "${GITHUB_REF:-}" == refs/tags/v* ]]; then
    normalize_version "${GITHUB_REF#refs/tags/}"
    return
  fi
  if [[ -f "$ROOT/App/EyesOnYou/Info.plist" ]]; then
    /usr/libexec/PlistBuddy -c \
      'Print :CFBundleShortVersionString' "$ROOT/App/EyesOnYou/Info.plist"
    return
  fi
  normalize_version "$(tr -d '[:space:]' < "$DIST_DIR/version.txt")"
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing required tool: $1" >&2
    exit 1
  }
}

need gh

VERSION="$(resolve_version)"
TAG="v${VERSION}"
DMG_PATH="$DIST_DIR/EyesOnYou-${VERSION}.dmg"

echo "==> publish GitHub Release"
echo "    tag: $TAG"
echo "    dmg: $DMG_PATH"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  "$ROOT/scripts/build-dmg.sh" "$VERSION"
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "error: expected DMG not found: $DMG_PATH" >&2
  echo "Run ./scripts/build-dmg.sh $VERSION first or drop --skip-build." >&2
  exit 1
fi

NOTES_FILE="$DIST_DIR/release-notes.md"
VERSION_NOTES="$ROOT/docs/releases/${TAG}.md"
if [[ -f "$VERSION_NOTES" ]]; then
  cp "$VERSION_NOTES" "$NOTES_FILE"
else
  cat > "$NOTES_FILE" <<EOF
## EyesOnYou ${VERSION}

### Install
1. Download \`EyesOnYou-${VERSION}.dmg\`
2. Open the disk image and drag **EyesOnYou** into **Applications**
3. Launch from Applications

### Notes
- EyesOnYou measures live socket activity and whole-Mac network totals while it is running.
- Traffic that cannot be matched safely to an app or route is shown as **Unattributed** instead of being discarded.
- The GitHub download is ad-hoc signed and is not notarized. Network Extension features still need Developer ID signing and user approval.
- In-app update checks this Releases page for \`.dmg\` / \`.pkg\` / \`.zip\` assets.
EOF
fi

GH_ARGS=(release create "$TAG" "$DMG_PATH" --title "EyesOnYou ${VERSION}" --notes-file "$NOTES_FILE")
if [[ "$DRAFT" -eq 1 ]]; then
  GH_ARGS+=(--draft)
fi
if [[ "$PRERELEASE" -eq 1 ]]; then
  GH_ARGS+=(--prerelease)
fi

# If the release already exists, replace the asset and refresh title/notes.
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "==> release $TAG exists — uploading asset and refreshing metadata"
  gh release upload "$TAG" "$DMG_PATH" --clobber
  gh release edit "$TAG" --title "EyesOnYou ${VERSION}" --notes-file "$NOTES_FILE"
  # Drop legacy FlowLens asset name if still attached to this tag.
  if gh release view "$TAG" --json assets --jq '.assets[].name' | grep -qx "FlowLens-${VERSION}.dmg"; then
    gh release delete-asset "$TAG" "FlowLens-${VERSION}.dmg" --yes || true
  fi
  echo "==> updated https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$TAG"
else
  echo "==> creating release $TAG"
  # Local runs: ensure the annotated tag exists and is pushed.
  # On GitHub Actions the tag is already present (push trigger) or created by the workflow.
  if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
    if ! git rev-parse "$TAG" >/dev/null 2>&1; then
      git tag -a "$TAG" -m "EyesOnYou ${VERSION}"
    fi
    git push origin "$TAG"
  fi
  gh "${GH_ARGS[@]}"
fi

echo "==> done"
gh release view "$TAG" --json url,tagName,assets --jq '{url,tagName,assets:[.assets[].name]}'
