import Foundation
import JellyfinKit
import Network

/// **Wie VLC die Serveradresse sieht — ins Protokoll, bei jedem Start.**
///
/// Bilder laden über `URLSession`, der Strom über VLCs eigene Sockets. Geht
/// das eine und das andere nicht, liegt der Unterschied genau zwischen diesen
/// beiden Wegen — und der zeigt sich nur auf dem Gerät des Nutzers, in
/// seinem Netz, mit seinem VPN. Gemeldet am 22.09.2026: iPhone über ein
/// selbst gehostetes NetBird, Server unter einer privaten `http`-Adresse,
/// Bilder da, Wiedergabe lädt endlos.
///
/// Die Probe macht dasselbe wie VLCs `vlc_h1_request`
/// (`modules/access/http/h1conn.c`): `getaddrinfo` mit `SOCK_STREAM` und
/// `IPPROTO_TCP`, ohne weitere Flags, dann ein gewöhnlicher `connect` auf
/// die erste Antwort. Sie schreibt drei Dinge:
///
/// - **welche Adressen herauskommen** — steht dort statt `10.x` eine
///   IPv6-Adresse, hat das System sie für ein reines IPv6-Netz (NAT64)
///   umgeschrieben, und das Paket läuft am VPN vorbei;
/// - **was der Socket sagt** — „No route to host" sofort spricht für eine
///   Sperre (Lokales Netzwerk), eine Wartezeit ohne Antwort für einen Weg,
///   auf dem nichts ankommt;
/// - **über welche Strecken das Gerät gerade geht** (`utun` ist das VPN).
///
/// VLC selbst wartet beim Verbinden ohne Frist (`vlc_tls_WaitConnect`,
/// `poll` mit -1) — erst der Kern gibt nach gut einer Minute auf. Daher das
/// endlose Laden; die Probe hat ihre eigene Frist.
enum Netzprobe {

    static func starten(_ url: URL) {
        guard let host = url.host, let schema = url.scheme?.lowercased(),
              schema == "http" || schema == "https" else { return }
        let port = url.port ?? (schema == "https" ? 443 : 80)
        Protokoll.schreib("[Netzprobe] Strom: \(url.ohneGeheimnis)")
        DispatchQueue.global(qos: .utility).async {
            strecken()
            verbinden(host: host, port: port)
        }
    }

    private static func strecken() {
        let wache = NWPathMonitor()
        let fertig = DispatchSemaphore(value: 0)
        wache.pathUpdateHandler = { pfad in
            let namen = pfad.availableInterfaces.map(\.name).joined(separator: ",")
            Protokoll.schreib("[Netzprobe] Strecken: \(namen) · Status \(pfad.status)"
                + " · IPv4 \(pfad.supportsIPv4 ? "ja" : "nein") · IPv6 \(pfad.supportsIPv6 ? "ja" : "nein")")
            fertig.signal()
        }
        wache.start(queue: DispatchQueue(label: "de.paulherter.swiftly.netzprobe"))
        _ = fertig.wait(timeout: .now() + 2)
        wache.cancel()
    }

    private static func verbinden(host: String, port: Int) {
        var hinweise = addrinfo()
        hinweise.ai_socktype = SOCK_STREAM
        hinweise.ai_protocol = IPPROTO_TCP
        var ergebnis: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hinweise, &ergebnis)
        guard rc == 0, let erste = ergebnis else {
            Protokoll.schreib("[Netzprobe] \(host): Auflösung scheitert: \(String(cString: gai_strerror(rc)))")
            return
        }
        defer { freeaddrinfo(erste) }

        var adressen: [String] = []
        var zeiger: UnsafeMutablePointer<addrinfo>? = erste
        while let eintrag = zeiger {
            adressen.append(numerisch(eintrag.pointee.ai_addr, eintrag.pointee.ai_addrlen))
            zeiger = eintrag.pointee.ai_next
        }
        Protokoll.schreib("[Netzprobe] \(host):\(port) → \(adressen.joined(separator: ", "))")

        let a = erste.pointee
        let fd = socket(a.ai_family, a.ai_socktype, a.ai_protocol)
        guard fd >= 0 else {
            Protokoll.schreib("[Netzprobe] Socket: \(String(cString: strerror(errno)))")
            return
        }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let beginn = Date()
        let ms = { Int(Date().timeIntervalSince(beginn) * 1000) }
        if connect(fd, a.ai_addr, a.ai_addrlen) != 0 {
            guard errno == EINPROGRESS else {
                Protokoll.schreib("[Netzprobe] connect \(adressen[0]): \(String(cString: strerror(errno))) nach \(ms()) ms")
                return
            }
            var warte = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&warte, 1, 8000) > 0 else {
                Protokoll.schreib("[Netzprobe] connect \(adressen[0]): keine Antwort in 8 s")
                return
            }
            var fehler: Int32 = 0
            var laenge = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &fehler, &laenge)
            guard fehler == 0 else {
                Protokoll.schreib("[Netzprobe] connect \(adressen[0]): \(String(cString: strerror(fehler))) nach \(ms()) ms")
                return
            }
        }
        Protokoll.schreib("[Netzprobe] connect \(adressen[0]): verbunden nach \(ms()) ms")
    }

    private static func numerisch(_ adresse: UnsafeMutablePointer<sockaddr>?, _ laenge: socklen_t) -> String {
        guard let adresse else { return "?" }
        var puffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(adresse, laenge, &puffer, socklen_t(puffer.count), nil, 0, NI_NUMERICHOST) == 0
        else { return "?" }
        return String(cString: puffer)
    }
}
