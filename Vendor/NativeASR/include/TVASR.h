#ifndef TVASR_H
#define TVASR_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct TVASRCancellation TVASRCancellation;
typedef struct TVASRRecognizer TVASRRecognizer;
typedef struct TVASRResult TVASRResult;

// Cancellation belongs to one operation; never reuse it after cancellation.
TVASRCancellation *tvasr_cancellation_create(void);
void tvasr_cancellation_cancel(TVASRCancellation *token);
int32_t tvasr_cancellation_is_cancelled(const TVASRCancellation *token);
void tvasr_cancellation_destroy(TVASRCancellation *token);

typedef struct {
    const char *engine;
    const char *model_type;
    const char *tokens;
    const char *encoder;
    const char *decoder;
    const char *joiner;
    const char *model;
    const char *vad;
} TVASRConfiguration;

// Must run on the serial inference queue. Only cancellation is callable concurrently.
TVASRRecognizer *tvasr_create(const TVASRConfiguration *config, TVASRCancellation *cancel, char **error);
void tvasr_destroy(TVASRRecognizer *recognizer);
// PCM is mono, 16 kHz, normalized float. At most 20 seconds, already extracted by FFmpeg.
int32_t tvasr_transcribe(TVASRRecognizer *recognizer, const float *samples, int32_t count,
                        TVASRCancellation *cancel, TVASRResult **result, char **error);
int32_t tvasr_result_count(const TVASRResult *result);
const char *tvasr_result_text(const TVASRResult *result, int32_t index);
double tvasr_result_start(const TVASRResult *result, int32_t index);
double tvasr_result_end(const TVASRResult *result, int32_t index);
int32_t tvasr_result_token_count(const TVASRResult *result, int32_t index);
const char *tvasr_result_token(const TVASRResult *result, int32_t index, int32_t token);
double tvasr_result_timestamp(const TVASRResult *result, int32_t index, int32_t token);
void tvasr_result_destroy(TVASRResult *result);
void tvasr_error_destroy(char *error);
const char *tvasr_version(void);
#ifdef __cplusplus
}
#endif
#endif
