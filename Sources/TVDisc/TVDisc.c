#include "TVDisc.h"
#include <libbluray/bluray.h>
#include <stdlib.h>
#include <string.h>

struct tvd_disc { BLURAY *bd; BLURAY_TITLE_INFO *selected; };
typedef struct { char id[6]; uint64_t in_time, out_time; } tvd_clip_key;
static int compare_clips(const void *a, const void *b) {
    const tvd_clip_key *x = a, *y = b;
    int id = memcmp(x->id, y->id, sizeof(x->id));
    if (id) return id;
    if (x->in_time != y->in_time) return x->in_time < y->in_time ? -1 : 1;
    return x->out_time == y->out_time ? 0 : x->out_time < y->out_time ? -1 : 1;
}

tvd_disc *tvd_create(void) {
    tvd_disc *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->bd = bd_init();
    if (!d->bd) { free(d); return NULL; }
    return d;
}
int tvd_open_path(tvd_disc *d, const char *path) { return d && path ? bd_open_disc(d->bd, path, NULL) : 0; }
int tvd_open_stream(tvd_disc *d, void *context, tvd_read_blocks read) { return d && read ? bd_open_stream(d->bd, context, read) : 0; }
int tvd_is_encrypted(tvd_disc *d) {
    const BLURAY_DISC_INFO *info = d ? bd_get_disc_info(d->bd) : NULL;
    return info && ((info->aacs_detected && !info->aacs_handled) || (info->bdplus_detected && !info->bdplus_handled));
}
uint32_t tvd_title_count(tvd_disc *d) { return d ? bd_get_titles(d->bd, TITLES_ALL, 0) : 0; }
int tvd_title(tvd_disc *d, uint32_t index, tvd_title_info *result) {
    if (!d || !result) return 0;
    memset(result, 0, sizeof(*result));
    BLURAY_TITLE_INFO *info = bd_get_title_info(d->bd, index, 0);
    if (!info) return 0;
    result->playlist = info->playlist; result->duration = info->duration; result->chapters = info->chapter_count;
    result->valid = info->duration > 0 && info->clip_count > 0 && info->playlist <= 99999;
    tvd_clip_key *keys = result->valid ? calloc(info->clip_count, sizeof(*keys)) : NULL;
    if (!keys) result->valid = 0;
    for (uint32_t i = 0; result->valid && i < info->clip_count; ++i) {
        const BLURAY_CLIP_INFO *clip = &info->clips[i];
        if (clip->out_time <= clip->in_time || clip->still_mode != BLURAY_STILL_NONE || strlen(clip->clip_id) != 5) { result->valid = 0; break; }
        for (int k = 0; k < 5; ++k) if (clip->clip_id[k] < '0' || clip->clip_id[k] > '9') result->valid = 0;
        memcpy(keys[i].id, clip->clip_id, sizeof(keys[i].id));
        keys[i].in_time = clip->in_time; keys[i].out_time = clip->out_time;
    }
    if (result->valid) {
        qsort(keys, info->clip_count, sizeof(*keys), compare_clips);
        for (uint32_t i = 2; i < info->clip_count; ++i) {
            if (!compare_clips(&keys[i - 2], &keys[i])) { result->looped = 1; break; }
        }
    }
    free(keys);
    bd_free_title_info(info);
    return 1;
}
int tvd_select(tvd_disc *d, uint32_t playlist) {
    if (!d || playlist > 99999) return 0;
    BLURAY_TITLE_INFO *info = bd_get_playlist_info(d->bd, playlist, 0);
    if (!info) return 0;
    if (!bd_select_playlist(d->bd, playlist)) { bd_free_title_info(info); return 0; }
    if (d->selected) bd_free_title_info(d->selected);
    d->selected = info;
    return 1;
}
uint64_t tvd_size(tvd_disc *d) { return d ? bd_get_title_size(d->bd) : 0; }
int tvd_chapter(tvd_disc *d, uint32_t index, uint64_t *start) {
    if (!d || !d->selected || !start || index >= d->selected->chapter_count) return 0;
    *start = d->selected->chapters[index].start;
    return 1;
}
int tvd_read_at(tvd_disc *d, uint64_t offset, uint8_t *buffer, int count) {
    if (!d || !d->selected || !buffer || count < 0) return -1;
    uint64_t size = bd_get_title_size(d->bd);
    if (offset >= size || count == 0) return 0;
    uint64_t position = bd_tell(d->bd);
    if (position != offset) {
        int64_t seeked = bd_seek(d->bd, offset);
        if (seeked < 0) return -1;
        position = (uint64_t)seeked;
        /* A malformed CPI must not produce bytes from a different range. */
        if (position > offset) return -1;
        uint8_t discard[64 * 1024];
        while (position < offset) {
            uint64_t remaining = offset - position;
            int n = bd_read(d->bd, discard, remaining < sizeof(discard) ? (int)remaining : (int)sizeof(discard));
            if (n <= 0) return -1;
            position += (uint64_t)n;
        }
    }
    if ((uint64_t)count > size - offset) count = (int)(size - offset);
    return bd_read(d->bd, buffer, count);
}
void tvd_close(tvd_disc *d) {
    if (!d) return;
    if (d->selected) bd_free_title_info(d->selected);
    if (d->bd) bd_close(d->bd);
    free(d);
}
