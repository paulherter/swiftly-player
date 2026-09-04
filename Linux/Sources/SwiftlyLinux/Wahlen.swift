import Foundation

/// Die Einstellungen des Nutzers, wie sie auf den Apple-Fassungen in
/// `AppModel` liegen — dort in `@AppStorage`, hier als JSON neben der
/// Sitzung.
///
/// **Die Vorgaben stehen so auf dem Mac** und sind nicht neu gewählt: Direct
/// Play erzwungen (der Grund für diese App), Bitrate unbegrenzt, nächste
/// Folge selbsttätig, 10 s zurück und 30 s vor. Welche Werte überhaupt zur
/// Wahl stehen, steht in `JellyfinKit.Bitrate`, `.Spanne` und `.Sprachwahl` —
/// nicht hier, sonst böten die Plattformen verschiedene Listen an.
struct Wahlen: Codable {
    var immerDirectPlay = true
    var bitratenGrenze = 0
    var tonSprache = ""
    var untertitelSprache = ""
    var untertitelAutomatisch = false
    var naechsteAutomatisch = true
    var zurueckSekunden = 10
    var vorSekunden = 30
    var fortschrittAufKacheln = true

    private static var datei: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/swiftly/wahlen.json")
    }

    static func lesen() -> Wahlen {
        guard let daten = try? Data(contentsOf: datei),
              let w = try? JSONDecoder().decode(Wahlen.self, from: daten)
        else { return Wahlen() }
        return w
    }

    func sichern() {
        let ordner = Self.datei.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        guard let daten = try? JSONEncoder().encode(self) else { return }
        try? daten.write(to: Self.datei, options: .atomic)
    }
}

/// Welche Werteliste gerade aufgeklappt ist.
enum Werteauswahl { case bitrate, ton, untertitel, zurueck, vor }

/// Die Fassung von libVLC, für die Fußzeile der Einstellungen.
///
/// Auf den Apple-Fassungen steht dort „VLCKit 4.0.0-a23". Hier liegt kein
/// VLCKit, sondern libVLC des Systems — der Text nennt deshalb, was wirklich
/// geladen ist, statt eine Fassung zu behaupten.
enum VLCFassung {
    static var text: String = "3.x"
}
