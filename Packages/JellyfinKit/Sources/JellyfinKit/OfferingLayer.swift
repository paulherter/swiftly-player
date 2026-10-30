import Foundation

/// The layer above the picture where “Skip intro” and “Next episode” appear
/// by themselves, without the controls opening.
///
/// Behaviour modeled on Netflix.
///
/// **Current behaviour:**
///
/// - **Skipping** (intro, recap …) is shown above the picture for ``knopfdauer``
///   from the start of the section and then fades out if nobody presses it (it used to
///   stay for the whole length of the intro). After that it belongs to the controls:
///   **while they are open it is shown**; if they are reopened within the section it
///   comes back with them and goes with them. The time only counts while playing and
///   keeps running with the controls open; closing them after it is up takes the
///   button along.
///
///   *Rejected:* an earlier version showed it for as long as the section ran, whether
///   the controls were open or not. The version before sent it away for good after
///   **one** open and close of the controls, which looked as if it sometimes went with
///   the controls and sometimes not. Now one rule applies: after the time is up it
///   goes exactly with them, every time.
/// - **Next episode** as a card exists only with a credits section from the server
///   (``Abschnittslogik/cardDue(position:dauer:abschnitte:hatNaechsteFolge:)``).
///   It stays, the fill runs for ``countdown``, and when it looks full, the next
///   episode starts after ``nachlauf``. With “Next episode automatically” off
///   (``Advance``) the platforms pass `cardDue: false`: no card, no advance. Opening the controls **deliberately**
///   meanwhile cancels it; then only the normal button in the controls remains. Without
///   a credits section playback never continues by itself.
/// - **Pointer movement is not a cancel**: on Mac, Linux and Windows every mouse
///   movement brings up the controls. If they open that way (``Oeffnung/nebenbei``),
///   the card stays in place and keeps counting. Only a click on the picture, a key or
///   a button (``Oeffnung/bewusst``) cancels it.
///
/// *Which* offer applies is decided by ``Abschnittslogik``; presentation and focus
/// are up to the platform. Time comes in as elapsed seconds per tick, not as a clock,
/// so every sequence can be tested without waiting, and a pause stops time by itself.
///
/// The button in the controls is unaffected: it keeps showing
/// ``Abschnittslogik/angebot(position:dauer:abschnitte:hatNaechsteFolge:)``.
public struct OfferingLayer: Sendable, Equatable {

    /// The card's “Next episode” fill runs this long at most. Shorter if the file ends
    /// sooner (``Abschnittslogik/countdown(position:dauer:)``).
    /// Ten seconds was too long.
    public static let countdown: Double = 7

    /// How long after the calculated end of the fill the switch happens.
    ///
    /// Platforms animate the fill over one tick (half a second), so it only looks full
    /// then; after that another 0.4 s of rest. Before, the episode switched while the bar
    /// did not yet look full.
    public static let postRun: Double = 0.5 + 0.4

    /// How long “Skip intro” (and any other skip) is shown above the picture without
    /// controls, counted from the start of the section, only while playing. After that,
    /// only with the controls.
    public static let buttonDuration: Double = 6

    public enum OfferingPresentation: Sendable, Equatable {
        case nothing
        case button(ButtonOffering)
        /// `share` runs from 0 to 1, how far the countdown is.
        case card(share: Double)

        public var visible: Bool { self != .nothing }
    }

    /// What the remembered state applies to. If it changes, everything starts over.
    private enum Occasion: Sendable, Equatable {
        case nobody
        case skip(to: Double)
        case nextEpisode
    }

    private var occasion: Occasion = .nobody
    private var offering: ButtonOffering = .nobody
    private var closed = false
    private var run: Double = 0
    /// How long the skip button has been shown, see ``knopfdauer``.
    private var buttonRun: Double = 0
    private var length: Double = Self.countdown
    private var triggered = false
    private var controlsOpen = false
    /// Open, but only through pointer movement; the card keeps running.
    private var onlyBeside = false

    /// How the controls opened.
    public enum Opening: Sendable, Equatable {
        /// Tap, click on the picture, key, remote: cancels the card.
        case deliberate
        /// Pointer movement (or mere sync with the view's state):
        /// cancels nothing and does not turn deliberately opened controls
        /// back into “incidental”.
        case beside
    }

    /// The controls cover the card: open, and not only through the pointer.
    private var controlsCover: Bool { controlsOpen && !onlyBeside }

    /// The countdown was cancelled. This episode then no longer advances by itself at the
    /// end of the file either; someone who wanted to watch the credits should not get
    /// thrown out one second before the end.
    public private(set) var nextCancelled = false

    public init() {}

    /// **The card waits while the controls are open** (episode card, iPhone and TV):
    /// it goes away, the countdown pauses, and when the controls close it comes back and
    /// keeps counting; otherwise playback would jump to the next episode in the middle of
    /// using the controls. Cancelling happens only explicitly (``close()``: X,
    /// swipe away, Menu). Off: the old behaviour where deliberately opened controls
    /// cancel the card (Android, Linux, Windows).
    public var cardWaitsControls = false

    private var cardGedeckt: Bool { controlsCover }

    /// The card is currently counting its countdown (visible or covered by the
    /// controls); then advancing belongs to it, not to the end of the file
    /// Dateiende (``Folgenende/weiterschalten(position:dauer:sinceOpen:cardCounts:)``).
    public var cardCounts: Bool {
        occasion == .nextEpisode && !closed && !triggered
    }

    /// **After a jump the countdown starts over**: someone who seeks into the credits
    /// or to the end should see the whole card, not a remainder that switches at once.
    public mutating func jumped() {
        guard occasion == .nextEpisode, !closed, !triggered else { return }
        run = 0
    }

    /// One tick. `true` means: switch to the next episode now, exactly once per episode.
    ///
    /// **Also call directly after a jump, with `elapsed: 0`.** Then the button appears
    /// or disappears immediately with the new position and not on the next tick.
    ///
    /// - Parameters:
    ///   - angebot: what ``Abschnittslogik`` currently offers.
    ///   - cardDue: ``Abschnittslogik/cardDue(position:dauer:abschnitte:hatNaechsteFolge:)``.
    ///   - laeuft: no countdown runs while stopped.
    ///   - vergangen: seconds since the last tick.
    ///   - countdown: how long the fill lasts if the card opens now —
    ///     ``Abschnittslogik/countdown(position:dauer:)``.
    public mutating func tick(offering new: ButtonOffering, cardDue: Bool,
                              running: Bool, elapsed: Double,
                              countdown: Double = Self.countdown,
                              atEnd: Bool = false) -> Bool {
        let newOccasion: Occasion
        switch new {
        case let .skip(to, _): newOccasion = .skip(to: to)
        case .nextEpisode: newOccasion = cardDue ? .nextEpisode : .nobody
        case .nobody: newOccasion = .nobody
        }
        if newOccasion != occasion {
            occasion = newOccasion
            run = 0
            buttonRun = 0
            length = max(countdown, 0.5)
            closed = false
        }
        offering = new

        if case .skip = occasion, running, elapsed > 0, !closed {
            buttonRun += elapsed
        }

        // **At the end of the file it keeps counting although nothing plays**,
        // otherwise the card would stay forever after a jump to the end.
        guard running || atEnd, elapsed > 0, occasion == .nextEpisode, !closed,
              !cardGedeckt, !triggered else { return false }
        run += elapsed
        if run >= length + Self.postRun {
            triggered = true
            return true
        }
        return false
    }

    /// The controls open or close. Call immediately, not on the next tick.
    ///
    /// A deliberate open cancels a “Next episode” card, even if the controls were already
    /// open through the pointer. Opening through the pointer (`.beside`) lets it run. A
    /// skip button whose ``knopfdauer`` is up returns with any kind of open and goes with
    /// closing.
    public mutating func controls(opened: Bool, through art: Opening = .deliberate) {
        guard opened else {
            controlsOpen = false
            onlyBeside = false
            return
        }
        switch art {
        case .deliberate:
            guard !controlsCover else { return }
            if occasion == .nextEpisode, !cardWaitsControls { close() }
            controlsOpen = true
            onlyBeside = false
        case .beside:
            guard !controlsOpen else { return }
            controlsOpen = true
            onlyBeside = true
        }
    }

    /// What is shown above the picture. A skip button during its first ``knopfdauer``
    /// seconds, after that only with the controls open; the card when they are closed or
    /// opened only by the pointer; when deliberately open, the normal button is there
    /// instead, and the platform shows it.
    public var display: OfferingPresentation {
        guard occasion != .nobody, !closed, !triggered else { return .nothing }
        if occasion == .nextEpisode {
            guard !cardGedeckt else { return .nothing }
            return .card(share: min(run / length, 1))
        }
        guard !buttonExpired else { return .nothing }
        return .button(offering)
    }

    /// The skip button has had its time without controls and the controls are closed:
    /// it is not shown.
    private var buttonExpired: Bool {
        buttonRun >= Self.buttonDuration && !controlsOpen
    }

    /// How long the fill of the currently shown card runs.
    public var countdownLength: Double { length }

    /// Seconds until the switch, for VoiceOver and labels.
    public var countdownRest: Int {
        Int(capped: (length - min(run, length)).rounded(.up))
    }

    /// Whether playback advances by itself at the end of the file: only with a card,
    /// and only if it is not cancelled.
    public var nextAtEnd: Bool {
        occasion == .nextEpisode && !nextCancelled
    }

    /// Back, or focus moves elsewhere: the overlay is gone until a new offer arrives.
    /// A running countdown is thereby cancelled.
    ///
    /// - Returns: `true` if there was something to close; Back has then done its job here
    ///   and must not leave the player.
    @discardableResult
    public mutating func close() -> Bool {
        guard occasion != .nobody, !closed, !triggered else { return false }
        // A hidden button is already gone: Back then belongs to the player,
        // not to an overlay nobody sees.
        if case .skip = occasion, buttonExpired { return false }
        if occasion == .nextEpisode { nextCancelled = true }
        closed = true
        return true
    }

    /// The button was pressed. The overlay goes, the platform executes.
    public mutating func pressed() {
        closed = true
    }

    /// A new episode plays: forget everything, including a cancel. Only whether the
    /// controls are open stays, since the view stays the same.
    public mutating func newEpisode() {
        let opened = controlsOpen, beside = onlyBeside, waits = cardWaitsControls
        self = OfferingLayer()
        cardWaitsControls = waits
        controlsOpen = opened
        onlyBeside = beside
    }
}

/// **The card's fill as continuous motion.**
///
/// The layer counts in ticks; a fill that follows the new value each tick stuttered on
/// iPhone at the start and near the end. This clock computes the fraction from the time
/// since the last start; the platform asks it on every frame (`TimelineView`, animation
/// tick). While stopped it holds exactly where it was and continues from there; it
/// never jumps back.
public struct FillClock: Sendable, Equatable {
    private var base: Double = 0
    private var since: Date?
    private var length: Double = OfferingLayer.countdown

    public init() {}

    /// Call on every tick and on every change. `share` is the layer's fraction; `nil`
    /// means no card, and the clock is set to zero.
    public mutating func set(share: Double?, running: Bool, length: Double,
                                 now: Date = Date()) {
        guard let share else { self = FillClock(); return }
        self.length = max(length, 0.5)
        if running {
            if since == nil {
                base = max(base, share)
                since = now
            }
        } else if since != nil {
            base = self.share(now: now)
            since = nil
        }
    }

    /// The fraction at this moment, 0 to 1.
    public func share(now: Date = Date()) -> Double {
        let run = since.map { max(now.timeIntervalSince($0), 0) } ?? 0
        return min(base + run / length, 1)
    }
}

/// Whether playback switches to the next episode by itself at the end.
///
/// **Anyone who has flipped the switch in Swiftly keeps their choice.** Anyone who
/// never touched it gets the setting of their Jellyfin account
/// (`EnableNextEpisodeAutoPlay`), so it applies equally on all devices, as in
/// Swiftfin. If the server says nothing, it stays “on”, the default since the first
/// version.
public enum Advance {
    public static func applies(ownSelection: Bool?, account: Bool?) -> Bool {
        ownSelection ?? account ?? true
    }
}

/// What counts from the Jellyfin account: from `GET /Users/{id}`, from the fields
/// `Configuration` (what the user set for themselves) and `Policy` (what the operator
/// allows them). **Two blocks, one request:** the app fetches this response at every
/// start anyway.
public struct AccountPreGift: Sendable, Equatable, Decodable {
    public let nextEpisodeAutomatic: Bool?
    /// `Policy.EnableContentDownloading`. `nil` if the server says nothing;
    /// then ``Downloadrecht/unbekannt`` applies, i.e. allowed.
    public let downloadsAllowed: Bool?
    /// `Policy.EnableVideoPlaybackTranscoding`: may the server transcode video for this
    /// account? `nil` if it says nothing.
    public let convertAllowed: Bool?
    /// `Policy.EnableAudioPlaybackTranscoding`: transcode audio. A transcoded download
    /// needs both, see
    /// ``Downloadqualitaet/waehlbar(videoConvert:audioConvert:)``.
    public let audioConvertAllowed: Bool?

    public init(nextEpisodeAutomatic: Bool?, downloadsAllowed: Bool? = nil,
                convertAllowed: Bool? = nil, audioConvertAllowed: Bool? = nil) {
        self.nextEpisodeAutomatic = nextEpisodeAutomatic
        self.downloadsAllowed = downloadsAllowed
        self.convertAllowed = convertAllowed
        self.audioConvertAllowed = audioConvertAllowed
    }

    /// Whether a smaller quality is offered when downloading.
    public var downloadQualitySelectable: Bool {
        DownloadQuality.selectable(videoConvert: convertAllowed, audioConvert: audioConvertAllowed)
    }

    /// The decision lives in ``DownloadPermission``, not in a `Bool?` that each platform
    /// interprets differently.
    public var downloadPermission: DownloadPermission { .fromServer(downloadsAllowed) }

    enum OuterKey: String, CodingKey {
        case configuration = "Configuration"
        case policy = "Policy"
    }
    enum Keys: String, CodingKey { case next = "EnableNextEpisodeAutoPlay" }
    enum RightsKey: String, CodingKey {
        case download = "EnableContentDownloading"
        case convert = "EnableVideoPlaybackTranscoding"
        case audioConvert = "EnableAudioPlaybackTranscoding"
    }

    public init(from decoder: any Decoder) throws {
        let outer = try decoder.container(keyedBy: OuterKey.self)
        // **Each block on its own.** Before, the decoder bailed out at once on a missing
        // `Configuration`; with two blocks that would have taken `Policy` with it, even though
        // it was right there.
        if outer.contains(.configuration) {
            let c = try outer.nestedContainer(keyedBy: Keys.self, forKey: .configuration)
            nextEpisodeAutomatic = try c.decodeIfPresent(Bool.self, forKey: .next)
        } else {
            nextEpisodeAutomatic = nil
        }
        if outer.contains(.policy) {
            let p = try outer.nestedContainer(keyedBy: RightsKey.self, forKey: .policy)
            downloadsAllowed = try p.decodeIfPresent(Bool.self, forKey: .download)
            convertAllowed = try p.decodeIfPresent(Bool.self, forKey: .convert)
            audioConvertAllowed = try p.decodeIfPresent(Bool.self, forKey: .audioConvert)
        } else {
            downloadsAllowed = nil
            convertAllowed = nil
            audioConvertAllowed = nil
        }
    }
}
