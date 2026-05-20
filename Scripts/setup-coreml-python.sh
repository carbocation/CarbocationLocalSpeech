#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON:-python3.10}"
VENV_PATH="$ROOT/.venv-coreml"

usage() {
  cat <<'EOF'
Usage:
  Scripts/setup-coreml-python.sh [--python python3.10] [--venv .venv-coreml]

Creates an isolated Python environment for whisper.cpp CoreML encoder generation.
The environment is intentionally separate from Homebrew/global Python packages.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python)
      PYTHON_BIN="${2:-}"
      shift 2
      ;;
    --venv)
      VENV_PATH="${2:-}"
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

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "Python command not found: $PYTHON_BIN" >&2
  exit 1
fi

case "$VENV_PATH" in
  /*) ;;
  *) VENV_PATH="$ROOT/$VENV_PATH" ;;
esac

echo "Creating CoreML Python environment with $(command -v "$PYTHON_BIN")"
"$PYTHON_BIN" -m venv "$VENV_PATH"

VENV_PYTHON="$VENV_PATH/bin/python"
if [[ ! -x "$VENV_PYTHON" ]]; then
  echo "venv did not create an executable Python at $VENV_PYTHON" >&2
  exit 1
fi

"$VENV_PYTHON" -m pip install --upgrade pip setuptools wheel

# Avoid the unrelated PyPI package named "whisper"; whisper.cpp needs
# OpenAI Whisper, which is distributed as "openai-whisper" and imports as
# "whisper".
"$VENV_PYTHON" -m pip uninstall -y whisper >/dev/null 2>&1 || true
"$VENV_PYTHON" -m pip install --upgrade --force-reinstall \
  "numpy<2" \
  "torch>=2.1" \
  coremltools \
  ane_transformers \
  openai-whisper

"$VENV_PYTHON" <<'PY'
import coremltools
import torch
import whisper
import ane_transformers

assert hasattr(whisper, "available_models")
assert hasattr(whisper, "load_model")

print("CoreML Python environment ready")
print(f"  python: {__import__('sys').executable}")
print(f"  coremltools: {coremltools.__version__}")
print(f"  torch: {torch.__version__}")
print(f"  whisper: {whisper.__file__}")
print(f"  ane_transformers: {ane_transformers.__file__}")
PY
