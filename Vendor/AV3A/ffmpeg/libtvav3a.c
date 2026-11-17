/*
 * AV3A channel-bed decoding through Yingxia's local reference decoder adapter.
 * This integration file is licensed under LGPL-2.1-or-later.
 */
#include <tvav3a.h>
#include "libavutil/channel_layout.h"
#include "avcodec.h"
#include "codec_internal.h"
#include "decode.h"

typedef struct TVAV3AContext { TVAV3ADecoder *decoder; } TVAV3AContext;

static AVChannelLayout channel_layout(int config)
{
    switch (config) {
    case 0: return (AVChannelLayout)AV_CHANNEL_LAYOUT_MONO;
    case 1: return (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
    case 2: return (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1;
    case 3: return (AVChannelLayout)AV_CHANNEL_LAYOUT_7POINT1;
    case 6: return (AVChannelLayout)AV_CHANNEL_LAYOUT_QUAD;
    case 7: return (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1POINT2;
    case 8: return (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1POINT4_BACK;
    case 9: return (AVChannelLayout)AV_CHANNEL_LAYOUT_7POINT1POINT2;
    case 10: return (AVChannelLayout)AV_CHANNEL_LAYOUT_7POINT1POINT4_BACK;
    default: return (AVChannelLayout){0};
    }
}

static av_cold int tvav3a_init(AVCodecContext *avctx)
{
    TVAV3AContext *s = avctx->priv_data;
    avctx->sample_fmt = AV_SAMPLE_FMT_S16;
    s->decoder = tv_av3a_create();
    return s->decoder ? 0 : AVERROR(ENOMEM);
}

static av_cold int tvav3a_close(AVCodecContext *avctx)
{
    TVAV3AContext *s = avctx->priv_data;
    tv_av3a_free(&s->decoder);
    return 0;
}

static void tvav3a_flush(AVCodecContext *avctx)
{
    TVAV3AContext *s = avctx->priv_data;
    tv_av3a_free(&s->decoder);
    s->decoder = tv_av3a_create();
}

static int tvav3a_decode(AVCodecContext *avctx, AVFrame *frame,
                         int *got_frame, AVPacket *packet)
{
    TVAV3AContext *s = avctx->priv_data;
    TVAV3AHeader h;
    int ret;
    *got_frame = 0;
    if (tv_av3a_read_header(packet->data, packet->size, &h) != 1 ||
        packet->size < h.frame_bytes) return AVERROR_INVALIDDATA;
    if (!s->decoder && !(s->decoder = tv_av3a_create())) return AVERROR(ENOMEM);
    av_channel_layout_uninit(&avctx->ch_layout);
    avctx->ch_layout = channel_layout(h.channel_config);
    avctx->sample_rate = h.sample_rate;
    avctx->bit_rate = h.bit_rate;
    avctx->frame_size = TV_AV3A_FRAME_SAMPLES;
    frame->nb_samples = TV_AV3A_FRAME_SAMPLES;
    ret = ff_get_buffer(avctx, frame, 0);
    if (ret < 0) return ret;
    ret = tv_av3a_decode(s->decoder, packet->data, h.frame_bytes,
                          (int16_t *)frame->data[0],
                          (size_t)h.channels * frame->nb_samples);
    if (ret < 0) return ret == -2 ? AVERROR(ENOMEM) : AVERROR_INVALIDDATA;
    *got_frame = 1;
    return h.frame_bytes;
}

const FFCodec ff_libtvav3a_decoder = {
    .p.name = "libtvav3a",
    CODEC_LONG_NAME("AVS3A reference channel-bed decoder (local edition)"),
    .p.type = AVMEDIA_TYPE_AUDIO,
    .p.id = AV_CODEC_ID_AV3A,
    .p.capabilities = AV_CODEC_CAP_CHANNEL_CONF | AV_CODEC_CAP_DR1,
    .caps_internal = FF_CODEC_CAP_INIT_CLEANUP,
    .priv_data_size = sizeof(TVAV3AContext),
    .init = tvav3a_init,
    .close = tvav3a_close,
    .flush = tvav3a_flush,
    FF_CODEC_DECODE_CB(tvav3a_decode),
};
