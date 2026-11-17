#ifndef TV_DOLBY_H
#define TV_DOLBY_H

#include <stddef.h>
#include <stdint.h>

typedef struct TVDolbyConverter TVDolbyConverter;

/* One instance belongs to one reader/seek generation; calls are serialized. */
TVDolbyConverter *tv_dolby_converter_create(void);
/* Input/output are full type-62 HEVC NALs, without Annex B or length fields.
 * Output is av_malloc-owned, freed by av_free. Negative return is an error. */
int tv_dolby_convert_p7_to_p81(TVDolbyConverter *converter, const uint8_t *nal,
                             size_t size, uint8_t **output, size_t *output_size);
void tv_dolby_converter_flush(TVDolbyConverter *converter);
void tv_dolby_converter_free(TVDolbyConverter **converter);

#endif
