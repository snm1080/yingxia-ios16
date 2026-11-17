# FFmpeg Swift C bridge

The macro/error and private-format declarations in `avutil_shim.h` and `avformat_shim.h`
come from kingslay/FFmpegKit tag 6.1.4, commit `c32be9bfb628042737ad3ef622e930c5c7b15954`:
https://github.com/kingslay/FFmpegKit/tree/6.1.4/Sources/FFmpegKit/include
Original GPL-3.0 license is preserved in `LICENSE`.

The umbrella header exports the existing project's FFmpeg C headers as one Swift module.
No prebuilt FFmpegKit framework or second copy of FFmpeg is downloaded or linked.
FFmpeg 8 removed AV_CH_LAYOUT_NATIVE; its unused Swift constant is omitted.

`TVDolby.c` implements the requested P7 FEL to single-layer P8.1 conversion.
It uses the same linked FFmpeg 8.1.3 RPU parser/generator, including CRC and
extension-block writing. The private DOVIContext header is pinned to that
version; its original SHA-256 is
`cc91857f1913e2c1d47989a77ac2eb18bec9a97b94ab386a868b8ecaae20745a`.
The only header changes replace two relative public includes with libavcodec
includes. Compile-time and runtime checks reject another libavcodec version.

The conversion semantics were checked against dovi_tool 2.3.0 `convert_to_p81`,
`convert_to_p81_remove_mapping`, `set_empty_p81_mapping` and `set_p81_coeffs`:
https://github.com/quietvoid/dovi_tool/tree/2.3.0/dolby_vision/src/rpu
The local bridge sets identity luma/chroma mapping, removes NLQ/residual use,
and writes the P8.1 matrices/offsets while keeping dynamic and static RPU
extension blocks. No dovi_tool executable, Rust runtime or second FFmpeg
library is included in the application. FFmpeg's header license is preserved.
