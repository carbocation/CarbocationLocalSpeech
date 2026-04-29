#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${CARBOCATION_LOCAL_SPEECH_REPO_URL:-https://github.com/carbocation/CarbocationLocalSpeech.git}"
TAG="${1:-${CARBOCATION_LOCAL_SPEECH_RELEASE_TAG:-}}"
WORK_DIR="${CARBOCATION_LOCAL_SPEECH_RELEASE_SMOKE_DIR:-}"
KEEP_WORK_DIR="${CARBOCATION_LOCAL_SPEECH_KEEP_RELEASE_SMOKE_DIR:-0}"

if [[ -z "$TAG" ]]; then
  echo "usage: $0 <release-tag>" >&2
  echo "example: $0 v0.2.0" >&2
  exit 2
fi

VERSION="${TAG#v}"

if [[ ! "$VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+([.-][0-9A-Za-z.-]+)?([+][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: release tag must be a SwiftPM semantic version tag, optionally prefixed with v: $TAG" >&2
  exit 1
fi

if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cls-release-smoke.XXXXXX")"
  if [[ "$KEEP_WORK_DIR" != "1" ]]; then
    trap 'rm -rf "$WORK_DIR"' EXIT
  fi
else
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
fi

mkdir -p "$WORK_DIR/Sources/ReleaseSmoke" "$WORK_DIR/Sources/ReleaseSmokeIOS"

cat > "$WORK_DIR/Package.swift" <<EOF
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CarbocationLocalSpeechReleaseSmoke",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "ReleaseSmoke", targets: ["ReleaseSmoke"]),
        .library(name: "ReleaseSmokeIOS", targets: ["ReleaseSmokeIOS"])
    ],
    dependencies: [
        .package(url: "$REPO_URL", exact: "$VERSION")
    ],
    targets: [
        .executableTarget(
            name: "ReleaseSmoke",
            dependencies: [
                .product(name: "CarbocationLocalSpeech", package: "CarbocationLocalSpeech"),
                .product(name: "CarbocationLocalSpeechRuntime", package: "CarbocationLocalSpeech"),
                .product(name: "CarbocationLocalSpeechUI", package: "CarbocationLocalSpeech"),
                .product(name: "CarbocationWhisperRuntime", package: "CarbocationLocalSpeech")
            ]
        ),
        .target(
            name: "ReleaseSmokeIOS",
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

cat > "$WORK_DIR/Sources/ReleaseSmoke/main.swift" <<'EOF'
import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime
import CarbocationLocalSpeechUI
import CarbocationWhisperRuntime
import Foundation

let curatedCount = CuratedSpeechModelCatalog.all.count
let vadModel = CuratedSpeechModelCatalog.recommendedVADModel
let appleSelection = try LocalSpeechEngine.selection(from: SpeechSystemModelID.appleSpeech.rawValue)
let status = WhisperRuntimeSmoke.linkStatus()

guard curatedCount > 0 else {
    fputs("release smoke failed: curated catalog is empty\n", stderr)
    exit(1)
}

guard case .system(.appleSpeech) = appleSelection else {
    fputs("release smoke failed: apple speech selection did not round-trip\n", stderr)
    exit(1)
}

guard status.isUsable else {
    fputs("release smoke failed: whisper runtime is not linked\n", stderr)
    exit(1)
}

print("release smoke: ok")
print("curatedModels=\(curatedCount)")
print("vadModel=\(vadModel.id)")
print("whisperStatus=\(status.displayDescription)")
EOF

cat > "$WORK_DIR/Sources/ReleaseSmokeIOS/ReleaseSmokeIOS.swift" <<'EOF'
import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime
import CarbocationLocalSpeechUI
import CarbocationWhisperRuntime
import Foundation
import SwiftUI

public enum ReleaseSmokeIOS {
    public static func validate() async throws -> Int {
        let curatedCount = CuratedSpeechModelCatalog.all.count
        let _ = try LocalSpeechEngine.selection(from: SpeechSystemModelID.appleSpeech.rawValue)
        let status = WhisperRuntimeSmoke.linkStatus()
        guard status.isUsable else {
            throw ReleaseSmokeIOSError.whisperRuntimeUnavailable(status.displayDescription)
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

public enum ReleaseSmokeIOSError: Error {
    case whisperRuntimeUnavailable(String)
}
EOF

echo "Testing $REPO_URL at $TAG from $WORK_DIR"
swift run --package-path "$WORK_DIR" ReleaseSmoke
IOS_SIMULATOR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
env CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache" SWIFTPM_CACHE_PATH="$WORK_DIR/swiftpm-cache" \
  swift build \
    --package-path "$WORK_DIR" \
    --triple arm64-apple-ios17.0-simulator \
    --sdk "$IOS_SIMULATOR_SDK" \
    --target ReleaseSmokeIOS
