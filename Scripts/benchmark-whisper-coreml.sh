#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBRARY_ROOT=""
VARIANT="small.en"
ITERATIONS="5"
WARMUPS="1"
THREADS="4"
PYTHON_CMD="${PYTHON:-}"
CURRENT_ARTIFACT="0"
CURRENT_ARTIFACT_COREML="0"

usage() {
  cat <<'EOF'
Usage:
  Scripts/benchmark-whisper-coreml.sh --library-root <SpeechModels> [--variant small.en] [--iterations 5] [--warmups 1] [--threads 4] [--python python3.10]
  Scripts/benchmark-whisper-coreml.sh --current-artifact --library-root <SpeechModels> [--coreml] [--variant small.en] [--iterations 5] [--warmups 1] [--threads 4]

Builds a baseline macOS whisper.cpp source artifact, benchmarks it, prepares the
CoreML encoder sidecar, rebuilds whisper.cpp with WHISPER_COREML=ON, benchmarks
again, and prints a timing comparison.

Use --current-artifact to skip rebuilding and benchmark the artifact currently
installed at Vendor/whisper-artifacts/current. Add --coreml in that mode to mark
the report as an explicitly requested CoreML run.

Set PYTHON=python3.10 or pass --python python3.10 when your Python binary is not
available as python3.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --library-root)
      LIBRARY_ROOT="${2:-}"
      shift 2
      ;;
    --variant)
      VARIANT="${2:-}"
      shift 2
      ;;
    --iterations)
      ITERATIONS="${2:-}"
      shift 2
      ;;
    --warmups)
      WARMUPS="${2:-}"
      shift 2
      ;;
    --threads)
      THREADS="${2:-}"
      shift 2
      ;;
    --python)
      PYTHON_CMD="${2:-}"
      shift 2
      ;;
    --current-artifact)
      CURRENT_ARTIFACT="1"
      shift
      ;;
    --coreml)
      CURRENT_ARTIFACT_COREML="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$LIBRARY_ROOT" ]]; then
  echo "missing --library-root" >&2
  usage >&2
  exit 1
fi

if [[ ! -d "$LIBRARY_ROOT" ]]; then
  echo "library root does not exist: $LIBRARY_ROOT" >&2
  exit 1
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$ROOT/.build/benchmarks/$TIMESTAMP-$VARIANT"
mkdir -p "$RUN_DIR"

BASELINE_JSON="$RUN_DIR/baseline.json"
COREML_JSON="$RUN_DIR/coreml.json"
SOURCE_OUT_DIR="$ROOT/Vendor/whisper-artifacts/current"

run_benchmark() {
  local scratch="$1"
  local output="$2"
  local use_coreml="${3:-0}"
  local benchmark_args=(
    --library-root "$LIBRARY_ROOT"
    --variant "$VARIANT"
    --iterations "$ITERATIONS"
    --warmups "$WARMUPS"
    --threads "$THREADS"
    --output "$output"
  )
  if [[ "$use_coreml" == "1" ]]; then
    benchmark_args+=(--coreml)
  fi

  env \
    CARBOCATION_LOCAL_SPEECH_FORCE_SOURCE_WHISPER=1 \
    CLANG_MODULE_CACHE_PATH="$scratch/module-cache" \
    SWIFTPM_CACHE_PATH="$scratch/swiftpm-cache" \
    swift run --scratch-path "$scratch" clss-benchmark "${benchmark_args[@]}"
}

if [[ "$CURRENT_ARTIFACT" == "1" ]]; then
  CURRENT_JSON="$RUN_DIR/current.json"
  echo "==> Running benchmark against current whisper.cpp artifact"
  run_benchmark "$RUN_DIR/swiftpm-current" "$CURRENT_JSON" "$CURRENT_ARTIFACT_COREML"
  echo "Report:"
  echo "  current: $CURRENT_JSON"
  exit 0
fi

echo "==> Building baseline whisper.cpp artifact (CoreML OFF)"
BUILD_DIR="$RUN_DIR/whisper-baseline-build" \
OUT_DIR="$SOURCE_OUT_DIR" \
WHISPER_COREML=OFF \
  "$ROOT/Scripts/build-whisper-macos.sh"

echo "==> Running baseline benchmark"
run_benchmark "$RUN_DIR/swiftpm-baseline" "$BASELINE_JSON" "0"

echo "==> Preparing CoreML encoder sidecar"
PREPARE_ARGS=(
  --library-root "$LIBRARY_ROOT"
  --variant "$VARIANT"
)
if [[ -n "$PYTHON_CMD" ]]; then
  PREPARE_ARGS+=(--python "$PYTHON_CMD")
fi
"$ROOT/Scripts/prepare-coreml-encoder.sh" "${PREPARE_ARGS[@]}"

echo "==> Building CoreML whisper.cpp artifact (CoreML ON)"
BUILD_DIR="$RUN_DIR/whisper-coreml-build" \
OUT_DIR="$SOURCE_OUT_DIR" \
WHISPER_COREML=ON \
WHISPER_COREML_ALLOW_FALLBACK=ON \
  "$ROOT/Scripts/build-whisper-macos.sh"

echo "==> Running CoreML benchmark"
run_benchmark "$RUN_DIR/swiftpm-coreml" "$COREML_JSON" "1"

echo "==> Comparison"
env \
  CARBOCATION_LOCAL_SPEECH_FORCE_SOURCE_WHISPER=1 \
  CLANG_MODULE_CACHE_PATH="$RUN_DIR/swiftpm-coreml/module-cache" \
  SWIFTPM_CACHE_PATH="$RUN_DIR/swiftpm-coreml/swiftpm-cache" \
  swift run --scratch-path "$RUN_DIR/swiftpm-coreml" clss-benchmark compare \
    --baseline "$BASELINE_JSON" \
    --candidate "$COREML_JSON"

echo "Reports:"
echo "  baseline: $BASELINE_JSON"
echo "  coreml:   $COREML_JSON"
