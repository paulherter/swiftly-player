#ifndef HDRBILD_H
#define HDRBILD_H

#include <stdbool.h>
#include "imagebridge.h"

/* **HDR on an SDR display, computed on the GPU.**
 *
 * libVLC 3 only tone-maps HDR to SDR in its own OpenGL output
 * (`--tone-mapping`, via libplacebo). This player draws itself through the
 * raw-frame callbacks in `imagebridge.c`, where VLC converts to RGB with
 * swscale and leaves the transfer curve as is. PQ values shown as sRGB are
 * exactly the washed-out, pale picture.
 *
 * So the HDR frame arrives as 10-bit YUV and is converted in a shader, per
 * pixel:
 *
 *   YUV (BT.2020, limited range) → R'G'B'
 *   → linear in nits (PQ per SMPTE ST 2084, HLG per BT.2100 with OOTF)
 *   → tone mapping per BT.2390 (EETF) to the SDR white of 203 nits
 *   → BT.2020 → BT.709 → gamma 2.2
 *
 * This is the same chain mpv runs through libplacebo. On the CPU it would be
 * too slow for 4K; on the GPU it costs almost nothing, and the RGB
 * conversion VLC would otherwise do on the CPU is skipped.
 *
 * All functions except `hdr_image_new`/`hdr_image_free` need a current GL context
 * (GtkGLArea). GL objects are created on first use; `es` says whether the
 * context is OpenGL ES (different shader header). */

typedef struct Hdrbild Hdrbild;

/* Transfer curves; same cases as `ColorRange.Kennlinie` in the package. */
enum { HDRBILD_PQ = 1, HDRBILD_HLG = 2 };

Hdrbild *hdr_image_new(void);
void hdr_image_free(Hdrbild *h);

/* Compiles the shaders. false means this context cannot do it, and the RGB
 * path stays in use. The reason is in `hdr_image_error`. */
bool hdr_image_set_up(Hdrbild *h, bool es);
const char *hdr_image_error(const Hdrbild *h);

/* Uploads an I0AL or P010 frame into the textures. */
bool hdr_image_upload(Hdrbild *h, const ImageState *state, bool es);

/* Draws into the bound framebuffer of size breite × hoehe (device pixels).
 * `fill`: fill instead of fit. `tip`: the material's brightest spot in
 * nits (1000 if not given). */
bool hdr_image_draw(Hdrbild *h, int width, int height, bool fill,
                      int curve, float tip, bool es);

/* Frees the GL objects; call before the context is torn down. */
void hdr_image_give_up(Hdrbild *h);

/* Vendor, device and version of the current GL context, for the startup log
 * line. Fixed buffer; call from the main thread only. */
const char *hdr_image_unstretch_info(void);

#endif
