# Fallen: GTK

Vier Zeilen je Falle. **Vor der Arbeit an der GTK-Fassung lesen** — jede hier
hat schon einmal einen Abend gekostet.

---

## Eine Zeichenfläche hält ihren Zeichner nicht

**Symptom** Absturz beim Start oder beim Öffnen eines Titels, oft erst beim
zweiten Mal, oft ohne Protokollzeile.
**Ursache** `set_draw_func` bekommt `self` unretained. Stirbt das Objekt,
während die Fläche noch gezeichnet wird, malt GTK auf freigegebenem Speicher.
**Messung** Über die PDB aufgelöst: `rlottie::Animation::renderSync` auf
freigegebenem Speicher; davor kein Durchgang ohne Fehlstart (3/8, 5/8, 6/8),
danach 30/30 sauber.
**Regel** Jede Fläche hält ihren Zeichner stark und gibt ihn im
`destroy`-Auftrag frei, plus eine `lebt`-Wache im Zeichner. **Alle** Flächen,
nicht nur die auffällige — vier Fälle in einer Fassung sind kein Zufall, und
drei von vier abzusichern ist eine Falle für den Nächsten.

## Eine Schleife, deren Abbruch am Zustand hängt

**Symptom** Die App reagiert auf nichts mehr, ein Kern läuft voll, das
Protokoll wächst um Dutzende MB je Sekunde.
**Ursache** `while let kind = gtk_widget_get_first_child(box) { gtk_box_remove(alsBox(box), kind) }`
— ist der Behälter keine Box, scheitert das Entfernen an der Zusicherung,
entfernt nichts, und dasselbe Kind kommt zurück. Für immer.
**Messung** Hauptfaden `R`, ein voller Kern, 18 GB Protokoll in zwei Stunden.
**Regel** Die Bedingung prüft den **Fortschritt**, nicht das Vorhandensein.
`gtk_widget_unparent` trägt für jedes Widget — damit entsteht der Fehlerfall
gar nicht. Und: ein blinder Cast (`alsBox`, `alsTafel`) ist immer ein
Verdächtiger.

## Erst der zweite Durchlauf hängt

**Symptom** Etwas funktioniert im Test und fällt beim Benutzer um.
**Ursache** Beim ersten Aufruf ist der Behälter leer, die Schleife läuft gar
nicht; sie braucht ein Kind, das schon drinsteht.
**Regel** Wer eine Schleife oder einen Zwischenspeicher prüft, ruft sie
**zweimal**. Einmal beweist nichts.

## Popover ohne Elternteil

**Symptom** `Finalizing GtkButton, but it still has children left: GtkPopover`
**Regel** Tafeln über `tafelAn(...)` anlegen — die hängt sie an und bestellt
das Lösen im selben Atemzug.

## Ein Übergang, dessen Kind im selben Zug entfernt wird

**Symptom** Die Animation ist gebaut und war nie zu sehen.
**Ursache** `UNDER_DOWN` über 350 ms gesetzt und das Kind unmittelbar danach
entfernt — ein abgehängtes Widget bekommt keine Striche mehr.
**Messung** Nach der Behebung: bei 143 ms sitzt der Player sichtbar tiefer,
bei 276 ms steht nur noch ein Streifen.
**Regel** Wer einen Übergang setzt, prüft am Bild, dass er läuft. Ein
Kommentar, der ihn beschreibt, ist kein Beleg.

## Der Ladevorgang hängt nicht am Widget

**Symptom** Ein Bild kommt an, nachdem seine Seite weg ist — `Gtk-CRITICAL`
in `gtk_widget_queue_draw`.
**Regel** Das ist die Kehrseite der ersten Falle und meist ein **Vorteil**:
weil der Abruf weiterläuft, gibt es hier kein Gegenstück zu `AsyncImage`s
`-999`. Wer davon ausgeht, muss das Widget trotzdem halten.
