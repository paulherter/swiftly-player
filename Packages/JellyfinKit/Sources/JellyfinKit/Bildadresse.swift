import Foundation

/// Welches Bild eines Eintrags gemeint ist.
public enum Bildart: String, Sendable {
    case poster    = "Primary"
    case hintergrund = "Backdrop"
    /// Quer liegendes Vorschaubild. Jellyfin pflegt es bei Serien oft, bei
    /// Folgen selten — als Rückfall für eine 16:9-Kachel taugt es trotzdem.
    case vorschau  = "Thumb"
}

/// Wie das Bild zugeschnitten werden soll.
public enum Bildmass: Sendable {
    /// Höhe begrenzen, Seitenverhältnis behalten — für Plakate.
    case hoechstensHoch(Int)
    /// Breite begrenzen — für Hintergründe.
    case hoechstensBreit(Int)
    /// Auf genau dieses Maß füllen — für runde Zeichen.
    case fuellend(breit: Int, hoch: Int)
}

/// Baut die Adresse eines Bildes auf dem Server.
///
/// Stand vorher an sieben Stellen fast gleich: einmal je Bildart in `AppModel`,
/// zweimal im Klienten, einmal in der Anmeldung. Zwei davon hängten das
/// Zugangsmerkmal an, zwei nicht — was solange nicht auffiel, wie der Server
/// Bilder auch ohne Anmeldung herausgibt.
public struct Bildadresse: Sendable {
    public let basis: URL
    public let token: String?

    public init(basis: URL, token: String?) {
        self.basis = basis
        self.token = token
    }

    public func bauen(itemID: String, art: Bildart = .poster, marke: String? = nil,
                      mass: Bildmass, index: Int? = nil, guete: Int = 90) -> URL? {
        var pfad = "Items/\(itemID)/Images/\(art.rawValue)"
        if let index { pfad += "/\(index)" }
        var teile = URLComponents(url: basis.appendingPathComponent(pfad),
                                  resolvingAgainstBaseURL: false)

        var werte: [URLQueryItem] = []
        // Die Marke ist Jellyfins Fingerabdruck des Bildes. Ohne sie liefert
        // der Server zwar auch etwas, aber Zwischenspeicher können veraltete
        // Fassungen behalten.
        if let marke { werte.append(.init(name: "tag", value: marke)) }
        switch mass {
        case let .hoechstensHoch(h):
            werte.append(.init(name: "maxHeight", value: String(h)))
        case let .hoechstensBreit(b):
            werte.append(.init(name: "maxWidth", value: String(b)))
        case let .fuellend(breit, hoch):
            werte.append(.init(name: "fillWidth", value: String(breit)))
            werte.append(.init(name: "fillHeight", value: String(hoch)))
        }
        werte.append(.init(name: "quality", value: String(guete)))
        if let token { werte.append(.init(name: "api_key", value: token)) }

        teile?.queryItems = werte
        return teile?.url
    }

    /// Das Profilbild eines Benutzers.
    public func benutzer(_ userID: String, marke: String? = nil, kante: Int) -> URL? {
        var teile = URLComponents(
            url: basis.appendingPathComponent("Users/\(userID)/Images/Primary"),
            resolvingAgainstBaseURL: false)
        var werte: [URLQueryItem] = []
        if let marke { werte.append(.init(name: "tag", value: marke)) }
        werte.append(.init(name: "fillWidth", value: String(kante)))
        werte.append(.init(name: "fillHeight", value: String(kante)))
        werte.append(.init(name: "quality", value: "90"))
        if let token { werte.append(.init(name: "api_key", value: token)) }
        teile?.queryItems = werte
        return teile?.url
    }
}
