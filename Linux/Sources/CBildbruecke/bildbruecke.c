#include "include/bildbruecke.h"

#include <stdlib.h>
#include <string.h>

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
    unsigned breite, hoehe, takt;   /* takt = Bytes je Zeile */
    int      schreibt;       /* in welchen Puffer VLC gerade schreibt */
    bool     neu;            /* seit dem letzten Holen dazugekommen */
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

/* VLC fragt, in welchem Format es liefern soll, und nennt dabei die Maße.
 * RV32 ist BGRX zu 32 Bit — genau das, was GdkMemoryTexture ohne Umrechnen
 * annimmt. Die Zeilenlänge muss ein Vielfaches von 32 Bytes sein, sonst legt
 * VLC intern noch einmal um. */
static unsigned aufbauen(void **opaque, char *chroma,
                         unsigned *breite, unsigned *hoehe,
                         unsigned *takte, unsigned *zeilen) {
    Bildbruecke *b = *opaque;
    memcpy(chroma, "RV24", 4);
    unsigned takt = (*breite * 3 + 31) & ~31u;   /* RV24: drei Bytes je Punkt */
    size_t groesse = (size_t)takt * (*hoehe);

    SCHLOSS_NEHMEN(&b->schloss);
    for (int i = 0; i < 2; i++) {
        free(b->puffer[i]);
        b->puffer[i] = calloc(1, groesse);
    }
    b->groesse = groesse;
    b->breite = *breite;
    b->hoehe = *hoehe;
    b->takt = takt;
    b->schreibt = 0;
    b->neu = false;
    SCHLOSS_GEBEN(&b->schloss);

    takte[0] = takt;
    zeilen[0] = *hoehe;
    return 1;   /* eine Ebene */
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
    ebenen[0] = b->puffer[b->schreibt];
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

void bildbruecke_anhaengen(Bildbruecke *b, libvlc_media_player_t *mp) {
    libvlc_video_set_format_callbacks(mp, aufbauen, abbauen);
    libvlc_video_set_callbacks(mp, sperren, loesen, zeigen, b);
}

bool bildbruecke_holen(Bildbruecke *b, const uint8_t **daten,
                       unsigned *breite, unsigned *hoehe, unsigned *takt) {
    SCHLOSS_NEHMEN(&b->schloss);
    bool da = b->neu && b->groesse > 0;
    if (da) {
        /* Der *nicht* beschriebene Puffer ist der fertige. */
        *daten = b->puffer[1 - b->schreibt];
        *breite = b->breite;
        *hoehe = b->hoehe;
        *takt = b->takt;
        b->neu = false;
    }
    SCHLOSS_GEBEN(&b->schloss);
    return da;
}
