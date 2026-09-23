import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// Der Weiterleiter vor VLC (Issue #4) gegen einen Vorposten im Test.
///
/// Der Vorposten hier lässt nur durch, wer `X-Vorposten: offen` mitbringt,
/// sonst 403 — wie Cloudflare Access mit einem Dienst-Token. Jeder Test
/// baut seinen eigenen auf einem eigenen Port; die Tafel der Köpfe ist
/// geteilt, der Port hält die Einträge auseinander.
///
/// **Nacheinander, und blockierend nur auf eigenen Fäden.** Die rohen
/// Steckdosen blockieren; liefen sie parallel auf dem kooperativen Pool,
/// wäre der voll, und `URLSession` im Weiterleiter käme nicht mehr dran
/// (gemessen: alle Verbindungen hingen in `warteAufAntwort`).
@Suite("Stromweiterleiter", .serialized)
struct StromweiterleiterTests {

    /// 1 MiB, jedes Byte aus seiner Stelle ableitbar.
    static let datei = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

    @Test("Ohne eingetragene Header bleibt die Adresse, wie sie ist")
    func ohneKoepfe() throws {
        let w = Stromweiterleiter()
        let u = try #require(URL(string: "https://ohne-koepfe.test/Videos/1/stream.mkv?static=true"))
        #expect(w.adresse(fuer: u) == u)
        #expect(w.aktuellerPort == 0)
    }

    @Test("Header gehen mit, der Vorposten lässt durch; direkt nicht")
    func koepfeGehenMit() throws {
        let posten = try Vorposten()
        let w = Stromweiterleiter()
        let direkt = posten.url("/Videos/1/stream.mkv?static=true&api_key=geheim")
        #expect(roh(port: posten.port, pfad: "/Videos/1/stream.mkv").status == 403)

        let umgelenkt = w.adresse(fuer: direkt)
        #expect(umgelenkt.host == "127.0.0.1")
        #expect(umgelenkt.port.map(UInt16.init) == w.aktuellerPort)
        #expect(umgelenkt.path.hasSuffix("/Videos/1/stream.mkv"))
        #expect(umgelenkt.query == "static=true&api_key=geheim")

        let a = roh(url: umgelenkt)
        #expect(a.status == 200)
        #expect(a.felder["content-length"] == "\(Self.datei.count)")
        #expect(a.koerper == Self.datei)
        #expect(posten.letzteAbfrage == "static=true&api_key=geheim")
    }

    @Test("Range geht 1:1 durch, auch auf mehreren Verbindungen gleichzeitig")
    func bereich() throws {
        let posten = try Vorposten()
        let w = Stromweiterleiter()
        let u = w.adresse(fuer: posten.url("/Videos/1/stream.mkv"))
        let fertig = DispatchSemaphore(value: 0)
        for i in 0..<6 {
            Thread {
                let von = i * 100_000 + 17, bis = von + 4_999
                let a = roh(url: u, range: "bytes=\(von)-\(bis)")
                #expect(a.status == 206)
                #expect(a.felder["content-range"] == "bytes \(von)-\(bis)/\(Self.datei.count)")
                #expect(a.felder["accept-ranges"] == "bytes")
                #expect(a.koerper == Self.datei.subdata(in: von..<(bis + 1)))
                fertig.signal()
            }.start()
        }
        for _ in 0..<6 { fertig.wait() }
    }

    @Test("Falsche Marke: 404, der Server sieht nichts")
    func falscheMarke() throws {
        let posten = try Vorposten()
        let w = Stromweiterleiter()
        let u = w.adresse(fuer: posten.url("/Videos/1/stream.mkv"))
        let marke = u.pathComponents[1]
        let falsch = String(marke.reversed())
        let a = roh(port: w.aktuellerPort, pfad: "/\(falsch)/Videos/1/stream.mkv")
        #expect(a.status == 404)
        #expect(roh(port: w.aktuellerPort, pfad: "/Videos/1/stream.mkv").status == 404)
        #expect(posten.anfragen == 0)
    }

    @Test("Schließt VLC die Verbindung, bricht die Anfrage beim Server ab")
    func abbruch() async throws {
        let posten = try Vorposten()
        let w = Stromweiterleiter()
        let u = w.adresse(fuer: posten.url("/endlos"))
        let v = try #require(Stecker.verbinden(port: UInt16(u.port ?? 0)))
        Stecker.senden(v, Data("GET \(u.path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        var puffer = [UInt8](repeating: 0, count: 65536)
        var gelesen = 0
        while gelesen < 200_000 {
            let n = Stecker.lesen(v, &puffer)
            if n <= 0 { break }
            gelesen += n
        }
        #expect(gelesen >= 200_000)
        Stecker.schliessen(v)
        // Der Vorposten merkt es, wenn sein Senden scheitert.
        for _ in 0..<100 where !posten.endlosAbgebrochen {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(posten.endlosAbgebrochen)
    }

    @Test("Liest VLC nicht (Pause), puffert der Weiterleiter nicht die ganze Datei")
    func gegendruck() async throws {
        let posten = try Vorposten()
        let w = Stromweiterleiter()
        let u = w.adresse(fuer: posten.url("/endlos"))
        let v = try #require(Stecker.verbinden(port: UInt16(u.port ?? 0)))
        defer { Stecker.schliessen(v) }
        Stecker.senden(v, Data("GET \(u.path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        var puffer = [UInt8](repeating: 0, count: 65536)
        #expect(Stecker.lesen(v, &puffer) > 0)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let a = posten.endlosGesendet
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let b = posten.endlosGesendet
        // Steht still. Meist hält das Anhalten den Server bei gut 8 MiB plus
        // Steckdosenpuffer; über Loopback liefert URLSession nach `suspend()`
        // aber manchmal noch Zig-Megabyte nach (gemessen: 72 MB gesendet).
        // Dann greift die Obergrenze, und die Anfrage endet — VLC setzt per
        // Range neu an. Gepuffert wird so oder so nicht die ganze Datei.
        #expect(b - a < 1 << 20)
        #expect(b < Stromweiterleiter.obergrenze + (16 << 20))
    }

    @Test("HLS: relative Adressen bleiben, absolute und wurzelbezogene laufen über den Weiterleiter")
    func liste() throws {
        let posten = try Vorposten()
        let w = Stromweiterleiter()
        let u = w.adresse(fuer: posten.url("/Videos/1/master.m3u8?api_key=geheim"))
        let marke = u.pathComponents[1]
        let a = roh(url: u)
        #expect(a.status == 200)
        let text = String(decoding: a.koerper, as: UTF8.self)
        let zeilen = text.components(separatedBy: "\n")
        #expect(zeilen.contains("main.m3u8?api_key=geheim"))
        #expect(zeilen.contains("/\(marke)/Videos/1/hls/0.ts"))
        #expect(zeilen.contains("http://127.0.0.1:\(w.aktuellerPort)/\(marke)/Videos/1/hls/1.ts"))
        #expect(zeilen.contains("https://fremd.test/werbung.ts"))
        #expect(text.contains("URI=\"/\(marke)/Videos/1/init.mp4\""))
        #expect(a.felder["content-length"] == "\(a.koerper.count)")
    }

    @Test("Anfragekopf: Verfahren, Ziel, Namen klein")
    func anfragekopf() throws {
        let k = try #require(Anfragekopf.zerlegen("GET /a/b?c=d HTTP/1.1\r\nRange: bytes=0-\r\nUser-Agent: VLC\r\n\r\n"))
        #expect(k.verfahren == "GET")
        #expect(k.ziel == "/a/b?c=d")
        #expect(k.koepfe["range"] == "bytes=0-")
        #expect(k.koepfe["user-agent"] == "VLC")
    }
}

// MARK: - Werkzeug

private struct Rohantwort {
    var status = 0
    var felder: [String: String] = [:]
    var koerper = Data()
}

private func roh(url: URL, range: String? = nil) -> Rohantwort {
    var pfad = url.path
    if let q = url.query { pfad += "?" + q }
    return roh(port: UInt16(url.port ?? 0), pfad: pfad, range: range)
}

/// Eine Anfrage wie VLC sie stellt, über eine rohe Steckdose.
private func roh(port: UInt16, pfad: String, range: String? = nil) -> Rohantwort {
    guard let v = Stecker.verbinden(port: port) else { return Rohantwort() }
    defer { Stecker.schliessen(v) }
    var kopf = "GET \(pfad) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUser-Agent: VLC/4.0.0\r\n"
    if let range { kopf += "Range: \(range)\r\n" }
    Stecker.senden(v, Data((kopf + "\r\n").utf8))
    var alles = Data()
    var puffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = Stecker.lesen(v, &puffer)
        if n <= 0 { break }
        alles.append(contentsOf: puffer[0..<n])
    }
    guard let trenner = alles.range(of: Data("\r\n\r\n".utf8)) else { return Rohantwort() }
    let kopftext = String(decoding: alles[..<trenner.lowerBound], as: UTF8.self)
    var a = Rohantwort()
    let zeilen = kopftext.components(separatedBy: "\r\n")
    a.status = Int(zeilen.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
    for z in zeilen.dropFirst() {
        guard let d = z.firstIndex(of: ":") else { continue }
        a.felder[z[..<d].lowercased()] = z[z.index(after: d)...].trimmingCharacters(in: .whitespaces)
    }
    a.koerper = Data(alles[trenner.upperBound...])
    return a
}

/// Ein Server hinter einem Vorposten: ohne `X-Vorposten: offen` gibt es 403.
private final class Vorposten: @unchecked Sendable {
    let port: UInt16
    private let griff: Stecker.Griff
    private let sperre = NSLock()
    private var _anfragen = 0
    private var _letzteAbfrage: String?
    private var _endlosAbgebrochen = false
    private var _endlosGesendet = 0

    var anfragen: Int { sperre.lock(); defer { sperre.unlock() }; return _anfragen }
    var letzteAbfrage: String? { sperre.lock(); defer { sperre.unlock() }; return _letzteAbfrage }
    var endlosAbgebrochen: Bool { sperre.lock(); defer { sperre.unlock() }; return _endlosAbgebrochen }
    var endlosGesendet: Int { sperre.lock(); defer { sperre.unlock() }; return _endlosGesendet }

    struct Fehler: Error {}

    init() throws {
        guard let (g, p) = Stecker.lauschen(bevorzugt: 0) else { throw Fehler() }
        griff = g
        port = p
        Eigenkoepfe.setzen([Eigenkopf(name: "X-Vorposten", wert: "offen")], fuer: url("/"))
        let t = Thread { [self] in
            while let v = Stecker.annehmen(griff) {
                Thread { self.bedienen(v); Stecker.schliessen(v) }.start()
            }
        }
        t.start()
    }

    deinit {
        Eigenkoepfe.setzen([], fuer: url("/"))
        Stecker.schliessen(griff)
    }

    func url(_ pfad: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(pfad)")! }

    private func bedienen(_ v: Stecker.Griff) {
        guard let a = Anfragekopf.lesen(v) else { return }
        guard a.koepfe["x-vorposten"] == "offen" else {
            Stecker.senden(v, Data("HTTP/1.1 403 Forbidden\r\nContent-Type: text/html\r\nContent-Length: 5\r\nConnection: close\r\n\r\nnein!".utf8))
            return
        }
        let teile = a.ziel.split(separator: "?", maxSplits: 1)
        let pfad = String(teile.first ?? "")
        sperre.lock()
        _anfragen += 1
        _letzteAbfrage = teile.count > 1 ? String(teile[1]) : nil
        sperre.unlock()

        switch pfad {
        case "/endlos":
            Stecker.senden(v, Data("HTTP/1.1 200 OK\r\nContent-Type: video/x-matroska\r\nConnection: close\r\n\r\n".utf8))
            let stueck = Data(repeating: 0x42, count: 16384)
            for _ in 0..<100_000 {
                guard Stecker.senden(v, stueck) else { break }
                sperre.lock(); _endlosGesendet += stueck.count; sperre.unlock()
            }
            sperre.lock(); _endlosAbgebrochen = true; sperre.unlock()
        case "/Videos/1/master.m3u8":
            let liste = """
            #EXTM3U
            #EXT-X-MAP:URI="/Videos/1/init.mp4"
            main.m3u8?api_key=geheim
            /Videos/1/hls/0.ts
            \(url("/Videos/1/hls/1.ts").absoluteString)
            https://fremd.test/werbung.ts
            """
            let d = Data(liste.utf8)
            Stecker.senden(v, Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(d.count)\r\nConnection: close\r\n\r\n".utf8))
            Stecker.senden(v, d)
        default:
            let datei = StromweiterleiterTests.datei
            var von = 0, bis = datei.count - 1, status = "200 OK", bereich = ""
            if let r = a.koepfe["range"], r.hasPrefix("bytes=") {
                let z = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                von = Int(z[0]) ?? 0
                if z.count > 1, let b = Int(z[1]) { bis = min(b, datei.count - 1) }
                status = "206 Partial Content"
                bereich = "Content-Range: bytes \(von)-\(bis)/\(datei.count)\r\n"
            }
            Stecker.senden(v, Data("HTTP/1.1 \(status)\r\nContent-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\n\(bereich)Content-Length: \(bis - von + 1)\r\nConnection: close\r\n\r\n".utf8))
            Stecker.senden(v, datei.subdata(in: von..<(bis + 1)))
        }
    }
}
