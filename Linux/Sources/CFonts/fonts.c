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
