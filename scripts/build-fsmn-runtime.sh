#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${1:-$ROOT_DIR/build/fsmn-runtime}"
PYTHON_BIN="${DOUBAO_VOICE_BUILD_PYTHON:-python3}"
WORKER="$ROOT_DIR/scripts/fsmn_vad_worker.py"

mkdir -p "$RUNTIME_DIR"

if [ ! -x "$RUNTIME_DIR/venv/bin/python3" ]; then
  echo "Creating bundled FSMN-VAD runtime: $RUNTIME_DIR"
  "$PYTHON_BIN" -m venv "$RUNTIME_DIR/venv"
fi

VENV_PYTHON="$RUNTIME_DIR/venv/bin/python3"
MODELSCOPE_CACHE="$RUNTIME_DIR/modelscope-cache"
export MODELSCOPE_CACHE
export DOUBAO_VOICE_FSMN_MODEL="${DOUBAO_VOICE_FSMN_MODEL:-fsmn-vad}"
export DOUBAO_VOICE_FSMN_REVISION="${DOUBAO_VOICE_FSMN_REVISION:-v2.0.4}"

echo "Installing FSMN-VAD Python packages into bundled runtime..."
"$VENV_PYTHON" -m pip install -U pip setuptools wheel
"$VENV_PYTHON" -m pip install -U torch torchaudio funasr modelscope

echo "Preloading FSMN-VAD model into bundled runtime cache..."
"$VENV_PYTHON" "$WORKER" </dev/null

echo "Bundled FSMN-VAD runtime is ready:"
echo "  $RUNTIME_DIR"
