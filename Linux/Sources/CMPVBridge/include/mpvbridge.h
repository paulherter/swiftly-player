#ifndef MPVBRIDGE_H
#define MPVBRIDGE_H
// Thin C layer between libmpv's render API and a GtkGLArea. Pointers are `void *`
// on purpose: Swift sees no mpv or GTK headers through this module.
//
// Why C: libmpv needs a `get_proc_address` callback, display handles for hardware
// decoding interop and the GL framebuffer binding (epoxy macros); none of that
// imports into Swift.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MpvGL MpvGL;

/// Call from the GtkGLArea's `realize` handler, GL context current. Creates the
/// render context for `mpv` (an `mpv_handle *`). NULL on failure; `error` receives a
/// static message.
MpvGL *mpvgl_new(void *mpv, void *glarea, const char **error);

/// Call from the `render` handler. `width`/`height` are framebuffer pixels.
/// Returns 0 on success.
int mpvgl_render(MpvGL *gl, int width, int height);

/// Diagnostics: RGB of one pixel of the bound framebuffer (call right after a render).
unsigned mpvgl_probe_pixel(int x, int y);

/// Call before the GL context goes away (`unrealize`), context current. The mpv core
/// keeps running; the next `mpvgl_new` continues at the same position.
void mpvgl_free(MpvGL *gl);

/// Which windowing system the display handle came from: "wayland", "x11" or "none".
const char *mpvgl_display_kind(void);

#ifdef __cplusplus
}
#endif
#endif
