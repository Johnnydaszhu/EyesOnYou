# Releasing EyesOnYou (DMG + GitHub Releases)

EyesOnYou ships UI builds as a **`.dmg`** attached to [GitHub Releases](https://github.com/Johnnydaszhu/FlowLens/releases). The in-app updater prefers assets ending in `.dmg`, then `.pkg`, then `.zip`.

## Quick paths

### A. GitHub Actions (recommended)

1. Bump `CFBundleShortVersionString` in `App/FlowLens/Info.plist` when cutting a real version.
2. Push a version tag:

```bash
git tag -a v0.1.0 -m "EyesOnYou 0.1.0"
git push origin v0.1.0
```

3. Workflow [`.github/workflows/release.yml`](../.github/workflows/release.yml) runs on `macos-14`, builds `EyesOnYou-0.1.0.dmg`, and publishes the Release.

Or: **Actions → Release DMG → Run workflow** and enter a version (creates the tag if missing).

### B. Local script

```bash
# Build only → dist/EyesOnYou-<version>.dmg
./scripts/build-dmg.sh
# or
./scripts/build-dmg.sh 0.1.1

# Build + create/upload GitHub Release (needs `gh auth login`)
./scripts/publish-release.sh
./scripts/publish-release.sh 0.1.1
./scripts/publish-release.sh --draft 0.1.1
```

## What the DMG contains

| Item | Purpose |
|---|---|
| `EyesOnYou.app` | Host app (+ embedded system extension bundle) |
| `Applications` | Symlink — drag-to-install |
| `README.txt` | Short install notes |

Default CI / script builds use **ad-hoc signing** (`CODE_SIGN_IDENTITY=-`). Those builds are for dashboard / demo telemetry. Live Network Extension capture still needs a paid team, Developer ID, notarization, and user approval.

## Signed + notarized builds (maintainer machine)

```bash
export CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export DEVELOPMENT_TEAM="TEAMID"
export NOTARIZE=1
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="TEAMID"
export APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"

./scripts/build-dmg.sh 0.1.1
./scripts/publish-release.sh --skip-build 0.1.1
```

Keep certificates and app-specific passwords out of git (see `CONTRIBUTING.md`). Optional local overrides: `config/Local.xcconfig`.

## Verify a downloaded build

```bash
codesign --verify --deep --strict --verbose=4 /Applications/EyesOnYou.app
spctl --assess --type execute --verbose=4 /Applications/EyesOnYou.app
# Notarized only:
xcrun stapler validate /Applications/EyesOnYou.app
```

## Outputs

| Path | Description |
|---|---|
| `dist/EyesOnYou-<ver>.dmg` | Disk image for Releases |
| `dist/EyesOnYou.app` | Same app bundle (local inspect) |
| `dist/version.txt` | Resolved marketing version |
| `build/DerivedData/` | xcodebuild derived data (gitignored) |
