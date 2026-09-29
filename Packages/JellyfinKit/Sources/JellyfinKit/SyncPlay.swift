import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **Gemeinsam schauen über Jellyfins SyncPlay.**
///
/// Nichts Eigenes: die Gruppe gehört dem Server. Wer drin ist, schickt
/// Bitten (`Pause`, `Unpause`, `Seek`) als Aufruf, der Server gibt sie als
/// Befehl mit **Ausführungszeitpunkt** über den Steuerkanal an alle weiter.
/// Damit der Zeitpunkt auf jedem Gerät derselbe Augenblick ist, rechnet jedes
/// Gerät seine Uhr gegen die des Servers (``Zeitabgleich``).
///
/// Vorbild ist jellyfin-web (`plugins/syncPlay/core`): dieselben Regeln für
/// Befehle in der Vergangenheit und in der Zukunft, dieselbe Messung der
/// Uhren. Was hier steht, ist nur die Rechnung — die Oberfläche und der
/// Abspieler hängen sich an, ohne sie selbst zu kennen.
public enum SyncPlay {
    /// Jellyfin zählt in Ticks zu 100 ns.
    public static let ticksJeSekunde: Double = 10_000_000

    static func sekunden(_ ticks: Int64) -> Double { Double(ticks) / ticksJeSekunde }
    static func ticks(_ sekunden: Double) -> Int64 { Int64((sekunden * ticksJeSekunde).rounded()) }

    /// **Ab wann ein Versatz zum Springen führt.** jellyfin-web springt ab
    /// 400 ms nach (`minDelaySkipToSync`); darunter hört niemand den
    /// Unterschied, ein Sprung in VLC dagegen schon.
    public static let sprunggrenze: Double = 0.4

    /// **Nachführen im Lauf erst ab einer Sekunde.** Ein Sprung kostet VLC
    /// bei MKV selbst ein paar hundert Millisekunden; mit der Grenze von
    /// oben liefe das in eine Schleife aus Springen und Nachhinken.
    /// jellyfin-web führt im Lauf von Haus aus gar nicht nach.
    public static let driftgrenze: Double = 1.0
}

// MARK: - Was der Server schickt

/// Eine Gruppe, wie `GET /SyncPlay/List` sie liefert.
public struct SyncPlayGruppe: Sendable, Equatable, Identifiable, Decodable {
    public enum Zustand: String, Sendable, Equatable {
        case leer = "Idle"
        case wartet = "Waiting"
        case angehalten = "Paused"
        case laeuft = "Playing"
    }

    public let id: String
    public let name: String
    public let zustand: Zustand?
    /// Benutzernamen, nicht Geräte. Wer auf zwei Geräten drin ist, steht
    /// zweimal.
    public let teilnehmer: [String]
    public let stand: Date?

    public init(id: String, name: String, zustand: Zustand? = nil,
                teilnehmer: [String] = [], stand: Date? = nil) {
        self.id = id
        self.name = name
        self.zustand = zustand
        self.teilnehmer = teilnehmer
        self.stand = stand
    }

    enum Schluessel: String, CodingKey {
        case id = "GroupId", name = "GroupName", zustand = "State"
        case teilnehmer = "Participants", stand = "LastUpdatedAt"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Schluessel.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        zustand = try c.decodeIfPresent(String.self, forKey: .zustand).flatMap(Zustand.init(rawValue:))
        teilnehmer = try c.decodeIfPresent([String].self, forKey: .teilnehmer) ?? []
        stand = try? c.decodeIfPresent(Datumsfeld.self, forKey: .stand)?.wert
    }

    /// Alle außer einem selbst, jeder Name einmal. Für „mit Paul und Tom".
    public func andere(als ich: String?) -> [String] {
        var gesehen = Set<String>()
        var ergebnis: [String] = []
        var eigenerUebersprungen = false
        for name in teilnehmer {
            if name == ich, !eigenerUebersprungen { eigenerUebersprungen = true; continue }
            if gesehen.insert(name).inserted { ergebnis.append(name) }
        }
        return ergebnis
    }
}

/// Ein Befehl mit Ausführungszeitpunkt (`SyncPlayCommand`).
public struct SyncPlayBefehl: Sendable, Equatable {
    public enum Art: String, Sendable, Equatable {
        case weiter = "Unpause"
        case pause = "Pause"
        case stopp = "Stop"
        case springen = "Seek"
    }

    public let gruppe: String
    /// `PlaylistItemId` — gilt nur für diesen Eintrag der Warteschlange.
    public let eintrag: String?
    public let art: Art
    /// Serverzeit, zu der er ausgeführt wird.
    public let wann: Date
    /// Stelle in Sekunden, zu der er gilt.
    public let stelle: Double?
    /// Serverzeit, zu der er ausgesandt wurde.
    public let ausgesandt: Date?

    public init(gruppe: String, eintrag: String?, art: Art, wann: Date,
                stelle: Double?, ausgesandt: Date? = nil) {
        self.gruppe = gruppe
        self.eintrag = eintrag
        self.art = art
        self.wann = wann
        self.stelle = stelle
        self.ausgesandt = ausgesandt
    }
}

/// Die Warteschlange der Gruppe (`PlayQueue`).
public struct SyncPlayWarteschlange: Sendable, Equatable {
    public struct Eintrag: Sendable, Equatable {
        public let titel: String
        public let eintrag: String
        public init(titel: String, eintrag: String) {
            self.titel = titel
            self.eintrag = eintrag
        }
    }

    /// `NewPlaylist`, `SetCurrentItem`, `NextItem` …
    public let grund: String
    public let stand: Date?
    public let eintraege: [Eintrag]
    public let index: Int
    public let startstelle: Double
    public let laeuft: Bool

    public init(grund: String, stand: Date?, eintraege: [Eintrag], index: Int,
                startstelle: Double, laeuft: Bool) {
        self.grund = grund
        self.stand = stand
        self.eintraege = eintraege
        self.index = index
        self.startstelle = startstelle
        self.laeuft = laeuft
    }

    public var aktuell: Eintrag? {
        eintraege.indices.contains(index) ? eintraege[index] : nil
    }

    /// Muss der Abspieler dafür einen (anderen) Titel laden? Umsortieren,
    /// Wiederholen und Mischen ändern nichts an dem, was läuft.
    public var wechseltTitel: Bool {
        ["NewPlaylist", "SetCurrentItem", "NextItem", "PreviousItem", "RemoveItems"].contains(grund)
    }
}

/// Alles, was über den Steuerkanal zu SyncPlay ankommt.
public enum SyncPlayNachricht: Sendable, Equatable {
    case befehl(SyncPlayBefehl)
    /// Man ist drin — nach `New` wie nach `Join`.
    case beigetreten(SyncPlayGruppe)
    case verlassen
    case nichtInGruppe
    case gibtEsNicht
    /// Einem in der Gruppe fehlt der Titel in seiner Bibliothek.
    case keinZugriff
    case jemandKam(String)
    case jemandGing(String)
    case zustand(SyncPlayGruppe.Zustand, grund: String?)
    case warteschlange(SyncPlayWarteschlange)
    /// Vom Steuerkanal selbst, nicht vom Server: die Leitung ist abgerissen.
    /// Der Server wirft die Sitzung damit aus der Gruppe.
    case leitungVerloren
    /// Vom Steuerkanal selbst: nach einem Abriss kommt wieder etwas an.
    case leitungWieder

    /// Liest eine ganze Nachricht des Steuerkanals. `nil` für alles, was
    /// nicht SyncPlay ist oder sich nicht lesen lässt.
    public static func lesen(_ text: String) -> SyncPlayNachricht? {
        guard let daten = text.data(using: .utf8),
              let kopf = try? JSONDecoder().decode(Kopf.self, from: daten) else { return nil }
        let dekoder = JSONDecoder()
        switch kopf.MessageType {
        case "SyncPlayCommand":
            guard let h = try? dekoder.decode(Huelle<Befehlsdaten>.self, from: daten),
                  let b = h.Data.befehl else { return nil }
            return .befehl(b)
        case "SyncPlayGroupUpdate":
            guard let art = try? dekoder.decode(Huelle<Gruppenkopf>.self, from: daten).Data.Type
            else { return nil }
            switch art {
            case "GroupJoined":
                return (try? dekoder.decode(Huelle<Gruppendaten<SyncPlayGruppe>>.self, from: daten))
                    .map { .beigetreten($0.Data.Data) }
            case "GroupLeft": return .verlassen
            case "NotInGroup": return .nichtInGruppe
            case "GroupDoesNotExist": return .gibtEsNicht
            case "LibraryAccessDenied": return .keinZugriff
            case "UserJoined":
                return (try? dekoder.decode(Huelle<Gruppendaten<String>>.self, from: daten))
                    .map { .jemandKam($0.Data.Data) }
            case "UserLeft":
                return (try? dekoder.decode(Huelle<Gruppendaten<String>>.self, from: daten))
                    .map { .jemandGing($0.Data.Data) }
            case "StateUpdate":
                guard let z = try? dekoder.decode(Huelle<Gruppendaten<Zustandsdaten>>.self, from: daten),
                      let zustand = SyncPlayGruppe.Zustand(rawValue: z.Data.Data.State) else { return nil }
                return .zustand(zustand, grund: z.Data.Data.Reason)
            case "PlayQueue":
                return (try? dekoder.decode(Huelle<Gruppendaten<Warteschlangendaten>>.self, from: daten))
                    .map { .warteschlange($0.Data.Data.schlange) }
            default:
                return nil
            }
        default:
            return nil
        }
    }

    // Nur zum Lesen. Die Feldnamen sind die des Servers.
    private struct Kopf: Decodable { let MessageType: String }
    private struct Huelle<D: Decodable>: Decodable { let Data: D }
    private struct Gruppenkopf: Decodable { let `Type`: String }
    private struct Gruppendaten<D: Decodable>: Decodable { let Data: D }
    private struct Zustandsdaten: Decodable { let State: String; let Reason: String? }

    private struct Befehlsdaten: Decodable {
        let GroupId: String
        let PlaylistItemId: String?
        let When: Datumsfeld
        let PositionTicks: Int64?
        let Command: String
        let EmittedAt: Datumsfeld?

        var befehl: SyncPlayBefehl? {
            guard let art = SyncPlayBefehl.Art(rawValue: Command) else { return nil }
            return SyncPlayBefehl(gruppe: GroupId, eintrag: PlaylistItemId, art: art,
                                  wann: When.wert, stelle: PositionTicks.map(SyncPlay.sekunden),
                                  ausgesandt: EmittedAt?.wert)
        }
    }

    private struct Warteschlangendaten: Decodable {
        struct Posten: Decodable { let ItemId: String; let PlaylistItemId: String }
        let Reason: String
        let LastUpdate: Datumsfeld?
        let Playlist: [Posten]?
        let PlayingItemIndex: Int?
        let StartPositionTicks: Int64?
        let IsPlaying: Bool?

        var schlange: SyncPlayWarteschlange {
            SyncPlayWarteschlange(
                grund: Reason, stand: LastUpdate?.wert,
                eintraege: (Playlist ?? []).map { .init(titel: $0.ItemId, eintrag: $0.PlaylistItemId) },
                index: PlayingItemIndex ?? -1,
                startstelle: SyncPlay.sekunden(StartPositionTicks ?? 0),
                laeuft: IsPlaying ?? false)
        }
    }
}

/// Ein Zeitstempel des Servers, mit seinen sieben Nachkommastellen — siehe
/// ``Zeitstempel``.
struct Datumsfeld: Decodable, Sendable {
    let wert: Date
    init(from decoder: any Decoder) throws { wert = try Zeitstempel.lesen(aus: decoder) }
}

extension SyncPlay {
    /// **Millisekunden, UTC, mit `Z`** — so liest der Server `When` in
    /// `Ready` und `Buffering`.
    public static func zeitText(_ datum: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: datum)
    }

    static func zeitLesen(_ text: String) -> Date? {
        let mit = ISO8601DateFormatter()
        mit.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = mit.date(from: text) { return d }
        let ohne = ISO8601DateFormatter()
        ohne.formatOptions = [.withInternetDateTime]
        return ohne.date(from: text)
    }
}

// MARK: - Zeitabgleich

/// **Wie weit die Uhr des Servers von unserer abweicht.**
///
/// Eine Messung sind vier Zeitpunkte: Anfrage gesendet (lokal), empfangen
/// (Server), Antwort gesendet (Server), empfangen (lokal). Daraus der
/// Versatz nach NTP: `((t1 − t0) + (t2 − t3)) / 2`. Gilt die Messung mit der
/// kürzesten Laufzeit der letzten acht — eine lange Laufzeit heißt, das Netz
/// hat irgendwo gewartet, und dann weiß man nicht, auf welchem Weg.
///
/// Genau so misst jellyfin-web (`TimeSync.js`), mit `GET /GetUtcTime`.
public struct Zeitabgleich: Sendable, Equatable {
    public struct Messung: Sendable, Equatable {
        public let gesendet: Date
        public let serverEmpfangen: Date
        public let serverGesendet: Date
        public let empfangen: Date

        public init(gesendet: Date, serverEmpfangen: Date, serverGesendet: Date, empfangen: Date) {
            self.gesendet = gesendet
            self.serverEmpfangen = serverEmpfangen
            self.serverGesendet = serverGesendet
            self.empfangen = empfangen
        }

        /// Server minus lokal, in Sekunden.
        public var versatz: TimeInterval {
            ((serverEmpfangen.timeIntervalSince(gesendet))
             + (serverGesendet.timeIntervalSince(empfangen))) / 2
        }

        /// Hin und zurück, ohne die Zeit, die der Server selbst brauchte.
        public var laufzeit: TimeInterval {
            empfangen.timeIntervalSince(gesendet) - serverGesendet.timeIntervalSince(serverEmpfangen)
        }
    }

    public static let behalten = 8

    public private(set) var messungen: [Messung] = []

    public init() {}

    /// Die Messung, die gilt.
    public var beste: Messung? { messungen.min { $0.laufzeit < $1.laufzeit } }

    public var bereit: Bool { !messungen.isEmpty }

    /// Server minus lokal. Ohne Messung null — dann gilt die eigene Uhr.
    public var versatz: TimeInterval { beste?.versatz ?? 0 }

    /// Eine Richtung, in Millisekunden — so will `/SyncPlay/Ping` es haben.
    public var pingMillisekunden: Int64 {
        Int64(max(0, (beste?.laufzeit ?? 0) / 2 * 1000).rounded())
    }

    public mutating func aufnehmen(_ m: Messung) {
        messungen.append(m)
        if messungen.count > Self.behalten { messungen.removeFirst(messungen.count - Self.behalten) }
    }

    public func lokal(_ server: Date) -> Date { server.addingTimeInterval(-versatz) }
    public func server(_ lokal: Date) -> Date { lokal.addingTimeInterval(versatz) }

    /// Wann gemessen wird: dreimal im Sekundenabstand, danach jede Minute.
    public static func pause(nachMessungen anzahl: Int) -> TimeInterval {
        anzahl < 3 ? 1 : 60
    }
}

// MARK: - Befehle ausführen

/// **Was der Abspieler mit einem Befehl tun soll, und wann.**
///
/// Die Regeln von jellyfin-web (`PlaybackCore.js`):
///
/// - **Weiter in der Zukunft:** bis zum Zeitpunkt warten, vorher an die
///   Stelle springen, falls man merklich daneben steht.
/// - **Weiter in der Vergangenheit:** die Gruppe läuft schon. Sofort los, und
///   zwar an der Stelle, an der sie **jetzt** ist — Stelle plus die Zeit seit
///   dem Befehl.
/// - **Pause:** zum Zeitpunkt anhalten, dann auf die Stelle der Gruppe.
/// - **Springen:** zum Zeitpunkt an die Stelle, angehalten. Danach meldet der
///   Abspieler „bereit", und der Server gibt das Weiter frei.
public struct SyncPlayAusfuehrung: Sendable, Equatable {
    public enum Schritt: Sendable, Equatable { case weiter, pause, springen, stopp }

    public let schritt: Schritt
    /// Wohin vorher (bei Pause: danach) gesprungen wird. `nil` heißt: bleiben.
    public let stelle: Double?
    /// Wie lange ab jetzt gewartet wird.
    public let warten: TimeInterval

    public init(schritt: Schritt, stelle: Double?, warten: TimeInterval) {
        self.schritt = schritt
        self.stelle = stelle
        self.warten = warten
    }

    public static func fuer(_ befehl: SyncPlayBefehl, jetzt: Date, abgleich: Zeitabgleich,
                            lokaleStelle: Double) -> SyncPlayAusfuehrung {
        let wannLokal = abgleich.lokal(befehl.wann)
        let warten = max(0, wannLokal.timeIntervalSince(jetzt))

        func nurWennDaneben(_ ziel: Double?) -> Double? {
            guard let ziel else { return nil }
            return abs(ziel - lokaleStelle) > SyncPlay.sprunggrenze ? max(0, ziel) : nil
        }

        switch befehl.art {
        case .weiter:
            if warten > 0 {
                return .init(schritt: .weiter, stelle: nurWennDaneben(befehl.stelle), warten: warten)
            }
            // Schon vorbei: dorthin, wo die Gruppe jetzt ist.
            let jetztDort = befehl.stelle.map {
                geschaetzteStelle(stelle: $0, gueltigAb: befehl.wann, jetzt: jetzt, abgleich: abgleich)
            }
            return .init(schritt: .weiter, stelle: nurWennDaneben(jetztDort), warten: 0)
        case .pause:
            return .init(schritt: .pause, stelle: nurWennDaneben(befehl.stelle), warten: warten)
        case .springen:
            return .init(schritt: .springen, stelle: befehl.stelle.map { max(0, $0) }, warten: warten)
        case .stopp:
            return .init(schritt: .stopp, stelle: nil, warten: warten)
        }
    }

    /// Wo die Gruppe jetzt ist, wenn sie seit `gueltigAb` (Serverzeit) ab
    /// `stelle` läuft.
    public static func geschaetzteStelle(stelle: Double, gueltigAb: Date, jetzt: Date,
                                         abgleich: Zeitabgleich) -> Double {
        stelle + max(0, abgleich.server(jetzt).timeIntervalSince(gueltigAb))
    }

    /// **Welche Stelle „bereit" nach einem Sprung meldet.**
    ///
    /// Der Server nimmt sie auf eine halbe Sekunde genau (`MaxPlaybackOffset`)
    /// und schickt sonst den Sprung noch einmal. Nach dem Anspielen steht VLC
    /// ein paar Zehntel hinter dem Ziel; das ist dieselbe Stelle, nicht eine
    /// neue. Erst ab einer Sekunde gilt die gemessene — dann ist der Sprung
    /// wirklich woanders gelandet, und das soll der Server wissen.
    public static func bereitStelle(ziel: Double, ist: Double) -> Double {
        abs(ist - ziel) <= 1 ? ziel : ist
    }

    /// **Nachführen im Lauf.** Gibt die Stelle zurück, an die gesprungen
    /// werden soll, oder `nil`, solange man nah genug dran ist. Nur nach
    /// einem „Weiter", und nur für den Eintrag, der gerade läuft.
    public static func nachfuehren(letzter: SyncPlayBefehl?, eintrag: String?, jetzt: Date,
                                   abgleich: Zeitabgleich, lokaleStelle: Double) -> Double? {
        guard let letzter, letzter.art == .weiter, let stelle = letzter.stelle,
              letzter.eintrag == nil || letzter.eintrag == eintrag,
              abgleich.lokal(letzter.wann) <= jetzt else { return nil }
        let soll = geschaetzteStelle(stelle: stelle, gueltigAb: letzter.wann, jetzt: jetzt,
                                     abgleich: abgleich)
        return abs(soll - lokaleStelle) > SyncPlay.driftgrenze ? soll : nil
    }
}

// MARK: - Puffern melden

/// **Steht der Film, obwohl er laufen soll?**
///
/// Dann muss die Gruppe es wissen (`Buffering`), sonst läuft sie dem einen
/// davon. Und sobald es weitergeht, „bereit" (`Ready`). Gemessen wird an der
/// Stelle, nicht an VLCs Zustand: der meldet das Puffern je nach Quelle gar
/// nicht oder im Sekundentakt.
public struct Pufferwaechter: Sendable, Equatable {
    public enum Meldung: Sendable, Equatable { case puffert, bereit }

    /// So lange ohne Fortschritt, bevor es als Puffern gilt.
    public static let frist: TimeInterval = 3

    public private(set) var puffert = false
    private var letzteStelle: Double?
    private var stehtSeit: Date?

    public init() {}

    public mutating func takt(stelle: Double, sollLaufen: Bool, jetzt: Date) -> Meldung? {
        defer { letzteStelle = stelle }
        guard sollLaufen else {
            stehtSeit = nil
            return nil
        }
        let bewegt = letzteStelle.map { stelle - $0 > 0.05 } ?? false
        if bewegt {
            stehtSeit = nil
            if puffert { puffert = false; return .bereit }
            return nil
        }
        if stehtSeit == nil { stehtSeit = jetzt }
        if !puffert, let seit = stehtSeit, jetzt.timeIntervalSince(seit) >= Self.frist {
            puffert = true
            return .puffert
        }
        return nil
    }

    /// Nach einem Sprung oder einem neuen Titel von vorn zählen.
    public mutating func zuruecksetzen() {
        puffert = false
        letzteStelle = nil
        stehtSeit = nil
    }
}

// MARK: - Aufrufe

/// Das Recht, das der Betreiber je Konto setzt (`Policy.SyncPlayAccess`).
public enum SyncPlayRecht: String, Sendable, Equatable {
    case anlegenUndBeitreten = "CreateAndJoinGroups"
    case beitreten = "JoinGroups"
    case keins = "None"

    public var darfAnlegen: Bool { self == .anlegenUndBeitreten }
    public var darfBeitreten: Bool { self != .keins }
}

extension JellyfinClient {

    /// Das SyncPlay-Recht des Kontos. `nil`, wenn der Server nichts sagt —
    /// dann entscheidet er beim Aufruf selbst.
    public func syncPlayRecht() async -> SyncPlayRecht? {
        struct Antwort: Decodable {
            struct Policy: Decodable { let SyncPlayAccess: String? }
            let Policy: Policy?
        }
        guard let s = try? requireSessionForReporting(),
              let req = try? rohAnfrage("Users/\(s.userID)", method: "GET"),
              let (daten, antwort) = try? await rohSitzung.data(for: req),
              let http = antwort as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let wert = try? JSONDecoder().decode(Antwort.self, from: daten).Policy?.SyncPlayAccess
        else { return nil }
        return SyncPlayRecht(rawValue: wert)
    }

    /// Alle Gruppen, die dieses Konto sehen darf.
    public func syncPlayGruppen() async throws -> [SyncPlayGruppe] {
        let req = try rohAnfrage("SyncPlay/List", method: "GET")
        let daten = try await syncPlaySenden(req)
        do {
            return try JSONDecoder().decode([SyncPlayGruppe].self, from: daten)
        } catch {
            throw JellyfinError.decoding(String(describing: error))
        }
    }

    public func syncPlayAnlegen(name: String) async throws {
        _ = try await syncPlaySenden(try syncPlayAnfrage("SyncPlay/New", ["GroupName": name]))
    }

    public func syncPlayBeitreten(_ gruppe: String) async throws {
        _ = try await syncPlaySenden(try syncPlayAnfrage("SyncPlay/Join", ["GroupId": gruppe]))
    }

    public func syncPlayVerlassen() async throws {
        _ = try await syncPlaySenden(try syncPlayAnfrage("SyncPlay/Leave", nil))
    }

    /// Setzt, was die Gruppe schaut. Alle laden es, dann hält die Gruppe an
    /// der Startstelle, bis jemand „Weiter" drückt.
    public func syncPlayWarteschlange(_ titel: [String], ab sekunden: Double = 0) async throws {
        _ = try await syncPlaySenden(try syncPlayAnfrage("SyncPlay/SetNewQueue", [
            "PlayingQueue": titel, "PlayingItemPosition": 0,
            "StartPositionTicks": SyncPlay.ticks(sekunden),
        ]))
    }

    public func syncPlayBitteWeiter() async throws {
        _ = try await syncPlaySenden(try syncPlayAnfrage("SyncPlay/Unpause", nil))
    }

    public func syncPlayBittePause() async throws {
        _ = try await syncPlaySenden(try syncPlayAnfrage("SyncPlay/Pause", nil))
    }

    public func syncPlayBitteSpringen(auf sekunden: Double) async throws {
        _ = try await syncPlaySenden(try syncPlayAnfrage("SyncPlay/Seek", [
            "PositionTicks": SyncPlay.ticks(max(0, sekunden)),
        ]))
    }

    /// `Ready` oder `Buffering`. `wann` ist **Serverzeit**.
    public func syncPlayStand(bereit: Bool, wann: Date, stelle: Double, laeuft: Bool,
                              eintrag: String) async throws {
        _ = try await syncPlaySenden(try syncPlayAnfrage(bereit ? "SyncPlay/Ready" : "SyncPlay/Buffering", [
            "When": SyncPlay.zeitText(wann),
            "PositionTicks": SyncPlay.ticks(max(0, stelle)),
            "IsPlaying": laeuft,
            "PlaylistItemId": eintrag,
        ]))
    }

    public func syncPlayPing(millisekunden: Int64) async throws {
        _ = try await syncPlaySenden(try syncPlayAnfrage("SyncPlay/Ping", ["Ping": millisekunden]))
    }

    /// Eine Messung für den ``Zeitabgleich``.
    public func serverzeitMessen() async throws -> Zeitabgleich.Messung {
        struct Antwort: Decodable {
            let RequestReceptionTime: String
            let ResponseTransmissionTime: String
        }
        let req = try rohAnfrage("GetUtcTime", method: "GET")
        let gesendet = Date()
        let daten = try await syncPlaySenden(req)
        let empfangen = Date()
        guard let a = try? JSONDecoder().decode(Antwort.self, from: daten),
              let rein = SyncPlay.zeitLesen(a.RequestReceptionTime),
              let raus = SyncPlay.zeitLesen(a.ResponseTransmissionTime) else {
            throw JellyfinError.decoding("GetUtcTime")
        }
        return .init(gesendet: gesendet, serverEmpfangen: rein, serverGesendet: raus,
                     empfangen: empfangen)
    }

    private func syncPlayAnfrage(_ pfad: String, _ rumpf: [String: Any]?) throws -> URLRequest {
        var req = try rohAnfrage(pfad, method: "POST")
        if let rumpf {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: rumpf)
        }
        return req
    }

    private func syncPlaySenden(_ req: URLRequest) async throws -> Data {
        let (daten, antwort): (Data, URLResponse)
        do {
            (daten, antwort) = try await rohSitzung.data(for: req)
        } catch {
            throw JellyfinError(anfrage: error)
        }
        guard let http = antwort as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine HTTP-Antwort.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: daten.prefix(300), encoding: .utf8))
        }
        return daten
    }
}
