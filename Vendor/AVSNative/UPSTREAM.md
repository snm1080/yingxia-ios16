# Native AVS2 and AVS3 video dependencies

This directory retains the pinned AVS2/AVS3 dependency metadata and local patches.
`SOURCE-INVENTORY.json` records every repository, revision, URL and SHA-256.
Run `Scripts/fetch-vendor-dependencies.py` to restore archives into ignored `sources/`.

| Dependency | Pinned source | License |
| --- | --- | --- |
| davs2 10bit fork | `xatabhk/davs2-10bit` at `21d64c8f8e36af71fc7a488cd6f789c86cdd1200` | GPL-2.0-or-later, as stated in its source headers; GPL v2 text retained |
| uavs3d | `uavs3/uavs3d` at `0e20d2c291853f196c68922a264bcd8471d75b68` | BSD-3-Clause |

The two existing davs2 patches are from `nilaoda/mpv-iina-avs` at
`0c8f04194d23ef17cac0b5928f021d177421e03c`. They enable the 10-bit build and
packet positions, and export sequence color metadata. Their exact bytes and
hashes are retained. Applying them does not establish that FFmpeg exports all
additional fields: its stock 8.1.3 davs2 adapter does not consume the added color
description or packet-position fields.

`Scripts/build-ios-avs.py` builds only native static archives, with no downloads,
Java, subprocess decoder or executable runtime dependency. The default target
is `arm64-apple-ios16.2`; explicit simulator targets append `-simulator` and can
use arm64 or x86_64. Both dependencies use the 10-bit-capable implementation,
which accepts 8-bit and 10-bit streams. uavs3d targets AVS3-P2 baseline profiles;
this is not a claim to cover every AVS profile.

davs2 uses its 23 generic C++ translation units and `--disable-asm`, matching
the local MacCat build route. uavs3d uses 29 C/assembly units on ARM64, with its
ARM64 optimizations, or 31 C units with SSE4.2/AVX2 dispatch on x86_64. The builder
normalizes davs2 source line endings before applying the published patches,
pins generated version strings instead of embedding the build clock, and writes
SDK-local pkg-config files. Source archives remain unchanged.

Before publishing a build prefix, the builder checks all input hashes, archive
architectures and implementation symbols, iOS platform/minimum deployment
metadata, and an all-object link against SDK libraries. Cached libraries, headers
and pkg-config files are hash-checked before reuse. Build sources, object files,
logs, manifests and the disposable link probe stay in `build/AVSNative/` (or the
explicit simulator work prefix). The app includes only the unified FFmpeg static
archive; the disposable dynamic link probe is never packaged.

The combined FFmpeg configuration enables `--enable-gpl` for davs2 and retains
`--enable-nonfree` for the existing AV3A reference policy. KSPlayer and its bridge
also retain their GPL-3.0 notices. These local compilation steps do not establish
public redistribution permission or clear codec patent rights. The existing AV3A
limitations in `Vendor/AV3A/UPSTREAM.md` continue to apply.

Compilation and linkage do not establish real-device playback, real-time 4K
performance, seek correctness, complete damaged-stream handling or HDR color
fidelity. 
