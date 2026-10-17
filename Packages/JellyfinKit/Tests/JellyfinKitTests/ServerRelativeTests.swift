import Foundation
import Testing
@testable import JellyfinKit

/// Server-relative values (`TranscodingUrl`, `DeliveryUrl`) keep the
/// subpath of a reverse proxy (jellyfin/Swiftfin#1695).
@Suite("Serverrelative Adressen")
struct ServerRelativeTests {

    private func address(_ detail: String, _ base: String) throws -> String? {
        AppModelURLNormalizer.serverRelative(detail, base: try #require(URL(string: base)))?.absoluteString
    }

    @Test("Unterpfad bleibt stehen")
    func underPath() throws {
        #expect(try address("/videos/1/master.m3u8?a=b&c=%2F", "https://h.de/jellyfin")
                == "https://h.de/jellyfin/videos/1/master.m3u8?a=b&c=%2F")
    }

    @Test("Ohne Unterpfad wie bisher")
    func withoutUnderPath() throws {
        #expect(try address("/videos/1/master.m3u8?a=b", "http://192.168.1.5:8096")
                == "http://192.168.1.5:8096/videos/1/master.m3u8?a=b")
        #expect(try address("videos/1/x.srt", "https://h.de/")
                == "https://h.de/videos/1/x.srt")
    }

    @Test("IPv6 und Port bleiben erhalten")
    func ipv6() throws {
        #expect(try address("/Videos/a/Stream.srt", "http://[fd00::5]:8096/jf")
                == "http://[fd00::5]:8096/jf/Videos/a/Stream.srt")
    }

    @Test("Vollständige Adresse bleibt, wie sie ist")
    func complete() throws {
        #expect(try address("https://andere.de/u.srt", "https://h.de/jellyfin")
                == "https://andere.de/u.srt")
    }

    @Test("Externe Untertitel hinter einem Unterpfad")
    func subtitleBehindProxy() throws {
        let feed = MediaStream(codec: "subrip", type: "Subtitle", language: "eng", displayTitle: nil,
                                channels: nil, isDefault: nil, index: 5, height: nil, width: nil,
                                isExternal: true, deliveryUrl: "/Videos/x/y/Subtitles/5/0/Stream.srt")
        let files = SubtitleFile.from(streams: [feed],
                                          server: try #require(URL(string: "https://h.de/jellyfin")),
                                          key: "abc")
        #expect(files.first?.address.absoluteString
                == "https://h.de/jellyfin/Videos/x/y/Subtitles/5/0/Stream.srt?ApiKey=abc")
    }
}
