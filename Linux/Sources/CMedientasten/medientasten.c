#include "include/medientasten.h"

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* Aus GTK. Von Hand deklariert, damit dieser Teil nicht die GDK-Kopfdateien
 * einbinden muss — die zoegen `windows.h` in jede Uebersetzungseinheit. */
extern void *gdk_win32_surface_get_handle(void *flaeche);

static WNDPROC vorherige;
static HWND    unser;
static void  (*rueckruf)(int);

/* Die eigene Fensterprozedur. Alles, was uns nicht angeht, geht unverändert
 * an die vorherige weiter — sonst hört GTK auf zu arbeiten. */
static LRESULT CALLBACK unsereProzedur(HWND h, UINT n, WPARAM w, LPARAM l) {
    if (n == WM_HOTKEY && rueckruf) {
        rueckruf((int)w);
        return 0;
    }
    if (n == WM_APPCOMMAND && rueckruf) {
        switch (GET_APPCOMMAND_LPARAM(l)) {
            case APPCOMMAND_MEDIA_PLAY_PAUSE: rueckruf(MT_UMSCHALTEN); return TRUE;
            case APPCOMMAND_MEDIA_PLAY:       rueckruf(MT_UMSCHALTEN); return TRUE;
            case APPCOMMAND_MEDIA_PAUSE:      rueckruf(MT_UMSCHALTEN); return TRUE;
            case APPCOMMAND_MEDIA_STOP:       rueckruf(MT_BEENDEN);    return TRUE;
            case APPCOMMAND_MEDIA_NEXTTRACK:  rueckruf(MT_WEITER);     return TRUE;
            case APPCOMMAND_MEDIA_PREVIOUSTRACK: rueckruf(MT_ZURUECK); return TRUE;
            default: break;
        }
    }
    return CallWindowProcW(vorherige, h, n, w, l);
}

void medientasten_anmelden(void *gdk_flaeche, void (*melden)(int griff)) {
    if (!gdk_flaeche || unser) return;
    HWND h = (HWND)gdk_win32_surface_get_handle(gdk_flaeche);
    if (!h) return;
    unser = h;
    rueckruf = melden;

    vorherige = (WNDPROC)SetWindowLongPtrW(unser, GWLP_WNDPROC,
                                           (LONG_PTR)unsereProzedur);
    if (!vorherige) { unser = NULL; rueckruf = NULL; return; }

    /* Ohne Zusatztaste, damit die Tasten auch dann gelten, wenn ein anderes
     * Fenster vorn ist. Die Kennung ist zugleich der Griff. */
    RegisterHotKey(unser, MT_UMSCHALTEN, 0, VK_MEDIA_PLAY_PAUSE);
    RegisterHotKey(unser, MT_BEENDEN,    0, VK_MEDIA_STOP);
    RegisterHotKey(unser, MT_WEITER,     0, VK_MEDIA_NEXT_TRACK);
    RegisterHotKey(unser, MT_ZURUECK,    0, VK_MEDIA_PREV_TRACK);
}

void medientasten_abmelden(void) {
    if (!unser) return;
    for (int i = MT_UMSCHALTEN; i <= MT_ZURUECK; i++) UnregisterHotKey(unser, i);
    if (vorherige) SetWindowLongPtrW(unser, GWLP_WNDPROC, (LONG_PTR)vorherige);
    unser = NULL; vorherige = NULL; rueckruf = NULL;
}

#else

/* Auf Linux erledigt das MPRIS. Die leeren Fassungen halten die Aufrufstelle
 * frei von Verzweigungen. */
void medientasten_anmelden(void *gdk_flaeche, void (*melden)(int griff)) { (void)gdk_flaeche; (void)melden; }
void medientasten_abmelden(void) {}

#endif
