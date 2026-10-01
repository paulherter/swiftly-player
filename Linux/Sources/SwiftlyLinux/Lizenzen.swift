import CGtk
import Foundation

/// **Open-Source-Lizenzen: Daten und Seiten.**
///
/// Gelesen wird `LICENSES/bausteine.json`, dieselbe Datei, aus der
/// `THIRD-PARTY-NOTICES.md` entsteht — keine zweite Liste. Sie liegt neben
/// dem Programm unter `Ressourcen/Lizenzen/` (`bauen.sh` und die Paketskripte
/// kopieren sie aus `LICENSES/`; unter Windows `bauen.ps1`). Die Volltexte
/// stehen daneben als `*.txt` und bleiben, wie sie sind.
struct Lizenzbaustein: Decodable {
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
}

struct Lizenzabschnitt: Decodable {
    let titel: String
    let absaetze: [String]
}

/// Quellen und schriftliches Angebot nach LGPL-2.1 §6.
struct Lizenzangebot: Decodable {
    let titel: String
    let kurz: String
    let kontakt: String
    let abschnitte: [Lizenzabschnitt]
}

struct Lizenzbestand: Decodable {
    let angebot: Lizenzangebot
    let bausteine: [Lizenzbaustein]

    /// Einmal gelesen. `nil`, wenn die Datei neben dem Programm fehlt — die
    /// Seite sagt das, statt eine leere Liste zu zeigen.
    static let geteilt: Lizenzbestand? = laden()

    /// So heißt diese Fassung in `plattformen`. Linux nutzt libVLC und GTK
    /// des Systems, Windows bündelt DLLs; die Liste trennt das über dieses
    /// Feld, nicht über zwei Kopien.
    static var plattform: String {
        #if os(Windows)
        "windows"
        #else
        "linux"
        #endif
    }

    func bausteine(player: Bool) -> [Lizenzbaustein] {
        bausteine.filter { ($0.gruppe == "player") == player && $0.plattformen.contains(Self.plattform) }
    }

    func baustein(id: String) -> Lizenzbaustein? {
        bausteine.first { $0.id == id }
    }

    private static func laden() -> Lizenzbestand? {
        guard let daten = datei("bausteine.json").flatMap({ try? Data(contentsOf: URL(fileURLWithPath: $0)) })
        else { return nil }
        return try? JSONDecoder().decode(Lizenzbestand.self, from: daten)
    }

    private static func datei(_ name: String) -> String? {
        Plattform.mitgeliefert("Lizenzen/\(name)")
    }

    /// Der Volltext einer Lizenz. Der Dateiname steht in `Lizenzbaustein.texte`.
    static func text(_ name: String) -> String? {
        guard let pfad = datei(name), let daten = try? Data(contentsOf: URL(fileURLWithPath: pfad))
        else { return nil }
        return String(data: daten, encoding: .utf8)
    }

    /// Absätze eines Volltexts. Die Lizenztexte tragen harte Zeilenumbrüche;
    /// zusammengesetzt wird, was zu einem Absatz gehört, damit die Zeilen auf
    /// jeder Breite umbrechen. Eingerückte Zeilen bilden eigene Absätze.
    static func absaetze(von text: String) -> [String] {
        var ergebnis: [String] = []
        var aktuell: [String] = []
        var eingerueckt = false
        func abschliessen() {
            if !aktuell.isEmpty { ergebnis.append(aktuell.joined(separator: " ")) }
            aktuell = []
        }
        for zeile in text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
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

    /// Die Adressen eines Absatzes, in der Reihenfolge, ohne Satzzeichen am Ende.
    static func adressen(in text: String) -> [String] {
        var treffer: [String] = []
        for wort in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            guard let start = wort.range(of: "https://") ?? wort.range(of: "http://") else { continue }
            var a = String(wort[start.lowerBound...])
            while let z = a.last, ",.;:)(".contains(z) { a.removeLast() }
            if !treffer.contains(a) { treffer.append(a) }
        }
        return treffer
    }
}

extension App {

    private func lizenzabsatz(_ text: String, leise: Bool = true, oben: Int32 = 10) -> Widget! {
        let l = beschriftung(text, stil: "swiftly-koerper")
        if leise { gtk_widget_add_css_class(l, "dim-label") }
        gtk_label_set_wrap(OpaquePointer(l), 1)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_label_set_justify(OpaquePointer(l), GTK_JUSTIFY_LEFT)
        gtk_label_set_selectable(OpaquePointer(l), 1)
        gtk_widget_set_margin_top(l, oben)
        return l
    }

    private func lizenzrubrik(_ text: String) -> Widget! {
        let k = rubrik(text)
        gtk_widget_remove_css_class(k, "swiftly-leise")
        gtk_widget_add_css_class(k, "swiftly-gruppenrubrik")
        gtk_widget_set_margin_start(k, 0)
        gtk_widget_set_margin_top(k, 26)
        gtk_widget_set_margin_bottom(k, 10)
        return k
    }

    /// Profil → Open-Source-Lizenzen.
    func lizenzenBauen(_ block: Widget!) {
        anhaengen(block, unterseitenkopf(uebersetzt("Open-Source-Lizenzen")))
        guard let bestand = Lizenzbestand.geteilt else {
            anhaengen(block, lizenzabsatz(uebersetzt("Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md."), oben: 14))
            return
        }
        // **Ganz oben, deutlich** — und im Wortlaut, den die Lizenz verlangt.
        let kopfsatz = lizenzabsatz(uebersetzt("Swiftly Player nutzt libVLC von VideoLAN unter der LGPL 2.1 oder später"),
                                    leise: false, oben: 14)
        gtk_widget_add_css_class(kopfsatz, "swiftly-listentitel")
        anhaengen(block, kopfsatz)

        // Quellen: jede Adresse aus dem Abschnitt „Source code", als Verweis.
        let quellabschnitt = bestand.angebot.abschnitte.first { $0.titel == "Source code" }
        var adressen: [String] = []
        for absatz in quellabschnitt?.absaetze ?? [] {
            for a in Lizenzbestand.adressen(in: absatz) where !adressen.contains(a) { adressen.append(a) }
        }
        if !adressen.isEmpty {
            anhaengen(block, lizenzrubrik(uebersetzt("Quelltext")))
            let q = zeilengruppe()
            for (i, a) in adressen.enumerated() {
                if i > 0 { anhaengen(q.raum, zeilenstrich()) }
                anhaengen(q.raum, wertezeile(symbol: "applications-internet-symbolic", titel: a,
                                             pfeil: true) {
                    if let url = URL(string: a) { imBrowser(url) }
                })
            }
            anhaengen(block, q.aussen)
        }

        // Das schriftliche Angebot, im Wortlaut von THIRD-PARTY-NOTICES.md.
        anhaengen(block, lizenzrubrik(uebersetzt("Quelltext und schriftliches Angebot")))
        for abschnitt in bestand.angebot.abschnitte {
            let t = beschriftung(abschnitt.titel, stil: "swiftly-listentitel")
            gtk_label_set_xalign(OpaquePointer(t), 0)
            gtk_widget_set_margin_top(t, 18)
            anhaengen(block, t)
            for absatz in abschnitt.absaetze { anhaengen(block, lizenzabsatz(absatz)) }
        }

        lizenzgruppe(block, uebersetzt("libVLC"), bestand.bausteine(player: true))
        lizenzgruppe(block, uebersetzt("Weitere Bausteine"), bestand.bausteine(player: false))
    }

    private func lizenzgruppe(_ block: Widget!, _ titel: String, _ liste: [Lizenzbaustein]) {
        guard !liste.isEmpty else { return }
        anhaengen(block, lizenzrubrik(titel))
        let g = zeilengruppe()
        for (i, b) in liste.enumerated() {
            if i > 0 { anhaengen(g.raum, zeilenstrich()) }
            anhaengen(g.raum, wertezeile(symbol: "text-x-generic-symbolic", titel: b.name,
                                         unter: "\(b.spdx) · \(b.urheber)", pfeil: true) { [weak self] in
                self?.unterseiteOeffnen(.lizenztext(b.id))
            })
        }
        anhaengen(block, g.aussen)
    }

    /// Ein Baustein: Angaben und der Volltext, scrollbar wie jede Unterseite.
    func lizenztextBauen(_ block: Widget!, id: String) {
        guard let b = Lizenzbestand.geteilt?.baustein(id: id) else {
            anhaengen(block, unterseitenkopf(uebersetzt("Open-Source-Lizenzen")))
            return
        }
        anhaengen(block, unterseitenkopf(b.name))
        let g = zeilengruppe()
        gtk_widget_set_margin_top(g.aussen, 14)
        let angaben: [(String, String)] = [(uebersetzt("Fassung"), b.version), (uebersetzt("Lizenz"), b.spdx),
                                           (uebersetzt("Urheber"), b.urheber), (uebersetzt("Quelle"), b.quelle)]
        for (i, a) in angaben.enumerated() {
            if i > 0 { anhaengen(g.raum, zeilenstrich()) }
            let istQuelle = i == 3
            anhaengen(g.raum, wertezeile(symbol: istQuelle ? "applications-internet-symbolic" : "text-x-generic-symbolic",
                                         titel: a.0, unter: a.1, pfeil: istQuelle,
                                         auswahl: istQuelle ? {
                if let url = URL(string: b.quelle) { imBrowser(url) }
            } : nil))
        }
        anhaengen(block, g.aussen)
        if let n = b.notiz { anhaengen(block, lizenzabsatz(n, oben: 14)) }
        for datei in b.texte {
            anhaengen(block, luftHoch(22))
            if let text = Lizenzbestand.text(datei) {
                for absatz in Lizenzbestand.absaetze(von: text) {
                    anhaengen(block, lizenzabsatz(absatz))
                }
            } else {
                anhaengen(block, lizenzabsatz(uebersetzt("Der Lizenztext fehlt in dieser Fassung. Du findest ihn auf GitHub im Ordner LICENSES."), oben: 0))
            }
        }
    }
}
