import Foundation
import Testing
@testable import JellyfinKit

/// **Whatever a server can send must not knock the app over.**
/// Large libraries, missing fields, null, nonsense, and numbers
/// that are not numbers.
@Suite("Robust einlesen")
struct RobustDecodeTests {

    /// A page like from a library with 5000 titles: every tenth without
    /// runtime, user data and images, very long names, some broken.
    private func largePage(_ count: Int) -> Data {
        var parts: [String] = []
        parts.reserveCapacity(count)
        let long = String(repeating: "Sehr langer Titel ", count: 150)
        for i in 0..<count {
            switch i % 10 {
            case 1: parts.append(#"{"Id":"f\#(i)","Name":"\#(long)\#(i)","Type":"Movie"}"#)
            case 2: parts.append(#"{"Id":"f\#(i)","Name":"F\#(i)","RunTimeTicks":null,"UserData":null,"ImageTags":null,"ProductionYear":null}"#)
            case 3: parts.append(#"{"Id":"f\#(i)","Name":"F\#(i)","UserData":{"PlaybackPositionTicks":1000000000000000000,"PlayedPercentage":1e308}}"#)
            case 4: parts.append(#"{"Id":null,"Name":"ohne Kennung"}"#)
            case 5: parts.append(#"{"Name":"ohne Kennung und Typ"}"#)
            case 6: parts.append("null")
            default: parts.append(#"{"Id":"f\#(i)","Name":"F\#(i)","Type":"Movie","RunTimeTicks":60000000000,"UserData":{"Played":true}}"#)
            }
        }
        return Data((#"{"Items":["# + parts.joined(separator: ",") + #"],"TotalRecordCount":\#(count)}"#).utf8)
    }

    @Test("5000 Titel mit Luecken: die lesbaren kommen durch, die Zahl stimmt")
    func largeLibrary() throws {
        let answer = try JSONDecoder().decode(ItemsResponse.self, from: largePage(5000))
        // Rest 4, 5 and 6 are unreadable; three of ten drop out.
        #expect(answer.items.count == 3500)
        #expect(answer.totalRecordCount == 5000)
        #expect(answer.items.allSatisfy { !$0.id.isEmpty })
    }

    @Test("Gesehener Anteil bleibt zwischen 0 und 100 — auch bei Unsinn vom Server")
    func shareLimited() throws {
        func share(_ raw: String) throws -> Double? {
            try JSONDecoder().decode(UserItemData.self, from: Data(#"{"PlayedPercentage":\#(raw)}"#.utf8))
                .playedPercentage
        }
        #expect(try share("1e308") == 100)
        #expect(try share("-3") == 0)
        #expect(try share("42.5") == 42.5)
        #expect(try share("null") == nil)
        // Where tvOS crashed: `Int(share * 100)` in the tile.
        let item = try JSONDecoder().decode(Item.self, from: Data(
            #"{"Id":"a","Name":"b","UserData":{"PlayedPercentage":1e308}}"#.utf8))
        #expect(Int(try #require(item.watchedShare) * 100) == 100)
    }

    @Test("Ticks aus Sekunden: NaN, Unendlich und Negatives werfen nicht")
    func ticksWithoutCrash() {
        #expect(JellyfinClient.ticks(fromSeconds: .nan) == 0)
        #expect(JellyfinClient.ticks(fromSeconds: .infinity) == 0)
        #expect(JellyfinClient.ticks(fromSeconds: -.infinity) == 0)
        #expect(JellyfinClient.ticks(fromSeconds: -5) == 0)
        #expect(JellyfinClient.ticks(fromSeconds: 1e300) > 0)
        #expect(JellyfinClient.ticks(fromSeconds: 90) == 900_000_000)
        #expect(JellyfinClient.ticks(fromSeconds: 1.5) == 15_000_000)
    }
}
