#!/bin/bash
# GlassTerm build + packaging pipeline.
# Usage: ./build.sh [--verify] [--clean]
#   --verify   build, then launch the packaged binary with GT_SMOKE=1 and assert SMOKE_OK.
#   --clean    remove build/ and GlassTerm.app only, then exit.
#   ARCHS=arm64|x86_64|universal ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="GlassTerm"
BUNDLE_ID="com.glassterm.app"
VERSION="1.0.0"
MIN_MACOS="13.0"
SWIFT_FLAGS=(-O -swift-version 5)

BUILD_DIR="build"
APP_DIR="${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
ICNS="Resources/AppIcon.icns"
VERIFY_TIMEOUT_SECS=15

usage() {
  cat <<EOF
${APP_NAME} build script

  ./build.sh              build ${APP_DIR} for the host CPU
  ./build.sh --verify     build, then run the GT_SMOKE=1 smoke test
  ./build.sh --clean      remove ${BUILD_DIR}/ and ${APP_DIR}
  ARCHS=arm64|x86_64|universal ./build.sh
EOF
}

DO_CLEAN=0
DO_VERIFY=0
for arg in "$@"; do
  case "$arg" in
    --clean)  DO_CLEAN=1 ;;
    --verify) DO_VERIFY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "❌ Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

ARCHS="${ARCHS:-$(uname -m)}"
case "$ARCHS" in
  arm64|x86_64|universal) ;;
  *) echo "❌ ARCHS must be arm64, x86_64 or universal (got '${ARCHS}')" >&2; exit 2 ;;
esac

clean_all() {
  rm -rf "$BUILD_DIR"
  rm -rf "$APP_DIR"
}

# The .iconset lives inside build/ so a repo checkout never sees it; the trap below
# also removes it on any exit path (success, failure, Ctrl-C).
cleanup_iconset() { rm -rf "${BUILD_DIR}/AppIcon.iconset"; }
trap cleanup_iconset EXIT

if [ "$DO_CLEAN" -eq 1 ]; then
  echo "▸ Cleaning…"
  clean_all
  echo "✅ Removed ${BUILD_DIR}/ and ${APP_DIR}"
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "❌ swiftc not found — install the Xcode command line tools (xcode-select --install)" >&2
  exit 1
fi

# ---------------------------------------------------------------- sources guard
shopt -s nullglob
SRC_FILES=(Sources/*.swift)
shopt -u nullglob

if [ "${#SRC_FILES[@]}" -eq 0 ]; then
  echo "❌ No Swift sources found: Sources/*.swift is empty. Nothing to build." >&2
  echo "   (Sources/ must contain main.swift, AppDelegate.swift, … before ./build.sh can compile)" >&2
  exit 1
fi

# ---------------------------------------------------------------- icon (best effort)
ensure_icon() {
  if [ -f "$ICNS" ]; then
    echo "▸ Icon present ($ICNS)"
    return 0
  fi
  if [ ! -f "tools/make-icon.swift" ]; then
    echo "⚠️  skipping icon (tools/make-icon.swift missing)"
    return 0
  fi
  for tool in swift sips iconutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "⚠️  skipping icon ($tool not found)"
      return 0
    fi
  done

  echo "▸ Drawing icon…"
  local png="${BUILD_DIR}/icon-1024.png"
  local iconset="${BUILD_DIR}/AppIcon.iconset"
  local spec size name
  rm -rf "$iconset"
  mkdir -p "$iconset"

  if ! swift tools/make-icon.swift "$png"; then
    echo "⚠️  skipping icon (drawing failed)"
    rm -rf "$iconset"
    return 0
  fi

  # size:iconset-basename — @2x entries are downscaled from the 1024 px master.
  local specs=(
    "16:icon_16x16"      "32:icon_16x16@2x"
    "32:icon_32x32"      "64:icon_32x32@2x"
    "128:icon_128x128"   "256:icon_128x128@2x"
    "256:icon_256x256"   "512:icon_256x256@2x"
    "512:icon_512x512"   "1024:icon_512x512@2x"
  )
  for spec in "${specs[@]}"; do
    size="${spec%%:*}"
    name="${spec##*:}"
    if ! sips -z "$size" "$size" "$png" --out "${iconset}/${name}.png" >/dev/null 2>&1; then
      echo "⚠️  skipping icon (sips failed at ${size}px)"
      rm -rf "$iconset"
      return 0
    fi
  done

  if iconutil -c icns "$iconset" -o "$ICNS" 2>/dev/null && [ -f "$ICNS" ]; then
    echo "  ✓ ${ICNS}"
  else
    echo "⚠️  skipping icon (iconutil failed)"
  fi
  rm -rf "$iconset"
  return 0
}

# ---------------------------------------------------------------- compile
compile_arch() {
  local arch="$1"
  local out="$2"
  swiftc "${SWIFT_FLAGS[@]}" \
    -target "${arch}-apple-macos${MIN_MACOS}" \
    -framework Cocoa \
    -o "$out" \
    "${SRC_FILES[@]}"
}

# ---------------------------------------------------------------- verify
verify_bundle() {
  local bin="${CONTENTS}/MacOS/${APP_NAME}"
  local log="${BUILD_DIR}/verify.log"
  local pid rc ticks elapsed status

  if [ ! -x "$bin" ]; then
    echo "❌ --verify: ${bin} is missing or not executable" >&2
    exit 1
  fi

  mkdir -p "$BUILD_DIR"
  set +e
  GT_SMOKE=1 "$bin" >"$log" 2>&1 &
  pid=$!

  ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((VERIFY_TIMEOUT_SECS * 10)) ]; then
      kill -TERM "$pid" 2>/dev/null
      sleep 0.3
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo "❌ --verify: timed out after ${VERIFY_TIMEOUT_SECS}s without exiting" >&2
      echo "--- smoke output ---" >&2
      cat "$log" >&2 2>/dev/null
      echo "--------------------" >&2
      exit 1
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
  rc=$?
  elapsed=$(awk "BEGIN { printf \"%.1f\", ${ticks} / 10 }" 2>/dev/null || echo "?")
  set -e

  status=0
  if ! grep -q "SMOKE_OK" "$log" 2>/dev/null; then
    echo "❌ --verify: output did not contain SMOKE_OK (exit ${rc}, ${elapsed}s)" >&2
    status=1
  elif [ "$rc" -ne 0 ]; then
    echo "❌ --verify: SMOKE_OK printed but the process exited ${rc}" >&2
    status=1
  fi
  if [ "$status" -ne 0 ]; then
    echo "--- smoke output ---" >&2
    cat "$log" >&2 2>/dev/null
    echo "--------------------" >&2
    exit 1
  fi

  echo "▸ Smoke test:"
  sed 's/^/    /' "$log"
  echo "VERIFY_OK"
}

# ---------------------------------------------------------------- pipeline
echo "▸ Cleaning…"
clean_all
mkdir -p "$BUILD_DIR"

ensure_icon

echo "▸ Compiling… (${#SRC_FILES[@]} sources, ${ARCHS}, macOS ${MIN_MACOS}+)"
if [ "$ARCHS" = "universal" ]; then
  compile_arch arm64  "${BUILD_DIR}/${APP_NAME}-arm64"
  compile_arch x86_64 "${BUILD_DIR}/${APP_NAME}-x86_64"
  lipo -create -output "${BUILD_DIR}/${APP_NAME}" \
    "${BUILD_DIR}/${APP_NAME}-arm64" "${BUILD_DIR}/${APP_NAME}-x86_64"
else
  compile_arch "$ARCHS" "${BUILD_DIR}/${APP_NAME}"
fi
chmod +x "${BUILD_DIR}/${APP_NAME}"

echo "▸ Bundling…"
rm -rf "$APP_DIR"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${CONTENTS}/MacOS/${APP_NAME}"
chmod +x "${CONTENTS}/MacOS/${APP_NAME}"
cp Resources/Info.plist "${CONTENTS}/Info.plist"

if [ -f "$ICNS" ]; then
  cp "$ICNS" "${CONTENTS}/Resources/AppIcon.icns"
fi

if ! plutil -lint "${CONTENTS}/Info.plist"; then
  echo "❌ Info.plist failed plutil -lint — refusing to ship a broken bundle" >&2
  exit 1
fi

plist_id="$(plutil -extract CFBundleIdentifier raw "${CONTENTS}/Info.plist" 2>/dev/null || true)"
plist_ver="$(plutil -extract CFBundleShortVersionString raw "${CONTENTS}/Info.plist" 2>/dev/null || true)"
if [ "$plist_id" != "$BUNDLE_ID" ]; then
  echo "❌ Info.plist CFBundleIdentifier is '${plist_id}', expected '${BUNDLE_ID}'" >&2
  exit 1
fi
if [ "$plist_ver" != "$VERSION" ]; then
  echo "❌ Info.plist CFBundleShortVersionString is '${plist_ver}', expected '${VERSION}'" >&2
  exit 1
fi

echo "▸ Signing… (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP_DIR" || \
  echo "⚠️  ad-hoc codesign failed (app still runnable)"

if [ "$DO_VERIFY" -eq 1 ]; then
  echo "▸ Verifying…"
  verify_bundle
fi

ABS_APP="$(pwd)/${APP_DIR}"
echo "✅ Built ${ABS_APP}"
echo "   Launch: open ${APP_DIR}"
