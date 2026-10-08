#ifndef HDRBILD_H
#define HDRBILD_H

#include <stdbool.h>
#include "bildbruecke.h"

/* **HDR auf einem SDR-Bildschirm, auf der Grafikkarte gerechnet.**
 *
 * libVLC 3 bildet HDR nur in seiner eigenen OpenGL-Ausgabe auf SDR ab
 * (`--tone-mapping`, ueber libplacebo). Wir zeichnen aber selbst, ueber die
 * Rohbild-Rueckrufe in `bildbruecke.c` — dort rechnet VLC mit swscale nach
 * RGB und laesst die Kennlinie, wie sie ist. PQ-Werte als sRGB gezeigt sind
 * genau das flaue, blasse Bild.
 *
 * Deshalb kommt das HDR-Bild hier als YUV zu zehn Bit an und wird in einem
 * Shader umgerechnet, fuer jeden Bildpunkt:
 *
 *   YUV (BT.2020, begrenzter Umfang) → R'G'B'
 *   → linear in Nits (PQ nach SMPTE ST 2084, HLG nach BT.2100 mit OOTF)
 *   → Tonemapping nach BT.2390 (EETF) auf die SDR-Weisse von 203 Nits
 *   → BT.2020 → BT.709 → Gamma 2.2
 *
 * Das ist dieselbe Kette, die mpv ueber libplacebo geht. Auf der CPU waere sie
 * fuer 4K zu langsam; hier kostet sie die Grafikkarte fast nichts, und die
 * Umrechnung nach RGB, die VLC sonst auf der CPU machte, faellt weg.
 *
 * Alle Funktionen ausser `hdrbild_neu`/`hdrbild_frei` erwarten einen
 * aktuellen GL-Kontext (GtkGLArea). Die GL-Objekte entstehen beim ersten
 * Gebrauch; `es` sagt, ob der Kontext OpenGL ES ist (anderer Shaderkopf). */

typedef struct Hdrbild Hdrbild;

/* Kennlinien — dieselben Faelle wie `Farbumfang.Kennlinie` im Paket. */
enum { HDRBILD_PQ = 1, HDRBILD_HLG = 2 };

Hdrbild *hdrbild_neu(void);
void hdrbild_frei(Hdrbild *h);

/* Uebersetzt die Shader. false heisst: dieser Kontext kann es nicht —
 * dann bleibt es beim RGB-Weg. Der Grund steht in `hdrbild_fehler`. */
bool hdrbild_einrichten(Hdrbild *h, bool es);
const char *hdrbild_fehler(const Hdrbild *h);

/* Laedt ein Bild der Art I0AL oder P010 in die Texturen. */
bool hdrbild_hochladen(Hdrbild *h, const Bildstand *stand, bool es);

/* Zeichnet in den gebundenen Rahmenpuffer der Groesse breite × hoehe
 * (Geraetepunkte). `fuellen`: formatfuellend statt ganz. `spitze`: die
 * hellste Stelle des Materials in Nits (ohne Angabe 1000). */
bool hdrbild_zeichnen(Hdrbild *h, int breite, int hoehe, bool fuellen,
                      int kennlinie, float spitze, bool es);

/* Gibt die GL-Objekte frei — vor dem Abbau des Kontexts. */
void hdrbild_aufgeben(Hdrbild *h);

/* Hersteller, Geraet und Fassung des gerade aktuellen GL-Kontexts, fuer die
 * Startzeile im Protokoll. Ein fester Puffer, nur vom Hauptfaden zu rufen. */
const char *hdrbild_gl_auskunft(void);

#endif
