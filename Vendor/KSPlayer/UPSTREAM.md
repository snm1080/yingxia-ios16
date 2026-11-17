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

