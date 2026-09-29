#include "include/bildbruecke.h"

#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>

/* **Ein Schloss, zwei Systeme.**
 *
 * `pthread` gibt es unter MSVC nicht. Windows hat dafuer den SRWLOCK — ein
 * Lese-Schreib-Schloss, das ohne Aufraeumen auskommt und im unbestrittenen
 * Fall ohne Systemaufruf durchlaeuft. Genau der Fall liegt hier vor: der
 * Dekoderfaden legt ein Bild ab, der Hauptfaden holt es, und beide halten das
 * Schloss nur fuer ein `memcpy`.
 *
 * Die Namen stehen als Makros da, damit der Rest der Datei fuer beide Systeme
 * gleich bleibt — es gibt nur eine Fassung dieser Logik, und die soll auch nur
 * einmal gelesen werden muessen. */
#ifdef _WIN32
  #define WIN32_LEAN_AND_MEAN
  #include <windows.h>
  typedef SRWLOCK Schloss;
  #define SCHLOSS_ANLEGEN(s)  InitializeSRWLock(s)
  #define SCHLOSS_NEHMEN(s)   AcquireSRWLockExclusive(s)
  #define SCHLOSS_GEBEN(s)    ReleaseSRWLockExclusive(s)
  #define SCHLOSS_AUFLOESEN(s) ((void)0)
#else
  #include <pthread.h>
  typedef pthread_mutex_t Schloss;
  #define SCHLOSS_ANLEGEN(s)  pthread_mutex_init((s), NULL)
  #define SCHLOSS_NEHMEN(s)   pthread_mutex_lock(s)
  #define SCHLOSS_GEBEN(s)    pthread_mutex_unlock(s)
  #define SCHLOSS_AUFLOESEN(s) pthread_mutex_destroy(s)
#endif

struct Bildbruecke {
    Schloss  schloss;
    uint8_t *puffer[2];      /* Doppelpuffer */
    size_t   groesse;
    unsigned breite, hoehe;
    int      art;            /* BILDART_* der jetzigen Puffer */
    unsigned ebenen;         /* 1 bei RGB, 2 bei P010, 3 bei I0AL */
    unsigned takt[3];        /* Bytes je Zeile, je Ebene */
    size_t   versatz[3];     /* Beginn jeder Ebene im Puffer */
    int      schreibt;       /* in welchen Puffer VLC gerade schreibt */
    bool     neu;            /* seit dem letzten Holen dazugekommen */
    bool     hdr;            /* Wunsch fuer das naechste Aufbauen */
};

Bildbruecke *bildbruecke_neu(void) {
    Bildbruecke *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    SCHLOSS_ANLEGEN(&b->schloss);
    return b;
}

void bildbruecke_frei(Bildbruecke *b) {
    if (!b) return;
    SCHLOSS_NEHMEN(&b->schloss);
    free(b->puffer[0]);
    free(b->puffer[1]);
    SCHLOSS_GEBEN(&b->schloss);
    SCHLOSS_AUFLOESEN(&b->schloss);
    free(b);
}

void bildbruecke_hdr(Bildbruecke *b, bool hdr) {
    SCHLOSS_NEHMEN(&b->schloss);
    b->hdr = hdr;
    SCHLOSS_GEBEN(&b->schloss);
}

static unsigned auf32(unsigned n) { return (n + 31) & ~31u; }

/* VLC fragt, in welchem Format es liefern soll, und nennt dabei die Maße —
 * und in `chroma` steht beim Aufruf, was der Dekoder selbst liefert.
 *
 * **SDR: RV24**, drei Bytes je Punkt, das nimmt GdkMemoryTexture ohne
 * Umrechnen an. **HDR: YUV zu zehn Bit.** Liefert der Dekoder schon P010
 * (Hardware, zurueckkopiert), bleibt es dabei; sonst I0AL, das der
 * Software-Dekoder fuer HEVC Main 10 ohnehin ausgibt — beides ohne jede
 * Umrechnung auf der CPU. Die Zeilenlaenge ist ein Vielfaches von 32 Bytes,
 * sonst legt VLC intern noch einmal um; die Zeilenzahl wird auf 16
 * aufgerundet, weil VLCs Umrechner in ganzen Bloecken schreiben. */
static unsigned aufbauen(void **opaque, char *chroma,
                         unsigned *breite, unsigned *hoehe,
                         unsigned *takte, unsigned *zeilen) {
    Bildbruecke *b = *opaque;
    unsigned w = *breite, h = *hoehe;
    unsigned cw = (w + 1) / 2, ch = (h + 1) / 2;
    unsigned hz = (h + 15) & ~15u, chz = (ch + 15) & ~15u;

    SCHLOSS_NEHMEN(&b->schloss);
    bool hdr = b->hdr;
    SCHLOSS_GEBEN(&b->schloss);

    int art;
    unsigned ebenen;
    if (!hdr) {
        memcpy(chroma, "RV24", 4);
        art = BILDART_RGB24; ebenen = 1;
        takte[0] = auf32(w * 3); zeilen[0] = h;
    } else if (memcmp(chroma, "P010", 4) == 0) {
        art = BILDART_P010; ebenen = 2;
        takte[0] = auf32(w * 2);  zeilen[0] = hz;
        takte[1] = auf32(cw * 4); zeilen[1] = chz;   /* U und V verschraenkt */
    } else {
        memcpy(chroma, "I0AL", 4);
        art = BILDART_I0AL; ebenen = 3;
        takte[0] = auf32(w * 2);  zeilen[0] = hz;
        takte[1] = auf32(cw * 2); zeilen[1] = chz;
        takte[2] = auf32(cw * 2); zeilen[2] = chz;
    }
    size_t versatz[3] = {0, 0, 0};
    size_t groesse = 0;
    for (unsigned i = 0; i < ebenen; i++) {
        versatz[i] = groesse;
        groesse += (size_t)takte[i] * zeilen[i];
    }

    SCHLOSS_NEHMEN(&b->schloss);
    for (int i = 0; i < 2; i++) {
        free(b->puffer[i]);
        b->puffer[i] = calloc(1, groesse + 64);
    }
    b->groesse = groesse;
    b->breite = w;
    b->hoehe = h;
    b->art = art;
    b->ebenen = ebenen;
    for (unsigned i = 0; i < 3; i++) {
        b->takt[i] = i < ebenen ? takte[i] : 0;
        b->versatz[i] = versatz[i];
    }
    b->schreibt = 0;
    b->neu = false;
    SCHLOSS_GEBEN(&b->schloss);

    return ebenen;
}

static void abbauen(void *opaque) {
    Bildbruecke *b = opaque;
    SCHLOSS_NEHMEN(&b->schloss);
    for (int i = 0; i < 2; i++) { free(b->puffer[i]); b->puffer[i] = NULL; }
    b->groesse = 0;
    b->neu = false;
    SCHLOSS_GEBEN(&b->schloss);
}

/* Vor dem Dekodieren: sagen, wohin geschrieben werden darf. */
static void *sperren(void *opaque, void **ebenen) {
    Bildbruecke *b = opaque;
    SCHLOSS_NEHMEN(&b->schloss);
    for (unsigned i = 0; i < b->ebenen; i++)
        ebenen[i] = b->puffer[b->schreibt] + b->versatz[i];
    return NULL;
}

static void loesen(void *opaque, void *bild, void *const *ebenen) {
    (void)bild; (void)ebenen;
    Bildbruecke *b = opaque;
    SCHLOSS_GEBEN(&b->schloss);
}

/* Nach dem Dekodieren: der geschriebene Puffer wird der sichtbare. */
static void zeigen(void *opaque, void *bild) {
    (void)bild;
    Bildbruecke *b = opaque;
    SCHLOSS_NEHMEN(&b->schloss);
    b->schreibt = 1 - b->schreibt;
    b->neu = true;
    SCHLOSS_GEBEN(&b->schloss);
}

/* ---- VLCs eigene Meldungen ---------------------------------------------
 *
 * **Warum das hier in C steht und nicht in Swift.** `libvlc_log_set` will
 * einen Rueckruf mit `va_list`, und eine Swift-Funktion mit `va_list` laesst
 * sich nicht als `@convention(c)` schreiben -- der Uebersetzer weist es ab.
 * Also wird die Zeile hier fertig formatiert und als einfache Zeichenkette
 * weitergereicht.
 *
 * Nur Warnungen und Fehler (Stufe 3 und 4). VLCs Debugstufe schreibt im
 * Sekundentakt und ertraenkt jedes Protokoll. */
static Spurzeile spur_ziel;

static void spur_rueckruf(void *daten, int stufe, const libvlc_log_t *wo,
                          const char *form, va_list argumente) {
    (void)daten; (void)wo;
    if (stufe < 3 || !spur_ziel) return;
    char puffer[1024];
    vsnprintf(puffer, sizeof puffer, form, argumente);
    spur_ziel(puffer);
}

void vlcspur_an(libvlc_instance_t *kern, Spurzeile ziel) {
    spur_ziel = ziel;
    libvlc_log_set(kern, spur_rueckruf, NULL);
}

void bildbruecke_anhaengen(Bildbruecke *b, libvlc_media_player_t *mp) {
    libvlc_video_set_format_callbacks(mp, aufbauen, abbauen);
    libvlc_video_set_callbacks(mp, sperren, loesen, zeigen, b);
}

bool bildbruecke_holen(Bildbruecke *b, Bildstand *stand) {
    SCHLOSS_NEHMEN(&b->schloss);
    bool da = b->neu && b->groesse > 0;
    if (da) {
        /* Der *nicht* beschriebene Puffer ist der fertige. */
        const uint8_t *fertig = b->puffer[1 - b->schreibt];
        for (unsigned i = 0; i < 3; i++) {
            stand->ebene[i] = i < b->ebenen ? fertig + b->versatz[i] : NULL;
            stand->takt[i] = b->takt[i];
        }
        stand->breite = b->breite;
        stand->hoehe = b->hoehe;
        stand->art = b->art;
        b->neu = false;
    }
    SCHLOSS_GEBEN(&b->schloss);
    return da;
}
