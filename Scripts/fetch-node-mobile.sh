#!/bin/bash
# Puts nodejs-mobile (Node.js built for iOS and tvOS; V8 runs without a JIT there) in build/NodeMobile, which
# Scripts/embed-node-mobile.sh adds to the iPhone, iPad and Apple TV apps. CatPawOpen (猫源) bundles run in it
# (EmbeddedNodeHost). The iOS and tvOS builds run this themselves, so nobody has to build Node.
#
# iOS uses a full-ICU Node 24 framework whose binary targets iOS 14, including for the iOS 16.2 app.
# tvOS uses jo32's Node 26 build with Apple TV slices. Both are checked against SHA-256 and kept once per Mac in
# ~/Library/Caches/tvbox-nodejs-mobile, so other checkouts and worktrees only link to it.
# To try a framework you built yourself (docs/BUILDING.md in that repository), point NODE_MOBILE_DIR at a folder
# holding NodeMobile.xcframework and LICENSE.node.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-${PLATFORM_NAME:-iphoneos}}" in
  ios|ios-simulator|iphoneos|iphonesimulator)
    VERSION=24.5.0
    RELEASE=v24.5.0-capawesome.1
    BASE="https://github.com/capawesome-team/nodejs-mobile/releases/download/$RELEASE"
    ARCHIVE_NAME="nodejs-mobile-$RELEASE-ios.zip"
    ARCHIVE_SHA256=dc7f0c6687510d8afcef7fa704a527dc802c9d1bbd095bbdff10d5ee41d9fbc7
    LICENSE_SHA256=1f15e76a631ad6b7d120ed4516865751b916b43061a22a34f0e17dcbdf49a705
    LICENSE_IN_ARCHIVE=yes
    ;;
  tvos|tvos-simulator|appletvos|appletvsimulator)
    VERSION=26.13.0
    RELEASE=v26.13.0-tvbox.1
    BASE="https://github.com/jo32/nodejs-mobile/releases/download/$RELEASE"
    ARCHIVE_NAME="nodejs-mobile-v$VERSION-apple.zip"
    ARCHIVE_SHA256=a84ac23e389f186dc64a78e2350b747b6e3f6cf56db12c9e1c3561db156b6440
    LICENSE_SHA256=12d632aa78f637d8c899f19d4549538c477b6df3836fe86731cd821f750abac8
    LICENSE_IN_ARCHIVE=no
    ;;
  *) echo "Unsupported Node mobile platform: $1" >&2; exit 2 ;;
esac
OUT=build/NodeMobile
CACHE_ROOT="${TVBOX_CACHE:-$HOME/Library/Caches}/tvbox-nodejs-mobile"
CACHE="$CACHE_ROOT/$RELEASE"

# Points build/NodeMobile at a folder; two builds (iOS and tvOS) may race to do it.
link() {
  [ "$(readlink "$OUT" 2>/dev/null)" = "$1" ] && return 0
  mkdir -p build
  rm -rf "$OUT"
  ln -s "$1" "$OUT" 2>/dev/null || [ "$(readlink "$OUT")" = "$1" ]
}

if [ -n "${NODE_MOBILE_DIR:-}" ]; then
  DIR=$(cd "$NODE_MOBILE_DIR" && pwd)
  [ -d "$DIR/NodeMobile.xcframework" ] || { echo "error: $DIR has no NodeMobile.xcframework" >&2; exit 1; }
  link "$DIR"
  echo "nodejs-mobile: using your build in $DIR"
  exit 0
fi

if [ "$(cat "$CACHE/VERSION" 2>/dev/null)" != "$RELEASE" ]; then
  echo "nodejs-mobile: downloading the prebuilt $RELEASE (about 80 MB, once per Mac)"
  mkdir -p "$CACHE_ROOT"
  TMP=$(mktemp -d "$CACHE_ROOT/.download.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL --retry 3 -o "$TMP/apple.zip" "$BASE/$ARCHIVE_NAME"
  echo "$ARCHIVE_SHA256  $TMP/apple.zip" | shasum -a 256 -c - > /dev/null
  # Node.js's LICENSE covers Node.js and the dependencies built into the framework.
  if [ "$LICENSE_IN_ARCHIVE" = yes ]; then
    unzip -p "$TMP/apple.zip" LICENSE > "$TMP/LICENSE"
  else
    curl -fsSL --retry 3 -o "$TMP/LICENSE" "$BASE/LICENSE"
  fi
  echo "$LICENSE_SHA256  $TMP/LICENSE" | shasum -a 256 -c - > /dev/null
  mkdir "$TMP/release"
  unzip -q "$TMP/apple.zip" 'NodeMobile.xcframework/*' -d "$TMP/release"
  cp "$TMP/LICENSE" "$TMP/release/LICENSE.node"
  echo "$RELEASE" > "$TMP/release/VERSION"
  # A complete folder appears in one rename (rename(2), which unlike mv never moves it into a folder already
  # there); when another build got there first, its copy is the same.
  [ -f "$CACHE/VERSION" ] || rm -rf "$CACHE"
  perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$TMP/release" "$CACHE" || [ "$(cat "$CACHE/VERSION" 2>/dev/null)" = "$RELEASE" ]
fi
link "$CACHE"
echo "nodejs-mobile $RELEASE is in $OUT"
