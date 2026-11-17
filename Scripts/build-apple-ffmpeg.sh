#!/bin/bash
# Builds the unified native iOS FFmpeg used by KSPlayer and TVMedia.
# All stock decoders/demuxers/parsers, dav1d AV1, davs2 AVS2, uavs3d AVS3,
# patched reference AV3A, selected
# audio/video filters, HTTP/HTTPS and DASH are compiled for iOS 16.2 arm64.
# AV3A reference-code policy is reflected by FFmpeg's --enable-nonfree build flag.
# Output and disposable build caches stay inside this maintained project.
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE="${TVBOX_FFMPEG_CACHE:-$PWD/build/FFmpeg/cache}"
SLICES="${TVBOX_FFMPEG_SLICES:-ios}"
SLICES="${SLICES//,/ }"
read -r -a selected_slices <<< "$SLICES"
[ "${#selected_slices[@]}" -gt 0 ] || { echo "Select at least one FFmpeg slice." >&2; exit 2; }
for slice in "${selected_slices[@]}"; do
  case "$slice" in
    ios) ;;
    *) echo "This maintained route builds only iOS arm64." >&2; exit 2 ;;
  esac
done
PROJECT_ROOT="$PWD"
python3 Scripts/build-ios-av3a.py
python3 Scripts/build-ios-avs.py --jobs "${JOBS:-2}"
SIGNATURE="$(python3 - "${selected_slices[@]}" <<'HASH'
import hashlib, sys
from pathlib import Path
h = hashlib.sha256()
paths = [Path("Scripts/build-apple-ffmpeg.sh"), Path("Scripts/write-player-capabilities.py"), Path("Scripts/build-ios-av3a.py"), Path("Scripts/prepare-ffmpeg-av3a.py"), Path("Scripts/build-ios-avs.py")]
paths += sorted(p for p in Path("Vendor/AV3A").rglob("*") if p.is_file())
paths += sorted(p for p in Path("Vendor/AVSNative").rglob("*") if p.is_file())
for p in paths:
    h.update(str(p).encode()); h.update(p.read_bytes())
h.update(Path("build/AV3A/iphoneos/lib/libtvav3a.a").read_bytes())
for name in ["davs2", "uavs3d"]:
    h.update(Path(f"build/AVSNative/iphoneos/lib/lib{name}.a").read_bytes())
h.update(" ".join(sys.argv[1:]).encode())
print(h.hexdigest()[:16])
HASH
)"
OUTPUT="$CACHE/$SIGNATURE/FFmpeg.xcframework"
LINK="$PWD/build/FFmpeg/FFmpeg.xcframework"
if [ -z "${PKG_CONFIG:-}" ] && [ -x "$PWD/build/tools/pkgconf/bin/pkgconf" ]; then
  export PKG_CONFIG="$PWD/build/tools/pkgconf/bin/pkgconf"
fi
link() {
  mkdir -p "$(dirname "$LINK")"
  [ "$(readlink "$LINK" 2>/dev/null)" = "$OUTPUT" ] || { rm -rf "$LINK"; ln -s "$OUTPUT" "$LINK"; }
}
if [ -f "$OUTPUT/Info.plist" ]; then
  link
  python3 Scripts/write-player-capabilities.py --config "$CACHE/$SIGNATURE/config_components.h" --license-config "$CACHE/$SIGNATURE/config.h" --archive "$OUTPUT/ios-arm64/libFFmpeg.a"
  echo "FFmpeg is up to date: $OUTPUT"
  exit 0
fi
WORK="$CACHE/work"
# Two checkouts building at once would share the work folder.
mkdir -p "$CACHE"
mkdir "$CACHE/lock" 2>/dev/null || { echo "Another FFmpeg build is running (or remove $CACHE/lock)" >&2; exit 1; }
trap 'rmdir "$CACHE/lock"' EXIT
mkdir -p "$WORK"

# RECIPE
VERSION=8.1.3
COMMIT=1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7
SOURCE="$WORK/FFmpeg-n$VERSION"
if [ ! -f "$SOURCE/configure" ]; then
  rm -rf "$SOURCE.download"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "n$VERSION" https://github.com/FFmpeg/FFmpeg.git "$SOURCE.download"
  test "$(git -C "$SOURCE.download" rev-parse HEAD)" = "$COMMIT"
  rm -rf "$SOURCE"; mv "$SOURCE.download" "$SOURCE"
fi
python3 Scripts/prepare-ffmpeg-av3a.py "$SOURCE"
# dav1d decodes AV1 for the conversion path where there is no AV1 hardware (Macs before the M3, iPhones and
# iPads before the A17 Pro, Apple TV).
DAV1D_VERSION=1.5.4
DAV1D_COMMIT=54706fc6bc0cdecab7e9593974a4039cc038fca7
DAV1D="$WORK/dav1d-$DAV1D_VERSION"
if [ ! -f "$DAV1D/meson.build" ]; then
  rm -rf "$DAV1D.download"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$DAV1D_VERSION" https://code.videolan.org/videolan/dav1d.git "$DAV1D.download"
  test "$(git -C "$DAV1D.download" rev-parse HEAD)" = "$DAV1D_COMMIT"
  rm -rf "$DAV1D"; mv "$DAV1D.download" "$DAV1D"
fi
# Its build tools, in a folder of their own.
TOOLS="$WORK/meson-1.9.1-ninja-1.13.2"
if [ ! -x "$TOOLS/bin/ninja" ]; then
  rm -rf "$TOOLS"
  python3 -m venv "$TOOLS"
  "$TOOLS/bin/pip" install --quiet --disable-pip-version-check meson==1.9.1 ninja==1.13.2
fi

DEMUXERS=matroska,avi,flv,asf,rm,mpegts,mpegps,mov,ogg
VIDEO_DECODERS=h264,hevc,mpeg1video,mpeg2video,mpeg4,msmpeg4v1,msmpeg4v2,msmpeg4v3,h263,flv,vc1,wmv1,wmv2,wmv3,rv10,rv20,rv30,rv40,vp6,vp6a,vp6f,vp8,vp9,theora,mjpeg,libdav1d
AUDIO_DECODERS=aac,aac_latm,ac3,eac3,dca,truehd,mlp,mp1,mp2,mp3,vorbis,opus,flac,alac,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le,pcm_u8,pcm_bluray,pcm_dvd,wmav1,wmav2,wmapro,wmalossless,cook,sipr,atrac3,ra_144,ra_288,amrnb,amrwb,adpcm_ima_wav,adpcm_ms
PARSERS=h264,hevc,aac,aac_latm,ac3,mpegaudio,dca,mlp,flac,vorbis,opus,mpeg4video,mpegvideo,vc1,vp8,vp9,av1,h263,rv34,cook
BSFS=aac_adtstoasc,extract_extradata,vp9_superframe
ENCODERS=aac_at,h264_videotoolbox,hevc_videotoolbox
# VideoToolbox decoding, for the picture that is converted (HDR to SDR) on the media engine, not the CPU.
HWACCELS=h264_videotoolbox,hevc_videotoolbox

build_slice() {
  local name=$1 sdk=$2 arch=$3 triple=$4
  local build="$WORK/build-$name" prefix="$WORK/install-$name"
  local sysroot cc extra=() asm=true
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" --find clang)"
  # No nasm on the build Mac: Intel Macs lose only the conversion path's assembly (FFmpeg's and dav1d's);
  # copying needs none.
  [ "$arch" = x86_64 ] && { extra+=(--disable-x86asm); asm=false; }
  rm -rf "$build" "$prefix" "$WORK/dav1d-build-$name"; mkdir -p "$build"
  cat > "$build/dav1d.cross" <<CROSS
[binaries]
c = '$cc'
ar = '$(xcrun --sdk "$sdk" --find ar)'
strip = '$(xcrun --sdk "$sdk" --find strip)'
[built-in options]
c_args = ['-target', '$triple', '-isysroot', '$sysroot']
c_link_args = ['-target', '$triple', '-isysroot', '$sysroot']
[properties]
needs_exe_wrapper = true
[host_machine]
system = 'darwin'
cpu_family = '$arch'
cpu = '$arch'
endian = 'little'
CROSS
  PATH="$TOOLS/bin:$PATH" "$TOOLS/bin/meson" setup "$WORK/dav1d-build-$name" "$DAV1D" --cross-file "$build/dav1d.cross" \
    --prefix "$prefix" --libdir lib --buildtype release --default-library static -Denable_asm=$asm \
    -Denable_tools=false -Denable_examples=false -Denable_tests=false -Denable_docs=false \
    > "$build/dav1d-setup.log" 2>&1 || { tail -30 "$build/dav1d-setup.log"; exit 1; }
  PATH="$TOOLS/bin:$PATH" ninja -j "${JOBS:-$(sysctl -n hw.ncpu)}" -C "$WORK/dav1d-build-$name" install > "$build/dav1d-build.log" 2>&1 \
    || { tail -40 "$build/dav1d-build.log"; exit 1; }
  # The iPhoneOS SDK provides libxml2 but does not ship its pkg-config metadata.
  # Generate metadata pointing only at this SDK, so DASH never picks a host library.
  cat > "$prefix/lib/pkgconfig/libxml-2.0.pc" <<XMLPC
prefix=$sysroot/usr
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libXML
Description: iPhoneOS SDK libxml2
Version: 2.9.13
Libs: -L\${libdir} -lxml2
Cflags: -I\${includedir}/libxml2
XMLPC
  (
    cd "$build"
    # Only this slice's dav1d, never one installed on the Mac.
    PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$PROJECT_ROOT/build/AV3A/iphoneos/lib/pkgconfig:$PROJECT_ROOT/build/AVSNative/iphoneos/lib/pkgconfig" PKG_CONFIG_PATH= \
    "$SOURCE/configure" --prefix="$prefix" --enable-cross-compile --target-os=darwin --arch="$arch" \
      --cc="$cc" --sysroot="$sysroot" \
      --extra-cflags="-target $triple -fno-common" --extra-ldflags="-target $triple" \
      --disable-programs --disable-doc --disable-debug --disable-shared --enable-static --enable-pic \
      --disable-autodetect --enable-pthreads --enable-zlib --enable-videotoolbox --enable-audiotoolbox \
      --enable-libtvav3a --enable-nonfree --enable-libxml2 --extra-cflags="-target $triple -fno-common -I$sysroot/usr/include/libxml2" \
      --enable-libdav1d --enable-libdavs2 --enable-libuavs3d --enable-gpl \
      --pkg-config="${PKG_CONFIG:-pkg-config}" --pkg-config-flags=--static \
      --disable-everything --enable-network --enable-securetransport --disable-avdevice --enable-avfilter \
      --enable-demuxers --enable-muxer=mp4 \
      --enable-decoders --enable-encoder="$ENCODERS" \
      --enable-parsers --enable-bsfs --enable-hwaccel="$HWACCELS" \
      --enable-protocol=file,http,https,tcp,tls,udp,rtp,rtmp,rtmps,crypto,data,pipe,concat,async,cache \
      --enable-filter=abuffer,abuffersink,buffer,buffersink,aformat,aresample,atempo,anull,volume,scale,format,null,fps,idet,yadif,bwdif,hflip,vflip,transpose,overlay,pad,crop,eq \
      ${extra[@]+"${extra[@]}"} > configure.log 2>&1 || { tail -30 configure.log; exit 1; }
    make -j "${JOBS:-$(sysctl -n hw.ncpu)}" > make.log 2>&1 || { tail -40 make.log; exit 1; }
    make install > install.log 2>&1
  )
  # One archive per slice, so the xcframework names a single library.
  libtool -static -no_warning_for_no_symbols -o "$prefix/libFFmpeg.a" \
    "$prefix"/lib/libavformat.a "$prefix"/lib/libavcodec.a "$prefix"/lib/libavfilter.a "$prefix"/lib/libswresample.a \
    "$prefix"/lib/libswscale.a "$prefix"/lib/libavutil.a "$prefix"/lib/libdav1d.a \
    "$PROJECT_ROOT/build/AV3A/iphoneos/lib/libtvav3a.a" \
    "$PROJECT_ROOT/build/AVSNative/iphoneos/lib/libdavs2.a" \
    "$PROJECT_ROOT/build/AVSNative/iphoneos/lib/libuavs3d.a"
  echo "FFmpeg $name built"
}

for slice in "${selected_slices[@]}"; do
  case "$slice" in
    macos-arm64) build_slice "$slice" macosx aarch64 arm64-apple-macos14.0 ;;
    macos-x86_64) build_slice "$slice" macosx x86_64 x86_64-apple-macos14.0 ;;
    ios) build_slice "$slice" iphoneos aarch64 arm64-apple-ios16.2 ;;
    ios-simulator) build_slice "$slice" iphonesimulator aarch64 arm64-apple-ios16.2-simulator ;;
    ios-simulator-x86_64) build_slice "$slice" iphonesimulator x86_64 x86_64-apple-ios16.2-simulator ;;
    tvos) build_slice "$slice" appletvos aarch64 arm64-apple-tvos17.0 ;;
    tvos-simulator) build_slice "$slice" appletvsimulator aarch64 arm64-apple-tvos17.0-simulator ;;
  esac
done
# END

PARTIAL="$CACHE/$SIGNATURE.partial"
rm -rf "$OUTPUT" "$PARTIAL"; mkdir -p "$PARTIAL"
arguments=()
add_platform() {
  local platform=$1 candidate selected headers= archives=()
  shift
  for candidate in "$@"; do
    for selected in "${selected_slices[@]}"; do
      if [ "$candidate" = "$selected" ]; then
        archives+=("$WORK/install-$candidate/libFFmpeg.a")
        headers="$WORK/install-$candidate/include"
        break
      fi
    done
  done
  [ "${#archives[@]}" -gt 0 ] || return 0
  if [ "${#archives[@]}" -gt 1 ]; then
    mkdir -p "$WORK/universal-$platform"
    lipo -create "${archives[@]}" -output "$WORK/universal-$platform/libFFmpeg.a"
    arguments+=(-library "$WORK/universal-$platform/libFFmpeg.a" -headers "$headers")
  else
    arguments+=(-library "${archives[0]}" -headers "$headers")
  fi
}
add_platform macos macos-arm64 macos-x86_64
add_platform ios ios
add_platform ios-simulator ios-simulator ios-simulator-x86_64
add_platform tvos tvos
add_platform tvos-simulator tvos-simulator
xcodebuild -create-xcframework "${arguments[@]}" -output "$PARTIAL/FFmpeg.xcframework" > /dev/null
rm -rf "$(dirname "$OUTPUT")"; mv "$PARTIAL" "$(dirname "$OUTPUT")"
cp "$WORK/build-ios/config_components.h" "$CACHE/$SIGNATURE/config_components.h"
cp "$WORK/build-ios/config.h" "$CACHE/$SIGNATURE/config.h"
link
python3 Scripts/write-player-capabilities.py --config "$CACHE/$SIGNATURE/config_components.h" --license-config "$CACHE/$SIGNATURE/config.h" --archive "$OUTPUT/ios-arm64/libFFmpeg.a"
echo "FFmpeg $VERSION: $OUTPUT"
