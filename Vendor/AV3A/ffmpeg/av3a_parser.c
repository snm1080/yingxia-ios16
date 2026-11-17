/* AV3A channel-bed framing. LGPL-2.1-or-later. */
#include <tvav3a.h>
#include "libavutil/mem.h"
#include "parser.h"
#include "parser_internal.h"

typedef struct AV3AParseContext {
    uint8_t frame[TV_AV3A_MAX_FRAME_BYTES + AV_INPUT_BUFFER_PADDING_SIZE];
    int have;
    TVAV3AHeader header;
} AV3AParseContext;

static int av3a_parse(AVCodecParserContext *s, AVCodecContext *avctx,
                       const uint8_t **out, int *out_size,
                       const uint8_t *buf, int buf_size)
{
    AV3AParseContext *p = s->priv_data;
    int consumed = 0, take;
    *out = NULL;
    *out_size = 0;
    while (consumed < buf_size) {
        if (p->have < TV_AV3A_HEADER_BYTES) {
            p->frame[p->have++] = buf[consumed++];
            if (p->have < TV_AV3A_HEADER_BYTES) continue;
        }
        if (tv_av3a_read_header(p->frame, p->have, &p->header) != 1) {
            memmove(p->frame, p->frame + 1, --p->have);
            continue;
        }
        take = FFMIN(buf_size - consumed, p->header.frame_bytes - p->have);
        memcpy(p->frame + p->have, buf + consumed, take);
        consumed += take;
        p->have += take;
        if (p->have == p->header.frame_bytes) {
            memset(p->frame + p->have, 0, AV_INPUT_BUFFER_PADDING_SIZE);
            *out = p->frame;
            *out_size = p->have;
            s->duration = TV_AV3A_FRAME_SAMPLES;
            s->key_frame = 1;
            avctx->sample_rate = p->header.sample_rate;
            avctx->bit_rate = p->header.bit_rate;
            p->have = 0;
            return consumed;
        }
    }
    return consumed;
}

const FFCodecParser ff_av3a_parser = {
    PARSER_CODEC_LIST(AV_CODEC_ID_AV3A),
    .priv_data_size = sizeof(AV3AParseContext),
    .parse = av3a_parse,
};
