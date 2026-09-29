import Foundation
import Testing
@testable import JellyfinKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Der Ablauf der Gruppe gegen einen Server, der nur mitschreibt, und einen
/// Player, der nur mitzählt. Die Zeiten sind echt, aber kurz.
@Suite("SyncPlay: Sitzung", .serialized)
struct SyncPlaySitzungTests {

    // MARK: Ein Server, der mitschreibt

    final class Mitschrift: URLProtocol, @unchecked Sendable {
        struct Aufruf: Sendable { let pfad: String; let rumpf: [String: String] }
        nonisolated(unsafe) static var aufrufe: [Aufruf] = []
        nonisolated(unsafe) static var verweigert: Set<String> = []
        static let sperre = NSLock()

        static func zuruecksetzen() {
            sperre.withLock { aufrufe = []; verweigert = [] }
        }
        static func alle(_ pfad: String) -> [Aufruf] {
            sperre.withLock { aufrufe.filter { $0.pfad == pfad } }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        override func startLoading() {
            let pfad = String(request.url!.path.dropFirst())
            var daten = request.httpBody ?? Data()
            if daten.isEmpty, let strom = request.httpBodyStream {
                strom.open()
                var puffer = [UInt8](repeating: 0, count: 4096)
                while strom.hasBytesAvailable {
                    let n = strom.read(&puffer, maxLength: puffer.count)
                    if n <= 0 { break }
                    daten.append(puffer, count: n)
                }
                strom.close()
            }
            var rumpf: [String: String] = [:]
            if let json = try? JSONSerialization.jsonObject(with: daten) as? [String: Any] {
                for (k, v) in json { rumpf[k] = "\(v)" }
            }
            Self.sperre.lock()
            Self.aufrufe.append(.init(pfad: pfad, rumpf: rumpf))
            let nein = Self.verweigert.contains(pfad)
            Self.sperre.unlock()

            let body: Data
            if pfad == "GetUtcTime" {
                let jetzt = SyncPlay.zeitText(Date())
                body = Data(#"{"RequestReceptionTime":"\#(jetzt)","ResponseTransmissionTime":"\#(jetzt)"}"#.utf8)
            } else {
                body = Data()
            }
            let antwort = HTTPURLResponse(url: request.url!, statusCode: nein ? 403 : 204,
                                          httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: antwort, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private static let server = URL(string: "https://tv.example.de")!

    private static func client() -> JellyfinClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Mitschrift.self]
        return JellyfinClient(baseURL: server, deviceID: "dev-1", deviceName: "Prueflauf",
                              session: .init(accessToken: "tok", userID: "u1", userName: "Paul",
                                             serverURL: server),
                              urlSession: URLSession(configuration: config))
    }

    // MARK: Ein Player, der mitzählt

    final class Probespieler: SyncPlaySpieler, @unchecked Sendable {
        private let sperre = NSLock()
        private var _titel: String
        private var _bereit: Bool
        private var basis: Double
        private var seit = Date()
        private var laeuft = false
        private(set) var schritte: [String] = []
        private(set) var weiterUm: Date?

        init(titel: String, bereit: Bool = true, stelle: Double = 0) {
            _titel = titel; _bereit = bereit; basis = stelle
        }

        private func jetzt() -> Double {
            laeuft ? basis + Date().timeIntervalSince(seit) : basis
        }
        func protokoll() -> [String] { sperre.withLock { schritte } }
        func weiterZeit() -> Date? { sperre.withLock { weiterUm } }

        func titel() async -> String { sperre.withLock { _titel } }
        func bereit() async -> Bool { sperre.withLock { _bereit } }
        func stelle() async -> Double { sperre.withLock { jetzt() } }
        func weiter() async {
            sperre.withLock {
                basis = jetzt(); seit = Date(); laeuft = true
                weiterUm = Date()
                schritte.append("weiter")
            }
        }
        func anhalten() async {
            sperre.withLock {
                basis = jetzt(); laeuft = false
                schritte.append("anhalten")
            }
        }
        func springen(_ ziel: Double) async {
            sperre.withLock {
                basis = ziel; seit = Date()
                schritte.append("springen \(Int(ziel.rounded()))")
            }
        }
    }

    final class Ladeliste: @unchecked Sendable {
        private let sperre = NSLock()
        private var liste: [(String, Double)] = []
        func merken(_ t: String, _ ab: Double) { sperre.withLock { liste.append((t, ab)) } }
        func alle() -> [(String, Double)] { sperre.withLock { liste } }
    }

    // MARK: Hilfen

    private let geladen = Ladeliste()

    private func sitzung() -> SyncPlaySitzung {
        Mitschrift.zuruecksetzen()
        let c = Self.client()
        let liste = geladen
        return SyncPlaySitzung(client: { c }, ich: { "Paul" },
                               titelLaden: { t, ab in liste.merken(t, ab); return true })
    }

    /// Wartet, bis es stimmt — höchstens `frist` Sekunden.
    private func bis(_ frist: Double = 3, _ bedingung: () async -> Bool) async -> Bool {
        let ende = Date().addingTimeInterval(frist)
        while Date() < ende {
            if await bedingung() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await bedingung()
    }

    private let gruppe = SyncPlayGruppe(id: "g1", name: "Filmabend", zustand: .leer, teilnehmer: ["Paul"])

    private func schlange(_ titel: String = "i1", eintrag: String = "p1", ab: Double = 0) -> SyncPlayWarteschlange {
        .init(grund: "NewPlaylist", stand: Date(), eintraege: [.init(titel: titel, eintrag: eintrag)],
              index: 0, startstelle: ab, laeuft: false)
    }

    /// In der Gruppe, Titel geladen, „bereit" gemeldet.
    private func geladeneSitzung(stelle: Double = 60) async -> (SyncPlaySitzung, Probespieler) {
        let s = sitzung()
        let p = Probespieler(titel: "i1", stelle: stelle)
        s.annehmen(.beigetreten(gruppe))
        #expect(await bis { await s.lage.gruppe != nil })
        await s.anschliessen(p)
        s.annehmen(.warteschlange(schlange(ab: stelle)))
        #expect(await bis { !Mitschrift.alle("SyncPlay/Ready").isEmpty })
        return (s, p)
    }

    // MARK: Tests

    @Test func beitrittUndWerKam() async {
        let s = sitzung()
        s.annehmen(.beigetreten(gruppe))
        s.annehmen(.jemandKam("Tom"))
        #expect(await bis { await s.lage.gruppe?.teilnehmer == ["Paul", "Tom"] })
        #expect(await s.lage.ereignis?.art == .dabei("Tom"))
        #expect(await s.lage.ereignis?.text.contains("Tom") == true)

        // Man selbst auf einem zweiten Gerät: kein Hinweis.
        let vorher = await s.lage.ereignis?.id
        s.annehmen(.jemandKam("Paul"))
        #expect(await bis { await s.lage.gruppe?.teilnehmer.count == 3 })
        #expect(await s.lage.ereignis?.id == vorher)

        s.annehmen(.jemandGing("Tom"))
        #expect(await bis { await s.lage.ereignis?.art == .gegangen("Tom") })
        // Die Uhr läuft nach dem Beitritt an.
        #expect(await bis { !Mitschrift.alle("GetUtcTime").isEmpty })
    }

    @Test func warteschlangeOhnePlayerOeffnetIhn() async {
        let s = sitzung()
        s.annehmen(.beigetreten(gruppe))
        s.annehmen(.warteschlange(schlange("i7", ab: 42)))
        #expect(await bis { !geladen.alle().isEmpty })
        #expect(geladen.alle().first?.0 == "i7")
        #expect(geladen.alle().first?.1 == 42)
        #expect(await s.lage.gehoertZurGruppe("i7"))

        // Der Player geht auf und hat das Bild: anhalten und „bereit".
        let p = Probespieler(titel: "i7", stelle: 42)
        await s.anschliessen(p)
        #expect(await bis { !Mitschrift.alle("SyncPlay/Ready").isEmpty })
        #expect(p.protokoll().contains("anhalten"))
        let bereit = Mitschrift.alle("SyncPlay/Ready")[0].rumpf
        #expect(bereit["PlaylistItemId"] == "p1")
        #expect(bereit["PositionTicks"] == "420000000")
        #expect(bereit["IsPlaying"] == "0")
    }

    @Test func weiterZumZeitpunkt() async {
        let (s, p) = await geladeneSitzung()
        let wann = Date().addingTimeInterval(0.6)
        s.annehmen(.befehl(.init(gruppe: "g1", eintrag: "p1", art: .weiter, wann: wann, stelle: 60)))
        #expect(await bis { p.weiterZeit() != nil })
        let um = try! #require(p.weiterZeit())
        // Nicht vorher, und nicht merklich danach.
        #expect(um.timeIntervalSince(wann) > -0.05)
        #expect(um.timeIntervalSince(wann) < 0.3)
        // Stand auf der Stelle: kein Sprung.
        #expect(!p.protokoll().contains { $0.hasPrefix("springen") && $0 != "springen 60" })
    }

    @Test func weiterVerpasstSpringtDorthinWoDieGruppeIst() async {
        let (s, p) = await geladeneSitzung()
        s.annehmen(.befehl(.init(gruppe: "g1", eintrag: "p1", art: .weiter,
                                 wann: Date().addingTimeInterval(-5), stelle: 60)))
        #expect(await bis { p.weiterZeit() != nil })
        #expect(p.protokoll().contains("springen 65"))
    }

    @Test func neuerBefehlLoestDenWartendenAb() async {
        let (s, p) = await geladeneSitzung()
        s.annehmen(.befehl(.init(gruppe: "g1", eintrag: "p1", art: .weiter,
                                 wann: Date().addingTimeInterval(1), stelle: 60)))
        s.annehmen(.befehl(.init(gruppe: "g1", eintrag: "p1", art: .pause,
                                 wann: Date().addingTimeInterval(0.1), stelle: 60)))
        try? await Task.sleep(for: .seconds(1.4))
        #expect(p.weiterZeit() == nil)
        #expect(p.protokoll().filter { $0 == "anhalten" }.count >= 2)
    }

    @Test func sprungSpieltAnUndMeldetDasZiel() async {
        let (s, p) = await geladeneSitzung()
        let vorher = Mitschrift.alle("SyncPlay/Ready").count
        s.annehmen(.befehl(.init(gruppe: "g1", eintrag: "p1", art: .springen,
                                 wann: Date(), stelle: 120)))
        #expect(await bis { Mitschrift.alle("SyncPlay/Ready").count > vorher })
        let schritte = p.protokoll()
        let i = try! #require(schritte.lastIndex(of: "springen 120"))
        #expect(Array(schritte[i...].prefix(3)) == ["springen 120", "weiter", "anhalten"])
        #expect(Mitschrift.alle("SyncPlay/Ready").last?.rumpf["PositionTicks"] == "1200000000")
    }

    @Test func befehlFuerAnderenEintragWartet() async {
        let (s, p) = await geladeneSitzung()
        s.annehmen(.befehl(.init(gruppe: "g1", eintrag: "p9", art: .weiter,
                                 wann: Date(), stelle: 0)))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(p.weiterZeit() == nil)
    }

    @Test func verlassenMerktDieGruppe() async {
        let (s, _) = await geladeneSitzung()
        await s.abtrennen()
        #expect(await s.lage.gruppe == nil)
        #expect(await s.lage.zuletztVerlassen?.id == "g1")
        #expect(await s.imPlayer == false)
        #expect(await bis { !Mitschrift.alle("SyncPlay/Leave").isEmpty })

        await s.beenden()
        #expect(await s.lage.zuletztVerlassen == nil)
    }

    @Test func bitteVerweigertKommtAlsFehler() async {
        let s = sitzung()
        Mitschrift.sperre.withLock { Mitschrift.verweigert = ["SyncPlay/Pause"] }
        var mitteilungen = s.mitteilungen.makeAsyncIterator()
        await s.bitteUmschalten(laeuftGerade: true)
        #expect(!Mitschrift.alle("SyncPlay/Pause").isEmpty)
        var gefunden = false
        for _ in 0..<5 {
            guard let m = await mitteilungen.next() else { break }
            if case .fehler(.nichtFreigegeben) = m { gefunden = true; break }
        }
        #expect(gefunden)
    }

    @Test func gibtEsNichtRaeumtAuf() async {
        let (s, _) = await geladeneSitzung()
        s.annehmen(.gibtEsNicht)
        #expect(await bis { await s.lage.gruppe == nil })
        #expect(await s.lage.schlangeTitel == nil)
    }

    @Test func kontowechselVerlaesstMitDemAltenClient() async {
        let (s, _) = await geladeneSitzung()
        await s.beenden(alterClient: Self.client())
        #expect(await s.lage.gruppe == nil)
        #expect(await s.lage.zuletztVerlassen == nil)
        #expect(await bis { !Mitschrift.alle("SyncPlay/Leave").isEmpty })
    }

    @Test func folgenwahlSetztDieWarteschlange() async {
        let (s, _) = await geladeneSitzung()
        await s.bitteTitel("i2", ab: 30)
        let aufruf = Mitschrift.alle("SyncPlay/SetNewQueue").last?.rumpf
        #expect(aufruf?["StartPositionTicks"] == "300000000")
        #expect(aufruf?["PlayingQueue"]?.contains("i2") == true)
    }

    // MARK: Leitung abgerissen

    @Test func abrissMitWiedereintrittTrittDerGruppeWiederBei() async {
        let (s, p) = await geladeneSitzung(stelle: 60)
        await s.geduldSetzen(leitung: 5, versuche: 3, antwort: 1, pause: 0.05)
        let readyVorher = Mitschrift.alle("SyncPlay/Ready").count

        s.annehmen(.leitungVerloren)
        // Die Gruppe bleibt stehen, solange man um sie kämpft.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await s.lage.gruppe?.id == "g1")
        #expect(Mitschrift.alle("SyncPlay/Join").isEmpty)

        s.annehmen(.leitungWieder)
        #expect(await bis { !Mitschrift.alle("SyncPlay/Join").isEmpty })
        #expect(Mitschrift.alle("SyncPlay/Join")[0].rumpf["GroupId"] == "g1")

        // Der Server bestätigt: Stand melden, keine Fehlermeldung.
        s.annehmen(.beigetreten(gruppe))
        #expect(await bis { Mitschrift.alle("SyncPlay/Ready").count > readyVorher })
        #expect(Mitschrift.alle("SyncPlay/Ready").last?.rumpf["IsPlaying"] == "0")
        #expect(await s.lage.gruppe?.id == "g1")
        _ = p
    }

    @Test func abrissOhneWiedereintrittMeldetVerlust() async {
        let (s, _) = await geladeneSitzung()
        await s.geduldSetzen(leitung: 5, versuche: 2, antwort: 0.1, pause: 0.02)
        let hoerer = Task<String?, Never> {
            for await m in s.mitteilungen {
                if case let .fehler(f) = m, case .leitungVerloren = f { return f.text }
            }
            return nil
        }
        s.annehmen(.leitungVerloren)
        s.annehmen(.leitungWieder)
        // Kein GroupJoined: nach den Versuchen ist die Gruppe weg, mit Hinweis.
        #expect(await bis { await s.lage.gruppe == nil })
        let fehlerText = await hoerer.value
        #expect(Mitschrift.alle("SyncPlay/Join").count == 2)
        #expect(fehlerText?.isEmpty == false)
    }

    @Test func leitungKehrtNieZurueck() async {
        let (s, _) = await geladeneSitzung()
        await s.geduldSetzen(leitung: 0.1, versuche: 1, antwort: 0.1, pause: 0.02)
        s.annehmen(.leitungVerloren)
        #expect(await bis { await s.lage.gruppe == nil })
        #expect(Mitschrift.alle("SyncPlay/Join").isEmpty)
    }

    @Test func abrissOhneGruppeTutNichts() async {
        let s = sitzung()
        s.annehmen(.leitungVerloren)
        s.annehmen(.leitungWieder)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(Mitschrift.alle("SyncPlay/Join").isEmpty)
    }
}
