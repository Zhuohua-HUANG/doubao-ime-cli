#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"

make -C "$ROOT_DIR" PREFIX="$PREFIX" uninstall

APP="/Applications/DoubaoVoiceCLI.app"
if [ -d "$APP" ]; then
  echo "To remove the menu bar helper app installed by the pkg, run:"
  echo "  sudo rm -rf \"$APP\""
fi
