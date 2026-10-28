import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - What is sent

/// **What another device is asked to play**: the title, where, which version and
/// which tracks.
///
/// **No plan, no address, no profile.** The receiving device asks the server for
/// its own plan with its own device profile, exactly as if someone had pressed
/// play over there. That is why sending a film to the TV can never make the
/// server transcode: the phone's profile plays no part in it.
///
/// Travels in Jellyfin's own format both ways: out as the query of
/// `POST /Sessions/{id}/Playing`, in as the `Play` message on the control
/// channel. There is no protocol of our own, so the dashboard and other clients
/// can send to Swiftly the same way.
public struct PlayOrder: Sendable, Equatable {
    /// What the server lists. Jellyfin may append the following episodes to a
    /// single one; the player finds its next episode itself and ignores them.
    public let itemIDs: [String]
    /// Which of ``itemIDs`` to start with.
    public let startIndex: Int
    /// Seconds, not ticks.
    public let start: Double
    public let mediaSourceID: String?
    /// Jellyfin's `Index`; `nil` leaves the choice to the receiver.
    public let audioIndex: Int?
    /// Jellyfin's `Index`, `-1` for "off"; `nil` leaves the choice to the receiver.
    public let subtitleIndex: Int?

    public init(itemIDs: [String], startIndex: Int = 0, start: Double,
                mediaSourceID: String? = nil, audioIndex: Int? = nil, subtitleIndex: Int? = nil) {
        self.itemIDs = itemIDs; self.startIndex = startIndex; self.start = start
        self.mediaSourceID = mediaSourceID
        self.audioIndex = audioIndex; self.subtitleIndex = subtitleIndex
    }

    /// One title with the tracks this device would have played.
    public init(itemID: String, start: Double, mediaSourceID: String?, tracks: TrackIndices) {
        self.init(itemIDs: [itemID], start: start, mediaSourceID: mediaSourceID,
                  audioIndex: tracks.audio, subtitleIndex: tracks.subtitle)
    }

    /// **What pressing play on this device becomes when it goes to another one.**
    ///
    /// The tracks are the ones this device would have opened with
    /// (``TrackRule/startIndices(streams:rememberedAudio:rememberedSubtitle:serverAudio:serverSubtitle:automatic:audioLanguage:subtitleLanguage:)``),
    /// read from the title's own `MediaSources`, so no `PlaybackInfo` is asked for
    /// a film that will not play here. Without sources the receiver chooses.
    ///
    /// - Parameter sourceID: the version picked by hand; otherwise the server's
    ///   first, the one the receiver would take as well.
    public static func title(_ item: Item, start: Double, sourceID: String?,
                             rememberedAudio: TrackImprint?,
                             rememberedSubtitle: TrackMemory.Choice?, automatic: Bool,
                             audioLanguage: String, subtitleLanguage: String) -> PlayOrder {
        let sources = item.mediaSources ?? []
        let source = sources.first { $0.id != nil && $0.id == sourceID } ?? sources.first
        guard let source, let streams = source.mediaStreams, !streams.isEmpty else {
            return PlayOrder(itemIDs: [item.id], start: start, mediaSourceID: sourceID ?? source?.id)
        }
        let tracks = TrackRule.startIndices(streams: streams, rememberedAudio: rememberedAudio,
                                            rememberedSubtitle: rememberedSubtitle,
                                            serverAudio: source.defaultAudioStreamIndex,
                                            serverSubtitle: source.defaultSubtitleStreamIndex,
                                            automatic: automatic, audioLanguage: audioLanguage,
                                            subtitleLanguage: subtitleLanguage)
        return PlayOrder(itemID: item.id, start: start, mediaSourceID: source.id ?? sourceID,
                         tracks: tracks)
    }

    /// The title to open, `nil` if the list is empty or the index points past it.
    public var itemID: String? {
        itemIDs.indices.contains(startIndex) ? itemIDs[startIndex] : nil
    }

    /// The tracks as the player takes them.
    public var tracks: TrackIndices { TrackIndices(audio: audioIndex, subtitle: subtitleIndex) }

    /// **`PlayNow` only.** `PlayNext` and `PlayLast` would add to a queue, and the
    /// player has none; starting such a title at once would be a different command
    /// than the one sent, so it is refused instead.
    static let playNow = "PlayNow"

    /// The query of `POST /Sessions/{id}/Playing`, names as in Jellyfin's
    /// `SessionController.Play`.
    var query: [URLQueryItem] {
        var q: [URLQueryItem] = [
            .init(name: "playCommand", value: Self.playNow),
            .init(name: "itemIds", value: itemIDs.joined(separator: ",")),
            .init(name: "startPositionTicks", value: String(Self.ticks(start))),
        ]
        if startIndex != 0 { q.append(.init(name: "startIndex", value: String(startIndex))) }
        if let mediaSourceID { q.append(.init(name: "mediaSourceId", value: mediaSourceID)) }
        if let audioIndex { q.append(.init(name: "audioStreamIndex", value: String(audioIndex))) }
        if let subtitleIndex {
            q.append(.init(name: "subtitleStreamIndex", value: String(subtitleIndex)))
        }
        return q
    }

    static func ticks(_ seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64((seconds * 10_000_000).rounded())
    }

    /// **The order from a `Play` message on the control channel**, otherwise `nil`.
    ///
    /// `{"MessageType":"Play","Data":{"ItemIds":[…],"StartPositionTicks":…,
    /// "PlayCommand":"PlayNow",…}}`. Each field is read on its own: a value of an
    /// unexpected type is dropped, not the whole order with it.
    public static func read(_ text: String) -> PlayOrder? {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(Message.self, from: data),
              message.type == "Play", let content = message.content else { return nil }
        return read(content)
    }

    static func read(_ c: Content) -> PlayOrder? {
        // Without a command it is taken as `PlayNow`: that is Jellyfin's default and
        // all a "Play" can mean to a player without a queue.
        guard (c.command ?? playNow) == playNow,
              let ids = c.itemIDs?.filter({ !$0.isEmpty }), !ids.isEmpty else { return nil }
        let order = PlayOrder(itemIDs: ids, startIndex: c.startIndex ?? 0,
                              start: Double(max(0, c.startTicks ?? 0)) / 10_000_000,
                              mediaSourceID: c.mediaSourceID.flatMap { $0.isEmpty ? nil : $0 },
                              audioIndex: c.audioIndex, subtitleIndex: c.subtitleIndex)
        return order.itemID == nil ? nil : order
    }

    struct Message: Decodable {
        let type: String
        let content: Content?

        enum CodingKeys: String, CodingKey {
            case type = "MessageType"
            case content = "Data"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            content = try? c.decodeIfPresent(Content.self, forKey: .content)
        }
    }

    struct Content: Decodable {
        let itemIDs: [String]?
        let startIndex: Int?
        let startTicks: Int64?
        let command: String?
        let mediaSourceID: String?
        let audioIndex: Int?
        let subtitleIndex: Int?

        enum CodingKeys: String, CodingKey {
            case itemIDs = "ItemIds"
            case startIndex = "StartIndex"
            case startTicks = "StartPositionTicks"
            case command = "PlayCommand"
            case mediaSourceID = "MediaSourceId"
            case audioIndex = "AudioStreamIndex"
            case subtitleIndex = "SubtitleStreamIndex"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            itemIDs = try? c.decodeIfPresent([String].self, forKey: .itemIDs)
            startIndex = try? c.decodeIfPresent(Int.self, forKey: .startIndex)
            startTicks = try? c.decodeIfPresent(Int64.self, forKey: .startTicks)
            command = try? c.decodeIfPresent(String.self, forKey: .command)
            mediaSourceID = try? c.decodeIfPresent(String.self, forKey: .mediaSourceID)
            audioIndex = try? c.decodeIfPresent(Int.self, forKey: .audioIndex)
            subtitleIndex = try? c.decodeIfPresent(Int.self, forKey: .subtitleIndex)
        }
    }
}

// MARK: - Where it can go

/// **The chosen output: a device, not a session.**
///
/// A session ID changes every time the app on the TV starts again, the device ID
/// does not. Remembering the session would turn "Living room" into a dead entry
/// after the TV's next restart. Before sending, ``PlayTargets/session(for:in:)``
/// finds the current session of this device.
///
/// The name is kept for the label and for the message when the device is gone; the
/// fresh list may not have it any more.
public struct PlayOutput: Codable, Sendable, Equatable {
    public let deviceID: String
    public let name: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case name
    }

    public init(deviceID: String, name: String) {
        self.deviceID = deviceID; self.name = name
    }

    /// `nil` for a session without a device ID: it could not be found again.
    public init?(session: RemoteSession) {
        guard let id = session.devicesIdentifier, !id.isEmpty else { return nil }
        self.init(deviceID: id, name: PlayTargets.name(of: session))
    }
}

/// Decides which devices are offered as a place to send a film to.
///
/// **Belongs in the package for the same reason as ``Takeover``**: five platforms
/// show the same list, and a condition missing on one of them offers the device
/// itself, someone else's TV or an app that cannot play the film.
///
/// **Unlike ``Takeover``, nothing has to be playing there.** A TV showing
/// Swiftly's home page is exactly where a film is sent.
public enum PlayTargets {

    /// After this much silence a session counts as gone. The same as for the
    /// takeover: a Swiftly on screen asks the server every few seconds itself.
    public static var idleTimeout: TimeInterval { Takeover.idleTimeout }

    /// Every device a film can be sent to, one entry per device, sorted by name.
    ///
    /// **Sorted by name, not by activity**: the list is a picker that stays open
    /// while the poll runs, and entries changing places under the finger would be
    /// tapped wrong.
    public static func targets(from sessions: [RemoteSession],
                               ownDevicesIdentifier: String,
                               ownUserIdentifier: String,
                               now: Date = Date()) -> [RemoteSession] {
        var freshest: [String: RemoteSession] = [:]
        for s in sessions where fits(s, ownDevicesIdentifier: ownDevicesIdentifier,
                                     ownUserIdentifier: ownUserIdentifier, now: now) {
            // `fits` has made sure the device ID exists.
            let device = s.devicesIdentifier ?? ""
            // **One entry per device.** A TV whose app was restarted keeps its old
            // session on the server for a while; listing both shows "Living room"
            // twice, and the older one no longer listens.
            if let known = freshest[device],
               (known.lastActivity ?? .distantPast) >= (s.lastActivity ?? .distantPast) {
                continue
            }
            freshest[device] = s
        }
        return freshest.values.sorted { left, right in
            let l = name(of: left), r = name(of: right)
            if l != r { return l.localizedStandardCompare(r) == .orderedAscending }
            return (left.devicesIdentifier ?? "") < (right.devicesIdentifier ?? "")
        }
    }

    /// **Has the server forgotten what this device can do?**
    ///
    /// After a server restart the app gets a new session, and the remote control
    /// reconnects by itself, but the capabilities were only reported at app start
    /// and at the start of a playback. Until then the new session is not
    /// controllable, so `/Sessions?controllableByUserId` leaves it out: a TV waiting
    /// on its home page vanished from every phone's list until someone restarted it.
    /// Missing from that list is exactly the sign; the report is cheap and may be
    /// repeated.
    public static func mustReport(_ sessions: [RemoteSession],
                                  ownDevicesIdentifier: String) -> Bool {
        !sessions.contains { $0.devicesIdentifier == ownDevicesIdentifier }
    }

    /// The current session of the chosen device, `nil` if it is gone.
    public static func session(for output: PlayOutput,
                               in targets: [RemoteSession]) -> RemoteSession? {
        targets.first { $0.devicesIdentifier == output.deviceID }
    }

    /// What the picker calls the device: the name its owner gave it.
    public static func name(of session: RemoteSession) -> String {
        if let n = session.deviceName, !n.isEmpty { return n }
        return session.program ?? ""
    }

    static func fits(_ s: RemoteSession, ownDevicesIdentifier: String,
                     ownUserIdentifier: String, now: Date) -> Bool {
        whyNot(s, ownDevicesIdentifier: ownDevicesIdentifier,
               ownUserIdentifier: ownUserIdentifier, now: now) == nil
    }

    /// **Why a session is not offered, in one word**, for the log. Like
    /// ``Takeover/whyNot(_:ownDevicesIdentifier:ownUserIdentifier:now:)``: a missing
    /// TV looks the same from outside whatever the reason.
    public static func whyNot(_ s: RemoteSession, ownDevicesIdentifier: String,
                              ownUserIdentifier: String, now: Date = Date()) -> String? {
        // 1. Not ourselves, and a device that can be found again.
        guard let device = s.devicesIdentifier, !device.isEmpty else { return "ohne Geräte-ID" }
        if device == ownDevicesIdentifier { return "wir selbst" }
        // 2. Only the own account. For an administrator the server lists the whole
        //    household; sending a film to someone else's TV would be overreach.
        guard let whom = s.userIdentifier else { return "kein Konto genannt" }
        guard whom == ownUserIdentifier else { return "fremdes Konto" }
        // 3. Only Swiftly, not Swiftly Music. Another client would build its own plan
        //    with its own profile, and nothing guarantees it plays without
        //    transcoding.
        guard Takeover.takesHint(s) else { return "kein Swiftly" }
        // 4. The command must arrive and the device must play films.
        guard s.takesCommands else { return "nimmt keine Befehle" }
        guard s.playableMediaTypes.contains("Video") else { return "spielt kein Video" }
        // 5. Fresh enough: a TV whose app was closed must not stay in the list.
        if let stir = s.lastActivity {
            let older = now.timeIntervalSince(stir)
            if older > idleTimeout { return "still seit \(Int(older)) s" }
        }
        return nil
    }
}

// MARK: - Sending

extension JellyfinClient {

    /// **Asks another session to play**, the route the Jellyfin dashboard takes.
    ///
    /// The server forwards it as a `Play` message on that session's control
    /// channel, where ``RemoteControl/playHear(_:)`` receives it.
    public func playOn(session: String, order: PlayOrder) async throws {
        let req = try playOnRequest(session: session, order: order)
        let answer: URLResponse
        do { answer = try await rawSession.data(for: req).1 }
        catch { throw JellyfinError(petition: error) }
        guard let http = answer as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw JellyfinError.transport(translated("Das andere Gerät hat nicht reagiert."))
        }
    }

    func playOnRequest(session: String, order: PlayOrder) throws -> URLRequest {
        try rawRequest("Sessions/\(session)/Playing", method: "POST", query: order.query)
    }
}
