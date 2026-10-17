import Foundation
import Testing
@testable import JellyfinKit

@Suite("Spuren: Zuordnung, Regel, Gedächtnis")
struct TrackRuleTests {

    private func ut(_ index: Int, _ language: String, forced: Bool = false, extern: Bool = false,
                    codec: String = "subrip", title: String? = nil, hi: Bool = false) -> MediaStream {
        MediaStream(codec: codec, type: "Subtitle", language: language, displayTitle: nil,
                    channels: nil, isDefault: nil, index: index, height: nil, width: nil,
                    isForced: forced, isExternal: extern, title: title,
                    deliveryUrl: extern ? "/Videos/x/y/Subtitles/\(index)/0/Stream.srt" : nil,
                    isHearingImpaired: hi)
    }

    private func audio(_ index: Int, _ language: String, codec: String = "aac", channels: Int = 2,
                     title: String? = nil) -> MediaStream {
        MediaStream(codec: codec, type: "Audio", language: language, displayTitle: nil,
                    channels: channels, isDefault: nil, index: index, height: nil, width: nil,
                    title: title)
    }

    private func vlc(_ identifier: String, _ name: String, language: String? = nil,
                     codec: String? = nil) -> PlayerTrack {
        PlayerTrack(identifier: identifier, name: name, language: language, codec: codec, channels: nil)
    }

    // MARK: Matching

    /// The case: video, German, English, two subtitles.
    /// English (index 2) is the second audio track, the second subtitle the
    /// second subtitle track; an external file does not count when opening.
    @Test func startPositionsJeArt() {
        let streams = [audio(1, "ger"), audio(2, "eng"), ut(3, "ger"), ut(4, "eng"), ut(5, "fre", extern: true)]
        let a = TrackMapping.startPositions(streams: streams, audio: 2, subtitle: .feed(4))
        #expect(a.audio == 1)
        #expect(a.subtitle == 1)
        let b = TrackMapping.startPositions(streams: streams, audio: nil, subtitle: .off)
        #expect(b.audio == nil)
        #expect(b.subtitle == nil)
        let c = TrackMapping.startPositions(streams: streams, audio: 1, subtitle: .feed(5))
        #expect(c.audio == 0)
        #expect(c.subtitle == nil)
    }

    /// **The many-track file from jellyfin-androidtv#5776, reproduced.**
    ///
    /// Three audio tracks and sixteen subtitles, mixed up in the file
    /// (video, audio, 5 subs, audio, 5 subs, audio, 6 subs), among them two ASS, one
    /// without a language, two German and three English. The track lists
    /// below are **measured**, not made up: libVLC 4 (VLCKit a23,
    /// macOS) reports `audio/N`/`spu/N` with N = Matroska track number, that is
    /// server index + 1; libVLC 3.0.23 (Linux, same numbering as Android)
    /// reports the ID as a number equal to the server index. In both cases
    /// every position must hit its own index, where ExoPlayer
    /// ended up at `floor(i / 2)`.
    @Test("Sechzehn Untertitel zwischen drei Tonspuren: jede Position trifft ihren Index")
    func multiTrackFile() {
        let audioLanguages = [(1, "ger"), (7, "eng"), (13, "jpn")]
        let utLanguages: [(Int, String, String)] = [
            (2, "ger", "subrip"), (3, "eng", "subrip"), (4, "fre", "subrip"), (5, "spa", "subrip"),
            (6, "ita", "subrip"), (8, "ger", "subrip"), (9, "eng", "subrip"), (10, "und", "subrip"),
            (11, "jpn", "subrip"), (12, "chi", "subrip"), (14, "kor", "subrip"), (15, "ger", "ass"),
            (16, "eng", "ass"), (17, "por", "subrip"), (18, "dut", "subrip"), (19, "pol", "subrip"),
        ]
        let streams = audioLanguages.map { audio($0.0, $0.1, codec: "ac3", channels: 6) }
            + utLanguages.map { ut($0.0, $0.1, forced: $0.0 == 8, codec: $0.2, title: $0.0 == 9 ? "SDH" : nil) }

        for (offset, name) in [(1, "libVLC 4"), (0, "libVLC 3")] {
            let audioTracks = audioLanguages.map {
                vlc("audio/\($0.0 + offset)", "Track", language: $0.1, codec: "AC-3")
            }
            let subTracks = utLanguages.map {
                vlc("spu/\($0.0 + offset)", "Track", language: $0.1,
                    codec: TechDetails.codecNameValue(vlcId: $0.2 == "ass" ? 0x2061_7373 : 0x7462_7573))
            }
            let z = TrackMapping.compose(audio: audioTracks, subtitle: subTracks, streams: streams, files: [])
            #expect(z.audio == audioLanguages.map(\.0), "\(name)")
            #expect(z.subtitle == utLanguages.map(\.0), "\(name)")
            // And backwards, as choosing by server index needs it.
            for (position, entryRecord) in utLanguages.enumerated() {
                #expect(z.subtitlePosition(index: entryRecord.0) == position, "\(name) Index \(entryRecord.0)")
            }
        }
    }

    @Test("Gleiche Namen: die Position entscheidet, nicht der Name")
    func sameNames() {
        let streams = [audio(1, "ger"), ut(2, "ger", forced: true), ut(3, "ger")]
        let z = TrackMapping.compose(
            audio: [vlc("audio/1", "Deutsch", language: "ger", codec: "AAC")],
            subtitle: [vlc("spu/2", "Deutsch", language: "ger"), vlc("spu/3", "Deutsch", language: "ger")],
            streams: streams, files: [])
        #expect(z.audio == [1])
        #expect(z.subtitle == [2, 3])
    }

    @Test("Abweichende Anzahl: nur Belegtes wird zugeordnet")
    func countSoftOff() {
        // VLC leaves out the middle track.
        let streams = [audio(1, "ger", codec: "dts"), audio(2, "eng", codec: "truehd"), audio(3, "jpn")]
        let z = TrackMapping.compose(
            audio: [vlc("audio/1", "German", language: "German", codec: "DTS"),
                  vlc("audio/3", "Japanese", language: "jpn", codec: "AAC")],
            subtitle: [], streams: streams, files: [])
        #expect(z.audio == [1, 3])

        // Nothing to match: better nothing than a guess.
        let without = TrackMapping.compose(audio: [vlc("audio/1", "Spur 1")], subtitle: [],
                                        streams: [audio(1, "ger"), audio(2, "eng")], files: [])
        #expect(without.audio == [nil])
    }

    @Test("Sprache widerspricht bei gleicher Anzahl: nicht blind nach Position")
    func contradiction() {
        let streams = [ut(3, "eng"), ut(4, "ger")]
        let z = TrackMapping.compose(audio: [], subtitle: [vlc("spu/4", "Deutsch", language: "ger")],
                                     streams: [ut(4, "ger")], files: [])
        #expect(z.subtitle == [4])
        let swappedOver = TrackMapping.compose(
            audio: [], subtitle: [vlc("spu/1", "German", language: "German"), vlc("spu/2", "English", language: "eng")],
            streams: streams, files: [])
        #expect(swappedOver.subtitle == [4, nil])
    }

    @Test("Externe Datei über den MD5 der Adresse, getrennt von den eingebetteten")
    func externalTrack() throws {
        let md5 = "0123456789abcdef0123456789abcdef"
        let streams = [audio(1, "ger"), ut(2, "ger", forced: true), ut(5, "eng", extern: true)]
        let file = SubtitleFile(index: 5, address: try #require(URL(string: "https://s/x.srt")), attribute: md5)
        let z = TrackMapping.compose(
            audio: [vlc("audio/1", "Deutsch")],
            subtitle: [vlc("\(md5)/spu/0", "Track 1"), vlc("spu/2", "Deutsch", language: "ger")],
            streams: streams, files: [file])
        #expect(z.subtitle == [5, 2])
        #expect(z.subtitlePosition(index: 5) == 0)

        // Without a trait: order, if it works out.
        let without = SubtitleFile(index: 5, address: file.address, attribute: nil)
        let z2 = TrackMapping.compose(audio: [], subtitle: [vlc("spu/2", "D"), vlc("\(md5)/spu/0", "T")],
                                      streams: streams, files: [without])
        #expect(z2.subtitle == [2, 5])
    }

    @Test("Externe Adressen kommen vom Server, mit Schlüssel")
    func externalAddresses() throws {
        let streams = [ut(2, "ger"), ut(5, "eng", extern: true)]
        let files = SubtitleFile.from(streams: streams, server: try #require(URL(string: "https://tv.example")),
                                          key: "abc", attribute: { _ in "m" })
        #expect(files.count == 1)
        #expect(files.first?.index == 5)
        #expect(files.first?.address.absoluteString == "https://tv.example/Videos/x/y/Subtitles/5/0/Stream.srt?ApiKey=abc")
        #expect(files.first?.attribute == "m")
    }

    @Test("DeliveryUrl, Title und Server-Vorgaben kommen an")
    func wasDecoded() throws {
        let json = #"{"Id":"q","DefaultAudioStreamIndex":2,"DefaultSubtitleStreamIndex":-1,"MediaStreams":[{"Type":"Subtitle","Index":4,"IsExternal":true,"IsForced":true,"Title":"Forced","DeliveryUrl":"/Videos/a/b/Subtitles/4/0/Stream.srt"}]}"#
        let source = try JSONDecoder().decode(MediaSource.self, from: Data(json.utf8))
        #expect(source.defaultAudioStreamIndex == 2)
        #expect(source.defaultSubtitleStreamIndex == -1)
        let feed = try #require(source.mediaStreams?.first)
        #expect(feed.deliveryUrl == "/Videos/a/b/Subtitles/4/0/Stream.srt")
        #expect(feed.title == "Forced")
        #expect(feed.isForced == true && feed.isExternal == true)
    }

    // MARK: Rule

    private func rule(_ streams: [MediaStream], remembered: TrackMemory.Choice? = nil, guideline: Int? = nil,
                       automatic: Bool = false, audioIndex: Int? = 1, tonwunsch: String = "",
                       wish: String = "") -> TrackRule.Subtitle {
        TrackRule.subtitle(streams: streams, remembered: remembered, serverPreGift: guideline,
                             automatic: automatic, audioIndex: audioIndex, tonwunsch: tonwunsch,
                             preferredLanguage: wish)
    }

    @Test("Ohne Einstellung: erzwungene an, sonst aus — nicht die erste")
    func forcedOrOut() {
        #expect(rule([audio(1, "ger"), ut(2, "ger"), ut(3, "ger", forced: true)]) == .feed(3))
        #expect(rule([audio(1, "ger"), ut(2, "ger"), ut(3, "eng")]) == .off)
        // With several forced ones, the one in the audio language.
        #expect(rule([audio(1, "ger"), ut(2, "eng", forced: true), ut(3, "ger", forced: true)]) == .feed(3))
    }

    @Test("Externe erzwungene Spur zählt mit")
    func externForced() {
        #expect(rule([audio(1, "ger"), ut(2, "eng"), ut(7, "ger", forced: true, extern: true)]) == .feed(7))
    }

    @Test("Vorgaben-Reihenfolge: Handwahl, automatisch, Server, erzwungen")
    func railsEpisode() {
        let streams = [audio(1, "eng"), ut(2, "ger", forced: true), ut(3, "ger"), ut(4, "eng")]
        let englishRemembered = TrackImprint(feed: streams[3], in: streams)
        // A manual choice beats everything, even "off".
        #expect(rule(streams, remembered: .track(englishRemembered), guideline: 3, automatic: true, wish: "Deutsch") == .feed(4))
        #expect(rule(streams, remembered: .off, guideline: 2) == .off)
        // Automatic, foreign audio: full track in the preferred language before the server default.
        #expect(rule(streams, guideline: 4, automatic: true, wish: "Deutsch") == .feed(3))
        // Server default without "automatic" only if forced.
        #expect(rule(streams, guideline: 4) == .feed(2))
        #expect(rule([audio(1, "ger"), ut(2, "ger"), ut(3, "ger", forced: true), ut(4, "ger", forced: true)], guideline: 4) == .feed(4))
        // With "automatic" the server default also applies in full.
        #expect(rule([audio(1, "ger"), ut(2, "ger", forced: true), ut(4, "eng")], guideline: 4, automatic: true, wish: "Deutsch") == .feed(4))
        // Server says "none": forced ones stay on.
        #expect(rule(streams, guideline: -1) == .feed(2))
    }

    /// findroid#756: SDH and a regular track of the same language looked the same,
    /// and automatic selection took whichever came first in the file.
    @Test("Automatisch: die gewöhnliche Spur vor der für Hörgeschädigte, auch wenn SDH zuerst steht")
    func hearingImpairedNotPreferred() {
        let streams = [audio(1, "eng"), ut(2, "ger", hi: true), ut(3, "ger", forced: true), ut(4, "ger")]
        #expect(rule(streams, automatic: true, wish: "Deutsch") == .feed(4))
        // If there is only SDH, SDH is better than nothing.
        #expect(rule([audio(1, "eng"), ut(2, "ger", hi: true)], automatic: true, wish: "Deutsch") == .feed(2))
        // A manual SDH choice stays SDH in the next episode, even if the order changes.
        let remembered = TrackImprint(feed: streams[1], in: streams)
        let next = [audio(1, "eng"), ut(2, "ger"), ut(3, "ger", hi: true)]
        #expect(rule(next, remembered: .track(remembered)) == .feed(3))
    }

    @Test("Das Merkmal kommt aus IsHearingImpaired")
    func hearingImpairedRead() throws {
        let json = #"{"Type":"Subtitle","Index":3,"Language":"ger","IsHearingImpaired":true}"#
        let feed = try JSONDecoder().decode(MediaStream.self, from: Data(json.utf8))
        #expect(feed.isHearingImpaired == true)
        let without = try JSONDecoder().decode(MediaStream.self, from: Data(#"{"Type":"Subtitle","Index":3}"#.utf8))
        #expect(without.isHearingImpaired == nil)
        // A snapshot from before the trait still reads.
        let alt = #"{"sprache":"ger","erzwungen":false,"extern":false}"#
        let imprint = try JSONDecoder().decode(TrackImprint.self, from: Data(alt.utf8))
        #expect(imprint.hearingImpaired == nil)
    }

    @Test("Schalter aus: die Wunschsprache schaltet nichts dazu")
    func toggleOut() {
        #expect(rule([audio(1, "eng"), ut(2, "ger"), ut(3, "eng")], wish: "Deutsch") == .off)
    }

    @Test("Ton: Handwahl, dann Tonsprache der App, dann Server, sonst Datei")
    func audioRule() {
        let streams = [audio(1, "ger", codec: "ac3", channels: 6), audio(2, "eng", codec: "truehd", channels: 8), audio(3, "eng", codec: "aac")]
        let remembered = TrackImprint(feed: streams[2], in: streams)
        #expect(TrackRule.audio(streams: streams, remembered: remembered, preferredLanguage: "Deutsch", serverPreGift: 1) == 3)
        #expect(TrackRule.audio(streams: streams, remembered: nil, preferredLanguage: "English", serverPreGift: 1) == 2)
        #expect(TrackRule.audio(streams: streams, remembered: nil, preferredLanguage: "", serverPreGift: 2) == 2)
        #expect(TrackRule.audio(streams: streams, remembered: nil, preferredLanguage: "", serverPreGift: nil) == nil)
    }

    @Test("Nächste Folge trifft die gemerkte Spur, auch bei gleichen Namen und neuer Reihenfolge")
    func nextEpisode() {
        let episode1 = [audio(1, "ger"), ut(2, "ger", forced: true, title: "Forced"), ut(3, "ger", title: "Full")]
        let selected = TrackImprint(feed: episode1[2], in: episode1, name: "Deutsch")
        // Episode 2: different indices, full track first.
        let episode2 = [audio(0, "ger"), ut(5, "ger", title: "Full"), ut(6, "ger", forced: true, title: "Forced")]
        #expect(rule(episode2, remembered: .track(selected), audioIndex: 0) == .feed(5))
        // Without a title, "forced" decides.
        let episode3 = [audio(0, "ger"), ut(8, "ger", forced: true), ut(9, "ger")]
        #expect(rule(episode3, remembered: .track(selected), audioIndex: 0) == .feed(9))
        // The language is missing: the normal case instead of a foreign language.
        let episode4 = [audio(0, "eng"), ut(8, "eng")]
        #expect(rule(episode4, remembered: .track(selected), audioIndex: 0) == .off)
    }

    @Test("Alte Einträge (Spurname) bleiben lesbar")
    func oldEntry() {
        let streams = [audio(1, "eng"), ut(2, "ger", forced: true), ut(3, "ger")]
        #expect(rule(streams, remembered: .name("Deutsch")) == .feed(3))
        #expect(rule(streams, remembered: .name("Deutsch Forced")) == .feed(2))
    }

    // MARK: Memory and report

    @Test("Gedächtnis je Serie, für Ton und Untertitel, übersteht einen Neustart")
    func memory() throws {
        let name = "SpurregelTests"
        let store = try #require(UserDefaults(suiteName: name))
        store.removePersistentDomain(forName: name)
        // An entry from the old version.
        store.set(["alt": "English"], forKey: "utJeTitel")
        let imprint = TrackImprint(feed: audio(2, "eng"), in: [audio(1, "ger"), audio(2, "eng")])
        TrackMemory(store: store).rememberSubtitle(.off, for: "serie")
        TrackMemory(store: store).rememberAudio(imprint, for: "serie")
        TrackMemory(store: store).rememberSubtitle(.track(imprint), for: "film")
        let new = TrackMemory(store: store)
        #expect(new.subtitle(for: "serie") == .off)
        #expect(new.audio(for: "serie") == imprint)
        #expect(new.subtitle(for: "film") == .track(imprint))
        #expect(new.subtitle(for: "alt") == .name("English"))
        #expect(new.subtitle(for: "anderes") == nil)
        #expect(new.audio(for: "film") == nil)
    }

    @Test("Meldung trägt die Spurindizes, ohne Angabe fehlen sie")
    func message() throws {
        let plan = PlaybackPlan.fromSlab(try #require(URL(string: "https://s/a")), container: nil)
        let with = JellyfinClient.reportBody(itemID: "i", plan: plan, positionTicks: 0, paused: false,
                                              tracks: TrackIndices(audio: 2, subtitle: -1))
        let text = String(decoding: try JSONEncoder().encode(with), as: UTF8.self)
        #expect(text.contains(#""AudioStreamIndex":2"#))
        #expect(text.contains(#""SubtitleStreamIndex":-1"#))
        let without = JellyfinClient.reportBody(itemID: "i", plan: plan, positionTicks: 0, paused: false,
                                               tracks: TrackIndices())
        let empty = String(decoding: try JSONEncoder().encode(without), as: UTF8.self)
        #expect(!empty.contains("StreamIndex"))
    }
}
