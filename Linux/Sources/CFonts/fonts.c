#include "include/fonts.h"

/* Declared by hand instead of including <fontconfig/fontconfig.h>: the
 * headers are not on every machine, but the library is (GTK depends on it).
 * A declaration is enough to call it. */
extern int FcConfigAppFontAddDir(void *config, const unsigned char *folder);

int fonts_load(const char *folder) {
    if (!folder || !*folder) return 0;
    /* A config of 0 means "the current one", the same GTK uses. */
    return FcConfigAppFontAddDir(0, (const unsigned char *)folder) ? 1 : 0;
}

/* The font map is created before our folder is added and keeps what it saw
 * then. Without telling it, the bundled font is registered but never found.
 * The function lives in libpangoft2; it is looked up at run time so neither
 * platform needs another link library. */
#ifdef _WIN32
#include <windows.h>
static void *lookup(const char *name) {
    HMODULE m = GetModuleHandleA("pangoft2-1.0-0.dll");
    if (!m) m = LoadLibraryA("pangoft2-1.0-0.dll");
    return m ? (void *)GetProcAddress(m, name) : 0;
}
#else
#define _GNU_SOURCE
#include <dlfcn.h>
static void *lookup(const char *name) { return dlsym(RTLD_DEFAULT, name); }
#endif

int fonts_announce(void *fontmap) {
    if (!fontmap) return 0;
    void (*changed)(void *) = (void (*)(void *))lookup("pango_fc_font_map_config_changed");
    if (!changed) return 0;
    changed(fontmap);
    return 1;
}

/* How many fonts the application set of the current fontconfig holds. */
extern void *FcConfigGetFonts(void *config, int set);
extern int FcFontSetCount(void *set);
int fonts_count(void) {
    void *set = FcConfigGetFonts(0, 1);
    return set ? *(int *)set : -1;   /* FcFontSet starts with nfont */
}
