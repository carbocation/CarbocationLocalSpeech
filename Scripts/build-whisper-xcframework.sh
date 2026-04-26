#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-"$ROOT/Vendor/whisper-artifacts/current"}"
LIBRARY="$ARTIFACT_DIR/lib/libwhisper-combined.a"
HEADERS="$ARTIFACT_DIR/include"
OUT="${OUT:-"$ROOT/Vendor/whisper-artifacts/whisper.xcframework"}"

if [[ ! -f "$LIBRARY" ]]; then
  "$ROOT/Scripts/build-whisper-macos.sh"
fi

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$LIBRARY" \
  -headers "$HEADERS" \
  -output "$OUT"

echo "Built $OUT"
