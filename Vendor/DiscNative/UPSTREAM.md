# iOS Blu-ray reader

Pinned libbluray 1.3.4 release source (including its bundled libudfread):
https://download.videolan.org/pub/videolan/libbluray/1.3.4/libbluray-1.3.4.tar.bz2

SHA-256: `478ffd68a0f5dde8ef6ca989b7f035b5a0a22c599142e5cd3ff7b03bbebe5f2b`.
The source archive is retrieved into ignored `sources/` by `Scripts/fetch-vendor-dependencies.py`.

`Scripts/build-ios-disc.sh` builds only arm64 iOS 16.2 static code and packages
an XCFramework. It disables BD-J, examples, external XML/font libraries, and
uses the bundled UDF reader. libbluray and libudfread are LGPL 2.1 or later;
`LICENSE.libbluray` applies to both. Their per-file copyright notices are
preserved in the release archive.

This integration reads unencrypted ISO/UDF images and local BDMV directories.
It selects and streams a movie playlist directly. Interactive HDMV/BD-J menus,
AACS/BD+ decryption and Java execution are not provided by this build.
