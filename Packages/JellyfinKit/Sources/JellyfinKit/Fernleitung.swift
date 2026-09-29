import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if os(Windows)
import WinSDK
#endif

/// **Die Leitung unter der Fernsteuerung** — ein WebSocket, gleich wie er
/// gebaut ist. Apple und Android nehmen ``URLSessionLeitung``; Linux und
/// Windows nehmen, wo es geht, ``CurlLeitung``.
///
/// Warum zwei: `URLSessionWebSocketTask` in swift-corelibs-foundation (unter
/// der Haube libcurl) wertet einen **unaufgefordert gesendeten Pong-Frame**
/// als Protokollfehler und schliesst mit 1002 / `-1005`. ASP.NET Core
/// (Jellyfin) schickt genau so einen alle `KeepAliveInterval` — vorgegeben
/// 120 Sekunden. RFC 6455 erlaubt das ausdruecklich (Abschnitt 5.5.3). Am
/// 29.09.2026 mit einem Mock-Server auf cachy nachgestellt: Abriss im selben
/// Augenblick, in dem der Pong ankommt.
protocol Fernleitung: AnyObject, Sendable {
    /// Verbindung aufbauen (nicht blockierend).
    func aufbauen()
    /// Die naechste Textnachricht. `nil`, wenn etwas anderes ankam, das
    /// trotzdem als Lebenszeichen der Gegenstelle zaehlt.
    func empfangen() async throws -> String?
    func senden(_ text: String) async throws
    func schliessen()
    /// Angaben zum Abriss fuer das Protokoll (HTTP-Status, Schliesscode …).
    var abrissAngaben: [String] { get }
}

/// Die Leitung war fuer dieses System nicht zu haben — die Fernsteuerung
/// weicht dann auf `URLSession` aus.
struct LeitungNichtUnterstuetzt: Error {}

// MARK: - URLSession

final class URLSessionLeitung: Fernleitung, @unchecked Sendable {
    private let aufgabe: URLSessionWebSocketTask

    init(anfrage: URLRequest, sitzung: URLSession) {
        aufgabe = sitzung.webSocketTask(with: anfrage)
    }

    func aufbauen() { aufgabe.resume() }

    func empfangen() async throws -> String? {
        if case let .string(text) = try await aufgabe.receive() { return text }
        return nil
    }

    func senden(_ text: String) async throws {
        try await aufgabe.send(.string(text))
    }

    func schliessen() { aufgabe.cancel(with: .goingAway, reason: nil) }

    var abrissAngaben: [String] {
        var teile: [String] = []
        if let http = aufgabe.response as? HTTPURLResponse {
            teile.append("HTTP \(http.statusCode)")
        }
        if aufgabe.closeCode != .invalid {
            var satz = "Schliesscode \(aufgabe.closeCode.rawValue)"
            if let grund = aufgabe.closeReason,
               let text = String(data: grund, encoding: .utf8), !text.isEmpty {
                satz += " (\(text))"
            }
            teile.append(satz)
        }
        return teile
    }
}

// MARK: - libcurl (Linux, Windows)

#if os(Linux) || os(Windows)

/// Was aus libcurl gebraucht wird, zur Laufzeit geladen — der Bau braucht
/// weder Header noch Bibliothek, und ein curl ohne WebSocket (vor 7.86 oder
/// ohne Unterstuetzung uebersetzt) faellt nur beim Laden auf.
struct CurlFunktionen: @unchecked Sendable {
    typealias Zeiger = UnsafeMutableRawPointer
    /// `struct curl_ws_frame { int age; int flags; curl_off_t offset;
    /// curl_off_t bytesleft; size_t len; }` — gelesen ueber Versaetze, denn
    /// ein Swift-Struct darf nicht in einen C-Prototyp.
    static let versatzFlags = 4
    static let versatzRest = 16

    let einrichten: @convention(c) () -> Zeiger?
    let aufraeumen: @convention(c) (Zeiger?) -> Void
    let optionZeiger: @convention(c) (Zeiger?, Int32, UnsafeRawPointer?) -> Int32
    let optionZahl: @convention(c) (Zeiger?, Int32, Int) -> Int32
    let ausfuehren: @convention(c) (Zeiger?) -> Int32
    let infoSocket: @convention(c) (Zeiger?, Int32, UnsafeMutablePointer<Int32>?) -> Int32
    let listeAnhaengen: @convention(c) (Zeiger?, UnsafePointer<CChar>?) -> Zeiger?
    let listeFreigeben: @convention(c) (Zeiger?) -> Void
    let wsEmpfangen: @convention(c) (Zeiger?, UnsafeMutableRawPointer?, Int, UnsafeMutablePointer<Int>?,
                                     UnsafeMutablePointer<UnsafeRawPointer?>?) -> Int32
    let wsSenden: @convention(c) (Zeiger?, UnsafeRawPointer?, Int, UnsafeMutablePointer<Int>?,
                                  Int64, UInt32) -> Int32
    let fehlertext: @convention(c) (Int32) -> UnsafePointer<CChar>?

    /// Einmal geladen, fuer das ganze Programm. `nil`: nicht verfuegbar.
    static let geladen: CurlFunktionen? = laden()

    private static func laden() -> CurlFunktionen? {
        #if os(Windows)
        var modul: HMODULE?
        for name in ["libcurl.dll", "libcurl-x64.dll", "libcurl-4.dll"] {
            modul = LoadLibraryA(name)
            if modul != nil { break }
        }
        guard let modul else { return nil }
        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            guard let p = GetProcAddress(modul, name) else { return nil }
            return unsafeBitCast(p, to: UnsafeMutableRawPointer.self)
        }
        #else
        var modul: UnsafeMutableRawPointer?
        for name in ["libcurl.so.4", "libcurl.so", "libcurl-gnutls.so.4"] {
            modul = dlopen(name, RTLD_NOW)
            if modul != nil { break }
        }
        guard let modul else { return nil }
        func symbol(_ name: String) -> UnsafeMutableRawPointer? { dlsym(modul, name) }
        #endif

        guard let a = symbol("curl_easy_init"), let b = symbol("curl_easy_cleanup"),
              let c = symbol("curl_easy_setopt"), let d = symbol("curl_easy_perform"),
              let e = symbol("curl_easy_getinfo"), let g = symbol("curl_slist_append"),
              let h = symbol("curl_slist_free_all"), let i = symbol("curl_ws_recv"),
              let j = symbol("curl_ws_send"), let k = symbol("curl_easy_strerror")
        else { return nil }
        // `curl_easy_setopt` und `curl_easy_getinfo` sind variadisch; mit
        // genau einem Argument nach dem Namen ruft es sich ueber einen
        // festen Prototyp auf x86-64 und arm64 (Linux wie Windows) gleich.
        return CurlFunktionen(
            einrichten: unsafeBitCast(a, to: (@convention(c) () -> Zeiger?).self),
            aufraeumen: unsafeBitCast(b, to: (@convention(c) (Zeiger?) -> Void).self),
            optionZeiger: unsafeBitCast(c, to: (@convention(c) (Zeiger?, Int32, UnsafeRawPointer?) -> Int32).self),
            optionZahl: unsafeBitCast(c, to: (@convention(c) (Zeiger?, Int32, Int) -> Int32).self),
            ausfuehren: unsafeBitCast(d, to: (@convention(c) (Zeiger?) -> Int32).self),
            infoSocket: unsafeBitCast(e, to: (@convention(c) (Zeiger?, Int32, UnsafeMutablePointer<Int32>?) -> Int32).self),
            listeAnhaengen: unsafeBitCast(g, to: (@convention(c) (Zeiger?, UnsafePointer<CChar>?) -> Zeiger?).self),
            listeFreigeben: unsafeBitCast(h, to: (@convention(c) (Zeiger?) -> Void).self),
            wsEmpfangen: unsafeBitCast(i, to: (@convention(c) (Zeiger?, UnsafeMutableRawPointer?, Int, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<UnsafeRawPointer?>?) -> Int32).self),
            wsSenden: unsafeBitCast(j, to: (@convention(c) (Zeiger?, UnsafeRawPointer?, Int, UnsafeMutablePointer<Int>?, Int64, UInt32) -> Int32).self),
            fehlertext: unsafeBitCast(k, to: (@convention(c) (Int32) -> UnsafePointer<CChar>?).self))
    }
}

/// **Ein WebSocket ueber libcurls eigene WS-Schnittstelle**
/// (`CONNECT_ONLY=2`, `curl_ws_recv`/`curl_ws_send`). Pong- und Ping-Frames
/// behandelt die Bibliothek selbst, ohne dass ein unaufgeforderter Pong den
/// Kanal beendet.
///
/// Ein eigener Faden liest; Senden geht von jedem Faden, beides unter einer
/// Sperre, denn ein curl-Handle ist nicht fadenfest.
final class CurlLeitung: Fernleitung, @unchecked Sendable {

    private enum Opt {
        static let url: Int32 = 10002
        static let httpheader: Int32 = 10023
        static let connectTimeout: Int32 = 78
        static let noSignal: Int32 = 99
        static let connectOnly: Int32 = 141
    }
    private static let infoActiveSocket: Int32 = 0x500000 + 44
    private static let again: Int32 = 81
    private enum Flag {
        static let text: Int32 = 1, binary: Int32 = 2, cont: Int32 = 4
        static let close: Int32 = 8, ping: Int32 = 16, pong: Int32 = 64
    }

    struct Fehler: Error, CustomStringConvertible {
        let text: String
        var description: String { text }
    }

    private let f: CurlFunktionen
    private let anfrage: URLRequest
    private let sperre = NSLock()
    private var handle: CurlFunktionen.Zeiger?
    private var kopfliste: CurlFunktionen.Zeiger?
    private var offen = false
    private var beendet = false
    private var schliesscode: Int?
    private var schliessgrund: String?
    private var letzterFehler: String?

    private let strom: AsyncThrowingStream<String?, Error>
    private let ausgang: AsyncThrowingStream<String?, Error>.Continuation
    private var leser: AsyncThrowingStream<String?, Error>.AsyncIterator

    init?(anfrage: URLRequest) {
        guard let f = CurlFunktionen.geladen, anfrage.url != nil else { return nil }
        self.f = f
        self.anfrage = anfrage
        (strom, ausgang) = AsyncThrowingStream.makeStream(of: String?.self)
        leser = strom.makeAsyncIterator()
    }

    func aufbauen() {
        let faden = Thread { [self] in lesen() }
        faden.name = "Fernleitung"
        faden.start()
    }

    func empfangen() async throws -> String? {
        guard let nachricht = try await leser.next() else {
            throw Fehler(text: "Leitung geschlossen")
        }
        return nachricht
    }

    func senden(_ text: String) async throws {
        try sendenSync(Array(text.utf8), flags: UInt32(Flag.text))
    }

    private func sendenSync(_ bytes: [UInt8], flags: UInt32) throws {
        var offset = 0
        var versuche = 0
        while offset < bytes.count || bytes.isEmpty {
            sperre.lock()
            guard offen, !beendet, let h = handle else {
                sperre.unlock()
                throw Fehler(text: "keine Leitung")
            }
            var gesendet = 0
            let rc = bytes.withUnsafeBytes { roh in
                f.wsSenden(h, roh.baseAddress.map { $0 + offset }, bytes.count - offset, &gesendet, 0, flags)
            }
            sperre.unlock()
            if rc == Self.again {
                versuche += 1
                if versuche > 200 { throw Fehler(text: "Senden blockiert") }
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            if rc != 0 { throw Fehler(text: "curl \(rc): \(meldung(rc))") }
            offset += gesendet
            if bytes.isEmpty { return }
        }
    }

    func schliessen() {
        sperre.lock()
        let war = beendet
        beendet = true
        if !war, offen, let h = handle {
            // Best effort: ordentlich mit 1001 („geht weg") verabschieden.
            let code: [UInt8] = [0x03, 0xE9]
            var gesendet = 0
            _ = code.withUnsafeBytes { f.wsSenden(h, $0.baseAddress, 2, &gesendet, 0, UInt32(Flag.close)) }
        }
        sperre.unlock()
        ausgang.finish(throwing: Fehler(text: "Leitung geschlossen"))
    }

    var abrissAngaben: [String] {
        sperre.lock(); defer { sperre.unlock() }
        var t: [String] = ["Leitung: libcurl"]
        if let c = schliesscode {
            var s = "Schliesscode \(c)"
            if let g = schliessgrund, !g.isEmpty { s += " (\(g))" }
            t.append(s)
        }
        if let e = letzterFehler { t.append(e) }
        return t
    }

    private func meldung(_ rc: Int32) -> String {
        f.fehlertext(rc).map { String(cString: $0) } ?? "?"
    }

    // MARK: Lesefaden

    private func lesen() {
        guard verbinden() else { aufraeumen(); return }
        var puffer = [UInt8](repeating: 0, count: 65_536)
        var teil = Data()
        var textAnfang = false
        while true {
            sperre.lock()
            if beendet { sperre.unlock(); break }
            guard let h = handle else { sperre.unlock(); break }
            var n = 0
            var rahmen: UnsafeRawPointer?
            let rc = f.wsEmpfangen(h, &puffer, puffer.count, &n, &rahmen)
            let flags = rahmen?.load(fromByteOffset: CurlFunktionen.versatzFlags, as: Int32.self) ?? 0
            let rest = rahmen?.load(fromByteOffset: CurlFunktionen.versatzRest, as: Int64.self) ?? 0
            sperre.unlock()

            if rc == Self.again { warten(); continue }
            if rc != 0 {
                fehlschlag("curl \(rc): \(meldung(rc))")
                break
            }
            if flags & Flag.close != 0 {
                sperre.lock()
                if n >= 2 { schliesscode = Int(puffer[0]) << 8 | Int(puffer[1]) }
                if n > 2 { schliessgrund = String(decoding: puffer[2..<n], as: UTF8.self) }
                sperre.unlock()
                fehlschlag("von der Gegenstelle geschlossen")
                break
            }
            // Ping beantwortet libcurl selbst; ein Pong ist kein Fehler.
            if flags & (Flag.ping | Flag.pong) != 0 { continue }
            if flags & Flag.text != 0 { textAnfang = true; teil.removeAll(keepingCapacity: true) }
            if textAnfang || flags & (Flag.binary | Flag.cont) != 0 { teil.append(puffer, count: n) }
            if rest == 0 && flags & Flag.cont == 0 {
                if textAnfang { ausgang.yield(String(decoding: teil, as: UTF8.self)) }
                else { ausgang.yield(nil) }
                textAnfang = false
                teil.removeAll(keepingCapacity: true)
            }
        }
        aufraeumen()
    }

    private func fehlschlag(_ text: String) {
        sperre.lock()
        letzterFehler = text
        let war = beendet
        sperre.unlock()
        if !war { ausgang.finish(throwing: Fehler(text: text)) }
    }

    /// Bis Daten kommen oder eine Viertelsekunde um ist — ohne die Sperre.
    private func warten() {
        #if os(Linux)
        var s: Int32 = -1
        sperre.lock()
        if let h = handle { _ = f.infoSocket(h, Self.infoActiveSocket, &s) }
        sperre.unlock()
        if s >= 0 {
            var p = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
            _ = poll(&p, 1, 250)
            return
        }
        #endif
        Thread.sleep(forTimeInterval: 0.025)
    }

    private func verbinden() -> Bool {
        guard let h = f.einrichten() else { fehlschlag("curl_easy_init"); return false }
        var liste: CurlFunktionen.Zeiger?
        for (name, wert) in anfrage.allHTTPHeaderFields ?? [:] {
            liste = "\(name): \(wert)".withCString { f.listeAnhaengen(liste, $0) }
        }
        let url = anfrage.url!.absoluteString
        _ = url.withCString { f.optionZeiger(h, Opt.url, $0) }
        if liste != nil { _ = f.optionZeiger(h, Opt.httpheader, UnsafeRawPointer(liste)) }
        _ = f.optionZahl(h, Opt.connectOnly, 2)
        _ = f.optionZahl(h, Opt.connectTimeout, 15)
        _ = f.optionZahl(h, Opt.noSignal, 1)

        sperre.lock()
        handle = h
        kopfliste = liste
        let schonZu = beendet
        sperre.unlock()
        if schonZu { return false }

        let rc = f.ausfuehren(h)      // Handschlag; blockiert bis zu 15 s
        if rc != 0 {
            // 1 = Protokoll unbekannt, 4 = nicht eingebaut: dieses curl kann kein WS.
            if rc == 1 || rc == 4 || rc == 48 {
                ausgang.finish(throwing: LeitungNichtUnterstuetzt())
            } else {
                fehlschlag("curl \(rc): \(meldung(rc))")
            }
            return false
        }
        sperre.lock(); offen = true; sperre.unlock()
        return true
    }

    private func aufraeumen() {
        sperre.lock()
        offen = false
        beendet = true
        let h = handle, liste = kopfliste
        handle = nil; kopfliste = nil
        sperre.unlock()
        if let h { f.aufraeumen(h) }
        if let liste { f.listeFreigeben(liste) }
    }
}

#endif
