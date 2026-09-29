#ifndef BILDBRUECKE_H
#define BILDBRUECKE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <vlc/vlc.h>

/* **Die Brücke zwischen VLCs Dekoderfaden und GTKs Hauptfaden.**
 *
 * libVLC 3 kennt `libvlc_video_set_output_callbacks` noch nicht — das kam
 * erst mit VLC 4. Was es gibt, sind Rohbild-Rückrufe: VLC schreibt jedes
 * Bild in einen Speicher, den wir stellen. Genau das tut diese Datei.
 *
 * **Warum C und nicht Swift.** Die Rückrufe laufen auf VLCs Dekoderfaden,
 * mehrmals je Sekunde, und teilen sich einen Puffer mit dem Hauptfaden. Das
 * ist genau die Sorte gemeinsam genutzter veränderlicher Zustand, die Swift 6
 * zu Recht verbietet — man käme nur mit `@unchecked Sendable` und einem
 * eigenen Schloss durch, also mit einer Zusicherung, die nichts prüft. In C
 * steht das Schloss sichtbar da, und die Grenze zu Swift ist eine einzige
 * Funktion, die ein fertiges Bild herausgibt.
 *
 * Zwei Puffer: VLC füllt den einen, während der andere gezeichnet wird.
 */

typedef struct Bildbruecke Bildbruecke;

Bildbruecke *bildbruecke_neu(void);
void bildbruecke_frei(Bildbruecke *b);

/* Hängt die Brücke an einen Player. Muss vor dem Start geschehen. */
/* Eine fertig formatierte Meldung von libVLC. Laeuft auf VLCs Faden. */
typedef void (*Spurzeile)(const char *);

/* Leitet libVLCs Warnungen und Fehler an `ziel`. NULL schaltet sie ab. */
void vlcspur_an(libvlc_instance_t *kern, Spurzeile ziel);

void bildbruecke_anhaengen(Bildbruecke *b, libvlc_media_player_t *mp);

/* **Welche Form ein Bild hat.** RGB ist der Weg fuer SDR: VLC rechnet selbst
 * nach RGB, und GTK zeigt es als Speichertextur. Fuer HDR bleibt das Bild,
 * wie der Dekoder es liefert — YUV zu zehn Bit —, und der Shader in
 * `hdrbild.c` rechnet es um. VLCs eigene Umrechnung nach RGB kennt weder
 * PQ noch HLG, genau daher kam das ausgewaschene Bild. */
enum {
    BILDART_RGB24 = 0,   /* RV24, eine Ebene */
    BILDART_I0AL  = 1,   /* YUV 4:2:0, 10 Bit in 16, niedrige Bits, drei Ebenen */
    BILDART_P010  = 2    /* YUV 4:2:0, 10 Bit in 16, hohe Bits, Y + UV verschraenkt */
};

typedef struct {
    const uint8_t *ebene[3];
    unsigned takt[3];          /* Bytes je Zeile */
    unsigned breite, hoehe;    /* sichtbare Masse des Bildes */
    int art;                   /* BILDART_* */
} Bildstand;

/* Vor dem Start: soll VLC YUV zu zehn Bit liefern (HDR) oder RGB (SDR)? */
void bildbruecke_hdr(Bildbruecke *b, bool hdr);

/* Holt das jüngste Bild. Gibt false zurück, wenn seit dem letzten Aufruf
 * keines dazugekommen ist — dann ist nichts zu tun.
 * Die Zeiger bleiben bis zum nächsten Aufruf gültig. */
bool bildbruecke_holen(Bildbruecke *b, Bildstand *stand);

#endif
