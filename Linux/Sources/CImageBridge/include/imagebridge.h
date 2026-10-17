#ifndef IMAGE_BRIDGE_H
#define IMAGE_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <vlc/vlc.h>

/* **Bridge between VLC's decoder thread and GTK's main thread.**
 *
 * libVLC 3 has no `libvlc_video_set_output_callbacks`; that arrived with VLC 4.
 * What exists are raw-frame callbacks: VLC writes each frame into memory
 * supplied by the caller. That is what this file does.
 *
 * **Why C and not Swift.** The callbacks run on VLC's decoder thread, several
 * times per second, and share a buffer with the main thread. That is the kind
 * of shared mutable state Swift 6 rightly forbids; it could only be passed
 * with `@unchecked Sendable` and a custom lock, an assertion that checks
 * nothing. In C the lock is visible, and the boundary to Swift is a single
 * function that returns a finished frame.
 *
 * Two buffers: VLC fills one while the other is being drawn.
 */

typedef struct ImageBridge ImageBridge;

ImageBridge *image_bridge_new(void);
void image_bridge_free(ImageBridge *b);

/* Attaches the bridge to a player. Must happen before playback starts. */
/* A fully formatted libVLC message. Runs on VLC's thread. */
typedef void (*TrackRow)(const char *);

/* Forwards libVLC warnings and errors to `target`. NULL turns it off. */
void vlc_track_on(libvlc_instance_t *kern, TrackRow target);

void image_bridge_append(ImageBridge *b, libvlc_media_player_t *mp);

/* **The shape of a frame.** RGB is the SDR path: VLC converts to RGB itself
 * and GTK shows it as a memory texture. For HDR the frame stays as the
 * decoder delivers it (10-bit YUV) and the shader in `hdrimage.c` converts
 * it. VLC's own RGB conversion knows neither PQ nor HLG, which produced a
 * washed-out picture. */
enum {
    PIXEL_FORMAT_RGB24 = 0,   /* RV24, one plane */
    PIXEL_FORMAT_I0AL  = 1,   /* YUV 4:2:0, 10 bit in 16, low bits, three planes */
    PIXEL_FORMAT_P010  = 2    /* YUV 4:2:0, 10 bit in 16, high bits, Y + interleaved UV */
};

typedef struct {
    const uint8_t *layer[3];
    unsigned tick[3];          /* bytes per row */
    unsigned width, height;    /* visible size of the frame */
    int art;                   /* BILDART_* */
} ImageState;

/* Before start: should VLC deliver 10-bit YUV (HDR) or RGB (SDR)? */
void image_bridge_hdr(ImageBridge *b, bool hdr);

/* Fetches the newest frame. Returns false if none has arrived since the
 * last call; then there is nothing to do.
 * The pointers stay valid until the next call. */
bool image_bridge_fetch(ImageBridge *b, ImageState *state);

#endif
