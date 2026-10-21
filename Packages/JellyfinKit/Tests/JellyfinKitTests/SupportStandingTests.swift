import Foundation
import Testing
@testable import JellyfinKit

@Suite("Support standing from the purchase history")
struct SupportStandingTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400

    func record(_ id: String, daysAgo: Double, expiresInDays: Double? = nil, revoked: Bool = false,
                entitled: Bool = false) -> SupportPurchaseRecord {
        SupportPurchaseRecord(productID: id, purchaseDate: Self.now - daysAgo * Self.day,
                              expirationDate: expiresInDays.map { Self.now + $0 * Self.day },
                              isRevoked: revoked, isCurrentEntitlement: entitled)
    }

    @Test("Nothing in the history is unknown, not ended")
    func empty() {
        #expect(SupportStandingResolver.resolve([], now: Self.now) == .unknown)
        #expect(SupportStandingResolver.resolve([record("other", daysAgo: 1)], now: Self.now) == .unknown)
    }

    @Test("Lifetime wins over a running subscription")
    func lifetimeFirst() {
        let history = [record(SupportProductID.monthly, daysAgo: 10, expiresInDays: 20, entitled: true),
                       record(SupportProductID.lifetime, daysAgo: 2)]
        #expect(SupportStandingResolver.resolve(history, now: Self.now)
            == .active(plan: .lifetime, since: Self.now - 2 * Self.day, renews: nil))
    }

    @Test("A refunded lifetime does not count")
    func refundedLifetime() {
        let history = [record(SupportProductID.lifetime, daysAgo: 2, revoked: true)]
        #expect(SupportStandingResolver.resolve(history, now: Self.now) == .ended)
    }

    @Test("A subscription counts until its period ends, and in the grace period")
    func monthly() {
        let running = [record(SupportProductID.monthly, daysAgo: 5, expiresInDays: 25)]
        #expect(SupportStandingResolver.resolve(running, now: Self.now)
            == .active(plan: .monthly, since: Self.now - 5 * Self.day, renews: Self.now + 25 * Self.day))
        let expired = [record(SupportProductID.monthly, daysAgo: 40, expiresInDays: -10)]
        #expect(SupportStandingResolver.resolve(expired, now: Self.now) == .ended)
        let grace = [record(SupportProductID.monthly, daysAgo: 40, expiresInDays: -1, entitled: true)]
        if case .active(.monthly, _, _) = SupportStandingResolver.resolve(grace, now: Self.now) {} else {
            Issue.record("grace period must keep the access")
        }
    }

    @Test("Several renewals start at the first purchase and end at the last period")
    func renewals() {
        let first = SupportPurchaseRecord(productID: SupportProductID.monthly,
                                          purchaseDate: Self.now - 60 * Self.day,
                                          expirationDate: Self.now - 30 * Self.day)
        let second = SupportPurchaseRecord(productID: SupportProductID.monthly,
                                           purchaseDate: Self.now - 30 * Self.day,
                                           originalPurchaseDate: Self.now - 60 * Self.day,
                                           expirationDate: Self.now + 5 * Self.day, isCurrentEntitlement: true)
        #expect(SupportStandingResolver.resolve([first, second], now: Self.now)
            == .active(plan: .monthly, since: Self.now - 60 * Self.day, renews: Self.now + 5 * Self.day))
    }

    @Test("A tip unlocks nothing unless the switch is on")
    func tips() {
        let tip = SupportTip.coffee.productID
        #expect(SupportStandingResolver.resolve([record(tip, daysAgo: 3)], now: Self.now) == .ended)
        #expect(SupportStandingResolver.resolve([record(tip, daysAgo: 3)], now: Self.now, tipsUnlock: true)
            == .active(plan: .tip, since: Self.now - 3 * Self.day, renews: nil))
        #expect(SupportStandingResolver.resolve([record(tip, daysAgo: 3, revoked: true)], now: Self.now, tipsUnlock: true) == .ended)
        #expect(SupportStandingResolver.resolve([record(tip, daysAgo: 3)], now: Self.now, tipsUnlock: false) == .ended)
    }

    @Test("Product IDs map to plans")
    func plans() {
        #expect(SupportProductID.plan(for: SupportProductID.monthly) == .monthly)
        #expect(SupportProductID.plan(for: SupportProductID.lifetime) == .lifetime)
        #expect(SupportProductID.plan(for: SupportTip.movie.productID) == .tip)
        #expect(SupportProductID.plan(for: "x") == nil)
        #expect(SupportProductID.all.count == 5)
    }
}
