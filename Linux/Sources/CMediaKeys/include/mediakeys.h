#ifndef MEDIENTASTEN_H
#define MEDIENTASTEN_H

/* **Keyboard media keys on Windows.**
 *
 * On Linux there is a standard for this on the session bus, MPRIS, and the
 * desktop environment binds its keys to it. Windows has no such thing: the
 * system sends `WM_APPCOMMAND` to the foreground window, and an app that
 * wants the keys in the background registers them via `RegisterHotKey`.
 * Both need a window handle and a custom window procedure, which Swift
 * cannot easily provide.
 *
 * Hence this C code, and hence silent failure: if registration fails
 * because another program already holds the key, the app keeps running,
 * just without the keys.
 */

/* Same handles as `MediaBar.Handle`, in the same order. */
enum { MT_TOGGLE = 0, MT_END = 1, MT_NEXT = 2, MT_BACK = 3,
       /* No keys, but the same path: Windows reports suspend and resume as
        * WM_POWERBROADCAST to the same window procedure. */
       MT_SLEEPS = 4, MT_WOKE = 5 };

/* Registers the keys for the window surface. Takes the window's
 * `GdkSurface`, not the handle: the conversion stays here so that
 * `windows.h` does not leak into the Swift side.
 *
 * `report` is called on the window's thread, the one GTK runs on. */
void media_keys_sign_in(void *gdk_area, void (*report)(int handle));
void media_keys_sign_out(void);

#endif
