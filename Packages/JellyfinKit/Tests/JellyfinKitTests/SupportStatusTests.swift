import Foundation
import Testing
@testable import JellyfinKit

@Suite("Support status and storage")
struct SupportStatusTests {
    static let since = Date(timeIntervalSince1970: 1_792_281_600)

    func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: Data(text.utf8))
    }

    @Test("The stored JSON shape is fixed")
    func wireShape() throws {
        #expect(try json(SupportStatus.none) == #"{"kind":"none"}"#)
        #expect(try json(SupportStatus.supporter(source: .store, since: Self.since))
            == #"{"kind":"supporter","since":1792281600,"source":"store"}"#)
        #expect(try json(SupportStatus.supporter(source: .key, since: nil)) == #"{"kind":"supporter","source":"key"}"#)
        #expect(try json(SupportUsage(firstLaunch: Self.since, watchedSeconds: 7_200))
            == #"{"firstLaunch":1792281600,"watchedSeconds":7200}"#)
        #expect(try json(SupportPromptHistory(cardSnoozedUntil: Self.since, cardDismissed: true, sheetShownAt: [Self.since]))
            == #"{"cardDismissed":true,"cardSnoozedUntil":1792281600,"cardSnoozes":0,"sheetShownAt":[1792281600]}"#)
    }

    @Test("Stored JSON reads back", arguments: [
        SupportStatus.none,
        .supporter(source: .store, since: since),
        .supporter(source: .key, since: nil),
    ])
    func roundTrip(_ status: SupportStatus) throws {
        #expect(try decode(SupportStatus.self, try json(status)) == status)
    }

    @Test("Unknown kinds do not decode")
    func unknownKind() {
        #expect(throws: (any Error).self) { try decode(SupportStatus.self, #"{"kind":"gold"}"#) }
    }

    @Test("Store: empty storage reads as nothing, writes go to the fixed keys")
    func store() {
        let storage = InMemorySupportStorage()
        let store = SupportStore(storage: storage)
        #expect(store.status == .none)
        #expect(store.usage == SupportUsage())
        #expect(store.promptHistory == SupportPromptHistory())

        store.status = .supporter(source: .key, since: Self.since)
        store.recordLaunch(now: Self.since)
        store.recordLaunch(now: Self.since.addingTimeInterval(1_000)) // second launch changes nothing
        var history = store.promptHistory
        history.dismissCard()
        store.promptHistory = history

        #expect(Set(storage.values.keys) == Set(SupportStorageKey.all))
        let reread = SupportStore(storage: storage)
        #expect(reread.status == .supporter(source: .key, since: Self.since))
        #expect(reread.usage.firstLaunch == Self.since)
        #expect(reread.promptHistory.cardDismissed)
    }

    @Test("Store: a damaged record reads as empty instead of failing")
    func damagedRecord() {
        let storage = InMemorySupportStorage(values: [SupportStorageKey.status: Data("{".utf8)])
        #expect(SupportStore(storage: storage).status == .none)
    }

    @Test("Storage keys are stable")
    func keys() {
        #expect(SupportStorageKey.all == ["support.status", "support.usage", "support.promptHistory"])
    }
}

@Suite("Support copy and tips")
struct SupportCopyTests {
    @Test("Keys are unique and every text has both languages")
    func uniqueAndComplete() {
        let keys = SupportCopy.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        for text in SupportCopy.all {
            #expect(!text.de.isEmpty && !text.en.isEmpty)
            #expect(text.de != text.en || text.de == "Swiftly")
        }
    }

    @Test("Placeholders match between the languages")
    func placeholders() {
        func tokens(_ s: String) -> [String] {
            ["%lld", "%@"].flatMap { token in Array(repeating: token, count: s.components(separatedBy: token).count - 1) }
        }
        for text in SupportCopy.all {
            #expect(tokens(text.de) == tokens(text.en), "\(text.key)")
        }
        #expect(String(format: SupportCopy.cardWatchedHours.en, 25) == "You have watched 25 hours with Swiftly.")
    }

    @Test("No exclamation marks and none of the banned words")
    func wording() {
        let banned = ["seamless", "nahtlos", "effortless", "mühelos", "powerful", "beautiful", "intuitive",
                      "ultimate", "ultimativ", "genieße", "experience", "unleash", "journey", "Sie "]
        for text in SupportCopy.all {
            #expect(!text.de.contains("!") && !text.en.contains("!"), "\(text.key)")
            for word in banned {
                #expect(!text.de.contains(word) && !text.en.lowercased().contains(word.lowercased()), "\(text.key): \(word)")
            }
        }
    }

    @Test("Language choice: German for de-*, English otherwise")
    func language() {
        #expect(SupportCopy.notNow.text(forLanguage: "de-AT") == "Nicht jetzt")
        #expect(SupportCopy.notNow.text(forLanguage: "DE") == "Nicht jetzt")
        #expect(SupportCopy.notNow.text(forLanguage: "fr") == "Not now")
    }

    @Test("Tips: fixed product IDs, smallest first")
    func tips() {
        #expect(SupportTip.ordered.map(\.productID) == [
            "de.paulherter.swiftly.tip.coffee",
            "de.paulherter.swiftly.tip.cake",
            "de.paulherter.swiftly.tip.movie",
        ])
        #expect(SupportTip.ordered == SupportTip.allCases)
        #expect(SupportTip(productID: "de.paulherter.swiftly.tip.cake") == .cake)
        #expect(SupportTip(productID: "de.paulherter.swiftly.tip.1") == nil)
        #expect(SupportTip.coffee.title == .tipCoffee)
    }
}
