import Foundation

/// A session on **another** device that is currently playing something.
///
/// Comes from `GET /Sessions`. Jellyfin lists every signed-in session there with what
/// it is showing; that is exactly the information needed for a “continue on the TV”,
/// and nothing of our own has to be distributed for it.
public struct RemoteSession: Sendable, Equatable, Decodable, Identifiable {

    public let id: String
    /// Who owns the session.
    ///
    /// **Indispensable.** `controllableByUserId` does not return the user's *own*
    /// sessions but those the user **may control**; for an administrator that is all of
    /// them. On a test server the badge therefore showed what someone else was watching.
    /// It went unnoticed with a non-admin account, where the response only contained own
    /// sessions anyway.
    public let userIdentifier: String?
    public let devicesIdentifier: String?
    public let deviceName: String?
    /// “Swiftly”, “Jellyfin Web”, “Swiftfin”: the name of the program.
    public let program: String?
    public let takesCommands: Bool
    public let running: Item?
    public let state: PlayState?
    public let lastActivity: Date?
    /// `Video`, `Audio`: what the session said it can play when it reported its
    /// capabilities.
    ///
    /// **Read from the server only, never stored.** It decides whether a device is
    /// offered as a place to send a film to (``PlayTargets``); Swiftly Music reports
    /// `Audio` alone.
    public let playableMediaTypes: [String]

    public struct PlayState: Sendable, Equatable, Decodable {
        public let halted: Bool?
        private let pointTicks: Int64?

        enum CodingKeys: String, CodingKey {
            case halted = "IsPaused"
            case pointTicks = "PositionTicks"
        }

        /// Seconds, not ticks. Ten million per second.
        public var spot: Double { Double(pointTicks ?? 0) / 10_000_000 }

        public init(halted: Bool?, spot: Double) {
            self.halted = halted
            self.pointTicks = Int64(spot * 10_000_000)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case userIdentifier = "UserId"
        case devicesIdentifier = "DeviceId"
        case deviceName = "DeviceName"
        case program = "Client"
        case takesCommands = "SupportsRemoteControl"
        case running = "NowPlayingItem"
        case state = "PlayState"
        case lastActivity = "LastActivityDate"
        case playableMediaTypes = "PlayableMediaTypes"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userIdentifier = try c.decodeIfPresent(String.self, forKey: .userIdentifier)
        devicesIdentifier = try c.decodeIfPresent(String.self, forKey: .devicesIdentifier)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        program = try c.decodeIfPresent(String.self, forKey: .program)
        takesCommands = try c.decodeIfPresent(Bool.self, forKey: .takesCommands) ?? false
        running = try c.decodeIfPresent(Item.self, forKey: .running)
        state = try c.decodeIfPresent(PlayState.self, forKey: .state)
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity)
        // `try?`: a value from a newer server that does not read as a list of strings
        // must not cost the whole session, and with it the takeover badge.
        playableMediaTypes = (try? c.decodeIfPresent([String].self, forKey: .playableMediaTypes)) ?? []
    }

    public init(id: String, userIdentifier: String? = nil, devicesIdentifier: String?,
                deviceName: String?, program: String?,
                takesCommands: Bool, running: Item?, state: PlayState?,
                lastActivity: Date? = nil, playableMediaTypes: [String] = []) {
        self.id = id; self.userIdentifier = userIdentifier
        self.playableMediaTypes = playableMediaTypes
        self.devicesIdentifier = devicesIdentifier; self.deviceName = deviceName
        self.program = program; self.takesCommands = takesCommands
        self.running = running; self.state = state; self.lastActivity = lastActivity
    }
}

/// The commands a foreign session accepts.
///
/// The spelling is Jellyfin's, not ours; it appears like this in the path.
/// Deliberately only the three needed here; the rest would be stock.
public enum ForeignCommand: String, Sendable {
    case halt = "Pause"
    case proceed   = "Unpause"
    case finish  = "Stop"
}

public extension RemoteSession {

    /// “Adults · S2 F1” in German, “Adults · S2 E1” in English: what is playing on the
    /// other side.
    ///
    /// **Lived in `Sources/Shared` and was unreachable for Linux.** There a separate,
    /// shorter version existed: title on top, device below. The same information composed
    /// differently, exactly the kind of drift nobody reports.
    ///
    /// **The abbreviation comes from `episodeCode`**, no longer built by hand: it was
    /// once fixed as “E”, also in German.
    var titleLine: String {
        guard let t = running else { return deviceName ?? "" }
        var parts: [String] = []
        if let series = t.seriesName, !series.isEmpty { parts.append(series) }
        else { parts.append(t.name) }
        if let abbreviation = t.episodeCode { parts.append(abbreviation) }
        return parts.joined(separator: " · ")
    }

    /// **Which device**: guessed from the name, the server gives no more. `DeviceType` is
    /// empty for custom clients.
    ///
    /// The *glyphs* stay with the platform: SF Symbols on Apple, Adwaita on Linux. Only
    /// the decision **which device** it is is shared; it must not drift apart.
    enum DevicesKind: Sendable { case phone, tablet, computer, tv, unknown }

    var devicesKind: DevicesKind {
        let name = (deviceName ?? "").lowercased()
        // **Android first, after the program.** An Android phone is called “Pixel 10 Pro”;
        // nothing in that name identifies it as a phone, and on iPhone it appeared as a TV.
        let app = (program ?? "").lowercased()
        if app.contains("android tv") { return .tv }
        if app.contains("android") { return .phone }
        if name.contains("ipad") { return .tablet }
        if name.contains("mac") || name.contains("pc") || name.contains("linux") {
            return .computer
        }
        if name.contains("iphone") || name.contains("phone") { return .phone }
        if name.contains("tv") || name.contains("appletv") { return .tv }
        return .unknown
    }
}

// MARK: - Which session is offered

/// Decides whether there is anything to take over.
///
/// **Belongs in the package because four platforms show the same badge.** The rule is
/// short but has four conditions, and if one is missing on one platform, a device
/// there offers itself or a button leads nowhere. Like `EpisodeEnd` and `TimeAssumption`.
public enum Takeover {

    /// After this much silence a session counts as forgotten.
    ///
    /// Jellyfin cleans up sessions late; an app that crashed stays “playing” there for
    /// minutes. An offer that leads nowhere is worse than none. The progress report comes
    /// every ten seconds, so ninety seconds is plenty of margin.
    public static let idleTimeout: TimeInterval = 90

    /// Head of the takeover hint (`DisplayMessage`) to the session handing over.
    public static let hintHeader = "Swiftly-Uebernahme"

    /// Does the session understand the takeover hint? Only the Swiftly player
    /// (“Swiftly Player”, formerly “Swiftly”); other programs show a `DisplayMessage` as
    /// text, and Swiftly Music takes over nothing.
    public static func takesHint(_ s: RemoteSession) -> Bool {
        let p = s.program ?? ""
        return p.hasPrefix("Swiftly") && p != "Swiftly Music"
    }

    /// **Does a stop belong to a takeover?** Only then does the picture go off as a
    /// card. The hint comes **before** the stop; a stop from the dashboard or from another
    /// app comes without it, and then it simply closes.
    /// - Parameter hintPre: Seconds since the hint, `nil` without a hint.
    public static func isHandoff(hintPre: TimeInterval?) -> Bool {
        guard let hintPre else { return false }
        return hintPre >= 0 && hintPre < hintDeadline
    }

    /// For this long a hint counts as announcing the next stop.
    public static let hintDeadline: TimeInterval = 3

    /// Everything that can be taken over, most recent activity first.
    ///
    /// **A list, not a single session.** If something plays on two devices, the UI should
    /// ask which one is meant instead of guessing. The rule: if something plays on two
    /// devices, a picker appears.
    ///
    /// - Parameters:
    ///   - eigeneGeraeteID: without it the device offers itself; the most common mistake
    ///     here, and it only shows when just one device is running.
    ///   - eigeneBenutzerID: without it, what someone else watches shows up.
    ///   - jetzt: for the idle check; passed in so it stays testable.
    public static func offerings(from sessions: [RemoteSession],
                                ownDevicesIdentifier: String,
                                ownUserIdentifier: String,
                                now: Date = Date()) -> [RemoteSession] {
        sessions
            .filter { fits($0, ownDevicesIdentifier: ownDevicesIdentifier,
                            ownUserIdentifier: ownUserIdentifier, now: now) }
            // Most recent first: whoever did something last is probably sitting in front of it.
            // `sorted` is stable, so ties keep the server's order.
            .sorted { left, right in
                (left.lastActivity ?? .distantPast) > (right.lastActivity ?? .distantPast)
            }
    }

    /// Where watching continues here.
    ///
    /// The position from the session query lags by up to ten seconds, the interval at
    /// which the other device reports progress. On ending, though, it reports its stop with
    /// the exact position, and the server stores it on the item. That one applies as soon
    /// as it has changed compared to before and is not behind the session position;
    /// Jellyfin sets it to null near the start and end, and then the session position is
    /// the better one.
    ///
    /// - Parameters:
    ///   - sitzung: position from the freshest session query, in seconds.
    ///   - gespeichertVorher: `PlaybackPositionTicks` of the item before ending.
    ///   - gespeichertNachher: the same afterwards, `nil` if nothing arrived.
    public static func startPoint(session: Double, savedBefore: Int64?,
                                   savedAfterwards: Int64?) -> Double {
        guard let afterwards = savedAfterwards, afterwards != savedBefore else { return session }
        let seconds = Double(afterwards) / 10_000_000
        return seconds >= session - 1 ? seconds : session
    }

    /// **What the confirmation before a takeover calls the title.**
    ///
    /// A badge with a single offer used to take over on the first press. The other
    /// device stops at once, so a press by mistake stops someone's film. The
    /// question names what moves, "the episode" or "the film", the way the viewer
    /// thinks of it; anything else is "the video".
    public enum Moving: Sendable, Equatable { case episode, movie, video }

    public static func moving(_ s: RemoteSession) -> Moving {
        switch s.running?.type {
        case "Episode": .episode
        case "Movie": .movie
        default: .video
        }
    }

    /// The one, if there is only one; otherwise the most recent.
    public static func offering(from sessions: [RemoteSession],
                               ownDevicesIdentifier: String,
                               ownUserIdentifier: String,
                               now: Date = Date()) -> RemoteSession? {
        offerings(from: sessions, ownDevicesIdentifier: ownDevicesIdentifier,
                 ownUserIdentifier: ownUserIdentifier, now: now).first
    }

    static func fits(_ s: RemoteSession, ownDevicesIdentifier: String,
                      ownUserIdentifier: String, now: Date) -> Bool {
        // 1. Not ourselves.
        guard s.devicesIdentifier != ownDevicesIdentifier else { return false }
        // 2. And not someone else. The server answers with everything this user *may*
        //    control; for an administrator that is the whole household. Only the own account
        //    is offered: stopping someone else's playback would be overreach, and the badge
        //    would show what someone else is watching.
        guard let whom = s.userIdentifier, whom == ownUserIdentifier else { return false }
        // 3. Something is playing, and it has an identifier to open it with.
        guard let title = s.running, !title.id.isEmpty else { return false }
        // 3b. Video only. Music and audiobooks (also from Swiftly Music) do not belong in
        //     the player; there is nothing to take over.
        guard isVideo(title), s.program != "Swiftly Music" else { return false }
        // 4. Stopping must arrive. Without it the other device would keep playing while the
        //    same thing starts here: two audio tracks in the room, and nobody understands why.
        guard s.takesCommands else { return false }
        // 5. Fresh enough.
        if let stir = s.lastActivity, now.timeIntervalSince(stir) > idleTimeout {
            return false
        }
        return true
    }

    /// **Why a session failed, in one word.**
    ///
    /// `fits` only returns true or false, and five reasons look the same from outside:
    /// the badge is missing, and one cannot tell whether the server returns nothing,
    /// whether the session belongs to another account or whether it is merely too old.
    /// This information therefore sits next to the rule and not in the view; it belongs to
    /// the five conditions and changes with them.
    /// Audio, audiobooks and music are not a takeover for the player.
    static func isVideo(_ title: Item) -> Bool {
        !["Audio", "AudioBook", "MusicAlbum", "Playlist"].contains(title.type ?? "")
    }

    public static func whyNot(_ s: RemoteSession, ownDevicesIdentifier: String,
                                  ownUserIdentifier: String,
                                  now: Date = Date()) -> String? {
        if s.devicesIdentifier == ownDevicesIdentifier { return "wir selbst" }
        guard let whom = s.userIdentifier else { return "kein Konto genannt" }
        guard whom == ownUserIdentifier else { return "fremdes Konto" }
        guard let title = s.running else { return "spielt nichts" }
        guard !title.id.isEmpty else { return "Titel ohne Kennung" }
        guard isVideo(title), s.program != "Swiftly Music" else { return "kein Video" }
        guard s.takesCommands else { return "nimmt keine Befehle" }
        if let stir = s.lastActivity {
            let older = now.timeIntervalSince(stir)
            if older > idleTimeout { return "still seit \(Int(older)) s" }
        }
        return nil
    }
}
