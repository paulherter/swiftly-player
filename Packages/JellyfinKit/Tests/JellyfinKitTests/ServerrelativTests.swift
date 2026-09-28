import Foundation
import Testing
@testable import JellyfinKit

/// Serverrelative Angaben (`TranscodingUrl`, `DeliveryUrl`) behalten den
/// Unterpfad eines Reverse-Proxys (jellyfin/Swiftfin#1695).
@Suite("Serverrelative Adressen")
struct ServerrelativTests {

    private func adresse(_ angabe: String, _ basis: String) throws -> String? {
        AppModelURLNormalizer.serverrelativ(angabe, basis: try #require(URL(string: basis)))?.absoluteString
    }

    @Test("Unterpfad bleibt stehen")
    func unterpfad() throws {
        #expect(try adresse("/videos/1/master.m3u8?a=b&c=%2F", "https://h.de/jellyfin")
                == "https://h.de/jellyfin/videos/1/master.m3u8?a=b&c=%2F")
    }

    @Test("Ohne Unterpfad wie bisher")
    func ohneUnterpfad() throws {
        #expect(try adresse("/videos/1/master.m3u8?a=b", "http://192.168.1.5:8096")
                == "http://192.168.1.5:8096/videos/1/master.m3u8?a=b")
        #expect(try adresse("videos/1/x.srt", "https://h.de/")
                == "https://h.de/videos/1/x.srt")
    }

    @Test("IPv6 und Port bleiben erhalten")
    func ipv6() throws {
        #expect(try adresse("/Videos/a/Stream.srt", "http://[fd00::5]:8096/jf")
                == "http://[fd00::5]:8096/jf/Videos/a/Stream.srt")
    }

    @Test("Vollständige Adresse bleibt, wie sie ist")
    func vollstaendig() throws {
        #expect(try adresse("https://andere.de/u.srt", "https://h.de/jellyfin")
                == "https://andere.de/u.srt")
    }

    @Test("Externe Untertitel hinter einem Unterpfad")
    func untertitelHinterProxy() throws {
        let strom = MediaStream(codec: "subrip", type: "Subtitle", language: "eng", displayTitle: nil,
                                channels: nil, isDefault: nil, index: 5, height: nil, width: nil,
                                isExternal: true, deliveryUrl: "/Videos/x/y/Subtitles/5/0/Stream.srt")
        let dateien = Untertiteldatei.aus(stroeme: [strom],
                                          server: try #require(URL(string: "https://h.de/jellyfin")),
                                          schluessel: "abc")
        #expect(dateien.first?.adresse.absoluteString
                == "https://h.de/jellyfin/Videos/x/y/Subtitles/5/0/Stream.srt?ApiKey=abc")
    }
}
