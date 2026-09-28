import Foundation
import Testing
@testable import JellyfinKit

/// **Was ein Server schicken kann, darf die App nicht umwerfen** (Robustheit
/// 1.0.5). Grosse Bibliotheken, fehlende Felder, Null, Unsinn — und Zahlen,
/// die keine sind.
@Suite("Robust einlesen")
struct RobustDekodierenTests {

    /// Eine Seite wie aus einer Bibliothek mit 5000 Titeln: jeder zehnte ohne
    /// Laufzeit, Nutzerdaten und Bilder, sehr lange Namen, einige kaputt.
    private func grosseSeite(_ anzahl: Int) -> Data {
        var teile: [String] = []
        teile.reserveCapacity(anzahl)
        let lang = String(repeating: "Sehr langer Titel ", count: 150)
        for i in 0..<anzahl {
            switch i % 10 {
            case 1: teile.append(#"{"Id":"f\#(i)","Name":"\#(lang)\#(i)","Type":"Movie"}"#)
            case 2: teile.append(#"{"Id":"f\#(i)","Name":"F\#(i)","RunTimeTicks":null,"UserData":null,"ImageTags":null,"ProductionYear":null}"#)
            case 3: teile.append(#"{"Id":"f\#(i)","Name":"F\#(i)","UserData":{"PlaybackPositionTicks":1000000000000000000,"PlayedPercentage":1e308}}"#)
            case 4: teile.append(#"{"Id":null,"Name":"ohne Kennung"}"#)
            case 5: teile.append(#"{"Name":"ohne Kennung und Typ"}"#)
            case 6: teile.append("null")
            default: teile.append(#"{"Id":"f\#(i)","Name":"F\#(i)","Type":"Movie","RunTimeTicks":60000000000,"UserData":{"Played":true}}"#)
            }
        }
        return Data((#"{"Items":["# + teile.joined(separator: ",") + #"],"TotalRecordCount":\#(anzahl)}"#).utf8)
    }

    @Test("5000 Titel mit Luecken: die lesbaren kommen durch, die Zahl stimmt")
    func grosseBibliothek() throws {
        let antwort = try JSONDecoder().decode(ItemsResponse.self, from: grosseSeite(5000))
        // Rest 4, 5 und 6 sind unlesbar — drei von zehn fallen weg.
        #expect(antwort.items.count == 3500)
        #expect(antwort.totalRecordCount == 5000)
        #expect(antwort.items.allSatisfy { !$0.id.isEmpty })
    }

    @Test("Gesehener Anteil bleibt zwischen 0 und 100 — auch bei Unsinn vom Server")
    func anteilBegrenzt() throws {
        func anteil(_ roh: String) throws -> Double? {
            try JSONDecoder().decode(UserItemData.self, from: Data(#"{"PlayedPercentage":\#(roh)}"#.utf8))
                .playedPercentage
        }
        #expect(try anteil("1e308") == 100)
        #expect(try anteil("-3") == 0)
        #expect(try anteil("42.5") == 42.5)
        #expect(try anteil("null") == nil)
        // Die Stelle, an der tvOS abstuerzte: `Int(anteil * 100)` in der Kachel.
        let item = try JSONDecoder().decode(Item.self, from: Data(
            #"{"Id":"a","Name":"b","UserData":{"PlayedPercentage":1e308}}"#.utf8))
        #expect(Int(try #require(item.gesehenerAnteil) * 100) == 100)
    }

    @Test("Ticks aus Sekunden: NaN, Unendlich und Negatives werfen nicht")
    func ticksOhneAbsturz() {
        #expect(JellyfinClient.ticks(fromSeconds: .nan) == 0)
        #expect(JellyfinClient.ticks(fromSeconds: .infinity) == 0)
        #expect(JellyfinClient.ticks(fromSeconds: -.infinity) == 0)
        #expect(JellyfinClient.ticks(fromSeconds: -5) == 0)
        #expect(JellyfinClient.ticks(fromSeconds: 1e300) > 0)
        #expect(JellyfinClient.ticks(fromSeconds: 90) == 900_000_000)
        #expect(JellyfinClient.ticks(fromSeconds: 1.5) == 15_000_000)
    }
}
