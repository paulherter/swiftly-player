import Foundation
// On Linux, URLSession is not in Foundation but in a separate module. That
// module does not exist on Apple platforms, so the import is conditional and
// has no effect there.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the other end wants from us.
public enum RemoteCommand: Sendable, Equatable {
    case pause
    case proceed
    case toggle
    case stop
    /// Absolute target position in seconds.
    case jumpOn(Double)
    case forward
    case back
    case next
    case previous
}

/// Remote control through Jellyfin's socket.
///
/// Without it the session shows up in the dashboard but cannot be controlled.
/// **Two** things were missing, not one:
///
/// 1. `Sessions/Capabilities/Full` is what tells the server in the first place
///    that this session accepts commands. Without the call the dashboard hides
///    the buttons.
/// 2. The socket through which the commands then arrive. There is no request
///    for them; the server pushes on its own.
///
/// The server also expects a keep-alive. If it stays away, the server drops the
/// connection after a short time.
public actor RemoteControl {
    private let base: URL
    private let token: String
    private let devicesIdentifier: String
    private let session: URLSession

    private var task: (any RemoteLink)?
    /// After a failure of libcurl-WS it stays with `URLSession`.
    private var onlyURLSession = false
    private var listener: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var nextGift: (@Sendable (RemoteCommand) -> Void)?
    /// What arrives for SyncPlay: commands with a timestamp and news from the
    /// group. A separate path next to the remote commands: those come from the
    /// dashboard, these from the group, and they want different things.
    private var syncPlayNextGift: (@Sendable (SyncPlayPostDirection) -> Void)?
    /// Who takes over playback right away, see
    /// ``JellyfinClient/handoffHint(an:geraet:)``.
    private var handoffNextGift: (@Sendable (String) -> Void)?
    /// How many times in a row the connection has dropped. Controls the wait before
    /// the next attempt and is reset on success.
    private var teardowns = 0

    /// The complete `Authorization` value, identical to the one all other calls
    /// carry. Why this is needed is explained at ``start``.
    private let credential: String

    /// **A session of its own without a time limit, not `URLSession.shared`.**
    ///
    /// Measured on two machines: on Linux the channel dropped after **exactly 120
    /// seconds**, on the Mac it stayed unchanged after 349 seconds. Same wording,
    /// same rhythm, same server, only a different Foundation.
    ///
    /// 120 is twice the default of `timeoutIntervalForRequest`. A long-lived
    /// connection is not a request with a response; Apple's Foundation does not
    /// take that limit seriously for a WebSocket, swift-corelibs-foundation
    /// apparently does. And since the drop fell **on** the fourth keep-alive and
    /// not between, it is a limit that strikes on sending, not one that expires
    /// while idle.
    ///
    /// So a session of its own, with limits set so wide that they mean nothing.
    /// Using `.shared` here brings the bug back, on one platform only.
    public static let durationSession: URLSession = {
        let k = URLSessionConfiguration.default
        k.timeoutIntervalForRequest = 86_400
        k.timeoutIntervalForResource = 86_400
        // `waitsForConnectivity` exists on swift-corelibs-foundation only as
        // read-only. It was an extra anyway: the reconnect after a drop is already
        // in `newConnect`.
        return URLSession(configuration: k)
    }()

    public init(base: URL, token: String, devicesIdentifier: String, credential: String,
                session: URLSession = RemoteControl.durationSession) {
        self.base = base
        self.token = token
        self.devicesIdentifier = devicesIdentifier
        self.credential = credential
        self.session = session
    }

    /// Sets who receives SyncPlay messages. May be set before or after
    /// ``start(at:)``.
    public func syncPlayHear(_ nextGift: (@Sendable (SyncPlayPostDirection) -> Void)?) {
        syncPlayNextGift = nextGift
    }

    /// Sets who receives the handoff notice (the device name).
    public func handoffHear(_ nextGift: (@Sendable (String) -> Void)?) {
        handoffNextGift = nextGift
    }

    /// Connects and calls `at` for every incoming command.
    public func start(at nextGift: @escaping @Sendable (RemoteCommand) -> Void) {
        self.nextGift = nextGift
        guard task == nil else { return }

        var parts = URLComponents(url: base.appendingPathComponent("socket"),
                                  resolvingAgainstBaseURL: false)
        parts?.scheme = base.scheme == "http" ? "ws" : "wss"
        // **`ApiKey`, not `api_key`.**
        //
        // Jellyfin 12 ships with `EnableLegacyAuthorization=false` and thereby
        // dropped the old spelling, together with `X-Emby-Token`,
        // `X-MediaBrowser-Token` and `X-Emby-Authorization`. `ApiKey` exists since 10.8
        // and in 12, so it carries **both** server versions and is no break for older
        // installations.
        parts?.queryItems = [
            URLQueryItem(name: "ApiKey", value: token),
            URLQueryItem(name: "deviceId", value: devicesIdentifier),
        ]
        guard let url = parts?.url else {
            TrackSupport.sag("[Fernsteuerung] Adresse liess sich nicht bauen")
            return
        }

        // **The channel must identify itself exactly like all other calls.**
        //
        // It used to carry only the token and device ID in the address, without a
        // client name. Jellyfin keys a session by **name and device** together; without
        // a name the channel ends up somewhere, not necessarily at the session that is
        // playing.
        //
        // The symptom: the control buttons appeared and disappeared every second, and
        // when they were there a completely different runtime stood next to them. There
        // were **two** sessions of the same device, the channel on one and the progress
        // reports on the other. It only became visible when the client name changed
        // from "Swiftly" to "Swiftly Player"; the trap was there before.
        //
        // The query values stay as well: older servers read the channel's login from
        // there, newer ones from the header.
        TrackSupport.sag("[Fernsteuerung] verbinde …")
        var petition = URLRequest(url: url)
        petition.ownHeadersSet()
        petition.setValue(credential, forHTTPHeaderField: "Authorization")
        let new = lineBuild(petition)
        new.buildUp()
        task = new
        eavesdrop()
        beat()
    }

    /// **Linux and Windows talk to the channel through libcurl's own WebSocket
    /// interface**, everything else through `URLSession`, see ``RemoteLink``.
    /// Whoever passes in their own `URLSession` (tests) keeps it;
    /// `SWIFTLY_WS=urlsession` forces the old path.
    private func lineBuild(_ petition: URLRequest) -> any RemoteLink {
        #if os(Linux) || os(Windows)
        if !onlyURLSession, session === RemoteControl.durationSession,
           ProcessInfo.processInfo.environment["SWIFTLY_WS"] != "urlsession",
           let curl = CurlLine(petition: petition) {
            return curl
        }
        #endif
        return URLSessionLine(petition: petition, session: session)
    }

    /// Rebuilds the connection after a drop.
    ///
    /// Previously the remote control gave up for good at the first drop, assuming a
    /// network change would trigger it again. A server that restarts is no network
    /// change, though: the session then stayed silent until the app's next start.
    /// The wait doubles up to half a minute, so a permanently dead server is not
    /// hit every second.
    private func newConnect() async {
        guard let nextGift else { return }
        teardowns += 1
        let wait = min(30, 1 << min(teardowns, 5))
        try? await Task.sleep(for: .seconds(wait))
        guard !Task.isCancelled, task == nil else { return }
        start(at: nextGift)
    }

    /// **Why the connection went away, not just that it did.**
    ///
    /// The bare error is not enough. A rejected handshake arrives here as the same
    /// unremarkable network error as a server that no longer exists, and that
    /// ambiguity is expensive to debug. Two details separate the cases at once:
    ///
    /// * The **HTTP status** of the answer to the upgrade. 401 means "login
    ///   rejected" and nothing else; that is what the switch from `api_key` to
    ///   `ApiKey` would have shown.
    /// * The **close code** with its reason, if the other end closed the connection
    ///   properly instead of dropping it.
    ///
    /// If neither is available, the error stays; then it really is the network.
    private func teardownReport(_ error: Error) {
        var parts = ["[Fernsteuerung] Leitung verloren"]
        parts.append(contentsOf: task?.teardownDetails ?? [])
        parts.append("\(error)")
        TrackSupport.sag(parts.joined(separator: " · "))
    }

    /// Says once per connection that something really arrives. An established
    /// socket proves nothing; the server can accept it and then stay silent.
    private var standsAlready = false
    /// After a drop, not yet reported that something arrives.
    private var tornDownReported = false
    private func firstResponseReport() {
        guard !standsAlready else { return }
        standsAlready = true
        TrackSupport.sag("[Fernsteuerung] Leitung steht, erste Nachricht da")
        if tornDownReported {
            tornDownReported = false
            syncPlayNextGift?(.connectionAgain)
        }
    }

    public func finish() {
        standsAlready = false
        nextGift = nil          // blocks the reconnect
        teardowns = 0
        listener?.cancel(); listener = nil
        heartbeat?.cancel(); heartbeat = nil
        task?.close()
        task = nil
    }

    private func eavesdrop() {
        listener = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let task = await self.running else { return }
                do {
                    if let text = try await task.receive() {
                        await self.process(text)
                    }
                    // Something arrived, the connection is up: the count of drops starts at zero
                    // again next time.
                    await self.firstResponseReport()
                    await self.resetCounting()
                } catch is LineNotSupported {
                    // This libcurl cannot do WebSocket: old path, same behavior.
                    guard !Task.isCancelled else { return }
                    TrackSupport.sag("[Fernsteuerung] libcurl ohne WebSocket — URLSession")
                    await self.uRLSessionFallBack()
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    // **The quietest spot in the whole app, until now.** Every failure here ended
                    // without a line: wrong login, server gone, other end refuses; from outside
                    // all the same, namely "the handoff just does not work".
                    await self.teardownReport(error)
                    await self.connectionLost()
                    return
                }
            }
        }
    }

    private var running: (any RemoteLink)? { task }

    private func uRLSessionFallBack() async {
        onlyURLSession = true
        task?.close()
        task = nil
        heartbeat?.cancel(); heartbeat = nil
        if let nextGift { start(at: nextGift) }
    }

    private func resetCounting() { teardowns = 0 }

    private func connectionLost() async {
        standsAlready = false
        // SyncPlay learns of it the same way on every platform: the server drops a
        // session without a connection from the group, and the session rejoins after
        // the reconnect.
        tornDownReported = true
        syncPlayNextGift?(.connectionLost)
        task?.close()
        task = nil
        heartbeat?.cancel(); heartbeat = nil
        await newConnect()
    }

    /// A keep-alive every 30 seconds, otherwise the server cleans up.
    private func beat() {
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                // **Thirty seconds, and they do not help on Linux.**
                //
                // Separated by an experiment because the numbers alone could not: the drop
                // fell on the fourth keep-alive every time, and four times thirty is exactly
                // the 120 seconds after which it came. "After two minutes" and "after four
                // messages" could not be told apart.
                //
                // With 45 seconds they could: the connection still dropped after **exactly 120
                // seconds**, now after two keep-alives. So it is the time. The interval goes
                // back to thirty; it was never the cause.
                try? await Task.sleep(for: .seconds(30))
                // `try?` swallows the cancellation; without this line a keep-alive would still
                // go out after stopping.
                guard !Task.isCancelled, let self else { return }
                TrackSupport.sag("[Fernsteuerung] Lebenszeichen")
                await self.dispatch(#"{"MessageType":"KeepAlive"}"#)
            }
        }
    }

    /// **The `async` form, not the one with a completion block.**
    ///
    /// `send(_:completionHandler:)` exists in swift-corelibs-foundation only from
    /// a newer version; under Swift 6.0 on Linux the build fails with "extra
    /// trailing closure passed in call". That does not show on a newer toolchain.
    ///
    /// `send(_:) async throws` exists on both sides and on Apple as well. The
    /// result is discarded as before: a keep-alive that does not arrive is not
    /// resent; the other end notices the drop from the missing answer.
    private func dispatch(_ text: String) {
        guard let task else {
            TrackSupport.sag("[Fernsteuerung] nichts zu senden — keine Leitung")
            return
        }
        // **`try?` swallowed the error here.**
        //
        // On Linux the connection dropped after **exactly two minutes** with close
        // code 1002. Two minutes is twice Jellyfin's keep-alive limit; the server drops
        // whoever does not report. Our keep-alive goes out every 30 seconds and should
        // have been enough, but whether it ever arrived could not be seen, because the
        // failure ended silently here. Now it reports.
        Task {
            do {
                try await task.dispatch(text)
            } catch {
                TrackSupport.sag("[Fernsteuerung] senden fehlgeschlagen: \(error)")
            }
        }
    }

    private func process(_ text: String) {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let art = raw["MessageType"] as? String else { return }

        switch art {
        case "ForceKeepAlive":
            dispatch(#"{"MessageType":"KeepAlive"}"#)

        case "SyncPlayCommand", "SyncPlayGroupUpdate":
            if let postDirection = SyncPlayPostDirection.read(text) {
                syncPlayNextGift?(postDirection)
            } else {
                TrackSupport.sag("[SyncPlay] nicht lesbar: \(text.prefix(300))")
            }

        case "GeneralCommand":
            if let device = Self.handoffHint(raw) { handoffNextGift?(device) }

        case "Playstate":
            guard let content = raw["Data"] as? [String: Any],
                  let command = content["Command"] as? String else { return }
            let target = content["SeekPositionTicks"] as? Int64
            if let far = Self.translate(command, target: target) { nextGift?(far) }

        default:
            break
        }
    }

    /// The device name from a handoff notice, otherwise `nil`, also for any
    /// ordinary `DisplayMessage` that does not come from us.
    static func handoffHint(_ raw: [String: Any]) -> String? {
        guard let content = raw["Data"] as? [String: Any],
              content["Name"] as? String == "DisplayMessage",
              let arguments = content["Arguments"] as? [String: Any],
              arguments["Header"] as? String == Takeover.hintHeader,
              let text = arguments["Text"] as? String, !text.isEmpty else { return nil }
        return text
    }

    static func translate(_ command: String, target: Int64?) -> RemoteCommand? {
        switch command {
        case "Pause":         return .pause
        case "Unpause":       return .proceed
        case "PlayPause":     return .toggle
        case "Stop":          return .stop
        case "Seek":          return target.map { .jumpOn(Double($0) / 10_000_000) }
        case "FastForward":   return .forward
        case "Rewind":        return .back
        case "NextTrack":     return .next
        case "PreviousTrack": return .previous
        default:              return nil
        }
    }
}

extension JellyfinClient {

    /// Tells the server what this session can do.
    ///
    /// Without this call the dashboard only shows the session; the buttons for
    /// pausing and stopping stay gray.
    public func reportCapabilities() async throws {
        struct Capabilities: Encodable {
            let PlayableMediaTypes: [String]
            let SupportedCommands: [String]
            let SupportsMediaControl: Bool
            let SupportsPersistentIdentifier: Bool
        }
        // **Every name here must match the server's `GeneralCommandType`; a single
        // typo discards the whole report.**
        //
        // It used to say `Playstate`. The server knows `PlayState`, with a capital S.
        // An invalid value in the list makes the body unreadable, the call fails, and
        // **no** capability is registered, not just that one.
        //
        // The effect is not obvious from this spot: the session still appears in
        // Jellyfin, just without buttons for pausing and stopping. And
        // `Sessions?controllableByUserId=…` no longer returns it, so no other device
        // sees it; the handoff failed completely, in both directions at once.
        //
        // Checked value by value against `/api-docs/openapi.json` of the server. That
        // is the source when something is added here, not memory and not an example
        // from the web. `PlayableMediaTypes` carries `MediaType`, checked the same way.
        let body = Capabilities(
            PlayableMediaTypes: ["Video", "Audio"],
            SupportedCommands: ["Play", "PlayState", "PlayNext", "PlayMediaSource",
                                "DisplayMessage", "SetAudioStreamIndex",
                                "SetSubtitleStreamIndex", "Mute", "Unmute",
                                "ToggleMute", "SetVolume"],
            SupportsMediaControl: true,
            SupportsPersistentIdentifier: true)

        let req = try rawRequest("Sessions/Capabilities/Full", method: "POST")
        var withBody = req
        withBody.setValue("application/json", forHTTPHeaderField: "Content-Type")
        withBody.httpBody = try JSONEncoder().encode(body)

        let (_, answer) = try await rawSession.data(for: withBody)
        guard let http = answer as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw JellyfinError.transport("Fähigkeiten konnten nicht gemeldet werden.")
        }
    }

    /// A remote control for the running login.
    public func remoteControl() throws -> RemoteControl {
        let s = try requireSessionForReporting()
        return RemoteControl(base: s.serverURL, token: s.accessToken,
                             devicesIdentifier: devicesId, credential: credentialChannel)
    }
}
