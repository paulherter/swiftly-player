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
}
