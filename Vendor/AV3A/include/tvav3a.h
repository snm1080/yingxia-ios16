/* Yingxia's local integration API for the pinned AVS3A reference decoder. */
#ifndef TVAV3A_H
#define TVAV3A_H
#include <stddef.h>
#include <stdint.h>
#define TV_AV3A_HEADER_BYTES 7
#define TV_AV3A_MAX_FRAME_BYTES 12307
#define TV_AV3A_FRAME_SAMPLES 1024
typedef struct TVAV3AHeader {
    int sample_rate, channels, channel_config, bit_rate;
    int nn_type, resolution, frame_bytes;
    unsigned crc;
} TVAV3AHeader;
typedef struct TVAV3ADecoder TVAV3ADecoder;
/* 1: supported channel-bed header; 0: incomplete; -1: invalid/unsupported. */
int tv_av3a_read_header(const uint8_t *data, size_t size, TVAV3AHeader *header);
TVAV3ADecoder *tv_av3a_create(void);
void tv_av3a_free(TVAV3ADecoder **decoder);
/* Exactly one framed packet; outputs interleaved native-order signed PCM16.
 * -1 invalid/corrupt frame, -2 allocation failure, 0 success. */
int tv_av3a_decode(TVAV3ADecoder *decoder, const uint8_t *data, size_t size,
                   int16_t *pcm, size_t pcm_samples);
#endif
