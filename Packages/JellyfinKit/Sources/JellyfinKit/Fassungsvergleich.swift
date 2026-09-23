import Foundation

/// **Ist die Fassung dort drüben neuer als unsere?**
///
/// Liegt im Paket und nicht bei der Windows-Fassung, weil die GTK-Schicht
/// kein Testziel hat: was dort steht, lässt sich nicht prüfen. Eine Regel wie
/// „1.0.10 ist neuer als 1.0.9" gehört aber geprüft — als Zeichenkette
/// verglichen wäre sie älter, und der Fehler fiele erst bei der zehnten
/// Ausgabe auf.
public enum Fassungsvergleich {

    /// Zahl für Zahl, von links. Fehlende Stellen zählen als null, damit
    /// „1.1" und „1.1.0" dasselbe sind.
    ///
    /// - Parameters:
    ///   - dort: die angebotene Fassung, etwa „1.0.4"
    ///   - hier: die eigene
    ///   - bauDort: die Baunummer der angebotenen Fassung, falls die
    ///     Veröffentlichung eine nennt
    ///   - bauHier: die eigene Baunummer
    public static func neuer(dort: String, hier: String,
                             bauDort: Int? = nil, bauHier: Int = 0) -> Bool {
        let a = teile(dort), b = teile(hier)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        // **Gleiche Fassung, und trotzdem kann drüben etwas Neueres liegen.**
        // Am 20.09.2026 lag 1.0.3 als Bau 2 auf der Veröffentlichungsseite,
        // während Bau 1 installiert war — dieselbe Nummer, aber mit einer
        // Behebung. Ohne die Baunummer meldete die App „ist aktuell".
        //
        // Nennt die Veröffentlichung keine, gilt eine gleiche Nummer als
        // derselbe Stand. Das ist die sichere Seite: lieber einmal nicht
        // angeboten als jedem Zuschauer eine Aktualisierung auf das, was er
        // schon hat.
        guard let bauDort else { return false }
        return bauDort > bauHier
    }

    private static func teile(_ fassung: String) -> [Int] {
        fassung.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// **Die Baunummer aus dem Text einer Veröffentlichung.**
    ///
    /// Das Kennzeichen trägt sie nicht — `v1.0.3` bleibt `v1.0.3`, auch wenn
    /// dieselbe Fassung ein zweites Mal hinausgeht. Im Text steht sie, als
    /// „build 7" oder „Bau 7".
    ///
    /// Gesucht wird die **größte** genannte Zahl, nicht die erste: ein Text,
    /// der die Geschichte mehrerer Bauten erzählt, nennt die ältere zuerst.
    public static func baunummer(ausText text: String) -> Int? {
        let klein = text.lowercased()
        var groesste: Int?
        for wort in ["build ", "bau "] {
            var ab = klein.startIndex
            while let fund = klein.range(of: wort, range: ab..<klein.endIndex) {
                let ziffern = klein[fund.upperBound...].prefix(while: \.isNumber)
                if let zahl = Int(ziffern), zahl > (groesste ?? 0) { groesste = zahl }
                ab = fund.upperBound
            }
        }
        return groesste
    }
}
