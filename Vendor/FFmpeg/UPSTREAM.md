# Unified native FFmpeg

Upstream: https://github.com/FFmpeg/FFmpeg, tag n8.1.3, commit
`1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7`. FFmpeg's license text is retained in `LICENSE`.

`Scripts/build-apple-ffmpeg.sh` prepares a single iOS 16.2 arm64 static archive shared by
KSPlayer's native demux/decode path and the TVMedia utility APIs. This prevents duplicate FFmpeg
symbols or mixed ABI versions. Its default builds only the iOS device slice. Prepared sources,
objects, archive and xcframework live inside `build/FFmpeg/`; this vendor directory links to it.

The build enables stock demuxers, parsers and decoders, dav1d AV1, selected video/audio filters,
VideoToolbox/AudioToolbox, SecureTransport HTTP/HTTPS and SDK libxml2 for DASH. VVC and VP5 use
FFmpeg's native decoders. dav1d 1.5.4 is pinned at
`54706fc6bc0cdecab7e9593974a4039cc038fca7` (BSD-2-Clause, `LICENSE.dav1d`).
The AV3A reference decoder and maintained FFmpeg integration are described in `Vendor/AV3A/UPSTREAM.md`;
AVS2 davs2-10bit and AVS3 uavs3d are pinned under `Vendor/AVSNative`, with offline source archives,
patches and license hashes. `Scripts/build-ios-avs.py` prepares their iOS arm64 libraries and explicit
simulator slices, then they are merged into the same FFmpeg archive. Both use 10-bit-capable builds.
The actual build uses `--enable-gpl` for davs2 and `--enable-nonfree` for AV3A and must not be
described as LGPL-only or unmodified FFmpeg. These flags do not clear public redistribution.
KSPlayer and the C shim dependency separately preserve their GPL-3.0 licenses.

`Scripts/write-player-capabilities.py` checks the actual codec/protocol configuration and arm64 archive
symbols, including both AVS decoder adapters and native implementations, and writes
`build/FFmpeg/player-capabilities.json`. GPL/nonfree values are read from the actual build configuration.
The archive's SHA-256 and enabled features
are recorded there. These checks establish compiled native capabilities, not device playback results.
