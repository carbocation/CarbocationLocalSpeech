#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="${WHISPER_DIR:-"$ROOT/Vendor/whisper.cpp"}"
ARTIFACTS_DIR="$ROOT/Vendor/whisper-artifacts"
MACOS_STAGE_DIR="${WHISPER_MACOS_STAGE_DIR:-"$ARTIFACTS_DIR/current"}"
IOS_DEVICE_STAGE_DIR="${WHISPER_IOS_DEVICE_STAGE_DIR:-"$ARTIFACTS_DIR/current-ios-device"}"
IOS_SIMULATOR_STAGE_DIR="${WHISPER_IOS_SIMULATOR_STAGE_DIR:-"$ARTIFACTS_DIR/current-ios-simulator"}"
BUILD_ROOT="${WHISPER_BUILD_ROOT:-"$ROOT/.build"}"
OUTPUT_DIR="${WHISPER_XCFRAMEWORK_OUTPUT_DIR:-"$ARTIFACTS_DIR/release"}"
XCFRAMEWORK_NAME="${WHISPER_XCFRAMEWORK_NAME:-whisper.xcframework}"
ZIP_NAME="${WHISPER_XCFRAMEWORK_ZIP_NAME:-whisper.xcframework.zip}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-17.0}"
WHISPER_COREML="${WHISPER_COREML:-OFF}"
WHISPER_COREML_ALLOW_FALLBACK="${WHISPER_COREML_ALLOW_FALLBACK:-ON}"
WHISPER_FORCE_REBUILD="${WHISPER_FORCE_REBUILD:-0}"

if [[ -n "${OUT:-}" ]]; then
  XCFRAMEWORK_PATH="$OUT"
  OUTPUT_DIR="$(dirname "$OUT")"
else
  XCFRAMEWORK_PATH="$OUTPUT_DIR/$XCFRAMEWORK_NAME"
fi

ZIP_PATH="${WHISPER_XCFRAMEWORK_ZIP_PATH:-"$OUTPUT_DIR/$ZIP_NAME"}"
CHECKSUM_PATH="$ZIP_PATH.checksum"

if [[ ! -f "$WHISPER_DIR/CMakeLists.txt" ]]; then
  echo "whisper.cpp is not checked out at $WHISPER_DIR" >&2
  echo "Initialize Vendor/whisper.cpp before building the binary artifact." >&2
  exit 1
fi

write_headers() {
  local headers="$1"
  "$ROOT/Scripts/sync-whisper-headers.sh" --dest "$headers"
  cat > "$headers/module.modulemap" <<'EOF'
module whisper [system] {
  header "whisper.h"
  header "ggml.h"
  header "ggml-alloc.h"
  header "ggml-backend.h"
  header "ggml-cpu.h"
  link "c++"
  export *
}
EOF
}

combine_static_libraries() {
  local build_dir="$1"
  local library="$2"
  local -a libs=()

  while IFS= read -r lib; do
    libs+=("$lib")
  done < <(find "$build_dir" -name '*.a' -print)

  if [[ "${#libs[@]}" -eq 0 ]]; then
    echo "No static libraries were produced by the whisper.cpp build at $build_dir." >&2
    exit 1
  fi

  mkdir -p "$(dirname "$library")"
  libtool -static -o "$library" "${libs[@]}"
}

build_macos_slice() {
  local library="$MACOS_STAGE_DIR/lib/libwhisper-combined.a"
  local headers="$MACOS_STAGE_DIR/include"

  if [[ "$WHISPER_FORCE_REBUILD" == "1" || ! -f "$library" ]]; then
    OUT_DIR="$MACOS_STAGE_DIR" \
    MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    WHISPER_COREML="$WHISPER_COREML" \
    WHISPER_COREML_ALLOW_FALLBACK="$WHISPER_COREML_ALLOW_FALLBACK" \
      "$ROOT/Scripts/build-whisper-macos.sh"
  fi

  write_headers "$headers"
  if [[ ! -f "$library" ]]; then
    echo "error: missing macOS whisper static library: $library" >&2
    exit 1
  fi
}

build_ios_slice() {
  local label="$1"
  local sdk="$2"
  local supported_platform="$3"
  local architectures="$4"
  local stage_dir="$5"
  local build_dir="$BUILD_ROOT/whisper-$label"
  local library="$stage_dir/lib/libwhisper-combined.a"
  local headers="$stage_dir/include"

  if [[ "$WHISPER_FORCE_REBUILD" == "1" || ! -f "$library" ]]; then
    rm -rf "$build_dir"
    cmake -S "$WHISPER_DIR" -B "$build_dir" -G Xcode \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_OSX_SYSROOT="$sdk" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
      -DCMAKE_OSX_ARCHITECTURES="$architectures" \
      -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS="$supported_platform" \
      -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
      -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
      -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
      -DIOS=ON \
      -DBUILD_SHARED_LIBS=OFF \
      -DGGML_NATIVE=OFF \
      -DGGML_METAL=ON \
      -DGGML_METAL_EMBED_LIBRARY=ON \
      -DWHISPER_COREML="$WHISPER_COREML" \
      -DWHISPER_COREML_ALLOW_FALLBACK="$WHISPER_COREML_ALLOW_FALLBACK" \
      -DWHISPER_BUILD_TESTS=OFF \
      -DWHISPER_BUILD_EXAMPLES=OFF
    cmake --build "$build_dir" --config Release -- -quiet
    combine_static_libraries "$build_dir" "$library"
  fi

  write_headers "$headers"
  if [[ ! -f "$library" ]]; then
    echo "error: missing $label whisper static library: $library" >&2
    exit 1
  fi
}

build_macos_slice
build_ios_slice "ios-device" "iphoneos" "iphoneos" "arm64" "$IOS_DEVICE_STAGE_DIR"
build_ios_slice "ios-simulator" "iphonesimulator" "iphonesimulator" "arm64;x86_64" "$IOS_SIMULATOR_STAGE_DIR"

mkdir -p "$OUTPUT_DIR"
rm -rf "$XCFRAMEWORK_PATH" "$ZIP_PATH" "$CHECKSUM_PATH"

xcodebuild -create-xcframework \
  -library "$MACOS_STAGE_DIR/lib/libwhisper-combined.a" \
  -headers "$MACOS_STAGE_DIR/include" \
  -library "$IOS_DEVICE_STAGE_DIR/lib/libwhisper-combined.a" \
  -headers "$IOS_DEVICE_STAGE_DIR/include" \
  -library "$IOS_SIMULATOR_STAGE_DIR/lib/libwhisper-combined.a" \
  -headers "$IOS_SIMULATOR_STAGE_DIR/include" \
  -output "$XCFRAMEWORK_PATH"

ditto -c -k --sequesterRsrc --keepParent "$XCFRAMEWORK_PATH" "$ZIP_PATH"
swift package compute-checksum "$ZIP_PATH" > "$CHECKSUM_PATH"

echo "xcframework: $XCFRAMEWORK_PATH"
echo "zip: $ZIP_PATH"
echo "checksum: $(cat "$CHECKSUM_PATH")"
