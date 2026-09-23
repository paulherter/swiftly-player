import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

/// **Der Weiterleiter vor dem Player — für Server hinter einem Vorposten.**
///
/// Cloudflare Access, Authelia, Authentik oder Pangolin lassen nur durch, wer
/// bestimmte Header mitbringt (``Eigenkoepfe``). API, Bilder und Downloads
/// laufen über `URLSession` und tragen sie. **VLC kann das nicht:** libVLC
/// setzt über Optionen nur User-Agent, Referrer und Kekse, keine beliebigen
/// Header — der Strom kam deshalb nie am Vorposten vorbei (Issue #4).
///
/// Also holt die App den Strom selbst: ein kleiner HTTP-Dienst auf
/// `127.0.0.1:<zufälliger Port>` nimmt VLCs Anfrage entgegen, holt dieselbe
/// Adresse beim Server — mit den Headern — und reicht Status, die Header, die
/// VLC zum Spulen braucht, und den Körper **gestreamt** durch.
///
/// - **Nur wenn Header eingetragen sind.** Sonst gibt ``adresse(fuer:)`` die
///   Adresse unverändert zurück, und VLC spricht wie immer direkt mit dem
///   Server. Für fast alle ändert sich nichts.
/// - **Nur an 127.0.0.1**, und jeder Server bekommt eine zufällige Marke
///   (128 Bit) als ersten Pfadteil. Eine andere App auf dem Gerät erreicht
///   den Port, kennt die Marke aber nicht und bekommt 404.
/// - **Eine Verbindung, ein Faden.** VLC öffnet fürs Spulen und für
///   Untertitel eigene Verbindungen; jede läuft für sich, blockierend, und
///   endet mit `Connection: close`.
/// - **Range geht 1:1 durch**, `Content-Range` und `Content-Length` kommen
///   unverändert zurück. Beim stückweisen Holen (unten) setzt der
///   Weiterleiter sie aus der Gesamtlänge so zusammen, wie VLC gefragt hat.
/// - **Kein Puffern ganzer Dateien.** Liest VLC nicht (Pause), hält der
///   Weiterleiter auf Apple die Anfrage beim Server an, sobald 8 MiB warten.
///   Wächst der Vorrat über 64 MiB, bricht er ab; VLC setzt mit
///   `:http-reconnect` und einem Range an genau der Stelle neu an. Auf
///   Linux und Windows (swift-corelibs) hält `suspend()` nichts an, und
///   `cancel()` wirkt erst, wenn schon viel mehr geladen ist (über Loopback
///   unter Last Hunderte MB). Dort holt er deshalb in Stücken von 16 MiB,
///   jedes mit eigenem Range, das nächste erst, wenn VLC das vorige
///   abgenommen hat. Nur wenn der Server Range nicht bedient, bleibt die
///   Obergrenze.
/// - **Abbruch:** schließt VLC die Verbindung, scheitert das nächste Senden,
///   und die Anfrage beim Server wird abgebrochen.
/// - **HLS:** relative Segmentadressen laufen von selbst über den
///   Weiterleiter. Absolute und wurzelbezogene (`/…`) schreibt er in
///   Wiedergabelisten um.
///
/// **Derselbe Code auf Apple, Linux und Windows** — nur
/// BSD-Sockets und `URLSession`, keine weitere Abhängigkeit. Network.framework
/// gibt es nur auf Apple, SwiftNIO wäre für einen Dienst mit einer Handvoll
/// Verbindungen eine schwere Abhängigkeit im Android-Kern. Android selbst
/// nimmt ihn nicht mehr: dort liest ein Weiterleiter über OkHttp blockierend,
/// sodass Pause und Abbruch sofort wirken (`Android/handy/…/Stromweiterleiter.kt`).
public final class Stromweiterleiter: @unchecked Sendable {

    /// Der eine für die App. Tests bauen sich eigene.
    public static let gemeinsam = Stromweiterleiter()

    /// Wohin der Weiterleiter meldet, was er tut — **nie Werte, nie Abfragen**,
    /// nur Verfahren, Pfad und Status. Die App hängt ihr Protokoll daran.
    public nonisolated(unsafe) static var protokoll: (@Sendable (String) -> Void)?

    private let sperre = NSLock()
    private var lauscher: Stecker.Griff?
    private var port: UInt16 = 0
    /// Marke → Ursprung (`https://rechner[:port]`), und zurück.
    private var ursprungFuerMarke: [String: String] = [:]
    private var markeFuerUrsprung: [String: String] = [:]
    private let sitzung: URLSession
    private let verteiler = Verteiler()

    init() {
        let k = URLSessionConfiguration.default
        k.urlCache = nil
        k.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Leerlauf, nicht Gesamtdauer: ein Film läuft Stunden.
        k.timeoutIntervalForRequest = 60
        k.httpMaximumConnectionsPerHost = 16
        let schlange = OperationQueue()
        schlange.maxConcurrentOperationCount = 1
        sitzung = URLSession(configuration: k, delegate: verteiler, delegateQueue: schlange)
    }

    // MARK: Adresse

    /// Die Adresse, die VLC bekommen soll.
    ///
    /// Unverändert, wenn für den Server keine Header eingetragen sind, wenn
    /// sie kein `http(s)` ist (Downloads liegen als Datei vor) oder wenn der
    /// Weiterleiter nicht lauschen kann — dann scheitert die Wiedergabe am
    /// Vorposten wie bisher, statt gar nicht erst zu beginnen.
    public func adresse(fuer url: URL) -> URL {
        guard !Eigenkoepfe.fuer(url).isEmpty,
              let k = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let schema = k.scheme?.lowercased(), schema == "http" || schema == "https",
              let rechner = k.percentEncodedHost, !rechner.isEmpty
        else { return url }
        let ursprung = "\(schema)://\(rechner)" + (k.port.map { ":\($0)" } ?? "")

        sperre.lock()
        defer { sperre.unlock() }
        guard let port = lauschenGesperrt() else { return url }
        let marke: String
        if let m = markeFuerUrsprung[ursprung] {
            marke = m
        } else {
            marke = Self.neueMarke()
            markeFuerUrsprung[ursprung] = marke
            ursprungFuerMarke[marke] = ursprung
        }
        let pfad = k.percentEncodedPath.isEmpty ? "/" : k.percentEncodedPath
        let abfrage = k.percentEncodedQuery.map { "?" + $0 } ?? ""
        return URL(string: "http://127.0.0.1:\(port)/\(marke)\(pfad)\(abfrage)") ?? url
    }

    /// Der Port, auf dem gerade gelauscht wird — 0, solange nicht.
    var aktuellerPort: UInt16 {
        sperre.lock(); defer { sperre.unlock() }
        return lauscher == nil ? 0 : port
    }

    /// Aus VLCs Anfragepfad die Adresse beim Server — `nil` bei falscher Marke.
    func ziel(fuer anfragepfad: String) -> (url: URL, marke: String)? {
        guard anfragepfad.hasPrefix("/") else { return nil }
        let ohne = anfragepfad.dropFirst()
        let ende = ohne.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? ohne.endIndex
        let marke = String(ohne[..<ende])
        var rest = String(ohne[ende...])
        if !rest.hasPrefix("/") { rest = "/" + rest }
        sperre.lock()
        let ursprung = ursprungFuerMarke[marke]
        sperre.unlock()
        guard let ursprung, let url = URL(string: ursprung + rest) else { return nil }
        return (url, marke)
    }

    private static func neueMarke() -> String {
        var zufall = SystemRandomNumberGenerator()
        return (0..<16).map { _ in
            let b = UInt8.random(in: 0...255, using: &zufall)
            return String(b, radix: 16).count == 1 ? "0" + String(b, radix: 16) : String(b, radix: 16)
        }.joined()
    }

    // MARK: Lauschen

    /// Startet den Lauscher, falls er nicht läuft. **Aufrufer hält die Sperre.**
    ///
    /// Nach einem Neustart zuerst derselbe Port: iOS nimmt einer
    /// ausgesetzten App die Lauschsteckdose weg, und VLC hält vielleicht noch
    /// eine Adresse mit dem alten Port.
    private func lauschenGesperrt() -> UInt16? {
        if lauscher != nil { return port }
        guard let (griff, neu) = Stecker.lauschen(bevorzugt: port) else {
            Self.protokoll?("[Weiterleiter] Lauschen gescheitert")
            return nil
        }
        lauscher = griff
        port = neu
        Self.protokoll?("[Weiterleiter] lauscht auf 127.0.0.1:\(neu)")
        let t = Thread { [weak self] in self?.annehmen(griff) }
        t.name = "Stromweiterleiter"
        t.start()
        return neu
    }

    private func annehmen(_ griff: Stecker.Griff) {
        while true {
            guard let verbindung = Stecker.annehmen(griff) else {
                if Stecker.nochmal() { continue }
                sperre.lock()
                if lauscher == griff { lauscher = nil }
                sperre.unlock()
                Stecker.schliessen(griff)
                Self.protokoll?("[Weiterleiter] Lauscher beendet")
                return
            }
            let t = Thread { [weak self] in
                self?.bedienen(verbindung)
                Stecker.schliessen(verbindung)
            }
            t.name = "Stromweiterleiter.Verbindung"
            t.start()
        }
    }

    // MARK: Eine Verbindung

    /// Wartende Bytes, ab denen die Anfrage beim Server angehalten wird.
    static let anhaltenAb = 8 << 20
    /// … und ab denen sie weiterläuft.
    static let weiterAb = 2 << 20
    /// Harte Grenze: darüber wird abgebrochen, VLC setzt per Range neu an.
    static let obergrenze = 64 << 20
    /// Wiedergabelisten sind klein; größer ist keine.
    static let listengrenze = 4 << 20

    private func bedienen(_ v: Stecker.Griff) {
        Stecker.lesefrist(v, sekunden: 30)
        guard let anfrage = Anfragekopf.lesen(v) else { return }
        guard anfrage.verfahren == "GET" || anfrage.verfahren == "HEAD" else {
            Stecker.senden(v, Self.kopf(405, ["Allow": "GET, HEAD"], laenge: 0)); return
        }
        guard let (url, marke) = ziel(fuer: anfrage.ziel) else {
            Self.protokoll?("[Weiterleiter] fremde Marke abgewiesen")
            Stecker.senden(v, Self.kopf(404, [:], laenge: 0)); return
        }

        var r = URLRequest(url: url)
        r.httpMethod = anfrage.verfahren
        // Unverändert durch, was fürs Spulen zählt. Alles andere (Kekse,
        // Icy-MetaData) bleibt draußen.
        for name in ["Range", "If-Range", "User-Agent", "Accept"] {
            if let w = anfrage.koepfe[name.lowercased()] { r.setValue(w, forHTTPHeaderField: name) }
        }
        // Sonst packt URLSession aus und Content-Length stimmt nicht mehr.
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        Eigenkoepfe.anwenden(auf: &r)

        // Wo `suspend()` nicht anhält (swift-corelibs), wird in Stücken
        // geholt: jede Anfrage beim Server trägt einen begrenzten Range, und
        // das nächste Stück kommt erst, wenn VLC das vorige abgenommen hat.
        // Liest VLC nicht, liegt beim Server keine offene Anfrage mehr —
        // ohne dass es auf `cancel()` ankommt, das dort spät wirkt.
        let erbeten = Leitung.anhaltenWirkt || anfrage.verfahren != "GET"
            || url.pathExtension.lowercased() == "m3u8"
            ? nil : Self.bereichLesen(anfrage.koepfe["range"])
        if let e = erbeten {
            r.setValue("bytes=\(e.von)-\(Self.stueckEnde(ab: e.von, bis: e.bis))",
                       forHTTPHeaderField: "Range")
        }

        let leitung = Leitung()
        let aufgabe = starten(r, leitung)
        defer { aufgabe.cancel() }

        let pfad = url.path
        guard let antwort = leitung.warteAufAntwort() else {
            Self.protokoll?("[Weiterleiter] \(anfrage.verfahren) \(pfad) → keine Antwort vom Server")
            Stecker.senden(v, Self.kopf(502, [:], laenge: 0)); return
        }
        let bereich = anfrage.koepfe["range"].map { " \($0)" } ?? ""
        Self.protokoll?("[Weiterleiter] \(anfrage.verfahren) \(pfad)\(bereich) → \(antwort.statusCode)")

        var felder: [String: String] = [:]
        for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges",
                     "Last-Modified", "ETag"] {
            if let w = antwort.value(forHTTPHeaderField: name) { felder[name] = w }
        }
        if antwort.value(forHTTPHeaderField: "Content-Encoding") != nil {
            felder["Content-Length"] = nil
        }
        var status = antwort.statusCode

        // Stückweise nur, wenn der Server den Range genau so bedient hat.
        // Sonst (200 ohne Range, Gesamtlänge unbekannt) läuft es wie bisher
        // in einem Zug, mit der Obergrenze als letztem Halt.
        var weiter: (ab: Int, bis: Int)?
        if let e = erbeten, status == 206,
           let teil = Self.inhaltsbereichLesen(antwort.value(forHTTPHeaderField: "Content-Range")),
           teil.von == e.von {
            let bis = min(e.bis ?? teil.gesamt - 1, teil.gesamt - 1)
            if anfrage.koepfe["range"] == nil {
                status = 200
                felder["Content-Range"] = nil
                felder["Content-Length"] = String(teil.gesamt)
            } else {
                felder["Content-Range"] = "bytes \(e.von)-\(bis)/\(teil.gesamt)"
                felder["Content-Length"] = String(bis - e.von + 1)
            }
            if teil.bis < bis { weiter = (teil.bis + 1, bis) }
        }

        if anfrage.verfahren == "HEAD" {
            Stecker.senden(v, Self.kopf(status, felder, laenge: nil)); return
        }

        let typ = (felder["Content-Type"] ?? "").lowercased()
        if typ.contains("mpegurl") || url.pathExtension.lowercased() == "m3u8" {
            guard let roh = leitung.alles(bis: Self.listengrenze) else {
                Stecker.senden(v, Self.kopf(502, [:], laenge: 0)); return
            }
            let text = String(decoding: roh, as: UTF8.self)
            let neu = Data(listeUmschreiben(text, marke: marke).utf8)
            felder["Content-Length"] = nil
            Stecker.senden(v, Self.kopf(status, felder, laenge: neu.count))
            Stecker.senden(v, neu)
            return
        }

        guard Stecker.senden(v, Self.kopf(status, felder, laenge: nil)) else { return }
        var gesendet = 0
        guard weitergeben(leitung, an: v, pfad: pfad, gesendet: &gesendet) else { return }

        // Die weiteren Stücke. Ändert sich die Datei dazwischen, antwortet
        // der Server auf If-Range mit 200 — dann endet die Verbindung, und
        // VLC setzt mit `:http-reconnect` neu an.
        if r.value(forHTTPHeaderField: "If-Range") == nil {
            if let etag = felder["ETag"], !etag.hasPrefix("W/") {
                r.setValue(etag, forHTTPHeaderField: "If-Range")
            } else if let datum = felder["Last-Modified"] {
                r.setValue(datum, forHTTPHeaderField: "If-Range")
            }
        }
        while let w = weiter {
            let ab = w.ab, bis = w.bis
            let ende = Self.stueckEnde(ab: ab, bis: bis)
            r.setValue("bytes=\(ab)-\(ende)", forHTTPHeaderField: "Range")
            let l = Leitung()
            let a = starten(r, l)
            defer { a.cancel() }
            guard let antw = l.warteAufAntwort(), antw.statusCode == 206,
                  let teil = Self.inhaltsbereichLesen(antw.value(forHTTPHeaderField: "Content-Range")),
                  teil.von == ab, teil.bis >= ab else {
                Self.protokoll?("[Weiterleiter] \(pfad) Stück ab \(ab) nicht bedient")
                return
            }
            guard weitergeben(l, an: v, pfad: pfad, gesendet: &gesendet) else { return }
            weiter = teil.bis < bis ? (teil.bis + 1, bis) : nil
        }
    }

    /// Stückgröße, wo nur so gebremst werden kann.
    static let stueck = 16 << 20

    private func starten(_ r: URLRequest, _ leitung: Leitung) -> URLSessionTask {
        let aufgabe = sitzung.dataTask(with: r)
        leitung.aufgabe = aufgabe
        verteiler.eintragen(leitung, fuer: aufgabe)
        aufgabe.resume()
        return aufgabe
    }

    /// Alles aus der Leitung an VLC; `false`, wenn VLC nicht mehr liest.
    private func weitergeben(_ leitung: Leitung, an v: Stecker.Griff, pfad: String,
                             gesendet: inout Int) -> Bool {
        while let stueck = leitung.naechstes() {
            guard Stecker.senden(v, stueck) else {
                Self.protokoll?("[Weiterleiter] \(pfad) abgebrochen nach \(gesendet) Bytes")
                return false
            }
            gesendet += stueck.count
        }
        return true
    }

    /// Letztes Byte des Stücks ab `von`, höchstens bis `bis`.
    static func stueckEnde(ab von: Int, bis: Int?) -> Int {
        let ende = von + stueck - 1
        return bis.map { min($0, ende) } ?? ende
    }

    /// `Range` von VLC: ohne Kopf alles ab 0, sonst `bytes=N-` oder
    /// `bytes=N-E`. Suffix und mehrere Bereiche: `nil`, geht in einem Zug.
    static func bereichLesen(_ w: String?) -> (von: Int, bis: Int?)? {
        guard let w else { return (0, nil) }
        let t = w.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("bytes="), !t.contains(",") else { return nil }
        let z = t.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard z.count == 2, let von = Int(z[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let hinten = z[1].trimmingCharacters(in: .whitespaces)
        if hinten.isEmpty { return (von, nil) }
        guard let bis = Int(hinten), bis >= von else { return nil }
        return (von, bis)
    }

    /// `Content-Range: bytes A-B/T` mit bekannter Gesamtlänge.
    static func inhaltsbereichLesen(_ w: String?) -> (von: Int, bis: Int, gesamt: Int)? {
        guard let w, w.hasPrefix("bytes ") else { return nil }
        let z = w.dropFirst(6).split(separator: "/")
        guard z.count == 2, let gesamt = Int(z[1]) else { return nil }
        let b = z[0].split(separator: "-")
        guard b.count == 2, let von = Int(b[0]), let bis = Int(b[1]),
              von <= bis, bis < gesamt else { return nil }
        return (von, bis, gesamt)
    }

    // MARK: Wiedergabelisten

    /// Absolute Adressen und wurzelbezogene Pfade in einer HLS-Liste auf den
    /// Weiterleiter umbiegen. Relative bleiben, wie sie sind — VLC löst sie
    /// gegen die Adresse der Liste auf, und die zeigt schon hierher.
    func listeUmschreiben(_ text: String, marke: String) -> String {
        func umbiegen(_ a: String) -> String {
            if a.hasPrefix("/") && !a.hasPrefix("//") { return "/\(marke)\(a)" }
            let klein = a.lowercased()
            if klein.hasPrefix("http://") || klein.hasPrefix("https://"), let u = URL(string: a) {
                return adresse(fuer: u).absoluteString
            }
            return a
        }
        let zeilen = text.split(separator: "\n", omittingEmptySubsequences: false).map { roh -> String in
            var zeile = String(roh)
            let cr = zeile.hasSuffix("\r")
            if cr { zeile.removeLast() }
            let getrimmt = zeile.trimmingCharacters(in: .whitespaces)
            if getrimmt.isEmpty {
                // bleibt
            } else if getrimmt.hasPrefix("#") {
                // URI="…" in EXT-X-MAP, EXT-X-MEDIA, EXT-X-KEY …
                if let a = zeile.range(of: "URI=\""),
                   let e = zeile[a.upperBound...].firstIndex(of: "\"") {
                    let alt = String(zeile[a.upperBound..<e])
                    zeile.replaceSubrange(a.upperBound..<e, with: umbiegen(alt))
                }
            } else {
                zeile = umbiegen(getrimmt)
            }
            return cr ? zeile + "\r" : zeile
        }
        return zeilen.joined(separator: "\n")
    }

    // MARK: Antwortkopf

    static func kopf(_ status: Int, _ felder: [String: String], laenge: Int?) -> Data {
        let grund: String
        switch status {
        case 200: grund = "OK"
        case 206: grund = "Partial Content"
        case 404: grund = "Not Found"
        case 405: grund = "Method Not Allowed"
        case 502: grund = "Bad Gateway"
        default: grund = "Status"
        }
        var s = "HTTP/1.1 \(status) \(grund)\r\n"
        for (n, w) in felder.sorted(by: { $0.key < $1.key }) { s += "\(n): \(w)\r\n" }
        if let laenge { s += "Content-Length: \(laenge)\r\n" }
        s += "Connection: close\r\n\r\n"
        return Data(s.utf8)
    }
}

// MARK: - Anfrage lesen

struct Anfragekopf {
    let verfahren: String
    let ziel: String
    /// Namen klein geschrieben.
    let koepfe: [String: String]

    /// Bis zur Leerzeile lesen. Mehr als 64 KiB Kopf ist keine VLC-Anfrage.
    static func lesen(_ v: Stecker.Griff) -> Anfragekopf? {
        var puffer = [UInt8]()
        let ende: [UInt8] = [13, 10, 13, 10]
        var stueck = [UInt8](repeating: 0, count: 4096)
        while puffer.count < 65536 {
            let n = Stecker.lesen(v, &stueck)
            guard n > 0 else { return nil }
            puffer.append(contentsOf: stueck[0..<n])
            if puffer.count >= 4, let _ = puffer.indices.dropLast(3).first(where: {
                puffer[$0] == ende[0] && puffer[$0 + 1] == ende[1]
                    && puffer[$0 + 2] == ende[2] && puffer[$0 + 3] == ende[3]
            }) { return zerlegen(String(decoding: puffer, as: UTF8.self)) }
        }
        return nil
    }

    static func zerlegen(_ text: String) -> Anfragekopf? {
        let zeilen = text.components(separatedBy: "\r\n")
        let erste = zeilen.first?.split(separator: " ") ?? []
        guard erste.count >= 2 else { return nil }
        var koepfe: [String: String] = [:]
        for z in zeilen.dropFirst() {
            guard let d = z.firstIndex(of: ":") else { continue }
            let n = z[..<d].trimmingCharacters(in: .whitespaces).lowercased()
            koepfe[n] = z[z.index(after: d)...].trimmingCharacters(in: .whitespaces)
        }
        return Anfragekopf(verfahren: String(erste[0]), ziel: String(erste[1]), koepfe: koepfe)
    }
}

// MARK: - Zwischen URLSession und dem Faden einer Verbindung

/// Was vom Server kommt, wartet hier, bis der Faden es an VLC sendet.
final class Leitung: @unchecked Sendable {
    /// **Anhalten nur auf Apple.** In swift-corelibs-foundation (Android,
    /// Linux, Windows) hält `suspend()` die Übertragung nicht an — gemessen
    /// auf Android: angehalten bei 8 MiB, danach kamen weiter Daten — und
    /// ein danach abgebrochener Auftrag meldete nie sein Ende. Dort holt
    /// der Weiterleiter in Stücken (``Stromweiterleiter/stueck``); die
    /// Obergrenze bleibt für Server, die Range nicht bedienen.
    #if canImport(Darwin)
    static let anhaltenWirkt = true
    #else
    static let anhaltenWirkt = false
    #endif

    private let bedingung = NSCondition()
    private var antwort: HTTPURLResponse?
    private var stuecke: [Data] = []
    private var wartend = 0
    private var fertig = false
    private var angehalten = false
    weak var aufgabe: URLSessionTask?

    func antwortDa(_ a: URLResponse) {
        bedingung.lock()
        antwort = a as? HTTPURLResponse
        if antwort == nil { fertig = true }
        bedingung.broadcast(); bedingung.unlock()
    }

    func daten(_ d: Data) {
        bedingung.lock()
        // Nach dem Abbruch liefert URLSession noch nach, was schon in der
        // Schlange stand — das wird nicht mehr gesendet, also nicht gehalten.
        guard !fertig else { bedingung.unlock(); return }
        stuecke.append(d)
        wartend += d.count
        if wartend > Stromweiterleiter.obergrenze {
            fertig = true
            aufgabe?.cancel()
        } else if Self.anhaltenWirkt && !angehalten && wartend > Stromweiterleiter.anhaltenAb {
            angehalten = true
            aufgabe?.suspend()
        }
        bedingung.broadcast(); bedingung.unlock()
    }

    func ende() {
        bedingung.lock()
        fertig = true
        bedingung.broadcast(); bedingung.unlock()
    }

    func warteAufAntwort() -> HTTPURLResponse? {
        bedingung.lock(); defer { bedingung.unlock() }
        while antwort == nil && !fertig { bedingung.wait() }
        return antwort
    }

    /// Das nächste Stück, `nil` am Ende.
    func naechstes() -> Data? {
        bedingung.lock(); defer { bedingung.unlock() }
        while stuecke.isEmpty && !fertig { bedingung.wait() }
        guard !stuecke.isEmpty else { return nil }
        let d = stuecke.count == 1 ? stuecke[0] : stuecke.reduce(into: Data()) { $0.append($1) }
        stuecke.removeAll(keepingCapacity: true)
        wartend = 0
        if angehalten && wartend < Stromweiterleiter.weiterAb {
            angehalten = false
            aufgabe?.resume()
        }
        return d
    }

    /// Den ganzen Körper — nur für Wiedergabelisten.
    func alles(bis grenze: Int) -> Data? {
        var d = Data()
        while let s = naechstes() {
            d.append(s)
            if d.count > grenze { return nil }
        }
        return d
    }
}

/// Der eine Delegat der Sitzung; ordnet jeden Rückruf seiner Leitung zu.
final class Verteiler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let sperre = NSLock()
    private var leitungen: [Int: Leitung] = [:]

    func eintragen(_ l: Leitung, fuer a: URLSessionTask) {
        sperre.lock(); leitungen[a.taskIdentifier] = l; sperre.unlock()
    }

    private func leitung(_ a: URLSessionTask) -> Leitung? {
        sperre.lock(); defer { sperre.unlock() }
        return leitungen[a.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        leitung(dataTask)?.antwortDa(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        leitung(dataTask)?.daten(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        sperre.lock()
        let l = leitungen.removeValue(forKey: task.taskIdentifier)
        sperre.unlock()
        l?.ende()
    }
}

// MARK: - Steckdosen, je Plattform

/// Das Wenige an BSD-Sockets, das der Weiterleiter braucht. Winsock heißt
/// fast gleich, nimmt aber andere Typen.
enum Stecker {
    #if os(Windows)
    typealias Griff = SOCKET
    private static let winsock: Void = {
        var d = WSADATA()
        _ = WSAStartup(0x0202, &d)
    }()
    #else
    typealias Griff = Int32
    #endif

    /// An 127.0.0.1 binden, bevorzugt an `bevorzugt`, sonst an einen freien Port.
    static func lauschen(bevorzugt: UInt16) -> (Griff, UInt16)? {
        if bevorzugt != 0, let g = lauschen(port: bevorzugt) { return g }
        return lauschen(port: 0)
    }

    private static func lauschen(port: UInt16) -> (Griff, UInt16)? {
        #if os(Windows)
        _ = winsock
        let g = socket(AF_INET, SOCK_STREAM, 0)
        guard g != INVALID_SOCKET else { return nil }
        #else
        #if canImport(Glibc) && !os(Android)
        let g = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let g = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard g >= 0 else { return nil }
        var eins: Int32 = 1
        _ = setsockopt(g, SOL_SOCKET, SO_REUSEADDR, &eins, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var a = sockaddr_in()
        #if canImport(Darwin)
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        #if os(Windows)
        a.sin_family = ADDRESS_FAMILY(AF_INET)
        #else
        a.sin_family = sa_family_t(AF_INET)
        #endif
        a.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)

        let groesse = MemoryLayout<sockaddr_in>.size
        let gebunden = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                bind(g, $0, Int32(groesse)) == 0
                #else
                bind(g, $0, socklen_t(groesse)) == 0
                #endif
            }
        }
        guard gebunden, listen(g, 16) == 0 else { schliessen(g); return nil }

        var b = sockaddr_in()
        #if os(Windows)
        var l = Int32(groesse)
        #else
        var l = socklen_t(groesse)
        #endif
        _ = withUnsafeMutablePointer(to: &b) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(g, $0, &l) }
        }
        return (g, UInt16(bigEndian: b.sin_port))
    }

    /// Zu 127.0.0.1 verbinden — nur für die Tests, die VLC spielen.
    static func verbinden(port: UInt16) -> Griff? {
        #if os(Windows)
        _ = winsock
        let g = socket(AF_INET, SOCK_STREAM, 0)
        guard g != INVALID_SOCKET else { return nil }
        #elseif canImport(Glibc) && !os(Android)
        let g = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard g >= 0 else { return nil }
        #else
        let g = socket(AF_INET, SOCK_STREAM, 0)
        guard g >= 0 else { return nil }
        #endif
        var a = sockaddr_in()
        #if canImport(Darwin)
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var eins: Int32 = 1
        _ = setsockopt(g, SOL_SOCKET, SO_NOSIGPIPE, &eins, socklen_t(MemoryLayout<Int32>.size))
        #endif
        #if os(Windows)
        a.sin_family = ADDRESS_FAMILY(AF_INET)
        #else
        a.sin_family = sa_family_t(AF_INET)
        #endif
        a.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)
        let groesse = MemoryLayout<sockaddr_in>.size
        let ok = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                connect(g, $0, Int32(groesse)) == 0
                #else
                connect(g, $0, socklen_t(groesse)) == 0
                #endif
            }
        }
        guard ok else { schliessen(g); return nil }
        return g
    }

    static func annehmen(_ g: Griff) -> Griff? {
        let v = accept(g, nil, nil)
        #if os(Windows)
        guard v != INVALID_SOCKET else { return nil }
        #else
        guard v >= 0 else { return nil }
        #if canImport(Darwin)
        var eins: Int32 = 1
        _ = setsockopt(v, SOL_SOCKET, SO_NOSIGPIPE, &eins, socklen_t(MemoryLayout<Int32>.size))
        #endif
        #endif
        return v
    }

    /// Ein unterbrochenes `accept` ist kein Ende.
    static func nochmal() -> Bool {
        #if os(Windows)
        return false
        #else
        return errno == EINTR || errno == ECONNABORTED
        #endif
    }

    static func lesefrist(_ g: Griff, sekunden: Int) {
        #if os(Windows)
        var ms = DWORD(sekunden * 1000)
        _ = withUnsafePointer(to: &ms) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4) {
                setsockopt(g, SOL_SOCKET, SO_RCVTIMEO, $0, Int32(MemoryLayout<DWORD>.size))
            }
        }
        #else
        var t = timeval()
        t.tv_sec = .init(sekunden)
        #if os(Android) && arch(arm)
        // 32-Bit-Android (viele Fernseher): dort ist `SO_RCVTIMEO` ein Makro mit
        // `sizeof`, das Swift nicht importiert. time_t ist hier 32 Bit, also gilt der alte Wert.
        let option = SO_RCVTIMEO_OLD
        #else
        let option = SO_RCVTIMEO
        #endif
        _ = setsockopt(g, SOL_SOCKET, option, &t, socklen_t(MemoryLayout<timeval>.size))
        #endif
    }

    static func lesen(_ g: Griff, _ puffer: inout [UInt8]) -> Int {
        let anzahl = puffer.count
        return puffer.withUnsafeMutableBytes { p in
            #if os(Windows)
            Int(recv(g, p.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(anzahl), 0))
            #else
            recv(g, p.baseAddress, anzahl, 0)
            #endif
        }
    }

    /// Alles senden. `false`, sobald die Gegenseite weg ist.
    @discardableResult
    static func senden(_ g: Griff, _ daten: Data) -> Bool {
        daten.withUnsafeBytes { p -> Bool in
            guard let basis = p.baseAddress else { return true }
            var ab = 0
            while ab < p.count {
                #if os(Windows)
                let n = Int(send(g, basis.advanced(by: ab).assumingMemoryBound(to: CChar.self),
                                 Int32(p.count - ab), 0))
                #elseif canImport(Darwin)
                let n = send(g, basis.advanced(by: ab), p.count - ab, 0)
                #else
                let n = send(g, basis.advanced(by: ab), p.count - ab, Int32(MSG_NOSIGNAL))
                #endif
                if n <= 0 {
                    #if !os(Windows)
                    if n < 0 && errno == EINTR { continue }
                    #endif
                    return false
                }
                ab += n
            }
            return true
        }
    }

    static func schliessen(_ g: Griff) {
        #if os(Windows)
        _ = closesocket(g)
        #else
        _ = close(g)
        #endif
    }
}
