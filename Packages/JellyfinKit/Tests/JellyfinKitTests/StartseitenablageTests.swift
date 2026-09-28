import Foundation
import Testing
@testable import JellyfinKit

@Suite("Startseitenablage")
struct StartseitenablageTests {

    /// Ein Eintrag, wie ihn der Server schickt — mit Stand, Bildern und
    /// Anbieternummern, damit die Rundreise mehr prüft als Kennung und Name.
    private func folge() throws -> Item {
        let json = """
        {"Id":"f1","Name":"Pilot","Type":"Episode","SeriesId":"s1","SeriesName":"Serie",
         "IndexNumber":1,"ParentIndexNumber":2,"Overview":"Worum es geht.",
         "ImageTags":{"Primary":"abc"},"BackdropImageTags":["b1"],
         "ProviderIds":{"Tvdb":"42"},"RunTimeTicks":27000000000,
         "UserData":{"PlaybackPositionTicks":6000000000,"Played":false,"IsFavorite":true}}
        """
        return try JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    @Test("Rundreise: was abgelegt wird, kommt gleich zurück")
    func rundreise() throws {
        let f = try folge()
        let ablage = Startseitenablage(bibliotheken: [Item(id: "b", name: "Serien")],
                                       weiterschauen: [f], naechsteFolge: [f], zuletzt: [],
                                       neueFilme: [], neueSerien: [f],
                                       gattungsreihen: [.init(name: "Drama", items: [f])])
        let zurueck = try #require(Startseitenablage.lesen(try ablage.daten()))
        #expect(zurueck == ablage)
        #expect(zurueck.weiterschauen.first?.userData?.playbackPositionTicks == 6000000000)
        #expect(zurueck.weiterschauen.first?.imageTags?["Primary"] == "abc")
    }

    @Test("Andere Fassung, Kaputtes und Leeres werden nicht gezeigt")
    func verworfen() throws {
        let f = try folge()
        var alt = Startseitenablage(bibliotheken: [], weiterschauen: [f], naechsteFolge: [],
                                    zuletzt: [], neueFilme: [], neueSerien: [], gattungsreihen: [])
        alt.fassung = Startseitenablage.aktuelleFassung + 1
        #expect(Startseitenablage.lesen(try alt.daten()) == nil)
        #expect(Startseitenablage.lesen(Data("{\"fassung\":1".utf8)) == nil)
        let leer = Startseitenablage(bibliotheken: [Item(id: "b", name: "x")], weiterschauen: [],
                                     naechsteFolge: [], zuletzt: [], neueFilme: [], neueSerien: [],
                                     gattungsreihen: [.init(name: "Drama", items: [])])
        #expect(Startseitenablage.lesen(try leer.daten()) == nil)
    }

    @Test("Dateiname je Konto, stabil und ohne Adresse")
    func dateiname() {
        let a = Startseitenablage.dateiname(konto: "https://server.example|u1")
        #expect(a == Startseitenablage.dateiname(konto: "https://server.example|u1"))
        #expect(a != Startseitenablage.dateiname(konto: "https://server.example|u2"))
        #expect(!a.contains("server"))
        #expect(a.hasSuffix(".json"))
    }
}
