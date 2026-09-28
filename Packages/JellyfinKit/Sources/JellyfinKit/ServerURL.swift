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
            // Eine nackte IPv6-Adresse braucht Klammern, sonst liest `URL`
            // ihre Doppelpunkte als Port und findet keinen Rechner.
            if istIPv6(text) { text = "[" + text + "]" }
            text = (istImHeimnetz(text) ? "http://" : "https://") + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    /// **Eine serverrelative Angabe an die Serveradresse hängen — mit deren
    /// Pfad.**
    ///
    /// Jellyfin nennt `TranscodingUrl` und `DeliveryUrl` als Pfad mit
    /// führendem Schrägstrich („/videos/…/master.m3u8"), ohne den Unterpfad,
    /// unter dem ein Reverse-Proxy den Server veröffentlicht. `URL(string:
    /// relativeTo:)` löst einen solchen Pfad nach RFC 3986 gegen die
    /// **Wurzel** des Rechners auf: aus `https://h.de/jellyfin` wurde
    /// `https://h.de/videos/…` — am Proxy ein 404. Externe Untertitel fehlten
    /// dann, und jede umgepackte Wiedergabe (AirPlay, Bitratengrenze) blieb
    /// schwarz. Mit IP und Port ohne Unterpfad fällt das nie auf
    /// (jellyfin/Swiftfin#1695). Die Abspieladresse selbst ging schon immer
    /// über `appendingPathComponent` und war nicht betroffen.
    ///
    /// Eine vollständige Adresse (externe Untertitel mit `IsExternalUrl`)
    /// bleibt, wie sie ist.
    public static func serverrelativ(_ angabe: String, basis: URL) -> URL? {
        if let voll = URL(string: angabe), voll.scheme != nil { return voll }
        guard let rel = URLComponents(string: angabe),
              var teile = URLComponents(url: basis, resolvingAgainstBaseURL: false)
        else { return nil }
        var vorne = teile.percentEncodedPath
        while vorne.hasSuffix("/") { vorne.removeLast() }
        var hinten = rel.percentEncodedPath
        while hinten.hasPrefix("/") { hinten.removeFirst() }
        teile.percentEncodedPath = vorne + "/" + hinten
        teile.percentEncodedQuery = rel.percentEncodedQuery
        teile.fragment = nil
        return teile.url
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
        // **IPv6-Literal**, mit Klammern („[fd00::5]:8096") oder ohne, wie
        // `URL.host()` es liefert. Gilt wie jedes IP-Literal als Heimnetz —
        // bisher nur zufaellig: der Schnitt am ersten Doppelpunkt liess
        // „fd00" stehen, und ein Name ohne Punkt ist ein Rechnername.
        if name.hasPrefix("["), let zu = name.firstIndex(of: "]") {
            return istIPv6(String(name[name.index(after: name.startIndex) ..< zu]))
        }
        if istIPv6(name) { return true }
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

    /// Sieht der Text aus wie eine IPv6-Adresse? Mindestens zwei Doppelpunkte,
    /// sonst nur Hexziffern und Punkte (fuer „::ffff:1.2.3.4"); eine Zone
    /// („fe80::1%en0") wird vorher abgeschnitten.
    static func istIPv6(_ text: String) -> Bool {
        let ohneZone = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        guard ohneZone.filter({ $0 == ":" }).count >= 2 else { return false }
        return ohneZone.allSatisfy { $0 == ":" || $0 == "." || $0.isHexDigit }
    }
}
