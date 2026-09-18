import Foundation

/// **Unter welchem Schlüssel ein Bild auf der Platte liegt** — ohne Host und
/// ohne Zugang (Audit Teil 3, #11).
///
/// Derselbe Server ist oft unter zwei Adressen erreichbar (zu Hause,
/// unterwegs), und ein Kontowechsel ändert nur den Zugang. Beides soll
/// dasselbe abgelegte Bild treffen. Übrig bleiben Weg und Abfrage — Kennung,
/// Bildart, Größe und `tag`.
///
/// **Nur mit `tag`.** Das ist Jellyfins Fingerabdruck des Bildes: ändert es
/// sich am Server, ändert sich die Adresse, und der alte Eintrag wird nicht
/// mehr getroffen. Ohne `tag` fiele ein veraltetes Bild nie auf — dann `nil`,
/// und das Bild geht nicht auf die Platte.
///
/// Anders als ``Bildschluessel``, der für den Arbeitsspeicher den Host
/// behält: der lebt nur so lange wie der Programmlauf.
public enum Bildablageschluessel {

    public static func fuer(_ url: URL) -> String? {
        guard let ohneZugang = URL(string: Bildschluessel.fuer(url)),
              var teile = URLComponents(url: ohneZugang, resolvingAgainstBaseURL: false),
              teile.queryItems?.contains(where: { $0.name.lowercased() == "tag" && $0.value?.isEmpty == false }) == true
        else { return nil }
        teile.scheme = nil
        teile.user = nil
        teile.password = nil
        teile.host = nil
        teile.port = nil
        return teile.string
    }
}
