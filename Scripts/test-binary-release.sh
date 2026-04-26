#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_URL="${PACKAGE_URL:-"$ROOT"}"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$TMP_DIR"
swift package init --type executable --name CLSBinaryConsumer

if [[ -d "$PACKAGE_URL" && ! -d "$PACKAGE_URL/.git" ]]; then
  DEPENDENCY='.package(path: "'"$PACKAGE_URL"'")'
else
  DEPENDENCY='.package(url: "'"$PACKAGE_URL"'", branch: "main")'
fi

cat > Package.swift <<EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CLSBinaryConsumer",
    platforms: [.macOS(.v14)],
    dependencies: [
        $DEPENDENCY
    ],
    targets: [
        .executableTarget(
            name: "CLSBinaryConsumer",
            dependencies: [
                .product(name: "CarbocationLocalSpeechRuntime", package: "CarbocationLocalSpeech")
            ]
        )
    ]
)
EOF

swift build
