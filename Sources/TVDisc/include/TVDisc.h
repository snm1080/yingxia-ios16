#ifndef TVDISC_H
#define TVDISC_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct tvd_disc tvd_disc;
typedef int (*tvd_read_blocks)(void *context, void *buffer, int lba, int blocks);
typedef struct {
    uint32_t playlist, chapters;
    uint64_t duration;
    int valid, looped;
} tvd_title_info;
tvd_disc *tvd_create(void);
int tvd_open_path(tvd_disc *, const char *path);
int tvd_open_stream(tvd_disc *, void *context, tvd_read_blocks);
/* 1 means AACS or BD+ was detected without an available decryption library. */
int tvd_is_encrypted(tvd_disc *);
uint32_t tvd_title_count(tvd_disc *);
int tvd_title(tvd_disc *, uint32_t index, tvd_title_info *);
int tvd_select(tvd_disc *, uint32_t playlist);
uint64_t tvd_size(tvd_disc *);
int tvd_chapter(tvd_disc *, uint32_t index, uint64_t *start);
/* Exact byte reads, correcting libbluray's access-unit-aligned seek position. */
int tvd_read_at(tvd_disc *, uint64_t offset, uint8_t *buffer, int count);
void tvd_close(tvd_disc *);
#ifdef __cplusplus
}
#endif
#endif
