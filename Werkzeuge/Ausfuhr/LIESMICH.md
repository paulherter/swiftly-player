# Ausfuhr

Die drei `ExportOptions.plist` für den App-Store-Bau.

**Warum sie hier liegen und nicht in `build/`.** Dort standen sie bis zum
12.09.2026 — in einem Ordner, der in `.gitignore` steht und jederzeit
weggeräumt werden darf. Sie sind aber keine Bauausgabe, sondern von Hand
geschriebene Einstellungen: Team, Signierart, Symbole hochladen, und vor allem
`manageAppVersionAndBuildNumber: false`. Ohne den Eintrag setzt Xcode die
Baunummer beim Ausleiten selbst und überschreibt, was in `project.yml` steht.

Wer `build/` löscht, verliert sie sonst und merkt es erst, wenn der nächste
Bau nicht mehr hochgeht.

Benutzt werden sie von `Notizen/Werkzeuge/Store/store.mjs`.
