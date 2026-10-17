import Foundation
import Testing
@testable import JellyfinKit

@Suite struct LogRingTests {

    @Test func blacksOutQueryValuesHeadersAndAddressData() {
        let raw = """
        http://10.0.0.5:8096/Videos/abc/stream?static=true&ApiKey=0123456789abcdef&mediaSourceId=x \
        Authorization: MediaBrowser Client="Swiftly", Token="geheim123" \
        X-Emby-Token: geheim456 https://nutzer:passwort@server.example/
        """
        let clean = LogRedaction.text(raw)
        for secret in ["0123456789abcdef", "geheim123", "geheim456", "passwort", "nutzer"] {
            #expect(!clean.contains(secret), "\(secret) steht noch drin")
        }
        // What is needed for troubleshooting stays.
        #expect(clean.contains("http://10.0.0.5:8096/Videos/abc/stream"))
        #expect(clean.contains("mediaSourceId=x"))
        #expect(clean.contains("server.example"))
    }

    @Test func givesOnlyLastHourFromOut() {
        let ring = LogRing()
        let now = Date(timeIntervalSince1970: 1_000_000)
        ring.append("alt", now: now.addingTimeInterval(-3700))
        ring.append("neu ApiKey=abc", now: now.addingTimeInterval(-10))
        let excerpt = ring.excerpt(seconds: 3600, now: now)
        #expect(excerpt.count == 1)
        #expect(excerpt.first?.hasSuffix("neu ApiKey=…") == true)
    }

    @Test func holdsSelfAnLimit() {
        let ring = LogRing(limit: 100)
        let now = Date()
        for i in 0..<500 { ring.append("zeile \(i)", now: now) }
        let excerpt = ring.excerpt(now: now)
        #expect(excerpt.count <= 100 + 100 / 8)
        #expect(excerpt.last?.hasSuffix("zeile 499") == true)
    }
}
