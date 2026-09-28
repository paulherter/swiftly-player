#if DEBUG
import UIKit
import JellyfinKit

/// **Selbsttest der Erstbild-Rettung** — ohne Finger und ohne Server, nur
/// über das Protokoll.
///
///     xcrun simctl launch <geraet> de.paulherter.swiftly \
///         -erstbildlauf <Adresse> [-erstbildab <s>] [-erstbildzwang <codec-Option>] [-erstbildimmer]
///
/// Legt einen Abspieler über das ganze Fenster, spielt `<Adresse>` (Datei
/// oder `http://`) 30 Sekunden und schreibt je Sekunde eine
/// `[Erstbildlauf]`-Zeile mit Uhr, gezeigten Bildern und Hinweis. Die
/// Bildspur wird behauptet, als hätte der Server sie genannt.
///
/// - `-erstbildzwang ":codec=araw,none"`: erzwingt einen Dekoder ohne Bild,
///   solange die Regel keinen Software-Dekoder verlangt — prüft, dass die
///   zweite Rettung greift.
/// - `-erstbildimmer`: der Zwang gilt auch dann — prüft die Ruhe danach.
@MainActor
enum Erstbildlauf {
    private static var argumente: [String] { ProcessInfo.processInfo.arguments }
    static var an: Bool { argumente.contains("-erstbildlauf") }

    private static func wert(_ name: String) -> String? {
        argumente.firstIndex(of: name).flatMap { argumente.indices.contains($0 + 1) ? argumente[$0 + 1] : nil }
    }
    private static func log(_ text: String) { Protokoll.schreib("[Erstbildlauf] " + text) }

    static func starten() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let roh = wert("-erstbildlauf"),
                  let adresse = roh.hasPrefix("/") ? URL(fileURLWithPath: roh) : URL(string: roh)
            else { log("keine Adresse"); return }
            let fenster = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            guard let fenster else { log("kein Fenster"); return }
            if let zwang = wert("-erstbildzwang") {
                VLCPlayerView.testZwang = (zwang, argumente.contains("-erstbildimmer"))
            }
            let ansicht = VLCPlayerView(frame: fenster.bounds)
            ansicht.testVideospur = true
            fenster.addSubview(ansicht)
            log("Start \(adresse.lastPathComponent) · Zwang \(wert("-erstbildzwang") ?? "—")"
                + (argumente.contains("-erstbildimmer") ? " (immer)" : ""))
            ansicht.play(url: adresse, abSekunden: wert("-erstbildab").flatMap(Double.init) ?? 0)
            for sekunde in 1...30 {
                try? await Task.sleep(for: .seconds(1))
                let stat = ansicht.player.media?.statistics
                log("t=\(sekunde) s · Uhr \(ansicht.player.time.intValue / 1000) s"
                    + " · gezeigt \(stat?.displayedPictures ?? 0) · dekodiert \(stat?.decodedVideo ?? 0)"
                    + " · Hinweis \(ansicht.erstbildHinweis ?? "—")")
            }
            ansicht.stop()
            ansicht.removeFromSuperview()
            log("Ende")
        }
    }
}
#endif
