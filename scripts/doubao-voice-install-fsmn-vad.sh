#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="/usr/local/share/doubao-ime-cli/fsmn-runtime"
RUNTIME_PYTHON="$RUNTIME_DIR/venv/bin/python3"
WORKER="/usr/local/share/doubao-ime-cli/scripts/fsmn_vad_worker.py"

if [ -x "$RUNTIME_PYTHON" ]; then
  PYTHON_BIN="$RUNTIME_PYTHON"
  PYTHON_RUN=("$PYTHON_BIN")
  if [ "$(/usr/bin/uname -m 2>/dev/null || true)" = "arm64" ] && [ -x /usr/bin/arch ]; then
    PYTHON_RUN=(/usr/bin/arch -arm64 "$PYTHON_BIN")
  fi
  export MODELSCOPE_CACHE="$RUNTIME_DIR/modelscope-cache"
  echo "Using bundled FSMN-VAD runtime: $PYTHON_BIN"
  if [ -f "$WORKER" ]; then
    echo "Verifying bundled FSMN-VAD model..."
    "${PYTHON_RUN[@]}" "$WORKER" </dev/null
    exit 0
  fi
  echo "FSMN-VAD worker not found at $WORKER"
  exit 1
fi

if [ -n "${DOUBAO_VOICE_PYTHON:-}" ]; then
  PYTHON_BIN="$DOUBAO_VOICE_PYTHON"
elif [ -x /opt/homebrew/bin/python3 ]; then
  PYTHON_BIN="/opt/homebrew/bin/python3"
elif [ -x /usr/local/bin/python3 ]; then
  PYTHON_BIN="/usr/local/bin/python3"
else
  PYTHON_BIN="/usr/bin/python3"
fi

echo "Bundled FSMN-VAD runtime was not found; repairing with user Python: $PYTHON_BIN"
PYTHON_RUN=("$PYTHON_BIN")
if ! "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
  echo "pip is not available for $PYTHON_BIN; trying ensurepip..."
  "$PYTHON_BIN" -m ensurepip --user
fi
"${PYTHON_RUN[@]}" -m pip install --user -U torch torchaudio funasr modelscope

if [ -f "$WORKER" ]; then
  echo "Preloading FSMN-VAD model. The first run may download model files..."
  "${PYTHON_RUN[@]}" "$WORKER" </dev/null
else
  echo "FSMN-VAD worker not found at $WORKER"
  echo "Install the Doubao Voice CLI pkg first, then run this command again."
  exit 1
fi
