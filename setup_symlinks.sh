#!/usr/bin/env bash
#
# setup_symlinks.sh
#
# Creates a symlink from this repo to the Box-synced tijuanabox folder.
# Run once after cloning (or whenever the symlink needs to be recreated).
#
# Usage:
#   bash setup_symlinks.sh
#   bash setup_symlinks.sh /path/to/box/tijuanabox   # override auto-detection
#

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Detect or accept the Box tijuanabox root --------------------------------

if [[ -n "${1:-}" ]]; then
    BOX_TIJUANA="$1"
else
    # Try common Box mount names on macOS
    BOX_BASE="$HOME/Library/CloudStorage"
    if [[ -d "$BOX_BASE/Box-Box/tijuanabox" ]]; then
        BOX_TIJUANA="$BOX_BASE/Box-Box/tijuanabox"
    elif [[ -d "$BOX_BASE/Box/tijuanabox" ]]; then
        BOX_TIJUANA="$BOX_BASE/Box/tijuanabox"
    elif [[ -d "$HOME/Box/tijuanabox" ]]; then
        BOX_TIJUANA="$HOME/Box/tijuanabox"
    else
        echo "ERROR: Could not find tijuanabox in Box."
        echo "Searched:"
        echo "  $BOX_BASE/Box-Box/tijuanabox"
        echo "  $BOX_BASE/Box/tijuanabox"
        echo "  $HOME/Box/tijuanabox"
        echo ""
        echo "Re-run with an explicit path:"
        echo "  bash setup_symlinks.sh /path/to/box/tijuanabox"
        exit 1
    fi
fi

echo "Using Box tijuanabox at: $BOX_TIJUANA"

# --- Create symlink -----------------------------------------------------------

LINK_PATH="$REPO_DIR/tijuanabox"

# Remove existing symlink or warn if something else is in the way
if [[ -L "$LINK_PATH" ]]; then
    rm "$LINK_PATH"
elif [[ -e "$LINK_PATH" ]]; then
    echo "WARNING: $LINK_PATH exists and is not a symlink — skipping."
    exit 1
fi

if [[ -d "$BOX_TIJUANA" ]]; then
    ln -s "$BOX_TIJUANA" "$LINK_PATH"
    echo "  OK  $LINK_PATH -> $BOX_TIJUANA"
else
    echo "  MISSING  $BOX_TIJUANA  (symlink not created)"
    exit 1
fi

echo ""
echo "Done. Symlink created."
