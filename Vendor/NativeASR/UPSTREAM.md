# Native offline speech dependency

This local iOS edition uses the same sherpa-onnx 1.13.4 and model manifest as the
read-only MacCat reference. No model is bundled with the application. Users
download individual model packages in AI subtitle settings.

`SOURCE-INVENTORY.json` records exact URLs, sizes and SHA-256 digests of all
prepared inputs. The upload package records these inputs without bundling their archives.
`Scripts/fetch-vendor-dependencies.py` restores them into ignored `sources/`.

- sherpa-onnx v1.13.4, official `ios-no-tts.tar.bz2` release: Apache-2.0.
  https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.4
- ONNX Runtime 1.27.0 iOS static framework, contained in that release: MIT.
  Its complete ThirdPartyNotices is included in `licenses/` and app resources.
- OpenFst 1.8.5-2026-04-11, kaldifst 1.8.0, kaldi-decoder 0.3.0,
  kaldi-native-fbank 1.22.3, simple-sentencepiece 0.7: Apache-2.0.
- Eigen 5.0.1: MPL-2.0/BSD notices included, headers used without source changes.
- nlohmann/json 3.12.0: MIT; cargs 1.0.3: MIT; KissFFT: BSD-3-Clause/Unlicense.
  These dependencies are incorporated in the upstream no-TTS static archive.

`Scripts/prepare-ios-asr.py` works offline using the pinned archives. It selects
only iPhoneOS arm64 and compiles the app bridge and five model implementation
objects with `arm64-apple-ios16.2` using the maintained Xcode compiler. Model
objects are rebuilt to replace empty `Ort::RunOptions` arguments with
`TVASRCurrentRunOptions()`. The script checks the expected number of call sites
and records original/patched/object hashes. Cancellation calls the actual ONNX
Runtime `RunOptionsSetTerminate` operation through `Ort::RunOptions::SetTerminate`.
This interrupts graph execution; there is also cancellation between decode chunks.
The C++ bridge catches inference exceptions and Swift releases the affected model.

No model layouts, weights, token tables or decoding algorithm are rewritten.
The public sherpa C ABI remains unchanged. CoreML is linked because the official
archive contains its provider; the app explicitly selects `cpu` and two inference
threads. All inference runs on one utility queue with at most one loaded model.
Each bounded sampled audio window has fresh decoder state, 0.3 s synthetic
pre-roll for streaming transducers and final flush; VAD handles the two offline
families. Endpoint origins come from sherpa's consumed-feature `start_time`,
not the number of accepted samples (which includes unread lookahead frames).
The app's existing generation/audio/seek identity prevents old results
from returning to playback.

The upstream sherpa objects have minimum iOS 13.0 and ONNX Runtime iOS 15.1;
rebuilt model/bridge objects and the app have minimum iOS 16.2. The output
`build/NativeASR/TVASR.xcframework` contains only iPhoneOS arm64. The Vendor link
is relative and disposable output remains under `build/`. The IPA build links Accelerate/CoreML/Foundation
and checks the resulting native symbols and deployment metadata. Preparation requires neither
CMake nor a host application build.

App resources include `local-asr-models.json` (byte-identical to MacCat's catalog)
and `NativeASR-Licenses.txt` (engine, dependency and available model notices).
`MODEL-LICENSES.json` records model evidence separately from engine licensing:

- Mandarin, English and bilingual Zipformer model cards declare Apache-2.0.
- The Cantonese conversion README links ASLP-lab/WSYue-ASR, whose card declares
  Apache-2.0. Silero VAD is MIT.
- The Japanese model's pinned LICENSE uses Moonshine AI Community terms for
  non-English models, including commercial/revenue conditions; it is not covered
  by the English model's MIT terms.
- German/French/Spanish conversion READMEs point to Banafo/Kroko-ASR. At inspection,
  its card says `license: other`, `license_name: test` and its LICENSE file is
  empty. This local integration does not infer commercial redistribution rights.

Compiling, checking manifests and linking for iOS do not establish on-device
recognition accuracy, inference throughput, temperature or audible playback.
