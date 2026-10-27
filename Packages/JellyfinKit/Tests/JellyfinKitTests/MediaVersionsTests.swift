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
}
