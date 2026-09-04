#include "include/bildbruecke.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct Bildbruecke {
    pthread_mutex_t schloss;
    uint8_t *puffer[2];      /* Doppelpuffer */
    size_t   groesse;
    unsigned breite, hoehe, takt;   /* takt = Bytes je Zeile */
    int      schreibt;       /* in welchen Puffer VLC gerade schreibt */
    bool     neu;            /* seit dem letzten Holen dazugekommen */
};

Bildbruecke *bildbruecke_neu(void) {
    Bildbruecke *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    pthread_mutex_init(&b->schloss, NULL);
    return b;
}

void bildbruecke_frei(Bildbruecke *b) {
    if (!b) return;
    pthread_mutex_lock(&b->schloss);
    free(b->puffer[0]);
    free(b->puffer[1]);
    pthread_mutex_unlock(&b->schloss);
    pthread_mutex_destroy(&b->schloss);
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

    pthread_mutex_lock(&b->schloss);
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
    pthread_mutex_unlock(&b->schloss);

    takte[0] = takt;
    zeilen[0] = *hoehe;
    return 1;   /* eine Ebene */
}

static void abbauen(void *opaque) {
    Bildbruecke *b = opaque;
    pthread_mutex_lock(&b->schloss);
    for (int i = 0; i < 2; i++) { free(b->puffer[i]); b->puffer[i] = NULL; }
    b->groesse = 0;
    b->neu = false;
    pthread_mutex_unlock(&b->schloss);
}

/* Vor dem Dekodieren: sagen, wohin geschrieben werden darf. */
static void *sperren(void *opaque, void **ebenen) {
    Bildbruecke *b = opaque;
    pthread_mutex_lock(&b->schloss);
    ebenen[0] = b->puffer[b->schreibt];
    return NULL;
}

static void loesen(void *opaque, void *bild, void *const *ebenen) {
    (void)bild; (void)ebenen;
    Bildbruecke *b = opaque;
    pthread_mutex_unlock(&b->schloss);
}

/* Nach dem Dekodieren: der geschriebene Puffer wird der sichtbare. */
static void zeigen(void *opaque, void *bild) {
    (void)bild;
    Bildbruecke *b = opaque;
    pthread_mutex_lock(&b->schloss);
    b->schreibt = 1 - b->schreibt;
    b->neu = true;
    pthread_mutex_unlock(&b->schloss);
}

void bildbruecke_anhaengen(Bildbruecke *b, libvlc_media_player_t *mp) {
    libvlc_video_set_format_callbacks(mp, aufbauen, abbauen);
    libvlc_video_set_callbacks(mp, sperren, loesen, zeigen, b);
}

bool bildbruecke_holen(Bildbruecke *b, const uint8_t **daten,
                       unsigned *breite, unsigned *hoehe, unsigned *takt) {
    pthread_mutex_lock(&b->schloss);
    bool da = b->neu && b->groesse > 0;
    if (da) {
        /* Der *nicht* beschriebene Puffer ist der fertige. */
        *daten = b->puffer[1 - b->schreibt];
        *breite = b->breite;
        *hoehe = b->hoehe;
        *takt = b->takt;
        b->neu = false;
    }
    pthread_mutex_unlock(&b->schloss);
    return da;
}
