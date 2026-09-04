import Foundation

/// Wie ein Titel beschriftet wird — **einmal, für alle fünf Plattformen.**
///
/// Lag zuerst in den Ansichtsdateien, dann in `Sources/Shared/Titelangaben.swift`.
/// Das war so lange richtig, wie alle Plattformen SwiftUI waren; die
/// Linux-Fassung erreicht `Sources/Shared` nicht und hätte abschreiben müssen.
/// Genau daran ist die Zeile schon einmal auseinandergelaufen: auf tvOS stand
/// bei Serien „0 Min.", weil dort die Prüfung `sekunden > 0` fehlte.
///
/// **Was hier steht, ist übersetzt** — über ``uebersetzt(_:)`` mit dem Bündel
/// des Pakets. Auf Linux gibt es keine Textkataloge; dort kommt der deutsche
/// Wortlaut heraus, weil er zugleich der Schlüssel ist. Das ist der bewusste
/// Rückfall, kein Versehen.

/// „2 Std. 8 Min." oder „94 Min."
public func laufzeit(_ sekunden: Double) -> String {
    let m = Int(sekunden / 60)
    return m >= 60 ? uebersetzt("\(m / 60) Std. \(m % 60) Min.")
                   : uebersetzt("\(m) Min.")
}

/// „1:23 h" oder „42 min" — für den Fortsetzen-Knopf.
///
/// Ohne Übersetzung: „h" und „min" stehen in beiden Sprachen so da.
public func zeitText(_ sekunden: Double) -> String {
    let gesamt = Int(sekunden)
    let (h, m) = (gesamt / 3600, (gesamt % 3600) / 60)
    return h > 0 ? "\(h):\(String(format: "%02d", m)) h" : "\(m) min"
}

/// „7,8" statt „7.8" — Jellyfin liefert Punkt, Deutsch schreibt Komma.
public func komma(_ wert: Double) -> String {
    String(format: "%.1f", wert).replacingOccurrences(of: ".", with: ",")
}

extension Item {

    /// Jahr, Laufzeit und Genre in einer Zeile.
    ///
    /// Serien haben keine eigene Laufzeit — der Server liefert dort 0, und
    /// ohne die Prüfung stünde „0 Min." in der Zeile.
    public var nebenzeile: String {
        var teile: [String] = []
        if let jahr = productionYear { teile.append(String(jahr)) }
        if let sekunden = runtimeSeconds, sekunden > 0 { teile.append(laufzeit(sekunden)) }
        if let genres, !genres.isEmpty {
            teile.append(genres.prefix(2).joined(separator: ", "))
        }
        return teile.joined(separator: " · ")
    }

    /// Sekunde, ab der fortgesetzt wird — oder nichts.
    ///
    /// Die Regel selbst steht in ``Fortsetzstelle``, mit beiden Grenzen und
    /// mit Tests. Hier stand sie einmal halb: unter einer Minute von vorn,
    /// aber am Ende ohne Grenze — eine durchgelaufene Folge lieferte damit
    /// ihr eigenes Ende als Fortsetzstelle und sprang beim Öffnen weiter.
    public var fortsetzenAb: Double? {
        Fortsetzstelle.ab(position: userData?.playbackPositionTicks.map { Double($0) / 10_000_000 },
                          laufzeit: runTimeTicks.map { Double($0) / 10_000_000 })
    }
}
