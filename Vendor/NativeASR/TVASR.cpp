#include "include/TVASR.h"
#include "TVASRRunOptions.h"
#include "sherpa-onnx/c-api/c-api.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

struct TVASRCancellation {
    std::atomic<bool> cancelled{false};
    Ort::RunOptions options;
};
namespace {
thread_local TVASRCancellation *current_cancel = nullptr;
struct Operation {
    TVASRCancellation *previous;
    explicit Operation(TVASRCancellation *token) : previous(current_cancel) { current_cancel = token; }
    ~Operation() { current_cancel = previous; }
};
void Check(TVASRCancellation *token) {
    if (token && token->cancelled.load()) throw std::runtime_error("cancelled");
}
void Error(char **error, const char *message) { if (error) *error = strdup(message ? message : "Native inference failed"); }
bool Equal(const char *a, const char *b) { return a && strcmp(a, b) == 0; }
double SegmentStart(const char *json) {
    // sherpa 1.13.4 exposes the consumed-feature-frame origin as start_time in
    // result JSON. Reset preserves unread feature frames, so accepted PCM length
    // must never be accumulated as the next segment's origin.
    if (!json) throw std::runtime_error("Missing stream timestamp");
    const char *field = strstr(json, "\"start_time\"");
    const char *colon = field ? strchr(field, ':') : nullptr;
    if (!colon) throw std::runtime_error("Missing stream timestamp");
    char *end = nullptr; const double value = strtod(colon + 1, &end);
    if (end == colon + 1 || !std::isfinite(value) || value < 0) throw std::runtime_error("Invalid stream timestamp");
    return value - 0.3;
}
template <class T, void (*Destroy)(const T *)> using Owned = std::unique_ptr<const T, decltype(Destroy)>;
struct Segment {
    std::string text;
    double start = 0, end = 0;
    std::vector<std::string> tokens;
    std::vector<double> timestamps;
};
}

const Ort::RunOptions &TVASRCurrentRunOptions() {
    Check(current_cancel);
    if (!current_cancel) throw std::runtime_error("Missing inference cancellation scope");
    return current_cancel->options;
}

struct TVASRRecognizer {
    const SherpaOnnxOnlineRecognizer *online = nullptr;
    const SherpaOnnxOfflineRecognizer *offline = nullptr;
    const SherpaOnnxVoiceActivityDetector *vad = nullptr;
    ~TVASRRecognizer() {
        if (online) SherpaOnnxDestroyOnlineRecognizer(online);
        if (offline) SherpaOnnxDestroyOfflineRecognizer(offline);
        if (vad) SherpaOnnxDestroyVoiceActivityDetector(vad);
    }
};
struct TVASRResult { std::vector<Segment> segments; };

extern "C" TVASRCancellation *tvasr_cancellation_create() {
    try { return new TVASRCancellation; } catch (...) { return nullptr; }
}
extern "C" void tvasr_cancellation_cancel(TVASRCancellation *token) {
    if (!token) return;
    token->cancelled.store(true);
    try { token->options.SetTerminate(); } catch (...) { }
}
extern "C" int32_t tvasr_cancellation_is_cancelled(const TVASRCancellation *token) { return token && token->cancelled.load(); }
extern "C" void tvasr_cancellation_destroy(TVASRCancellation *token) { delete token; }
extern "C" const char *tvasr_version() { return SherpaOnnxGetVersionStr(); }
extern "C" TVASRRecognizer *tvasr_create(const TVASRConfiguration *config, TVASRCancellation *cancel, char **error) {
    if (error) *error = nullptr;
    try {
        Operation operation(cancel); Check(cancel);
        if (!config) throw std::runtime_error("Missing model configuration");
        auto result = std::make_unique<TVASRRecognizer>();
        if (Equal(config->engine, "ONLINE_TRANSDUCER")) {
            SherpaOnnxOnlineRecognizerConfig c{};
            c.feat_config = {16000, 80};
            c.model_config.transducer = {config->encoder, config->decoder, config->joiner};
            c.model_config.tokens = config->tokens; c.model_config.model_type = config->model_type;
            c.model_config.num_threads = 2; c.model_config.provider = "cpu";
            c.decoding_method = "greedy_search";
            c.enable_endpoint = 1; c.rule1_min_trailing_silence = 2.4f;
            c.rule2_min_trailing_silence = 0.45f; c.rule3_min_utterance_length = 12.0f;
            result->online = SherpaOnnxCreateOnlineRecognizer(&c);
            if (!result->online) throw std::runtime_error("Cannot load streaming model");
        } else {
            SherpaOnnxOfflineRecognizerConfig c{};
            c.feat_config = {16000, 80}; c.model_config.tokens = config->tokens;
            c.model_config.num_threads = 2; c.model_config.provider = "cpu";
            c.decoding_method = "greedy_search";
            if (Equal(config->engine, "OFFLINE_WENET_CTC")) c.model_config.wenet_ctc.model = config->model;
            else if (Equal(config->engine, "OFFLINE_MOONSHINE")) {
                c.model_config.moonshine.encoder = config->encoder;
                c.model_config.moonshine.merged_decoder = config->decoder;
            } else throw std::runtime_error("Unsupported model engine");
            result->offline = SherpaOnnxCreateOfflineRecognizer(&c);
            if (!result->offline) throw std::runtime_error("Cannot load offline model");
            Check(cancel);
            SherpaOnnxVadModelConfig v{};
            v.silero_vad.model = config->vad; v.silero_vad.threshold = 0.5f;
            v.silero_vad.min_silence_duration = 0.4f; v.silero_vad.min_speech_duration = 0.25f;
            v.silero_vad.max_speech_duration = 10.0f; v.silero_vad.window_size = 512;
            v.sample_rate = 16000; v.num_threads = 1; v.provider = "cpu";
            result->vad = SherpaOnnxCreateVoiceActivityDetector(&v, 25.0f);
            if (!result->vad) throw std::runtime_error("Cannot load voice activity model");
        }
        Check(cancel); return result.release();
    } catch (const std::exception &e) { Error(error, e.what()); return nullptr; }
      catch (...) { Error(error, "Native model initialization failed"); return nullptr; }
}
extern "C" void tvasr_destroy(TVASRRecognizer *recognizer) { delete recognizer; }

namespace {
void Online(TVASRRecognizer *recognizer, const float *samples, int count, TVASRCancellation *cancel, TVASRResult &result) {
    Owned<SherpaOnnxOnlineStream, SherpaOnnxDestroyOnlineStream> stream(
        SherpaOnnxCreateOnlineStream(recognizer->online), SherpaOnnxDestroyOnlineStream);
    if (!stream) throw std::runtime_error("Cannot create audio stream");
    const double duration = count / 16000.0;
    int accepted = 0;
    std::vector<float> silence(12800, 0);
    SherpaOnnxOnlineStreamAcceptWaveform(stream.get(), 16000, silence.data(), 4800);
    auto emit = [&] {
        Owned<SherpaOnnxOnlineRecognizerResult, SherpaOnnxDestroyOnlineRecognizerResult> answer(
            SherpaOnnxGetOnlineStreamResult(recognizer->online, stream.get()), SherpaOnnxDestroyOnlineRecognizerResult);
        if (answer && answer->text && answer->text[0]) {
            Segment segment; segment.text = answer->text;
            segment.start = SegmentStart(answer->json);
            segment.end = std::min(duration, accepted / 16000.0);
            if (answer->count > 0 && answer->count <= 2048 && answer->tokens_arr && answer->timestamps) {
                for (int i = 0; i < answer->count; ++i) {
                    segment.tokens.emplace_back(answer->tokens_arr[i] ? answer->tokens_arr[i] : "");
                    segment.timestamps.push_back(answer->timestamps[i]);
                }
            }
            result.segments.push_back(std::move(segment));
        }
        SherpaOnnxOnlineStreamReset(recognizer->online, stream.get());
    };
    auto decode = [&] {
        while (SherpaOnnxIsOnlineStreamReady(recognizer->online, stream.get())) {
            Check(cancel); SherpaOnnxDecodeOnlineStream(recognizer->online, stream.get());
        }
    };
    for (int offset = 0; offset < count; offset += 1600) {
        Check(cancel);
        const int size = std::min(1600, count - offset);
        SherpaOnnxOnlineStreamAcceptWaveform(stream.get(), 16000, samples + offset, size); accepted += size;
        decode();
        if (SherpaOnnxOnlineStreamIsEndpoint(recognizer->online, stream.get())) emit();
    }
    Check(cancel);
    SherpaOnnxOnlineStreamAcceptWaveform(stream.get(), 16000, silence.data(), 12800);
    SherpaOnnxOnlineStreamInputFinished(stream.get()); decode(); emit();
}
void Offline(TVASRRecognizer *recognizer, const float *samples, int count, TVASRCancellation *cancel, TVASRResult &result) {
    SherpaOnnxVoiceActivityDetectorReset(recognizer->vad);
    auto emit = [&] {
        while (!SherpaOnnxVoiceActivityDetectorEmpty(recognizer->vad)) {
            Check(cancel);
            Owned<SherpaOnnxSpeechSegment, SherpaOnnxDestroySpeechSegment> speech(
                SherpaOnnxVoiceActivityDetectorFront(recognizer->vad), SherpaOnnxDestroySpeechSegment);
            if (!speech) throw std::runtime_error("Cannot read voice activity segment");
            Owned<SherpaOnnxOfflineStream, SherpaOnnxDestroyOfflineStream> stream(
                SherpaOnnxCreateOfflineStream(recognizer->offline), SherpaOnnxDestroyOfflineStream);
            if (!stream) throw std::runtime_error("Cannot create audio stream");
            SherpaOnnxAcceptWaveformOffline(stream.get(), 16000, speech->samples, speech->n);
            SherpaOnnxDecodeOfflineStream(recognizer->offline, stream.get()); Check(cancel);
            Owned<SherpaOnnxOfflineRecognizerResult, SherpaOnnxDestroyOfflineRecognizerResult> answer(
                SherpaOnnxGetOfflineStreamResult(stream.get()), SherpaOnnxDestroyOfflineRecognizerResult);
            if (answer && answer->text && answer->text[0]) {
                Segment segment; segment.text = answer->text;
                segment.start = std::max(0.0, speech->start / 16000.0);
                segment.end = std::min(count / 16000.0, (speech->start + speech->n) / 16000.0);
                if (segment.end > segment.start) result.segments.push_back(std::move(segment));
            }
            SherpaOnnxVoiceActivityDetectorPop(recognizer->vad);
        }
    };
    for (int offset = 0; offset < count; offset += 512) {
        Check(cancel);
        const int size = std::min(512, count - offset);
        if (size == 512) SherpaOnnxVoiceActivityDetectorAcceptWaveform(recognizer->vad, samples + offset, size);
        else {
            float tail[512]{}; std::copy_n(samples + offset, size, tail);
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(recognizer->vad, tail, 512);
        }
        emit();
    }
    SherpaOnnxVoiceActivityDetectorFlush(recognizer->vad); emit();
}
}
extern "C" int32_t tvasr_transcribe(TVASRRecognizer *recognizer, const float *samples, int32_t count,
                                    TVASRCancellation *cancel, TVASRResult **result, char **error) {
    if (result) *result = nullptr;
    if (error) *error = nullptr;
    try {
        Operation operation(cancel); Check(cancel);
        if (!recognizer || !result || !samples || count <= 0 || count > 20 * 16000) throw std::runtime_error("Invalid audio");
        auto output = std::make_unique<TVASRResult>();
        if (recognizer->online) Online(recognizer, samples, count, cancel, *output);
        else if (recognizer->offline && recognizer->vad) Offline(recognizer, samples, count, cancel, *output);
        else throw std::runtime_error("Recognizer is not initialized");
        Check(cancel); *result = output.release(); return 0;
    } catch (const std::exception &e) { Error(error, e.what()); return tvasr_cancellation_is_cancelled(cancel) ? -2 : -1; }
      catch (...) { Error(error, "Native inference failed"); return -1; }
}
extern "C" int32_t tvasr_result_count(const TVASRResult *r) { return r ? static_cast<int32_t>(r->segments.size()) : 0; }
static const Segment *Get(const TVASRResult *r, int32_t i) { return r && i >= 0 && i < tvasr_result_count(r) ? &r->segments[i] : nullptr; }
extern "C" const char *tvasr_result_text(const TVASRResult *r, int32_t i) { auto s = Get(r, i); return s ? s->text.c_str() : ""; }
extern "C" double tvasr_result_start(const TVASRResult *r, int32_t i) { auto s = Get(r, i); return s ? s->start : 0; }
extern "C" double tvasr_result_end(const TVASRResult *r, int32_t i) { auto s = Get(r, i); return s ? s->end : 0; }
extern "C" int32_t tvasr_result_token_count(const TVASRResult *r, int32_t i) { auto s = Get(r, i); return s ? static_cast<int32_t>(s->tokens.size()) : 0; }
extern "C" const char *tvasr_result_token(const TVASRResult *r, int32_t i, int32_t t) { auto s = Get(r, i); return s && t >= 0 && t < s->tokens.size() ? s->tokens[t].c_str() : ""; }
extern "C" double tvasr_result_timestamp(const TVASRResult *r, int32_t i, int32_t t) { auto s = Get(r, i); return s && t >= 0 && t < s->timestamps.size() ? s->timestamps[t] : 0; }
extern "C" void tvasr_result_destroy(TVASRResult *result) { delete result; }
extern "C" void tvasr_error_destroy(char *error) { free(error); }
