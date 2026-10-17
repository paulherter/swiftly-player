import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

@Suite("Downloadqualitaet")
struct DownloadQualityTests {

    /// 45 minutes in ticks.
    let episode: Int64 = 45 * 60 * 10_000_000

    @Test("Nur mit beiden Rechten waehlbar; Schweigen sperrt nicht")
    func selectable() {
        #expect(DownloadQuality.selectable(videoConvert: nil, audioConvert: nil))
        #expect(DownloadQuality.selectable(videoConvert: true, audioConvert: true))
        #expect(!DownloadQuality.selectable(videoConvert: false, audioConvert: true))
        #expect(!DownloadQuality.selectable(videoConvert: true, audioConvert: false))
    }

    @Test("Ohne Recht nur das Original")
    func withoutRight() {
        #expect(DownloadQuality.offered(selectable: false, sourceBitrateOf: 50_000_000) == [.original])
    }

    @Test("Stufen, die nicht kleiner machen, fallen weg")
    func levelsFilter() {
        #expect(DownloadQuality.offered(selectable: true, sourceBitrateOf: nil)
                == [.original, .hd1080, .hd720, .sd480])
        #expect(DownloadQuality.offered(selectable: true, sourceBitrateOf: 30_000_000)
                == [.original, .hd1080, .hd720, .sd480])
        // A 720p episode at 3 Mbit/s: only 480p makes it smaller.
        #expect(DownloadQuality.offered(selectable: true, sourceBitrateOf: 3_000_000)
                == [.original, .sd480])
    }

    @Test("Quellbitrate aus Groesse und Laufzeit, die beste zaehlt")
    func sourceBitrate() {
        // 2.7 GB in 45 minutes = 8 Mbit/s
        #expect(DownloadQuality.bitrate(bytes: 2_700_000_000, runtimeTicks: episode) == 8_000_000)
        #expect(DownloadQuality.bitrate(bytes: 0, runtimeTicks: episode) == nil)
        #expect(DownloadQuality.bitrate(bytes: 1, runtimeTicks: nil) == nil)
        let q = DownloadQuality.sourceBitrateOf([(1_350_000_000, episode), (2_700_000_000, episode), (5, nil)])
        #expect(q == 8_000_000)
    }

    @Test("Geschaetzte Groesse: Bitrate mal Laufzeit, nie ueber dem Original")
    func size() {
        let original: Int64 = 10_000_000_000
        #expect(DownloadQuality.original.estimatedBytes(original: original, runtimeTicks: episode) == original)
        // 720p: 4.256 Mbit/s * 2700 s / 8 * 1.03 ≈ 1.48 GB
        let s720 = DownloadQuality.hd720.estimatedBytes(original: original, runtimeTicks: episode)
        #expect(s720 > 1_400_000_000 && s720 < 1_550_000_000)
        #expect(DownloadQuality.sd480.estimatedBytes(original: original, runtimeTicks: episode) < s720)
        // Source smaller than the tier: never larger than the original.
        #expect(DownloadQuality.hd1080.estimatedBytes(original: 500_000_000, runtimeTicks: episode) == 500_000_000)
        // Without a runtime, no number.
        #expect(DownloadQuality.hd720.estimatedBytes(original: original, runtimeTicks: nil) == 0)
    }

    @Test("Posten in anderer Qualitaet: Matroska, Schaetzung, alte Listen bleiben lesbar")
    func entries() throws {
        let p = DownloadItem(id: "a", account: "u", art: .film, title: "T",
                               runtimeTicks: episode, container: "mp4", source: "q",
                               bytes: 10_000_000_000)
        #expect(p.quality == nil && !p.converted && p.guete == .original)
        let small = p.inQuality(.hd720)
        #expect(small.container == "mkv")
        #expect(small.fileName.hasSuffix(".mkv"))
        #expect(small.converted && small.guete == .hd720)
        #expect(small.bytes < p.bytes)
        let same = p.inQuality(.original)
        #expect(same == p)

        // A list from before 1.0.5 has no `quality` field.
        let alt = try JSONEncoder().encode([p])
        var raw = try #require(String(data: alt, encoding: .utf8))
        raw = raw.replacingOccurrences(of: #","qualitaet":null"#, with: "")
        let hasRead = try JSONDecoder().decode([DownloadItem].self, from: Data(raw.utf8))
        #expect(hasRead.first?.guete == .original)

        // And the new list carries the choice.
        let new = try JSONDecoder().decode([DownloadItem].self,
                                           from: JSONEncoder().encode([small]))
        #expect(new.first?.quality == .hd720)
    }

    @Test("Gruppe nennt die Stufe nur, wenn sie fuer alle gilt")
    func gemeinsam() {
        let a = DownloadItem(id: "a", account: "u", art: .episode, title: "A",
                               runtimeTicks: episode, bytes: 1_000_000_000)
        let b = DownloadItem(id: "b", account: "u", art: .episode, title: "B",
                               runtimeTicks: episode, bytes: 1_000_000_000)
        #expect(DownloadQuality.gemeinsam([a.inQuality(.sd480), b.inQuality(.sd480)]) == .sd480)
        #expect(DownloadQuality.gemeinsam([a.inQuality(.sd480), b]) == nil)
        #expect(DownloadQuality.gemeinsam([a, b]) == nil)
        #expect(DownloadQuality.gemeinsam([]) == nil)
    }

    @Test("Eine Schaetzung zeigt vor dem Ende nie voll")
    func share() {
        var p = DownloadItem(id: "a", account: "u", art: .film, title: "T",
                               runtimeTicks: episode, bytes: 10_000_000_000).inQuality(.sd480)
        p.state = .loads
        p.loaded = p.bytes * 2
        #expect(p.share == 0.99)
        p.state = .done
        #expect(p.share == 1)
    }

    @Test("Worte: Plakette und Bitrate sprachbewusst")
    func phrases() {
        let de = Locale(identifier: "de_DE"), en = Locale(identifier: "en_US")
        #expect(DownloadQuality.sd480.addition(locale: de) == "1,5 Mbit/s")
        #expect(DownloadQuality.sd480.addition(locale: en) == "1.5 Mbit/s")
        #expect(DownloadQuality.hd720.badge(locale: de) == "720p · 4 Mbit/s")
    }

    @Test("Umgewandelt: eingebettete Textuntertitel reisen mit, Bilduntertitel nicht")
    func subtitle() {
        func ut(_ i: Int, _ codec: String, extern: Bool = false) -> MediaStream {
            MediaStream(codec: codec, type: "Subtitle", language: "ger", displayTitle: nil,
                        channels: nil, isDefault: nil, index: i, height: nil, width: nil,
                        isExternal: extern,
                        deliveryUrl: extern ? "/Videos/x/q/Subtitles/\(i)/0/Stream.srt" : nil)
        }
        let streams = [ut(2, "subrip"), ut(3, "PGSSUB"), ut(4, "ass"), ut(5, "srt", extern: true)]
        let server = URL(string: "https://tv.example.de")!
        let original = SubtitleFile.withLoad(streams: streams, itemID: "x", source: "q",
                                                server: server, key: "k", converted: false)
        #expect(original.map(\.index) == [5])
        let small = SubtitleFile.withLoad(streams: streams, itemID: "x", source: "q",
                                             server: server, key: "k", converted: true)
        #expect(small.map(\.index) == [2, 4, 5])
        #expect(small.first?.address.path == "/Videos/x/q/Subtitles/2/0/Stream.srt")
        #expect(small[1].address.pathExtension == "ass")
        #expect(small.first?.address.query?.contains("ApiKey=k") == true)
    }

    @Test("Adresse: Original unveraendert, Stufe wandelt um")
    func address() async throws {
        let c = JellyfinClient(baseURL: URL(string: "https://tv.example.de")!,
                               deviceID: "dev-42", deviceName: "Prueflauf",
                               session: .init(accessToken: "tok", userID: "u1", userName: "n",
                                              serverURL: URL(string: "https://tv.example.de")!))
        let originalValue = try await c.downloadURL(itemID: "abc", mediaSourceID: "q", quality: .original)
        // Fetch first, then compare: the Linux compiler cannot translate
        // `await` inside `#expect` (autoclosure without concurrency).
        let withoutLevel = try await c.downloadURL(itemID: "abc", mediaSourceID: "q")
        #expect(originalValue == withoutLevel)
        #expect(originalValue.query?.contains("static=true") == true)

        let small = try await c.downloadURL(itemID: "abc", mediaSourceID: "q", quality: .hd720)
        let parts = URLComponents(url: small, resolvingAgainstBaseURL: false)!
        func value(_ n: String) -> String? { parts.queryItems?.first { $0.name == n }?.value }
        #expect(small.path == "/Videos/abc/stream.mkv")
        #expect(value("static") == "false")
        #expect(value("videoBitRate") == "4000000")
        #expect(value("maxHeight") == "720")
        #expect(value("videoCodec") == "h264")
        #expect(value("mediaSourceId") == "q")
        #expect(value("ApiKey") == "tok")
    }

    @Test("Tonrecht aus /Users/{id}")
    func audioRight() throws {
        let v = try JSONDecoder().decode(AccountPreGift.self, from: Data(
            #"{"Policy":{"EnableVideoPlaybackTranscoding":true,"EnableAudioPlaybackTranscoding":false}}"#.utf8))
        #expect(v.audioConvertAllowed == false)
        #expect(!v.downloadQualitySelectable)
        let empty = try JSONDecoder().decode(AccountPreGift.self, from: Data(#"{"Id":"x"}"#.utf8))
        #expect(empty.downloadQualitySelectable)
    }
}
