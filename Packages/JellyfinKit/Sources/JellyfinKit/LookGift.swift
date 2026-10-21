import Foundation

/// **When the gift pop-up for a seasonal look may appear.** One check, tested, the same on
/// every platform.
///
/// Once per season and look, inside the window, after sign-in, never during playback, never
/// to someone who has the look already, never while something else asked this session
/// (the pop-up is a big ask: one per session), and not in the first seconds after the home
/// page came up.
public enum LookGift {
    /// How long the home page stands before the pop-up comes, so it never lands on top of
    /// the first look at the rows.
    public static let quietAfterHome: TimeInterval = 3

    public struct Context: Sendable, Equatable {
        public var now: Date
        /// Signed in and the home page loaded.
        public var homeReady: Bool
        /// Player, mini player or Picture in Picture.
        public var playing: Bool
        /// Another big ask already showed this session (support sheet, rating, What's New).
        public var askedThisSession: Bool
        /// How long the home page has been standing.
        public var secondsOnHome: TimeInterval
        public var owned: Set<String>
        public var offered: Set<String>

        public init(now: Date, homeReady: Bool, playing: Bool, askedThisSession: Bool,
                    secondsOnHome: TimeInterval, owned: Set<String>, offered: Set<String>) {
            self.now = now
            self.homeReady = homeReady
            self.playing = playing
            self.askedThisSession = askedThisSession
            self.secondsOnHome = secondsOnHome
            self.owned = owned
            self.offered = offered
        }
    }

    /// The stored id of one offer: `halloween-2026`.
    public static func offerID(_ look: Look, at date: Date, calendar: Calendar = .current) -> String? {
        guard let season = look.availability, let year = season.seasonYear(at: date, calendar: calendar) else {
            return nil
        }
        return "\(season.id)-\(year)"
    }

    /// The gift whose pop-up is due now, if any.
    public static func due(_ context: Context, looks: [Look] = Look.all,
                           calendar: Calendar = .current) -> Look? {
        guard context.homeReady, !context.playing, !context.askedThisSession,
              context.secondsOnHome >= quietAfterHome else { return nil }
        return looks.first { look in
            guard look.isGift, !context.owned.contains(look.id),
                  let id = offerID(look, at: context.now, calendar: calendar) else { return false }
            return !context.offered.contains(id)
        }
    }

    /// Whether a gift can be picked up now (in its window), or is picked up already.
    public static func isAvailable(_ look: Look, owned: Set<String>, now: Date,
                                   calendar: Calendar = .current) -> Bool {
        guard look.isGift else { return true }
        if owned.contains(look.id) { return true }
        return look.availability?.isActive(at: now, calendar: calendar) ?? true
    }
}

/// **Where the small seasonal extras may show.** Bats move, details stand; both only in
/// the look's window, only with the switch on, never during playback.
public enum LookEffects {
    public enum Page: Sendable {
        /// The rare bat.
        case home
        /// The web in the corner of the look card.
        case profile
        /// No effect at all: only the accent. A detail on a page without an element to hang
        /// it on looks like a mistake.
        case detail
        case other
    }

    public struct Context: Sendable, Equatable {
        public var look: Look
        public var now: Date
        public var switchOn: Bool
        public var playing: Bool
        public var reduceMotion: Bool
        public var lowPower: Bool
        public var foreground: Bool

        public init(look: Look, now: Date, switchOn: Bool, playing: Bool, reduceMotion: Bool,
                    lowPower: Bool, foreground: Bool) {
            self.look = look
            self.now = now
            self.switchOn = switchOn
            self.playing = playing
            self.reduceMotion = reduceMotion
            self.lowPower = lowPower
            self.foreground = foreground
        }
    }

    /// The standing details: the web in the corner of the look card.
    public static func details(on page: Page, _ context: Context, calendar: Calendar = .current) -> Bool {
        guard page == .home || page == .profile, context.switchOn, !context.playing,
              let season = context.look.availability else { return false }
        return season.isActive(at: context.now, calendar: calendar)
    }

    /// **Why no bat flies right now**, or `nil` when one may. The log names it, so a bat that
    /// never shows can be traced to its reason instead of guessed at.
    public enum BatBlock: String, Sendable, Equatable {
        case wrongPage, switchOff, playing, outsideWindow, reduceMotion, lowPower, background
    }

    public static func batBlock(on page: Page, _ context: Context, calendar: Calendar = .current) -> BatBlock? {
        guard page == .home else { return .wrongPage }
        guard context.switchOn else { return .switchOff }
        guard !context.playing else { return .playing }
        guard let season = context.look.availability, season.isActive(at: context.now, calendar: calendar) else {
            return .outsideWindow
        }
        if context.reduceMotion { return .reduceMotion }
        if context.lowPower { return .lowPower }
        if !context.foreground { return .background }
        return nil
    }

    /// The bat: only on the home page (and in the looks panel's preview of it), and only when
    /// nothing argues against movement.
    public static func bats(on page: Page, _ context: Context, calendar: Calendar = .current) -> Bool {
        batBlock(on: page, context, calendar: calendar) == nil
    }

    /// **The rhythm:** the first bat about 6 s after the page stands, then one every 45 to
    /// 90 s; a flight takes 2.5 to 3.5 s.
    public static let firstBat: TimeInterval = 6
    public static let pause: ClosedRange<Double> = 45...90
    public static let flight: ClosedRange<Double> = 2.5...3.5

    /// The wait before the next bat.
    public static func wait(first: Bool) -> TimeInterval {
        first ? firstBat : Double.random(in: pause)
    }
}

/// **What the profile shows at the top about looks**, for each state.
///
/// | | owns a look of their own | no look of their own |
/// |---|---|---|
/// | **supporter** | "Your look" line | "Your look" line |
/// | **not a supporter, supporter build** | "Your look" line | teaser card |
/// | **not a supporter, this version** | "Your look" line | nothing (a plain "Looks" row under Appearance, while a gift can be picked up) |
public enum LookProfileEntry: Sendable, Equatable {
    case none
    /// "Make Swiftly yours", the way to the preview (supporter update only).
    case teaser
    /// A quiet line with the look's name and "Change".
    case current

    /// - Parameters:
    ///   - supporterFeatures: the supporter build with its preview and purchase (today:
    ///     debug builds only).
    ///   - ownsLook: picked up a gift, so there is something to choose.
    public static func at(supporterFeatures: Bool, isSupporter: Bool, ownsLook: Bool) -> LookProfileEntry {
        if isSupporter || ownsLook { return .current }
        return supporterFeatures ? .teaser : .none
    }

    /// The plain "Looks" row under Appearance: only where the profile shows nothing and a
    /// gift is there to pick up.
    public static func showsLooksRow(entry: LookProfileEntry, giftAvailable: Bool) -> Bool {
        entry == .none && giftAvailable
    }
}
