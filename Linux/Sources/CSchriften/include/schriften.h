#ifndef SCHRIFTEN_H
#define SCHRIFTEN_H

/* **Die mitgelieferte Schrift anmelden.**
 *
 * Auf dem Mac ist die Schrift der Oberfläche SF Pro; die gibt es nur dort.
 * Inter ist ihr nächster Verwandter und liegt der App bei — auf Linux ist sie
 * oft schon installiert, unter Windows nie. Ohne Anmeldung fiele die
 * Oberfläche dort auf Segoe UI zurück und sähe anders aus als auf dem Mac.
 *
 * Angemeldet wird über fontconfig, und zwar nur für diesen einen Prozess:
 * `FcConfigAppFontAddDir` legt nichts im System ab und braucht keine Rechte.
 * Pango benutzt fontconfig auf beiden Plattformen — unter Windows ist das
 * nachgemessen, die App bricht ohne `etc\fonts` beim ersten Fenster ab.
 *
 * Gibt 1 zurück, wenn der Ordner angenommen wurde. Sonst 0, und dann bleibt
 * es bei der Schrift des Systems — ein Schönheitsfehler, kein Grund
 * anzuhalten.
 */
int schriften_laden(const char *ordner);

#endif
