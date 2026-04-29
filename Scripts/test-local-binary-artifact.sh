#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_INPUT="${CARBOCATION_LOCAL_SPEECH_LOCAL_BINARY_ARTIFACT_PATH:-"Vendor/whisper-artifacts/release/whisper.xcframework"}"
WORK_DIR="${CARBOCATION_LOCAL_SPEECH_LOCAL_BINARY_SMOKE_DIR:-}"
KEEP_WORK_DIR="${CARBOCATION_LOCAL_SPEECH_KEEP_LOCAL_BINARY_SMOKE_DIR:-0}"

case "$ARTIFACT_INPUT" in
  /*)
    ARTIFACT_PATH="$ARTIFACT_INPUT"
    if [[ "$ARTIFACT_INPUT" == "$ROOT/"* ]]; then
      ARTIFACT_MANIFEST_PATH="${ARTIFACT_INPUT#"$ROOT/"}"
    else
      echo "error: SwiftPM binary target paths must be relative to the package root." >&2
      echo "Artifact is outside this package: $ARTIFACT_INPUT" >&2
      exit 1
    fi
    ;;
  *)
    ARTIFACT_PATH="$ROOT/$ARTIFACT_INPUT"
    ARTIFACT_MANIFEST_PATH="$ARTIFACT_INPUT"
    ;;
esac

if [[ ! -d "$ARTIFACT_PATH" ]]; then
  echo "error: local whisper binary artifact not found: $ARTIFACT_PATH" >&2
  echo "Run Scripts/build-whisper-xcframework.sh first." >&2
  exit 1
fi

if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cls-local-binary-smoke.XXXXXX")"
  if [[ "$KEEP_WORK_DIR" != "1" ]]; then
    trap 'rm -rf "$WORK_DIR"' EXIT
  fi
else
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
fi

mkdir -p "$WORK_DIR/Sources/LocalBinaryConsumerIOS"

cat > "$WORK_DIR/Package.swift" <<EOF
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CarbocationLocalSpeechLocalBinarySmoke",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "LocalBinaryConsumerIOS", targets: ["LocalBinaryConsumerIOS"])
    ],
    dependencies: [
        .package(path: "$ROOT")
    ],
    targets: [
        .target(
            name: "LocalBinaryConsumerIOS",
            dependencies: [
                .product(name: "CarbocationLocalSpeech", package: "CarbocationLocalSpeech"),
                .product(name: "CarbocationLocalSpeechRuntime", package: "CarbocationLocalSpeech"),
                .product(name: "CarbocationLocalSpeechUI", package: "CarbocationLocalSpeech"),
                .product(name: "CarbocationWhisperRuntime", package: "CarbocationLocalSpeech")
            ]
        )
    ]
)
EOF

cat > "$WORK_DIR/Sources/LocalBinaryConsumerIOS/LocalBinaryConsumerIOS.swift" <<'EOF'
import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime
import CarbocationLocalSpeechUI
import CarbocationWhisperRuntime
import Foundation
import SwiftUI

public enum LocalBinaryConsumerIOS {
    public static func validate() async throws -> Int {
        let curatedCount = CuratedSpeechModelCatalog.all.count
        let _ = try LocalSpeechEngine.selection(from: SpeechSystemModelID.appleSpeech.rawValue)
        let status = WhisperRuntimeSmoke.linkStatus()
        guard status.isUsable else {
            throw LocalBinaryConsumerIOSError.whisperRuntimeUnavailable(status.displayDescription)
        }
        return curatedCount
    }

    @MainActor
    public static func makeSettingsView(
        library: SpeechModelLibrary,
        selectionStorageValue: Binding<String>
    ) -> some View {
        SpeechSettingsView(
            library: library,
            selectionStorageValue: selectionStorageValue
        )
    }
}

public enum LocalBinaryConsumerIOSError: Error {
    case whisperRuntimeUnavailable(String)
}
EOF

echo "Testing local binary artifact from $ARTIFACT_PATH with clean consumer at $WORK_DIR"
IOS_SIMULATOR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH="$ARTIFACT_MANIFEST_PATH" \
  env CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache" SWIFTPM_CACHE_PATH="$WORK_DIR/swiftpm-cache" \
  swift build \
    --package-path "$WORK_DIR" \
    --triple arm64-apple-ios17.0-simulator \
    --sdk "$IOS_SIMULATOR_SDK" \
    --target LocalBinaryConsumerIOS
