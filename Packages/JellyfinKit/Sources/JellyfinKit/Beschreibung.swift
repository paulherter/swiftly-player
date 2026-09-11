import Foundation

/// **Beschreibungen vom Server, lesbar gemacht.**
///
/// Jellyfin reicht den Text durch, wie er hinterlegt ist — und bei Serien aus
/// manchen Quellen steht darin Auszeichnung: `<br>`, `<p>`, `<i>`, dazu
/// `&amp;` und `&#39;`. Die Oberfläche setzte das bisher wörtlich auf den
/// Schirm; von einem Tester gemeldet.
///
/// Umgesetzt wird, was eine Bedeutung für den Fließtext hat — Umbrüche und
/// Absätze —, der Rest fällt weg. Hervorhebungen gehen dabei verloren; eine
/// kursive Zeile ist in einer Beschreibung Schmuck, ein Umbruch nicht.
///
/// **Hier und nicht in der Ansicht**, weil sechs Fassungen denselben Text
/// zeigen. Eine Bereinigung je Oberfläche wäre sechsmal dieselbe Funktion.
public enum Beschreibung {

    public static func lesbar(_ roh: String) -> String {
        var s = roh.replacingOccurrences(of: "\r\n", with: "\n")

        // Umbrüche und Absätze zuerst, solange die Marken noch da sind.
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</(p|div|h[1-6])\s*>"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<li[^<>]*>"#, with: "\n• ", options: .regularExpression)

        // Alle übrigen Marken. Nur, was wie eine aussieht: ein Buchstabe
        // direkt nach „<" oder „</". „5 < 6 und 7 > 3" bleibt stehen.
        s = s.replacingOccurrences(of: #"</?[A-Za-z][^<>]*>"#, with: "", options: .regularExpression)

        s = zeichenAufloesen(s)

        // **Geschützte Leerzeichen werden normale.** In einer Beschreibung
        // soll alles umbrechen dürfen; ein Absatz, dessen Wörter an solchen
        // Zeichen hängen, ist für den Zeilenumbruch ein einziges Wort — breiter
        // als der Schirm, und die ganze Seite ließ sich seitwärts ziehen.
        for zeichen in ["\u{00A0}", "\u{202F}", "\u{2007}"] {
            s = s.replacingOccurrences(of: zeichen, with: " ")
        }

        // Leerraum am Zeilenende weg, höchstens eine Leerzeile am Stück.
        s = s.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `&amp;` zuletzt: sonst würde aus `&amp;lt;` erst `&lt;` und dann `<`
    /// — zweimal aufgelöst, wo einmal gemeint war.
    private static func zeichenAufloesen(_ text: String) -> String {
        var s = text
        for (marke, zeichen) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                 ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: marke, with: zeichen)
        }
        s = zahlzeichenAufloesen(s)
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// `&#8211;` und `&#x2013;` — Gedankenstriche und Anführungszeichen kommen
    /// aus manchen Quellen nur so.
    private static func zahlzeichenAufloesen(_ text: String) -> String {
        guard let muster = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]{1,6});"#) else { return text }
        let ns = text as NSString
        var ergebnis = ""
        var zuletzt = 0
        for treffer in muster.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            ergebnis += ns.substring(with: NSRange(location: zuletzt, length: treffer.range.location - zuletzt))
            let hex = ns.substring(with: treffer.range(at: 1)) == "x"
            let ziffern = ns.substring(with: treffer.range(at: 2))
            if let wert = UInt32(ziffern, radix: hex ? 16 : 10), let zeichen = Unicode.Scalar(wert) {
                ergebnis += String(Character(zeichen))
            } else {
                ergebnis += ns.substring(with: treffer.range)
            }
            zuletzt = treffer.range.location + treffer.range.length
        }
        ergebnis += ns.substring(from: zuletzt)
        return ergebnis
    }
}

extension Item {
    /// Die Beschreibung, wie sie auf dem Schirm stehen soll — `nil`, wenn nach
    /// dem Bereinigen nichts übrig bleibt.
    public var beschreibung: String? {
        guard let overview else { return nil }
        let text = Beschreibung.lesbar(overview)
        return text.isEmpty ? nil : text
    }
}

extension Item {
    /// Der Tag aus `PremiereDate` — bei einer Person der Geburtstag.
    ///
    /// **Nur der Tag, ohne Uhrzeit.** Jellyfin schreibt Mitternacht UTC
    /// dazu; als Zeitpunkt gelesen wäre es westlich von Greenwich der Vortag.
    public var tagesdatum: DateComponents? {
        guard let roh = premiereDate, roh.count >= 10 else { return nil }
        let teile = roh.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard teile.count == 3 else { return nil }
        return DateComponents(year: teile[0], month: teile[1], day: teile[2])
    }

    /// Die Kennung bei TMDB — über sie findet Seerr eine Person.
    public var tmdbKennung: Int? { providerIds?["Tmdb"].flatMap { Int($0) } }
}
