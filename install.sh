#!/bin/sh
set -e

REPO="qu0b/bees"
INSTALL_DIR="${BEES_INSTALL_DIR:-$HOME/.bees/bin}"
BINARY="bees"

# Detect platform
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$OS" in
    linux) ;;
    *) echo "Error: unsupported OS: $OS (only linux is supported)" >&2; exit 1 ;;
esac

case "$ARCH" in
    x86_64|amd64) ARCH="x86_64" ;;
    *) echo "Error: unsupported architecture: $ARCH (only x86_64 is supported)" >&2; exit 1 ;;
esac

ASSET="bees-linux-${ARCH}.tar.gz"

# Get latest release URL
if [ -n "$BEES_VERSION" ]; then
    TAG="$BEES_VERSION"
else
    TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
fi

if [ -z "$TAG" ]; then
    echo "Error: could not determine latest release" >&2
    exit 1
fi

URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

echo "Installing bees ${TAG}..."

# Download and extract
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading ${URL}..."
curl -fsSL "$URL" -o "${TMPDIR}/${ASSET}"
tar -xzf "${TMPDIR}/${ASSET}" -C "$TMPDIR"

# Install
mkdir -p "$INSTALL_DIR"
mv "${TMPDIR}/${BINARY}" "${INSTALL_DIR}/${BINARY}"
chmod 755 "${INSTALL_DIR}/${BINARY}"

echo "Installed bees to ${INSTALL_DIR}/${BINARY}"

# Check PATH
case ":$PATH:" in
    *":${INSTALL_DIR}:"*) ;;
    *)
        echo ""
        echo "Add bees to your PATH:"
        echo "  echo 'export PATH=\"${INSTALL_DIR}:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
        ;;
esac
