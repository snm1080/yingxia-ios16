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

---

## Fourth local deviation: Dolby Vision Profile 5 FFmpeg route + GPU colour stage (2026-11-26, our build 42)

The native 'dvhe' VideoToolbox session wedges after one frame for Profile 5
on iPadOS 16 / A12 (the failure the third deviation guards against), so
build 42 stops sending P5 to the native decoder at all — the split
mpv/SenPlayer use (FFmpeg videotoolbox hwaccel for the base layer, GPU
shaders for the RPU):

- `Sources/KSPlayer/MEPlayer/MEPlayerItemTrack.swift` (`makeDecode`):
  tracks with `dovi.dv_profile == 5` return `FFmpegDecode` before the
  native branches. P7->P8.1 converted tracks keep the native route; all
  non-P5 behaviour is unchanged. The third deviation's 120-packet guard
  stays in `VideoToolboxDecode` as the last-resort net for that route.
- `Sources/KSPlayer/MEPlayer/MEPlayerItemTrack.swift`
  (`makePacketQueue`): the packet queue is hard-bounded (1024 packets,
  `expanding: false`) so a wedged decoder can no longer flood memory.
- `Sources/KSPlayer/MEPlayer/FFmpegDecode.swift`: (a) 120 consecutive
  frame-less video packets arm a decoder-level codec-context rebuild,
  resuming at the next keyframe, instead of relying on the app-level
  reopen; (b) `AV_FRAME_DATA_DOVI_METADATA` side data is parsed into
  `DolbyVisionFrameMetadata` and attached to the produced
  `VideoVTBFrame` (`Sources/KSPlayer/MEPlayer/Model.swift`) instead of
  being read and discarded.
- `Sources/KSPlayer/Metal/DolbyVisionColor.swift` (new),
  `Sources/KSPlayer/Metal/Shaders.metal` (`displayDolbyVisionTexture`),
  `Sources/KSPlayer/Metal/MetalRender.swift`,
  `Sources/KSPlayer/MEPlayer/MetalPlayView.swift`: frames carrying parsed
  RPU metadata bypass the sample-buffer display layer and render through
  a dedicated Metal pipeline performing RPU reshaping (polynomial + MMR)
  -> ycc_to_rgb (PQ domain) -> PQ EOTF -> LMS matrix -> BT.2390 tone
  mapping to 100 nits -> BT.2020->BT.709 -> sRGB. The layer is forced to
  sRGB with EDR off for these frames. HDR10/HLG/SDR frames are untouched.
  Approximations vs libplacebo: source peak comes from the RPU color
  metadata (not per-frame L1 ext blocks), and libplacebo's BT.2446a /
  gamut-desaturation refinements are not ported; the EOTF->matrix round
  trip is composed directly in linear light.
- `Sources/KSPlayer/AVPlayer/KSOptions.swift`: adds
  `onPlaybackDiagnostic`, a free-form diagnostic channel the app forwards
  into its diagnostics log (DV routing, hwaccel format, RPU presence,
  rebuild events).
- Build 43 (2026-11-26) extends this deviation with diagnostics only,
  after the build-42 colour stage produced a black picture on device
  while the decode route itself verified healthy: `KSOptions` adds
  `dolbyVisionColorStageEnabled` (set by the app from its player
  settings; false drops the parsed metadata at the `MetalPlayView`
  hand-off so P5 frames render through the legacy shader path, base
  layer only), and `FFmpegDecode` emits one-shot `dv rpu-dump`
  (parsed RPU value ranges via `DolbyVisionFrameMetadata.diagnosticSummary`)
  and `dv frame-dump` (decoded-plane sample min/max) lines per session.
- Build 44 (2026-11-27) fixes the black picture the build-43 dumps
  localized: the decoded BL and the parsed RPU were both healthy
  (frame-dump luma [57,824]/[65,1017], sane pivots/coefficients), and
  the legacy bypass rendered the same frames fine, leaving the colour
  stage itself. In `Shaders.metal`, `doviPQToLinear` raised the PQ
  signal to m1 (2610/16384) — the inverse-EOTF exponent — where the
  ST 2084 EOTF's first step is 1/m2 (32/2523), as the file's own
  `shaderLinearize` already did; the wrong exponent maps the whole
  real picture range to ~1e-6..1e-10 linear, i.e. black. One constant
  corrected. Build 44 also adds a one-shot `dv out-dump` (per drawable
  geometry): `MetalRender` re-renders the first Dolby frame of a
  session into a shared offscreen texture and logs its RGB min/max,
  splitting shader-math faults from presentation faults in the export.
- Build 45 (2026-11-27) hardens two things build 44's on-device test
  exposed. (1) The `dv out-dump` readback itself crashed the app
  twice: EXC_BREAKPOINT in swift_slowAlloc via
  _ContiguousArrayBuffer.init on the Metal completion-dispatch
  thread — `dolbyOutputStats` allocated a full-frame [UInt8] sized
  from the texture's live dimensions inside the command-buffer
  completion handler. It now validates width/height/format against
  hard caps before allocating, reads back one sampled row at a time
  into a single ≤32 KB row buffer, and scans with scalar
  accumulators: no data-dependent allocation is reachable from the
  handler, and the reported ranges are unchanged. (2) Some files
  died with `KSPlayerErrorDomain:13 / KSPlayer.NativeCodec:-1313558101`
  — that code is FFmpeg's AVERROR_UNKNOWN (FFERRTAG 'UNKN'), which
  FFmpeg 8.1's videotoolbox hwaccel returns for every
  VTDecompressionSessionDecodeFrame failure (bad data / malfunction /
  invalid session; the raw OSStatus never reaches Swift). It fired
  within the first GOP after a start/seek, deterministically at the
  same position across wholesale app-level retries. `FFmpegDecode`
  now absorbs AVERROR_UNKNOWN on VT-backed video contexts
  (`hw_device_ctx != nil`) into the build-42 rebuild machinery:
  drop to the next keyframe, recreate the codec context + VT
  session, resume — at most 4 times per decoder instance, logged as
  `decoder rebuild reason=native-codec-error count=N`; past the
  budget the error surfaces exactly as before. Software decode,
  audio, and the user-facing error mapping are untouched.
- Build 46 (2026-11-27) fixes build 45's absorption, which never
  fired once on device, and adds the witness that proves it.
  Forensics, from the code and Sam's build-45 diagnostics export
  (5,644 lines; the error appears 72 times in the E005 pattern
  family, with zero `decoder rebuild` lines anywhere):
  * Where the surfaced error is built: `KSPlayerErrorDomain:13` is
    `KSPlayerErrorCode.codecVideoReceiveFrame` (PlayerDefines.swift,
    13th case), and the `KSPlayer.NativeCodec:<code>` underlying
    error is wrapped from the decode completion's `AVError` in
    `MEPlayerItemTrack.doDecode`'s failure path. The only sites in
    the player that construct that error pair are
    `FFmpegDecode.decodeFrame`'s send-packet failure
    (FFmpegDecode.swift, `avcodec_send_packet`) and receive-frame
    failure (`avcodec_receive_frame`) — exhaustive check:
    `VideoToolboxDecode` wraps OSStatus codes instead (the export
    shows its -12909 as a separate line), `DolbyVisionLayerProbe`
    is software-only and swallows all errors, the resample/filter
    completion cannot produce this pair, and `createContext`
    failures throw codes 8/10, never 13. So build 45's hook WAS
    consulted at both of its sites and returned false.
  * Why it returned false: the error-code and media-type conditions
    provably matched (the vendored shim defines
    `swift_AVERROR_UNKNOWN = AVERROR_UNKNOWN` = -1313558101, and
    code 13 is chosen only for the non-audio — video — track). The
    failing condition was the third: `codecContext.hw_device_ctx`.
    That field is assigned exactly once, inside the `get_format`
    callback in AVFFmpegExtension.swift, and was read nowhere else
    in the codebase; decoding runs frame-threaded
    (`decoderOptions["threads"] = "auto"` in KSOptions), and the
    export gives the counterfactual — build-45 sessions that had
    just produced `AV_PIX_FMT_VIDEOTOOLBOX` frames through the
    same decoder instance (`dv ffmpeg format=videotoolbox` +
    `dv frame-dump` lines) failed after a seek with the error
    still unabsorbed, repeatedly. Reading the field back is not a
    reliable witness of VT activity under FFmpeg 8.1.
  * Fix: the gate now uses state the decoder records itself —
    `vtBackedVideoContext`, snapshotted in init from the exact
    condition `createContext` uses to install the get_format
    callback (video + hardware decode requested), and latched on
    when a VideoToolbox-format frame is produced. The
    `hw_device_ctx` read is gone. Every AVERROR_UNKNOWN sighting
    at either call site first emits a witness line,
    `dv nativecodec seen site=send-packet|receive-frame
    absorbed=yes|no reason=vt-session-failure|not-vt-backed|
    budget-exhausted|not-video code=-1313558101`, before the
    caller acts on the decision, so the next export proves
    coverage either way. Absorption mechanics, the budget of 4,
    and all build-42/43/44/45 diagnostics are unchanged; software
    decode and audio still surface the error exactly as before.
- Build 47 (2026-11-27) fixes the rebuild's effectiveness, which
  Sam's build-46 diagnostics export (E005 window, 98 witness
  lines) isolated: detection was proven (81 absorptions), but at
  a poisoned stream position every rebuilt context re-failed at
  send-packet within a packet or two — 4 clusters of 15–35
  sightings each burned the whole per-instance budget of 4 on
  rebuilds that produced zero frames, surfaced the error, and
  the app-level reopen repeated the identical cycle (position
  stuck at 227–233 s across 4 instances). The export's two
  isolated incidents were each cured by a single rebuild and
  played on, so the machinery was right for spots and wrong for
  regions. Code forensics for the three candidate mechanisms:
  * Budget burn in the pending window (sightings between arming
    and the rebuild landing): does not occur — the drop guard at
    the top of `decodeFrame` returns every packet before
    send/receive while `awaitingRebuildKeyFrame` is set, and the
    export's clusters interleave exactly one rebuild execution
    per absorption. `shouldRebuildForNativeCodecError` still
    gained a defensive pending branch (absorbed without budget,
    witnessed once per window as `absorbed=pending
    reason=rebuild-pending`) so the invariant holds by
    construction.
  * Rebuild re-poisoning: the rebuilt context is configured
    identically to the original (`createContext`:
    parameters-to-context from codecpar extradata + the same
    get_format install + open2, for init and rebuild alike), and
    the failed packet is dropped, never retried — the first
    packet a rebuilt context receives is the resume keyframe, a
    different packet from the one that failed. What does not
    change is the input region: dropping exactly one GOP per
    rebuild cannot cross a region that is hostile for several
    GOPs.
  * The real OSStatus: FFmpeg 8.1's videotoolbox hwaccel
    (`ff_videotoolbox_common_end_frame`, release/8.1 source)
    returns AVERROR_UNKNOWN both when
    VTDecompressionSessionDecodeFrame fails — logging
    `Failed to decode frame (<name>, <status>)` at error level
    first, and flagging its own internal session restart for
    malfunction/invalid-session — and when the output callback
    delivers no image buffer, which the callback itself logs at
    warning level (`vt decoder cb: output image buffer is null:
    <status>, reconfig <0|1>`). The status is reachable only
    through av_log; KSPlayer's callback in `MEPlayerItem.swift`
    now scrapes those two lines (bypassing the log-level guard
    like the existing parser-missing case) into
    `VTDecodeFailureLog` (FFmpegDecode.swift), and the witness
    line consumes it as a `vtstatus=` suffix.
  Fix (`FFmpegDecode.swift`): consecutive-failure escalation
  plus per-session budget. A native-codec absorption whose
  outgoing context produced < 30 frame-producing packets since
  it was created counts as the same incident: the frameless
  streak advances and the armed rebuild drops extra whole GOPs
  before resuming (skip ladder 0, 1, 2, 4 extra keyframes), so
  the budget of 4 spans ~11 GOPs. A context that sustains 30
  frame-producing packets restores the budget and clears the
  streak (`dv nativecodec budget restored frames=30`) — the
  budget is per genuinely-rebuilt session, so isolated
  incidents scattered across a long session no longer
  accumulate toward a false exhaustion, while a poisoned
  region still exhausts and surfaces the error to the
  app-level badspot ladder as before. The arm diagnostic line
  gains `skipgops=`; all build 42–46 diagnostic lines are
  otherwise unchanged, and the starved rebuild path, software
  decode and audio are untouched. Seek resets
  (doFlushCodec/decode) clear the pending skip, streak and
  proof counter along with the existing flags.

This deviation must be re-applied after every future Vendor sync.
