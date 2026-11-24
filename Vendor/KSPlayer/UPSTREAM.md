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


---

## build06 stability pack synced (2026-11-23, our build 24)

lmentor's build06 snapshot (branch `iOS16.2-NoJava`, published 2026-11-23)
replaced 14 KSPlayer files and added `MEPlaybackReadState.swift` and
`PlaybackCacheTimeline.swift`: `KSMEPlayer.replaceUrl` defers activation until
the retiring source fully closes, the new read-state class makes reader
wait/resume/seek/close mutex-correct, and `KSOptions` gains a 32 MB
packet-queue soft cap (`maxBufferSize`), an explicit live-streaming flag, an
audio-frame-count floor of 2, and GOP-safe video clock sync. Synced wholesale
under `Sources/`; nothing outside `Vendor/KSPlayer` changed.

The one local deviation is unchanged and was re-applied on top of the synced
`KSMEPlayer.swift`: the `audioRouteChange` headphone fix (build 6, 2026-11-18)
— when `playbackState == .playing`, `KSOptions.activateAudioSession()` +
`audioOutput.play()` after `audioOutput.flush()`. Upstream's version of the
function is still stock (format update + flush only), so this block must be
re-applied after every future Vendor sync.

---

## Second local deviation: VT fallback decoder (2026-11-23, our build 25)

File: `Sources/KSPlayer/MEPlayer/MEPlayerItemTrack.swift`, in the
decoder-failure replacement inside `SyncPlayerItemTrack`. Upstream (build06)
constructs the replacement FFmpeg decoder with `hardwareDecode: false`, so a
native VideoToolbox failure disables VideoToolbox for the replacement too.
Our version omits that argument, restoring build 23's fallback semantics: the
replacement inherits `options` and may use VideoToolbox hwaccel. Why: on the
user's A12/iOS 16.6 the native VT decoder can trip on streams that FFmpeg's
VT hwaccel handles fine, and build 23's behavior was proven on-device; build
24 (with upstream's `hardwareDecode: false`) fell back to permanent software
decode instead, driving CPU to ~99% on 4K60. Approved by Sam, 2026-11-23.
This deviation must be re-applied after every future Vendor sync.

---

## Third local deviation: P5 swallowed-packet fail-fast guard (2026-11-24, our build 29)

File: `Sources/KSPlayer/MEPlayer/VideoToolboxDecode.swift`. Upstream's
`VideoToolboxDecode.decodeFrame` has two paths that consume a packet without
ever calling its completion handler: the async output callback returns
silently on `.frameDropped`, and a synchronous
`kVTInvalidSessionErr`/`kVTVideoDecoderMalfunctionErr` on a non-keyframe only
sets `needReconfig` (the next packet then pays a full session recreate plus a
blocking drain, indefinitely). With no completion, neither a frame nor a
failure reaches the track, so the reader keeps demuxing into the packet queue
until the process dies. On-device evidence (build 26 diagnostics export,
2026-11-23): a Dolby Vision Profile 5 title's recovery reopen created a VT
session, produced exactly one frame (the seek target), then logged nothing
again; the process was jetsammed ≤20 s later at a 1518 MB footprint. Our
version counts consecutive swallowed packets on both paths, resets the count
on any completed frame, and on crossing 120 (~2 s at 60 fps, ~5 s at 24 fps —
a healthy session completes frames continuously, and any recoverable stream
completes a frame within one GOP) completes the current packet with
`.failure` through the same completion handler, landing on the existing
terminal path (track `.failed` → the DV error surface for
`requiresNativeDolbyVision` tracks). This deviation must be re-applied after
every future Vendor sync.
