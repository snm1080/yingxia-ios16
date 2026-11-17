#include "TVMedia.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/time.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <string.h>

#define TVT_TIMEOUT_US 1500000
#define TVT_INPUT_BYTES (24LL << 20)
#define TVT_MAX_OPENS 32
#define TVT_MAX_PACKETS 2048
#define TVT_MAX_FRAMES 180
#define TVT_MAX_PIXELS (8192LL * 4320)
#define TVT_IO_BUFFER 32768
#define TVT_MAX_SEEKS 128

typedef struct {
    void *context;
    TVMInterruptFunction interrupted;
    const char *headers;
    int64_t deadline, remaining;
    int opens, seeks;
} TVTRequest;

typedef struct {
    TVTRequest *request;
    AVIOContext *source;
} TVTIO;

/// Forward HTTP's location/cookies options through the wrapper. HLS resolves relative segment URLs against
/// the final redirected playlist URL and carries cookies returned by the server into later requests.
static void *thumbnail_io_child(void *object, void *previous) {
    TVTIO *io = ((AVIOContext *)object)->opaque;
    return previous ? NULL : io->source;
}

static const AVClass thumbnail_io_class = {
    .class_name = "TVThumbnailIO",
    .item_name = av_default_item_name,
    .version = LIBAVUTIL_VERSION_INT,
    .child_next = thumbnail_io_child,
};

static int thumbnail_interrupted(void *opaque) {
    TVTRequest *request = opaque;
    return av_gettime_relative() >= request->deadline ||
        (request->interrupted && request->interrupted(request->context));
}

static int thumbnail_read(void *opaque, uint8_t *buffer, int size) {
    TVTIO *io = opaque;
    if (thumbnail_interrupted(io->request)) return AVERROR_EXIT;
    if (io->request->remaining <= 0) return AVERROR(ENOSPC);
    size = (int)FFMIN(size, io->request->remaining);
    int count = avio_read(io->source, buffer, size);
    if (count > 0) io->request->remaining -= count;
    return count;
}

static int64_t thumbnail_seek(void *opaque, int64_t offset, int whence) {
    TVTIO *io = opaque;
    if (thumbnail_interrupted(io->request)) return AVERROR_EXIT;
    if (++io->request->seeks > TVT_MAX_SEEKS) return AVERROR(ENOSPC);
    if (whence == AVSEEK_SIZE) return avio_size(io->source);
    // Protocols without byte seeking would read and discard an arbitrary distance on avio_seek().
    // Reject that path; HLS still seeks by opening the selected segment itself.
    if (!(io->source->seekable & AVIO_SEEKABLE_NORMAL)) return AVERROR(ENOSYS);
    int64_t before = io->source->bytes_read;
    int64_t position = avio_seek(io->source, offset, whence | AVSEEK_FORCE);
    io->request->remaining -= FFMAX(0, io->source->bytes_read - before);
    return position;
}

/// Every resource (including HLS playlists, keys and segments) passes through the same byte/deadline budget.
/// FFmpeg's underlying protocol may read ahead by one 32 KiB buffer per opened resource.
static int thumbnail_io_open(AVFormatContext *format, AVIOContext **result, const char *url,
                             int flags, AVDictionary **options) {
    TVTRequest *request = format->opaque;
    if (thumbnail_interrupted(request)) return AVERROR_EXIT;
    if ((flags & AVIO_FLAG_WRITE) || request->remaining <= 0 || ++request->opens > TVT_MAX_OPENS)
        return AVERROR(ENOSPC);
    TVTIO *io = av_mallocz(sizeof *io);
    uint8_t *buffer = av_malloc(TVT_IO_BUFFER);
    if (!io || !buffer) { av_free(io); av_free(buffer); return AVERROR(ENOMEM); }
    io->request = request;
    AVDictionary *ioOptions = NULL;
    if (options) av_dict_copy(&ioOptions, *options, 0);
    av_dict_set(&ioOptions, "rw_timeout", "2000000", 0);
    av_dict_set(&ioOptions, "timeout", "2000000", 0);
    av_dict_set(&ioOptions, "multiple_requests", "0", 0);
    if (request->headers && *request->headers) av_dict_set(&ioOptions, "headers", request->headers, 0);
    AVIOInterruptCB interrupt = { thumbnail_interrupted, request };
    int status = avio_open2(&io->source, url, flags, &interrupt, &ioOptions);
    av_dict_free(&ioOptions);
    if (status < 0) { av_free(io); av_free(buffer); return status; }
    AVIOContext *wrapped = avio_alloc_context(buffer, TVT_IO_BUFFER, 0, io, thumbnail_read, NULL, thumbnail_seek);
    if (!wrapped) {
        avio_closep(&io->source); av_free(io); av_free(buffer);
        return AVERROR(ENOMEM);
    }
    wrapped->seekable = io->source->seekable;
    wrapped->max_packet_size = io->source->max_packet_size;
    wrapped->av_class = &thumbnail_io_class;
    *result = wrapped;
    return 0;
}

static int thumbnail_io_close(AVFormatContext *format, AVIOContext *wrapped) {
    (void)format;
    if (!wrapped) return 0;
    TVTIO *io = wrapped->opaque;
    int status = avio_closep(&io->source);
    av_free(io);
    av_freep(&wrapped->buffer);
    avio_context_free(&wrapped);
    return status;
}

static int thumbnail_rotation(const AVStream *stream, const AVFrame *frame) {
    const AVPacketSideData *side = av_packet_side_data_get(stream->codecpar->coded_side_data,
        stream->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    const AVFrameSideData *frameSide = av_frame_get_side_data(frame, AV_FRAME_DATA_DISPLAYMATRIX);
    const uint8_t *matrix = frameSide && frameSide->size >= 9 * sizeof(int32_t) ? frameSide->data :
        side && side->size >= 9 * sizeof(int32_t) ? side->data : NULL;
    double angle = matrix ? -av_display_rotation_get((const int32_t *)matrix) : 0;
    if (!isfinite(angle)) return 0;
    int quarterTurns = (int)lround(angle / 90.0);
    return ((quarterTurns % 4) + 4) % 4;
}

static int thumbnail_convert(AVFormatContext *format, AVStream *stream, AVFrame *frame,
                             int width, int height, int64_t time, TVMThumbnail *result) {
    if (frame->width <= 0 || frame->height <= 0 || frame->width > 8192 || frame->height > 8192 ||
        (int64_t)frame->width * frame->height > TVT_MAX_PIXELS) return AVERROR(E2BIG);
    AVRational sampleAspect = av_guess_sample_aspect_ratio(format, stream, frame);
    double aspect = sampleAspect.num > 0 && sampleAspect.den > 0 ? av_q2d(sampleAspect) : 1;
    if (!isfinite(aspect) || aspect < 0.05 || aspect > 20) aspect = 1;
    int rotation = thumbnail_rotation(stream, frame);
    double displayWidth = frame->width * aspect, displayHeight = frame->height;
    double scale = rotation % 2 ? fmin(height / displayWidth, width / displayHeight) :
        fmin(width / displayWidth, height / displayHeight);
    scale = fmin(1, scale);
    int scaledWidth = FFMAX(1, (int)floor(displayWidth * scale));
    int scaledHeight = FFMAX(1, (int)floor(displayHeight * scale));
    int stride = scaledWidth * 4;
    uint8_t *pixels = av_malloc((size_t)stride * scaledHeight);
    if (!pixels) return AVERROR(ENOMEM);
    struct SwsContext *scaler = sws_getContext(frame->width, frame->height, frame->format,
        scaledWidth, scaledHeight, AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
    if (!scaler) { av_free(pixels); return AVERROR(ENOSYS); }
    uint8_t *planes[4] = { pixels, NULL, NULL, NULL };
    int strides[4] = { stride, 0, 0, 0 };
    int status = sws_scale(scaler, (const uint8_t * const *)frame->data, frame->linesize, 0,
        frame->height, planes, strides);
    sws_freeContext(scaler);
    if (status != scaledHeight) { av_free(pixels); return status < 0 ? status : AVERROR_INVALIDDATA; }
    for (int y = 0; y < scaledHeight; y++) {
        for (int x = 0; x < scaledWidth; x++) pixels[(size_t)y * stride + x * 4 + 3] = 255;
    }
    int outputWidth = rotation % 2 ? scaledHeight : scaledWidth;
    int outputHeight = rotation % 2 ? scaledWidth : scaledHeight;
    if (rotation) {
        uint8_t *rotated = av_malloc((size_t)outputWidth * outputHeight * 4);
        if (!rotated) { av_free(pixels); return AVERROR(ENOMEM); }
        for (int y = 0; y < scaledHeight; y++) {
            for (int x = 0; x < scaledWidth; x++) {
                int rx = rotation == 1 ? scaledHeight - y - 1 : rotation == 2 ? scaledWidth - x - 1 : y;
                int ry = rotation == 1 ? x : rotation == 2 ? scaledHeight - y - 1 : scaledWidth - x - 1;
                memcpy(rotated + ((size_t)ry * outputWidth + rx) * 4, pixels + (size_t)y * stride + x * 4, 4);
            }
        }
        av_free(pixels); pixels = rotated;
    }
    result->pixels = pixels;
    result->width = outputWidth; result->height = outputHeight; result->stride = outputWidth * 4;
    result->time = time;
    return 0;
}

void tvm_thumbnail_free(TVMThumbnail *thumbnail) {
    if (!thumbnail) return;
    av_freep(&thumbnail->pixels);
    memset(thumbnail, 0, sizeof *thumbnail);
}

int tvm_thumbnail(const char *url, const char *headers, double seconds, int maxWidth, int maxHeight,
                  void *context, TVMInterruptFunction interrupted, TVMThumbnail *thumbnail) {
    if (!thumbnail) return AVERROR(EINVAL);
    memset(thumbnail, 0, sizeof *thumbnail);
    if (!url || !*url || !isfinite(seconds) || seconds < 0 || seconds > 1e9 ||
        maxWidth <= 0 || maxHeight <= 0) return AVERROR(EINVAL);
    // 3x phone previews need square bounds: fitting portrait content inside a
    // fixed landscape180px box previously shrank it to roughly101x180 pixels.
    maxWidth = FFMIN(maxWidth, 640); maxHeight = FFMIN(maxHeight, 640);
    TVTRequest request = { context, interrupted, headers, av_gettime_relative() + TVT_TIMEOUT_US, TVT_INPUT_BYTES, 0, 0 };
    AVFormatContext *format = avformat_alloc_context();
    AVCodecContext *decoder = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL, *last = NULL;
    AVDictionary *options = NULL;
    AVDictionary **probeOptions = NULL;
    unsigned probeStreams = 0;
    int status = AVERROR(ENOMEM), frames = 0;
    int64_t lastTime = AV_NOPTS_VALUE;
    if (!format) return status;
    format->opaque = &request;
    format->interrupt_callback = (AVIOInterruptCB){ thumbnail_interrupted, &request };
    format->io_open = thumbnail_io_open;
    format->io_close2 = thumbnail_io_close;
    format->probesize = 1 << 20;
    format->max_analyze_duration = 1500000;
    format->max_probe_packets = 256;
    format->fps_probe_size = 0;
    format->max_streams = 64;
    format->max_index_size = 1 << 20;
    // Valid network HLS segments can have image suffixes; keep file/protocol gates.
    av_dict_set(&options, "extension_picky", "0", 0);
    av_dict_set(&options, "rw_timeout", "2000000", 0);
    av_dict_set(&options, "http_persistent", "0", 0);
    av_dict_set(&options, "http_multiple", "0", 0);
    av_dict_set(&options, "max_reload", "0", 0);
    av_dict_set(&options, "m3u8_hold_counters", "1", 0);
    av_dict_set(&options, "allowed_media_types", "video", 0);
    av_dict_set(&options, "skip_estimate_duration_from_pts", "1", 0);
    if (headers && *headers) av_dict_set(&options, "headers", headers, 0);
    status = avformat_open_input(&format, url, NULL, &options);
    av_dict_free(&options);
    if (status < 0) goto cleanup;
    probeStreams = format->nb_streams;
    probeOptions = av_calloc(FFMAX(1, probeStreams), sizeof *probeOptions);
    if (!probeOptions) { status = AVERROR(ENOMEM); goto cleanup; }
    for (unsigned index = 0; index < probeStreams; index++) {
        av_dict_set_int(&probeOptions[index], "max_pixels", TVT_MAX_PIXELS, 0);
        av_dict_set(&probeOptions[index], "threads", "1", 0);
    }
    status = avformat_find_stream_info(format, probeOptions);
    for (unsigned index = 0; index < probeStreams; index++) av_dict_free(&probeOptions[index]);
    av_freep(&probeOptions);
    if (status < 0 || thumbnail_interrupted(&request)) goto cleanup;
    int video = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (video < 0) { status = video; goto cleanup; }
    AVStream *stream = format->streams[video];
    if (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) { status = AVERROR_STREAM_NOT_FOUND; goto cleanup; }
    for (unsigned index = 0; index < format->nb_streams; index++) {
        if ((int)index != video) format->streams[index]->discard = AVDISCARD_ALL;
    }
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    decoder = codec ? avcodec_alloc_context3(codec) : NULL;
    if (!decoder) { status = AVERROR_DECODER_NOT_FOUND; goto cleanup; }
    status = avcodec_parameters_to_context(decoder, stream->codecpar);
    if (status < 0) goto cleanup;
    decoder->thread_count = 1;
    decoder->thread_type = 0;
    decoder->max_pixels = TVT_MAX_PIXELS;
    status = avcodec_open2(decoder, codec, NULL);
    if (status < 0) goto cleanup;
    int64_t start = format->start_time != AV_NOPTS_VALUE ? format->start_time :
        stream->start_time != AV_NOPTS_VALUE ? av_rescale_q(stream->start_time, stream->time_base, AV_TIME_BASE_Q) : 0;
    int64_t relative = (int64_t)llround(seconds * AV_TIME_BASE);
    if (format->duration > 0 && format->duration != AV_NOPTS_VALUE)
        relative = FFMIN(relative, FFMAX(0, format->duration - 100000));
    int64_t target = start + relative;
    int64_t seekTime = av_rescale_q(target, AV_TIME_BASE_Q, stream->time_base);
    status = avformat_seek_file(format, video, INT64_MIN, seekTime, seekTime, AVSEEK_FLAG_BACKWARD);
    if (status < 0 && relative > 250000) goto cleanup;
    avcodec_flush_buffers(decoder);
    packet = av_packet_alloc(); frame = av_frame_alloc(); last = av_frame_alloc();
    if (!packet || !frame || !last) { status = AVERROR(ENOMEM); goto cleanup; }
    for (int packets = 0; packets < TVT_MAX_PACKETS && !thumbnail_interrupted(&request); packets++) {
        int readStatus = av_read_frame(format, packet);
        if (readStatus < 0 && readStatus != AVERROR_EOF) { status = readStatus; break; }
        if (readStatus >= 0 && packet->stream_index != video) { av_packet_unref(packet); continue; }
        status = avcodec_send_packet(decoder, readStatus == AVERROR_EOF ? NULL : packet);
        av_packet_unref(packet);
        if (status < 0 && status != AVERROR_EOF) break;
        while (!thumbnail_interrupted(&request) && (status = avcodec_receive_frame(decoder, frame)) >= 0) {
            if (++frames > TVT_MAX_FRAMES) { status = AVERROR(E2BIG); goto cleanup; }
            int64_t pts = frame->best_effort_timestamp;
            int64_t at = pts != AV_NOPTS_VALUE ? av_rescale_q(pts, stream->time_base, AV_TIME_BASE_Q) : AV_NOPTS_VALUE;
            if ((at != AV_NOPTS_VALUE && at >= target && at <= target + 2000000) ||
                (at == AV_NOPTS_VALUE && relative <= 250000)) {
                status = thumbnail_convert(format, stream, frame, maxWidth, maxHeight,
                    at == AV_NOPTS_VALUE ? -1 : at - start, thumbnail);
                goto cleanup;
            }
            if (at != AV_NOPTS_VALUE && at < target && target - at <= 1000000) {
                av_frame_unref(last);
                status = av_frame_ref(last, frame);
                if (status < 0) goto cleanup;
                lastTime = at;
            }
            av_frame_unref(frame);
            if (at != AV_NOPTS_VALUE && at > target + 2000000) { status = AVERROR(ERANGE); goto cleanup; }
        }
        if (readStatus == AVERROR_EOF) {
            status = lastTime != AV_NOPTS_VALUE && !thumbnail_interrupted(&request) ?
                thumbnail_convert(format, stream, last, maxWidth, maxHeight, lastTime - start, thumbnail) : AVERROR_EOF;
            goto cleanup;
        }
        if (status != AVERROR(EAGAIN) && status != AVERROR_EOF) break;
    }
    status = thumbnail_interrupted(&request) ? AVERROR_EXIT : status >= 0 ? AVERROR(E2BIG) : status;
cleanup:
    av_dict_free(&options);
    if (probeOptions) {
        for (unsigned index = 0; index < probeStreams; index++) av_dict_free(&probeOptions[index]);
        av_free(probeOptions);
    }
    av_frame_free(&last); av_frame_free(&frame); av_packet_free(&packet);
    avcodec_free_context(&decoder);
    avformat_close_input(&format);
    if (thumbnail_interrupted(&request)) { tvm_thumbnail_free(thumbnail); return AVERROR_EXIT; }
    return thumbnail->pixels ? 0 : status < 0 ? status : AVERROR_INVALIDDATA;
}

