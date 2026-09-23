import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Zugangsdaten der Anwendung

/// **Die Kennung der Trakt-Anwendung — nicht die eines Nutzers.**
///
/// Trakt verlangt, dass jede App bei trakt.tv/oauth/applications angelegt
/// ist; von dort kommen `client_id` und `client_secret`. Beide stehen
/// **nicht im Repo**: das ist öffentlich, und wer sie hat, spricht im Namen
/// von Swiftly mit Trakt.
///
/// Sie liegen deshalb in einer Datei, die `.gitignore` sperrt:
///
///     Packages/JellyfinKit/Sources/JellyfinKit/Resources/Trakt.json
///     {"client_id": "…", "client_secret": "…"}
///
/// **Eine Datei für alle Fassungen, die das Paket bauen.** Apple, Linux und
/// Windows nehmen sie über das Ressourcenbündel des Pakets mit; ein
/// `.xcconfig` hätte nur die Apple-Ziele erreicht, und für Linux und Windows
/// hätte es einen zweiten Weg gebraucht, der auseinanderläuft. Android hat
/// kein `Bundle.module` (siehe `Uebersetzung.swift`) und reicht die Werte
/// über ``init(clientID:secret:)`` herein.
///
/// **Fehlt die Datei, gibt es kein Trakt** — ``ausPaket`` ist dann `nil`,
/// und die Einstellung dazu steht gar nicht erst da. Ein Bau ohne Zugang ist
/// also kein kaputter Bau, sondern einer ohne diese Zugabe.
///
/// Dass ein Geheimnis in einer ausgelieferten App herauszulösen ist, gilt
/// für jede native Trakt-App (Plezy trägt es sogar im Quelltext). Es schützt
/// nicht das Konto eines Nutzers — dafür gibt es dessen eigenen Token —,
/// sondern nur den Namen der Anwendung.
public struct TraktZugang: Sendable, Equatable {
    public let clientID: String
    public let secret: String

    public init(clientID: String, secret: String) {
        self.clientID = clientID
        self.secret = secret
    }

    /// Liest die Konfigurationsdatei. `nil`, wenn ein Wert fehlt oder leer
    /// ist — ein halber Zugang wäre ein Knopf, der garantiert scheitert.
    public static func lesen(_ daten: Data) -> TraktZugang? {
        struct Datei: Decodable {
            let client_id: String?
            let client_secret: String?
        }
        guard let datei = try? JSONDecoder().decode(Datei.self, from: daten) else { return nil }
        let id = (datei.client_id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let geheim = (datei.client_secret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !geheim.isEmpty else { return nil }
        return TraktZugang(clientID: id, secret: geheim)
    }

    #if os(Android)
    /// Auf Android gibt es kein Ressourcenbündel — die App reicht die Werte
    /// selbst herein.
    public static let ausPaket: TraktZugang? = nil
    #else
    /// Der Zugang aus `Resources/Trakt.json`, einmal gelesen.
    public static let ausPaket: TraktZugang? = {
        guard let url = Bundle.module.url(forResource: "Trakt", withExtension: "json"),
              let daten = try? Data(contentsOf: url) else { return nil }
        return lesen(daten)
    }()
    #endif
}

// MARK: - Token eines Nutzers

/// Was nach dem Verbinden gespeichert wird. Auf Apple im Schlüsselbund, auf
/// Linux und Windows in einer Datei mit denselben Rechten wie die
/// Jellyfin-Sitzung.
public struct TraktToken: Codable, Sendable, Equatable {
    public var zugriff: String
    public var erneuerung: String
    public var ablauf: Date
    /// Der Name bei Trakt — nur für die Anzeige „Verbunden als …".
    public var benutzer: String?

    public init(zugriff: String, erneuerung: String, ablauf: Date, benutzer: String? = nil) {
        self.zugriff = zugriff
        self.erneuerung = erneuerung
        self.ablauf = ablauf
        self.benutzer = benutzer
    }

    /// **Eine Stunde vor Ablauf erneuern, nicht erst danach.** Wie lange ein
    /// Token gilt, sagt Trakt in `expires_in`, und das kann nur ein Tag sein.
    /// Wer bis zum 401 wartet, schickt jede erste Meldung des Tages zweimal.
    public func erneuernFaellig(jetzt: Date = Date()) -> Bool {
        ablauf.timeIntervalSince(jetzt) < 3600
    }

    /// Aus der Antwort von `/oauth/device/token` oder `/oauth/token`.
    static func aus(_ daten: Data, jetzt: Date = Date()) -> TraktToken? {
        struct Antwort: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Double?
            let created_at: Double?
        }
        guard let a = try? JSONDecoder().decode(Antwort.self, from: daten) else { return nil }
        let beginn = a.created_at.map { Date(timeIntervalSince1970: $0) } ?? jetzt
        return TraktToken(zugriff: a.access_token, erneuerung: a.refresh_token,
                          ablauf: beginn.addingTimeInterval(a.expires_in ?? 86_400))
    }
}

// MARK: - Gerätecode

/// **Anmelden ohne Browser in der App** — der Weg, den Trakt für Fernseher
/// vorsieht, und der auf jedem Gerät gleich geht: die App zeigt einen Code
/// und eine Adresse, der Nutzer gibt den Code auf einem beliebigen Gerät
/// bei Trakt ein, und die App fragt im Takt nach, ob er freigegeben ist.
public struct TraktGeraetecode: Sendable, Equatable {
    /// Geht nur an Trakt zurück, nie auf den Schirm.
    public let geraetecode: String
    /// Das, was der Nutzer abtippt.
    public let nutzercode: String
    /// Meist `https://trakt.tv/activate`.
    public let adresse: URL
    /// Wie lange der Code gilt, in Sekunden (bei Trakt zehn Minuten).
    public let gueltig: TimeInterval
    /// Wie oft nachgefragt werden darf, in Sekunden.
    public let abstand: TimeInterval

    public init(geraetecode: String, nutzercode: String, adresse: URL,
                gueltig: TimeInterval, abstand: TimeInterval) {
        self.geraetecode = geraetecode
        self.nutzercode = nutzercode
        self.adresse = adresse
        self.gueltig = gueltig
        self.abstand = abstand
    }

    /// Die Adresse mit dem Code darin — dann muss auf dem Telefon nichts
    /// getippt werden. Für den QR-Code auf dem Fernseher und den Knopf auf
    /// iPhone und Mac.
    public var direktadresse: URL { adresse.appendingPathComponent(nutzercode) }

    /// Die Adresse ohne `https://`, zum Abtippen.
    public var adresseKurz: String {
        var text = adresse.absoluteString
        for vorsatz in ["https://", "http://"] where text.hasPrefix(vorsatz) {
            text.removeFirst(vorsatz.count)
        }
        return text
    }

    static func aus(_ daten: Data) -> TraktGeraetecode? {
        struct Antwort: Decodable {
            let device_code: String
            let user_code: String
            let verification_url: String
            let expires_in: Double
            let interval: Double
        }
        guard let a = try? JSONDecoder().decode(Antwort.self, from: daten),
              let url = URL(string: a.verification_url) else { return nil }
        return TraktGeraetecode(geraetecode: a.device_code, nutzercode: a.user_code,
                                adresse: url, gueltig: a.expires_in,
                                abstand: max(1, a.interval))
    }
}

/// Was eine Nachfrage bei `/oauth/device/token` ergibt.
public enum TraktFreigabe: Sendable, Equatable {
    case erteilt(TraktToken)
    /// 400 — der Nutzer hat den Code noch nicht eingegeben.
    case ausstehend
    /// 429 — zu oft gefragt; der Abstand wird größer.
    case langsamer
    /// 404 oder 410 — Code unbekannt oder abgelaufen.
    case abgelaufen
    /// 409 oder 418 — schon benutzt oder abgelehnt.
    case abgelehnt

    static func aus(status: Int, daten: Data) -> TraktFreigabe {
        switch status {
        case 200:
            guard let token = TraktToken.aus(daten) else { return .ausstehend }
            return .erteilt(token)
        case 404, 410: return .abgelaufen
        case 409, 418: return .abgelehnt
        case 429:      return .langsamer
        // 400 heisst „noch nicht"; alles andere ist ein Schluckauf, und der
        // nächste Takt fragt ohnehin wieder.
        default:       return .ausstehend
        }
    }
}

public enum TraktFehler: Error, Equatable, Sendable {
    /// Unerwartete Antwort, mit dem HTTP-Status.
    case status(Int)
    /// 429. Trakt nennt in `Retry-After`, wie lange zu warten ist.
    case ratenlimit(nachSekunden: TimeInterval?)
    /// Der Erneuerungstoken gilt nicht mehr — der Nutzer muss neu verbinden.
    case abgemeldet
    case codeAbgelaufen
    case abgelehnt
    case unlesbar
}

// MARK: - Welcher Titel

/// Die Kennungen, über die Trakt einen Titel findet.
///
/// **Kein eigener Abgleich über den Namen.** Jellyfin kennt IMDb, TMDB und
/// TVDB aus seinen Metadaten (`ProviderIds`), und Trakt nimmt genau die an.
/// Ein Titel ohne eine davon wird nicht gemeldet — lieber nichts als die
/// falsche Folge im Verlauf.
public struct TraktKennungen: Sendable, Equatable, Encodable {
    public var imdb: String?
    public var tmdb: Int?
    public var tvdb: Int?

    public init(imdb: String? = nil, tmdb: Int? = nil, tvdb: Int? = nil) {
        self.imdb = imdb
        self.tmdb = tmdb
        self.tvdb = tvdb
    }

    /// Aus Jellyfins `ProviderIds`. Die Schlüssel heißen dort `Imdb`,
    /// `Tmdb`, `Tvdb`; die Groß- und Kleinschreibung schwankt zwischen
    /// Plugins, also wird sie nicht beachtet.
    public init(anbieter: [String: String]?) {
        var imdb: String?, tmdb: Int?, tvdb: Int?
        for (schluessel, wert) in anbieter ?? [:] {
            let w = wert.trimmingCharacters(in: .whitespaces)
            switch schluessel.lowercased() {
            // Eine IMDb-Kennung beginnt mit „tt"; alles andere ist ein
            // Plugin, das dort etwas Eigenes ablegt.
            case "imdb" where w.hasPrefix("tt"): imdb = w
            case "tmdb": tmdb = Int(w).flatMap { $0 > 0 ? $0 : nil }
            case "tvdb": tvdb = Int(w).flatMap { $0 > 0 ? $0 : nil }
            default: break
            }
        }
        self.init(imdb: imdb, tmdb: tmdb, tvdb: tvdb)
    }

    public var leer: Bool { imdb == nil && tmdb == nil && tvdb == nil }
}

/// Was an Trakt gemeldet wird: ein Film oder eine Folge.
public enum TraktZiel: Sendable, Equatable {
    case film(TraktKennungen)
    /// **Die Serie plus Staffel und Nummer** — so, wie Plezy es macht, und
    /// aus demselben Grund: das trägt auch dann, wenn Trakt die einzelne
    /// Folge (noch) nicht unter ihrer eigenen Kennung führt.
    case folge(serie: TraktKennungen, staffel: Int, nummer: Int)
    /// Nur, wenn die Serie keine Kennung trägt, die Folge aber schon.
    case folgeSelbst(TraktKennungen)

    /// - Parameters:
    ///   - titel: der laufende Titel, frisch vom Server (`Items/{id}`
    ///     liefert `ProviderIds` immer mit, Listeneinträge nicht).
    ///   - serie: bei einer Folge deren Serie, sonst `nil`.
    public static func aus(titel: Item, serie: Item?) -> TraktZiel? {
        switch titel.type {
        case "Movie":
            let k = TraktKennungen(anbieter: titel.providerIds)
            return k.leer ? nil : .film(k)
        case "Episode":
            let s = TraktKennungen(anbieter: serie?.providerIds)
            if !s.leer, let staffel = titel.parentIndexNumber, let nummer = titel.indexNumber {
                return .folge(serie: s, staffel: staffel, nummer: nummer)
            }
            let eigen = TraktKennungen(anbieter: titel.providerIds)
            return eigen.leer ? nil : .folgeSelbst(eigen)
        default:
            // Musikvideos, Fernsehen, Heimvideos: kennt Trakt nicht.
            return nil
        }
    }

    /// Der Rumpf für `/scrobble/*`. Fortschritt in Prozent, 0 bis 100.
    func rumpf(fortschritt: Double) -> Data {
        struct Kennungshuelle: Encodable { let ids: TraktKennungen }
        struct Folgenangabe: Encodable { let season: Int; let number: Int }
        struct Rumpf: Encodable {
            var movie: Kennungshuelle?
            var show: Kennungshuelle?
            var episode: FolgenOderKennung?
            let progress: Double
        }
        enum FolgenOderKennung: Encodable {
            case angabe(Folgenangabe)
            case kennung(Kennungshuelle)
            func encode(to encoder: any Encoder) throws {
                switch self {
                case let .angabe(a): try a.encode(to: encoder)
                case let .kennung(k): try k.encode(to: encoder)
                }
            }
        }
        let p = (min(100, max(0, fortschritt)) * 100).rounded() / 100
        var r = Rumpf(progress: p)
        switch self {
        case let .film(k):
            r.movie = Kennungshuelle(ids: k)
        case let .folge(serie, staffel, nummer):
            r.show = Kennungshuelle(ids: serie)
            r.episode = .angabe(Folgenangabe(season: staffel, number: nummer))
        case let .folgeSelbst(k):
            r.episode = .kennung(Kennungshuelle(ids: k))
        }
        let kodierer = JSONEncoder()
        kodierer.outputFormatting = .sortedKeys
        return (try? kodierer.encode(r)) ?? Data()
    }
}

public extension TraktZiel {
    /// **Holt, was für die Zuordnung fehlt** — den Titel frisch (mit
    /// `ProviderIds`) und bei einer Folge die Serie dazu.
    ///
    /// Zwei Anfragen an den eigenen Server beim Start einer Wiedergabe, nicht
    /// mehr. Scheitert eine, gibt es eben keine Trakt-Meldung; die Wiedergabe
    /// merkt davon nichts.
    static func aufloesen(_ titel: Item, client: JellyfinClient) async -> TraktZiel? {
        let frisch = (titel.providerIds == nil ? try? await client.item(id: titel.id) : nil) ?? titel
        var serie: Item?
        if frisch.type == "Episode", let id = frisch.seriesId {
            serie = try? await client.item(id: id)
        }
        return aus(titel: frisch, serie: serie)
    }
}

// MARK: - Die Verbindung zu Trakt

/// Was eine Leitung zurückgibt — Status, Rumpf und die eine Kopfzeile, die
/// hier gebraucht wird.
public struct TraktAntwort: Sendable {
    public let status: Int
    public let daten: Data
    public let wiederholenNach: TimeInterval?

    public init(status: Int, daten: Data = Data(), wiederholenNach: TimeInterval? = nil) {
        self.status = status
        self.daten = daten
        self.wiederholenNach = wiederholenNach
    }
}

/// Der Weg ins Netz, austauschbar — die Tests setzen eine Attrappe ein und
/// schicken keine einzige echte Anfrage an Trakt.
public typealias TraktLeitung = @Sendable (URLRequest) async throws -> TraktAntwort

public struct TraktClient: Sendable {
    public static let basis = URL(string: "https://api.trakt.tv")!

    public let zugang: TraktZugang
    private let leitung: TraktLeitung

    public init(zugang: TraktZugang, leitung: @escaping TraktLeitung = TraktClient.netz) {
        self.zugang = zugang
        self.leitung = leitung
    }

    /// **Eine eigene, kurze Sitzung, nicht `ortsnetzfaehig`.** Trakt steht
    /// im Internet; auf eine Ortsnetz-Erlaubnis zu warten hätte keinen Sinn,
    /// und eine Meldung, die nach zehn Sekunden nicht durch ist, ist ohnehin
    /// überholt.
    public static let netz: TraktLeitung = { anfrage in
        let (daten, antwort) = try await sitzung.data(for: anfrage)
        let http = antwort as? HTTPURLResponse
        let nach = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
        return TraktAntwort(status: http?.statusCode ?? 0, daten: daten, wiederholenNach: nach)
    }

    private static let sitzung: URLSession = {
        let k = URLSessionConfiguration.ephemeral
        k.timeoutIntervalForRequest = 10
        k.timeoutIntervalForResource = 15
        return URLSession(configuration: k)
    }()

    // MARK: Anmelden

    /// `POST /oauth/device/code`.
    public func geraetecode() async throws -> TraktGeraetecode {
        let a = try await senden("oauth/device/code", rumpf: ["client_id": zugang.clientID])
        guard a.status == 200 else { throw Self.fehler(a) }
        guard let code = TraktGeraetecode.aus(a.daten) else { throw TraktFehler.unlesbar }
        return code
    }

    /// Eine einzelne Nachfrage bei `POST /oauth/device/token`.
    public func freigabe(_ code: TraktGeraetecode) async -> TraktFreigabe {
        guard let a = try? await senden("oauth/device/token", rumpf: [
            "code": code.geraetecode,
            "client_id": zugang.clientID,
            "client_secret": zugang.secret,
        ]) else { return .ausstehend }
        return TraktFreigabe.aus(status: a.status, daten: a.daten)
    }

    /// **Fragt im Takt, bis der Code freigegeben ist.**
    ///
    /// Endet mit dem Token, mit ``TraktFehler/codeAbgelaufen`` oder
    /// ``TraktFehler/abgelehnt`` — oder mit `CancellationError`, wenn die
    /// Seite geschlossen wird. `schlafen` ist nur für die Tests austauschbar;
    /// die Frist zählt die geschlafene Zeit, nicht die Uhr, damit ein Test
    /// nicht zehn Minuten wartet.
    public func freigabeAbwarten(
        _ code: TraktGeraetecode,
        schlafen: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async throws -> TraktToken {
        var abstand = code.abstand
        var verstrichen: TimeInterval = 0
        while verstrichen < code.gueltig {
            try await schlafen(abstand)
            verstrichen += abstand
            try Task.checkCancellation()
            switch await freigabe(code) {
            case let .erteilt(token): return token
            case .ausstehend:         continue
            // RFC 8628: bei „slow down" fünf Sekunden drauf, und zwar
            // dauerhaft — nicht nur für den nächsten Versuch.
            case .langsamer:          abstand += 5
            case .abgelaufen:         throw TraktFehler.codeAbgelaufen
            case .abgelehnt:          throw TraktFehler.abgelehnt
            }
        }
        throw TraktFehler.codeAbgelaufen
    }

    /// `POST /oauth/token` mit dem Erneuerungstoken.
    ///
    /// **400 und 401 heißen: dieser Zugang ist tot.** Trakt gibt beim
    /// Erneuern einen *neuen* Erneuerungstoken aus; wer den alten ein zweites
    /// Mal schickt oder dessen App getrennt wurde, bekommt `invalid_grant`.
    /// Dann hilft nur neu verbinden — alles andere (5xx, keine Verbindung)
    /// ist vorübergehend, und der alte Token bleibt.
    public func erneuern(_ token: TraktToken) async throws -> TraktToken {
        let a = try await senden("oauth/token", rumpf: [
            "refresh_token": token.erneuerung,
            "client_id": zugang.clientID,
            "client_secret": zugang.secret,
            "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
            "grant_type": "refresh_token",
        ])
        switch a.status {
        case 200:
            guard var neu = TraktToken.aus(a.daten) else { throw TraktFehler.unlesbar }
            neu.benutzer = token.benutzer
            return neu
        case 400, 401, 403: throw TraktFehler.abgemeldet
        default: throw Self.fehler(a)
        }
    }

    /// `POST /oauth/revoke` — beim Trennen. Gelingt es nicht, ist der Token
    /// hier trotzdem weg; bei Trakt läuft er dann nach einem Tag ab.
    public func widerrufen(_ token: TraktToken) async {
        _ = try? await senden("oauth/revoke", rumpf: [
            "token": token.zugriff,
            "client_id": zugang.clientID,
            "client_secret": zugang.secret,
        ])
    }

    /// Der Name bei Trakt, für „Verbunden als …". `GET /users/settings`.
    public func benutzername(_ token: TraktToken) async -> String? {
        struct Antwort: Decodable {
            struct Nutzer: Decodable { let username: String?; let name: String? }
            let user: Nutzer?
        }
        guard let a = try? await senden("users/settings", methode: "GET", token: token.zugriff),
              a.status == 200,
              let antwort = try? JSONDecoder().decode(Antwort.self, from: a.daten) else { return nil }
        return antwort.user?.username ?? antwort.user?.name
    }

    // MARK: Melden

    public enum Schritt: String, Sendable {
        case start, pause, stop
    }

    /// `POST /scrobble/{start|pause|stop}`.
    ///
    /// **409 ist kein Fehler.** Trakt antwortet so, wenn derselbe Titel
    /// gerade erst gemeldet wurde — beim zweiten Stopp, beim Neustart kurz
    /// nach dem Ende. Gemeint ist „schon erledigt", und genau so wird es
    /// behandelt.
    ///
    /// Den Rest der Regel macht Trakt selbst: ein Stopp ab 80 % trägt den
    /// Titel als gesehen ein, darunter gilt er als angehalten.
    public func melden(_ schritt: Schritt, ziel: TraktZiel, fortschritt: Double,
                       token: String) async throws {
        let a = try await senden("scrobble/\(schritt.rawValue)", daten: ziel.rumpf(fortschritt: fortschritt),
                                 token: token)
        switch a.status {
        case 200, 201, 409: return
        default: throw Self.fehler(a)
        }
    }

    // MARK: Unterbau

    private func senden(_ pfad: String, methode: String = "POST", rumpf: [String: String]? = nil,
                        token: String? = nil) async throws -> TraktAntwort {
        let daten = try rumpf.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        return try await senden(pfad, methode: methode, daten: daten, token: token)
    }

    private func senden(_ pfad: String, methode: String = "POST", daten: Data?,
                        token: String? = nil) async throws -> TraktAntwort {
        var anfrage = URLRequest(url: Self.basis.appendingPathComponent(pfad))
        anfrage.httpMethod = methode
        anfrage.httpBody = daten
        anfrage.setValue("application/json", forHTTPHeaderField: "Content-Type")
        anfrage.setValue("2", forHTTPHeaderField: "trakt-api-version")
        anfrage.setValue(zugang.clientID, forHTTPHeaderField: "trakt-api-key")
        // Trakt sitzt hinter Cloudflare, und das weist Anfragen ohne
        // Absender gelegentlich ab.
        anfrage.setValue("Swiftly", forHTTPHeaderField: "User-Agent")
        if let token { anfrage.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await leitung(anfrage)
    }

    static func fehler(_ a: TraktAntwort) -> TraktFehler {
        a.status == 429 ? .ratenlimit(nachSekunden: a.wiederholenNach) : .status(a.status)
    }
}
