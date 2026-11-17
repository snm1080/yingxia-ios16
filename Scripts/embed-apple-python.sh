#!/bin/bash
# Xcode build phase of the iOS and tvOS apps: embeds build/ApplePython/$PLATFORM_NAME, made by
# Scripts/build-apple-python.sh, and signs its frameworks before Xcode signs the app. A build without it
# in Debug still works: ApplePython.c reports Python as missing and the app offers no Python sources.
# A Release build requires the runtime so Python sources are retained in the delivered application.
set -euo pipefail
SOURCE="$SRCROOT/build/ApplePython/$PLATFORM_NAME"
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
sync_current_host() {
  mkdir -p "$APP/PythonHost"
  cp "$SRCROOT/Runtime/PythonHost/host.py" "$APP/PythonHost/host.py"
  rsync -a --delete --delete-excluded --exclude '__pycache__/' --exclude '*.pyc' \
    "$SRCROOT/Runtime/PythonHost/base/" "$APP/PythonHost/base/"
  # A prepared runtime may contain unchecked-hash bytecode from an earlier source revision.
  # Python must read the current host and helpers that this app was built from.
  find "$APP/PythonHost" -maxdepth 1 -name 'host.*.pyc' -delete
  if [ -d "$APP/PythonHost/__pycache__" ]; then
    find "$APP/PythonHost/__pycache__" -name 'host.*.pyc' -delete
  fi
}
# Copying and re-signing the ~100 frameworks takes ~10 s, and signing changes them, so rsync would copy them
# again on every build. Skip both while the source, the signing and the embedded copy are unchanged.
STAMP="${DERIVED_FILE_DIR:-$TARGET_TEMP_DIR}/embed-apple-python.stamp"
if [ ! -d "$SOURCE" ]; then
  case "$PLATFORM_NAME" in
    iphoneos) target=ios ;; iphonesimulator) target=ios-simulator ;; appletvos) target=tvos ;; *) target=tvos-simulator ;;
  esac
  if [ "${CONFIGURATION:-}" = Release ]; then
    echo "error: This release needs Python. Run Scripts/build-apple-python.sh $target first." >&2
    exit 1
  fi
  echo "warning: This build has no Python runtime, so Python sources won't run. Run Scripts/build-apple-python.sh $target first."
  rm -rf "$APP/python" "$APP/PythonHost" "$APP/Frameworks/Python.framework" "$STAMP"
  exit 0
fi
SIGN=
if [ "${CODE_SIGNING_ALLOWED:-YES}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then SIGN=yes; fi
KEY=$({
  echo "$APP|$SIGN|${EXPANDED_CODE_SIGN_IDENTITY:-}|${OTHER_CODE_SIGN_FLAGS:-}"
  find "$SOURCE" -exec stat -f '%m %z %N' {} +
} | md5 -q)
embedded() {
  [ -d "$APP/python" ] && [ -d "$APP/PythonHost" ] || return 1
  for framework in "$SOURCE/Frameworks/"*.framework; do
    local copy="$APP/Frameworks/$(basename "$framework")"
    [ -d "$copy" ] || return 1
    [ -z "$SIGN" ] || [ -d "$copy/_CodeSignature" ] || return 1
  done
}
if [ "$(cat "$STAMP" 2>/dev/null)" = "$KEY" ] && embedded; then
  sync_current_host
  echo "Python runtime already embedded and signed"
  exit 0
fi
rm -f "$STAMP"
rsync -a --delete "$SOURCE/python/" "$APP/python/"
rsync -a --delete "$SOURCE/PythonHost/" "$APP/PythonHost/"
sync_current_host
mkdir -p "$APP/Frameworks"
for framework in "$SOURCE/Frameworks/"*.framework; do
  rsync -a --delete "$framework/" "$APP/Frameworks/$(basename "$framework")/"
done
if [ -n "$SIGN" ]; then
  for framework in "$SOURCE/Frameworks/"*.framework; do
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} -o runtime --timestamp=none \
      --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$APP/Frameworks/$(basename "$framework")"
  done
fi
mkdir -p "$(dirname "$STAMP")"
echo "$KEY" > "$STAMP"
