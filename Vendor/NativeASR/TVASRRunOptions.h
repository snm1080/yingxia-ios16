#ifndef TVASR_RUN_OPTIONS_H
#define TVASR_RUN_OPTIONS_H
#include "onnxruntime_cxx_api.h"
// The bridge sets a thread-local operation before entering sherpa. Patched model
// objects pass this to every encoder/decoder/joiner/VAD Run; SetTerminate interrupts
// the actual ONNX graph and unwinds into the bridge's exception boundary.
const Ort::RunOptions &TVASRCurrentRunOptions();
#endif
