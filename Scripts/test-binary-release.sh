#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${CARBOCATION_LOCAL_SPEECH_REPO_URL:-https://github.com/carbocation/CarbocationLocalSpeech.git}"
TAG="${1:-${CARBOCATION_LOCAL_SPEECH_RELEASE_TAG:-}}"
WORK_DIR="${CARBOCATION_LOCAL_SPEECH_RELEASE_SMOKE_DIR:-}"
KEEP_WORK_DIR="${CARBOCATION_LOCAL_SPEECH_KEEP_RELEASE_SMOKE_DIR:-0}"

if [[ -z "$TAG" ]]; then
  echo "usage: $0 <release-tag>" >&2
  echo "example: $0 v0.1.0" >&2
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

mkdir -p "$WORK_DIR/Sources/ReleaseSmoke"

cat > "$WORK_DIR/Package.swift" <<EOF
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CarbocationLocalSpeechReleaseSmoke",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ReleaseSmoke", targets: ["ReleaseSmoke"])
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

echo "Testing $REPO_URL at $TAG from $WORK_DIR"
swift run --package-path "$WORK_DIR" ReleaseSmoke
