#!/usr/bin/env bash
set -euo pipefail

# Install into ~/.local/bin by default, because it is user-writable and commonly
# included in PATH. Override with:
#
#   PREFIX=/usr/local ./install.sh
#
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"

make -C "$ROOT_DIR" PREFIX="$PREFIX" install

echo
echo "Next step: grant Accessibility permission when macOS prompts."
echo "Source install only installs the CLI. The pkg installer also installs"
echo "the /Applications/DoubaoVoiceCLI.app menu bar helper and Logitech entry."
echo "  $PREFIX/bin/doubao-voice check --prompt"
echo
"$PREFIX/bin/doubao-voice" check --prompt || true
