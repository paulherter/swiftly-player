import Foundation
import StoreKitTest
import Testing
@testable import JellyfinKit

/// The local StoreKit configuration (`StoreKit/Swiftly.storekit`) names exactly the products the
/// code asks for, with the planned prices and kinds. (A command-line test process has no app
/// identity, so StoreKit itself cannot answer here; the buy flow runs from Xcode with this file
/// set in the scheme, see `StoreKit/README.md`.)
struct SupportStoreKitConfigTests {
    private var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("StoreKit/Swiftly.storekit")
    }

    private struct Entry { let price: String; let type: String }

    private func entries() throws -> [String: Entry] {
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var items = root["products"] as? [[String: Any]] ?? []
        for group in root["subscriptionGroups"] as? [[String: Any]] ?? [] {
            items += group["subscriptions"] as? [[String: Any]] ?? []
        }
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            guard let id = item["productID"] as? String, let price = item["displayPrice"] as? String,
                  let type = item["type"] as? String else { return nil }
            return (id, Entry(price: price, type: type))
        })
    }

    @Test func productsMatchTheCode() throws {
        let found = try entries()
        #expect(Set(found.keys) == Set(SupportProductID.all))
        #expect(found[SupportProductID.monthly]?.price == "1.99")
        #expect(found[SupportProductID.monthly]?.type == "RecurringSubscription")
        #expect(found[SupportProductID.lifetime]?.price == "19.99")
        #expect(found[SupportProductID.lifetime]?.type == "NonConsumable")
        #expect(found[SupportTip.coffee.productID]?.price == "1.99")
        #expect(found[SupportTip.cake.productID]?.price == "4.99")
        #expect(found[SupportTip.movie.productID]?.price == "9.99")
        #expect(found.filter { SupportTip.ordered.map(\.productID).contains($0.key) }.allSatisfy { $0.value.type == "Consumable" })
    }

    @Test func storeKitAcceptsTheFile() throws {
        _ = try SKTestSession(contentsOf: url)
    }
}
