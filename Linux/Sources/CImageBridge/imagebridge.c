#include "include/imagebridge.h"

#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>

/* **One lock, two systems.**
 *
 * `pthread` does not exist under MSVC. Windows has SRWLOCK instead: a
 * reader-writer lock that needs no cleanup and makes no system call when
 * uncontended. That is the case here: the decoder thread stores a frame, the
 * main thread fetches it, and both hold the lock only for a `memcpy`.
 *
 * The names are macros so the rest of the file is identical for both systems.
 * */
#ifdef _WIN32
  #define WIN32_LEAN_AND_MEAN
  #include <windows.h>
  typedef SRWLOCK Padlock;
  #define LOCK_CREATE(s)  InitializeSRWLock(s)
  #define LOCK_TAKE(s)   AcquireSRWLockExclusive(s)
  #define LOCK_NOTICE(s)    ReleaseSRWLockExclusive(s)
  #define LOCK_RESOLVE(s) ((void)0)
#else
  #include <pthread.h>
  typedef pthread_mutex_t Padlock;
  #define LOCK_CREATE(s)  pthread_mutex_init((s), NULL)
  #define LOCK_TAKE(s)   pthread_mutex_lock(s)
  #define LOCK_NOTICE(s)    pthread_mutex_unlock(s)
  #define LOCK_RESOLVE(s) pthread_mutex_destroy(s)
#endif

struct ImageBridge {
    Padlock  lock;
    uint8_t *buffer[2];      /* double buffer */
    size_t   size;
    unsigned width, height;
    int      art;            /* BILDART_* of the current buffers */
    unsigned layers;         /* 1 for RGB, 2 for P010, 3 for I0AL */
    unsigned tick[3];        /* bytes per row, per plane */
    size_t   offset[3];     /* start of each plane in the buffer */
    int      writes;       /* buffer VLC is currently writing to */
    bool     new;            /* added since the last fetch */
    bool     hdr;            /* requested for the next setup */
};

ImageBridge *image_bridge_new(void) {
    ImageBridge *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    LOCK_CREATE(&b->lock);
    return b;
}

void image_bridge_free(ImageBridge *b) {
    if (!b) return;
    LOCK_TAKE(&b->lock);
    free(b->buffer[0]);
    free(b->buffer[1]);
    LOCK_NOTICE(&b->lock);
    LOCK_RESOLVE(&b->lock);
    free(b);
}

void image_bridge_hdr(ImageBridge *b, bool hdr) {
    LOCK_TAKE(&b->lock);
    b->hdr = hdr;
    LOCK_NOTICE(&b->lock);
}

static unsigned on32(unsigned n) { return (n + 31) & ~31u; }

/* VLC asks which format to deliver in, passing the dimensions; `chroma`
 * holds what the decoder itself delivers on entry.
 *
 * **SDR: RV24**, three bytes per pixel, which GdkMemoryTexture accepts without
 * conversion. **HDR: 10-bit YUV.** If the decoder already delivers P010
 * (hardware, copied back) that stays; otherwise I0AL, which the software
 * decoder outputs for HEVC Main 10 anyway. Neither needs a CPU conversion.
 * Row pitch is a multiple of 32 bytes, otherwise VLC copies internally again;
 * the row count is rounded up to 16 because VLC's converters write in whole
 * blocks. */
static unsigned build(void **opaque, char *chroma,
                         unsigned *width, unsigned *height,
                         unsigned *beats, unsigned *rows) {
    ImageBridge *b = *opaque;
    unsigned w = *width, h = *height;
    unsigned cw = (w + 1) / 2, ch = (h + 1) / 2;
    unsigned hz = (h + 15) & ~15u, chz = (ch + 15) & ~15u;

    LOCK_TAKE(&b->lock);
    bool hdr = b->hdr;
    LOCK_NOTICE(&b->lock);

    int art;
    unsigned layers;
    if (!hdr) {
        memcpy(chroma, "RV24", 4);
        art = PIXEL_FORMAT_RGB24; layers = 1;
        beats[0] = on32(w * 3); rows[0] = h;
    } else if (memcmp(chroma, "P010", 4) == 0) {
        art = PIXEL_FORMAT_P010; layers = 2;
        beats[0] = on32(w * 2);  rows[0] = hz;
        beats[1] = on32(cw * 4); rows[1] = chz;   /* U and V interleaved */
    } else {
        memcpy(chroma, "I0AL", 4);
        art = PIXEL_FORMAT_I0AL; layers = 3;
        beats[0] = on32(w * 2);  rows[0] = hz;
        beats[1] = on32(cw * 2); rows[1] = chz;
        beats[2] = on32(cw * 2); rows[2] = chz;
    }
    size_t offset[3] = {0, 0, 0};
    size_t size = 0;
    for (unsigned i = 0; i < layers; i++) {
        offset[i] = size;
        size += (size_t)beats[i] * rows[i];
    }

    LOCK_TAKE(&b->lock);
    for (int i = 0; i < 2; i++) {
        free(b->buffer[i]);
        b->buffer[i] = calloc(1, size + 64);
    }
    b->size = size;
    b->width = w;
    b->height = h;
    b->art = art;
    b->layers = layers;
    for (unsigned i = 0; i < 3; i++) {
        b->tick[i] = i < layers ? beats[i] : 0;
        b->offset[i] = offset[i];
    }
    b->writes = 0;
    b->new = false;
    LOCK_NOTICE(&b->lock);

    return layers;
}

static void tearDown(void *opaque) {
    ImageBridge *b = opaque;
    LOCK_TAKE(&b->lock);
    for (int i = 0; i < 2; i++) { free(b->buffer[i]); b->buffer[i] = NULL; }
    b->size = 0;
    b->new = false;
    LOCK_NOTICE(&b->lock);
}

/* Before decoding: tell VLC where it may write. */
static void *lock(void *opaque, void **layers) {
    ImageBridge *b = opaque;
    LOCK_TAKE(&b->lock);
    for (unsigned i = 0; i < b->layers; i++)
        layers[i] = b->buffer[b->writes] + b->offset[i];
    return NULL;
}

static void resolve(void *opaque, void *image, void *const *layers) {
    (void)image; (void)layers;
    ImageBridge *b = opaque;
    LOCK_NOTICE(&b->lock);
}

/* After decoding: the written buffer becomes the visible one. */
static void show(void *opaque, void *image) {
    (void)image;
    ImageBridge *b = opaque;
    LOCK_TAKE(&b->lock);
    b->writes = 1 - b->writes;
    b->new = true;
    LOCK_NOTICE(&b->lock);
}

/* ---- VLC's own log messages ---------------------------------------------
 *
 * **Why this is in C and not Swift.** `libvlc_log_set` takes a callback with
 * a `va_list`, and a Swift function with `va_list` cannot be written as
 * `@convention(c)`; the compiler rejects it. So the line is formatted here
 * and passed on as a plain string.
 *
 * Only warnings and errors (levels 3 and 4). VLC's debug level writes every
 * second and drowns any log. */
static TrackRow track_target;

static void track_callback(void *data, int level, const libvlc_log_t *wo,
                          const char *form, va_list arguments) {
    (void)data; (void)wo;
    if (level < 3 || !track_target) return;
    char buffer[1024];
    vsnprintf(buffer, sizeof buffer, form, arguments);
    track_target(buffer);
}

void vlc_track_on(libvlc_instance_t *kern, TrackRow target) {
    track_target = target;
    libvlc_log_set(kern, track_callback, NULL);
}

void image_bridge_append(ImageBridge *b, libvlc_media_player_t *mp) {
    libvlc_video_set_format_callbacks(mp, build, tearDown);
    libvlc_video_set_callbacks(mp, lock, resolve, show, b);
}

bool image_bridge_fetch(ImageBridge *b, ImageState *state) {
    LOCK_TAKE(&b->lock);
    bool present = b->new && b->size > 0;
    if (present) {
        /* The buffer that is *not* being written is the finished one. */
        const uint8_t *done = b->buffer[1 - b->writes];
        for (unsigned i = 0; i < 3; i++) {
            state->layer[i] = i < b->layers ? done + b->offset[i] : NULL;
            state->tick[i] = b->tick[i];
        }
        state->width = b->width;
        state->height = b->height;
        state->art = b->art;
        b->new = false;
    }
    LOCK_NOTICE(&b->lock);
    return present;
}
