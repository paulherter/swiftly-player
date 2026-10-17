#include "include/mediakeys.h"

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* From GTK. Declared by hand so this part does not have to include the GDK
 * headers, which would pull `windows.h` into every translation unit. */
extern void *gdk_win32_surface_get_handle(void *area);

static WNDPROC previous;
static HWND    our;
static void  (*callback)(int);

/* The app's own window procedure. Everything it does not handle is passed
 * on unchanged to the previous one; otherwise GTK stops working. */
static LRESULT CALLBACK ourProcedure(HWND h, UINT n, WPARAM w, LPARAM l) {
    /* Suspend and resume. After resume the WASAPI audio output is often no
 * longer valid and the connection to the server has dropped anyway; the app
 * rebuilds both (App.mediaHandle). Depending on the cause, resume arrives as
 * AUTOMATIC or SUSPEND; both report, the app only uses the first. */
    if (n == WM_POWERBROADCAST && callback) {
        if (w == PBT_APMSUSPEND) callback(MT_SLEEPS);
        else if (w == PBT_APMRESUMEAUTOMATIC || w == PBT_APMRESUMESUSPEND) callback(MT_WOKE);
        return TRUE;
    }
    if (n == WM_HOTKEY && callback) {
        callback((int)w);
        return 0;
    }
    if (n == WM_APPCOMMAND && callback) {
        switch (GET_APPCOMMAND_LPARAM(l)) {
            case APPCOMMAND_MEDIA_PLAY_PAUSE: callback(MT_TOGGLE); return TRUE;
            case APPCOMMAND_MEDIA_PLAY:       callback(MT_TOGGLE); return TRUE;
            case APPCOMMAND_MEDIA_PAUSE:      callback(MT_TOGGLE); return TRUE;
            case APPCOMMAND_MEDIA_STOP:       callback(MT_END);    return TRUE;
            case APPCOMMAND_MEDIA_NEXTTRACK:  callback(MT_NEXT);     return TRUE;
            case APPCOMMAND_MEDIA_PREVIOUSTRACK: callback(MT_BACK); return TRUE;
            default: break;
        }
    }
    return CallWindowProcW(previous, h, n, w, l);
}

void media_keys_sign_in(void *gdk_area, void (*report)(int handle)) {
    if (!gdk_area || our) return;
    HWND h = (HWND)gdk_win32_surface_get_handle(gdk_area);
    if (!h) return;
    our = h;
    callback = report;

    previous = (WNDPROC)SetWindowLongPtrW(our, GWLP_WNDPROC,
                                           (LONG_PTR)ourProcedure);
    if (!previous) { our = NULL; callback = NULL; return; }

    /* No modifier, so the keys work even when another window is in front. The
 * identifier doubles as the handle. */
    RegisterHotKey(our, MT_TOGGLE, 0, VK_MEDIA_PLAY_PAUSE);
    RegisterHotKey(our, MT_END,    0, VK_MEDIA_STOP);
    RegisterHotKey(our, MT_NEXT,     0, VK_MEDIA_NEXT_TRACK);
    RegisterHotKey(our, MT_BACK,    0, VK_MEDIA_PREV_TRACK);
}

void media_keys_sign_out(void) {
    if (!our) return;
    for (int i = MT_TOGGLE; i <= MT_BACK; i++) UnregisterHotKey(our, i);
    if (previous) SetWindowLongPtrW(our, GWLP_WNDPROC, (LONG_PTR)previous);
    our = NULL; previous = NULL; callback = NULL;
}

#else

/* On Linux, MPRIS handles this. The empty versions keep the call site free
 * of branches. */
void media_keys_sign_in(void *gdk_area, void (*report)(int handle)) { (void)gdk_area; (void)report; }
void media_keys_sign_out(void) {}

#endif
