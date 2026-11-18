#!/usr/bin/env bash
set -euo pipefail
VERSION="${1:?usage: export-android-release.sh <versionName>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -f /home/box/.godot-dev-env.sh ]]; then
  # shellcheck disable=SC1091
  source /home/box/.godot-dev-env.sh
fi
# shellcheck disable=SC1091
source "$(dirname "$0")/credentials.env"
mkdir -p "$ROOT/build/android"
OUT="$ROOT/build/android/蒂法玉腹沙盒-${VERSION}-android-arm64.apk"
GODOT="${GODOT:-/home/box/bin/godot}"
LIBGL_ALWAYS_SOFTWARE=1 "$GODOT" --headless --path "$ROOT" --export-release Android "$OUT"
echo "exported $OUT"
