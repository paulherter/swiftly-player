import Foundation
import Testing
@testable import JellyfinKit

@Suite("Several versions of a title")
struct MediaVersionsTests {

    private func source(_ id: String?, name: String? = nil, size: Int64? = nil) -> MediaSource {
        MediaSource(id: id, name: name, container: "mkv", size: size,
                    supportsDirectPlay: true, supportsDirectStream: true,
                    supportsTranscoding: true, transcodingUrl: nil, mediaStreams: [])
    }

    @Test("One version means no choice")
    func single() {
        #expect(MediaVersions.choices([source("a")]).isEmpty)
        #expect(MediaVersions.choices(nil).isEmpty)
    }

    @Test("Two versions with ids are offered")
    func several() {
        #expect(MediaVersions.choices([source("a"), source("b")]).count == 2)
    }

    @Test("A source without an id cannot be chosen")
    func withoutID() {
        #expect(MediaVersions.choices([source("a"), source(nil)]).isEmpty)
    }

    @Test("An empty name falls back to a placeholder")
    func emptyName() {
        #expect(!source("a", name: "  ").versionName.isEmpty)
        #expect(source("a", name: "Directors Cut").versionName == "Directors Cut")
    }

    @Test("The chosen version beats the cheapest one")
    func pickedWins() throws {
        let response = PlaybackInfoResponse(
            mediaSources: [source("a"), source("b")], playSessionId: "s")
        let plan = try PlaybackPlan.make(
            from: response, itemID: "i", profile: .vlc(),
            streamURL: { _, source, _ in URL(string: "https://x/\(source ?? "")")! },
            serverBase: URL(string: "https://x")!, preferredSourceID: "b")
        #expect(plan?.mediaSourceID == "b")
    }

    private func video(_ id: String, name: String?, height: Int?) -> MediaSource {
        MediaSource(id: id, name: name, container: "mkv", size: nil,
                    supportsDirectPlay: true, supportsDirectStream: true,
                    supportsTranscoding: true, transcodingUrl: nil,
                    mediaStreams: [MediaStream(codec: "hevc", type: "Video", language: nil, displayTitle: nil,
                                                  channels: nil, isDefault: nil, index: 0, height: height, width: nil)])
    }

    @Test("Sources not loaded yet mean wait, not play")
    func notLoaded() {
        #expect(MediaVersions.start(nil, downloaded: false) == .wait)
    }

    @Test("One version, none listed or a copy on the device play at once")
    func playsDirectly() {
        #expect(MediaVersions.start([source("a")], downloaded: false) == .play)
        #expect(MediaVersions.start([], downloaded: false) == .play)
        #expect(MediaVersions.start(nil, downloaded: true) == .play)
        #expect(MediaVersions.start([source("a"), source("b")], downloaded: true) == .play)
    }

    @Test("Several versions are offered")
    func choosesWhenSeveral() {
        let two = [source("a"), source("b")]
        #expect(MediaVersions.start(two, downloaded: false) == .choose(two))
    }

    @Test("The next episode keeps the version with the same name")
    func matchesByName() {
        let previous = video("a", name: "Film - 4K", height: 2160)
        let next = [video("x", name: "Film - 1080p", height: 1080),
                    video("y", name: " film - 4k ", height: 2160)]
        #expect(MediaVersions.matching(previous: previous, in: next)?.id == "y")
    }

    @Test("Without a matching name the same resolution counts")
    func matchesByHeight() {
        let previous = video("a", name: "Episode 1 4K", height: 2160)
        let next = [video("x", name: "Episode 2 HD", height: 1080),
                    video("y", name: "Episode 2 UHD", height: 2160)]
        #expect(MediaVersions.matching(previous: previous, in: next)?.id == "y")
    }

    @Test("No match, or no choice in the next episode, means automatic")
    func noMatch() {
        let previous = video("a", name: "A", height: 2160)
        #expect(MediaVersions.matching(previous: previous,
                                       in: [video("x", name: "B", height: 720),
                                            video("y", name: "C", height: 1080)]) == nil)
        #expect(MediaVersions.matching(previous: previous, in: [video("x", name: "A", height: 2160)]) == nil)
        #expect(MediaVersions.matching(previous: previous, in: nil) == nil)
    }
}
