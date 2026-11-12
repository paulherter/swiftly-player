import Foundation
import Testing

@testable import SwiftlyCore

@Suite struct LogShareTextTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func theFileHasVersionSystemStampAndTheLines() {
        let text = LogShareText.text(
            version: "2.5", system: LogShareText.systemIOS(.init(majorVersion: 18, minorVersion: 1, patchVersion: 0), model: "iPhone"),
            now: now, excerpt: ["10:00:00.000 hello"])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "Swiftly 2.5")
        #expect(lines[1] == "iOS 18.1.0 · iPhone")
        #expect(lines[2] == "Stand 2023-11-14T22:13:20Z")
        #expect(lines[3].isEmpty)
        #expect(lines[4] == "10:00:00.000 hello")
    }

    @Test func anEmptyHourSaysSoInsteadOfShippingNothing() {
        let text = LogShareText.text(version: "2.5", system: "macOS 15.1.0", now: now, excerpt: [])
        #expect(text.contains(logShareEmptyNote()))
        #expect(LogShareText.fileName == "Swiftly-Protokoll.txt")
    }
}
