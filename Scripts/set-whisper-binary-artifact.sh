#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <artifact-url> <swiftpm-checksum>" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL_VALUE="$1"
CHECKSUM_VALUE="$2"
PACKAGE="$ROOT/Package.swift"

perl -0pi -e "s#let whisperBinaryArtifactURL = \"[^\"]*\"#let whisperBinaryArtifactURL = \"$URL_VALUE\"#" "$PACKAGE"
perl -0pi -e "s#let whisperBinaryArtifactChecksum = \"[^\"]*\"#let whisperBinaryArtifactChecksum = \"$CHECKSUM_VALUE\"#" "$PACKAGE"

echo "Stamped Package.swift with whisper binary artifact metadata."
