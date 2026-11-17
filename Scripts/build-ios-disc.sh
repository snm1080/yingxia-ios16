#!/bin/bash
# iOS arm64 only: LGPL libbluray + bundled libudfread, no Java or menu runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
DISC_ROOT="$PWD"
DISC_VERSION=1.3.4
DISC_SHA=478ffd68a0f5dde8ef6ca989b7f035b5a0a22c599142e5cd3ff7b03bbebe5f2b
DISC_ARCHIVE="$DISC_ROOT/Vendor/DiscNative/sources/libbluray-$DISC_VERSION.tar.bz2"
[ "$(shasum -a 256 "$DISC_ARCHIVE" | awk '{print $1}')" = "$DISC_SHA" ] || { echo 'libbluray source SHA-256 mismatch' >&2; exit 1; }
DISC_SIGNATURE="$( { cat "$0"; printf '%s\n' "$DISC_SHA"; } | shasum -a 256 | cut -c1-16)"
DISC_CACHE="$DISC_ROOT/build/Disc/$DISC_SIGNATURE"
DISC_OUTPUT="$DISC_CACHE/DiscNative.xcframework"
DISC_LINK="$DISC_ROOT/Vendor/DiscNative/DiscNative.xcframework"
link_disc() {
  [ "$(readlink "$DISC_LINK" 2>/dev/null || true)" = "../../build/Disc/$DISC_SIGNATURE/DiscNative.xcframework" ] || {
    rm -rf "$DISC_LINK"
    ln -s "../../build/Disc/$DISC_SIGNATURE/DiscNative.xcframework" "$DISC_LINK"
  }
}
if [ -f "$DISC_OUTPUT/Info.plist" ]; then link_disc; echo "DiscNative is up to date: $DISC_OUTPUT"; exit 0; fi
mkdir -p "$DISC_CACHE"
mkdir "$DISC_ROOT/build/Disc/lock" 2>/dev/null || { echo 'Another DiscNative build is running' >&2; exit 1; }
trap 'rmdir "$DISC_ROOT/build/Disc/lock"' EXIT
DISC_WORK="$DISC_CACHE/work"
mkdir -p "$DISC_WORK"
tar -xjf "$DISC_ARCHIVE" -C "$DISC_WORK"
DISC_SOURCE="$DISC_WORK/libbluray-$DISC_VERSION"
# iOS has no optical devices or DiskArbitration framework. Keep image/directory
# paths intact and let libudfread read the image directly, without OS mounting.
cat > "$DISC_SOURCE/src/file/mount_darwin.c" <<'C'
#include "mount.h"
#include <string.h>
char *mount_get_mountpoint(const char *path) { return path ? strdup(path) : NULL; }
C
sed -i '' 's/-framework DiskArbitration//g' "$DISC_SOURCE/configure"
# 1.3.4's --disable-bdjava-jar disables JAR generation only, and otherwise
# retains the JVM loader. Replace that module with an explicit unavailable
# implementation and remove every JNI native implementation from this build.
python3 - "$DISC_SOURCE" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
for source in (p/'src/libbluray/bdj/native').glob('*.c'):
    source.write_text('/* iOS local edition: Java execution removed. */\n')
bdj=p/'src/libbluray/bdj/bdj.c'
bdj.write_text('''#include "bdj.h"
#include <stdlib.h>
void bdj_config_cleanup(BDJ_CONFIG *p) {
    free(p->persistent_root); free(p->cache_root); free(p->java_home);
    free(p->classpath[0]); free(p->classpath[1]);
    p->persistent_root = p->cache_root = p->java_home = NULL;
    p->classpath[0] = p->classpath[1] = NULL;
}
''')
bluray=p/'src/libbluray/bluray.c'
s=bluray.read_text().replace('#include "bdj/bdj.h"', '''#include "bdj/bdj.h"
#define bdj_open(path, bd, id, storage) ((BDJAVA *)0)
#define bdj_close(java) ((void)0)
#define bdj_process_event(java, ev, param) 0
#define bdj_jvm_available(storage) BDJ_CHECK_NO_JVM''')
bluray.write_text(s)
PY
DISC_BUILD="$DISC_WORK/ios-arm64"
DISC_PREFIX="$DISC_WORK/install"
mkdir -p "$DISC_BUILD"
DISC_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
DISC_CC="$(xcrun --sdk iphoneos --find clang)"
(
 cd "$DISC_BUILD"
 CC="$DISC_CC" AR="$(xcrun --sdk iphoneos --find ar)" RANLIB="$(xcrun --sdk iphoneos --find ranlib)" \
 CFLAGS="-O2 -target arm64-apple-ios16.2 -isysroot $DISC_SDK -fPIC -fvisibility=hidden" \
 LDFLAGS="-target arm64-apple-ios16.2 -isysroot $DISC_SDK" \
 "$DISC_SOURCE/configure" --host=aarch64-apple-darwin --prefix="$DISC_PREFIX" \
 --disable-shared --enable-static --without-external-libudfread \
 --without-libxml2 --without-freetype --without-fontconfig --disable-bdjava-jar \
 --disable-examples --disable-doxygen-doc > configure.log 2>&1 || { tail -50 configure.log; exit 1; }
 make -j "${JOBS:-$(sysctl -n hw.ncpu)}" > make.log 2>&1 || { tail -60 make.log; exit 1; }
 make install > install.log 2>&1
)
# Check the actual UDF implementation and Java exclusion before packaging.
nm -g "$DISC_PREFIX/lib/libbluray.a" > "$DISC_CACHE/symbols.txt"
rg -q ' T _udfread_open_input' "$DISC_CACHE/symbols.txt"
if rg -q ' T _(JNI_|Java_|bdj_open|bdj_start)' "$DISC_CACHE/symbols.txt"; then echo 'Unexpected Java execution symbols' >&2; exit 1; fi
[ "$(lipo -archs "$DISC_PREFIX/lib/libbluray.a")" = arm64 ]
xcodebuild -create-xcframework -library "$DISC_PREFIX/lib/libbluray.a" -headers "$DISC_PREFIX/include" -output "$DISC_CACHE/DiscNative.partial.xcframework" > "$DISC_CACHE/xcframework.log" 2>&1
mv "$DISC_CACHE/DiscNative.partial.xcframework" "$DISC_OUTPUT"
link_disc
python3 - "$DISC_OUTPUT" "$DISC_SHA" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); lib=next(p.rglob('libbluray.a'))
(p.parent/'manifest.json').write_text(json.dumps({'library':'libbluray','version':'1.3.4','sourceSha256':sys.argv[2],'librarySha256':hashlib.sha256(lib.read_bytes()).hexdigest(),'platform':'iOS','architecture':'arm64','minimumOS':'16.2','libudfread':'bundled','java':False,'encryptedDiscs':False,'menus':False},indent=2)+'\n')
PY
echo "DiscNative iOS arm64 built: $DISC_OUTPUT"
