import Darwin
import Foundation
import JellyfinKit
import SwiftlyCore

/// **The socket half of the server search.** The core decides what to ask, whom, and what the answers
/// mean (`LegacyLogin.serverSearch`); this only owns one UDP socket per round: send to a target, then
/// read what comes back until the time is up.
private final class BroadcastSocket: DatagramHost, @unchecked Sendable {
    private let handle: Int32

    init() {
        handle = socket(AF_INET, SOCK_DGRAM, 0)
        var one: Int32 = 1
        if handle >= 0 { _ = setsockopt(handle, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size)) }
    }

    deinit { if handle >= 0 { close(handle) } }

    func send(payload: Data, target: UInt32, port: UInt16) -> Bool {
        guard handle >= 0 else { return false }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = target.bigEndian
        a.sin_port = port.bigEndian
        let size = MemoryLayout<sockaddr_in>.size
        let n = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { to in
                payload.withUnsafeBytes { sendto(handle, $0.baseAddress, payload.count, 0, to, socklen_t(size)) }
            }
        }
        return n == payload.count
    }

    func receive(seconds: UInt32) -> [Data] {
        guard handle >= 0 else { return [] }
        // One-second steps, so the deadline is kept to the second without a timer.
        var limit = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        var answers: [Data] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < end {
            let n = recv(handle, &buffer, buffer.count, 0)
            if n > 0 { answers.append(Data(buffer[0..<n])) }
        }
        return answers
    }
}

extension AccountsHost {
    /// Every interface that is up, has IPv4 and is not the loopback (host byte order).
    private nonisolated static func interfaces() -> [DiscoverInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [DiscoverInterface] = []
        var next: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = next?.pointee {
            next = entry.ifa_next
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            let a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            found.append(DiscoverInterface(address: UInt32(bigEndian: a), netmask: UInt32(bigEndian: m)))
        }
        return found
    }

    /// The servers on the network as a growing list, one value per round that found something new,
    /// until the consumer stops. The core merges the rounds; here only the loop and the pause.
    nonisolated static func watchServers() -> AsyncStream<[FoundServer]> {
        AsyncStream { continuation in
            let task = Task.detached {
                let login = await MainActor.run { try? AccountsHost.shared.legacyForSearch() }
                guard let login else { continuation.finish(); return }
                let pause = UInt64(max(login.serverSearchPause(), 1000)) * 1_000_000
                var known: [FoundServer] = []
                while !Task.isCancelled {
                    let text = login.serverSearch(
                        socket: BroadcastSocket(), interfaces: interfaces(),
                        known: Self.encode(known), except: "[]")
                    let now = Self.decode(text)
                    if now != known {
                        known = now
                        continuation.yield(known)
                    }
                    try? await Task.sleep(nanoseconds: pause)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func encode(_ list: [FoundServer]) -> String {
        let rows = list.map { ["id": $0.id, "name": $0.name, "adresse": $0.address] }
        return (try? String(data: JSONSerialization.data(withJSONObject: rows), encoding: .utf8)) ?? "[]"
    }

    private nonisolated static func decode(_ text: String) -> [FoundServer] {
        struct Row: Decodable { let id: String; let name: String; let adresse: String }
        let rows = (try? JSONDecoder().decode([Row].self, from: Data(text.utf8))) ?? []
        return rows.map { FoundServer(id: $0.id, name: $0.name, address: $0.adresse) }
    }
}
