import Foundation
import Testing
@testable import JellyfinKit

@Suite struct ProtokollringTests {

    @Test func schwaerztAbfragewerteKoepfeUndAdressdaten() {
        let roh = """
        http://10.0.0.5:8096/Videos/abc/stream?static=true&ApiKey=0123456789abcdef&mediaSourceId=x \
        Authorization: MediaBrowser Client="Swiftly", Token="geheim123" \
        X-Emby-Token: geheim456 https://nutzer:passwort@server.example/
        """
        let sauber = Protokollschwaerzung.text(roh)
        for geheim in ["0123456789abcdef", "geheim123", "geheim456", "passwort", "nutzer"] {
            #expect(!sauber.contains(geheim), "\(geheim) steht noch drin")
        }
        // Was zur Fehlersuche gebraucht wird, bleibt.
        #expect(sauber.contains("http://10.0.0.5:8096/Videos/abc/stream"))
        #expect(sauber.contains("mediaSourceId=x"))
        #expect(sauber.contains("server.example"))
    }

    @Test func gibtNurDieLetzteStundeHeraus() {
        let ring = Protokollring()
        let jetzt = Date(timeIntervalSince1970: 1_000_000)
        ring.anhaengen("alt", jetzt: jetzt.addingTimeInterval(-3700))
        ring.anhaengen("neu ApiKey=abc", jetzt: jetzt.addingTimeInterval(-10))
        let auszug = ring.auszug(sekunden: 3600, jetzt: jetzt)
        #expect(auszug.count == 1)
        #expect(auszug.first?.hasSuffix("neu ApiKey=…") == true)
    }

    @Test func haeltSichAnDieGrenze() {
        let ring = Protokollring(grenze: 100)
        let jetzt = Date()
        for i in 0..<500 { ring.anhaengen("zeile \(i)", jetzt: jetzt) }
        let auszug = ring.auszug(jetzt: jetzt)
        #expect(auszug.count <= 100 + 100 / 8)
        #expect(auszug.last?.hasSuffix("zeile 499") == true)
    }
}
