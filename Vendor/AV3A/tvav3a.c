/* Local iOS adapter. Reference decoder notices are retained in reference/. */
#include "tvav3a.h"
#include <stdlib.h>
#include <string.h>
#include "avs3_stat_dec.h"
#include "avs3_prot_com.h"
#include "avs3_prot_dec.h"
#include "avs3_rom_com.h"

struct TVAV3ADecoder { AVS3DecoderHandle native; TVAV3AHeader config; };

static unsigned read_bits(const uint8_t *data, unsigned *offset, unsigned bits)
{
    unsigned value = 0;
    while (bits--) {
        value = (value << 1) | ((data[*offset / 8] >> (7 - *offset % 8)) & 1);
        ++*offset;
    }
    return value;
}

int tv_av3a_read_header(const uint8_t *data, size_t size, TVAV3AHeader *h)
{
    static const int channels[] = {1, 2, 6, 8, 0, 0, 4, 8, 10, 10, 12};
    unsigned bit = 0, fs, rate;
    int payload_bits;
    if (!data || !h) return -1;
    if (size < TV_AV3A_HEADER_BYTES) return 0;
    memset(h, 0, sizeof(*h));
    if (read_bits(data, &bit, 12) != 0xfff || read_bits(data, &bit, 4) != 2 ||
        read_bits(data, &bit, 1) != 0) return -1;
    h->nn_type = read_bits(data, &bit, 3);
    /* Channel beds only: object rendering and HOA require a separate renderer. */
    if (h->nn_type > 1 || read_bits(data, &bit, 3) != 0) return -1;
    fs = read_bits(data, &bit, 4);
    if (fs >= AVS3_SIZE_FS_TABLE) return -1;
    h->sample_rate = (int)avs3SamplingRateTable[fs];
    h->crc = read_bits(data, &bit, 8) << 8;
    h->channel_config = read_bits(data, &bit, 7);
    if ((unsigned)h->channel_config >= sizeof(channels) / sizeof(channels[0]) ||
        !(h->channels = channels[h->channel_config])) return -1;
    h->resolution = read_bits(data, &bit, 2);
    rate = read_bits(data, &bit, 4);
    h->crc |= read_bits(data, &bit, 8);
    if (h->resolution > 2) return -1;
    h->bit_rate = (int)codecBitrateConfigTable[h->channel_config].bitrateTable[rate];
    if (h->bit_rate <= 0) return -1;
    /* Use the reference decoder's exact float truncation rule. */
    payload_bits = (int)(((float)h->bit_rate / h->sample_rate) * TV_AV3A_FRAME_SAMPLES) - 56;
    h->frame_bytes = TV_AV3A_HEADER_BYTES + (payload_bits + 7) / 8;
    if (payload_bits <= 0 || h->frame_bytes > TV_AV3A_MAX_FRAME_BYTES) return -1;
    return 1;
}

TVAV3ADecoder *tv_av3a_create(void) { return calloc(1, sizeof(TVAV3ADecoder)); }

void tv_av3a_free(TVAV3ADecoder **decoder)
{
    if (!decoder || !*decoder) return;
    if ((*decoder)->native) Avs3DecoderDestroy((*decoder)->native);
    free(*decoder);
    *decoder = NULL;
}

int tv_av3a_decode(TVAV3ADecoder *d, const uint8_t *data, size_t size,
                   int16_t *pcm, size_t pcm_samples)
{
    TVAV3AHeader h;
    uint16_t crc;
    if (!d || !pcm || tv_av3a_read_header(data, size, &h) != 1 ||
        size != (size_t)h.frame_bytes ||
        pcm_samples < (size_t)h.channels * TV_AV3A_FRAME_SAMPLES) return -1;
    if (Crc16((uint8_t *)data + TV_AV3A_HEADER_BYTES,
              h.frame_bytes - TV_AV3A_HEADER_BYTES) != h.crc) return -1;
    if (d->native && (h.sample_rate != d->config.sample_rate ||
        h.channel_config != d->config.channel_config || h.nn_type != d->config.nn_type ||
        h.bit_rate != d->config.bit_rate || h.resolution != d->config.resolution)) {
        Avs3DecoderDestroy(d->native);
        d->native = NULL;
    }
    if (!d->native) {
        d->native = calloc(1, sizeof(AVS3Decoder));
        if (!d->native) return -2;
        if (Avs3ParseBsFrameHeader(d->native, (uint8_t *)data, 1, NULL) != AVS3_TRUE)
            return -1;
        Avs3InitDecoder(d->native, &d->native->fModel, NULL);
        d->config = h;
    }
    if (Avs3ParseBsFrameHeader(d->native, (uint8_t *)data, 0, &crc) != AVS3_TRUE)
        return -1;
    memcpy(d->native->hBitstream->bitstream, data + TV_AV3A_HEADER_BYTES,
           h.frame_bytes - TV_AV3A_HEADER_BYTES);
    Avs3Decode(d->native, pcm);
    ResetBitstream(d->native->hBitstream);
    return 0;
}
