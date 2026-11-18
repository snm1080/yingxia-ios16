# KSPlayer source dependency

Upstream: https://github.com/kingslay/KSPlayer
Pinned commit: `be7f60d3b94a0941c643fe8699113cfce4f08e83` (2026-10-05).
License: GPL-3.0, preserved in `LICENSE`.

This is the last source implementation before the upstream Swift 6.2 binary package migration.
The maintained Xcode 16.1 toolchain compiles this source in Swift 5 language mode for iOS 16.2.
`Package.swift` at the project root defines the build targets and exposes `KSPlayer` to the iOS app.
The project root manifest is the build definition for this source snapshot.

Local adaptations use the project's single FFmpeg 8.1.3 library through `Vendor/FFmpegKit`;
`import Libav*`/`import Libsw*` statements become `import FFmpegKit`. This avoids linking the
old FFmpeg 6 ABI alongside the existing TVMedia code. Additional FFmpeg 8 adaptations use explicit SwsContext pointers and SwsFlags raw values,
remove avcodec_close (context free closes it), and import HDR metadata through the C umbrella.
The C VPCC declaration matches FFmpeg 8's const parameter signature.

Local extension KSOptions.onVideoDecoderChanged reports actual VideoToolbox/FFmpeg decoder paths;
FFmpeg frames refine software versus VideoToolbox-backed output. KSMEPlayer exposes playbackCommand
and seekCommand so system PiP actions use the application's serialized playback controls.

---

## Official source landed (2026-11-18)

lmentor published the modified KSPlayer source on branch `iOS16.2-NoJava`
(commit `ec9c0e3`「补全 KSPlayer Sources 和 模板.js」, 2026-11-18 16:39; the
following commit `113a64b` only fixes .gitignore and does not touch KSPlayer).
The 60-file reconstruction (kingslay/KSPlayer `be7f60d` base, local FFmpeg 8
adaptations, three extension APIs recreated from App call sites) was replaced
wholesale by the author's own 74 files under `Sources/` (71 Swift +
DisplayCriteria.m/.h + Shaders.metal; the author's LICENSE is identical to the
one already vendored). The three extension APIs and the FFmpeg 8 adaptations
above are the author's own in this tree; the 14 files the reconstruction
lacked (Dolby Vision pipeline, MEPlaybackSource/PlaybackInputIO, playback
clock/cadence, Metal gating, ASSAnimation) are present. Official source wins
any conflict.

