import Foundation

/// A marked section of an episode: intro, recap, outro.
///
/// Comes from `/MediaSegments/{itemId}`. **Since Jellyfin 10.10 this is a core
/// API, not a plugin endpoint.** The Intro Skipper plugin *writes* there; reading
/// goes through the official route. The old plugin-specific paths
/// (`/Episode/{id}/IntroTimestamps/v1`) answer 404 on 10.11, verified against
/// the server.
///
/// So **no plugin detection** is needed: an empty list means there are no
/// sections and thus no button. That falls out by itself instead of through a
/// query "is the plugin running?".
///
/// The field names come from the server's OpenAPI description
/// (`MediaSegmentDto`), not from a populated response. Nothing about them is
/// guessed, though.
public struct Segment: Sendable, Equatable, Codable {

    public enum Art: String, Sendable, Codable {
        case unknown  = "Unknown"
        case ads    = "Commercial"
        case preview   = "Preview"
        case lookBack = "Recap"
        case credits    = "Outro"
        case introSegment   = "Intro"

        /// Whether this section is skipped in principle.
        ///
        /// "Unknown" is not, since nobody knows what would be skipped there.
        /// The outro is included here but applies only if something comes after it.
        /// That is decided by ``Abschnittslogik``, because it needs the file length.
        var skippable: Bool {
            switch self {
            case .introSegment, .lookBack, .preview, .ads, .credits: true
            case .unknown: false
            }
        }

        public var label: String {
            switch self {
            case .introSegment:   translated("Intro überspringen")
            case .lookBack: translated("Rückblick überspringen")
            case .preview:   translated("Vorschau überspringen")
            case .ads:    translated("Werbung überspringen")
            case .credits:    translated("Abspann überspringen")
            case .unknown:  translated("Überspringen")
            }
        }
    }

    public let art: Art
    /// Seconds, not ticks, converted on decoding.
    public let from: Double
    public let until: Double

    public init(art: Art, from: Double, until: Double) {
        self.art = art
        self.from = from
        self.until = until
    }

    enum CodingKeys: String, CodingKey {
        case art = "Type"
        case fromTicks = "StartTicks"
        case untilTicks = "EndTicks"
    }

    /// **Ticks are hundred-nanosecond units.** Ten million per second; taking them
    /// for milliseconds is off by a factor of 10,000.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // **Decoded as text, not as `Art`.** A type this version does not know (a new
        // server, an addition) would otherwise throw on decoding, and the whole
        // response with it: not a single skip button, not even for the known intro
        // next to it.
        art = (try? c.decodeIfPresent(String.self, forKey: .art)).flatMap { $0.flatMap(Art.init(rawValue:)) }
            ?? .unknown
        from = Double(try c.decodeIfPresent(Int64.self, forKey: .fromTicks) ?? 0) / 10_000_000
        until = Double(try c.decodeIfPresent(Int64.self, forKey: .untilTicks) ?? 0) / 10_000_000
    }

    /// **The same form in which the server sends them**, so a download can store
    /// its sections and read them back the same way (offline, see
    /// ``Downloadposten/abschnitte``). Seconds back to ticks, rounded.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(art, forKey: .art)
        try c.encode(Int64((from * 10_000_000).rounded()), forKey: .fromTicks)
        try c.encode(Int64((until * 10_000_000).rounded()), forKey: .untilTicks)
    }

    public func contains(_ spot: Double) -> Bool {
        spot >= from && spot < until
    }
}

/// The response shape of `/MediaSegments/{itemId}`.
public struct SectionResponse: Sendable, Decodable {
    public let items: [Segment]

    enum CodingKeys: String, CodingKey { case items = "Items" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent(Lenient<Segment>.self, forKey: .items)?.values ?? []
    }
}

// MARK: - Which button applies

/// What the button at the bottom right of the player offers.
///
/// **It is the same button.** Design and position come from the existing
/// "Next episode" button; only label and timing change. That saves a second
/// design.
public enum ButtonOffering: Sendable, Equatable {
    case nobody
    /// Jump to this second, with this label.
    case skip(to: Double, art: Segment.Art)
    case nextEpisode

    /// What is written on the button.
    public var label: String {
        switch self {
        case .nobody:                 ""
        case let .skip(_, art): art.label
        case .nextEpisode:          translated("Nächste Folge")
        }
    }

    /// Which symbol precedes it.
    ///
    /// **Two different ones, on purpose.** Skipping continues *within* the same
    /// episode, advancing leaves it. The same symbol for both would blur the
    /// difference, and it is the only one that cannot be undone before the press.
    public var symbolText: String {
        switch self {
        case .nobody:          ""
        case .skip:   "forward.fill"
        case .nextEpisode:   "forward.end.fill"
        }
    }

    public var visible: Bool { self != .nobody }
}

/// Decides from position, duration and sections which button applies.
///
/// **It belongs in the package and not in the views.** Four platforms show the
/// same button, and this is exactly the kind of rule that drifts apart if
/// nobody re-measures it.
///
/// **Without sections nothing changes, not even the timing.** Then
/// ``Folgenende/buttonShow(position:dauer:)`` alone decides, as before.
public enum SectionLogic {

    /// Shortly before the end of a section it is no longer offered.
    ///
    /// Otherwise the button flashes up for a blink and is gone before the thumb is
    /// there, and a jump to a spot that is reached in a moment anyway is no jump.
    public static let minRemaining: Double = 1.5

    /// Shorter sections get no button.
    ///
    /// As in Jellyfin Android TV: a button that is gone again after two seconds is
    /// not an offer but a flash on the screen.
    public static let minLength: Double = 3

    /// How close an outro must reach to the end of the file to count as "until
    /// the end". The analysis rarely ends on the last frame.
    public static let creditsTolerance: Double = 2

    /// Sections that qualify for a button.
    static func valid(_ sections: [Segment]) -> [Segment] {
        sections.filter { $0.until - $0.from >= minLength }
    }

    /// Does the outro reach the end of the file? Then "Next episode" is the offer.
    /// Otherwise a scene follows, and the outro is skipped.
    static func sufficesEnd(_ credits: Segment, duration: Double) -> Bool {
        // Without a duration nothing can be said. Better to behave as before.
        guard duration > 0 else { return true }
        return credits.until >= duration - creditsTolerance
    }

    public static func offering(position: Double, duration: Double,
                               sections: [Segment],
                               hasNextEpisode: Bool) -> ButtonOffering {
        let sections = valid(sections)

        // 1. If the position is inside a skippable section, that one applies.
        //    An outro only if something comes after it: otherwise the button would
        //    jump to the end of the file, and that is no skipping.
        if let here = sections.first(where: {
            $0.art.skippable && $0.contains(position) && ($0.until - position) > minRemaining
                && !($0.art == .credits && sufficesEnd($0, duration: duration))
        }) {
            return .skip(to: here.until, art: here.art)
        }

        guard hasNextEpisode else { return .nobody }

        // 2. If there is outro information, it applies, and alone.
        //    Not in addition to the remaining-time rule: two times for one button
        //    would mean it appears twice. If the outro does not reach the end, "Next
        //    episode" comes after it, i.e. after the scene behind the outro.
        if let credits = sections.first(where: { $0.art == .credits }) {
            let since = sufficesEnd(credits, duration: duration) ? credits.from : credits.until
            return position >= since ? .nextEpisode : .nobody
        }

        // 3. Otherwise as before.
        return EpisodeEnd.buttonShow(position: position, duration: duration)
            ? .nextEpisode : .nobody
    }

    /// Whether the "Next episode" card opens by itself.
    ///
    /// **Only with an outro section from the server that reaches the end:** then
    /// from the start of the outro. Without an outro there is no card and no
    /// automatic advance, only the button in the controls. It used to open in the
    /// last ten seconds; without analysis nobody knows whether action is still
    /// going on there.
    ///
    /// If a scene follows the outro, the outro is skipped, and the scene after it
    /// gets no card: a countdown in the middle of it would cut it off.
    ///
    /// **`remainingWindow`** (iPhone and TV): without an outro section the card comes in
    /// the last so many seconds, and its countdown runs to the end of the file
    /// (``countdown(position:dauer:sections:restfenster:)``) and cuts nothing off.
    /// `nil` is the old behavior (Android, Linux, Windows).
    public static func cardDue(position: Double, duration: Double,
                                    sections: [Segment],
                                    hasNextEpisode: Bool,
                                    remainingWindow: Double? = nil) -> Bool {
        // Without a duration nothing is "at the end"; before the first picture it is 0.
        guard duration > 0 else { return false }
        let credits = valid(sections).first(where: { $0.art == .credits })
        if credits == nil, let remainingWindow {
            return duration - position <= remainingWindow
                && offering(position: position, duration: duration, sections: sections,
                           hasNextEpisode: hasNextEpisode) == .nextEpisode
        }
        guard let credits, sufficesEnd(credits, duration: duration), position >= credits.from
        else { return false }
        return offering(position: position, duration: duration, sections: sections,
                       hasNextEpisode: hasNextEpisode) == .nextEpisode
    }

    /// How long the card's fill runs when it opens at this position:
    /// ``Angebotsebene/countdown``, but never beyond the end of the file.
    public static func countdown(position: Double, duration: Double) -> Double {
        guard duration > 0 else { return OfferingLayer.countdown }
        return min(OfferingLayer.countdown, max(duration - position, 1))
    }

    /// As above, but without an outro section and with `remainingWindow` the countdown
    /// runs to the end of the file: nobody knows there whether action is still going on.
    public static func countdown(position: Double, duration: Double, sections: [Segment],
                                 remainingWindow: Double?) -> Double {
        guard remainingWindow != nil, duration > 0,
              !valid(sections).contains(where: { $0.art == .credits })
        else { return countdown(position: position, duration: duration) }
        return max(duration - position, 1)
    }
}
