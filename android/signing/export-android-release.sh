#!/usr/bin/env bash
# 导出并签名正式 Android arm64 APK。密钥只来自 credentials.env / Godot 环境变量，
# 不得写入 export_presets.cfg。导出后必须通过 apksigner 校验，否则失败。
set -euo pipefail
VERSION="${1:?usage: export-android-release.sh <versionName>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -f /home/box/.godot-dev-env.sh ]]; then
  # shellcheck disable=SC1091
  source /home/box/.godot-dev-env.sh
fi
# shellcheck disable=SC1091
source "$(dirname "$0")/credentials.env"

# 证书公开指纹（0.2.22 起的正式证书，与 README 一致）。
EXPECTED_CERT_SHA256="1c0810c2c165f37f429e05910abf797880de2516a9d5afcc297e1b72c70cba3d"

if [[ -z "${JAVA_HOME:-}" ]]; then
  for jdk in /home/box/jdk-21 /opt/jdk-21; do
    if [[ -x "$jdk/bin/java" ]]; then
      export JAVA_HOME="$jdk"
      export PATH="$JAVA_HOME/bin:$PATH"
      break
    fi
  done
fi
if [[ -n "${JAVA_HOME:-}" && ":$PATH:" != *":$JAVA_HOME/bin:"* ]]; then
  export PATH="$JAVA_HOME/bin:$PATH"
fi

if [[ -z "${GODOT:-}" ]]; then
  for g in /opt/godot/Godot_v4.7.2-stable_linux.x86_64 /home/box/godot/Godot_v4.7.2-stable_linux.x86_64 /home/box/bin/godot; do
    if [[ -x "$g" ]]; then
      GODOT="$g"
      break
    fi
  done
fi
if [[ -z "${GODOT:-}" ]]; then
  echo "error: Godot binary not found (set GODOT)" >&2
  exit 1
fi

find_apksigner() {
  local sdk c
  sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  if [[ -n "$sdk" ]]; then
    c="$(ls -1d "$sdk"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -n "$c" && -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  fi
  for sdk in /home/box/android-sdk /opt/android-sdk; do
    c="$(ls -1d "$sdk"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -n "$c" && -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

# 校验：整体通过、v2 有效、v1 在 API 18–23 有效、证书与正式发行一致、META-INF 有签名文件。
# 默认 apksigner 在 minSdk≥24 时会显示 “v1: false”（该 API 走 v2），不能当作没有 v1。
verify_apk() {
  local apk="$1"
  local as="$2"
  local log v1log
  if [[ ! -f "$apk" ]]; then
    echo "error: APK not found: $apk" >&2
    return 1
  fi
  log="$(mktemp)"
  v1log="$(mktemp)"
  cleanup() { rm -f "$log" "$v1log"; }
  trap cleanup RETURN

  if ! "$as" verify --verbose --print-certs "$apk" >"$log" 2>&1; then
    echo "error: apksigner verify failed for $apk" >&2
    cat "$log" >&2
    return 1
  fi
  if ! grep -q '^Verifies$' "$log"; then
    echo "error: apksigner did not report Verifies for $apk" >&2
    cat "$log" >&2
    return 1
  fi
  if ! grep -q 'Verified using v2 scheme (APK Signature Scheme v2): true' "$log"; then
    echo "error: APK is missing a valid v2 signature (required to install on Android 11+)" >&2
    cat "$log" >&2
    return 1
  fi

  if ! "$as" verify --min-sdk-version 18 --max-sdk-version 23 --verbose "$apk" >"$v1log" 2>&1; then
    echo "error: v1 JAR signature does not verify (API 18–23)" >&2
    cat "$v1log" >&2
    return 1
  fi
  if ! grep -q 'Verified using v1 scheme (JAR signing): true' "$v1log"; then
    echo "error: v1 JAR signature is not valid (API 18–23)" >&2
    cat "$v1log" >&2
    return 1
  fi

  if ! unzip -Z1 "$apk" | grep -qE '^META-INF/[^/]+\.(RSA|DSA|EC)$'; then
    echo "error: APK has no META-INF signature file (.RSA/.DSA/.EC)" >&2
    return 1
  fi

  local cert
  cert="$(awk '/certificate SHA-256 digest:/{print tolower($NF); exit}' "$log")"
  if [[ "$cert" != "$EXPECTED_CERT_SHA256" ]]; then
    echo "error: signing cert SHA-256 ${cert:-<none>} does not match the 0.2.22+ release certificate" >&2
    return 1
  fi

  local v3="false"
  if grep -q 'Verified using v3 scheme (APK Signature Scheme v3): true' "$log"; then
    v3="true"
  fi
  echo "verified $apk  v1=ok v2=ok v3=$v3 cert=$cert"
}

APKSIGNER="$(find_apksigner)" || {
  echo "error: apksigner not found (set ANDROID_SDK_ROOT or ANDROID_HOME)" >&2
  exit 1
}

mkdir -p "$ROOT/build/android"
OUT="$ROOT/build/android/蒂法玉腹沙盒-${VERSION}-android-arm64.apk"
LIBGL_ALWAYS_SOFTWARE=1 "$GODOT" --headless --path "$ROOT" --export-release Android "$OUT"
echo "exported $OUT"
verify_apk "$OUT" "$APKSIGNER"
