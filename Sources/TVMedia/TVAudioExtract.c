#include "TVMedia.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libavutil/time.h>
#include <libswresample/swresample.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <string.h>

#define TVA_TIMEOUT_US 20000000
#define TVA_INPUT_BYTES (64LL << 20)
#define TVA_MAX_OPENS 128
#define TVA_MAX_PACKETS 16000
#define TVA_MAX_SEEKS 4096
#define TVA_IO_BUFFER 32768
#define TVA_MAX_UNTIMED_FRAMES 96

typedef struct {
    void *context;
    TVMInterruptFunction interrupted;
    const char *headers;
    int64_t deadline, remaining;
    int opens, seeks, ioError, sampling;
} TVARequest;

typedef struct {
    TVARequest *request;
    AVIOContext *source;
} TVAIO;

/// Forward HTTP's location/cookies options through the wrapper. HLS resolves relative segment URLs against
/// the final redirected playlist URL and carries cookies returned by the server into later requests.
static void *audio_io_child(void *object, void *previous) {
    TVAIO *io = ((AVIOContext *)object)->opaque;
    return previous ? NULL : io->source;
}

static const AVClass audio_io_class = {
    .class_name = "TVAudioSampleIO",
    .item_name = av_default_item_name,
    .version = LIBAVUTIL_VERSION_INT,
    .child_next = audio_io_child,
};

static int audio_interrupted(void *opaque) {
    TVARequest *request = opaque;
    return request->ioError || av_gettime_relative() >= request->deadline ||
        (request->interrupted && request->interrupted(request->context));
}

static int audio_io_error(TVARequest *request, int status) {
    if (status < 0 && status != AVERROR_EOF && !request->ioError) request->ioError = status;
    return status;
}

static int audio_transport_error(TVARequest *request, int status) {
    // HLS master probing may discard a broken, unrelated variant and continue
    // with its valid audio. Keep resource limits globally fatal, but only make
    // transport errors sticky after stream discovery and audio selection.
    return request->sampling ? audio_io_error(request, status) : status;
}

static int audio_read(void *opaque, uint8_t *buffer, int size) {
    TVAIO *io = opaque;
    if (audio_interrupted(io->request)) return AVERROR_EXIT;
    if (io->request->remaining <= 0) return audio_io_error(io->request, AVERROR(ENOSPC));
    size = (int)FFMIN(size, io->request->remaining);
    int count = avio_read(io->source, buffer, size);
    if (count > 0) io->request->remaining -= count;
    return count < 0 ? audio_transport_error(io->request, count) : count;
}

static int64_t audio_seek(void *opaque, int64_t offset, int whence) {
    TVAIO *io = opaque;
    if (audio_interrupted(io->request)) return AVERROR_EXIT;
    // Container size queries do not reposition or fetch media. MP4 audio reads
    // also seek around each discarded video chunk, often hundreds of times in
    // one speech window; the thumbnail's single-frame limit cannot cover that.
    if (whence == AVSEEK_SIZE) return avio_size(io->source);
    if (++io->request->seeks > TVA_MAX_SEEKS) return audio_io_error(io->request, AVERROR(ENOSPC));
    // Protocols without byte seeking would read and discard an arbitrary distance on avio_seek().
    // Reject that path; HLS still seeks by opening the selected segment itself.
    if (!(io->source->seekable & AVIO_SEEKABLE_NORMAL)) return AVERROR(ENOSYS);
    int64_t before = io->source->bytes_read;
    int64_t position = avio_seek(io->source, offset, whence | AVSEEK_FORCE);
    io->request->remaining -= FFMAX(0, io->source->bytes_read - before);
    if (io->request->remaining < 0) return audio_io_error(io->request, AVERROR(ENOSPC));
    return position;
}

/// Every resource (including HLS playlists, keys and segments) passes through the same byte/deadline budget.
/// FFmpeg's underlying protocol may read ahead by one 32 KiB buffer per opened resource.
static int audio_io_open(AVFormatContext *format, AVIOContext **result, const char *url,
                             int flags, AVDictionary **options) {
    TVARequest *request = format->opaque;
    if (audio_interrupted(request)) return AVERROR_EXIT;
    if ((flags & AVIO_FLAG_WRITE) || request->remaining <= 0 || ++request->opens > TVA_MAX_OPENS)
        return audio_io_error(request, AVERROR(ENOSPC));
    TVAIO *io = av_mallocz(sizeof *io);
    uint8_t *buffer = av_malloc(TVA_IO_BUFFER);
    if (!io || !buffer) { av_free(io); av_free(buffer); return AVERROR(ENOMEM); }
    io->request = request;
    AVDictionary *ioOptions = NULL;
    if (options) av_dict_copy(&ioOptions, *options, 0);
    av_dict_set(&ioOptions, "rw_timeout", "2000000", 0);
    av_dict_set(&ioOptions, "timeout", "2000000", 0);
    av_dict_set(&ioOptions, "multiple_requests", "0", 0);
    if (request->headers && *request->headers) av_dict_set(&ioOptions, "headers", request->headers, 0);
    AVIOInterruptCB interrupt = { audio_interrupted, request };
    int status = avio_open2(&io->source, url, flags, &interrupt, &ioOptions);
    av_dict_free(&ioOptions);
    if (status < 0) { av_free(io); av_free(buffer); return audio_transport_error(request, status); }
    AVIOContext *wrapped = avio_alloc_context(buffer, TVA_IO_BUFFER, 0, io, audio_read, NULL, audio_seek);
    if (!wrapped) {
        avio_closep(&io->source); av_free(io); av_free(buffer);
        return AVERROR(ENOMEM);
    }
    wrapped->seekable = io->source->seekable;
    wrapped->max_packet_size = io->source->max_packet_size;
    wrapped->av_class = &audio_io_class;
    *result = wrapped;
    return 0;
}

static int audio_io_close(AVFormatContext *format, AVIOContext *wrapped) {
    (void)format;
    if (!wrapped) return 0;
    TVAIO *io = wrapped->opaque;
    int status = avio_closep(&io->source);
    av_free(io);
    av_freep(&wrapped->buffer);
    avio_context_free(&wrapped);
    return status;
}

void tvm_audio_free(TVMAudioSample *sample) {
    if (!sample) return;
    av_freep(&sample->bytes);
    memset(sample, 0, sizeof *sample);
}

int tvm_audio_sample(const char *url, const char *headers, int wanted, double seconds, double duration,
                     void *context, TVMInterruptFunction interrupted, TVMAudioSample *sample) {
    if (!sample) return AVERROR(EINVAL);
    memset(sample, 0, sizeof *sample);
    if (!url || !*url || !isfinite(seconds) || seconds < 0 || seconds > 1e9 ||
        !isfinite(duration) || duration <= 0 || duration > 20) return AVERROR(EINVAL);
    TVARequest request = { context, interrupted, headers, av_gettime_relative() + TVA_TIMEOUT_US, TVA_INPUT_BYTES, 0, 0, 0, 0 };
    AVFormatContext *format = avformat_alloc_context();
    AVCodecContext *decoder = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    SwrContext *resampler = NULL;
    AVDictionary *options = NULL;
    uint8_t *converted = NULL;
    int status = AVERROR(ENOMEM), used = 0, untimed = 0, capacity = (int)ceil(duration * 16000);
    int64_t cursor = AV_NOPTS_VALUE;
    if (!format) return status;
    format->opaque = &request;
    format->interrupt_callback = (AVIOInterruptCB){ audio_interrupted, &request };
    format->io_open = audio_io_open; format->io_close2 = audio_io_close;
    format->probesize = 1 << 20; format->max_analyze_duration = 1500000;
    format->max_probe_packets = 256; format->max_streams = 64;
    // Valid network HLS segments can have image suffixes; keep file/protocol gates.
    av_dict_set(&options, "extension_picky", "0", 0);
    av_dict_set(&options, "rw_timeout", "2000000", 0);
    av_dict_set(&options, "http_persistent", "0", 0);
    av_dict_set(&options, "http_multiple", "0", 0);
    // HLS applies these counters before opening even a VOD's first segment,
    // then revisits the same segment during stream probing and time seeking.
    // Zero reloads / one hold makes valid ENDLIST media appear to be at EOF.
    av_dict_set(&options, "max_reload", "2", 0);
    av_dict_set(&options, "m3u8_hold_counters", "4", 0);
    av_dict_set(&options, "skip_estimate_duration_from_pts", "1", 0);
    if (headers && *headers) av_dict_set(&options, "headers", headers, 0);
    status = avformat_open_input(&format, url, NULL, &options);
    av_dict_free(&options);
    if (status < 0) goto cleanup;
    status = avformat_find_stream_info(format, NULL);
    if (status < 0 || audio_interrupted(&request)) goto cleanup;
    int audio = wanted >= 0 && wanted < (int)format->nb_streams &&
        format->streams[wanted]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO ? wanted :
        wanted < 0 ? av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0) : AVERROR_STREAM_NOT_FOUND;
    if (audio < 0) { status = audio; goto cleanup; }
    AVStream *stream = format->streams[audio];
    for (unsigned index = 0; index < format->nb_streams; index++)
        if ((int)index != audio) format->streams[index]->discard = AVDISCARD_ALL;
    request.sampling = 1;
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    decoder = codec ? avcodec_alloc_context3(codec) : NULL;
    if (!decoder) { status = AVERROR_DECODER_NOT_FOUND; goto cleanup; }
    status = avcodec_parameters_to_context(decoder, stream->codecpar);
    if (status < 0) goto cleanup;
    decoder->thread_count = 1;
    decoder->pkt_timebase = stream->time_base;
    status = avcodec_open2(decoder, codec, NULL);
    if (status < 0) goto cleanup;
    int64_t origin = format->start_time != AV_NOPTS_VALUE ? format->start_time :
        stream->start_time != AV_NOPTS_VALUE ? av_rescale_q(stream->start_time, stream->time_base, AV_TIME_BASE_Q) : 0;
    int64_t target = origin + (int64_t)llround(seconds * AV_TIME_BASE);
    int64_t end = target + (int64_t)llround(duration * AV_TIME_BASE);
    int64_t seek = av_rescale_q(target, AV_TIME_BASE_Q, stream->time_base);
    status = avformat_seek_file(format, audio, INT64_MIN, seek, seek, AVSEEK_FLAG_BACKWARD);
    if (status < 0 && seconds > 0.25) goto cleanup;
    avcodec_flush_buffers(decoder);
    packet = av_packet_alloc(); frame = av_frame_alloc();
    sample->bytes = av_malloc((size_t)capacity * 2);
    if (!packet || !frame || !sample->bytes) { status = AVERROR(ENOMEM); goto cleanup; }
    for (int packets = 0; packets < TVA_MAX_PACKETS && !audio_interrupted(&request); packets++) {
        int read = av_read_frame(format, packet);
        if (read < 0 && read != AVERROR_EOF) { status = read; goto cleanup; }
        if (read >= 0 && packet->stream_index != audio) { av_packet_unref(packet); continue; }
        status = avcodec_send_packet(decoder, read == AVERROR_EOF ? NULL : packet);
        av_packet_unref(packet);
        if (status < 0 && status != AVERROR_EOF) goto cleanup;
        while ((status = avcodec_receive_frame(decoder, frame)) >= 0 && !audio_interrupted(&request)) {
            if (frame->sample_rate <= 0 || frame->sample_rate > 384000 || frame->ch_layout.nb_channels < 1 ||
                frame->ch_layout.nb_channels > 32 || frame->nb_samples > 262144) { status = AVERROR(E2BIG); goto cleanup; }
            int64_t at = frame->best_effort_timestamp != AV_NOPTS_VALUE ?
                av_rescale_q(frame->best_effort_timestamp, stream->time_base, AV_TIME_BASE_Q) : cursor;
            if (at == AV_NOPTS_VALUE) {
                // At an HLS PES boundary FFmpeg can emit an initial AAC frame
                // without PTS. Do not guess that frame's position after a seek:
                // discard bounded preroll until a real timestamp establishes
                // the cursor, then only extrapolate subsequent missing PTS.
                if (seconds > 0.25) {
                    av_frame_unref(frame);
                    if (++untimed > TVA_MAX_UNTIMED_FRAMES) { status = AVERROR_INVALIDDATA; goto cleanup; }
                    continue;
                }
                at = origin;
            }
            cursor = at + av_rescale(frame->nb_samples, AV_TIME_BASE, frame->sample_rate);
            if (at >= end) { status = 0; goto complete; }
            if (!resampler) {
                AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
                status = swr_alloc_set_opts2(&resampler, &mono, AV_SAMPLE_FMT_S16, 16000,
                    &frame->ch_layout, frame->format, frame->sample_rate, 0, NULL);
                if (status < 0 || (status = swr_init(resampler)) < 0) goto cleanup;
            }
            int64_t delay = swr_get_delay(resampler, frame->sample_rate);
            int outputCapacity = (int)av_rescale_rnd(delay + frame->nb_samples, 16000, frame->sample_rate, AV_ROUND_UP);
            if (outputCapacity < 0 || outputCapacity > 262144) { status = AVERROR(E2BIG); goto cleanup; }
            converted = av_malloc((size_t)outputCapacity * 2);
            if (!converted) { status = AVERROR(ENOMEM); goto cleanup; }
            int count = swr_convert(resampler, &converted, outputCapacity, (const uint8_t **)frame->extended_data, frame->nb_samples);
            if (count < 0) { status = count; goto cleanup; }
            int64_t outputAt = at - av_rescale(delay, AV_TIME_BASE, frame->sample_rate);
            int skip = (int)FFMIN(count, FFMAX(0, av_rescale_rnd(target - outputAt, 16000, AV_TIME_BASE, AV_ROUND_UP)));
            int until = (int)FFMIN(count, FFMAX(0, av_rescale_rnd(end - outputAt, 16000, AV_TIME_BASE, AV_ROUND_DOWN)));
            int copy = FFMIN(FFMAX(0, until - skip), capacity - used);
            if (copy) {
                if (!used) sample->position = (outputAt - origin) / (double)AV_TIME_BASE + skip / 16000.0;
                memcpy(sample->bytes + used * 2, converted + skip * 2, (size_t)copy * 2); used += copy;
            }
            av_freep(&converted); av_frame_unref(frame);
            if (used >= capacity) { status = 0; goto complete; }
        }
        if (status != AVERROR(EAGAIN) && status != AVERROR_EOF) goto cleanup;
        if (read == AVERROR_EOF) { status = 0; goto complete; }
    }
    status = AVERROR(E2BIG);
    goto cleanup;
complete:
    if (used < 1600) { status = AVERROR_INVALIDDATA; goto cleanup; }
    sample->size = used * 2; sample->duration = used / 16000.0;
cleanup:
    av_free(converted); av_dict_free(&options);
    swr_free(&resampler); av_frame_free(&frame); av_packet_free(&packet);
    avcodec_free_context(&decoder); avformat_close_input(&format);
    // HLS may swallow an unsuccessful segment open and report ordinary EOF.
    // A resource/transport failure must not publish a truncated speech window.
    if (request.ioError) status = request.ioError;
    else if (audio_interrupted(&request)) status = AVERROR_EXIT;
    if (status < 0 || !sample->size) { tvm_audio_free(sample); return status < 0 ? status : AVERROR_INVALIDDATA; }
    return 0;
}
