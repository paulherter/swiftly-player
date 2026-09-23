import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import JellyfinKit

/// Alles gegen eine Attrappe — keine einzige Anfrage geht an Trakt.
@Suite("Trakt")
struct TraktTests {

    // MARK: Attrappe

    /// Nimmt Anfragen entgegen und antwortet nach Pfad aus einer Liste.
    final class Attrappe: @unchecked Sendable {
        private let sperre = NSLock()
        private var antworten: [String: [TraktAntwort]] = [:]
        private(set) var anfragen: [URLRequest] = []

        func antworte(_ pfad: String, _ a: TraktAntwort...) {
            sperre.lock(); antworten[pfad, default: []] += a; sperre.unlock()
        }

        var pfade: [String] {
            sperre.lock(); defer { sperre.unlock() }
            return anfragen.map { $0.url!.path }
        }

        func rumpf(_ i: Int) -> [String: Any] {
            sperre.lock(); defer { sperre.unlock() }
            let d = anfragen[i].httpBody ?? Data()
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        }

        var leitung: TraktLeitung {
            { [self] anfrage in annehmen(anfrage) }
        }

        private func annehmen(_ anfrage: URLRequest) -> TraktAntwort {
            sperre.lock(); defer { sperre.unlock() }
            anfragen.append(anfrage)
            let pfad = anfrage.url!.path
            guard var liste = antworten[pfad], !liste.isEmpty else {
                return TraktAntwort(status: 201)
            }
            let a = liste.removeFirst()
            // Die letzte Antwort bleibt stehen, damit ein Takt, der
            // mehrmals fragt, nicht ins Leere läuft.
            antworten[pfad] = liste.isEmpty ? [a] : liste
            return a
        }
    }

    private let zugang = TraktZugang(clientID: "id-123", secret: "geheim-456")

    private func token(ablauf: Date = Date().addingTimeInterval(86_400)) -> TraktToken {
        TraktToken(zugriff: "zugriff-alt", erneuerung: "erneuerung-alt", ablauf: ablauf, benutzer: "paula")
    }

    private static let tokenantwort = Data("""
    {"access_token":"zugriff-neu","token_type":"bearer","expires_in":86400,
     "refresh_token":"erneuerung-neu","scope":"public","created_at":1790000000}
    """.utf8)

    // MARK: Zugang

    @Test("Zugang braucht beide Werte")
    func zugangLesen() {
        #expect(TraktZugang.lesen(Data(#"{"client_id":"a","client_secret":"b"}"#.utf8))
                == TraktZugang(clientID: "a", secret: "b"))
        #expect(TraktZugang.lesen(Data(#"{"client_id":"a","client_secret":" "}"#.utf8)) == nil)
        #expect(TraktZugang.lesen(Data(#"{"client_id":"a"}"#.utf8)) == nil)
        #expect(TraktZugang.lesen(Data("kein json".utf8)) == nil)
    }

    // MARK: Kennungen und Ziel

    @Test("ProviderIds werden zu Trakt-Kennungen, Müll fällt raus")
    func kennungen() {
        let k = TraktKennungen(anbieter: ["Imdb": "tt0120737", "tmdb": "120", "Tvdb": "abc", "Zap2It": "x"])
        #expect(k == TraktKennungen(imdb: "tt0120737", tmdb: 120, tvdb: nil))
        #expect(TraktKennungen(anbieter: ["Imdb": "0120737"]).leer)
        #expect(TraktKennungen(anbieter: nil).leer)
    }

    @Test("Film über seine Kennungen, Folge über Serie plus Staffel und Nummer")
    func zielBauen() {
        let film = Item(id: "f", name: "Film", type: "Movie", providerIds: ["Tmdb": "603"])
        #expect(TraktZiel.aus(titel: film, serie: nil) == .film(TraktKennungen(tmdb: 603)))

        let folge = Item(id: "e", name: "Pilot", type: "Episode", indexNumber: 1,
                         parentIndexNumber: 1, seriesId: "s", providerIds: ["Tvdb": "349232"])
        let serie = Item(id: "s", name: "The Mentalist", type: "Series",
                         providerIds: ["Tvdb": "82459", "Imdb": "tt1196946"])
        #expect(TraktZiel.aus(titel: folge, serie: serie)
                == .folge(serie: TraktKennungen(imdb: "tt1196946", tvdb: 82459), staffel: 1, nummer: 1))
        // Serie ohne Kennung: die Folge selbst.
        #expect(TraktZiel.aus(titel: folge, serie: nil) == .folgeSelbst(TraktKennungen(tvdb: 349232)))
        // Weder noch: nicht melden.
        let nackt = Item(id: "n", name: "Heimvideo", type: "Episode")
        #expect(TraktZiel.aus(titel: nackt, serie: nil) == nil)
        #expect(TraktZiel.aus(titel: Item(id: "m", name: "Clip", type: "MusicVideo",
                                          providerIds: ["Imdb": "tt1"]), serie: nil) == nil)
    }

    @Test("Rumpf so, wie Trakt ihn erwartet")
    func rumpf() throws {
        let folge = TraktZiel.folge(serie: TraktKennungen(tvdb: 82459), staffel: 2, nummer: 5)
        let r = try #require(try JSONSerialization.jsonObject(with: folge.rumpf(fortschritt: 42.123)) as? [String: Any])
        #expect((r["show"] as? [String: Any])?["ids"] as? [String: Int] == ["tvdb": 82459])
        #expect(r["episode"] as? [String: Int] == ["season": 2, "number": 5])
        #expect(r["progress"] as? Double == 42.12)
        #expect(r["movie"] == nil)

        let film = TraktZiel.film(TraktKennungen(imdb: "tt1"))
        let f = try #require(try JSONSerialization.jsonObject(with: film.rumpf(fortschritt: 130)) as? [String: Any])
        #expect(f["progress"] as? Double == 100)
        #expect((f["movie"] as? [String: Any])?["ids"] as? [String: String] == ["imdb": "tt1"])

        let selbst = TraktZiel.folgeSelbst(TraktKennungen(tmdb: 7))
        let s = try #require(try JSONSerialization.jsonObject(with: selbst.rumpf(fortschritt: 1)) as? [String: Any])
        #expect((s["episode"] as? [String: Any])?["ids"] as? [String: Int] == ["tmdb": 7])
        #expect(s["show"] == nil)
    }

    // MARK: Anmelden

    @Test("Gerätecode: Adresse mit Code darin und zum Abtippen")
    func geraetecode() async throws {
        let a = Attrappe()
        a.antworte("/oauth/device/code", TraktAntwort(status: 200, daten: Data("""
        {"device_code":"d-1","user_code":"5055CC52","verification_url":"https://trakt.tv/activate",
         "expires_in":600,"interval":5}
        """.utf8)))
        let code = try await TraktClient(zugang: zugang, leitung: a.leitung).geraetecode()
        #expect(code.nutzercode == "5055CC52")
        #expect(code.direktadresse.absoluteString == "https://trakt.tv/activate/5055CC52")
        #expect(code.adresseKurz == "trakt.tv/activate")
        #expect(a.rumpf(0)["client_id"] as? String == "id-123")
        #expect(a.anfragen[0].value(forHTTPHeaderField: "trakt-api-key") == "id-123")
        #expect(a.anfragen[0].value(forHTTPHeaderField: "trakt-api-version") == "2")
    }

    private func code(gueltig: TimeInterval = 600) -> TraktGeraetecode {
        TraktGeraetecode(geraetecode: "d-1", nutzercode: "ABCD", adresse: URL(string: "https://trakt.tv/activate")!,
                         gueltig: gueltig, abstand: 5)
    }

    @Test("Freigabe: wartet, wird langsamer, bekommt den Token")
    func freigabeAbwarten() async throws {
        let a = Attrappe()
        a.antworte("/oauth/device/token",
                   TraktAntwort(status: 400), TraktAntwort(status: 429),
                   TraktAntwort(status: 400), TraktAntwort(status: 200, daten: Self.tokenantwort))
        let geschlafen = Attrappe.Schlaf()
        let t = try await TraktClient(zugang: zugang, leitung: a.leitung)
            .freigabeAbwarten(code(), schlafen: { await geschlafen.merken($0) })
        #expect(t.zugriff == "zugriff-neu")
        #expect(t.erneuerung == "erneuerung-neu")
        #expect(t.ablauf == Date(timeIntervalSince1970: 1_790_000_000 + 86_400))
        // Nach dem 429 fünf Sekunden mehr, und zwar dauerhaft.
        #expect(await geschlafen.werte == [5, 5, 10, 10])
        #expect(a.rumpf(0)["client_secret"] as? String == "geheim-456")
    }

    @Test("Freigabe: abgelaufen, abgelehnt, Frist vorbei")
    func freigabeEnden() async {
        for (status, erwartet) in [(410, TraktFehler.codeAbgelaufen), (404, .codeAbgelaufen),
                                   (418, .abgelehnt), (409, .abgelehnt)] {
            let a = Attrappe()
            a.antworte("/oauth/device/token", TraktAntwort(status: status))
            await #expect(throws: erwartet) {
                try await TraktClient(zugang: zugang, leitung: a.leitung)
                    .freigabeAbwarten(code(), schlafen: { _ in })
            }
        }
        let a = Attrappe()
        a.antworte("/oauth/device/token", TraktAntwort(status: 400))
        await #expect(throws: TraktFehler.codeAbgelaufen) {
            try await TraktClient(zugang: zugang, leitung: a.leitung)
                .freigabeAbwarten(code(gueltig: 20), schlafen: { _ in })
        }
        #expect(a.anfragen.count == 4)
    }

    @Test("Erneuern: 400 heißt getrennt, 5xx heißt später")
    func erneuern() async throws {
        let a = Attrappe()
        a.antworte("/oauth/token", TraktAntwort(status: 200, daten: Self.tokenantwort))
        let neu = try await TraktClient(zugang: zugang, leitung: a.leitung).erneuern(token())
        #expect(neu.zugriff == "zugriff-neu")
        #expect(neu.benutzer == "paula")
        #expect(a.rumpf(0)["grant_type"] as? String == "refresh_token")
        #expect(a.rumpf(0)["refresh_token"] as? String == "erneuerung-alt")

        let b = Attrappe()
        b.antworte("/oauth/token", TraktAntwort(status: 400))
        await #expect(throws: TraktFehler.abgemeldet) {
            try await TraktClient(zugang: zugang, leitung: b.leitung).erneuern(token())
        }
        let c = Attrappe()
        c.antworte("/oauth/token", TraktAntwort(status: 503))
        await #expect(throws: TraktFehler.status(503)) {
            try await TraktClient(zugang: zugang, leitung: c.leitung).erneuern(token())
        }
    }

    // MARK: Melden

    private func melder(_ a: Attrappe, token t: TraktToken?,
                        jetzt: @escaping @Sendable () -> Date = { Date() },
                        geaendert: @escaping @Sendable (TraktToken?, String?) -> Void = { _, _ in })
        -> Traktmelder {
        let m = Traktmelder(client: TraktClient(zugang: zugang, leitung: a.leitung),
                            geaendert: geaendert, protokoll: { _ in }, jetzt: jetzt)
        m.tokenSetzen(t, kennung: "konto-1")
        return m
    }

    private let film = TraktZiel.film(TraktKennungen(tmdb: 603))

    @Test("Start, Pause, Weiter, Stopp — in dieser Reihenfolge, mit Prozent")
    func ablauf() async {
        let a = Attrappe()
        let m = melder(a, token: token())
        let ziel = film
        m.melden(.start(titelID: "f", ziel: { ziel }, stelle: 600, dauer: 6000))
        m.melden(.laufzustand(laeuft: false, stelle: 1200))
        m.melden(.laufzustand(laeuft: false, stelle: 1201)) // kein Wechsel
        m.melden(.laufzustand(laeuft: true, stelle: 1200))
        m.melden(.stopp(titelID: "f", stelle: 5400))
        await m.abgearbeitet()
        #expect(a.pfade == ["/scrobble/start", "/scrobble/pause", "/scrobble/start", "/scrobble/stop"])
        #expect(a.rumpf(0)["progress"] as? Double == 10)
        #expect(a.rumpf(3)["progress"] as? Double == 90)
        #expect(a.anfragen[0].value(forHTTPHeaderField: "Authorization") == "Bearer zugriff-alt")
    }

    @Test("Nicht verbunden: nichts geht hinaus, nichts wird aufgelöst")
    func ohneToken() async {
        let a = Attrappe()
        let m = melder(a, token: nil)
        let aufgeloest = Attrappe.Schlaf()
        m.melden(.start(titelID: "f", ziel: { await aufgeloest.merken(1); return nil }, stelle: 0, dauer: 100))
        m.melden(.stopp(titelID: "f", stelle: 90))
        await m.abgearbeitet()
        #expect(a.anfragen.isEmpty)
        #expect(await aufgeloest.werte.isEmpty)
    }

    @Test("Ohne Kennung oder Laufzeit kein Start und kein Stopp")
    func ohneZiel() async {
        let a = Attrappe()
        let m = melder(a, token: token())
        m.melden(.start(titelID: "x", ziel: { nil }, stelle: 0, dauer: 100))
        m.melden(.stopp(titelID: "x", stelle: 95))
        let ziel = film
        m.melden(.start(titelID: "y", ziel: { ziel }, stelle: 0, dauer: 0))
        m.melden(.stopp(titelID: "y", stelle: 95))
        await m.abgearbeitet()
        #expect(a.anfragen.isEmpty)
    }

    @Test("Ein später Stopp trifft nicht die nächste Folge")
    func fremderStopp() async {
        let a = Attrappe()
        let m = melder(a, token: token())
        let ziel = film
        m.melden(.start(titelID: "neu", ziel: { ziel }, stelle: 0, dauer: 100))
        m.melden(.stopp(titelID: "alt", stelle: 99))
        await m.abgearbeitet()
        #expect(a.pfade == ["/scrobble/start"])
    }

    @Test("Trakt-Fehler bleiben drin, 409 gilt als erledigt")
    func fehlerSchlucken() async {
        let a = Attrappe()
        a.antworte("/scrobble/start", TraktAntwort(status: 500))
        a.antworte("/scrobble/stop", TraktAntwort(status: 409))
        let m = melder(a, token: token())
        let ziel = film
        m.melden(.start(titelID: "f", ziel: { ziel }, stelle: 0, dauer: 100))
        m.melden(.stopp(titelID: "f", stelle: 85))
        await m.abgearbeitet()
        #expect(a.pfade == ["/scrobble/start", "/scrobble/stop"])
    }

    @Test("401: einmal erneuern, nachschicken, neuen Token weitergeben")
    func erneuernBei401() async {
        let a = Attrappe()
        a.antworte("/scrobble/start", TraktAntwort(status: 401), TraktAntwort(status: 201))
        a.antworte("/oauth/token", TraktAntwort(status: 200, daten: Self.tokenantwort))
        let gemerkt = Attrappe.Tokenablage()
        let m = melder(a, token: token(), geaendert: { t, k in gemerkt.merken(t, k) })
        let ziel = film
        m.melden(.start(titelID: "f", ziel: { ziel }, stelle: 0, dauer: 100))
        await m.abgearbeitet()
        #expect(a.pfade == ["/scrobble/start", "/oauth/token", "/scrobble/start"])
        #expect(a.anfragen[2].value(forHTTPHeaderField: "Authorization") == "Bearer zugriff-neu")
        #expect(gemerkt.letzter?.0?.zugriff == "zugriff-neu")
        #expect(gemerkt.letzter?.1 == "konto-1")
    }

    @Test("Kurz vor Ablauf wird vorher erneuert; ein toter Zugang trennt")
    func erneuernVorher() async {
        let a = Attrappe()
        a.antworte("/oauth/token", TraktAntwort(status: 401))
        let gemerkt = Attrappe.Tokenablage()
        let m = melder(a, token: token(ablauf: Date().addingTimeInterval(60)),
                       geaendert: { t, k in gemerkt.merken(t, k) })
        let ziel = film
        m.melden(.start(titelID: "f", ziel: { ziel }, stelle: 0, dauer: 100))
        m.melden(.stopp(titelID: "f", stelle: 90))
        await m.abgearbeitet()
        #expect(a.pfade == ["/oauth/token"])
        #expect(gemerkt.anzahl == 1)
        #expect(gemerkt.letzter?.0 == nil)
    }

    @Test("429: bis Retry-After still, danach wieder")
    func ratenlimit() async {
        let a = Attrappe()
        a.antworte("/scrobble/start", TraktAntwort(status: 429, wiederholenNach: 30), TraktAntwort(status: 201))
        let uhr = Attrappe.Uhr()
        let m = melder(a, token: token(), jetzt: { uhr.jetzt })
        let ziel = film
        m.melden(.start(titelID: "f", ziel: { ziel }, stelle: 0, dauer: 100))
        m.melden(.laufzustand(laeuft: false, stelle: 10))
        await m.abgearbeitet()
        #expect(a.pfade == ["/scrobble/start"])
        uhr.vor(31)
        m.melden(.laufzustand(laeuft: true, stelle: 10))
        await m.abgearbeitet()
        #expect(a.pfade == ["/scrobble/start", "/scrobble/start"])
    }

    @Test("Sprünge höchstens alle 30 Sekunden")
    func spruenge() async {
        let a = Attrappe()
        let uhr = Attrappe.Uhr()
        let m = melder(a, token: token(), jetzt: { uhr.jetzt })
        let ziel = film
        m.melden(.start(titelID: "f", ziel: { ziel }, stelle: 0, dauer: 100))
        m.melden(.sprung(stelle: 20))
        await m.abgearbeitet()
        uhr.vor(31)
        m.melden(.sprung(stelle: 40))
        m.melden(.sprung(stelle: 50))
        await m.abgearbeitet()
        #expect(a.pfade == ["/scrobble/start", "/scrobble/start"])
        #expect(a.rumpf(1)["progress"] as? Double == 40)
    }

    @Test("Nach dem Trennen geht nichts mehr hinaus")
    func trennen() async {
        let a = Attrappe()
        let m = melder(a, token: token())
        let ziel = film
        m.melden(.start(titelID: "f", ziel: { ziel }, stelle: 0, dauer: 100))
        m.tokenSetzen(nil, kennung: nil)
        m.melden(.stopp(titelID: "f", stelle: 90))
        await m.abgearbeitet()
        #expect(a.pfade == ["/scrobble/start"])
    }
}

extension TraktTests.Attrappe {
    actor Schlaf {
        private(set) var werte: [TimeInterval] = []
        func merken(_ s: TimeInterval) { werte.append(s) }
    }

    final class Tokenablage: @unchecked Sendable {
        private let sperre = NSLock()
        private var liste: [(TraktToken?, String?)] = []
        func merken(_ t: TraktToken?, _ k: String?) { sperre.lock(); liste.append((t, k)); sperre.unlock() }
        var letzter: (TraktToken?, String?)? { sperre.lock(); defer { sperre.unlock() }; return liste.last }
        var anzahl: Int { sperre.lock(); defer { sperre.unlock() }; return liste.count }
    }

    final class Uhr: @unchecked Sendable {
        private let sperre = NSLock()
        private var stand = Date()
        var jetzt: Date { sperre.lock(); defer { sperre.unlock() }; return stand }
        func vor(_ s: TimeInterval) { sperre.lock(); stand.addTimeInterval(s); sperre.unlock() }
    }
}
