import Foundation

/// **The Apple product IDs of the supporter plans.** The same IDs in App Store Connect and in
/// the local StoreKit file. The Android IDs (`supporter`, `supporter_lifetime`) are the Play
/// Console's and live in the Android app.
public enum SupportProductID {
    /// Auto-renewable subscription, group "Swiftly Supporter", one month.
    public static let monthly = "de.paulherter.swiftly.supporter.monthly"
    /// Non-consumable, bought once.
    public static let lifetime = "de.paulherter.swiftly.supporter.lifetime"

    /// Plans and tips, in the order the sheet shows them.
    public static let all: [String] = [monthly, lifetime] + SupportTip.ordered.map(\.productID)

    /// Which plan a product ID stands for; `nil` for anything that is not ours.
    public static func plan(for productID: String) -> SupportPlan? {
        switch productID {
        case monthly: .monthly
        case lifetime: .lifetime
        default: SupportTip(productID: productID) == nil ? nil : .tip
        }
    }
}

/// One line of the App Store's purchase history, reduced to what the standing needs.
public struct SupportPurchaseRecord: Sendable, Equatable {
    public let productID: String
    public let purchaseDate: Date
    /// The first purchase of a subscription; the same as `purchaseDate` otherwise.
    public let originalPurchaseDate: Date
    /// Subscriptions only: the end of the paid period.
    public let expirationDate: Date?
    /// Refunded or revoked by Apple.
    public let isRevoked: Bool
    /// Listed among the current entitlements by the App Store. This also covers a billing
    /// grace period, in which the paid period is over but access stays.
    public let isCurrentEntitlement: Bool

    public init(productID: String, purchaseDate: Date, originalPurchaseDate: Date? = nil,
                expirationDate: Date? = nil, isRevoked: Bool = false, isCurrentEntitlement: Bool = false) {
        self.productID = productID
        self.purchaseDate = purchaseDate
        self.originalPurchaseDate = originalPurchaseDate ?? purchaseDate
        self.expirationDate = expirationDate
        self.isRevoked = isRevoked
        self.isCurrentEntitlement = isCurrentEntitlement
    }
}

/// **What the purchase history says about this Apple Account right now.**
public enum SupportStanding: Sendable, Equatable {
    /// Supports. `renews` is the end of the paid period for the monthly plan, `nil` otherwise.
    case active(plan: SupportPlan, since: Date, renews: Date?)
    /// Supported once, but it is over: the subscription ran out, or everything was refunded.
    case ended
    /// The history has nothing of ours (new device, no connection yet, never bought).
    /// The caller keeps what it has stored.
    case unknown
}

/// Turns the history into a standing. Pure, so it can be tested without the App Store.
public enum SupportStandingResolver {
    /// - Parameter tipsUnlock: whether a tip alone makes someone a supporter (it does not: a tip
    ///   is a thank-you and unlocks nothing).
    public static func resolve(_ records: [SupportPurchaseRecord], now: Date,
                               tipsUnlock: Bool = false) -> SupportStanding {
        func earliest(_ id: String, live: (SupportPurchaseRecord) -> Bool) -> [SupportPurchaseRecord] {
            records.filter { $0.productID == id && !$0.isRevoked && live($0) }
        }
        let lifetime = earliest(SupportProductID.lifetime) { _ in true }
        if let since = lifetime.map(\.purchaseDate).min() {
            return .active(plan: .lifetime, since: since, renews: nil)
        }
        let monthly = earliest(SupportProductID.monthly) {
            $0.isCurrentEntitlement || ($0.expirationDate.map { $0 > now } ?? false)
        }
        if let since = monthly.map(\.originalPurchaseDate).min() {
            let end = monthly.compactMap(\.expirationDate).max()
            return .active(plan: .monthly, since: since, renews: end)
        }
        if tipsUnlock {
            let tips = records.filter { !$0.isRevoked && SupportProductID.plan(for: $0.productID) == .tip }
            if let since = tips.map(\.purchaseDate).min() {
                return .active(plan: .tip, since: since, renews: nil)
            }
        }
        return records.contains { SupportProductID.plan(for: $0.productID) != nil } ? .ended : .unknown
    }
}
