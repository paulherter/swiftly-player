import Foundation
import Testing
@testable import JellyfinKit

@Suite("Fixture accounts: which ones are removed")
struct FixtureAccountPruneTests {

    private func account(_ name: String, _ address: String, kind: ServerKind = .jellyfin) -> Session {
        Session(accessToken: "secret-\(name)", userID: "id-\(name)", userName: name,
                serverURL: URL(string: address)!, kind: kind)
    }

    @Test("Only addresses on this machine are local")
    func local() {
        for a in ["http://127.0.0.1:8096", "http://127.0.0.1:54321", "http://localhost:8096", "http://LOCALHOST", "http://[::1]:8096"] {
            #expect(FixtureAccountPrune.isLocal(URL(string: a)!), "\(a)")
        }
        for a in ["https://tv.example.de", "http://192.168.1.20:8096", "http://127.0.0.2:1", "http://127.0.0.1.example.com",
                  "https://localhost.example.de", "http://10.0.0.1"] {
            #expect(!FixtureAccountPrune.isLocal(URL(string: a)!), "\(a)")
        }
    }

    @Test("Real and Plex accounts are never selected")
    func selection() {
        let real = account("paul", "https://tv.example.de")
        let lan = account("lan", "http://192.168.1.20:8096")
        let plex = account("plex", "https://192-168-1-5.abc.plex.direct:32400", kind: .plex)
        let demo1 = account("demo", "http://127.0.0.1:50001")
        let demo2 = account("demo", "http://localhost:50002")
        let picked = FixtureAccountPrune.selection(from: [demo1, real, lan, demo2, plex])
        #expect(picked == [demo1, demo2])
    }

    @Test("The backup lists every account without secrets and marks the removed ones")
    func backup() throws {
        let real = account("paul", "https://tv.example.de")
        let demo = account("demo", "http://127.0.0.1:50001")
        let data = try FixtureAccountPrune.backup(of: [real, demo], at: Date(timeIntervalSince1970: 0))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("secret-"))
        #expect(text.contains("tv.example.de") && text.contains("127.0.0.1:50001"))
        let file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(file["accounts"] as? [[String: Any]])
        #expect(rows.map { $0["remove"] as? Bool } == [false, true])
    }
}
