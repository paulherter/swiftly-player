#include "include/mpvbridge.h"

#include <gtk/gtk.h>
#include <epoxy/gl.h>
#ifdef _WIN32
#include <windows.h>   /* wglGetProcAddress; link opengl32 */
#else
#include <epoxy/egl.h>
#if __has_include(<epoxy/glx.h>)
#include <epoxy/glx.h>
#define HAVE_GLX 1
#endif
#endif
#include <stdlib.h>
#include <string.h>

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

#ifdef _WIN32
/* no X11/Wayland handles on Windows */
#elif __has_include(<gdk/x11/gdkx.h>)
#include <gdk/x11/gdkx.h>
#define HAVE_X11 1
#endif
#if !defined(_WIN32) && __has_include(<gdk/wayland/gdkwayland.h>)
#include <gdk/wayland/gdkwayland.h>
#define HAVE_WL 1
#endif

struct MpvGL {
    mpv_render_context *ctx;
    GtkGLArea *area;   /* strong ref, dropped in mpvgl_free */
};

static void *proc_address(void *unused, const char *name) {
    (void)unused;
#ifdef _WIN32
    /* GTK4 on Windows renders through WGL. Extension functions come from
       wglGetProcAddress, GL 1.1 ones from opengl32.dll itself. */
    void *p = (void *)wglGetProcAddress(name);
    if (!p || p == (void *)1 || p == (void *)2 || p == (void *)3 || p == (void *)-1) {
        static HMODULE gl32;
        if (!gl32) gl32 = GetModuleHandleA("opengl32.dll");
        p = gl32 ? (void *)GetProcAddress(gl32, name) : NULL;
    }
    return p;
#else
#ifdef HAVE_GLX
    if (glXGetCurrentContext() != NULL)
        return (void *)glXGetProcAddressARB((const GLubyte *)name);
#endif
    return (void *)eglGetProcAddress(name);
#endif
}

static gboolean queue_render_idle(gpointer data) {
    GtkGLArea *area = GTK_GL_AREA(data);
    gtk_gl_area_queue_render(area);
    g_object_unref(area);
    return G_SOURCE_REMOVE;
}

/* Called by mpv from an arbitrary thread whenever a new frame is ready. */
static void on_update(void *data) {
    MpvGL *gl = data;
    g_idle_add_full(G_PRIORITY_HIGH, queue_render_idle, g_object_ref(gl->area), NULL);
}

const char *mpvgl_display_kind(void) {
    GdkDisplay *d = gdk_display_get_default();
#ifdef HAVE_WL
    if (d && GDK_IS_WAYLAND_DISPLAY(d)) return "wayland";
#endif
#ifdef HAVE_X11
    if (d && GDK_IS_X11_DISPLAY(d)) return "x11";
#endif
    return "none";
}

MpvGL *mpvgl_new(void *mpv, void *glarea, const char **error) {
    static const char *no_ctx = "mpv_render_context_create failed";
    MpvGL *gl = calloc(1, sizeof *gl);
    if (!gl) return NULL;
    gl->area = g_object_ref(GTK_GL_AREA(glarea));

    mpv_opengl_init_params init = { .get_proc_address = proc_address };
    int advanced = 1;
    void *display = NULL;
    int display_type = 0;
    GdkDisplay *d = gdk_display_get_default();
#ifdef HAVE_WL
    if (d && GDK_IS_WAYLAND_DISPLAY(d)) {
        display = gdk_wayland_display_get_wl_display(d);
        display_type = MPV_RENDER_PARAM_WL_DISPLAY;
    }
#endif
#ifdef HAVE_X11
    if (!display && d && GDK_IS_X11_DISPLAY(d)) {
        display = gdk_x11_display_get_xdisplay(d);
        display_type = MPV_RENDER_PARAM_X11_DISPLAY;
    }
#endif
    mpv_render_param params[4];
    int n = 0;
    params[n++] = (mpv_render_param){ MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL };
    params[n++] = (mpv_render_param){ MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &init };
    if (display) params[n++] = (mpv_render_param){ display_type, display };
    params[n++] = (mpv_render_param){ MPV_RENDER_PARAM_INVALID, NULL };
    (void)advanced;

    if (mpv_render_context_create(&gl->ctx, mpv, params) < 0) {
        if (error) *error = no_ctx;
        g_object_unref(gl->area);
        free(gl);
        return NULL;
    }
    mpv_render_context_set_update_callback(gl->ctx, on_update, gl);
    return gl;
}

int mpvgl_render(MpvGL *gl, int width, int height) {
    if (!gl || !gl->ctx) return -1;
    GLint fbo = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
    mpv_opengl_fbo target = { .fbo = fbo, .w = width, .h = height, .internal_format = 0 };
    int flip = 1;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &target },
        { MPV_RENDER_PARAM_FLIP_Y, &flip },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    mpv_render_context_update(gl->ctx);
    int r = mpv_render_context_render(gl->ctx, params);
    /* mpv leaves GL state changed; GTK expects its framebuffer bound again. */
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    mpv_render_context_report_swap(gl->ctx);
    return r;
}

unsigned mpvgl_probe_pixel(int x, int y) {
    unsigned char px[4] = {0, 0, 0, 0};
    glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    return (unsigned)px[0] << 16 | (unsigned)px[1] << 8 | px[2];
}

void mpvgl_free(MpvGL *gl) {
    if (!gl) return;
    if (gl->ctx) {
        mpv_render_context_set_update_callback(gl->ctx, NULL, NULL);
        mpv_render_context_free(gl->ctx);
    }
    g_object_unref(gl->area);
    free(gl);
}
