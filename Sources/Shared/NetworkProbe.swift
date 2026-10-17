import Foundation
import JellyfinKit
import Network

/// **How VLC sees the server address: logged at every launch.**
///
/// Images load via `URLSession`, the stream over VLC's own sockets. If one
/// works and the other does not, the difference lies exactly between these
/// two paths, and it shows only on the user's device, in their network,
/// with their VPN. Seen with a phone on a self-hosted VPN mesh and a server
/// at a private `http` address: images present, playback loading forever.
///
/// The probe does the same as VLC's `vlc_h1_request`
/// (`modules/access/http/h1conn.c`): `getaddrinfo` with `SOCK_STREAM` and
/// `IPPROTO_TCP`, no other flags, then a plain `connect` on the first
/// result. It writes three things:
///
/// - **which addresses come out**: if an IPv6 address shows instead of
/// `10.x`, the system rewrote it for an IPv6-only network (NAT64), and the
/// packet bypasses the VPN;
/// - **what the socket says**: an immediate "No route to host" points to a
/// block (Local Network permission), a wait without an answer to a path on
/// which nothing arrives;
/// - **which interfaces the device is currently using** (`utun` is the VPN).
///
/// VLC itself waits without a deadline when connecting
/// (`vlc_tls_WaitConnect`, `poll` with -1); only the kernel gives up after
/// a good minute. Hence the endless loading; the probe has its own
/// deadline.
enum NetworkProbe {

    static func start(_ url: URL) {
        guard let host = url.host, let schema = url.scheme?.lowercased(),
              schema == "http" || schema == "https" else { return }
        let port = url.port ?? (schema == "https" ? 443 : 80)
        AppLog.writeOut("[Netzprobe] Strom: \(url.withoutSecret)")
        DispatchQueue.global(qos: .utility).async {
            legs()
            linkUp(host: host, port: port)
        }
    }

    private static func legs() {
        let sentry = NWPathMonitor()
        let done = DispatchSemaphore(value: 0)
        sentry.pathUpdateHandler = { path in
            let names = path.availableInterfaces.map(\.name).joined(separator: ",")
            AppLog.writeOut("[Netzprobe] Strecken: \(names) · Status \(path.status)"
                + " · IPv4 \(path.supportsIPv4 ? "ja" : "nein") · IPv6 \(path.supportsIPv6 ? "ja" : "nein")")
            done.signal()
        }
        sentry.start(queue: DispatchQueue(label: "de.paulherter.swiftly.netzprobe"))
        _ = done.wait(timeout: .now() + 2)
        sentry.cancel()
    }

    private static func linkUp(host: String, port: Int) {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let first = result else {
            AppLog.writeOut("[Netzprobe] \(host): Auflösung scheitert: \(String(cString: gai_strerror(rc)))")
            return
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let entryRecord = pointer {
            addresses.append(numeric(entryRecord.pointee.ai_addr, entryRecord.pointee.ai_addrlen))
            pointer = entryRecord.pointee.ai_next
        }
        AppLog.writeOut("[Netzprobe] \(host):\(port) → \(addresses.joined(separator: ", "))")

        let a = first.pointee
        let fd = socket(a.ai_family, a.ai_socktype, a.ai_protocol)
        guard fd >= 0 else {
            AppLog.writeOut("[Netzprobe] Socket: \(String(cString: strerror(errno)))")
            return
        }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let beginning = Date()
        let ms = { Int(Date().timeIntervalSince(beginning) * 1000) }
        if connect(fd, a.ai_addr, a.ai_addrlen) != 0 {
            guard errno == EINPROGRESS else {
                AppLog.writeOut("[Netzprobe] connect \(addresses[0]): \(String(cString: strerror(errno))) nach \(ms()) ms")
                return
            }
            var holdOn = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&holdOn, 1, 8000) > 0 else {
                AppLog.writeOut("[Netzprobe] connect \(addresses[0]): keine Antwort in 8 s")
                return
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else {
                AppLog.writeOut("[Netzprobe] connect \(addresses[0]): \(String(cString: strerror(error))) nach \(ms()) ms")
                return
            }
        }
        AppLog.writeOut("[Netzprobe] connect \(addresses[0]): verbunden nach \(ms()) ms")
    }

    private static func numeric(_ address: UnsafeMutablePointer<sockaddr>?, _ length: socklen_t) -> String {
        guard let address else { return "?" }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
        else { return "?" }
        return String(cString: buffer)
    }
}
