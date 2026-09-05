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
public struct Seerrtreffer: Sendable, Equatable, Identifiable, Codable {
    /// Die Kennung bei TMDB. Seerr nimmt sie beim Anfragen als `mediaId`.
    public let id: Int
    /// `movie` oder `tv`. Personen fallen beim Einlesen heraus.
    public let art: String
    public let titel: String
    public let jahr: Int?
    public let plakatPfad: String?
    public let stand: Seerrstand

    public var istSerie: Bool { art == "tv" }

    /// Die Bildadresse bei TMDB.
    ///
    /// **Nicht von Seerr, sondern von TMDB.** Seerr liefert nur den Pfad;
    /// das Bild holt der Nutzer direkt, ohne Umweg über den eigenen Server
    /// und ohne Merkmal. `w342` ist die kleinste Grösse, die auf einem
    /// Plakat in einem Raster nicht weich aussieht.
    public func plakat(breite: Int = 342) -> URL? {
        guard let plakatPfad, !plakatPfad.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w\(breite)\(plakatPfad)")
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
        struct Antwort: Decodable {
            struct Eintrag: Decodable {
                let id: Int
                let mediaType: String?
                let title: String?
                let name: String?
                let releaseDate: String?
                let firstAirDate: String?
                let posterPath: String?
                let mediaInfo: Info?
                struct Info: Decodable { let status: Int? }
            }
            let results: [Eintrag]
        }
        guard let a = try? JSONDecoder().decode(Antwort.self, from: daten) else { return [] }
        return a.results.compactMap { e in
            guard let art = e.mediaType, art == "movie" || art == "tv" else { return nil }
            guard let titel = e.title ?? e.name, !titel.isEmpty else { return nil }
            let datum = e.releaseDate ?? e.firstAirDate
            return Seerrtreffer(
                id: e.id,
                art: art,
                titel: titel,
                jahr: datum.flatMap { Int($0.prefix(4)) },
                plakatPfad: e.posterPath,
                stand: e.mediaInfo?.status.flatMap(Seerrstand.init(rawValue:)) ?? .offen)
        }
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
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        for anhang in ["/api/v1", "/api"] where text.lowercased().hasSuffix(anhang) {
            text.removeLast(anhang.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }
}
