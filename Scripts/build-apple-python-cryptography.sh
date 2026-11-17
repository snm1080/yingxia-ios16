#!/bin/bash
# iOS cffi and cryptography wheels for the interpreter assembled by build-apple-python.sh.
# The build tools stay in build/: this also works on Intel Macs without Homebrew or Rust installed.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:-ios}"
case "$TARGET" in
  ios) PLATFORM=iphoneos; SLICE=ios-arm64; RUST_TARGET=aarch64-apple-ios; OPENSSL_TARGET=ios64-xcrun
    RUST_TARGET_SHA=81fb496f94a3f52ec2818a76a7107905b13b37d490ca849d22c0a7a7d7b0125e ;;
  ios-simulator) PLATFORM=iphonesimulator; SLICE=ios-arm64_x86_64-simulator
    RUST_TARGET=aarch64-apple-ios-sim; OPENSSL_TARGET=iossimulator-arm64-xcrun
    RUST_TARGET_SHA=9362b66fbaf2503276ea34f34b41b171269db9ba4dce05dde3472ea9d1852601 ;;
  *) echo "Usage: $0 [ios|ios-simulator]" >&2; exit 2 ;;
esac
VERSION=3.14; SUPPORT=b13; MINIMUM_OS=16.2
WORK="$PWD/build/apple-python"
WHEELS="$WORK/wheels/$PLATFORM/$MINIMUM_OS"
XCFRAMEWORK="$WORK/iOS-$VERSION-$SUPPORT/Python.xcframework"
CROSS_VENV="$WORK/venv-$PLATFORM-$MINIMUM_OS"
HOST_PYTHON="${HOST_PYTHON:-$(bash Scripts/fetch-build-python.sh)}"
CFFI_VERSION="$(sed -n 's/^cffi==//p' Runtime/PythonHost/requirements.txt)"
CRYPTO_VERSION="$(sed -n 's/^cryptography==//p' Runtime/PythonHost/requirements.txt)"
[ "$CRYPTO_VERSION" = 48.0.1 ] || { echo 'Update the cryptography source checksum for this pin.' >&2; exit 1; }
mkdir -p "$WHEELS" "$WORK/sources"
if ! ls "$WHEELS/cffi-$CFFI_VERSION-"*.whl >/dev/null 2>&1; then
  "$CROSS_VENV/bin/python" -m pip download --quiet --disable-pip-version-check --no-deps \
    --only-binary=:all: "cffi==$CFFI_VERSION" -d "$WHEELS"
fi
if ls "$WHEELS/cryptography-$CRYPTO_VERSION-"*.whl >/dev/null 2>&1; then exit 0; fi

# Install only the compiler, Cargo and the host/target standard libraries from the official release.
# Hashes come from channel-rust-1.92.0.toml; no rustup or changes to the user's shell are required.
RUST_VERSION=1.92.0; RUST_DATE=2025-12-11
case "$(uname -m)" in
  x86_64) RUST_HOST=x86_64-apple-darwin
    RUSTC_SHA=0facbd5d2742c8e97c53d59c9b5b81db6088cfc285d9ecb99523a50d6765fc5c
    CARGO_SHA=b033a7c33aba8af947c9d0ab2785f9696347cded228ffe731897f1c627466262
    HOST_STD_SHA=6ce143bf9e83c71e200f4180e8774ab22c8c8c2351c88484b13ff13be82c8d57 ;;
  arm64) RUST_HOST=aarch64-apple-darwin
    RUSTC_SHA=15dee753c9217dff4cf45d734b29dc13ce6017d8a55fe34eed75022b39a63ff0
    CARGO_SHA=bce6e7def37240c5a63115828017a9fc0ebcb31e64115382f5943b62b71aa34a
    HOST_STD_SHA=ea619984fcb8e24b05dbd568d599b8e10d904435ab458dfba6469e03e0fd69aa ;;
  *) echo 'Unsupported build Mac architecture' >&2; exit 1 ;;
esac
RUST="$PWD/build/tools/rust-$RUST_VERSION-$RUST_HOST"
download() {
  local url="$1" checksum="$2" archive="$3"
  if [ ! -f "$archive" ]; then
    curl -fsSL --retry 3 "$url" -o "$archive.download"
    mv "$archive.download" "$archive"
  fi
  echo "$checksum  $archive" | shasum -a 256 -c - >&2
}
install_rust() {
  local component="$1" arch="$2" checksum="$3"
  local name="$component-$RUST_VERSION-$arch"
  [ -f "$RUST/.$name" ] && return 0
  download "https://static.rust-lang.org/dist/$RUST_DATE/$name.tar.xz" "$checksum" "$WORK/sources/$name.tar.xz"
  tar -xJf "$WORK/sources/$name.tar.xz" -C "$WORK/sources"
  bash "$WORK/sources/$name/install.sh" --prefix="$RUST" --disable-ldconfig
  touch "$RUST/.$name"
  rm -rf "$WORK/sources/$name"
}
install_rust rustc "$RUST_HOST" "$RUSTC_SHA"
install_rust cargo "$RUST_HOST" "$CARGO_SHA"
install_rust rust-std "$RUST_HOST" "$HOST_STD_SHA"
install_rust rust-std "$RUST_TARGET" "$RUST_TARGET_SHA"
export PATH="$RUST/bin:$PATH" CARGO_HOME="$WORK/cargo-home"

# Static OpenSSL makes the wheel independent of libraries outside the application.
OPENSSL_VERSION=3.5.9
OPENSSL_ARCHIVE="$WORK/sources/openssl-$OPENSSL_VERSION.tar.gz"
download "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
  603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a "$OPENSSL_ARCHIVE"
OPENSSL="$WORK/openssl-$PLATFORM-$MINIMUM_OS-$OPENSSL_VERSION"
SDK="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
if [ ! -f "$OPENSSL/lib/libcrypto.a" ] || [ ! -f "$OPENSSL/lib/libssl.a" ]; then
  rm -rf "$OPENSSL" && mkdir -p "$OPENSSL/source"
  tar -xzf "$OPENSSL_ARCHIVE" --strip-components=1 -C "$OPENSSL/source"
  (cd "$OPENSSL/source" && CC="$(xcrun --sdk "$PLATFORM" -f clang)" \
    ./Configure "$OPENSSL_TARGET" no-shared no-tests no-apps no-module no-engine \
      --prefix="$OPENSSL" -isysroot "$SDK" "-mios-version-min=$MINIMUM_OS" \
    && make -j "${JOBS:-6}" && make install_sw) > "$OPENSSL/build.log" 2>&1 \
    || { tail -40 "$OPENSSL/build.log" >&2; exit 1; }
fi

# CFFI must run on the Mac while generating C code. The cross interpreter supplies iOS platform metadata;
# PYTHONPATH gives its build scripts a native cffi backend, never the device's extension module.
NATIVE_VENV="$WORK/cryptography-host-venv"
if [ ! -x "$NATIVE_VENV/bin/maturin" ]; then
  "$HOST_PYTHON" -m venv "$NATIVE_VENV"
  "$NATIVE_VENV/bin/python" -m pip install --quiet --disable-pip-version-check \
    maturin==1.12.6 "cffi==$CFFI_VERSION" setuptools==80.9.0
fi
CRYPTO_ARCHIVE="$WORK/sources/cryptography-$CRYPTO_VERSION.tar.gz"
download 'https://files.pythonhosted.org/packages/source/c/cryptography/cryptography-48.0.1.tar.gz' \
  266f4ee051abb2f725b74ef8072b521ce1feacf685a3364fa6a6b45548db791a "$CRYPTO_ARCHIVE"
CRYPTO_SOURCE="$WORK/cryptography-$PLATFORM-$MINIMUM_OS-$CRYPTO_VERSION"
if [ ! -d "$CRYPTO_SOURCE" ]; then
  mkdir -p "$CRYPTO_SOURCE"
  tar -xzf "$CRYPTO_ARCHIVE" --strip-components=1 -C "$CRYPTO_SOURCE"
  # Upstream applies the macOS clang runtime to every Apple target. It is incompatible with iOS.
  "$HOST_PYTHON" -I - "$CRYPTO_SOURCE/src/rust/cryptography-cffi/build.rs" <<'PATCH'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
anchor = 'target.contains("apple") && openssl_static'
assert source.count(anchor) == 1, 'cryptography changed: update the iOS compiler-runtime patch'
path.write_text(source.replace(anchor, 'target.ends_with("apple-darwin") && openssl_static'))
PATCH
fi
export IPHONEOS_DEPLOYMENT_TARGET="$MINIMUM_OS" OPENSSL_DIR="$OPENSSL" OPENSSL_STATIC=1
export PYTHONPATH="$NATIVE_VENV/lib/python$VERSION/site-packages"
export PYO3_CROSS=1 PYO3_CROSS_PYTHON_VERSION="$VERSION"
export RUSTFLAGS="-Lnative=$XCFRAMEWORK/$SLICE/lib"
env "CC_${RUST_TARGET//-/_}=$(xcrun --sdk "$PLATFORM" -f clang)" \
  "CFLAGS_${RUST_TARGET//-/_}=-target arm64-apple-ios$MINIMUM_OS$([ "$PLATFORM" != iphonesimulator ] || echo -simulator) -isysroot $SDK -I$XCFRAMEWORK/$SLICE/include/python$VERSION" \
  "$NATIVE_VENV/bin/maturin" build --release --locked --target "$RUST_TARGET" \
    -i "$CROSS_VENV/bin/python" --manifest-path "$CRYPTO_SOURCE/src/rust/Cargo.toml" --out "$WHEELS"
