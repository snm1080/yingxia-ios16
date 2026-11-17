# AV3A audio in the independent iOS edition

This directory contains the native AVS3A reference decoder used by the local
iOS 16.2 arm64 build. The application calls it in process through the unified
FFmpeg library. It does not launch an external executable.

The reference source is pinned to:

- Repository: <https://github.com/Dreamello/av3a>
- Commit: `b44b5321862385a06ad6c427de5791e18f16c16b`
- Archive: <https://codeload.github.com/Dreamello/av3a/tar.gz/b44b5321862385a06ad6c427de5791e18f16c16b>
- Archive SHA-256: `036d238f0e2bbeb43107a25e74dc5ab77b245aa5e8a8d06385df5def2f28dea0`
- Decoder version reported by its README: `AVS3A_RMv3.3.1`.

`SOURCE-INVENTORY.json` records the original path and SHA-256 for every copied
source/header. `reference/` is prepared locally from the pinned source and is omitted from this upload package. This selection excludes
the upstream CLI entry point, prebuilt binaries, renderer, encoder entry point,
and ArcSoft's unused proprietary `ASLOG.h`/`ASLOG.cpp`. Some common C files also
contain encoder helper routines; they remain as required by the reference source
organization. No executable is imported or built.

The neural model is already embedded in `reference/common/model.h`: 79,930
bytes, decoded byte-array SHA-256
`47369924c90e5eb8272229cfe6f7172dbb838e0a5abac61187d50dc61b3a3542`.
`Avs3InitDecoder` copies this model and initializes the decoder from memory.
The historical `modelPath` function argument is unused in this pinned source.
The app needs no separate `model.bin`, writable model directory, or model download.

Huawei 2023 copyright and the UHD World Association Code Sharing Policy notices
remain in the source. The policy linked by those source notices was retrieved from
<https://www.theuwa.com/UWA_Code_Sharing_Policy.pdf> and is retained verbatim as
`UWA_Code_Sharing_Policy.pdf` (SHA-256
`4bf111af7d109edfab4353cfa4cc2694f65563947b1bebfa7d86a8ea3534d99d`).
This record does not clear public redistribution or any codec patent rights.
The local FFmpeg configuration explicitly uses `--enable-nonfree` so its license
report does not misrepresent the combined binary as an ordinary LGPL build.

The files `tvav3a.c`, `include/tvav3a.h`, and `ffmpeg/` are the local integration.
They use bounded header/frame parsing, validate payload CRC before decoding,
register a decoder and parser with FFmpeg 8.1.3, recognize MPEG-TS stream type
`0xd5`, and recognize the MP4 sample entry `av3a`. The AV3A codec ID is appended
after FFmpeg's existing audio IDs, preserving all stock codec ID values.

Supported output is signed, interleaved PCM16 for channel beds: mono, stereo,
4.0, 5.1, 7.1, 5.1.2, 5.1.4, 7.1.2, and 7.1.4. FFmpeg supplies speaker layouts
to the player for its normal audio conversion/output path. The integration
rejects object/HOA profiles because it does not include an immersive metadata
renderer. It does not claim Audio Vivid binaural/spatial rendering fidelity.

Build with `python3 Scripts/build-ios-av3a.py`, then apply
`python3 Scripts/prepare-ffmpeg-av3a.py <FFmpeg-source-directory>` before the
unified FFmpeg configuration. Both steps are called by `build-apple-ffmpeg.sh`.
The library output is `build/AV3A/iphoneos/lib/libtvav3a.a`; its build manifest
records target, pinned source, source fingerprint, and library hash. Only iPhoneOS
arm64 with minimum iOS 16.2 is built. NEON matrix operations are enabled.

The builder makes one temporary source adaptation: it preserves the upstream
implausible-latent clamp while removing its process-global diagnostic counters
and desktop log-file writes. The unused debug file writer is omitted from the
archive. The unchanged source remains in `reference/` and is hash-checked first.

