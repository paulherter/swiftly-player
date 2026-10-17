import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// **The wire to Discord: what is playing, shown in the user's own profile.**
///
/// Discord does not accept this over the network but through a local socket
/// that its desktop app provides on the same machine. No key, no account, no
/// sign-in: if Discord is open, the wire exists; if not, it does not. That is
/// also why nothing here can go wrong in a way that harms anyone: there is no
/// server that anything would be sent to.
///
/// **What is deliberately not sent.** The image URLs of this server carry
/// `ApiKey` in plain text (see ``Adressgeheimnis``). Handing a poster to
/// Discord would publish the server access, to a place that caches and
/// forwards it. So the Swiftly logo and text are shown instead. Anyone who
/// wants to change that first needs an address without a key, not the other
/// way round.
///
/// The connection is an extra and must never be in the way: every error ends
/// here and is reported through ``TrackSupport``, nothing else. No throwing outward,
/// no waiting, no retrying every second.
///
/// # On the Mac this does not work in the App Store, and not for lack of
/// # effort
///
/// Both routes were tried, not reasoned about:
///
/// **The socket is the right way, and the sandbox blocks it.** From a program
/// without a sandbox it works fine; Discord accepts the handshake and confirms
/// `SET_ACTIVITY` with what it will display. A sandboxed app gets its
/// **own** folder inside its container as `TMPDIR`, so it looks in the wrong
/// place; and with the right path, `/var/folders/<random>/T/discord-ipc-0`, the
/// sandbox does not allow the connection. It cannot be named as an exception
/// either because of the random part.
///
/// **The network route would be allowed and does not work.** Discord listens
/// on 6463 to 6472, and the app may connect there. But with our origin it
/// rejects with `4001 Invalid Origin`, and with an allowed one the connection
/// opens and **stays silent**: no `READY`, no answer. That route is meant for
/// extensions with OAuth approval, not for a status display.
///
/// That leaves only a build **without** the sandbox for the Mac, i.e. outside
/// the App Store. Linux and Windows do not have the question.
///
/// Anyone who revisits this: the two measurements above are the starting
/// point, not the assumption that it might work somehow.
/// **On Windows the wire is a named pipe, not a socket.**
///
/// `\\.\pipe\discord-ipc-0`, otherwise the **same protocol**: the same frame of
/// opcode and length, the same handshake, the same frames. Only `CreateFileW`
/// and `WriteFile` replace `socket` and `write`.
///
/// And one difference that makes it simpler: there is only **one** location.
/// Pipes hang off no folder that packaging could move, so the search for
/// Flatpak and Snap locations does not apply.
#if os(Windows)
import WinSDK

public actor DiscordBridge {

    private let hostApp: String
    private var pipe: HANDLE?

    public init(hostApp: String) {
        self.hostApp = hostApp
    }

    private func linkUp() -> Bool {
        if pipe != nil { return true }
        for n in 0...9 {
            let distance = #"\\.\pipe\discord-ipc-"# + String(n)
            let grip = distance.withCString(encodedAs: UTF16.self) { pointer in
                // **`GENERIC_READ` is `UInt32`, `GENERIC_WRITE` is `Int32`.** Swift's WinSDK
                // mapping types the two differently; the OR takes the type of the left
                // value, and the right one then does not fit. Verified on Windows, not
                // guessed from the error.
                //
                // And the obvious shortcut does not work:
                // `DWORD(bitPattern: GENERIC_READ | GENERIC_WRITE)` is already `UInt32`, and
                // `DWORD(bitPattern:)` wants `Int32`. The conversion belongs around the
                // **right** value.
                CreateFileW(pointer,
                            GENERIC_READ | DWORD(bitPattern: GENERIC_WRITE),
                            0, nil, DWORD(OPEN_EXISTING), 0, nil)
            }
            guard let grip, grip != INVALID_HANDLE_VALUE else {
                // **The first failed attempt tells whether the call is built correctly.**
                //
                // Without this line it cannot even be shown that `CreateFileW` was tried.
                // With it, a single value separates the two cases that otherwise look the
                // same: **2** (`ERROR_FILE_NOT_FOUND`) means "the pipe is not there, the call
                // is fine", anything else means "the call is built wrong". That makes the
                // Windows path measurable without Discord, which is the point: not having to
                // install Discord to check something that can be checked another way.
                if n == 0 {
                    TrackSupport.sag("[Discord] Roehre 0 nicht zu oeffnen, "
                             + "GetLastError=\(GetLastError()) "
                             + "(2 = nicht da, alles andere = Aufruf falsch)")
                }
                continue
            }
            pipe = grip
            if dispatch(0, ["v": 1, "client_id": hostApp]) {
                TrackSupport.sag("[Discord] verbunden ueber \(distance)")
                return true
            }
            CloseHandle(grip)
            pipe = nil
        }
        TrackSupport.sag("[Discord] keine Roehre gefunden — zehn Nummern abgesucht")
        return false
    }

    /// The same frame as on Unix: opcode and length as four bytes each,
    /// little-endian, then the body.
    private func dispatch(_ grip: UInt32, _ content: [String: Any]) -> Bool {
        guard let pipe,
              let data = try? JSONSerialization.data(withJSONObject: content) else { return false }
        var header = Data()
        var g = grip.littleEndian
        var l = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &g) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &l) { header.append(contentsOf: $0) }
        let everything = header + data
        return everything.withUnsafeBytes { raw -> Bool in
            var since = 0
            while since < raw.count {
                var written: DWORD = 0
                let ok = WriteFile(pipe,
                                   raw.baseAddress!.advanced(by: since),
                                   DWORD(raw.count - since), &written, nil)
                if !ok || written == 0 { return false }
                since += Int(written)
            }
            return true
        }
    }

    private func disconnect() {
        if let pipe { CloseHandle(pipe) }
        pipe = nil
    }

    public func showItem(_ display: DiscordDisplay?) {
        guard linkUp() else { return }
        var arg: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier)]
        if let display { arg["activity"] = display.asWordsBook }
        let frameRect: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": arg,
            "nonce": UUID().uuidString,
        ]
        if !dispatch(1, frameRect) {
            TrackSupport.sag("[Discord] Roehre weg, wird beim naechsten Mal neu aufgebaut")
            disconnect()
        }
    }

    public func close() {
        guard pipe != nil else { return }
        _ = dispatch(2, [:])
        disconnect()
    }
}


#elseif os(Android)

/// **On Android there is nothing to talk to.** Discord shows "watching ..."
/// only through its desktop app, which has no socket on a phone or TV. The same
/// interface, without effect; otherwise the package fails to compile on
/// `socket` and `sockaddr_un`, which Bionic does not offer under `Glibc`.
public actor DiscordBridge {
    public init(hostApp: String) {}
    public func showItem(_ display: DiscordDisplay?) {}
    public func close() {}
}

#else

public actor DiscordBridge {

    /// The application under which Discord shows the status. Its name appears to
    /// the user as "watching ...", its icon is the large image.
    private let hostApp: String
    private var wire: Int32 = -1
    private var connected = false

    public init(hostApp: String) {
        self.hostApp = hostApp
    }

    // MARK: Connecting

    /// **Ten possible locations, and that is not excessive.**
    ///
    /// Discord numbers its sockets (`discord-ipc-0` to `-9`); if one instance is
    /// already running, the next takes 1. Depending on how Discord is installed,
    /// they live elsewhere: under Flatpak in its own runtime folder, under Snap in
    /// its own. Anyone who checks only one place got it working on their own
    /// machine and not for half of the users.
    private func set() -> [String] {
        let env = ProcessInfo.processInfo.environment
        var root: [String] = []
        #if os(macOS)
        // On the Mac it lives in the session's temporary folder.
        root.append(env["TMPDIR"] ?? NSTemporaryDirectory())
        #else
        if let x = env["XDG_RUNTIME_DIR"] { root.append(x) }
        root.append(contentsOf: [env["TMPDIR"], env["TMP"], env["TEMP"], "/tmp"].compactMap { $0 })
        if let x = env["XDG_RUNTIME_DIR"] {
            root.append("\(x)/app/com.discordapp.Discord")   // Flatpak
            root.append("\(x)/snap.discord")                 // Snap
        }
        #endif
        var routes: [String] = []
        for w in root {
            let clean = w.hasSuffix("/") ? String(w.dropLast()) : w
            for n in 0...9 { routes.append("\(clean)/discord-ipc-\(n)") }
        }
        return routes
    }

    private func open(_ distance: String) -> Int32 {
        // A Unix path in `sockaddr_un` is limited to 104 characters. Longer does not
        // mean "fails" but "silently truncated", and then you connect to something
        // else or to nothing.
        guard distance.utf8.count < 104 else { return -1 }
        // **`SOCK_STREAM` is not the same on both systems.** On Linux it is an
        // enumeration with `rawValue`, on Darwin already an `Int32`. Both are handled
        // here.
        #if canImport(Glibc)
        let art = Int32(SOCK_STREAM.rawValue)
        #else
        let art = SOCK_STREAM
        #endif
        let fd = socket(AF_UNIX, art, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            distance.utf8.enumerated().forEach { target[$0.offset] = $0.element }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        if ok != 0 { closeDescriptor(fd); return -1 }
        return fd
    }

    // MARK: Frames

    private enum Handle: UInt32 { case handshake = 0, frameRect = 1, closing = 2 }

    private func dispatch(_ grip: Handle, _ content: [String: Any]) -> Bool {
        guard wire >= 0,
              let data = try? JSONSerialization.data(withJSONObject: content) else { return false }
        var header = Data()
        var g = grip.rawValue.littleEndian
        var l = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &g) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &l) { header.append(contentsOf: $0) }
        let everything = header + data
        return everything.withUnsafeBytes { raw -> Bool in
            var since = 0
            while since < raw.count {
                let n = write(wire, raw.baseAddress!.advanced(by: since), raw.count - since)
                if n <= 0 { return false }
                since += n
            }
            return true
        }
    }

    /// Connects if necessary. Returns whether a connection exists afterwards.
    private func safeSet() -> Bool {
        if connected, wire >= 0 { return true }
        for distance in set() {
            let fd = open(distance)
            guard fd >= 0 else { continue }
            wire = fd
            if dispatch(.handshake, ["v": 1, "client_id": hostApp]) {
                connected = true
                alreadyComplained = false
                TrackSupport.sag("[Discord] verbunden ueber \(distance)")
                return true
            }
            closeDescriptor(fd); wire = -1
        }
        // **A failure says something too.** Without it, "Discord is not running"
        // could not be told apart from "Discord never asks us at all", an
        // ambiguity that is hard to debug.
        //
        // Once per attempt, not on every tick: otherwise it fills the log whenever
        // Discord is not open.
        if !alreadyComplained {
            alreadyComplained = true
            let routes = set()
            TrackSupport.sag("[Discord] keine Steckdose gefunden — \(routes.count) Stellen "
                     + "abgesucht, zuerst \(routes.first ?? "—")")
        }
        return false
    }

    /// So the complaint comes once and not on every tick.
    private var alreadyComplained = false

    private func disconnect() {
        if wire >= 0 { closeDescriptor(wire) }
        wire = -1
        connected = false
    }

    // MARK: Showing

    /// Sets what is in the profile. `nil` clears the display.
    public func showItem(_ display: DiscordDisplay?) {
        guard safeSet() else { return }
        var arg: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier)]
        if let display { arg["activity"] = display.asWordsBook }
        let frameRect: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": arg,
            "nonce": UUID().uuidString,
        ]
        TrackSupport.sag("[Discord] sende: \(display.map(\.shortVersion) ?? "nichts")")
        if !dispatch(.frameRect, frameRect) {
            // Discord quit, connection dead. Rebuild next time, not here in a loop, which
            // would be a counter without purpose.
            TrackSupport.sag("[Discord] Leitung weg, wird beim naechsten Mal neu aufgebaut")
            disconnect()
        }
    }

    public func close() {
        guard connected else { return }
        _ = dispatch(.closing, [:])
        disconnect()
    }
}


/// The C `close`, out of reach of the `close()` methods of the types above.
private func closeDescriptor(_ fd: Int32) { _ = close(fd) }

#endif

/// **What is in the profile.**
///
/// Deliberately without SwiftUI and without knowledge of ``Item``: the three
/// platform versions that use this build their lines themselves, on the Mac
/// from an `Item`, on Linux and Windows from what the player knows.
public struct DiscordDisplay: Sendable {

    /// The bold line. The movie, or for a series its name.
    public let title: String
    /// The line below. For a series "S2:E1 · Episode name", otherwise empty.
    public let subline: String?
    /// Start and end of the current playback as points in time.
    ///
    /// **Discord draws the bar itself** from these two numbers; no progress is
    /// sent, certainly not every second. When paused, send them away: a bar that
    /// keeps running while the picture is still is worse than none.
    public let from: Date?
    public let until: Date?

    public init(title: String, subline: String? = nil, from: Date? = nil, until: Date? = nil) {
        self.title = title
        self.subline = subline
        self.from = from
        self.until = until
    }

    /// **The icon as an address, not as a stored name.**
    ///
    /// The usual way is to upload an image in the developer portal and name it
    /// here. That turned out worse: the portal now only offers background, cover
    /// image and preview video, all the wrong formats, and the classic images
    /// could no longer be found. Counter-checked: `oauth2/applications/<id>/assets`
    /// returned **zero** entries, and Discord silently discarded `large_image`.
    ///
    /// Discord does accept an **address** and fetches it itself; the reply echoes
    /// it as `mp:external/…`. So nobody has to touch a portal, and the icon is the
    /// same one the Linux version uses as its application icon: one file, not two
    /// that can drift apart.
    ///
    /// It points into the public repository. If that is renamed, the image stays
    /// empty; the rest of the display still works.
    static let symbolText = "https://raw.githubusercontent.com/paulherter/swiftly-player/main/Linux/Ressourcen/icons/hicolor/512x512/apps/de.paulherter.swiftly.png"

    /// For the log: what goes out, in one line.
    var shortVersion: String {
        let extentSpan = (from != nil && until != nil)
            ? "Balken \(Int(until!.timeIntervalSince(from!))) s"
            : "ohne Balken"
        return "\(title) · \(subline ?? "—") · \(extentSpan)"
    }

    var asWordsBook: [String: Any] {
        var d: [String: Any] = [
            // 3 means "watching". Discord knows playing, streaming, listening, watching
            // and competing; for a video player it is this one.
            "type": 3,
            "details": title,
            "assets": ["large_image": Self.symbolText, "large_text": "Swiftly Player"],
        ]
        if let subline, !subline.isEmpty { d["state"] = subline }
        if let from, let until {
            d["timestamps"] = ["start": Int(from.timeIntervalSince1970 * 1000),
                               "end": Int(until.timeIntervalSince1970 * 1000)]
        }
        return d
    }
}

extension DiscordDisplay: Equatable {
    /// **To the second, not to the instant.**
    ///
    /// The timestamps are built from `Date()` and the position in the movie;
    /// between two ticks they drift by fractions even if nothing changed. A
    /// comparison on `Date` would therefore **always** differ, the guard against
    /// needless sending would do nothing, and several frames per second would go
    /// out to Discord.
    public static func == (a: Self, b: Self) -> Bool {
        func secondUnit(_ d: Date?) -> Int? { d.map { Int($0.timeIntervalSince1970) } }
        return a.title == b.title && a.subline == b.subline
            && secondUnit(a.from) == secondUnit(b.from) && secondUnit(a.until) == secondUnit(b.until)
    }
}
