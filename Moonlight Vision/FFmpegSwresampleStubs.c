//
//  FFmpegSwresampleStubs.c
//  Moonlight Vision
//
//  The bundled libavcodec's Opus decoder references libswresample, which is not
//  shipped. Moonlight decodes audio with libopus directly and never opens the
//  FFmpeg Opus decoder, so these stubs only satisfy the linker; if they were ever
//  reached they fail cleanly instead of resampling.
//

#include <errno.h>
#include <stddef.h>
#include <stdint.h>

struct SwrContext;

struct SwrContext *swr_alloc(void) { return NULL; }
int swr_init(struct SwrContext *s) { (void)s; return -ENOSYS; }
int swr_is_initialized(struct SwrContext *s) { (void)s; return 0; }
void swr_close(struct SwrContext *s) { (void)s; }
void swr_free(struct SwrContext **s) { if (s) *s = NULL; }
int swr_convert(struct SwrContext *s, uint8_t **out, int out_count, const uint8_t **in, int in_count)
{
    (void)s; (void)out; (void)out_count; (void)in; (void)in_count;
    return -ENOSYS;
}
