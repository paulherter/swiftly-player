#include "include/schriften.h"

/* Von Hand deklariert statt <fontconfig/fontconfig.h> eingebunden: die
 * Kopfdateien liegen nicht auf jedem Rechner, die Bibliothek aber schon —
 * GTK haengt ohnehin an ihr. Eine Deklaration genuegt, um sie zu rufen. */
extern int FcConfigAppFontAddDir(void *config, const unsigned char *ordner);

int schriften_laden(const char *ordner) {
    if (!ordner || !*ordner) return 0;
    /* 0 als Konfiguration heisst „die laufende" — dieselbe, die GTK benutzt. */
    return FcConfigAppFontAddDir(0, (const unsigned char *)ordner) ? 1 : 0;
}
