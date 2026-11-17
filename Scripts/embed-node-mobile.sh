#!/bin/bash
# Xcode build phase of the iOS and tvOS apps: embeds nodejs-mobile from build/NodeMobile and the CatPawOpen runner
# (Runtime/NodeHost), and signs the framework before Xcode signs the app. build/NodeMobile is the prebuilt release
# that Scripts/fetch-node-mobile.sh downloads (once per Mac), so contributors never build Node themselves.
# A Debug build that can't download it (offline) still works: EmbeddedNodeHost then reports Node as missing and
# CatPawOpen sources stay unsupported. A Release build stops instead, so no release ships without Node.
set -euo pipefail
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
case "$PLATFORM_NAME" in
  iphoneos) SLICES="ios-arm64" ;;
  iphonesimulator) SLICES="ios-arm64-simulator ios-arm64_x86_64-simulator" ;;
  appletvos) SLICES="tvos-arm64" ;;
  appletvsimulator) SLICES="tvos-arm64-simulator" ;;
  *) SLICES= ;;
esac
if [ -n "$SLICES" ] && ! "$SRCROOT/Scripts/fetch-node-mobile.sh"; then
  if [ "${CONFIGURATION:-}" = Release ]; then
    echo "error: Couldn't get the prebuilt Node.js runtime (Scripts/fetch-node-mobile.sh); a release needs it for CatPawOpen sources."
    exit 1
  fi
  echo "warning: Couldn't download the prebuilt Node.js runtime; building without it."
fi
FRAMEWORK=
for SLICE in $SLICES; do
  CANDIDATE="$SRCROOT/build/NodeMobile/NodeMobile.xcframework/$SLICE/NodeMobile.framework"
  if [ -d "$CANDIDATE" ]; then FRAMEWORK=$CANDIDATE; break; fi
done
# Signing changes the 55 MB binary, so rsync would copy it again on every build. Skip copying and signing
# while the source, the signing and the embedded copy are unchanged.
STAMP="${DERIVED_FILE_DIR:-$TARGET_TEMP_DIR}/embed-node-mobile.stamp"
if [ -z "$FRAMEWORK" ]; then
  if [ "${CONFIGURATION:-}" = Release ]; then
    echo "error: No Node.js framework for $PLATFORM_NAME; a release needs Node for CatPawOpen sources." >&2
    exit 1
  fi
  echo "warning: This build has no Node.js runtime, so CatPawOpen sources won't run. Scripts/fetch-node-mobile.sh downloads it."
  rm -rf "$APP/Frameworks/NodeMobile.framework" "$APP/NodeHost" "$STAMP"
  exit 0
fi
rsync -a --delete "$SRCROOT/Runtime/NodeHost/" "$APP/NodeHost/"
cp "$SRCROOT/build/NodeMobile/LICENSE.node" "$APP/NodeHost/LICENSE.node"
SIGN=
if [ "${CODE_SIGNING_ALLOWED:-YES}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then SIGN=yes; fi
KEY=$({
  echo "$APP|$SIGN|${EXPANDED_CODE_SIGN_IDENTITY:-}|${OTHER_CODE_SIGN_FLAGS:-}"
  find "$FRAMEWORK" -exec stat -f '%m %z %N' {} +
} | md5 -q)
COPY="$APP/Frameworks/NodeMobile.framework"
if [ "$(cat "$STAMP" 2>/dev/null)" = "$KEY" ] && [ -f "$COPY/NodeMobile" ] && [ -f "$COPY/PrivacyInfo.xcprivacy" ] && { [ -z "$SIGN" ] || [ -d "$COPY/_CodeSignature" ]; }; then
  echo "Node.js runtime already embedded"
  exit 0
fi
rm -f "$STAMP"
mkdir -p "$APP/Frameworks"
# The app opens the framework with dlopen and never compiles against it, so its headers stay out.
rsync -a --delete --exclude Headers --exclude Modules "$FRAMEWORK/" "$COPY/"
# A higher binary deployment target cannot be repaired by lowering its plist.
# Reject incompatible overrides before signing or shipping the app.
case "$PLATFORM_NAME" in
  iphone*) MAXIMUM_OS="${IPHONEOS_DEPLOYMENT_TARGET:-16.2}" ;;
  appletv*) MAXIMUM_OS="${TVOS_DEPLOYMENT_TARGET:-17.0}" ;;
esac
for NEEDED in $(xcrun vtool -show-build "$COPY/NodeMobile" | awk '/minos/ {print $2}'); do
  [ "$(printf '%s\n%s\n' "$NEEDED" "$MAXIMUM_OS" | sort -V | tail -1)" = "$MAXIMUM_OS" ] ||
    { echo "error: Node requires $PLATFORM_NAME $NEEDED; app targets $MAXIMUM_OS" >&2; exit 1; }
done
# Node links OpenSSL, a commonly used SDK: without a privacy manifest TestFlight review marks the build invalid
# (ITMS-91061), as it did the Python frameworks.
cp "$SRCROOT/Config/Python/PrivacyInfo.xcprivacy" "$COPY/"
if [ -n "$SIGN" ]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} --timestamp=none \
    --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$COPY"
fi
mkdir -p "$(dirname "$STAMP")"
echo "$KEY" > "$STAMP"
