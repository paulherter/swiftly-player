import Foundation

/// Macht aus Nutzereingaben wie „tv.beispiel.de" oder „192.168.1.5:8096" eine
/// brauchbare Basis-URL.
public enum AppModelURLNormalizer {

    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            // Kein Schema angegeben: raten, und zwar richtig herum.
            //
            // Vorher wurde immer `https` angenommen. Der überwiegende Teil
            // selbst gehosteter Jellyfin-Server läuft aber im Heimnetz unter
            // einer IP ohne Zertifikat — wer die Adresse ohne Schema eintippt,
            // bekam einen Fehler, dessen Ursache nicht zu erraten ist.
            text = (istImHeimnetz(text) ? "http://" : "https://") + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    /// Dieselbe Adresse mit dem jeweils anderen Schema — für den zweiten
    /// Versuch, wenn der erste an der Verbindung scheitert.
    ///
    /// `nil`, wenn schon `http` steht: dorthin auszuweichen wäre kein
    /// Ausweichen, und ein Rückschritt auf unverschlüsselt darf nie
    /// automatisch geschehen, wenn der Nutzer `https` verlangt hat.
    public static func andersHerum(_ url: URL) -> URL? {
        guard url.scheme == "https" else { return nil }
        var teile = URLComponents(url: url, resolvingAgainstBaseURL: false)
        teile?.scheme = "http"
        return teile?.url
    }

    /// Adressen, bei denen ein Zertifikat unwahrscheinlich ist: IP-Literale,
    /// `.local`, `.lan`, `.home`, `.internal` und nackte Rechnernamen ohne Punkt.
    public static func istImHeimnetz(_ text: String) -> Bool {
        // Vor einem etwaigen Port und Pfad abschneiden.
        let name = text.split(separator: "/").first.map(String.init) ?? text
        let ohnePort = name.split(separator: ":").first.map(String.init) ?? name
        let klein = ohnePort.lowercased()

        if klein.hasSuffix(".local") || klein.hasSuffix(".lan")
            || klein.hasSuffix(".home") || klein.hasSuffix(".internal")
            || klein == "localhost" {
            return true
        }
        // Ein Name ohne Punkt ist ein Rechnername im eigenen Netz.
        if !klein.contains(".") { return true }
        // IPv4-Literal.
        let teile = klein.split(separator: ".", omittingEmptySubsequences: false)
        if teile.count == 4, teile.allSatisfy({ stueck in
            !stueck.isEmpty && stueck.allSatisfy(\.isNumber) && (Int(stueck) ?? 256) < 256
        }) {
            return true
        }
        return false
    }
}
