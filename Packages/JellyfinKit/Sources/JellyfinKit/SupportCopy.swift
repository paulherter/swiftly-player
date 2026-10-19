import Foundation

/// **The texts of "Support Swiftly", in German and English.**
///
/// The German sentence is the lookup key, as everywhere in the apps: each platform copies
/// these pairs into its own catalog (`Localizable.xcstrings`, the `.lproj` files on Linux and
/// Windows, the Android texts) and looks them up there. Keeping them here gives every platform
/// the same wording and lets a test check the pairs.
///
/// Placeholders use catalog syntax: `%lld` for a whole number, `%@` for text.
///
/// Texts that only direct builds may contain (the website, the supporter key) live in the
/// `SupportKeyKit` module, so store builds do not carry them.
public struct SupportCopy: Sendable, Hashable {
    /// German wording, also the catalog key.
    public let de: String
    public let en: String

    public init(de: String, en: String) {
        self.de = de
        self.en = en
    }

    public var key: String { de }

    /// The text for a language code such as "de", "de-AT" or "en-US"; English otherwise.
    public func text(forLanguage code: String) -> String {
        code.lowercased().hasPrefix("de") ? de : en
    }

    // MARK: Entry (Settings, About)

    public static let supportSwiftly = SupportCopy(de: "Swiftly unterstützen", en: "Support Swiftly")
    public static let sayThanks = SupportCopy(de: "Mit einem Kaffee Danke sagen",
                                              en: "Say thanks with a coffee")
    /// Apple TV settings row, where there is room for one more sentence.
    public static let sayThanksFreeForAll = SupportCopy(
        de: "Mit einem Kaffee Danke sagen. Alles bleibt für alle kostenlos.",
        en: "Say thanks with a coffee. Everything stays free for everyone.")

    // MARK: Sheet

    public static let sheetIntro = SupportCopy(
        de: "Wir bauen Swiftly ohne Werbung und ohne Tracking. Wenn es deine Abende besser macht, hilft uns ein Kaffee, weiterzumachen.",
        en: "We build Swiftly without ads or tracking. If it makes your evenings better, a coffee helps us keep going.")
    public static let freeForEveryone = SupportCopy(de: "Alles bleibt für alle kostenlos.",
                                                    en: "Everything stays free for everyone.")
    public static let storeThankYouGifts = SupportCopy(
        de: "Als Dankeschön bekommst du ein Herz in „Über“ und zusätzliche App-Icons.",
        en: "As a thank-you, you get a heart in About and extra app icons.")
    /// `%@` is the store's localized price, for example "4,99 €".
    public static let supportWithPrice = SupportCopy(de: "Mit %@ unterstützen", en: "Support with %@")
    public static let oneTimePurchase = SupportCopy(
        de: "Einmaliger Kauf über deinen App-Store. Nichts verlängert sich.",
        en: "One-time purchase through your app store. Nothing renews.")
    public static let oneTimePurchaseAppStore = SupportCopy(
        de: "Einmaliger Kauf über den App Store. Nichts verlängert sich.",
        en: "One-time purchase through the App Store. Nothing renews.")
    public static let maybeLater = SupportCopy(de: "Vielleicht später", en: "Maybe later")
    public static let restorePurchases = SupportCopy(de: "Käufe wiederherstellen", en: "Restore Purchases")

    // MARK: Tips (prices come from the store)

    public static let tipCoffee = SupportCopy(de: "Ein Kaffee", en: "A coffee")
    public static let tipCake = SupportCopy(de: "Kaffee und Kuchen", en: "Coffee and cake")
    public static let tipMovie = SupportCopy(de: "Filmabend", en: "Movie night")

    // MARK: Thank-you page

    public static let thanksTitle = SupportCopy(de: "Danke. Du bist dabei.", en: "Thank you. You are in.")
    public static let thanksBody = SupportCopy(
        de: "Dein Kaffee hilft uns, Swiftly für alle kostenlos zu halten. Das ist neu für dich.",
        en: "Your coffee helps us keep Swiftly free for everyone. Here is what is new for you.")
    public static let giftIconsTitle = SupportCopy(de: "Unterstützer-App-Icons", en: "Supporter app icons")
    public static let giftIconsDetail = SupportCopy(de: "Neue Icons für die App", en: "New icons for the app")
    public static let giftHeartTitle = SupportCopy(de: "Ein Herz in „Über“", en: "A heart in About")
    public static let giftHeartDetail = SupportCopy(de: "Neben deiner Versionsnummer",
                                                    en: "Next to your version number")
    public static let chooseAppIcon = SupportCopy(de: "App-Icon wählen", en: "Choose an app icon")
    /// Already in the app catalog.
    public static let done = SupportCopy(de: "Fertig", en: "Done")

    // MARK: Card on the home page

    /// `%lld` is `WatchTimeCounter.watchedHours`; the card only appears from 2 hours on.
    public static let cardWatchedHours = SupportCopy(de: "Du hast mit Swiftly %lld Stunden geschaut.",
                                                     en: "You have watched %lld hours with Swiftly.")
    public static let cardAsk = SupportCopy(de: "Wenn es dir einen Kaffee wert ist, freuen wir uns sehr.",
                                            en: "If it earns a coffee, we would love that.")
    public static let cardSupport = SupportCopy(de: "Unterstützen", en: "Support")
    public static let notNow = SupportCopy(de: "Nicht jetzt", en: "Not now")
    public static let dontShowAgain = SupportCopy(de: "Nicht mehr zeigen", en: "Don’t show again")

    // MARK: Supporter state

    public static let supporterBadge = SupportCopy(de: "Unterstützer", en: "Supporter")
    public static let thankYou = SupportCopy(de: "Danke", en: "Thank you")
    public static let appIcon = SupportCopy(de: "App-Icon", en: "App icon")
    public static let supporterIcons = SupportCopy(de: "Unterstützer-Icons", en: "Supporter icons")

    /// Every text above, for catalog checks. Keys are unique (a test checks it).
    public static let all: [SupportCopy] = [
        supportSwiftly, sayThanks, sayThanksFreeForAll,
        sheetIntro, freeForEveryone, storeThankYouGifts, supportWithPrice,
        oneTimePurchase, oneTimePurchaseAppStore, maybeLater, restorePurchases,
        tipCoffee, tipCake, tipMovie,
        thanksTitle, thanksBody, giftIconsTitle, giftIconsDetail,
        giftHeartTitle, giftHeartDetail, chooseAppIcon, done,
        cardWatchedHours, cardAsk, cardSupport, notNow, dontShowAgain,
        supporterBadge, thankYou, appIcon, supporterIcons,
    ]
}

/// **The three tips, in display order.** Product IDs are the same in App Store Connect and
/// the Play Console; prices come from the store, never from here.
public enum SupportTip: String, CaseIterable, Sendable, Codable {
    case coffee = "de.paulherter.swiftly.tip.coffee"
    case cake = "de.paulherter.swiftly.tip.cake"
    case movie = "de.paulherter.swiftly.tip.movie"

    public var productID: String { rawValue }

    /// Smallest first, as in the sheet.
    public static let ordered: [SupportTip] = [.coffee, .cake, .movie]

    public var title: SupportCopy {
        switch self {
        case .coffee: .tipCoffee
        case .cake: .tipCake
        case .movie: .tipMovie
        }
    }

    /// The symbol in front of the title.
    public var emoji: String {
        switch self {
        case .coffee: "☕"
        case .cake: "🍰"
        case .movie: "🎬"
        }
    }

    public init?(productID: String) {
        self.init(rawValue: productID)
    }
}
