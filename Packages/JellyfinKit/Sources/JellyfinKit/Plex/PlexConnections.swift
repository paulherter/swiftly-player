import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The address of a server that answered, and who answered under it.
public struct PlexChosenConnection: Sendable, Equatable, Codable {
    public let machineIdentifier: String
    public let uri: URL
    public let isLocal: Bool
    public let isRelay: Bool

    public init(machineIdentifier: String, uri: URL, isLocal: Bool, isRelay: Bool) {
        self.machineIdentifier = machineIdentifier; self.uri = uri
        self.isLocal = isLocal; self.isRelay = isRelay
    }
}

/// **Which address of a Plex server to use.**
///
/// plex.tv lists every way to reach a server: its LAN address, the public one, the
/// `plex.direct` host names with a certificate, and the relay (slow, throttled). The right
/// one depends on where the device is right now, so it is decided by asking, not by
/// reading a flag: order the list, then try the entries and take the best that answers.
public struct PlexConnector: Sendable {

    /// Asks one address "are you the server I want?". Replaceable so a test needs no
    /// network.
    public typealias Probe = @Sendable (PlexConnectionInfo) async -> Bool

    private let probe: Probe
    /// How long a better-ranked address may still be pending once a worse one has
    /// answered. Short: a few hundred milliseconds cost less than a dead LAN address.
    private let grace: Duration

    public init(grace: Duration = .seconds(1), probe: @escaping Probe) {
        self.probe = probe
        self.grace = grace
    }

    /// **The session of the probes: it does not wait for connectivity.** The shared
    /// ``URLSession/localNetworkCapable`` does, and with it the 3 s request timeout does
    /// not apply: an address that does not answer (a LAN address of another network, a
    /// closed port) took about 21 s to fail (measured), and the choice waited for it
    /// before taking the address that had answered in a fraction of a second.
    public static let probeSession: URLSession = {
        let k = URLSessionConfiguration.default
        k.timeoutIntervalForRequest = 6
        k.timeoutIntervalForResource = 8
        k.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: k)
    }()

    /// The real probe: `GET /identity` with a short timeout, and the machine identifier in
    /// the answer must be the one we are looking for. **Without that check** a different
    /// server answering at a recycled home address would be taken for ours (the account
    /// often holds two: an owned one and a shared one).
    public init(identity: PlexIdentity, token: String, machineIdentifier: String,
                timeout: TimeInterval = 3, urlSession: URLSession = PlexConnector.probeSession) {
        self.init { connection in
            guard let base = URL(string: connection.uri) else { return false }
            return await PlexConnector.identityMatches(
                base: base, identity: identity, token: token,
                machineIdentifier: machineIdentifier,
                timeout: connection.isRelay ? max(timeout, 6) : timeout, session: urlSession)
        }
    }

    // MARK: - Order

    /// Best first: the remembered address, then local, then remote, then relay. Within a
    /// group the plain `http` address comes before the `https` one for a LAN address (no
    /// certificate to go wrong) unless the server insists on https; IPv6 last.
    public static func ranked(_ connections: [PlexConnectionInfo],
                              httpsRequired: Bool = false,
                              remembered: URL? = nil) -> [PlexConnectionInfo] {
        func score(_ c: PlexConnectionInfo) -> Int {
            var points = 0
            if c.isRelay { points += 1000 } else if !c.isLocal { points += 100 }
            if c.isIPv6 { points += 10 }
            if httpsRequired {
                if !c.isHTTPS { points += 50 }       // would be refused anyway
            } else if c.isLocal {
                if c.isHTTPS { points += 1 }         // no certificate to go wrong on the LAN
            } else if !c.isHTTPS {
                points += 1                          // across the internet https first
            }
            if let remembered, URL(string: c.uri) == remembered { points -= 10_000 }
            return points
        }
        // `sorted` is not stable; the original index keeps equal scores in plex.tv's order.
        return connections.enumerated()
            .sorted { (score($0.element), $0.offset) < (score($1.element), $1.offset) }
            .map(\.element)
    }

    // MARK: - Choice

    /// Tries the remembered address alone first (one quick round trip on the usual path);
    /// otherwise tries all in parallel and takes **the best-ranked one that answers**, as
    /// soon as every better-ranked one has failed. Nothing answering is
    /// ``PlexError/serverUnreachable``.
    public func choose(from server: PlexServerResource,
                       remembered: PlexChosenConnection? = nil) async throws
        -> PlexChosenConnection {
        let ordered = Self.ranked(server.connections, httpsRequired: server.httpsRequired,
                                  remembered: remembered?.uri)
        guard !ordered.isEmpty else { throw PlexError.serverUnreachable }

        if let remembered, remembered.machineIdentifier == server.machineIdentifier,
           let known = ordered.first(where: { URL(string: $0.uri) == remembered.uri }),
           await probe(known) {
            return PlexChosenConnection(machineIdentifier: server.machineIdentifier,
                                        uri: remembered.uri, isLocal: known.isLocal,
                                        isRelay: known.isRelay)
        }

        // The best answering address wins. A better-ranked one that is still pending when a
        // worse one has answered gets `grace` more, then the answered one is taken.
        let grace = self.grace
        let winner: Int? = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, connection) in ordered.enumerated() {
                group.addTask { (index, await probe(connection)) }
            }
            var answered: [Int: Bool] = [:]
            var best: Int?
            var timerStarted = false
            for await (index, ok) in group {
                if index < 0 {                       // the grace ran out
                    group.cancelAll()
                    return best
                }
                answered[index] = ok
                if ok, best == nil || index < best! { best = index }
                if let candidate = best {
                    if (0..<candidate).allSatisfy({ answered[$0] == false }) {
                        group.cancelAll()
                        return candidate
                    }
                    if !timerStarted {
                        timerStarted = true
                        group.addTask { try? await Task.sleep(for: grace); return (-1, false) }
                    }
                }
            }
            return best
        }
        guard let winner, let uri = URL(string: ordered[winner].uri) else {
            throw PlexError.serverUnreachable
        }
        return PlexChosenConnection(machineIdentifier: server.machineIdentifier, uri: uri,
                                    isLocal: ordered[winner].isLocal,
                                    isRelay: ordered[winner].isRelay)
    }

    // MARK: - Probe

    static func identityMatches(base: URL, identity: PlexIdentity, token: String,
                                machineIdentifier: String, timeout: TimeInterval,
                                session: URLSession) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("identity"))
        req.timeoutInterval = timeout
        for (name, value) in identity.headers(token: token) { req.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let answer = try? JSONDecoder().decode(PlexEnvelope<PlexListing>.self, from: data)
        else { return false }
        return answer.container.machineIdentifier == machineIdentifier
    }
}
