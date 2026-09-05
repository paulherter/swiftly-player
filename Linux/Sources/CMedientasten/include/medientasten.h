#ifndef MEDIENTASTEN_H
#define MEDIENTASTEN_H

/* **Die Medientasten der Tastatur unter Windows.**
 *
 * Auf Linux gibt es dafür einen Standard auf dem Sitzungsbus — MPRIS —, und
 * die Arbeitsumgebung bindet ihre Tasten daran. Windows kennt das nicht: dort
 * schickt das System `WM_APPCOMMAND` an das Vordergrundfenster, und wer die
 * Tasten auch im Hintergrund haben will, meldet sie über `RegisterHotKey` an.
 * Beides braucht ein Fensterhandle und eine eigene Fensterprozedur, und beides
 * gibt es in Swift nicht ohne Weiteres.
 *
 * Deshalb hier, und deshalb still im Fehlerfall: schlägt die Anmeldung fehl —
 * weil ein anderes Programm die Taste schon hält —, läuft die App weiter, nur
 * ohne Tasten. Das ist kein Grund, irgendetwas anzuhalten.
 */

/* Dieselben Griffe wie in `Medienleiste.Griff`, in derselben Reihenfolge. */
enum { MT_UMSCHALTEN = 0, MT_BEENDEN = 1, MT_WEITER = 2, MT_ZURUECK = 3 };

/* Meldet die Tasten für die Fensterfläche an — übergeben wird die `GdkSurface`
 * des Fensters, nicht das Handle: die Umrechnung bleibt hier, damit
 * `windows.h` nicht durch die Swift-Seite muss.
 *
 * `melden` wird auf dem Faden des Fensters gerufen — demselben, auf dem GTK
 * arbeitet. */
void medientasten_anmelden(void *gdk_flaeche, void (*melden)(int griff));
void medientasten_abmelden(void);

#endif
