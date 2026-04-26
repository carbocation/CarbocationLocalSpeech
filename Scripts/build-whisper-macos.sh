#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="${WHISPER_DIR:-"$ROOT/Vendor/whisper.cpp"}"
BUILD_DIR="${BUILD_DIR:-"$ROOT/.build/whisper-macos"}"
OUT_DIR="${OUT_DIR:-"$ROOT/Vendor/whisper-artifacts/current"}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

if [[ ! -f "$WHISPER_DIR/CMakeLists.txt" ]]; then
  echo "whisper.cpp is not checked out at $WHISPER_DIR" >&2
  echo "Initialize Vendor/whisper.cpp before building the source artifact." >&2
  exit 1
fi

cmake -S "$WHISPER_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON \
  -DWHISPER_COREML=ON \
  -DWHISPER_COREML_ALLOW_FALLBACK=ON \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF

cmake --build "$BUILD_DIR" --config Release --parallel

mkdir -p "$OUT_DIR/include" "$OUT_DIR/lib"
cp "$WHISPER_DIR/include/whisper.h" "$OUT_DIR/include/whisper.h"

LIBS=()
while IFS= read -r lib; do
  LIBS+=("$lib")
done < <(find "$BUILD_DIR" -name '*.a' -print)
if [[ "${#LIBS[@]}" -eq 0 ]]; then
  echo "No static libraries were produced by the whisper.cpp build." >&2
  exit 1
fi

libtool -static -o "$OUT_DIR/lib/libwhisper-combined.a" "${LIBS[@]}"
echo "Built $OUT_DIR/lib/libwhisper-combined.a"
