#!/bin/bash
# A local CPython for cross-building Apple Python extensions and matching bytecode.
# No Homebrew or changes to the system Python are needed on an Intel build Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=3.14.10
RELEASE=20261026
case "$(uname -m)" in
  x86_64) ARCH=x86_64; SHA256=01cedae5d4a66ac570e13cb35fa570d0e79ba8e9affd4518a5d85b6c2b98ff10 ;;
  arm64) ARCH=aarch64; SHA256=30a18bcb9ab75e485b4bf4e5d783dde165571e7e42c56dff47a2d2c5345183a4 ;;
  *) echo 'Unsupported build Mac architecture' >&2; exit 1 ;;
esac
DEST="$PWD/build/tools/cpython-$VERSION-$RELEASE-$ARCH"
if [ ! -x "$DEST/python/bin/python3.14" ]; then
  mkdir -p "$PWD/build/tools"
  TMP=$(mktemp -d "$PWD/build/tools/.python.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL --retry 3 "https://github.com/astral-sh/python-build-standalone/releases/download/$RELEASE/cpython-$VERSION%2B$RELEASE-$ARCH-apple-darwin-install_only.tar.gz" -o "$TMP/python.tar.gz"
  echo "$SHA256  $TMP/python.tar.gz" | shasum -a 256 -c - >&2
  mkdir "$TMP/release"
  tar -xzf "$TMP/python.tar.gz" -C "$TMP/release"
  mv "$TMP/release" "$DEST"
fi
"$DEST/python/bin/python3.14" -c 'import sys; assert sys.version_info[:2] == (3, 14)'
echo "$DEST/python/bin/python3.14"
