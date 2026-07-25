#!/usr/bin/env bash
# Capture English overview screenshots (light + dark) into docs/screenshots/.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/screenshots"
BUNDLE_ID="com.example.EyesOnYou"
APP_NAME="EyesOnYou"
APP="$ROOT/build/DerivedData/Build/Products/Release/${APP_NAME}.app"

if [[ ! -d "$APP" ]]; then
  APP="$ROOT/dist/${APP_NAME}.app"
fi
if [[ ! -d "$APP" ]]; then
  echo "error: ${APP_NAME}.app not found; run ./scripts/build-dmg.sh first" >&2
  exit 1
fi

echo "Using app: $APP"
mkdir -p "$OUT"

kill_app() {
  pkill -9 -x "$APP_NAME" 2>/dev/null || true
  # Also kill Xcode-launched binaries that keep odd windows around.
  pgrep -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" | while read -r pid; do
    kill -9 "$pid" 2>/dev/null || true
  done
  sleep 0.8
}

set_prefs() {
  local appearance="$1"
  defaults write "$BUNDLE_ID" eyesonyou.languagePreference -string english
  defaults write "$BUNDLE_ID" eyesonyou.appearanceMode -string "$appearance"
}

# Largest real dashboard window (skip menu-bar / title-strip leftovers).
front_window_id() {
  python3 - <<'PY'
import Quartz
wins = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID) or []
best = None
best_area = 0
for w in wins:
    if (w.get("kCGWindowOwnerName") or "") != "EyesOnYou":
        continue
    bounds = w.get("kCGWindowBounds") or {}
    width = float(bounds.get("Width") or 0)
    height = float(bounds.get("Height") or 0)
    if width < 900 or height < 600:
        continue
    if int(w.get("kCGWindowLayer") or 0) != 0:
        continue
    area = width * height
    if area > best_area:
        best_area = area
        best = w
if best is None:
    raise SystemExit(1)
print(int(best["kCGWindowNumber"]))
PY
}

capture_mode() {
  local appearance="$1"
  local outfile="$2"

  echo "==> capture $appearance → $outfile"
  kill_app
  set_prefs "$appearance"

  "$APP/Contents/MacOS/${APP_NAME}" >/tmp/eyesonyou-capture.log 2>&1 &
  local app_pid=$!

  local wid=""
  for _ in $(seq 1 80); do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      echo "error: ${APP_NAME} exited early; see /tmp/eyesonyou-capture.log" >&2
      cat /tmp/eyesonyou-capture.log >&2 || true
      return 1
    fi
    if wid="$(front_window_id 2>/dev/null)"; then
      break
    fi
    sleep 0.25
  done

  if [[ -z "${wid:-}" ]]; then
    echo "error: could not find ${APP_NAME} dashboard window" >&2
    kill_app
    return 1
  fi

  # Demo data + layout settle; English strings load at launch.
  sleep 2.5

  wid="$(front_window_id)"
  rm -f "$outfile"
  if ! screencapture -x -o -l"$wid" "$outfile"; then
    echo "error: screencapture failed for window $wid (grant Screen Recording to the terminal/Cursor)" >&2
    kill_app
    return 1
  fi
  if [[ ! -s "$outfile" ]]; then
    echo "error: empty screenshot" >&2
    kill_app
    return 1
  fi

  echo "    wrote $outfile (window $wid, $(wc -c < "$outfile") bytes)"
  kill_app
  return 0
}

capture_mode light "$OUT/overview-light.png" || exit 1
capture_mode dark "$OUT/overview-dark.png" || exit 1

file "$OUT/overview-light.png" "$OUT/overview-dark.png"
ls -lh "$OUT/overview-light.png" "$OUT/overview-dark.png"
echo "==> done (English UI)"
