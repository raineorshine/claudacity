#!/usr/bin/env bash
# install.sh — download and install the latest claudacity binary from GitHub releases
set -euo pipefail

REPO="raineorshine/claudacity"
BIN_DIR="$HOME/.local/bin"
BINARY="claudacity"
ALIAS="cly"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  arm64 | aarch64) ARCH="aarch64" ;;
  x86_64) ARCH="x86_64" ;;
  *)
    echo "❌  Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# Get latest release tag
echo "➜   Fetching latest release..."
LATEST=$(curl -s -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/releases/latest" |
  grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')

if [ -z "$LATEST" ]; then
  echo "❌  Could not determine latest release."
  echo "    Check: https://github.com/${REPO}/releases"
  exit 1
fi

URL="https://github.com/${REPO}/releases/download/v${LATEST}/${BINARY}-${ARCH}-apple-darwin"

mkdir -p "$BIN_DIR"

echo "➜   Downloading claudacity v${LATEST} for ${ARCH}..."
curl -L --fail -o "${BIN_DIR}/${BINARY}" "$URL"
chmod +x "${BIN_DIR}/${BINARY}"

# Short alias
ln -sf "${BINARY}" "${BIN_DIR}/${ALIAS}"

# Ensure BIN_DIR is in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo ""
  echo "⚠️   $BIN_DIR is not in your PATH."
  echo "    Add this to your ~/.zshrc or ~/.zprofile:"
  echo ""
  echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
fi

echo "✅  claudacity v${LATEST} installed to ${BIN_DIR}/${BINARY}"
echo "    Alias: ${BIN_DIR}/${ALIAS}"
echo ""
echo "Usage:"
echo "  claudacity save work"
echo "  claudacity save personal"
echo "  cly pick"
