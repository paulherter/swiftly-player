# Fallen: SwiftUI

Vier Zeilen je Falle. **Vor der Arbeit an einer Apple-Ansicht lesen.**

---

## `AsyncImage` bricht ab und versucht danach nichts mehr

**Symptom** Nach einem Kontowechsel bleiben Kacheln grau — besonders beim
zweiten Hin und Her.
**Ursache** Geht die Kachel vom Schirm, bricht der Abruf ab; die Ansicht
bleibt im Fehlerzustand stehen. Kommt dieselbe Kachel zurück, passiert nichts.
**Messung** `NSURLErrorDomain -999` zwanzigmal in Folge, während derselbe
Aufruf von aussen HTTP 200 und 158 KB lieferte.
**Regel** `Netzbild` benutzen: es lädt in einer Aufgabe, die **nicht** am Leben
der Kachel hängt, und entschlüsselt abseits des Zeichenlaufs. Damit fällt der
Anlaufzähler ersatzlos weg.

## `.task(id:)` an einer Kennung, die sich nicht ändert

**Symptom** Nach einem Kontowechsel steht auf offenen Seiten der Sehstand des
vorigen Kontos; ein Druck auf Abspielen setzt an fremder Stelle an.
**Ursache** `DetailView` hängt an `titel.id`, `SerienView` an der Staffel,
`SucheView` am Begriff — keine davon ändert sich beim Wechsel.
**Regel** `VERHALTEN.md` G4: der Seitenstapel wird geleert (Profilseite
ausgenommen). Nicht jede Seite einzeln nachrüsten — die nächste vergisst es.

## Vorher leeren statt ersetzen

**Symptom** Zucken, Sprünge, ausbleibende Bilder beim Neuladen.
**Ursache** `views = []` oder `reihe = []` vor dem Abruf hängt jede Kachel für
die Dauer der Abfrage aus.
**Regel** Ersetzen, wenn das Neue da ist. Was stehenbleibt, ist für den
Bruchteil einer Sekunde veraltet — das ist billiger als ein Neuaufbau.

## `disabled` legt einen Schleier

**Symptom** Ausgerechnet das hervorgehobene Element sieht blass aus.
**Ursache** Das aktive Konto als `disabled` markiert, weil es dort nichts
umzuschalten gibt — SwiftUI dunkelt gesperrte Knöpfe ab.
**Regel** Nicht schaltbar heisst nicht gesperrt. Den Druck ins Leere laufen
lassen, statt den Knopf zu sperren.

## Gestapelte Kreise brauchen `zIndex`

**Symptom** Der *nicht* verbundene Kreis liegt oben.
**Ursache** Ein `HStack` mit negativem Abstand zeichnet in der Reihenfolge der
Auslage.

## `@State` für etwas, das die Ansicht überlebt

**Symptom** Zwei Fenster, zwei Anmeldungen; oder Zustand, der beim Zurückholen
verschwindet.
**Ursache** `AppModel` liegt als `@State` in `RootView` — jedes weitere Fenster
bekäme ein eigenes.
**Regel** Solange das so ist, kann die Mac-Fassung **kein** zweites Fenster.
Wer eines will, hebt `AppModel` vorher heraus.

## Ein Kommentar, der über seinem Typ steht, gehört ihm

**Symptom** Nach dem Einfügen eines neuen Typs hängt die Beschreibung am
falschen.
**Regel** Beim Einfügen zwischen Kommentar und Typ nachsehen. Zweimal an einem
Tag passiert, beide Male ohne dass ein Bau es bemerkt hätte.
