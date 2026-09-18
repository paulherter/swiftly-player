import Foundation

/// **Welche Reihen die Startseite trägt, und in welcher Folge.**
///
/// Die Aufzählung stand in `AppModel` und erreichte Linux und Windows damit
/// nicht — dort war die Reihenfolge fest verdrahtet, ohne Ausblenden und ohne
/// Umsortieren. Welche Reihe wann gilt, ist aber keine Anzeigefrage: `passt`
/// entscheidet, ob eine Reihe überhaupt existiert, und die Antwort muss
/// überall dieselbe sein.
public enum Startreihe: String, CaseIterable, Sendable, Identifiable {
    case weiterschauen, naechsteFolge, neueFilme, neueSerien, neuzugaenge

    public var id: String { rawValue }

    /// Welche Reihen es gerade gibt: getrennt die neuen Filme und Serien
    /// einzeln, sonst die gemeinsame.
    ///
    /// **Getrennt statt zusätzlich.** Ist die Einstellung an, ersetzt das Paar
    /// die gemeinsame Reihe; ist sie aus, gibt es das Paar nicht. So kostet
    /// die Einstellung nichts, solange sie niemand benutzt.
    public func passt(getrennt: Bool) -> Bool {
        switch self {
        case .neuzugaenge:            !getrennt
        case .neueFilme, .neueSerien: getrennt
        default:                      true
        }
    }

    /// Der Name in der Einstellungsliste — **deutsch, weil Deutsch der
    /// Schlüssel ist** (E7).
    ///
    /// **Nicht die Überschrift auf der Startseite.** Dort steht „Zuletzt
    /// hinzugefügte Filme", hier „Neue Filme": das eine ist der Titel einer
    /// Reihe, das andere der Name der Zeile, die man verschiebt. Linux trug
    /// bis zum 13.09.2026 den Einstellungsnamen als Überschrift.
    public var listenname: String {
        switch self {
        case .weiterschauen: "Weiterschauen"
        case .naechsteFolge: "Nächste Folge"
        case .neueFilme:     "Neue Filme"
        case .neueSerien:    "Neue Serien"
        case .neuzugaenge:   "Neu hinzugefügt"
        }
    }

    /// Das Zeichen in der Einstellungsliste. **Adwaita-Namen**, weil nur
    /// Linux und Windows diese Liste selbst bauen; Apple hat seine eigenen
    /// SF-Symbole an der Ansicht. Ohne Zeichen sah die Reihenliste als
    /// einzige Liste der App anders aus als alle anderen.
    public var zeichen: String {
        switch self {
        case .weiterschauen: "media-playback-start-symbolic"
        case .naechsteFolge: "media-skip-forward-symbolic"
        case .neueFilme:     "video-x-generic-symbolic"
        case .neueSerien:    "tv-symbolic"
        case .neuzugaenge:   "starred-symbolic"
        }
    }

    /// Die Überschrift über der Reihe auf der Startseite selbst.
    public var reihentitel: String {
        switch self {
        case .weiterschauen: "Weiterschauen"
        case .naechsteFolge: "Nächste Folge"
        case .neueFilme:     "Zuletzt hinzugefügte Filme"
        case .neueSerien:    "Zuletzt hinzugefügte Serien"
        case .neuzugaenge:   "Zuletzt hinzugefügt"
        }
    }
}

/// Wie die eingestellte Reihenfolge gelesen und gesichert wird.
///
/// **Warum eine eigene Rechnung.** Eine abgelegte Liste kann veralten: eine
/// Reihe fällt weg, eine kommt dazu, oder die Datei stammt aus einer Fassung,
/// die es noch nicht gab. Jeder dieser Fälle darf die Startseite nicht leeren.
public enum Startreihenfolge {

    /// Die geltende Reihenfolge: was abgelegt ist, gefolgt von allem, was dort
    /// fehlt — damit eine neue Reihe auftaucht, statt still zu verschwinden.
    public static func geltend(abgelegt: [String]) -> [Startreihe] {
        let bekannt = abgelegt.compactMap(Startreihe.init(rawValue:))
        let fehlend = Startreihe.allCases.filter { !bekannt.contains($0) }
        return bekannt + fehlend
    }

    /// Was am Ende auf der Seite steht: in der Reihenfolge, ohne die
    /// ausgeblendeten, ohne die, die es gerade nicht gibt.
    public static func sichtbar(abgelegt: [String], aus: Set<String>,
                                getrennt: Bool) -> [Startreihe] {
        geltend(abgelegt: abgelegt)
            .filter { !aus.contains($0.rawValue) && $0.passt(getrennt: getrennt) }
    }

    /// Verschiebt eine Reihe um eine Stelle — **innerhalb der sichtbaren**.
    ///
    /// Was gerade nicht gilt, hängt hinten an und taucht beim Umschalten
    /// wieder auf; würde es mitgezählt, spränge eine Reihe über eine Lücke,
    /// die niemand sieht.
    public static func verschoben(_ was: Startreihe, um schritt: Int,
                                  abgelegt: [String], getrennt: Bool) -> [String] {
        var sichtbar = geltend(abgelegt: abgelegt).filter { $0.passt(getrennt: getrennt) }
        guard let von = sichtbar.firstIndex(of: was) else { return abgelegt }
        let nach = von + schritt
        guard nach >= 0, nach < sichtbar.count else { return abgelegt }
        sichtbar.swapAt(von, nach)
        let unsichtbar = geltend(abgelegt: abgelegt).filter { !$0.passt(getrennt: getrennt) }
        return (sichtbar + unsichtbar).map(\.rawValue)
    }
}
