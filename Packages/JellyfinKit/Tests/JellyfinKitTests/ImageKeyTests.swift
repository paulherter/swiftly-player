import Foundation
import Testing
@testable import JellyfinKit

/// **The flip side: an image belongs to no account.**
@Suite("Schluessel des Bildspeichers")
struct ImageKeyTests {

    @Test("Das Zugangsmerkmal faellt aus dem Schluessel")
    func withoutRememberTimes() throws {
        let url = try #require(URL(string:
            "https://tv.example.de/Items/abc/Images/Primary?tag=xyz&maxHeight=450&ApiKey=GEHEIM"))
        let s = ImageKey.of(url)
        #expect(!s.contains("GEHEIM"))
        // **`tag` stays.** It is Jellyfin's fingerprint; without it a changed
        // version of the image would go unnoticed.
        #expect(s.contains("tag=xyz"))
        #expect(s.contains("maxHeight=450"))
        #expect(s.contains("/Items/abc/Images/Primary"))
    }

    @Test("Auch die kleingeschriebene Fassung")
    func smallWritten() throws {
        let url = try #require(URL(string: "https://x.de/i?api_key=G&tag=1"))
        #expect(!ImageKey.of(url).contains("G"))
    }

    /// **Two accounts, the same poster, one key.** Otherwise the
    /// cache would be cold after every switch.
    @Test("Zwei Konten ergeben denselben Schluessel")
    func twoAccounts() throws {
        let a = try #require(URL(string: "https://x.de/i?tag=1&ApiKey=AAA"))
        let b = try #require(URL(string: "https://x.de/i?tag=1&ApiKey=BBB"))
        #expect(ImageKey.of(a) == ImageKey.of(b))
    }

    @Test("Eine Adresse ohne Merkmal bleibt, wie sie ist")
    func withoutQuery() throws {
        let url = try #require(URL(string: "https://x.de/i"))
        #expect(ImageKey.of(url) == "https://x.de/i")
    }
}
