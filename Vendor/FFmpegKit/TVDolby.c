#include "include/TVDolby.h"
#include "private/ffmpeg_dovi_rpu_8_1.h"
#include <libavutil/mem.h>
#include <libavutil/error.h>
#include <libavcodec/version.h>
#include <errno.h>
#include <string.h>

/* Internal DOVIContext is compiled against the project's one pinned FFmpeg.
 * A dependency upgrade must review this boundary, not reuse a foreign ABI. */
#if LIBAVCODEC_VERSION_MAJOR != 62 || LIBAVCODEC_VERSION_MINOR != 28 || LIBAVCODEC_VERSION_MICRO != 103
#error "TVDolby requires pinned FFmpeg 8.1.3 / libavcodec 62.28.103"
#endif

struct TVDolbyConverter {
    DOVIContext input;
    DOVIContext output;
};

static void configure(TVDolbyConverter *converter)
{
    converter->input.cfg = (AVDOVIDecoderConfigurationRecord) {
        .dv_version_major = 1, .dv_profile = 7,
        .rpu_present_flag = 1, .el_present_flag = 1, .bl_present_flag = 1,
        .dv_md_compression = AV_DOVI_COMPRESSION_NONE,
    };
    converter->output.enable = 1;
    converter->output.cfg = (AVDOVIDecoderConfigurationRecord) {
        .dv_version_major = 1, .dv_profile = 8,
        .rpu_present_flag = 1, .el_present_flag = 0, .bl_present_flag = 1,
        .dv_bl_signal_compatibility_id = 1,
        .dv_md_compression = AV_DOVI_COMPRESSION_NONE,
    };
}

TVDolbyConverter *tv_dolby_converter_create(void)
{
    if (avcodec_version() != LIBAVCODEC_VERSION_INT)
        return NULL;
    TVDolbyConverter *converter = av_mallocz(sizeof(*converter));
    if (converter)
        configure(converter);
    return converter;
}

void tv_dolby_converter_flush(TVDolbyConverter *converter)
{
    if (!converter)
        return;
    ff_dovi_ctx_unref(&converter->input);
    ff_dovi_ctx_unref(&converter->output);
    configure(converter);
}

void tv_dolby_converter_free(TVDolbyConverter **converter)
{
    if (!converter || !*converter)
        return;
    tv_dolby_converter_flush(*converter);
    av_freep(converter);
}

static void remove_fel_mapping(AVDOVIRpuDataHeader *header, AVDOVIDataMapping *mapping)
{
    /* dovi_tool 2.3.0 mode 2: remove FEL luma/chroma reshaping and NLQ,
     * instead of keeping its profile-7 residual-dependent curves. */
    header->el_spatial_resampling_filter_flag = 0;
    header->disable_residual_flag = 1;
    mapping->nlq_method_idc = AV_DOVI_NLQ_NONE;
    mapping->num_x_partitions = 1;
    mapping->num_y_partitions = 1;
    memset(mapping->nlq, 0, sizeof(mapping->nlq));
    memset(mapping->nlq_pivots, 0, sizeof(mapping->nlq_pivots));
    for (int component = 0; component < 3; component++) {
        AVDOVIReshapingCurve *curve = &mapping->curves[component];
        memset(curve, 0, sizeof(*curve));
        curve->num_pivots = 2;
        curve->pivots[1] = 1023;
        curve->mapping_idc[0] = AV_DOVI_MAPPING_POLYNOMIAL;
        curve->poly_order[0] = 1;
        curve->poly_coef[0][1] = INT64_C(1) << header->coef_log2_denom;
    }
}

static void set_p81_color(AVDOVIColorMetadata *color)
{
    static const int ycc_to_rgb[] = {9574, 0, 13802, 9574, -1540, -5348, 9574, 17610, 0};
    static const int rgb_to_lms[] = {7222, 8771, 390, 2654, 12430, 1300, 0, 422, 15962};
    static const int offset[] = {16777216, 134217728, 134217728};
    for (int index = 0; index < 9; index++) {
        color->ycc_to_rgb_matrix[index] = (AVRational) {ycc_to_rgb[index], 1 << 13};
        color->rgb_to_lms_matrix[index] = (AVRational) {rgb_to_lms[index], 1 << 14};
    }
    for (int index = 0; index < 3; index++)
        color->ycc_to_rgb_offset[index] = (AVRational) {offset[index], 1 << 28};
    color->signal_color_space = 0;
}

int tv_dolby_convert_p7_to_p81(TVDolbyConverter *converter, const uint8_t *nal,
                             size_t size, uint8_t **output, size_t *output_size)
{
    if (output)
        *output = NULL;
    if (output_size)
        *output_size = 0;
    if (!converter || !nal || !output || !output_size || size < 7 || size > 65536 ||
        (nal[0] & 0x81) || ((nal[0] >> 1) & 0x3f) != 62 || nal[1] != 1 || nal[2] != 25)
        return AVERROR(EINVAL);

    /* Decode NAL emulation prevention before FFmpeg's RPU bit parser.
     * The type-62 header is excluded but the mandatory 0x19 prefix stays. */
    uint8_t *rbsp = av_malloc(size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!rbsp)
        return AVERROR(ENOMEM);
    size_t length = 0;
    int zeros = 0;
    for (size_t index = 2; index < size; index++) {
        uint8_t byte = nal[index];
        if (zeros == 2 && byte == 3) {
            if (index + 1 >= size || nal[index + 1] > 3) {
                av_free(rbsp);
                return AVERROR_INVALIDDATA;
            }
            zeros = 0;
            continue;
        }
        rbsp[length++] = byte;
        zeros = byte == 0 ? zeros + 1 : 0;
    }
    memset(rbsp + length, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    int result = ff_dovi_rpu_parse(&converter->input, rbsp, length, AV_EF_CRCCHECK | AV_EF_EXPLODE);
    av_free(rbsp);
    if (result < 0) {
        ff_dovi_ctx_flush(&converter->input);
        return result;
    }
    AVDOVIMetadata *metadata = NULL;
    result = ff_dovi_get_metadata(&converter->input, &metadata);
    if (result <= 0)
        return result < 0 ? result : AVERROR_INVALIDDATA;
    AVDOVIRpuDataHeader *header = av_dovi_get_header(metadata);
    AVDOVIDataMapping *mapping = av_dovi_get_mapping(metadata);
    if (header->rpu_type != 2 || header->vdr_rpu_profile != 1 || header->vdr_bit_depth != 12 ||
        header->bl_bit_depth != 10 || header->coef_log2_denom > 32 ||
        header->el_spatial_resampling_filter_flag != 1 || header->disable_residual_flag != 0) {
        av_free(metadata);
        return AVERROR_INVALIDDATA;
    }
    remove_fel_mapping(header, mapping);
    set_p81_color(av_dovi_get_color(metadata));
    uint8_t *rpu = NULL;
    int rpu_size = 0;
    /* No reference compression: every output carries its complete mapping/DM,
     * CRC and extension blocks so downstream native starts need no old state. */
    result = ff_dovi_rpu_generate(&converter->output, metadata, FF_DOVI_WRAP_NAL, &rpu, &rpu_size);
    av_free(metadata);
    if (result < 0 || !rpu || rpu_size <= 0) {
        av_free(rpu);
        ff_dovi_ctx_flush(&converter->output);
        return result < 0 ? result : AVERROR_INVALIDDATA;
    }
    *output = av_malloc((size_t) rpu_size + 2 + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!*output) {
        av_free(rpu);
        return AVERROR(ENOMEM);
    }
    (*output)[0] = 0x7c;
    (*output)[1] = 1;
    memcpy(*output + 2, rpu, rpu_size);
    memset(*output + 2 + rpu_size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    *output_size = (size_t) rpu_size + 2;
    av_free(rpu);
    return 0;
}
