import Foundation

/// Eine Sitzung auf einem **anderen** Gerät, die gerade etwas abspielt.
///
/// Kommt aus `GET /Sessions`. Jellyfin führt dort jede angemeldete Sitzung mit
/// dem, was sie gerade zeigt — das ist genau die Auskunft, die es für ein
/// „weiter auf dem Fernseher" braucht, und wir müssen dafür nichts Eigenes
/// verteilen.
public struct Fremdsitzung: Sendable, Equatable, Decodable, Identifiable {

    public let id: String
    public let geraeteID: String?
    public let geraetename: String?
    /// „Swiftly", „Jellyfin Web", „Swiftfin" — der Name des Programms.
    public let programm: String?
    public let nimmtBefehle: Bool
    public let laeuft: Item?
    public let stand: Spielstand?
    public let letzteRegung: Date?

    public struct Spielstand: Sendable, Equatable, Decodable {
        public let angehalten: Bool?
        private let stelleTicks: Int64?

        enum CodingKeys: String, CodingKey {
            case angehalten = "IsPaused"
            case stelleTicks = "PositionTicks"
        }

        /// Sekunden, nicht Ticks. Zehn Millionen auf die Sekunde.
        public var stelle: Double { Double(stelleTicks ?? 0) / 10_000_000 }

        public init(angehalten: Bool?, stelle: Double) {
            self.angehalten = angehalten
            self.stelleTicks = Int64(stelle * 10_000_000)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case geraeteID = "DeviceId"
        case geraetename = "DeviceName"
        case programm = "Client"
        case nimmtBefehle = "SupportsRemoteControl"
        case laeuft = "NowPlayingItem"
        case stand = "PlayState"
        case letzteRegung = "LastActivityDate"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        geraeteID = try c.decodeIfPresent(String.self, forKey: .geraeteID)
        geraetename = try c.decodeIfPresent(String.self, forKey: .geraetename)
        programm = try c.decodeIfPresent(String.self, forKey: .programm)
        nimmtBefehle = try c.decodeIfPresent(Bool.self, forKey: .nimmtBefehle) ?? false
        laeuft = try c.decodeIfPresent(Item.self, forKey: .laeuft)
        stand = try c.decodeIfPresent(Spielstand.self, forKey: .stand)
        letzteRegung = try c.decodeIfPresent(Date.self, forKey: .letzteRegung)
    }

    public init(id: String, geraeteID: String?, geraetename: String?, programm: String?,
                nimmtBefehle: Bool, laeuft: Item?, stand: Spielstand?,
                letzteRegung: Date? = nil) {
        self.id = id; self.geraeteID = geraeteID; self.geraetename = geraetename
        self.programm = programm; self.nimmtBefehle = nimmtBefehle
        self.laeuft = laeuft; self.stand = stand; self.letzteRegung = letzteRegung
    }
}

/// Die Befehle, die eine fremde Sitzung annimmt.
///
/// Die Schreibweise ist Jellyfins, nicht unsere — sie steht so im Pfad.
/// Bewusst nur die drei, die hier gebraucht werden; der Rest waere Vorrat.
public enum Fremdbefehl: String, Sendable {
    case anhalten = "Pause"
    case weiter   = "Unpause"
    case beenden  = "Stop"
}

// MARK: - Welche Sitzung angeboten wird

/// Entscheidet, ob es etwas zu übernehmen gibt.
///
/// **Gehört ins Paket, weil vier Plattformen dasselbe Abzeichen zeigen.** Die
/// Regel ist kurz, aber sie hat vier Bedingungen, und wenn eine davon auf
/// einer Plattform fehlt, zeigt dort ein Gerät sich selbst an oder ein Knopf
/// führt ins Leere. Wie `Folgenende` und `Zeitannahme`.
public enum Uebernahme {

    /// Nach so langer Stille gilt eine Sitzung als vergessen.
    ///
    /// Jellyfin räumt Sitzungen erst spät auf; eine App, die abgestürzt ist,
    /// steht dort noch minutenlang „am Spielen". Ein Angebot, das ins Leere
    /// führt, ist schlechter als keins. Der Fortschrittsbericht kommt alle
    /// zehn Sekunden, also sind neunzig Sekunden reichlich Luft.
    public static let stillefrist: TimeInterval = 90

    /// Die Sitzung, die angeboten wird — oder `nil`.
    ///
    /// - Parameters:
    ///   - eigeneGeraeteID: Ohne die zeigt das Gerät sich selbst an. Der
    ///     häufigste Fehler an dieser Stelle, und er fällt erst auf, wenn nur
    ///     ein Gerät läuft.
    ///   - jetzt: Für die Stillefrist. Von außen, damit es prüfbar bleibt.
    public static func angebot(aus sitzungen: [Fremdsitzung],
                               eigeneGeraeteID: String,
                               jetzt: Date = Date()) -> Fremdsitzung? {
        sitzungen
            .filter { taugt($0, eigeneGeraeteID: eigeneGeraeteID, jetzt: jetzt) }
            // Die jüngste: wer zuletzt etwas getan hat, sitzt vermutlich davor.
            .max { links, rechts in
                (links.letzteRegung ?? .distantPast) < (rechts.letzteRegung ?? .distantPast)
            }
    }

    static func taugt(_ s: Fremdsitzung, eigeneGeraeteID: String, jetzt: Date) -> Bool {
        // 1. Nicht wir selbst.
        guard s.geraeteID != eigeneGeraeteID else { return false }
        // 2. Es läuft etwas, und es hat eine Kennung, mit der man es öffnen kann.
        guard let titel = s.laeuft, !titel.id.isEmpty else { return false }
        // 3. Anhalten muss ankommen. Ohne das würde das andere Gerät
        //    weiterlaufen, während hier dasselbe beginnt — zwei Tonspuren
        //    im Raum, und niemand versteht, warum.
        guard s.nimmtBefehle else { return false }
        // 4. Frisch genug.
        if let regung = s.letzteRegung, jetzt.timeIntervalSince(regung) > stillefrist {
            return false
        }
        return true
    }
}
