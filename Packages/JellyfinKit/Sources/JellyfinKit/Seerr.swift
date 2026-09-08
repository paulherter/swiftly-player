import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Jellyseerr und Overseerr — suchen, was der Server **nicht** hat, und es
/// anfragen.
///
/// **Warum die halbe Anbindung hier steht und nicht in einer Ansicht.** Was
/// ein Suchtreffer bedeutet, welcher Stand welche Handlung erlaubt und wie
/// aus einer Antwort ein Eintrag wird, ist auf allen sechs Plattformen
/// dieselbe Frage — und ohne Simulator prüfbar. Die Ansicht entscheidet
/// hinterher nur noch, wie es aussieht.
///
/// **Die Anmeldung läuft über Jellyfin, nicht über ein eigenes Konto.** Seerr
/// nimmt unter `/api/v1/auth/jellyfin` denselben Benutzernamen und dasselbe
/// Passwort wie der Medienserver und legt dafür eine Sitzung an — als
/// **Keks**, nicht als Merkmal im Kopf. Deshalb hält `Seerrzugang` eine
/// Zeichenkette, die aussieht wie ein Token und keiner ist.

/// Wie weit ein Titel bei Seerr ist.
///
/// Die Zahlen kommen aus der Schnittstelle und stehen dort wörtlich so:
/// `1 = UNKNOWN, 2 = PENDING, 3 = PROCESSING, 4 = PARTIALLY_AVAILABLE,
/// 5 = AVAILABLE, 6 = DELETED`. Sie werden nicht umbenannt — wer sie im
/// Protokoll sieht, soll sie in Seerrs eigener Oberfläche wiederfinden.
public enum Seerrstand: Int, Codable, Sendable, Equatable {
    /// Niemand hat es angefragt. Der einzige Stand, der einen Knopf verdient.
    case offen = 1
    case wartetAufFreigabe = 2
    case laedt = 3
    case teilweiseDa = 4
    case da = 5
    case geloescht = 6

    /// Darf der Nutzer hier anfragen?
    ///
    /// **Ein Stand ist keine Schaltfläche.** Was wartet oder lädt, lässt sich
    /// nicht noch einmal anfragen; ein Knopf daneben wäre eine Behauptung, es
    /// gäbe etwas zu tun. Bei `teilweiseDa` schon — dort fehlen Staffeln, und
    /// genau die kann man nachfordern.
    public var anfragbar: Bool {
        switch self {
        case .offen, .geloescht, .teilweiseDa: true
        case .wartetAufFreigabe, .laedt, .da: false
        }
    }

    /// Liegt der Titel schon auf dem Server? Dann gehört er in den oberen
    /// Block, nicht in den unteren.
    public var schonDa: Bool { self == .da }
}

/// Ein Treffer von Seerr — ein Titel, den der eigene Server (noch) nicht hat.
public struct Seerrtreffer: Sendable, Hashable, Identifiable, Codable {
    /// Die Kennung bei TMDB. Seerr nimmt sie beim Anfragen als `mediaId`.
    public let id: Int
    /// `movie` oder `tv`. Personen fallen beim Einlesen heraus.
    public let art: String
    public let titel: String
    public let jahr: Int?
    public let plakatPfad: String?
    /// Das **Querbild**, nicht das Plakat.
    ///
    /// TMDB liefert beides getrennt, und der Kopf einer Detailseite braucht
    /// das Querbild: ein hochgezogenes Plakat ist zu hoch, drückt alles
    /// darunter nach unten und war nie dafür gedacht.
    public let kulissePfad: String?
    public let stand: Seerrstand

    public var istSerie: Bool { art == "tv" }

    /// Die Bildadresse bei TMDB.
    ///
    /// **Nicht von Seerr, sondern von TMDB.** Seerr liefert nur den Pfad;
    /// das Bild holt der Nutzer direkt, ohne Umweg über den eigenen Server
    /// und ohne Merkmal. `w342` ist die kleinste Grösse, die auf einem
    /// Plakat in einem Raster nicht weich aussieht.
    public func plakat(breite: Int = 342) -> URL? {
        Self.tmdb(plakatPfad, breite: breite)
    }

    /// Das Querbild für den Kopf einer Seite. **Nur das Querbild** — fehlt
    /// es, kommt nichts zurück statt eines hochgezogenen Plakats.
    public func kulisse(breite: Int = 780) -> URL? {
        Self.tmdb(kulissePfad, breite: breite)
    }

    private static func tmdb(_ pfad: String?, breite: Int) -> URL? {
        guard let pfad, !pfad.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w\(breite)\(pfad)")
    }
}


/// Ein Mensch aus der Besetzung.
///
/// **Rolle, nicht Beruf.** Seerr fuehrt unter `credits.cast` die Darsteller
/// mit ihrer Figur; die Crew steht daneben und gehoert nicht auf eine Seite,
/// auf der man einen Titel anfragt.
public struct Seerrperson: Sendable, Hashable, Identifiable, Codable {
    public let id: Int
    public let name: String
    /// Die Figur, die er spielt. Kann fehlen.
    public let rolle: String?
    public let bildPfad: String?

    /// Das Portraet bei TMDB. `w185` ist die kleinste Groesse, die auf einem
    /// 76er Kreis nicht weich wird.
    public func bild(breite: Int = 185) -> URL? {
        guard let bildPfad, !bildPfad.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w\(breite)\(bildPfad)")
    }
}

/// Eine Staffel, wie Seerr sie kennt.
public struct Seerrstaffel: Sendable, Hashable, Identifiable, Codable {
    /// Die Nummer, so wie sie beim Anfragen wieder hinausgeht.
    public let nummer: Int
    public let folgen: Int
    /// Was der eigene Server davon schon hat.
    public let stand: Seerrstand

    public var id: Int { nummer }
    /// Staffel 0 ist bei TMDB das Sammelbecken für Specials.
    public var istSpecials: Bool { nummer == 0 }
}

/// Was auf der Seite eines Titels steht, den es noch nicht gibt.
public struct Seerrdetail: Sendable, Equatable, Codable {
    public let beschreibung: String?
    /// Höchstens zwei — mehr passt nicht in eine Nebenzeile, und die dritte
    /// sagt ohnehin nichts mehr.
    public let genres: [String]
    /// In Minuten. Bei einer Serie die Länge einer Folge.
    public let laufzeit: Int?
    public let bewertung: Double?
    public let staffeln: [Seerrstaffel]
    /// Die Besetzung, in der Reihenfolge, in der Seerr sie liefert — das ist
    /// die Reihenfolge der Wichtigkeit, nicht das Alphabet.
    public let besetzung: [Seerrperson]
    /// Was Seerr sonst noch vorschlaegt. **Dieselbe Sorte Treffer wie aus
    /// der Suche**, damit die Kachel und die Seite dahinter dieselben sind.
    ///
    /// Kommt aus einem **zweiten** Abruf — siehe ``Seerr/vorschlaege(aus:art:)``.
    public let aehnliches: [Seerrtreffer]

    /// Dieselbe Auskunft, nur mit den Vorschlaegen aus dem zweiten Abruf.
    public func mit(aehnliches neu: [Seerrtreffer]) -> Seerrdetail {
        Seerrdetail(beschreibung: beschreibung, genres: genres, laufzeit: laufzeit,
                    bewertung: bewertung, staffeln: staffeln, besetzung: besetzung,
                    aehnliches: neu)
    }
}

/// Adresse und Sitzung. Liegt beim Nutzer, nicht hier.
public struct Seerrzugang: Codable, Sendable, Equatable {
    public let adresse: URL
    /// Der Sitzungskeks, so wie er im `Cookie`-Kopf wieder hinausgeht.
    public let keks: String

    public init(adresse: URL, keks: String) {
        self.adresse = adresse
        self.keks = keks
    }
}

/// Die Teile, die ohne Netz prüfbar sind.
///
/// **Absichtlich getrennt vom Abruf.** Was eine Antwort bedeutet, ist die
/// Frage, an der es hängt; ob der Abruf durchkommt, ist Sache des Netzes.
/// Genau diese Trennung fehlte bei der Ablage, und dort hat sie jeden
/// bestehenden Nutzer die Anmeldung gekostet.
public enum Seerr {

    /// Aus Seerrs Suchantwort die Treffer, die uns etwas angehen.
    ///
    /// **Personen fallen heraus.** Die Schnittstelle liefert sie mit
    /// (`mediaType: "person"`), und ein Schauspieler ist nichts, was man
    /// anfragen kann. Ebenso fällt heraus, was gar keinen Titel trägt.
    ///
    /// Fehlt `mediaInfo`, hat noch nie jemand danach gefragt — das ist
    /// `offen`, nicht „unbekannt". Seerr legt den Eintrag erst mit der
    /// ersten Anfrage an.
    public static func treffer(ausSuche daten: Data) -> [Seerrtreffer] {
        guard let a = try? JSONDecoder().decode(Trefferliste.self, from: daten) else { return [] }
        return treffer(aus: a.results, standardArt: nil)
    }

    /// Die Form, in der Seerr Trefferlisten ausliefert — Suche wie
    /// Vorschlaege. **Einmal beschrieben, zweimal benutzt.**
    struct Trefferliste: Decodable {
        struct Eintrag: Decodable {
            let id: Int
            let mediaType: String?
            let title: String?
            let name: String?
            let releaseDate: String?
            let firstAirDate: String?
            let posterPath: String?
            let backdropPath: String?
            let mediaInfo: Info?
            struct Info: Decodable { let status: Int? }
        }
        let results: [Eintrag]
    }

    /// **`standardArt` ist der Unterschied zwischen Suche und Vorschlag.**
    ///
    /// In der Suche steht an jedem Eintrag, was er ist — dort *muss* die
    /// Angabe kommen, sonst waere ein Schauspieler nicht von einem Film zu
    /// unterscheiden. Unter `recommendations` einer Filmseite stehen nur
    /// Filme, und Seerr spart sich das Feld. Ohne diesen Rueckfall kam dort
    /// nie ein Treffer an, obwohl die Antwort voll war.
    static func treffer(aus eintraege: [Trefferliste.Eintrag],
                        standardArt: String?) -> [Seerrtreffer] {
        eintraege.compactMap { e in
            guard let art = e.mediaType ?? standardArt, art == "movie" || art == "tv" else { return nil }
            guard let titel = e.title ?? e.name, !titel.isEmpty else { return nil }
            let datum = e.releaseDate ?? e.firstAirDate
            return Seerrtreffer(
                id: e.id,
                art: art,
                titel: titel,
                jahr: datum.flatMap { Int($0.prefix(4)) },
                plakatPfad: e.posterPath,
                kulissePfad: e.backdropPath,
                stand: e.mediaInfo?.status.flatMap(Seerrstand.init(rawValue:)) ?? .offen)
        }
    }

    /// Aus Seerrs Detailantwort, was die Seite braucht.
    ///
    /// **Staffel 0 fällt heraus.** TMDB legt dort Specials ab; wer „alle
    /// Staffeln" anfragt, meint sie nicht mit, und in einer Liste zum
    /// Ankreuzen steht sie ganz oben, wo niemand sie erwartet.
    ///
    /// Fehlt einer Staffel der Stand, ist sie **offen** — dieselbe
    /// Begründung wie beim Suchtreffer: Seerr legt den Eintrag erst mit der
    /// ersten Anfrage an.
    public static func detail(aus daten: Data) -> Seerrdetail? {
        struct Antwort: Decodable {
            struct Besetzung: Decodable {
                struct Kopf: Decodable {
                    let id: Int
                    let name: String?
                    let character: String?
                    let profilePath: String?
                }
                let cast: [Kopf]?
            }
            struct Staffel: Decodable {
                let seasonNumber: Int
                let episodeCount: Int?
                let mediaInfo: Info?
            }
            struct Info: Decodable { let status: Int? }
            struct Gattung: Decodable { let name: String? }
            let overview: String?
            let genres: [Gattung]?
            let runtime: Int?
            let episodeRunTime: [Int]?
            let voteAverage: Double?
            let seasons: [Staffel]?
            let credits: Besetzung?
            let mediaInfo: MedienInfo?
            struct MedienInfo: Decodable {
                struct Staffelstand: Decodable { let seasonNumber: Int; let status: Int? }
                let seasons: [Staffelstand]?
            }
        }
        guard let a = try? JSONDecoder().decode(Antwort.self, from: daten) else { return nil }

        // Der Stand je Staffel steht nicht bei der Staffel, sondern in einer
        // zweiten Liste daneben. Erst zusammenführen, dann ausliefern.
        var staende: [Int: Seerrstand] = [:]
        for e in a.mediaInfo?.seasons ?? [] {
            if let s = e.status.flatMap(Seerrstand.init(rawValue:)) { staende[e.seasonNumber] = s }
        }
        let staffeln = (a.seasons ?? [])
            .filter { $0.seasonNumber > 0 }
            .map { Seerrstaffel(nummer: $0.seasonNumber,
                                folgen: $0.episodeCount ?? 0,
                                stand: staende[$0.seasonNumber] ?? .offen) }

        // **Wer keinen Namen hat, ist keine Besetzung.** Und mehr als zwanzig
        // Koepfe liest niemand — TMDB fuehrt bei grossen Serien ueber hundert,
        // und jeder davon waere ein Bild, das geholt wird.
        let besetzung = (a.credits?.cast ?? []).compactMap { k -> Seerrperson? in
            guard let name = k.name, !name.isEmpty else { return nil }
            return Seerrperson(id: k.id, name: name,
                               rolle: (k.character?.isEmpty ?? true) ? nil : k.character,
                               bildPfad: k.profilePath)
        }.prefix(20).map { $0 }

        let text = a.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Seerrdetail(beschreibung: (text?.isEmpty ?? true) ? nil : text,
                           genres: (a.genres ?? []).compactMap(\.name).prefix(2).map { $0 },
                           laufzeit: a.runtime ?? a.episodeRunTime?.first,
                           bewertung: a.voteAverage,
                           staffeln: staffeln,
                           besetzung: besetzung,
                           // **Leer, und das ist kein Versehen.** Die
                           // Vorschlaege kommen aus einem eigenen Abruf;
                           // ``SeerrClient/detail(art:id:)`` setzt sie nach.
                           aehnliches: [])
    }

    /// Die Vorschlaege zu einem Titel.
    ///
    /// **Ein eigener Abruf, kein Feld der Detailantwort.** Genau das war der
    /// Fehler: `credits` liefert Seerr in der Detailantwort mit, die
    /// Vorschlaege nicht — die stehen unter `/{art}/{id}/recommendations`.
    /// Die Besetzung war deshalb da und „Aehnliches" blieb leer, samt
    /// Ueberschrift, auch bei Titeln, zu denen es reichlich gibt.
    ///
    /// `art` ist nicht Zierde: in dieser Antwort steht an den Eintraegen
    /// **kein** `mediaType` — die Seite weiss ja, was sie ist. Ohne den
    /// Rueckfall kaeme auch aus einer vollen Antwort nichts an.
    public static func vorschlaege(aus daten: Data, art: String) -> [Seerrtreffer] {
        guard let a = try? JSONDecoder().decode(Trefferliste.self, from: daten) else { return [] }
        return treffer(aus: a.results, standardArt: art)
    }

    /// Den Sitzungskeks aus der Antwort auf die Anmeldung holen.
    ///
    /// **Seerr arbeitet mit einer Sitzung, nicht mit einem Merkmal.** Nach
    /// `POST /api/v1/auth/jellyfin` steht sie in `Set-Cookie`, meist als
    /// `connect.sid`. Wir schneiden alles hinter dem ersten Strichpunkt ab —
    /// `Path`, `HttpOnly` und `Expires` gehören dem Browser, nicht uns.
    ///
    /// Mehrere Kekse werden mit `, ` aneinandergehängt; deshalb wird je
    /// Bestandteil gesucht und nicht auf einen einzigen gehofft.
    public static func keks(ausKopf setCookie: String) -> String? {
        for teil in setCookie.split(separator: ",") {
            let stueck = teil.trimmingCharacters(in: .whitespaces)
            guard let gleich = stueck.firstIndex(of: "="),
                  stueck[..<gleich].contains("sid") else { continue }
            let bis = stueck.firstIndex(of: ";") ?? stueck.endIndex
            let keks = String(stueck[..<bis])
            if !keks.hasSuffix("=") { return keks }
        }
        return nil
    }

    /// Was beim Anfragen an Seerr geht.
    ///
    /// **Bei einem Film gibt es keine Staffeln, und dann darf das Feld auch
    /// nicht dastehen.** Seerr nimmt entweder eine Liste von Nummern oder das
    /// Wort `all`; ein leeres Feld hat es schon einmal mit „gar keine"
    /// verwechselt.
    public static func anfrageRumpf(art: String, id: Int, staffeln: [Int]?) -> [String: Any] {
        var rumpf: [String: Any] = ["mediaType": art, "mediaId": id]
        if art == "tv", let staffeln, !staffeln.isEmpty {
            rumpf["seasons"] = staffeln
        } else if art == "tv" {
            rumpf["seasons"] = "all"
        }
        return rumpf
    }

    /// Die Adresse aufräumen, bevor sie gespeichert wird.
    ///
    /// Dieselbe Sorgfalt wie beim Jellyfin-Server: der Nutzer tippt
    /// `seerr.example.de`, `https://seerr.example.de/` oder mit `/api/v1`
    /// dahinter — gemeint ist immer dasselbe.
    public static func adresse(aus eingabe: String) -> URL? {
        var text = eingabe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // **Dieselbe Regel wie beim Medienserver, nicht eine zweite.**
        // Wer `192.168.1.9:5055` tippt, meint kein `https` — dort steht
        // praktisch nie ein Zertifikat, und die Anmeldung scheiterte an
        // etwas, das mit Seerr nichts zu tun hat. `AppModelURLNormalizer.istImHeimnetz`
        // beantwortet das seit dem Jellyfin-Server; sie hier noch einmal zu
        // schreiben wäre die Kopie, die auseinanderläuft.
        if !text.lowercased().hasPrefix("http") {
            text = (AppModelURLNormalizer.istImHeimnetz(text) ? "http://" : "https://") + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        for anhang in ["/api/v1", "/api"] where text.lowercased().hasSuffix(anhang) {
            text.removeLast(anhang.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    /// Die Adressen, die probiert werden — in dieser Reihenfolge.
    ///
    /// **Weil Raten manchmal danebengeht.** `adresse(aus:)` waehlt das Schema
    /// nach derselben Regel wie beim Medienserver, und die trifft die meisten
    /// Faelle. Trifft sie daneben, lief die Anmeldung bisher in eine
    /// Zeitueberschreitung, und der Nutzer musste `https://` selbst davor
    /// tippen — genau so ist es 09.2026 auf dem Mac gegangen.
    ///
    /// Der Medienserver kennt den zweiten Versuch laengst
    /// (``AppModelURLNormalizer.andersHerum``); Seerr bekommt ihn jetzt auch.
    ///
    /// **Nur wenn wir geraten haben.** Wer das Schema selbst hinschreibt, hat
    /// entschieden — dann wird nicht dahinter ausgewichen. Das ist auch der
    /// Grund, warum die Liste hier entsteht und nicht an der Aufrufstelle: ob
    /// geraten wurde, weiss nur diese Funktion.
    public static func adressen(aus eingabe: String) -> [URL] {
        guard let erste = adresse(aus: eingabe) else { return [] }
        let getippt = eingabe.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("http")
        guard !getippt else { return [erste] }
        var teile = URLComponents(url: erste, resolvingAgainstBaseURL: false)
        teile?.scheme = erste.scheme == "https" ? "http" : "https"
        guard let zweite = teile?.url else { return [erste] }
        return [erste, zweite]
    }
}

/// Der Abruf. Alles, was hier passiert, hängt am Netz — was es **bedeutet**,
/// steht oben in ``Seerr`` und ist ohne Netz geprüft.
public actor SeerrClient {
    private let zugang: Seerrzugang
    private let sitzung: URLSession

    public init(zugang: Seerrzugang, sitzung: URLSession = .ortsnetzfaehig) {
        self.zugang = zugang
        self.sitzung = sitzung
    }

    /// Anmelden mit den Zugangsdaten des **Medienservers**.
    ///
    /// Seerr fragt Jellyfin selbst, ob Name und Passwort stimmen, und legt
    /// dafür eine eigene Sitzung an. Zurück kommt der Keks, den jeder weitere
    /// Aufruf mitträgt.
    public static func anmelden(an adresse: URL, benutzer: String, passwort: String,
                                sitzung: URLSession = .ortsnetzfaehig) async throws -> Seerrzugang {
        var req = URLRequest(url: adresse.appendingPathComponent("api/v1/auth/jellyfin"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["username": benutzer, "password": passwort])

        let (daten, antwort) = try await sitzung.data(for: req)
        guard let http = antwort as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine Antwort von Seerr.")
        }
        switch http.statusCode {
        case 200, 201: break
        case 401, 403:
            throw JellyfinError.transport("Name oder Passwort stimmen nicht.")
        case 404:
            throw JellyfinError.transport("Unter dieser Adresse antwortet kein Seerr.")
        default:
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: daten.prefix(200), encoding: .utf8))
        }
        // **Der Keks ist der Zugang.** Ohne ihn wäre die Anmeldung zwar
        // gelungen, aber der nächste Aufruf stünde wieder davor.
        guard let kopf = http.value(forHTTPHeaderField: "Set-Cookie"),
              let keks = Seerr.keks(ausKopf: kopf) else {
            throw JellyfinError.transport("Seerr hat keine Sitzung mitgegeben.")
        }
        return Seerrzugang(adresse: adresse, keks: keks)
    }

    private func anfrage(_ pfad: String, methode: String = "GET",
                         abfrage: [URLQueryItem] = [], rumpf: Data? = nil) throws -> URLRequest {
        var teile = URLComponents(url: zugang.adresse.appendingPathComponent("api/v1/" + pfad),
                                  resolvingAgainstBaseURL: false)
        if !abfrage.isEmpty { teile?.queryItems = abfrage }
        guard let url = teile?.url else { throw JellyfinError.transport("Adresse unbrauchbar.") }
        var req = URLRequest(url: url)
        req.httpMethod = methode
        req.setValue(zugang.keks, forHTTPHeaderField: "Cookie")
        if let rumpf {
            req.httpBody = rumpf
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// Suchen. Fehler sind hier kein Grund zu werfen: die Seerr-Treffer sind
    /// eine Zugabe zur eigenen Bibliothek, und wenn Seerr schweigt, soll die
    /// Suche trotzdem etwas zeigen.
    public func suchen(_ begriff: String) async -> [Seerrtreffer] {
        guard let req = try? anfrage("search", abfrage: [.init(name: "query", value: begriff)]),
              let (daten, antwort) = try? await sitzung.data(for: req),
              let http = antwort as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        return Seerr.treffer(ausSuche: daten)
    }

    /// Anfragen. Hier wird sehr wohl geworfen — der Nutzer hat gedrückt und
    /// muss erfahren, ob es geklappt hat.
    public func anfragen(art: String, id: Int, staffeln: [Int]? = nil) async throws {
        let rumpf = try JSONSerialization.data(
            withJSONObject: Seerr.anfrageRumpf(art: art, id: id, staffeln: staffeln))
        let req = try anfrage("request", methode: "POST", rumpf: rumpf)
        let (daten, antwort) = try await sitzung.data(for: req)
        guard let http = antwort as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine Antwort von Seerr.")
        }
        switch http.statusCode {
        case 200, 201: return
        case 401, 403:
            throw JellyfinError.transport("Deine Seerr-Anmeldung gilt nicht mehr.")
        case 409:
            // Kein Fehler: jemand war schneller. Der Stand sagt es beim
            // nächsten Laden von selbst.
            return
        default:
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: daten.prefix(200), encoding: .utf8))
        }
    }

    /// Beschreibung, Bewertung und Staffeln zu einem Treffer.
    ///
    /// Kommt nichts, bleibt die Seite bei dem, was der Suchtreffer schon
    /// trägt — eine leere Beschreibung ist besser als eine Fehlermeldung für
    /// etwas, das nur schmückt.
    public func detail(art: String, id: Int) async -> Seerrdetail? {
        // **Zwei Abrufe, nebeneinander.** Die Vorschlaege stehen nicht in der
        // Detailantwort, sondern unter einem eigenen Pfad. Nacheinander
        // waeren es zwei Wartezeiten fuer eine Seite.
        async let haupt = hole("\(art)/\(id)")
        async let vorschlag = hole("\(art)/\(id)/recommendations")
        let (a, b) = await (haupt, vorschlag)

        guard let a, let auskunft = Seerr.detail(aus: a) else { return nil }
        // **Kommen keine Vorschlaege, steht die Seite trotzdem.** Sie sind
        // eine Zugabe; ein Fehler dort darf die Beschreibung nicht kosten.
        guard let b else { return auskunft }
        return auskunft.mit(aehnliches: Seerr.vorschlaege(aus: b, art: art))
    }

    /// Ein GET, der bei allem ausser einer 200 nichts zurueckgibt.
    private func hole(_ pfad: String) async -> Data? {
        guard let req = try? anfrage(pfad),
              let (daten, antwort) = try? await sitzung.data(for: req),
              let http = antwort as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return daten
    }

    /// Ob die gespeicherte Sitzung noch gilt.
    public func gilt() async -> Bool {
        guard let req = try? anfrage("auth/me"),
              let (_, antwort) = try? await sitzung.data(for: req),
              let http = antwort as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}
