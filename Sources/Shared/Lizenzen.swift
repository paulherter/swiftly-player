import Foundation

// **Open-Source-Lizenzen: die Daten, nicht die Ansicht.**
//
// Gelesen wird `LICENSES/bausteine.json` aus dem Bündel — dieselbe Datei, aus
// der `THIRD-PARTY-NOTICES.md` entsteht (`Werkzeuge/lizenzen-erzeugen.py`).
// Hier steht nichts, was auch dort stehen müsste: keine zweite Liste, die
// auseinanderlaufen kann. Die Lizenztexte liegen daneben als `LICENSES/*.txt`
// und bleiben, wie sie sind (englisch, amtlicher Wortlaut).
//
// Auf allen drei Apple-Zielen eingebunden; die Ansichten hat jede Plattform
// für sich.

struct Lizenzbaustein: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String
    let spdx: String
    let urheber: String
    let quelle: String
    let plattformen: [String]
    let texte: [String]
    let gruppe: String
    let notiz: String?

    var quelleURL: URL? { URL(string: quelle) }
}

struct Lizenzabschnitt: Decodable, Hashable, Sendable {
    let titel: String
    let absaetze: [String]
}

/// Quellen und schriftliches Angebot nach LGPL-2.1 §6.
struct Lizenzangebot: Decodable, Sendable {
    let titel: String
    let kurz: String
    let kontakt: String
    let abschnitte: [Lizenzabschnitt]
}

struct Lizenzbestand: Decodable, Sendable {
    let angebot: Lizenzangebot
    let bausteine: [Lizenzbaustein]

    /// Einmal gelesen. `nil`, wenn das Bündel die Datei nicht trägt — die
    /// Ansicht sagt das dann, statt eine leere Liste zu zeigen.
    static let geteilt: Lizenzbestand? = laden()

    /// Wofür diese Fassung gebaut ist: so heißt sie in `plattformen`.
    /// iPhone und iPad sind dieselbe App und tragen dieselbe Liste.
    static var plattform: String {
        #if os(macOS)
        "macos"
        #elseif os(tvOS)
        "tvos"
        #else
        "ios"
        #endif
    }

    /// Die Bausteine einer Gruppe, die in dieser Fassung stecken.
    func bausteine(gruppe: String) -> [Lizenzbaustein] {
        bausteine.filter { $0.gruppe == gruppe && $0.plattformen.contains(Self.plattform) }
    }

    func baustein(id: String) -> Lizenzbaustein? {
        bausteine.first { $0.id == id }
    }

    /// Ein Absatz mit anklickbaren Adressen. Die Adressen stehen im Text
    /// selbst, so wie sie in `THIRD-PARTY-NOTICES.md` stehen; hier werden
    /// sie nur erkannt, nicht noch einmal geführt.
    static func verlinkt(_ text: String) -> AttributedString {
        var ergebnis = AttributedString(text)
        guard let leser = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return ergebnis
        }
        let bereich = NSRange(text.startIndex..., in: text)
        for treffer in leser.matches(in: text, range: bereich) {
            guard let url = treffer.url, let stelle = Range(treffer.range, in: text),
                  let ziel = Range(stelle, in: ergebnis) else { continue }
            ergebnis[ziel].link = url
        }
        return ergebnis
    }

    private static func laden() -> Lizenzbestand? {
        guard let daten = Data(lizenzdatei: "bausteine.json") else { return nil }
        return try? JSONDecoder().decode(Lizenzbestand.self, from: daten)
    }

    /// Der Volltext einer Lizenz. Der Dateiname steht in `Lizenzbaustein.texte`.
    static func text(_ datei: String) -> String? {
        guard let daten = Data(lizenzdatei: datei) else { return nil }
        return String(data: daten, encoding: .utf8)
    }

    /// Absätze eines Volltexts. Die Lizenztexte tragen harte Zeilenumbrüche;
    /// zusammengesetzt wird, was zu einem Absatz gehört, damit die Zeilen
    /// auf jeder Breite umbrechen. Eingerückte Zeilen (Titel, Aufzählungen)
    /// bilden eigene Absätze, getrennt von den nicht eingerückten.
    static func absaetze(von text: String) -> [String] {
        var ergebnis: [String] = []
        var aktuell: [String] = []
        var eingerueckt = false
        func abschliessen() {
            if !aktuell.isEmpty { ergebnis.append(aktuell.joined(separator: " ")) }
            aktuell = []
        }
        let zeilen = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for zeile in zeilen {
            let roh = String(zeile)
            let gekuerzt = roh.trimmingCharacters(in: .whitespaces)
            if gekuerzt.isEmpty { abschliessen(); continue }
            let einzug = roh.hasPrefix("   ") || roh.hasPrefix("\t")
            if einzug != eingerueckt { abschliessen(); eingerueckt = einzug }
            aktuell.append(gekuerzt)
        }
        abschliessen()
        return ergebnis
    }
}

private extension Data {
    /// `LICENSES/<name>` im Bündel. Als Ordnerverweis eingebunden, die
    /// Struktur bleibt also erhalten.
    init?(lizenzdatei name: String) {
        guard let ordner = Bundle.main.resourceURL?.appendingPathComponent("LICENSES", isDirectory: true),
              let daten = try? Data(contentsOf: ordner.appendingPathComponent(name))
        else { return nil }
        self = daten
    }
}
