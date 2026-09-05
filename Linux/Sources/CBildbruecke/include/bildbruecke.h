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
void bildbruecke_anhaengen(Bildbruecke *b, libvlc_media_player_t *mp);

/* Holt das jüngste Bild. Gibt false zurück, wenn seit dem letzten Aufruf
 * keines dazugekommen ist — dann ist nichts zu tun.
 * Der Zeiger bleibt bis zum nächsten Aufruf gültig. */
bool bildbruecke_holen(Bildbruecke *b, const uint8_t **daten,
                       unsigned *breite, unsigned *hoehe, unsigned *takt);

#endif
