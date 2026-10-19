import Foundation
import JellyfinKit
import Observation
import StoreKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// **"Support Swiftly" in the store builds: state, watch time and the asks.**
//
// The rules (when the card and the sheet may appear, how watch time is counted)
// live in the package (`SupportPrompt`, `WatchTimeCounter`), so every platform asks
// the same way. This file only connects them to the app: the stored records, the
// player's progress, the App Store. Each platform draws its own views on top.
//
// Included in all three Apple targets.

/// `SupportStore` over `UserDefaults.standard`. The keys come from the package
/// (`SupportStorageKey`) and must never change: a renamed key loses what devices
/// have stored.
struct UserDefaultsSupportStorage: SupportStorage {
    func data(forKey key: String) -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    func setData(_ data: Data?, forKey key: String) {
        if let data {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// What the support sheet tells the person after a purchase attempt. Never an
/// error code: what happened and what they can do.
enum SupportNotice: Equatable, Sendable {
    /// Ask to Buy or a payment that needs another step.
    case pending
    /// Closed the App Store dialog. Nothing happened, which is fine.
    case cancelled
    /// The purchase itself failed.
    case failed
    /// No connection to the App Store, or the products are not there.
    case unavailable
    /// "Restore Purchases" found nothing.
    case nothingToRestore

    var text: String {
        switch self {
        case .pending:
            String(localized: "Der Kauf wartet noch auf eine Freigabe. Sobald sie da ist, bist du dabei.")
        case .cancelled:
            String(localized: "Kein Problem, es wurde nichts gekauft.")
        case .failed:
            String(localized: "Der Kauf ist nicht durchgegangen. Versuch es gleich noch mal.")
        case .unavailable:
            String(localized: "Der App Store ist gerade nicht erreichbar. Versuch es später noch mal.")
        case .nothingToRestore:
            String(localized: "Auf diesem Apple Account haben wir keinen Kauf gefunden.")
        }
    }
}

extension SupportCopy {
    /// The text in the app's language, from the app catalog. The German sentence is
    /// the key, as for every other label.
    var localized: String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }
}

/// **StoreKit 2 for the three tips.** No state of its own: it answers what the
/// App Store knows, and `SupportModel` keeps the result.
///
/// The tips are consumables. With `SKIncludeConsumableInAppPurchaseHistory` in
/// the Info.plist, `Transaction.all` also returns finished consumables, so the
/// supporter status comes back on a new device or after a reinstall without any
/// server of our own.
enum SupportStoreKit {
    /// What the history says about this Apple Account.
    enum History: Equatable {
        /// At least one verified tip that was not refunded; the earliest date.
        case supporter(since: Date)
        /// Only refunded tips.
        case revoked
        /// No tip at all, or the history is not available.
        case nothing
    }

    static func products() async throws -> [SupportTip: Product] {
        let found = try await Product.products(for: SupportTip.ordered.map(\.productID))
        var result: [SupportTip: Product] = [:]
        for product in found {
            if let tip = SupportTip(productID: product.id) { result[tip] = product }
        }
        return result
    }

    static func history() async -> History {
        var earliest: Date?
        var revoked = false
        for await entry in Transaction.all {
            guard case let .verified(transaction) = entry,
                  SupportTip(productID: transaction.productID) != nil else { continue }
            if transaction.revocationDate != nil {
                revoked = true
            } else {
                earliest = min(earliest ?? transaction.purchaseDate, transaction.purchaseDate)
            }
        }
        if let earliest { return .supporter(since: earliest) }
        return revoked ? .revoked : .nothing
    }

    /// Only tips are ours to finish; anything else is left alone.
    static func isTip(_ transaction: Transaction) -> Bool {
        SupportTip(productID: transaction.productID) != nil
    }
}

/// **One holder for the whole app**, like `AppModel.only`.
@MainActor
@Observable
final class SupportModel {
    static let shared = SupportModel()

    enum ProductsState: Equatable {
        case idle, loading, ready, unavailable
    }

    private(set) var status: SupportStatus
    private(set) var products: [SupportTip: Product] = [:]
    private(set) var productsState: ProductsState = .idle
    /// The tip whose purchase is running; the sheet shows progress on it.
    private(set) var purchasing: SupportTip?
    private(set) var restoring = false
    var notice: SupportNotice?
    /// After a purchase (or a late approval) the sheet shows the thank-you page.
    var showsThanks = false
    /// The support sheet (iPhone, iPad, Mac) or page (Apple TV) is open. Every
    /// entry point sets this one flag; the root view presents it.
    var presented = false
    /// The card at the end of the home page.
    private(set) var cardVisible = false
    /// The chosen supporter icon; `nil` is the regular one.
    private(set) var appIcon: SupporterIcon?

    @ObservationIgnored private let store = SupportStore(storage: UserDefaultsSupportStorage())
    @ObservationIgnored private var counter: WatchTimeCounter
    @ObservationIgnored private let launchedAt = Date.now
    @ObservationIgnored private var started = false
    @ObservationIgnored private var updates: Task<Void, Never>?
    /// A purchase completed while no support page was open (Ask to Buy approved
    /// later, bought on another device): the next visit starts with the thank-you.
    @ObservationIgnored private var thanksPending = false
    /// The sheet was opened by the rules, not by a tap; counted once it appears.
    @ObservationIgnored private var scheduledAsk = false

    private init() {
        status = store.status
        counter = WatchTimeCounter(totalSeconds: store.usage.watchedSeconds)
        appIcon = SupporterIcon.current
    }

    static var platform: SupportPlatform {
        #if os(tvOS)
        .appleTV
        #elseif os(macOS)
        .mac
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #endif
    }

    var isSupporter: Bool { status.isSupporter }
    var watchedHours: Int { counter.watchedHours }

    // MARK: Start

    /// Once per app start: first launch, the App Store listener, the status from
    /// the purchase history.
    func start() {
        guard !started else { return }
        started = true
        store.recordLaunch(now: .now)
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task {
            for await entry in Transaction.unfinished {
                await handle(entry)
            }
            await refreshStatus()
            SupporterIcon.restoreOnLaunch(isSupporter: isSupporter)
        }
        observeLifecycle()
    }

    /// Reads the purchase history. A device that has nothing in it keeps its
    /// stored status: the record is the cache, the history the proof.
    func refreshStatus() async {
        switch await SupportStoreKit.history() {
        case let .supporter(since):
            if !status.isSupporter { setStatus(.supporter(source: .store, since: since)) }
        case .revoked:
            if case .supporter(.store, _) = status { setStatus(.none) }
        case .nothing:
            break
        }
    }

    private func setStatus(_ new: SupportStatus) {
        status = new
        store.status = new
        if new.isSupporter { cardVisible = false }
        AppLog.writeOut("[Support] Status: \(new.isSupporter ? "Unterstuetzer" : "keiner")")
    }

    /// A transaction from outside a purchase in this sheet: Ask to Buy approved,
    /// bought on another device, a refund.
    private func handle(_ update: VerificationResult<Transaction>) async {
        guard case let .verified(transaction) = update else {
            // Never counted, but finished, so it does not come back on every launch.
            if case let .unverified(transaction, error) = update, SupportStoreKit.isTip(transaction) {
                AppLog.writeOut("[Support] Unbestaetigte Transaktion: \(error)")
                await transaction.finish()
            }
            return
        }
        guard SupportStoreKit.isTip(transaction) else { return }
        if transaction.revocationDate == nil {
            let wasSupporter = isSupporter
            setStatus(.supporter(source: .store, since: transaction.purchaseDate))
            if !wasSupporter {
                notice = nil
                showsThanks = true
                thanksPending = true
            }
        } else {
            await refreshStatus()
        }
        await transaction.finish()
    }

    // MARK: Products and purchases

    func loadProducts() async {
        guard productsState != .loading, productsState != .ready else { return }
        productsState = .loading
        do {
            let found = try await SupportStoreKit.products()
            products = found
            productsState = found.isEmpty ? .unavailable : .ready
        } catch {
            AppLog.writeOut("[Support] Produkte nicht geladen: \(error)")
            productsState = .unavailable
        }
    }

    /// Buys one tip. `purchase` is SwiftUI's `PurchaseAction`, which brings the
    /// window or scene the App Store dialog belongs to.
    func buy(_ tip: SupportTip,
             with purchase: (Product) async throws -> Product.PurchaseResult) async {
        guard purchasing == nil, let product = products[tip] else {
            if products[tip] == nil { notice = .unavailable }
            return
        }
        purchasing = tip
        notice = nil
        defer { purchasing = nil }
        do {
            switch try await purchase(product) {
            case let .success(.verified(transaction)):
                setStatus(.supporter(source: .store, since: transaction.purchaseDate))
                await transaction.finish()
                showsThanks = true
                // Closed while the App Store dialog ran: the thank-you waits for the next visit.
                if !presented { thanksPending = true }
            case let .success(.unverified(transaction, error)):
                AppLog.writeOut("[Support] Unbestaetigter Kauf: \(error)")
                await transaction.finish()
                notice = .failed
            case .pending:
                notice = .pending
            case .userCancelled:
                notice = .cancelled
            @unknown default:
                notice = .failed
            }
        } catch StoreKitError.userCancelled {
            notice = .cancelled
        } catch StoreKitError.networkError, StoreKitError.notAvailableInStorefront {
            notice = .unavailable
        } catch {
            AppLog.writeOut("[Support] Kauf fehlgeschlagen: \(error)")
            notice = .failed
        }
    }

    /// "Restore Purchases". Shows an Apple sign-in, hence only on a tap.
    func restore() async {
        guard !restoring else { return }
        restoring = true
        notice = nil
        defer { restoring = false }
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            AppLog.writeOut("[Support] Wiederherstellen fehlgeschlagen: \(error)")
            notice = .unavailable
            return
        }
        let wasSupporter = isSupporter
        await refreshStatus()
        if isSupporter {
            if !wasSupporter { showsThanks = true }
        } else {
            notice = .nothingToRestore
        }
    }

    /// Opens the sheet from any entry point: header heart, settings row, card.
    ///
    /// **If the flag is already set, it is set again.** A sheet SwiftUI could not show
    /// (something else was presented at that moment) leaves the flag true without a
    /// sheet; setting it once more would change nothing, and every entry would be dead.
    func open() {
        prepare()
        if presented {
            presented = false
            Task { presented = true }
        } else {
            presented = true
        }
    }

    /// The sheet is on screen. Only now does an occasional ask count as shown.
    func sheetAppeared() {
        guard scheduledAsk else { return }
        scheduledAsk = false
        var history = store.promptHistory
        history.recordSheetShown(at: .now)
        store.promptHistory = history
        AppLog.writeOut("[Support] Blatt gezeigt")
    }

    /// A fresh visit: no old notice; a thank-you that arrived meanwhile comes first.
    /// For pages that present themselves (the Apple TV settings entry).
    func prepare() {
        notice = nil
        showsThanks = thanksPending
        thanksPending = false
    }

    /// Closing the sheet keeps nothing half-done for the next time.
    func closed() {
        notice = nil
        showsThanks = false
        thanksPending = false
        scheduledAsk = false
    }

    // MARK: Watch time

    /// From `AppModel.reportProgress`, every few seconds while a title is open.
    func playbackProgress(isPlaying: Bool) {
        counter.playbackProgress(isPlaying: isPlaying, at: .now)
        if counter.needsSave { store.save(&counter) }
    }

    /// The title ended or the player closed.
    func playbackStopped() {
        counter.playbackStopped(at: .now)
        store.save(&counter)
    }

    /// The app goes to the background: whatever was counted is stored now, a
    /// frozen app may never come back to do it.
    private func observeLifecycle() {
        #if os(macOS)
        let name = NSApplication.willTerminateNotification
        #else
        let name = UIApplication.didEnterBackgroundNotification
        #endif
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SupportModel.shared.playbackStopped() }
        }
    }

    // MARK: The asks

    /// **Decides whether the card shows and whether the sheet comes, by the rules in
    /// the package.** Called a minute after launch, when the player closes and when the
    /// app comes back to the front; never during playback (`isPlaying` is the open player,
    /// paused or not).
    ///
    /// `sheetAllowed` is false when another question is due at the same moment
    /// (rating, the Discord hint): one ask at a time, and never a tip next to a
    /// rating.
    func evaluate(isPlaying: Bool, sheetAllowed: Bool) {
        let decision = SupportPrompt.decide(.init(
            now: .now, status: status, usage: store.usage, history: store.promptHistory,
            isPlaying: isPlaying, secondsSinceLaunch: Date.now.timeIntervalSince(launchedAt),
            platform: Self.platform))
        if decision.showsSheet, sheetAllowed, !presented {
            scheduledAsk = true
            open()
        } else if decision.showsCard {
            cardVisible = true
        }
    }

    /// "Not now" on the card: back in 30 days.
    func snoozeCard() {
        var history = store.promptHistory
        history.snoozeCard(now: .now)
        store.promptHistory = history
        cardVisible = false
    }

    /// "Don't show again" on the card.
    func dismissCard() {
        var history = store.promptHistory
        history.dismissCard()
        store.promptHistory = history
        cardVisible = false
    }

    // MARK: App icon

    /// Switches the icon. Only for supporters; the picker shows the others a preview.
    /// The way back to the original stays open to everyone: after a refund the
    /// supporter icon must not be stuck.
    func choose(_ icon: SupporterIcon?) async {
        guard canChoose(icon) else { return }
        if await SupporterIcon.apply(icon) { appIcon = icon }
    }

    func canChoose(_ icon: SupporterIcon?) -> Bool {
        isSupporter || (icon == nil && appIcon != nil)
    }

    /// The icon the app shows now; for everyone else nothing is marked.
    func isChosen(_ icon: SupporterIcon?) -> Bool {
        appIcon == icon && (isSupporter || appIcon != nil)
    }
}

#if DEBUG
// MARK: - Preview (debug builds only)

extension SupportModel {
    /// Shows the card at the end of the home page without the days of use.
    func debugShowCard() {
        if isSupporter { setStatus(.none) }
        cardVisible = true
    }

    /// Opens the sheet straight on the thank-you page.
    func debugShowThanks() {
        thanksPending = true
        open()
    }

    /// Supporter status without a purchase (key source, so the store history leaves it alone).
    func debugMarkSupporter() {
        setStatus(.supporter(source: .key, since: .now))
    }

    /// Back to the state of a fresh install: no status, no ask history, regular icon.
    func debugReset() {
        setStatus(.none)
        store.promptHistory = SupportPromptHistory()
        cardVisible = false
        notice = nil
        showsThanks = false
        thanksPending = false
        if appIcon != nil { Task { if await SupporterIcon.apply(nil) { appIcon = nil } } }
    }
}
#endif

// MARK: - Supporter icons

/// **The six supporter icons.** Each is the regular play mark in other colors, so
/// the app stays recognizable (guideline 2.3.8). Switched only by the person,
/// always back to the original with "Standard".
///
/// The raw value is the name in the asset catalog (iPhone, iPad, Apple TV) and of
/// the `.icns` in the Mac bundle. It is a string the build looks up; renaming a
/// case breaks the icon.
enum SupporterIcon: String, CaseIterable, Identifiable, Sendable {
    case heart = "AppIcon-Heart"
    case aurora = "AppIcon-Aurora"
    case gold = "AppIcon-Gold"
    case light = "AppIcon-Light"
    case night = "AppIcon-Night"
    case coffee = "AppIcon-Coffee"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .heart: String(localized: "Herz")
        case .aurora: String(localized: "Aurora")
        case .gold: String(localized: "Gold")
        case .light: String(localized: "Hell")
        case .night: String(localized: "Nacht")
        case .coffee: String(localized: "Kaffee")
        }
    }

    /// Small image for the picker. An alternate icon cannot be loaded as an image,
    /// hence a copy in the catalog (iPhone, iPad, Apple TV).
    var previewAsset: String {
        "AppIconPreview-" + rawValue.replacingOccurrences(of: "AppIcon-", with: "")
    }

    static let standardPreviewAsset = "AppIconPreview-Standard"

    /// Remembered on the Mac only: iOS and tvOS keep the choice themselves.
    private static let macChoiceKey = "support.appIcon"

    @MainActor static var current: SupporterIcon? {
        #if os(macOS)
        UserDefaults.standard.string(forKey: macChoiceKey).flatMap(SupporterIcon.init(rawValue:))
        #else
        UIApplication.shared.alternateIconName.flatMap(SupporterIcon.init(rawValue:))
        #endif
    }

    /// `true` when the system took it.
    @MainActor static func apply(_ icon: SupporterIcon?) async -> Bool {
        #if os(macOS)
        guard setDockIcon(icon) else { return false }
        UserDefaults.standard.set(icon?.rawValue, forKey: macChoiceKey)
        return true
        #else
        guard UIApplication.shared.supportsAlternateIcons else { return false }
        do {
            try await UIApplication.shared.setAlternateIconName(icon?.rawValue)
            return true
        } catch {
            AppLog.writeOut("[Support] Icon nicht gewechselt: \(error)")
            return false
        }
        #endif
    }

    /// The Mac has no alternate icons, only the Dock icon of the running app. It is
    /// set again on every launch.
    @MainActor static func restoreOnLaunch(isSupporter: Bool) {
        #if os(macOS)
        guard isSupporter, let icon = current else { return }
        _ = setDockIcon(icon)
        #endif
    }

    #if os(macOS)
    /// The `.icns` lies in the bundle under the asset name.
    @MainActor static func image(_ icon: SupporterIcon?) -> NSImage? {
        guard let icon else { return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) }
        guard let url = Bundle.main.url(forResource: icon.rawValue, withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    @MainActor private static func setDockIcon(_ icon: SupporterIcon?) -> Bool {
        guard let icon else {
            // `nil` puts the bundle's own icon back.
            NSApp.applicationIconImage = nil
            return true
        }
        guard let image = image(icon) else { return false }
        NSApp.applicationIconImage = image
        return true
    }
    #endif
}
