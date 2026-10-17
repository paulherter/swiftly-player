import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **Watching together via Jellyfin's SyncPlay.**
///
/// Nothing of its own: the group belongs to the server. Members send requests (`Pause`,
/// `Unpause`, `Seek`) as calls; the server relays them to everyone as commands with an
/// **execution time** over the control channel. For that time to be the same moment on
/// every device, each device calculates its clock against the server's (``Zeitabgleich``).
///
/// Modeled on jellyfin-web (`plugins/syncPlay/core`): the same rules for commands in the
/// past and in the future, the same clock measurement. This file is only the calculation;
/// the UI and the player attach to it without knowing it.
public enum SyncPlay {
    /// Jellyfin counts in ticks of 100 ns.
    public static let ticksJeSecond: Double = 10_000_000

    static func seconds(_ ticks: Int64) -> Double { Double(ticks) / ticksJeSecond }
    static func ticks(_ seconds: Double) -> Int64 { Int64((seconds * ticksJeSecond).rounded()) }

    /// **From which offset a correction seeks.** jellyfin-web seeks from 400 ms
    /// (`minDelaySkipToSync`); below that nobody hears the difference, but a seek in VLC is
    /// audible.
    public static let jumpLimit: Double = 0.4

    /// **Catching up while playing only from one second.** A seek costs VLC a few hundred
    /// milliseconds on MKV; with the limit above this would loop between seeking and
    /// falling behind. jellyfin-web does not catch up during playback at all.
    public static let driftLimit: Double = 1.0
}

// MARK: - What the server sends

/// A group as `GET /SyncPlay/List` returns it.
public struct SyncPlayGroup: Sendable, Equatable, Identifiable, Decodable {
    public enum Phase: String, Sendable, Equatable {
        case empty = "Idle"
        case waits = "Waiting"
        case halted = "Paused"
        case running = "Playing"
    }

    public let id: String
    public let name: String
    public let condition: Phase?
    /// User names, not devices. Someone on two devices appears twice.
    public let participant: [String]
    public let state: Date?

    public init(id: String, name: String, condition: Phase? = nil,
                participant: [String] = [], state: Date? = nil) {
        self.id = id
        self.name = name
        self.condition = condition
        self.participant = participant
        self.state = state
    }

    enum Keys: String, CodingKey {
        case id = "GroupId", name = "GroupName", condition = "State"
        case participant = "Participants", state = "LastUpdatedAt"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        condition = try c.decodeIfPresent(String.self, forKey: .condition).flatMap(Phase.init(rawValue:))
        participant = try c.decodeIfPresent([String].self, forKey: .participant) ?? []
        state = try? c.decodeIfPresent(DateField.self, forKey: .state)?.value
    }

    /// Everyone except oneself, each name once. For "with Ann and Ben".
    public func other(asValue ich: String?) -> [String] {
        var watched = Set<String>()
        var result: [String] = []
        var ownSkipped = false
        for name in participant {
            if name == ich, !ownSkipped { ownSkipped = true; continue }
            if watched.insert(name).inserted { result.append(name) }
        }
        return result
    }
}

/// A command with an execution time (`SyncPlayCommand`).
public struct SyncPlayCommand: Sendable, Equatable {
    public enum Art: String, Sendable, Equatable {
        case proceed = "Unpause"
        case pause = "Pause"
        case stop = "Stop"
        case jump = "Seek"
    }

    public let group: String
    /// `PlaylistItemId`: valid only for this queue entry.
    public let entryRecord: String?
    public let art: Art
    /// Server time at which it is executed.
    public let moment: Date
    /// Position in seconds at which it applies.
    public let spot: Double?
    /// Server time at which it was sent.
    public let emitted: Date?

    public init(group: String, entryRecord: String?, art: Art, moment: Date,
                spot: Double?, emitted: Date? = nil) {
        self.group = group
        self.entryRecord = entryRecord
        self.art = art
        self.moment = moment
        self.spot = spot
        self.emitted = emitted
    }
}

/// The group's queue (`PlayQueue`).
public struct SyncPlayQueue: Sendable, Equatable {
    public struct Record: Sendable, Equatable {
        public let title: String
        public let entryRecord: String
        public init(title: String, entryRecord: String) {
            self.title = title
            self.entryRecord = entryRecord
        }
    }

    /// `NewPlaylist`, `SetCurrentItem`, `NextItem` ...
    public let reason: String
    public let state: Date?
    public let entries: [Record]
    public let index: Int
    public let startPoint: Double
    public let running: Bool

    public init(reason: String, state: Date?, entries: [Record], index: Int,
                startPoint: Double, running: Bool) {
        self.reason = reason
        self.state = state
        self.entries = entries
        self.index = index
        self.startPoint = startPoint
        self.running = running
    }

    public var current: Record? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    /// Must the player load a (different) title for this? Reordering, repeating and
    /// shuffling do not change what is playing.
    public var switchesTitle: Bool {
        ["NewPlaylist", "SetCurrentItem", "NextItem", "PreviousItem", "RemoveItems"].contains(reason)
    }
}

/// Everything that arrives about SyncPlay over the control channel.
public enum SyncPlayPostDirection: Sendable, Equatable {
    case command(SyncPlayCommand)
    /// One is in the group, after `New` as well as `Join`.
    case joined(SyncPlayGroup)
    case leave
    case notInGroup
    case doesNotExist
    /// Someone in the group lacks the title in their library.
    case noAccess
    case someoneJoined(String)
    case someoneLeft(String)
    case condition(SyncPlayGroup.Phase, reason: String?)
    case queue(SyncPlayQueue)
    /// From the control channel itself, not the server: the connection dropped. The server
    /// then removes the session from the group.
    case connectionLost
    /// From the control channel itself: after a drop, something arrives again.
    case connectionAgain

    /// Parses a whole control-channel message. `nil` for anything that is not SyncPlay or
    /// cannot be read.
    public static func read(_ text: String) -> SyncPlayPostDirection? {
        guard let data = text.data(using: .utf8),
              let header = try? JSONDecoder().decode(Header.self, from: data) else { return nil }
        let decoderRef = JSONDecoder()
        switch header.MessageType {
        case "SyncPlayCommand":
            guard let h = try? decoderRef.decode(Wrapper<CommandData>.self, from: data),
                  let b = h.Data.command else { return nil }
            return .command(b)
        case "SyncPlayGroupUpdate":
            guard let art = try? decoderRef.decode(Wrapper<GroupsHeader>.self, from: data).Data.Type
            else { return nil }
            switch art {
            case "GroupJoined":
                return (try? decoderRef.decode(Wrapper<GroupsData<SyncPlayGroup>>.self, from: data))
                    .map { .joined($0.Data.Data) }
            case "GroupLeft": return .leave
            case "NotInGroup": return .notInGroup
            case "GroupDoesNotExist": return .doesNotExist
            case "LibraryAccessDenied": return .noAccess
            case "UserJoined":
                return (try? decoderRef.decode(Wrapper<GroupsData<String>>.self, from: data))
                    .map { .someoneJoined($0.Data.Data) }
            case "UserLeft":
                return (try? decoderRef.decode(Wrapper<GroupsData<String>>.self, from: data))
                    .map { .someoneLeft($0.Data.Data) }
            case "StateUpdate":
                guard let z = try? decoderRef.decode(Wrapper<GroupsData<StateData>>.self, from: data),
                      let condition = SyncPlayGroup.Phase(rawValue: z.Data.Data.State) else { return nil }
                return .condition(condition, reason: z.Data.Data.Reason)
            case "PlayQueue":
                return (try? decoderRef.decode(Wrapper<GroupsData<QueueData>>.self, from: data))
                    .map { .queue($0.Data.Data.queue) }
            default:
                return nil
            }
        default:
            return nil
        }
    }

    // Read-only. The field names are the server's.
    private struct Header: Decodable { let MessageType: String }
    private struct Wrapper<D: Decodable>: Decodable { let Data: D }
    private struct GroupsHeader: Decodable { let `Type`: String }
    private struct GroupsData<D: Decodable>: Decodable { let Data: D }
    private struct StateData: Decodable { let State: String; let Reason: String? }

    private struct CommandData: Decodable {
        let GroupId: String
        let PlaylistItemId: String?
        let When: DateField
        let PositionTicks: Int64?
        let Command: String
        let EmittedAt: DateField?

        var command: SyncPlayCommand? {
            guard let art = SyncPlayCommand.Art(rawValue: Command) else { return nil }
            return SyncPlayCommand(group: GroupId, entryRecord: PlaylistItemId, art: art,
                                  moment: When.value, spot: PositionTicks.map(SyncPlay.seconds),
                                  emitted: EmittedAt?.value)
        }
    }

    private struct QueueData: Decodable {
        struct PlaylistEntry: Decodable { let ItemId: String; let PlaylistItemId: String }
        let Reason: String
        let LastUpdate: DateField?
        let Playlist: [PlaylistEntry]?
        let PlayingItemIndex: Int?
        let StartPositionTicks: Int64?
        let IsPlaying: Bool?

        var queue: SyncPlayQueue {
            SyncPlayQueue(
                reason: Reason, state: LastUpdate?.value,
                entries: (Playlist ?? []).map { .init(title: $0.ItemId, entryRecord: $0.PlaylistItemId) },
                index: PlayingItemIndex ?? -1,
                startPoint: SyncPlay.seconds(StartPositionTicks ?? 0),
                running: IsPlaying ?? false)
        }
    }
}

/// A server timestamp with its seven fractional digits; see ``Zeitstempel``.
struct DateField: Decodable, Sendable {
    let value: Date
    init(from decoder: any Decoder) throws { value = try TimestampFormat.read(from: decoder) }
}

extension SyncPlay {
    /// **Milliseconds, UTC, with `Z`**: how the server reads `When` in `Ready` and
    /// `Buffering`.
    public static func timeText(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func timeRead(_ text: String) -> Date? {
        let with = ISO8601DateFormatter()
        with.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = with.date(from: text) { return d }
        let without = ISO8601DateFormatter()
        without.formatOptions = [.withInternetDateTime]
        return without.date(from: text)
    }
}

// MARK: - Clock sync

/// **How far the server's clock is from ours.**
///
/// One measurement is four timestamps: request sent (local), received (server), response
/// sent (server), received (local). The offset follows NTP: `((t1 - t0) + (t2 - t3)) / 2`.
/// The measurement with the shortest round trip of the last eight counts; a long round trip
/// means the network waited somewhere, and then the path is unknown.
///
/// jellyfin-web measures the same way (`TimeSync.js`), with `GET /GetUtcTime`.
public struct TimeReconcile: Sendable, Equatable {
    public struct Reading: Sendable, Equatable {
        public let sent: Date
        public let serverReceive: Date
        public let serverSent: Date
        public let receive: Date

        public init(sent: Date, serverReceive: Date, serverSent: Date, receive: Date) {
            self.sent = sent
            self.serverReceive = serverReceive
            self.serverSent = serverSent
            self.receive = receive
        }

        /// Server minus local, in seconds.
        public var offset: TimeInterval {
            ((serverReceive.timeIntervalSince(sent))
             + (serverSent.timeIntervalSince(receive))) / 2
        }

        /// Round trip, without the time the server itself needed.
        public var runtime: TimeInterval {
            receive.timeIntervalSince(sent) - serverSent.timeIntervalSince(serverReceive)
        }
    }

    public static let keep = 8

    public private(set) var measurements: [Reading] = []

    public init() {}

    /// The measurement that counts.
    public var best: Reading? { measurements.min { $0.runtime < $1.runtime } }

    public var ready: Bool { !measurements.isEmpty }

    /// Server minus local. Zero without a measurement; then the local clock counts.
    public var offset: TimeInterval { best?.offset ?? 0 }

    /// One direction, in milliseconds, as `/SyncPlay/Ping` wants it.
    public var pingMilliseconds: Int64 {
        Int64(max(0, (best?.runtime ?? 0) / 2 * 1000).rounded())
    }

    public mutating func record(_ m: Reading) {
        measurements.append(m)
        if measurements.count > Self.keep { measurements.removeFirst(measurements.count - Self.keep) }
    }

    public func localOnly(_ server: Date) -> Date { server.addingTimeInterval(-offset) }
    public func server(_ localOnly: Date) -> Date { localOnly.addingTimeInterval(offset) }

    /// When to measure: three times at one-second intervals, then every minute.
    public static func pause(toMeasurements count: Int) -> TimeInterval {
        count < 3 ? 1 : 60
    }
}

// MARK: - Executing commands

/// **What the player should do with a command, and when.**
///
/// The rules of jellyfin-web (`PlaybackCore.js`):
///
/// - **Play, in the future:** wait until the time; seek to the position beforehand if
///   noticeably off.
/// - **Play, in the past:** the group is already running. Start at once, at the position
///   the group is at **now**: position plus the time since the command.
/// - **Pause:** pause at the time, then go to the group's position.
/// - **Seek:** at the time, go to the position, paused. The player then reports "ready" and
///   the server releases the play.
public struct SyncPlayExecution: Sendable, Equatable {
    public enum Step: Sendable, Equatable { case proceed, pause, jump, stop }

    public let step: Step
    /// Where to seek beforehand (for pause: afterwards). `nil` means stay.
    public let spot: Double?
    /// How long to wait from now.
    public let wait: TimeInterval

    public init(step: Step, spot: Double?, wait: TimeInterval) {
        self.step = step
        self.spot = spot
        self.wait = wait
    }

    public static func of(_ command: SyncPlayCommand, now: Date, reconcile: TimeReconcile,
                            localPoint: Double) -> SyncPlayExecution {
        let whenLocal = reconcile.localOnly(command.moment)
        let wait = max(0, whenLocal.timeIntervalSince(now))

        func onlyIfPresentBeside(_ target: Double?) -> Double? {
            guard let target else { return nil }
            return abs(target - localPoint) > SyncPlay.jumpLimit ? max(0, target) : nil
        }

        switch command.art {
        case .proceed:
            if wait > 0 {
                return .init(step: .proceed, spot: onlyIfPresentBeside(command.spot), wait: wait)
            }
            // Already past: go to where the group is now.
            let nowThere = command.spot.map {
                estimatedPoint(spot: $0, validFrom: command.moment, now: now, reconcile: reconcile)
            }
            return .init(step: .proceed, spot: onlyIfPresentBeside(nowThere), wait: 0)
        case .pause:
            return .init(step: .pause, spot: onlyIfPresentBeside(command.spot), wait: wait)
        case .jump:
            return .init(step: .jump, spot: command.spot.map { max(0, $0) }, wait: wait)
        case .stop:
            return .init(step: .stop, spot: nil, wait: wait)
        }
    }

    /// Where the group is now, if it has been running from `spot` since `validFrom`
    /// (server time).
    public static func estimatedPoint(spot: Double, validFrom: Date, now: Date,
                                         reconcile: TimeReconcile) -> Double {
        spot + max(0, reconcile.server(now).timeIntervalSince(validFrom))
    }

    /// **Which position "ready" reports after a seek.**
    ///
    /// The server accepts it to within half a second (`MaxPlaybackOffset`) and otherwise
    /// sends the seek again. After starting, VLC is a few tenths behind the target; that is
    /// the same position, not a new one. Only from one second on does the measured one
    /// count: the seek then really landed elsewhere, and the server should know.
    public static func readyPoint(target: Double, actualValue: Double) -> Double {
        abs(actualValue - target) <= 1 ? target : actualValue
    }

    /// **Catching up during playback.** Returns the position to seek to, or `nil` while
    /// close enough. Only after a "play", and only for the entry currently playing.
    public static func bringUpToDate(lastOne: SyncPlayCommand?, entryRecord: String?, now: Date,
                                   reconcile: TimeReconcile, localPoint: Double) -> Double? {
        guard let lastOne, lastOne.art == .proceed, let spot = lastOne.spot,
              lastOne.entryRecord == nil || lastOne.entryRecord == entryRecord,
              reconcile.localOnly(lastOne.moment) <= now else { return nil }
        let should = estimatedPoint(spot: spot, validFrom: lastOne.moment, now: now,
                                     reconcile: reconcile)
        return abs(should - localPoint) > SyncPlay.driftLimit ? should : nil
    }
}

// MARK: - Reporting buffering

/// **Is the movie stopped although it should be playing?**
///
/// Then the group must know (`Buffering`), or it runs away from that member. And once it
/// continues, "ready" (`Ready`). This is measured on the position, not on VLC's state,
/// which reports buffering either not at all or every second depending on the source.
public struct BufferGuard: Sendable, Equatable {
    public enum Message: Sendable, Equatable { case buffers, ready }

    /// How long without progress before it counts as buffering.
    public static let deadline: TimeInterval = 3

    public private(set) var buffers = false
    private var lastPoint: Double?
    private var standsSince: Date?

    public init() {}

    public mutating func tick(spot: Double, shouldRun: Bool, now: Date) -> Message? {
        defer { lastPoint = spot }
        guard shouldRun else {
            standsSince = nil
            return nil
        }
        let moved = lastPoint.map { spot - $0 > 0.05 } ?? false
        if moved {
            standsSince = nil
            if buffers { buffers = false; return .ready }
            return nil
        }
        if standsSince == nil { standsSince = now }
        if !buffers, let since = standsSince, now.timeIntervalSince(since) >= Self.deadline {
            buffers = true
            return .buffers
        }
        return nil
    }

    /// Start counting again after a seek or a new title.
    public mutating func reset() {
        buffers = false
        lastPoint = nil
        standsSince = nil
    }
}

// MARK: - Calls

/// The permission the operator sets per account (`Policy.SyncPlayAccess`).
public enum SyncPlayRight: String, Sendable, Equatable {
    case createAndJoin = "CreateAndJoinGroups"
    case join = "JoinGroups"
    case no = "None"

    public var mayCreate: Bool { self == .createAndJoin }
    public var mayJoin: Bool { self != .no }
}

extension JellyfinClient {

    /// The account's SyncPlay permission. `nil` if the server says nothing; it then decides
    /// on the call itself.
    public func syncPlayRight() async -> SyncPlayRight? {
        struct Reply: Decodable {
            struct Policy: Decodable { let SyncPlayAccess: String? }
            let Policy: Policy?
        }
        guard let s = try? requireSessionForReporting(),
              let req = try? rawRequest("Users/\(s.userID)", method: "GET"),
              let (data, answer) = try? await rawSession.data(for: req),
              let http = answer as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let value = try? JSONDecoder().decode(Reply.self, from: data).Policy?.SyncPlayAccess
        else { return nil }
        return SyncPlayRight(rawValue: value)
    }

    /// All groups this account may see.
    public func syncPlayGroups() async throws -> [SyncPlayGroup] {
        let req = try rawRequest("SyncPlay/List", method: "GET")
        let data = try await syncPlaySend(req)
        do {
            return try JSONDecoder().decode([SyncPlayGroup].self, from: data)
        } catch {
            throw JellyfinError.decoding(String(describing: error))
        }
    }

    public func syncPlayCreate(name: String) async throws {
        _ = try await syncPlaySend(try syncPlayRequest("SyncPlay/New", ["GroupName": name]))
    }

    public func syncPlayJoin(_ group: String) async throws {
        _ = try await syncPlaySend(try syncPlayRequest("SyncPlay/Join", ["GroupId": group]))
    }

    public func syncPlayLeave() async throws {
        _ = try await syncPlaySend(try syncPlayRequest("SyncPlay/Leave", nil))
    }

    /// Sets what the group watches. Everyone loads it, then the group holds at the start
    /// position until someone presses play.
    public func syncPlayQueue(_ title: [String], since seconds: Double = 0) async throws {
        _ = try await syncPlaySend(try syncPlayRequest("SyncPlay/SetNewQueue", [
            "PlayingQueue": title, "PlayingItemPosition": 0,
            "StartPositionTicks": SyncPlay.ticks(seconds),
        ]))
    }

    public func syncPlayBitNext() async throws {
        _ = try await syncPlaySend(try syncPlayRequest("SyncPlay/Unpause", nil))
    }

    public func syncPlayBitPause() async throws {
        _ = try await syncPlaySend(try syncPlayRequest("SyncPlay/Pause", nil))
    }

    public func syncPlayPleaseJump(on seconds: Double) async throws {
        _ = try await syncPlaySend(try syncPlayRequest("SyncPlay/Seek", [
            "PositionTicks": SyncPlay.ticks(max(0, seconds)),
        ]))
    }

    /// `Ready` or `Buffering`. `moment` is **server time**.
    public func syncPlayState(ready: Bool, moment: Date, spot: Double, running: Bool,
                              entryRecord: String) async throws {
        _ = try await syncPlaySend(try syncPlayRequest(ready ? "SyncPlay/Ready" : "SyncPlay/Buffering", [
            "When": SyncPlay.timeText(moment),
            "PositionTicks": SyncPlay.ticks(max(0, spot)),
            "IsPlaying": running,
            "PlaylistItemId": entryRecord,
        ]))
    }

    public func syncPlayPing(milliseconds: Int64) async throws {
        _ = try await syncPlaySend(try syncPlayRequest("SyncPlay/Ping", ["Ping": milliseconds]))
    }

    /// A measurement for the ``Zeitabgleich``.
    public func serverTimeMeasure() async throws -> TimeReconcile.Reading {
        struct Reply: Decodable {
            let RequestReceptionTime: String
            let ResponseTransmissionTime: String
        }
        let req = try rawRequest("GetUtcTime", method: "GET")
        let sent = Date()
        let data = try await syncPlaySend(req)
        let receive = Date()
        guard let a = try? JSONDecoder().decode(Reply.self, from: data),
              let within = SyncPlay.timeRead(a.RequestReceptionTime),
              let out = SyncPlay.timeRead(a.ResponseTransmissionTime) else {
            throw JellyfinError.decoding("GetUtcTime")
        }
        return .init(sent: sent, serverReceive: within, serverSent: out,
                     receive: receive)
    }

    private func syncPlayRequest(_ path: String, _ shell: [String: Any]?) throws -> URLRequest {
        var req = try rawRequest(path, method: "POST")
        if let shell {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: shell)
        }
        return req
    }

    private func syncPlaySend(_ req: URLRequest) async throws -> Data {
        let (data, answer): (Data, URLResponse)
        do {
            (data, answer) = try await rawSession.data(for: req)
        } catch {
            throw JellyfinError(petition: error)
        }
        guard let http = answer as? HTTPURLResponse else {
            throw JellyfinError.transport("Keine HTTP-Antwort.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(status: http.statusCode,
                                     body: String(data: data.prefix(300), encoding: .utf8))
        }
        return data
    }
}
