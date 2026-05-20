#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBRARY_ROOT=""
VARIANT="small.en"
PYTHON_CMD="${PYTHON:-}"

usage() {
  cat <<'EOF'
Usage:
  Scripts/prepare-coreml-encoder.sh --library-root <SpeechModels> [--variant small.en] [--python python3.10]

Generates or verifies the whisper.cpp CoreML encoder sidecar for a locally installed
model, then installs it beside the matching ggml-*.bin file.

Set PYTHON=python3.10 or pass --python python3.10 when your Python binary is not
available as python3.
EOF
}

resolve_python() {
  if [[ -n "$PYTHON_CMD" ]]; then
    if ! command -v "$PYTHON_CMD" >/dev/null 2>&1; then
      echo "Python command not found: $PYTHON_CMD" >&2
      exit 1
    fi
    return
  fi

  for candidate in python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      PYTHON_CMD="$candidate"
      return
    fi
  done

  echo "could not find Python; pass --python <command> or set PYTHON=<command>" >&2
  exit 1
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
    --python)
      PYTHON_CMD="${2:-}"
      shift 2
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

MODEL_FILENAME="ggml-${VARIANT}.bin"
ENCODER_NAME="ggml-${VARIANT}-encoder.mlmodelc"
MODEL_PATH="$(find "$LIBRARY_ROOT" -mindepth 2 -maxdepth 2 -type f -name "$MODEL_FILENAME" -print -quit)"

if [[ -z "$MODEL_PATH" ]]; then
  echo "could not find $MODEL_FILENAME under $LIBRARY_ROOT" >&2
  exit 1
fi

MODEL_DIR="$(dirname "$MODEL_PATH")"
DESTINATION="$MODEL_DIR/$ENCODER_NAME"

if [[ -d "$DESTINATION" ]]; then
  echo "CoreML encoder sidecar already exists: $DESTINATION"
  exit 0
fi

WHISPER_DIR="$ROOT/Vendor/whisper.cpp"
GENERATED="$WHISPER_DIR/models/$ENCODER_NAME"

if [[ ! -d "$GENERATED" ]]; then
  echo "Generating CoreML encoder sidecar for $VARIANT via whisper.cpp."
  echo "This requires Python dependencies used by Vendor/whisper.cpp/models/generate-coreml-model.sh."
  resolve_python
  PYTHON_PATH="$(command -v "$PYTHON_CMD")"
  echo "Using Python: $PYTHON_PATH"
  if ! "$PYTHON_CMD" <<'PY'
import importlib
import sys


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def require_import(module_name):
    try:
        return importlib.import_module(module_name)
    except Exception as error:
        fail(f"Could not import {module_name}: {type(error).__name__}: {error}")


def version_tuple(version):
    base = version.split("+", 1)[0]
    parts = []
    for piece in base.split("."):
        if not piece.isdigit():
            break
        parts.append(int(piece))
    return tuple(parts)


coremltools = require_import("coremltools")
torch = require_import("torch")
whisper = require_import("whisper")
require_import("ane_transformers")

torch_version = getattr(torch, "__version__", "0")
if version_tuple(torch_version) < (2, 1):
    fail(
        "Installed torch is too old for CoreML conversion. "
        f"Found torch {torch_version}; install torch>=2.1 in the selected Python environment. "
        "For global python3.10: python3.10 -m pip install --upgrade 'torch>=2.1'"
    )

if not all(hasattr(whisper, attr) for attr in ("available_models", "load_model")):
    fail(
        "The importable 'whisper' module does not look like OpenAI Whisper. "
        f"Found {getattr(whisper, '__file__', '(unknown path)')}. "
        "Install the PyPI package 'openai-whisper' instead of the unrelated package named 'whisper'. "
        "For global python3.10: python3.10 -m pip uninstall -y whisper && "
        "python3.10 -m pip install --upgrade openai-whisper"
    )

print(
    "Python CoreML dependencies OK: "
    f"coremltools {getattr(coremltools, '__version__', 'unknown')}, "
    f"torch {torch_version}"
)
PY
  then
    exit 1
  fi
  PYTHON_SHIM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clss-coreml-python.XXXXXX")"
  cleanup_python_shim() {
    rm -rf "$PYTHON_SHIM_DIR"
  }
  trap cleanup_python_shim EXIT
  ln -sf "$PYTHON_PATH" "$PYTHON_SHIM_DIR/python3"
  (
    export PATH="$PYTHON_SHIM_DIR:$PATH"
    cd "$WHISPER_DIR"
    ./models/generate-coreml-model.sh "$VARIANT"
  )
fi

if [[ ! -d "$GENERATED" ]]; then
  echo "CoreML generation did not produce $GENERATED" >&2
  exit 1
fi

rm -rf "$DESTINATION"
ditto "$GENERATED" "$DESTINATION"
echo "Installed CoreML encoder sidecar: $DESTINATION"
