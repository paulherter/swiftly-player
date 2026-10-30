import Foundation
import Testing
@testable import JellyfinKit

@Suite("Download audio and next episode")
struct DownloadAudioTests {

    private func audio(_ index: Int, _ language: String, codec: String = "ac3",
                       channels: Int = 6, isDefault: Bool = false) -> MediaStream {
        MediaStream(codec: codec, type: "Audio", language: language, displayTitle: nil,
                    channels: channels, isDefault: isDefault, index: index, height: nil, width: nil)
    }

    private var film: [MediaStream] { [audio(1, "ger"), audio(2, "eng", codec: "dts")] }

    private func episodeItem(_ id: String, season: Int, number: Int,
                             streams: [MediaStream] = []) -> Item {
        Item(id: id, name: "Folge " + id, type: "Episode", indexNumber: number, parentIndexNumber: season,
             mediaSources: [MediaSource(id: "src-" + id, name: nil, container: "mkv", size: 1_000,
                                        supportsDirectPlay: true, supportsDirectStream: true,
                                        supportsTranscoding: true, transcodingUrl: nil,
                                        mediaStreams: streams)])
    }

    private func watched(_ id: String = "e1", season: Int = 1, number: Int = 1) -> DownloadItem {
        DownloadItem(id: id, account: "u1", art: .episode, title: "x", series: "S",
                     seriesIdentifier: "s1", season: season, episode: number,
                     container: "mkv", bytes: 1_000, state: .done, watched: true)
    }

    // MARK: Choice

    @Test("One track means no choice, several do")
    func offered() {
        #expect(!DownloadAudio.offered(streams: [audio(1, "ger")]))
        #expect(DownloadAudio.offered(streams: film))
    }

    @Test("A film offers all tracks first, then each track")
    func filmOptions() {
        let options = DownloadAudio.trackOptions(streams: film)
        #expect(options.map(\.choice) == [.all, .track(1), .track(2)])
    }

    @Test("Equal labels get a number")
    func distinctLabels() {
        let twin = [audio(1, "ger"), audio(2, "ger")]
        let labels = DownloadAudio.trackOptions(streams: twin).dropFirst().map(\.label)
        #expect(Set(labels).count == 2)
    }

    @Test("Without a wished language nothing is cut away")
    func preselectionNone() {
        let options = DownloadAudio.trackOptions(streams: film)
        #expect(DownloadAudio.preselected(options: options, streams: film,
                                          preferredLanguage: "") == .all)
    }

    @Test("The wished language is preselected, a missing one is not")
    func preselection() {
        let options = DownloadAudio.trackOptions(streams: film)
        let key = TrackImprint.languageKey("eng") ?? "eng"
        #expect(DownloadAudio.preselected(options: options, streams: film,
                                          preferredLanguage: key) == .track(2))
        #expect(DownloadAudio.preselected(options: options, streams: film,
                                          preferredLanguage: "fr") == .all)
    }

    @Test("A selection offers languages, in the order they appear")
    func languages() {
        let a = [audio(1, "ger"), audio(2, "eng")]
        let b = [audio(1, "eng"), audio(2, "jpn")]
        let options = DownloadAudio.languageOptions([a, b])
        #expect(options.count == 4)
        #expect(options.first?.choice == .all)
        #expect(DownloadAudio.offered(selection: [a, b]))
        #expect(!DownloadAudio.offered(selection: [[audio(1, "ger"), audio(2, "ger")]]))
    }

    @Test("A language is found at its own index in each file")
    func languageIndex() {
        let key = TrackImprint.languageKey("eng") ?? "eng"
        #expect(DownloadAudio.index(for: .language(key), streams: [audio(1, "ger"), audio(2, "eng")]) == 2)
        #expect(DownloadAudio.index(for: .language(key), streams: [audio(1, "eng"), audio(2, "ger")]) == 1)
        #expect(DownloadAudio.index(for: .language(key), streams: [audio(1, "ger"), audio(2, "fra")]) == nil)
        #expect(DownloadAudio.index(for: .track(9), streams: film) == nil)
        #expect(DownloadAudio.index(for: .all, streams: film) == nil)
    }

    // MARK: Item

    @Test("One track makes a built file; all tracks stay the original")
    func itemWithAudio() {
        let base = DownloadItem(id: "f", account: "u1", art: .film, title: "F",
                                container: "mp4", bytes: 5_000)
        #expect(!base.streamed)
        let all = base.withAudio(.all, streams: film)
        #expect(all == base)
        let one = base.withAudio(.track(2), streams: film)
        #expect(one.audioIndex == 2)
        #expect(one.streamed && !one.converted)
        #expect(one.container == "mkv")
        // The sheet always starts from the catalog's item, so the quality comes first.
        let small = base.inQuality(.hd720).withAudio(.track(2), streams: film)
        #expect(small.audioIndex == 2 && small.converted)
        #expect(small.inQuality(.original).audioIndex == 2)
        #expect(small.inQuality(.original).container == "mkv")
    }

    @Test("An old list without the new fields still reads")
    func oldList() throws {
        let json = #"{"id":"a","konto":"u1","art":"film","titel":"T","bytes":1,"geladen":0,"stand":"fertig","gesehen":false,"angelegt":0,"nochAufDemServer":true}"#
        let item = try JSONDecoder().decode(DownloadItem.self, from: Data(json.utf8))
        #expect(item.audioIndex == nil && item.replaces == nil && item.nextPending == nil)
        let again = try JSONDecoder().decode(
            DownloadItem.self, from: JSONEncoder().encode(item.withAudio(index: 3, language: "de")))
        #expect(again.audioIndex == 3 && again.audioLanguage == "de")
    }

    // MARK: Address

    @Test("Address: one track on the original is a copy, on a level it only names the track")
    func address() async throws {
        let c = JellyfinClient(baseURL: URL(string: "https://tv.example.de")!,
                               deviceID: "dev-42", deviceName: "Prueflauf",
                               session: .init(accessToken: "tok", userID: "u1", userName: "n",
                                              serverURL: URL(string: "https://tv.example.de")!))
        func parts(_ url: URL) -> (String, (String) -> String?) {
            let p = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            return (url.path, { n in p.queryItems?.first { $0.name == n }?.value })
        }
        let copy = try await c.downloadURL(itemID: "abc", mediaSourceID: "q", quality: .original,
                                           audioStreamIndex: 3)
        let (path, value) = parts(copy)
        #expect(path == "/Videos/abc/stream.mkv")
        #expect(value("static") == "false")
        #expect(value("videoCodec") == "copy" && value("audioCodec") == "copy")
        #expect(value("AudioStreamIndex") == "3")
        #expect(value("videoBitRate") == nil)

        let small = try await c.downloadURL(itemID: "abc", mediaSourceID: "q", quality: .hd720,
                                            audioStreamIndex: 3)
        let (_, v2) = parts(small)
        #expect(v2("videoCodec") == "h264" && v2("AudioStreamIndex") == "3")

        let plain = try await c.downloadURL(itemID: "abc", mediaSourceID: "q", quality: .original)
        #expect(plain.query?.contains("AudioStreamIndex") == false)
    }

    // MARK: Next episode

    @Test("The end is 90 percent")
    func end() {
        #expect(DownloadRules.reachedEnd(ticks: 900, runtimeTicks: 1_000))
        #expect(!DownloadRules.reachedEnd(ticks: 899, runtimeTicks: 1_000))
        #expect(!DownloadRules.reachedEnd(ticks: 900, runtimeTicks: nil))
    }

    @Test("The next episode is the next by season and number, specials never follow")
    func following() {
        let list = [episodeItem("a", season: 0, number: 1), episodeItem("b", season: 1, number: 2),
                    episodeItem("c", season: 1, number: 3), episodeItem("d", season: 2, number: 1)]
        #expect(DownloadRules.followingEpisode(after: watched(number: 2), in: list)?.id == "c")
        #expect(DownloadRules.followingEpisode(after: watched(number: 3), in: list)?.id == "d")
        #expect(DownloadRules.followingEpisode(after: watched(season: 2, number: 1), in: list) == nil)
    }

    @Test("The follow-up keeps quality and audio language and points back")
    func followUp() {
        let key = TrackImprint.languageKey("eng") ?? "eng"
        var old = watched().inQuality(.hd720)
        old = old.withAudio(index: 2, language: key)
        let next = episodeItem("e2", season: 1, number: 2, streams: [audio(1, "eng"), audio(2, "ger")])
        let follower = DownloadRules.followUp(to: old, next: next)
        #expect(follower.id == "e2" && follower.replaces == "e1")
        #expect(follower.quality == .hd720)
        #expect(follower.audioIndex == 1 && follower.audioLanguage == key)
        #expect(follower.state == .waits && !follower.watched)
        // A file without the language is loaded whole, the language is carried on.
        let other = episodeItem("e3", season: 1, number: 3, streams: [audio(1, "fra"), audio(2, "ger")])
        let whole = DownloadRules.followUp(to: old, next: other)
        #expect(whole.audioIndex == nil && whole.audioLanguage == key)
    }

    @Test("A watched episode goes only when its follower is finished and it is watched")
    func replaced() {
        var follower = watched("e2", number: 2)
        follower.replaces = "e1"
        follower.watched = false
        #expect(DownloadRules.replacedOne(by: follower, in: [watched(), follower]) == "e1")
        var running = follower; running.state = .loads
        #expect(DownloadRules.replacedOne(by: running, in: [watched(), running]) == nil)
        var unwatched = watched(); unwatched.watched = false
        #expect(DownloadRules.replacedOne(by: follower, in: [unwatched, follower]) == nil)
        #expect(DownloadRules.replacedOne(by: follower, in: [follower]) == nil)
    }
}
