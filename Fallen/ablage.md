# Fallen: Ablage und Anmeldung

Was gespeichert wird, überlebt die Fassung, die es geschrieben hat. **Diese
Datei vor jeder Änderung an Formaten, Schlüsseln oder Namen lesen.**

---

## Der Schlüsselbund kennt das Programm an seiner Signatur

**Symptom** Auf dem Mac wird eine Einstellung nicht mehr gemerkt; Lesen geht,
Schreiben nicht, und der Fehler verschwindet in einem `catch`.
**Ursache** Der dateibasierte Schlüsselbund hängt das **Änderungsrecht** an
die Signatur des Programms, das den Eintrag angelegt hat. Nach einer
Umbenennung (`Swiftly-macOS` → `Swiftly`) ist es ein anderes.
**Messung** `errSecDuplicateItem`; letzter erfolgreicher Schreibvorgang
19:48:54, Umbenennung 20:32. Derselbe Eintrag unter frischem Namen liess sich
sehr wohl anlegen.
**Regel** `kSecUseDataProtectionKeychain` — dort gilt die Zugriffsgruppe aus
den Entitlements. Beim Umzug in einen anderen Speicher: einmal aus dem alten
lesen und hinüberschreiben, **und `delete` in beiden Speichern räumen**, sonst
holt der Umzug eine gelöschte Anmeldung zurück.

## Ein Format wird übersetzt, nicht durchgereicht

**Symptom** Nach dem Aktualisieren steht der Benutzer vor dem Anmeldeschirm.
Auf keinem Entwicklungsrechner zu sehen.
**Ursache** Die alte Ablage trägt andere Feldnamen (`token`, `benutzerID`) als
der Typ, der sie lesen soll (`accessToken`, `userID`). `try?` verschluckt es,
die Übernahme liefert `nil`.
**Regel** Wo ein Format über die Zeit trägt, steht die Umsetzung im Paket und
hat einen Test — **mit wörtlichem JSON**. Ein Test, der frisch kodiert und
wieder dekodiert, prüft nur, dass unser Kodierer zu unserem Dekodierer passt,
und geht bei einer Umbenennung stillschweigend mit.

## Wer schon umgestellt ist, sieht den Fehler nie

**Symptom** Ein Fehler, der jeden bestehenden Nutzer trifft, und niemanden im
Team.
**Ursache** Der Übergangsweg wird nur beim **ersten** Start nach dem Sprung
genommen. Wer die neue Ablage schon hat, geht ihn nie.
**Regel** Den Aktualisierungsfall ausdrücklich herstellen: neue Ablage
beiseite, alte hinlegen, starten. Gefunden wurde es am 05.09. nur, weil eine
Prüfmaschine zufällig den alten Stand trug.

## Das Prüfkriterium kann falsch sein

**Symptom** Ein richtiger Fix wird wieder ausgebaut, weil die Prüfung ihn
nicht bestätigt.
**Ursache** Auf ein neu geschriebenes `konten.json` geprüft — das schreibt die
App beim Start aus der alten Ablage aber gar nicht.
**Regel** Vor der Messung fragen, woran man den Erfolg **erkennen** würde. Die
CPU-Last hat es hier beantwortet: mit Sitzung läuft die Fernsteuerung, ohne
nicht.
