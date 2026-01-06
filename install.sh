#!/usr/bin/env bash
# td installer - picks the sqlite implementation (fastest)
set -euo pipefail

REPO="alosec/td"
BRANCH="impl/sqlite"
INSTALL_DIR="${TD_INSTALL_DIR:-$HOME/.local/bin}"

echo "Installing td (sqlite implementation)..."

# Create install dir if needed
mkdir -p "$INSTALL_DIR"

# Download
curl -fsSL "https://raw.githubusercontent.com/$REPO/$BRANCH/td" -o "$INSTALL_DIR/td"
chmod +x "$INSTALL_DIR/td"

# Check if in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  echo ""
  echo "Add to your PATH:"
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
  echo ""
fi

echo "✓ Installed to $INSTALL_DIR/td"
echo ""
echo "Quick start:"
echo "  td init"
echo "  td create \"My first task\" -p 1"
echo "  td ready"
