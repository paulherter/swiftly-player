import Foundation
import Testing
@testable import JellyfinKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **Zwei Geräte in einer Gruppe, gegen einen nachgebauten Server.**
///
/// Der Server hier macht, was Jellyfins `SyncPlay`-Gruppe tut, so weit es den
/// Abgleich angeht: Bitten annehmen, auf alle warten, Befehle mit einem
/// Zeitpunkt in der Zukunft verteilen. Seine Uhr geht 2,5 s vor, und die
/// beiden Geräte hören ihn verschieden schnell (30 und 150 ms) — beides muss
/// der Zeitabgleich schlucken. Gemessen wird, wann und wo die beiden Player
/// weiterlaufen, anhalten und nach einem Sprung stehen.
@Suite("SyncPlay: zwei Geräte im Gleichschritt", .serialized)
struct SyncPlayGleichschrittTests {

    // MARK: Der nachgebaute Server

    final class Gruppenserver: @unchecked Sendable {
        static let uhrVorlauf: TimeInterval = 2.5
        static let sperre = NSLock()
        nonisolated(unsafe) static var laufend: Gruppenserver?

        struct Mitglied { let name: String; let sitzung: SyncPlaySitzung; let verzug: Double }
        var mitglieder: [String: Mitglied] = [:]   // Geräte-ID
        var drin: Set<String> = []
        var bereit: Set<String> = []
        var titel = ""
        var eintrag = "p1"
        var stelle: Double = 0
        var stelleAb = Date()          // Serverzeit, ab der `stelle` gilt, wenn es läuft
        var laeuft = false
        var weiterNachSprung = false
        var protokoll: [String] = []

        func jetzt() -> Date { Date().addingTimeInterval(Self.uhrVorlauf) }

        func aktuelleStelle() -> Double {
            laeuft ? stelle + jetzt().timeIntervalSince(stelleAb) : stelle
        }

        func senden(_ an: String, _ n: SyncPlayNachricht) {
            guard let m = mitglieder[an] else { return }
            Task {
                try? await Task.sleep(for: .seconds(m.verzug))
                m.sitzung.annehmen(n)
            }
        }
        func allen(_ n: SyncPlayNachricht) { for id in drin { senden(id, n) } }

        func befehl(_ art: SyncPlayBefehl.Art, in sekunden: Double) {
            let b = SyncPlayBefehl(gruppe: "g1", eintrag: eintrag, art: art,
                                   wann: jetzt().addingTimeInterval(sekunden),
                                   stelle: aktuelleStelle(), ausgesandt: jetzt())
            protokoll.append("Server: \(art.rawValue) bei \(String(format: "%.2f", b.stelle ?? 0)) s")
            allen(.befehl(b))
        }

        func gruppe() -> SyncPlayGruppe {
            SyncPlayGruppe(id: "g1", name: "Messlauf", zustand: laeuft ? .laeuft : .angehalten,
                           teilnehmer: drin.compactMap { mitglieder[$0]?.name }.sorted())
        }

        func schlange() -> SyncPlayWarteschlange {
            .init(grund: "NewPlaylist", stand: jetzt(), eintraege: [.init(titel: titel, eintrag: eintrag)],
                  index: 0, startstelle: stelle, laeuft: laeuft)
        }

        /// Ein Aufruf eines Geräts. Gibt den Rumpf der Antwort zurück.
        func aufruf(_ geraet: String, _ pfad: String, _ rumpf: [String: Any]) -> Data {
            Self.sperre.lock(); defer { Self.sperre.unlock() }
            switch pfad {
            case "GetUtcTime":
                let t = SyncPlay.zeitText(jetzt())
                return Data(#"{"RequestReceptionTime":"\#(t)","ResponseTransmissionTime":"\#(t)"}"#.utf8)
            case "SyncPlay/New":
                bereit = []
                drin = [geraet]
                senden(geraet, .beigetreten(gruppe()))
            case "SyncPlay/Join":
                for id in drin { senden(id, .jemandKam(mitglieder[geraet]!.name)) }
                drin.insert(geraet)
                senden(geraet, .beigetreten(gruppe()))
                bereit.remove(geraet)
                senden(geraet, .warteschlange(schlange()))
            case "SyncPlay/SetNewQueue":
                titel = (rumpf["PlayingQueue"] as? [String])?.first ?? ""
                stelle = SyncPlay.sekunden((rumpf["StartPositionTicks"] as? NSNumber)?.int64Value ?? 0)
                laeuft = false
                bereit = []
                allen(.warteschlange(schlange()))
            case "SyncPlay/Ready":
                bereit.insert(geraet)
                if bereit.count == drin.count, weiterNachSprung {
                    weiterNachSprung = false
                    befehl(.weiter, in: 0.5)
                    laeuft = true; stelleAb = jetzt().addingTimeInterval(0.5)
                }
            case "SyncPlay/Unpause":
                guard bereit.count == drin.count else { break }
                // Wie Jellyfin: in der Zukunft, damit jeder es rechtzeitig hört.
                befehl(.weiter, in: 0.5)
                laeuft = true; stelleAb = jetzt().addingTimeInterval(0.5)
            case "SyncPlay/Pause":
                stelle = aktuelleStelle(); laeuft = false
                befehl(.pause, in: 0)
            case "SyncPlay/Seek":
                weiterNachSprung = laeuft
                laeuft = false
                stelle = SyncPlay.sekunden((rumpf["PositionTicks"] as? NSNumber)?.int64Value ?? 0)
                bereit = []
                befehl(.springen, in: 0)
            default:
                break
            }
            return Data()
        }
    }

    final class Leitung: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let pfad = String(request.url!.path.dropFirst())
            let kopf = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let geraet = kopf.components(separatedBy: "DeviceId=\"").dropFirst().first?
                .components(separatedBy: "\"").first ?? "?"
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
            let rumpf = (try? JSONSerialization.jsonObject(with: daten) as? [String: Any]) ?? [:]
            let antwortDaten = Gruppenserver.laufend?.aufruf(geraet, pfad, rumpf) ?? Data()
            let antwort = HTTPURLResponse(url: request.url!, statusCode: antwortDaten.isEmpty ? 204 : 200,
                                          httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: antwort, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: antwortDaten)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    // MARK: Ein Player mit Uhr

    final class Uhrspieler: SyncPlaySpieler, @unchecked Sendable {
        private let sperre = NSLock()
        private let id: String
        private var basis: Double = 0
        private var seit = Date()
        private var laeuft = false
        private(set) var weiterUm: [Date] = []
        init(_ id: String) { self.id = id }
        private func jetzt() -> Double { laeuft ? basis + Date().timeIntervalSince(seit) : basis }
        func weiterZeiten() -> [Date] { sperre.withLock { weiterUm } }
        func titel() async -> String { id }
        func bereit() async -> Bool { true }
        func stelle() async -> Double { sperre.withLock { jetzt() } }
        func weiter() async { sperre.withLock { basis = jetzt(); seit = Date(); laeuft = true; weiterUm.append(Date()) } }
        func anhalten() async { sperre.withLock { basis = jetzt(); laeuft = false } }
        func springen(_ ziel: Double) async { sperre.withLock { basis = ziel; seit = Date() } }
    }

    private func geraet(_ id: String, _ name: String, verzug: Double, server: Gruppenserver)
        -> (SyncPlaySitzung, Uhrspieler) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Leitung.self]
        let adresse = URL(string: "https://tv.example.de")!
        let c = JellyfinClient(baseURL: adresse, deviceID: id, deviceName: name,
                               session: .init(accessToken: "tok-\(id)", userID: "u-\(id)",
                                              userName: name, serverURL: adresse),
                               urlSession: URLSession(configuration: config))
        let spieler = Uhrspieler("i1")
        let s = SyncPlaySitzung(client: { c }, ich: { name }, titelLaden: { _, _ in true })
        Gruppenserver.sperre.withLock {
            server.mitglieder[id] = .init(name: name, sitzung: s, verzug: verzug)
        }
        return (s, spieler)
    }

    private func bis(_ frist: Double = 5, _ bedingung: () async -> Bool) async -> Bool {
        let ende = Date().addingTimeInterval(frist)
        while Date() < ende {
            if await bedingung() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await bedingung()
    }

    @Test func pausePlaySpulenKommenGleichzeitigAn() async throws {
        let server = Gruppenserver()
        Gruppenserver.laufend = server
        defer { Gruppenserver.laufend = nil }
        var protokoll: [String] = []
        func notiere(_ s: String) { protokoll.append(s) }

        let (a, spielerA) = geraet("a", "Paul", verzug: 0.03, server: server)
        let (b, spielerB) = geraet("b", "Tom", verzug: 0.15, server: server)
        await a.anschliessen(spielerA)
        await b.anschliessen(spielerB)

        // A legt an, B tritt bei.
        #expect(await a.anlegen(name: "Messlauf", titel: "i1"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await b.beitreten(SyncPlayGruppe(id: "g1", name: "Messlauf")))
        // Beide messen die Uhr und melden „bereit".
        #expect(await bis { Gruppenserver.sperre.withLock { server.bereit.count } == 2 })
        #expect(await bis {
            let x = await a.abgleich.bereit
            let y = await b.abgleich.bereit
            return x && y
        })
        let versatzA = await a.abgleich.versatz, versatzB = await b.abgleich.versatz
        notiere("Uhr: A \(Int(versatzA * 1000)) ms, B \(Int(versatzB * 1000)) ms (Server geht 2500 ms vor)")
        #expect(abs(versatzA - Gruppenserver.uhrVorlauf) < 0.1)
        #expect(abs(versatzB - Gruppenserver.uhrVorlauf) < 0.1)

        func abstand(_ was: String) async -> Double {
            let sa = await spielerA.stelle(), sb = await spielerB.stelle()
            notiere("\(was): A \(String(format: "%.3f", sa)) s · B \(String(format: "%.3f", sb)) s · Versatz \(Int(abs(sa - sb) * 1000)) ms")
            return abs(sa - sb)
        }
        func startAbstand(_ n: Int) -> Double {
            let ta = spielerA.weiterZeiten(), tb = spielerB.weiterZeiten()
            guard ta.count > n, tb.count > n else { return .infinity }
            let d = abs(ta[n].timeIntervalSince(tb[n]))
            notiere("Weiter Nr. \(n + 1): Start liegt \(Int(d * 1000)) ms auseinander")
            return d
        }

        // Weiter (bittet B, der langsamere).
        await b.bitteUmschalten(laeuftGerade: false)
        #expect(await bis { spielerA.weiterZeiten().count == 1 && spielerB.weiterZeiten().count == 1 })
        #expect(startAbstand(0) < 0.1)
        try await Task.sleep(for: .seconds(1.5))
        #expect(await abstand("nach 1,5 s Lauf") < 0.1)

        // Pause (bittet A).
        await a.bitteUmschalten(laeuftGerade: true)
        try await Task.sleep(for: .milliseconds(600))
        // Die Pause gilt „jetzt" — wer sie später hört, hält später an. Unter
        // der Sprunggrenze bleibt er stehen, wo er ist (wie jellyfin-web).
        #expect(await abstand("angehalten") < SyncPlay.sprunggrenze + 0.05)

        // Spulen auf 300 s, während es steht — dann wieder weiter.
        await a.bitteSpringen(auf: 300)
        #expect(await bis { Gruppenserver.sperre.withLock { server.bereit.count } == 2 })
        #expect(await abstand("nach dem Sprung") < 0.1)
        #expect(abs(await spielerA.stelle() - 300) < 0.5)
        await b.bitteUmschalten(laeuftGerade: false)
        #expect(await bis { spielerA.weiterZeiten().count >= 3 && spielerB.weiterZeiten().count >= 3 })
        #expect(startAbstand(spielerA.weiterZeiten().count - 1) < 0.1)
        try await Task.sleep(for: .seconds(1))
        #expect(await abstand("nach 1 s Lauf") < 0.1)

        // Spulen im Lauf: alle halten an, springen, und laufen gemeinsam weiter.
        let vorherA = spielerA.weiterZeiten().count, vorherB = spielerB.weiterZeiten().count
        await b.bitteSpringen(auf: 120)
        // Einmal zum Anspielen nach dem Sprung, einmal auf das gemeinsame Weiter.
        #expect(await bis { spielerA.weiterZeiten().count >= vorherA + 2
                            && spielerB.weiterZeiten().count >= vorherB + 2 })
        try await Task.sleep(for: .seconds(1))
        #expect(await abstand("Sprung im Lauf, danach") < 0.1)
        #expect(abs(await spielerA.stelle() - 120) < 3)

        await a.bitteUmschalten(laeuftGerade: true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await abstand("zum Schluss angehalten") < SyncPlay.sprunggrenze + 0.05)

        await a.abtrennen(); await b.abtrennen()
        for zeile in Gruppenserver.sperre.withLock({ server.protokoll }) + protokoll {
            print("[Gleichschritt] \(zeile)")
        }
    }
}
