#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="$ROOT/Vendor/whisper-artifacts"
STAGE_DIR="${ARTIFACT_DIR:-"$ARTIFACTS_DIR/current"}"
OUTPUT_DIR="${WHISPER_XCFRAMEWORK_OUTPUT_DIR:-"$ARTIFACTS_DIR/release"}"
XCFRAMEWORK_NAME="${WHISPER_XCFRAMEWORK_NAME:-whisper.xcframework}"
ZIP_NAME="${WHISPER_XCFRAMEWORK_ZIP_NAME:-whisper.xcframework.zip}"
LIBRARY="$STAGE_DIR/lib/libwhisper-combined.a"
HEADERS="$STAGE_DIR/include"

if [[ -n "${OUT:-}" ]]; then
  XCFRAMEWORK_PATH="$OUT"
  OUTPUT_DIR="$(dirname "$OUT")"
else
  XCFRAMEWORK_PATH="$OUTPUT_DIR/$XCFRAMEWORK_NAME"
fi

ZIP_PATH="${WHISPER_XCFRAMEWORK_ZIP_PATH:-"$OUTPUT_DIR/$ZIP_NAME"}"
CHECKSUM_PATH="$ZIP_PATH.checksum"

if [[ ! -f "$LIBRARY" ]]; then
  "$ROOT/Scripts/build-whisper-macos.sh"
fi

"$ROOT/Scripts/sync-whisper-headers.sh" --dest "$HEADERS"
cat > "$HEADERS/module.modulemap" <<'EOF'
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

if [[ ! -f "$LIBRARY" ]]; then
  echo "error: missing whisper static library: $LIBRARY" >&2
  exit 1
fi

if [[ ! -f "$HEADERS/whisper.h" ]]; then
  echo "error: missing whisper headers: $HEADERS" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$XCFRAMEWORK_PATH" "$ZIP_PATH" "$CHECKSUM_PATH"

xcodebuild -create-xcframework \
  -library "$LIBRARY" \
  -headers "$HEADERS" \
  -output "$XCFRAMEWORK_PATH"

ditto -c -k --sequesterRsrc --keepParent "$XCFRAMEWORK_PATH" "$ZIP_PATH"
swift package compute-checksum "$ZIP_PATH" > "$CHECKSUM_PATH"

echo "xcframework: $XCFRAMEWORK_PATH"
echo "zip: $ZIP_PATH"
echo "checksum: $(cat "$CHECKSUM_PATH")"
