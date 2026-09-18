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

public extension Item {

    /// Die Zeile unter einem Suchtreffer: „Furious · S1 E4 · 52 Min."
    ///
    /// **Lag in `Sources/Shared` und war für Linux unerreichbar.** Dort stand
    /// unter einem Suchtreffer deshalb nur das Jahr — dieselbe Auskunft,
    /// halbiert. Genau die Sorte Abweichung, die niemand meldet, weil beide
    /// Seiten für sich plausibel aussehen.
    ///
    /// Beim ersten Umzug fiel auf, dass die Gattung „Film" als **reine
    /// Zeichenkette** angehängt wurde, während „Serie" und „Folge" daneben
    /// übersetzt wurden. Auf Englisch stand dort „Film" statt „Movie".
    var trefferauskunft: String {
        var teile: [String] = []
        switch type {
        case "Movie":   teile.append(uebersetzt("Film"))
        case "Series":  teile.append(uebersetzt("Serie"))
        case "Episode": teile.append(seriesName ?? uebersetzt("Folge"))
        default: break
        }
        if let kuerzel = folgenkuerzel { teile.append(kuerzel) }
        if let jahr = productionYear, type != "Episode" { teile.append(String(jahr)) }
        if let anzahl = childCount, type == "Series" {
            teile.append(uebersetzt("\(anzahl) Staffeln"))
        }
        if let s = runtimeSeconds, type != "Series" { teile.append(laufzeit(s)) }
        return teile.joined(separator: " · ")
    }

    /// „Noch 12 Minuten" — oder `nil`, wenn nichts Nennenswertes fehlt.
    ///
    /// Stand einmal zweimal da und war **nicht** gleich: einmal „Noch 12
    /// Minuten", einmal „Noch 12 min". Schlimmer, die zweite Fassung entstand
    /// als reine Zeichenkette und lief nie durch die Übersetzung.
    var restzeitText: String? {
        guard let gesamt = runtimeSeconds, gesamt > 0, let ab = fortsetzenAb else { return nil }
        return uebersetzt("Noch \(Int((gesamt - ab) / 60)) Minuten")
    }

    /// Beschriftung des Hauptknopfes auf einer Serienseite.
    ///
    /// **Stand einmal dreimal da.** iOS und tvOS hatten sie je für sich —
    /// dieselben vier Fälle, zeichengleich.
    ///
    /// `folge` ist die nächste anzuspielende Folge, `laedt`, ob die Staffel
    /// noch geholt wird. Ohne Folge und ohne Laden gibt es nichts abzuspielen.
    static func serienknopf(folge: Item?, laedt: Bool) -> String {
        // **Zwei getrennte Aufrufe, kein Fragezeichen im Argument.** Aus einem
        // berechneten Schlüssel lässt sich nichts herausziehen; der Text
        // bliebe in der Ausgangssprache stehen.
        guard let folge else {
            return laedt ? uebersetzt("Lädt…") : uebersetzt("Keine Folgen")
        }
        let kuerzel = folge.folgenkuerzel ?? folge.name
        let angefangen = (folge.userData?.playbackPositionTicks ?? 0) > 0
        return angefangen ? uebersetzt("Fortsetzen \(kuerzel)")
                          : uebersetzt("Abspielen \(kuerzel)")
    }
}
