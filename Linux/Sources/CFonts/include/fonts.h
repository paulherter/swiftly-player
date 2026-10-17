#ifndef SCHRIFTEN_H
#define SCHRIFTEN_H

/* **Register the bundled font.**
 *
 * On the Mac the UI font is SF Pro, which exists only there. Inter is its
 * closest relative and ships with the app; on Linux it is often already
 * installed, on Windows never. Without registration the UI would fall back to
 * Segoe UI there and look different from the Mac.
 *
 * Registration goes through fontconfig, for this process only:
 * `FcConfigAppFontAddDir` stores nothing in the system and needs no
 * privileges. Pango uses fontconfig on both platforms; on Windows the app
 * aborts at the first window without `etc\fonts`.
 *
 * Returns 1 if the directory was accepted. Otherwise 0, and the system font
 * stays; a cosmetic flaw, not a reason to stop.
 */
int fonts_load(const char *folder);

#endif
