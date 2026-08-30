#!/bin/bash
# Test-only harness runner. Boots Xvfb + a dbus session with an unlocked
# gnome-keyring (the app's secure storage needs it), then runs an
# integration_test target on the Linux embedder.
#
# Usage: tool/run_shots.sh <integration_test/file.dart> [output-dir]
set -u

# Derived from the script's own location, so the harness runs from any checkout
# rather than one machine's layout.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-integration_test/screenshot_test.dart}"
OUT="${2:-$REPO/.shots-fresh}"
LOG="${SHOT_LOG:-${TMPDIR:-/tmp}/pos_shots.log}"

# Only when the toolchain is not already on PATH, which it is not under a
# detached run; FLUTTER_HOME overrides for a checkout that installed elsewhere.
command -v flutter >/dev/null 2>&1 || export PATH="${FLUTTER_HOME:-/opt/flutter}/bin:$PATH"
export SHOT_DIR="$OUT"
mkdir -p "$OUT"

pkill -f "Xvfb :99" >/dev/null 2>&1
sleep 1
Xvfb :99 -screen 0 1600x2400x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
XVFB_PID=$!
sleep 2

cd "$REPO" || exit 1

dbus-run-session -- bash -c '
  eval "$(printf "\n" | gnome-keyring-daemon --unlock --components=secrets,pkcs11)"
  export DISPLAY=:99
  cd '"$REPO"'
  # Bounded: a screen that never settles would otherwise wedge the run forever.
  timeout 900 flutter test "'"$TARGET"'" -d linux --no-pub 2>&1
' | tee "$LOG"
RC=${PIPESTATUS[0]}

kill "$XVFB_PID" >/dev/null 2>&1
echo "=== run_shots exit $RC ; log $LOG ; out $OUT ==="
exit "$RC"
