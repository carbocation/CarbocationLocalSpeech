#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="${WHISPER_DIR:-"$ROOT/Vendor/whisper.cpp"}"
TAG=""
FETCH=1
INCLUDE_PRERELEASE=0
VALIDATE=0
DRY_RUN=0
FORCE=0

usage() {
  cat >&2 <<'USAGE'
Usage: Scripts/bump-whisper-upstream.sh [<tag>|--latest] [options]

Checks out a whisper.cpp upstream tag in Vendor/whisper.cpp and syncs the
checked-in public headers used by the SwiftPM source-build target.

Options:
  --latest              Use the latest stable upstream tag (default).
  --include-prerelease  Allow prerelease tags when resolving --latest.
  --no-fetch            Use locally available tags without fetching from origin.
  --validate            Build the XCFramework and run binary-artifact validation.
  --dry-run             Print the selected tag and planned actions without changes.
  --force               Allow overwriting local changes in synced whisper headers.
  -h, --help            Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --latest)
      TAG=""
      shift
      ;;
    --include-prerelease)
      INCLUDE_PRERELEASE=1
      shift
      ;;
    --no-fetch)
      FETCH=0
      shift
      ;;
    --validate)
      VALIDATE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      if [[ -n "$TAG" ]]; then
        usage
        exit 2
      fi
      TAG="$1"
      shift
      ;;
  esac
done

if [[ ! -d "$WHISPER_DIR/.git" && ! -f "$WHISPER_DIR/.git" ]]; then
  echo "error: whisper.cpp submodule is not checked out at $WHISPER_DIR" >&2
  echo "Run: git submodule update --init --recursive" >&2
  exit 1
fi

if [[ -n "$(git -C "$WHISPER_DIR" status --porcelain)" ]]; then
  echo "error: whisper.cpp submodule has local changes; commit/stash them first." >&2
  exit 1
fi

if [[ "$FORCE" -eq 0 ]] && [[ -n "$(git -C "$ROOT" status --porcelain -- Sources/whisper/include)" ]]; then
  echo "error: Sources/whisper/include has local changes; use --force to overwrite." >&2
  exit 1
fi

if [[ "$FETCH" -eq 1 ]]; then
  git -C "$WHISPER_DIR" fetch --tags --force origin
fi

if [[ -z "$TAG" ]]; then
  if [[ "$INCLUDE_PRERELEASE" -eq 1 ]]; then
    TAG="$(git -C "$WHISPER_DIR" tag --list 'v[0-9]*' --sort=-v:refname | head -n 1)"
  else
    TAG="$(
      git -C "$WHISPER_DIR" tag --list 'v[0-9]*' --sort=-v:refname \
        | grep -E '^v[0-9]+(\.[0-9]+)*$' \
        | head -n 1
    )"
  fi
fi

if [[ -z "$TAG" ]]; then
  echo "error: no matching whisper.cpp tag found." >&2
  exit 1
fi

if ! git -C "$WHISPER_DIR" rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null; then
  echo "error: whisper.cpp tag not found: $TAG" >&2
  exit 1
fi

CURRENT="$(git -C "$WHISPER_DIR" describe --tags --dirty --always)"
echo "whisper.cpp current: $CURRENT"
echo "whisper.cpp target:  $TAG"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "dry run: would checkout Vendor/whisper.cpp at $TAG"
  echo "dry run: would sync Sources/whisper/include"
  echo "dry run: would verify header sync and C header parse"
  if [[ "$VALIDATE" -eq 1 ]]; then
    echo "dry run: would rebuild the staged whisper library"
    echo "dry run: would build whisper.xcframework and run binary-artifact validation"
  fi
  exit 0
fi

git -C "$WHISPER_DIR" checkout --detach "$TAG"
"$ROOT/Scripts/sync-whisper-headers.sh"
"$ROOT/Scripts/sync-whisper-headers.sh" --check
clang -fsyntax-only -x c -I "$ROOT/Sources/whisper/include" -include whisper.h /dev/null

if [[ "$VALIDATE" -eq 1 ]]; then
  "$ROOT/Scripts/build-whisper-macos.sh"
  "$ROOT/Scripts/build-whisper-xcframework.sh"
  (
    cd "$ROOT"
    CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH="Vendor/whisper-artifacts/release/whisper.xcframework" swift test
  )
  "$ROOT/Scripts/test-local-binary-artifact.sh"
fi

echo "Updated whisper.cpp to $TAG."
echo "Review and commit Vendor/whisper.cpp plus synced headers."
