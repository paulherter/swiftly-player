#if DEBUG
import UIKit
import JellyfinKit

/// **Messlauf: wie schnell greift ein Tempowechsel?** Ohne Finger, nur
/// Protokoll.
///
///     xcrun simctl launch <geraet> de.paulherter.swiftly -tempolauf <Datei>
///
/// Spielt die Datei, setzt nach 5 s das Tempo auf 2 und nach weiteren 4 s
/// zurück auf 1, und schreibt je 25 ms die Filmzeit neben die Wanduhr. Die
/// Steigung (Filmzeit je Wandzeit) zeigt, ab wann VLC wirklich schneller
/// läuft — die Uhr des Players folgt dem Ton.
@MainActor
enum Tempolauf {
    private static var argumente: [String] { ProcessInfo.processInfo.arguments }
    static var an: Bool { argumente.contains("-tempolauf") }
    private static func log(_ t: String) { Protokoll.schreib("[Tempolauf] " + t) }

    static func starten() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let i = argumente.firstIndex(of: "-tempolauf"), argumente.indices.contains(i + 1),
                  let fenster = UIApplication.shared.connectedScenes
                    .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { log("nichts"); return }
            if let j = argumente.firstIndex(of: "-tempozusatz"), argumente.indices.contains(j + 1) {
                VLCPlayerView.testZusatz = argumente[j + 1].split(separator: " ").map(String.init)
                log("Zusatz \(VLCPlayerView.testZusatz)")
            }
            let ansicht = VLCPlayerView(frame: fenster.bounds)
            ansicht.testVideospur = true
            fenster.addSubview(ansicht)
            ansicht.play(url: URL(fileURLWithPath: argumente[i + 1]), abSekunden: 0)
            try? await Task.sleep(for: .seconds(5))
            // `-nurspielen`: 65 s ohne Tempowechsel — Tonaussetzer zählen.
            if argumente.contains("-nurspielen") {
                for schritt in 1...13 {
                    try? await Task.sleep(for: .seconds(5))
                    let st = ansicht.player.media?.statistics
                    log("t=\(schritt * 5) s · Ton gespielt \(st?.playedAudioBuffers ?? 0)"
                        + " · verloren \(st?.lostAudioBuffers ?? 0) · Film \(ansicht.player.time.intValue / 1000) s")
                }
                ansicht.stop()
                log("Ende")
                return
            }
            for ziel: Float in [2, 1] {
                let t0 = Date()
                ansicht.tempo = ziel
                if argumente.contains("-tempospringen") {
                    // Puffer leeren: an die Stelle springen, an der VLC steht.
                    ansicht.player.time = ansicht.player.time
                }
                if argumente.contains("-tempofast") {
                    ansicht.player.jump(withOffset: 0, completion: {})
                }
                log("gesetzt \(ziel) · rate jetzt \(ansicht.player.rate)")
                var vorige = (w: 0.0, m: Double(ansicht.player.time.intValue))
                var gemeldet = false
                for _ in 0..<160 {
                    try? await Task.sleep(for: .milliseconds(25))
                    let w = Date().timeIntervalSince(t0) * 1000
                    let m = Double(ansicht.player.time.intValue)
                    if w - vorige.w >= 100 {
                        let steigung = (m - vorige.m) / (w - vorige.w)
                        let st = ansicht.player.media?.statistics
                        log("t=\(Int(w)) ms · Film \(Int(m)) ms · Steigung \(String(format: "%.2f", steigung))"
                            + " · Bilder \(st?.displayedPictures ?? 0) · Ton \(st?.playedAudioBuffers ?? 0)"
                            + " · Pos \(String(format: "%.5f", ansicht.player.position))")
                        if !gemeldet, abs(steigung - Double(ziel)) < 0.25 {
                            gemeldet = true
                            log("angekommen nach ~\(Int(w)) ms")
                        }
                        vorige = (w, m)
                    }
                }
            }
            ansicht.stop()
            ansicht.removeFromSuperview()
            log("Ende")
        }
    }
}
#endif
