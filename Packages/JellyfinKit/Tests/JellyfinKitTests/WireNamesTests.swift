import Foundation
import Testing
@testable import JellyfinKit

/// **The stored and exchanged JSON keeps its old key names.** Property names were
/// translated; the keys that devices in the field already wrote must still decode, and
/// newly written data must still use them.
@Suite struct WireNamesTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func keys<T: Encodable>(_ value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Set(object?.keys.map { $0 } ?? [])
    }

    @Test("A pending report written by an older version still decodes")
    func pendingReport() throws {
        let report = try decode(PendingReport.self, #"{"itemID":"i1","konto":"u1","ticks":42,"wann":700000000}"#)
        #expect(report.account == "u1" && report.ticks == 42)
        #expect(try keys(report) == ["itemID", "konto", "ticks", "wann"])
    }

    @Test("An own header keeps the key `wert`")
    func ownHeader() throws {
        let header = try decode(OwnHeader.self, #"{"name":"X-Test","wert":"1"}"#)
        #expect(header.value == "1")
        #expect(try keys(header) == ["name", "wert"])
    }

    @Test("The account bundle keeps `konten` and `aktiveKennung`")
    func accountBundle() throws {
        let json = #"{"konten":[{"accessToken":"t","userID":"u","userName":"n","serverURL":"https://x.test"}],"aktiveKennung":"u"}"#
        let bundle = try decode(AccountBundle.self, json)
        #expect(bundle.activeId == "u" && bundle.accounts.count == 1)
        #expect(try keys(bundle) == ["konten", "aktiveKennung"])
    }

    @Test("The stored home page keeps its German keys")
    func homeStore() throws {
        let json = #"{"fassung":1,"bibliotheken":[],"weiterschauen":[],"naechsteFolge":[],"zuletzt":[],"neueFilme":[],"neueSerien":[],"gattungsreihen":[]}"#
        let store = try decode(HomeStore.self, json)
        #expect(store.version == 1 && store.libraries.isEmpty)
        #expect(try keys(store) == ["fassung", "bibliotheken", "weiterschauen", "naechsteFolge", "zuletzt", "neueFilme", "neueSerien", "gattungsreihen"])
    }

    @Test("A start library keeps `sammlung`")
    func startLibrary() throws {
        let library = try decode(StartLibrary.self, #"{"id":"a","name":"Filme","sammlung":true}"#)
        #expect(library.collection)
        #expect(try keys(library) == ["id", "name", "sammlung"])
    }

    @Test("A Seerr season keeps `nummer`, `folgen` and `stand`")
    func seerrSeason() throws {
        let season = try decode(SeerrSeason.self, #"{"nummer":2,"folgen":10,"stand":5}"#)
        #expect(season.number == 2 && season.episodes == 10 && season.state == .present)
        #expect(try keys(season) == ["nummer", "folgen", "stand"])
    }
}
