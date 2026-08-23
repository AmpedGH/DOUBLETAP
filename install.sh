#!/bin/bash
#
# install.sh - installs doubletap.sh as a system-wide 'doubletap' command
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/usr/local/bin/doubletap"

if [[ $EUID -ne 0 ]]; then
    echo "[!] Run this installer with sudo." >&2
    exit 1
fi

chmod +x "$SCRIPT_DIR/doubletap.sh"
ln -sf "$SCRIPT_DIR/doubletap.sh" "$TARGET"

echo "[*] Installed. Symlinked $SCRIPT_DIR/doubletap.sh -> $TARGET"
echo "[*] Run with: sudo doubletap"
