#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="${WHISPER_DIR:-"$ROOT/Vendor/whisper.cpp"}"
DEST_DIR="$ROOT/Sources/whisper/include"
MODE="sync"

usage() {
  cat >&2 <<'USAGE'
Usage: Scripts/sync-whisper-headers.sh [--check] [--dest <dir>]

Copies the public whisper.cpp headers needed by Sources/whisper/module.modulemap.
Use --check to fail if the destination is out of sync.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --dest)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi
      DEST_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ ! -f "$WHISPER_DIR/include/whisper.h" ]]; then
  echo "whisper.cpp is not checked out at $WHISPER_DIR" >&2
  exit 1
fi

HEADERS=(
  "include/whisper.h"
  "ggml/include/ggml.h"
  "ggml/include/ggml-alloc.h"
  "ggml/include/ggml-backend.h"
  "ggml/include/ggml-cpu.h"
)

if [[ "$MODE" == "sync" ]]; then
  mkdir -p "$DEST_DIR"
fi

for header in "${HEADERS[@]}"; do
  source="$WHISPER_DIR/$header"
  destination="$DEST_DIR/$(basename "$header")"

  if [[ ! -f "$source" ]]; then
    echo "Missing upstream header: $source" >&2
    exit 1
  fi

  if [[ "$MODE" == "check" ]]; then
    if [[ ! -f "$destination" ]]; then
      echo "Missing synced header: $destination" >&2
      exit 1
    fi
    if ! cmp -s "$source" "$destination"; then
      echo "Out-of-sync header: $destination" >&2
      echo "Run Scripts/sync-whisper-headers.sh" >&2
      exit 1
    fi
  else
    cp "$source" "$destination"
  fi
done

if [[ "$MODE" == "sync" ]]; then
  echo "Synced whisper.cpp headers to $DEST_DIR"
fi
