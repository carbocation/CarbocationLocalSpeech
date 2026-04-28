#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 <artifact-url> <swiftpm-checksum>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL_VALUE="$1"
CHECKSUM_VALUE="$2"
PACKAGE="$ROOT/Package.swift"

if [[ ! "$URL_VALUE" =~ ^https:// ]]; then
  echo "error: artifact URL must use https://: $URL_VALUE" >&2
  exit 1
fi

if [[ ! "$CHECKSUM_VALUE" =~ ^[a-f0-9]{64}$ ]]; then
  echo "error: checksum must be the 64-character hex output from 'swift package compute-checksum'." >&2
  exit 1
fi

WHISPER_BINARY_ARTIFACT_URL="$URL_VALUE" \
WHISPER_BINARY_ARTIFACT_CHECKSUM="$CHECKSUM_VALUE" \
perl -0pi -e '
  s/let whisperBinaryArtifactURL = "[^"]*"/let whisperBinaryArtifactURL = "$ENV{WHISPER_BINARY_ARTIFACT_URL}"/
    or die "failed to replace whisperBinaryArtifactURL\n";
  s/let whisperBinaryArtifactChecksum = "[^"]*"/let whisperBinaryArtifactChecksum = "$ENV{WHISPER_BINARY_ARTIFACT_CHECKSUM}"/
    or die "failed to replace whisperBinaryArtifactChecksum\n";
' "$PACKAGE"

echo "Stamped Package.swift with whisper binary artifact metadata."
