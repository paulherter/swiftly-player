import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import JellyfinKit

/// All against a stub; not a single request goes to Trakt.
@Suite("Trakt")
struct TraktTests {

    // MARK: Stub

    /// Accepts requests and answers from a list by path.
    final class Dummy: @unchecked Sendable {
        private let barrier = NSLock()
        private var respond: [String: [TraktResponse]] = [:]
        private(set) var askFor: [URLRequest] = []

        func answerBack(_ path: String, _ a: TraktResponse...) {
            barrier.lock(); respond[path, default: []] += a; barrier.unlock()
        }

        var paths: [String] {
            barrier.lock(); defer { barrier.unlock() }
            return askFor.map { $0.url!.path }
        }

        func shell(_ i: Int) -> [String: Any] {
            barrier.lock(); defer { barrier.unlock() }
            let d = askFor[i].httpBody ?? Data()
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        }

        var conduit: TraktConnection {
            { [self] petition in accept(petition) }
        }

        private func accept(_ petition: URLRequest) -> TraktResponse {
            barrier.lock(); defer { barrier.unlock() }
            askFor.append(petition)
            let path = petition.url!.path
            guard var list = respond[path], !list.isEmpty else {
                return TraktResponse(status: 201)
            }
            let a = list.removeFirst()
            // The last answer stays in place, so a tick that
            // asks several times does not run into nothing.
            respond[path] = list.isEmpty ? [a] : list
            return a
        }
    }

    private let access = TraktAccess(clientID: "id-123", secret: "geheim-456")

    private func token(flow: Date = Date().addingTimeInterval(86_400)) -> TraktToken {
        TraktToken(access: "zugriff-alt", renewal: "erneuerung-alt", flow: flow, user: "paula")
    }

    private static let tokenResponse = Data("""
    {"access_token":"zugriff-neu","token_type":"bearer","expires_in":86400,
     "refresh_token":"erneuerung-neu","scope":"public","created_at":1790000000}
    """.utf8)

    // MARK: Access

    @Test("Zugang braucht beide Werte")
    func accessRead() {
        #expect(TraktAccess.read(Data(#"{"client_id":"a","client_secret":"b"}"#.utf8))
                == TraktAccess(clientID: "a", secret: "b"))
        #expect(TraktAccess.read(Data(#"{"client_id":"a","client_secret":" "}"#.utf8)) == nil)
        #expect(TraktAccess.read(Data(#"{"client_id":"a"}"#.utf8)) == nil)
        #expect(TraktAccess.read(Data("kein json".utf8)) == nil)
    }

    // MARK: IDs and target

    @Test("ProviderIds werden zu Trakt-Kennungen, Müll fällt raus")
    func identifiers() {
        let k = TraktIds(provider: ["Imdb": "tt0120737", "tmdb": "120", "Tvdb": "abc", "Zap2It": "x"])
        #expect(k == TraktIds(imdb: "tt0120737", tmdb: 120, tvdb: nil))
        #expect(TraktIds(provider: ["Imdb": "0120737"]).empty)
        #expect(TraktIds(provider: nil).empty)
    }

    @Test("Film über seine Kennungen, Folge über Serie plus Staffel und Nummer")
    func targetBuild() {
        let film = Item(id: "f", name: "Film", type: "Movie", providerIds: ["Tmdb": "603"])
        #expect(TraktTarget.from(title: film, series: nil) == .film(TraktIds(tmdb: 603)))

        let episode = Item(id: "e", name: "Pilot", type: "Episode", indexNumber: 1,
                         parentIndexNumber: 1, seriesId: "s", providerIds: ["Tvdb": "349232"])
        let series = Item(id: "s", name: "The Mentalist", type: "Series",
                         providerIds: ["Tvdb": "82459", "Imdb": "tt1196946"])
        #expect(TraktTarget.from(title: episode, series: series)
                == .episode(series: TraktIds(imdb: "tt1196946", tvdb: 82459), season: 1, number: 1))
        // Series without an ID: the episode itself.
        #expect(TraktTarget.from(title: episode, series: nil) == .episodeSelf(TraktIds(tvdb: 349232)))
        // Neither: do not report.
        let bare = Item(id: "n", name: "Heimvideo", type: "Episode")
        #expect(TraktTarget.from(title: bare, series: nil) == nil)
        #expect(TraktTarget.from(title: Item(id: "m", name: "Clip", type: "MusicVideo",
                                          providerIds: ["Imdb": "tt1"]), series: nil) == nil)
    }

    @Test("Rumpf so, wie Trakt ihn erwartet")
    func shell() throws {
        let episode = TraktTarget.episode(series: TraktIds(tvdb: 82459), season: 2, number: 5)
        let r = try #require(try JSONSerialization.jsonObject(with: episode.shell(progress: 42.123)) as? [String: Any])
        #expect((r["show"] as? [String: Any])?["ids"] as? [String: Int] == ["tvdb": 82459])
        #expect(r["episode"] as? [String: Int] == ["season": 2, "number": 5])
        #expect(r["progress"] as? Double == 42.12)
        #expect(r["movie"] == nil)

        let film = TraktTarget.film(TraktIds(imdb: "tt1"))
        let f = try #require(try JSONSerialization.jsonObject(with: film.shell(progress: 130)) as? [String: Any])
        #expect(f["progress"] as? Double == 100)
        #expect((f["movie"] as? [String: Any])?["ids"] as? [String: String] == ["imdb": "tt1"])

        let itself = TraktTarget.episodeSelf(TraktIds(tmdb: 7))
        let s = try #require(try JSONSerialization.jsonObject(with: itself.shell(progress: 1)) as? [String: Any])
        #expect((s["episode"] as? [String: Any])?["ids"] as? [String: Int] == ["tmdb": 7])
        #expect(s["show"] == nil)
    }

    // MARK: Signing in

    @Test("Gerätecode: Adresse mit Code darin und zum Abtippen")
    func devicesCode() async throws {
        let a = Dummy()
        a.answerBack("/oauth/device/code", TraktResponse(status: 200, data: Data("""
        {"device_code":"d-1","user_code":"5055CC52","verification_url":"https://trakt.tv/activate",
         "expires_in":600,"interval":5}
        """.utf8)))
        let code = try await TraktClient(access: access, conduit: a.conduit).devicesCode()
        #expect(code.userCode == "5055CC52")
        #expect(code.directAddress.absoluteString == "https://trakt.tv/activate/5055CC52")
        #expect(code.addressShort == "trakt.tv/activate")
        #expect(a.shell(0)["client_id"] as? String == "id-123")
        #expect(a.askFor[0].value(forHTTPHeaderField: "trakt-api-key") == "id-123")
        #expect(a.askFor[0].value(forHTTPHeaderField: "trakt-api-version") == "2")
    }

    private func code(valid: TimeInterval = 600) -> TraktDevicesCode {
        TraktDevicesCode(devicesCode: "d-1", userCode: "ABCD", address: URL(string: "https://trakt.tv/activate")!,
                         valid: valid, spacing: 5)
    }

    @Test("Freigabe: wartet, wird langsamer, bekommt den Token")
    func sharingWaitFor() async throws {
        let a = Dummy()
        a.answerBack("/oauth/device/token",
                   TraktResponse(status: 400), TraktResponse(status: 429),
                   TraktResponse(status: 400), TraktResponse(status: 200, data: Self.tokenResponse))
        let slept = Dummy.Sleep()
        let t = try await TraktClient(access: access, conduit: a.conduit)
            .sharingWaitFor(code(), sleep: { await slept.remember($0) })
        #expect(t.access == "zugriff-neu")
        #expect(t.renewal == "erneuerung-neu")
        #expect(t.flow == Date(timeIntervalSince1970: 1_790_000_000 + 86_400))
        // After the 429, five seconds more, and permanently.
        #expect(await slept.values == [5, 5, 10, 10])
        #expect(a.shell(0)["client_secret"] as? String == "geheim-456")
    }

    @Test("Freigabe: abgelaufen, abgelehnt, Frist vorbei")
    func sharingEnd() async {
        for (status, expects) in [(410, TraktError.codeExpired), (404, .codeExpired),
                                   (418, .rejected), (409, .rejected)] {
            let a = Dummy()
            a.answerBack("/oauth/device/token", TraktResponse(status: status))
            await #expect(throws: expects) {
                try await TraktClient(access: access, conduit: a.conduit)
                    .sharingWaitFor(code(), sleep: { _ in })
            }
        }
        let a = Dummy()
        a.answerBack("/oauth/device/token", TraktResponse(status: 400))
        await #expect(throws: TraktError.codeExpired) {
            try await TraktClient(access: access, conduit: a.conduit)
                .sharingWaitFor(code(valid: 20), sleep: { _ in })
        }
        #expect(a.askFor.count == 4)
    }

    @Test("Erneuern: 400 heißt getrennt, 5xx heißt später")
    func renew() async throws {
        let a = Dummy()
        a.answerBack("/oauth/token", TraktResponse(status: 200, data: Self.tokenResponse))
        let new = try await TraktClient(access: access, conduit: a.conduit).renew(token())
        #expect(new.access == "zugriff-neu")
        #expect(new.user == "paula")
        #expect(a.shell(0)["grant_type"] as? String == "refresh_token")
        #expect(a.shell(0)["refresh_token"] as? String == "erneuerung-alt")

        let b = Dummy()
        b.answerBack("/oauth/token", TraktResponse(status: 400))
        await #expect(throws: TraktError.signedOut) {
            try await TraktClient(access: access, conduit: b.conduit).renew(token())
        }
        let c = Dummy()
        c.answerBack("/oauth/token", TraktResponse(status: 503))
        await #expect(throws: TraktError.status(503)) {
            try await TraktClient(access: access, conduit: c.conduit).renew(token())
        }
    }

    // MARK: Reporting

    private func reporter(_ a: Dummy, token t: TraktToken?,
                        now: @escaping @Sendable () -> Date = { Date() },
                        changed: @escaping @Sendable (TraktToken?, String?) -> Void = { _, _ in })
        -> TraktReporter {
        let m = TraktReporter(client: TraktClient(access: access, conduit: a.conduit),
                            changed: changed, log: { _ in }, now: now)
        m.tokenSet(t, identifier: "konto-1")
        return m
    }

    private let film = TraktTarget.film(TraktIds(tmdb: 603))

    @Test("Start, Pause, Weiter, Stopp — in dieser Reihenfolge, mit Prozent")
    func flow() async {
        let a = Dummy()
        let m = reporter(a, token: token())
        let target = film
        m.report(.start(titleID: "f", target: { target }, spot: 600, duration: 6000))
        m.report(.runState(running: false, spot: 1200))
        m.report(.runState(running: false, spot: 1201)) // no change
        m.report(.runState(running: true, spot: 1200))
        m.report(.stop(titleID: "f", spot: 5400))
        await m.processed()
        #expect(a.paths == ["/scrobble/start", "/scrobble/pause", "/scrobble/start", "/scrobble/stop"])
        #expect(a.shell(0)["progress"] as? Double == 10)
        #expect(a.shell(3)["progress"] as? Double == 90)
        #expect(a.askFor[0].value(forHTTPHeaderField: "Authorization") == "Bearer zugriff-alt")
    }

    @Test("Nicht verbunden: nichts geht hinaus, nichts wird aufgelöst")
    func withoutToken() async {
        let a = Dummy()
        let m = reporter(a, token: nil)
        let resolved = Dummy.Sleep()
        m.report(.start(titleID: "f", target: { await resolved.remember(1); return nil }, spot: 0, duration: 100))
        m.report(.stop(titleID: "f", spot: 90))
        await m.processed()
        #expect(a.askFor.isEmpty)
        #expect(await resolved.values.isEmpty)
    }

    @Test("Ohne Kennung oder Laufzeit kein Start und kein Stopp")
    func withoutTarget() async {
        let a = Dummy()
        let m = reporter(a, token: token())
        m.report(.start(titleID: "x", target: { nil }, spot: 0, duration: 100))
        m.report(.stop(titleID: "x", spot: 95))
        let target = film
        m.report(.start(titleID: "y", target: { target }, spot: 0, duration: 0))
        m.report(.stop(titleID: "y", spot: 95))
        await m.processed()
        #expect(a.askFor.isEmpty)
    }

    @Test("Ein später Stopp trifft nicht die nächste Folge")
    func foreignStop() async {
        let a = Dummy()
        let m = reporter(a, token: token())
        let target = film
        m.report(.start(titleID: "neu", target: { target }, spot: 0, duration: 100))
        m.report(.stop(titleID: "alt", spot: 99))
        await m.processed()
        #expect(a.paths == ["/scrobble/start"])
    }

    @Test("Trakt-Fehler bleiben drin, 409 gilt als erledigt")
    func swallowError() async {
        let a = Dummy()
        a.answerBack("/scrobble/start", TraktResponse(status: 500))
        a.answerBack("/scrobble/stop", TraktResponse(status: 409))
        let m = reporter(a, token: token())
        let target = film
        m.report(.start(titleID: "f", target: { target }, spot: 0, duration: 100))
        m.report(.stop(titleID: "f", spot: 85))
        await m.processed()
        #expect(a.paths == ["/scrobble/start", "/scrobble/stop"])
    }

    @Test("401: einmal erneuern, nachschicken, neuen Token weitergeben")
    func renew401() async {
        let a = Dummy()
        a.answerBack("/scrobble/start", TraktResponse(status: 401), TraktResponse(status: 201))
        a.answerBack("/oauth/token", TraktResponse(status: 200, data: Self.tokenResponse))
        let remembered = Dummy.TokenStore()
        let m = reporter(a, token: token(), changed: { t, k in remembered.remember(t, k) })
        let target = film
        m.report(.start(titleID: "f", target: { target }, spot: 0, duration: 100))
        await m.processed()
        #expect(a.paths == ["/scrobble/start", "/oauth/token", "/scrobble/start"])
        #expect(a.askFor[2].value(forHTTPHeaderField: "Authorization") == "Bearer zugriff-neu")
        #expect(remembered.lastOne?.0?.access == "zugriff-neu")
        #expect(remembered.lastOne?.1 == "konto-1")
    }

    @Test("Kurz vor Ablauf wird vorher erneuert; ein toter Zugang trennt")
    func renewBefore() async {
        let a = Dummy()
        a.answerBack("/oauth/token", TraktResponse(status: 401))
        let remembered = Dummy.TokenStore()
        let m = reporter(a, token: token(flow: Date().addingTimeInterval(60)),
                       changed: { t, k in remembered.remember(t, k) })
        let target = film
        m.report(.start(titleID: "f", target: { target }, spot: 0, duration: 100))
        m.report(.stop(titleID: "f", spot: 90))
        await m.processed()
        #expect(a.paths == ["/oauth/token"])
        #expect(remembered.count == 1)
        #expect(remembered.lastOne?.0 == nil)
    }

    @Test("429: bis Retry-After still, danach wieder")
    func rateLimit() async {
        let a = Dummy()
        a.answerBack("/scrobble/start", TraktResponse(status: 429, repeatTo: 30), TraktResponse(status: 201))
        let clock = Dummy.Clock()
        let m = reporter(a, token: token(), now: { clock.now })
        let target = film
        m.report(.start(titleID: "f", target: { target }, spot: 0, duration: 100))
        m.report(.runState(running: false, spot: 10))
        await m.processed()
        #expect(a.paths == ["/scrobble/start"])
        clock.forward(31)
        m.report(.runState(running: true, spot: 10))
        await m.processed()
        #expect(a.paths == ["/scrobble/start", "/scrobble/start"])
    }

    @Test("Sprünge höchstens alle 30 Sekunden")
    func jumps() async {
        let a = Dummy()
        let clock = Dummy.Clock()
        let m = reporter(a, token: token(), now: { clock.now })
        let target = film
        m.report(.start(titleID: "f", target: { target }, spot: 0, duration: 100))
        m.report(.leap(spot: 20))
        await m.processed()
        clock.forward(31)
        m.report(.leap(spot: 40))
        m.report(.leap(spot: 50))
        await m.processed()
        #expect(a.paths == ["/scrobble/start", "/scrobble/start"])
        #expect(a.shell(1)["progress"] as? Double == 40)
    }

    @Test("Nach dem Trennen geht nichts mehr hinaus")
    func disconnect() async {
        let a = Dummy()
        let m = reporter(a, token: token())
        let target = film
        m.report(.start(titleID: "f", target: { target }, spot: 0, duration: 100))
        m.tokenSet(nil, identifier: nil)
        m.report(.stop(titleID: "f", spot: 90))
        await m.processed()
        #expect(a.paths == ["/scrobble/start"])
    }
}

extension TraktTests.Dummy {
    actor Sleep {
        private(set) var values: [TimeInterval] = []
        func remember(_ s: TimeInterval) { values.append(s) }
    }

    final class TokenStore: @unchecked Sendable {
        private let barrier = NSLock()
        private var list: [(TraktToken?, String?)] = []
        func remember(_ t: TraktToken?, _ k: String?) { barrier.lock(); list.append((t, k)); barrier.unlock() }
        var lastOne: (TraktToken?, String?)? { barrier.lock(); defer { barrier.unlock() }; return list.last }
        var count: Int { barrier.lock(); defer { barrier.unlock() }; return list.count }
    }

    final class Clock: @unchecked Sendable {
        private let barrier = NSLock()
        private var state = Date()
        var now: Date { barrier.lock(); defer { barrier.unlock() }; return state }
        func forward(_ s: TimeInterval) { barrier.lock(); state.addTimeInterval(s); barrier.unlock() }
    }
}
