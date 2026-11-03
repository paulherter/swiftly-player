import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

/// A Jellyfin server that answered on the local network.
///
/// The keys are the server's own (`Id`, `Name`, `Address`), the answer of
/// `UdpServerEntryPoint` in Jellyfin. `EndpointAddress` is left out: it is empty
/// unless the server is behind something that rewrites it.
public struct FoundServer: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// A full base address, "http://192.168.1.5:8096", as the server publishes it.
    public let address: String

    /// **The address as a person would say it**: "192.168.1.5:8096", without the
    /// scheme. The row shows this; the field gets the full ``address``.
    public var shortAddress: String {
        var text = address
        for scheme in ["http://", "https://"] where text.lowercased().hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    public init(id: String, name: String, address: String) {
        self.id = id
        self.name = name
        self.address = address
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case address = "Address"
    }
}

/// **Finding the server instead of typing its address.**
///
/// Jellyfin listens on UDP 7359 for the sentence "who is JellyfinServer?" and
/// answers the sender with a ``FoundServer``. The web client, the Android app and
/// Swiftfin ask the same way, so no server setting is involved: whoever has not
/// switched off "Enable auto discovery" is found.
///
/// **A broadcast, not a sweep of the subnet.** On iPhone, iPad and Apple TV that
/// needs `com.apple.developer.networking.multicast`; without it `sendto` fails
/// there and the list stays empty, while everything else keeps working. The
/// sentence goes to 255.255.255.255 and, on Apple, also to the broadcast address
/// of every interface: on a Mac with a VPN the default route is the tunnel, and
/// 255.255.255.255 would leave through it and reach nobody.
public enum ServerDiscovery {
    public static let port: UInt16 = 7359
    static let question = "who is JellyfinServer?"

    /// How long one round listens for answers. A server on the same network answers
    /// within milliseconds; the rest is slack for Wi-Fi waking up.
    public static let listening = 2
    /// The pause between rounds while the page is open. The first round on iOS
    /// usually goes nowhere, because the system is still asking for permission to
    /// use the local network; and a server may be switched on while the page is open.
    public static let pause: Duration = .seconds(8)

    /// One answer. `nil` for anything that is not a usable server: another program on
    /// the port, a server without address.
    public static func read(_ data: Data) -> FoundServer? {
        guard let server = try? JSONDecoder().decode(FoundServer.self, from: data),
              !server.id.isEmpty,
              AppModelURLNormalizer.normalize(server.address) != nil
        else { return nil }
        return server
    }

    /// **One entry per server, in a stable order.** Every round asks again, and a
    /// server with two interfaces answers once on each; its `Id` is the same. The
    /// latest answer wins (the address may have changed), the order is by name so
    /// the rows do not jump when a round finishes.
    public static func merged(_ known: [FoundServer], _ new: [FoundServer]) -> [FoundServer] {
        var byID: [String: FoundServer] = [:]
        for server in known + new { byID[server.id] = server }
        return byID.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// **What the page shows**: without the server whose address is already in the
    /// field or under "Zuletzt verbunden". Compared by host and port, so
    /// "192.168.1.5:8096" and "http://192.168.1.5:8096/" are the same server.
    public static func shown(_ found: [FoundServer], except addresses: [String?]) -> [FoundServer] {
        let taken = Set(addresses.compactMap { $0.flatMap(key) })
        return found.filter { key($0.address).map { !taken.contains($0) } ?? false }
    }

    private static func key(_ address: String) -> String? {
        guard let url = AppModelURLNormalizer.normalize(address), let host = url.host() else { return nil }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        return "\(host.lowercased()):\(port)"
    }

    /// **The broadcast address of an interface**: its address with all host bits set.
    /// Both in host byte order.
    static func broadcast(address: UInt32, netmask: UInt32) -> UInt32 {
        address | ~netmask
    }

    /// The servers on the network, as a growing list, one value per round that found
    /// something new. Runs until the consumer stops listening.
    public static func watch() -> AsyncStream<[FoundServer]> {
        AsyncStream { continuation in
            let task = Task {
                var found: [FoundServer] = []
                while !Task.isCancelled {
                    let now = merged(found, await search())
                    if now != found {
                        found = now
                        continuation.yield(found)
                    }
                    try? await Task.sleep(for: pause)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One round: ask, listen for ``listening`` seconds. Empty when nothing answers or
    /// the network refuses the broadcast.
    public static func search() async -> [FoundServer] {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: Datagram.ask(question, port: port,
                                                            seconds: listening).compactMap(read))
            }
            thread.name = "Serversuche"
            thread.start()
        }
    }
}

// MARK: - Sockets, per platform

/// The UDP half next to ``Plug``: one socket, the sentence to every broadcast
/// address, then whatever comes back until the time is up.
private enum Datagram {
    static func ask(_ sentence: String, port: UInt16, seconds: Int) -> [Data] {
        #if os(Windows)
        _ = Plug.winsock
        let g = socket(AF_INET, SOCK_DGRAM, 0)
        guard g != INVALID_SOCKET else { return [] }
        var one: DWORD = 1
        _ = withUnsafePointer(to: &one) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4) {
                setsockopt(g, SOL_SOCKET, SO_BROADCAST, $0, Int32(MemoryLayout<DWORD>.size))
            }
        }
        #else
        #if canImport(Glibc) && !os(Android)
        let g = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        let g = socket(AF_INET, SOCK_DGRAM, 0)
        #endif
        guard g >= 0 else { return [] }
        var one: Int32 = 1
        _ = setsockopt(g, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        defer { Plug.close(g) }

        var sent = false
        for target in targets() {
            sent = send(g, sentence, to: target, port: port) || sent
        }
        guard sent else { return [] }

        // One-second steps, so the deadline is kept to the second without a timer.
        Plug.readDeadline(g, seconds: 1)
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        var answers: [Data] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < end {
            let n = Plug.read(g, &buffer)
            if n > 0 { answers.append(Data(buffer[0..<n])) }
        }
        return answers
    }

    /// 255.255.255.255 always; on Apple also the broadcast address of every interface
    /// that is up, has IPv4 and is not the loopback. Host byte order.
    private static func targets() -> [UInt32] {
        var all: [UInt32] = [UInt32.max]
        #if canImport(Darwin)
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return all }
        defer { freeifaddrs(list) }
        var next: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = next?.pointee {
            next = entry.ifa_next
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            let a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let target = ServerDiscovery.broadcast(address: UInt32(bigEndian: a), netmask: UInt32(bigEndian: m))
            if !all.contains(target) { all.append(target) }
        }
        #endif
        return all
    }

    private static func send(_ g: Plug.Handle, _ sentence: String, to target: UInt32, port: UInt16) -> Bool {
        var a = sockaddr_in()
        #if canImport(Darwin)
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        #if os(Windows)
        a.sin_family = ADDRESS_FAMILY(AF_INET)
        a.sin_addr.S_un.S_addr = target.bigEndian
        #else
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = target.bigEndian
        #endif
        a.sin_port = port.bigEndian
        let bytes = Array(sentence.utf8)
        let size = MemoryLayout<sockaddr_in>.size
        let n = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { to in
                bytes.withUnsafeBytes { p -> Int in
                    // Bionic declares the buffer non-null, the other C libraries optional.
                    guard let base = p.baseAddress else { return -1 }
                    #if os(Windows)
                    return Int(sendto(g, base.assumingMemoryBound(to: CChar.self),
                                      Int32(p.count), 0, to, Int32(size)))
                    #else
                    return sendto(g, base, p.count, 0, to, socklen_t(size))
                    #endif
                }
            }
        }
        return n == bytes.count
    }
}
