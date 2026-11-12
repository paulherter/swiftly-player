import Foundation
import Testing

@testable import SwiftlyCore

@Suite(.serialized) struct LooksImagesTests {
    @Test @MainActor func theLookSwitchesFollowTheModelAndSurviveANewModel() throws {
        let store = MemoryKeyValue()
        let controller = LookController(model: makeCore(store: store).lookModel())
        #expect(!controller.selection.lookId.isEmpty)
        let before = controller.effectsOn
        try controller.setEffectsOn(!before)
        #expect(controller.effectsOn == !before)
        // The same store, a new core: the switch was kept.
        #expect(LookController(model: makeCore(store: store).lookModel()).effectsOn == !before)
        try controller.beginPreview()
        #expect(controller.isPreviewing)
        try controller.endPreview()
        #expect(!controller.isPreviewing)
        #expect(!controller.freeLooks(now: 1_800_000_000, utcOffset: 0).isEmpty)
    }

    @Test @MainActor func theSupportStatusAndWatchTimeAreKept() throws {
        let store = MemoryKeyValue()
        let controller = SupportController(model: makeCore(store: store).supportModel())
        #expect(!controller.status.supporter)
        #expect(controller.watchedHours == 0)
        try controller.recordLaunch(now: 1_800_000_000)
        var status = controller.status
        status.supporter = true
        try controller.setStatus(status)
        #expect(controller.status.supporter)
        #expect(SupportController(model: makeCore(store: store).supportModel()).status.supporter)
    }

    @Test @MainActor func theTakeoverCardFollowsThePolledSessions() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        let model = makeCore().takeoverModel(account: account(server), locale: "de")
        let controller = TakeoverController(model: model)
        #expect(controller.card == .hidden)
        try controller.polled(sessionsJson: Data("[]".utf8), now: 1_800_000_000)
        #expect(controller.card == .hidden)

        let sessions = """
            [{"Id":"s1","UserId":"user-token-a","DeviceId":"other-device","DeviceName":"Wohnzimmer",
              "Client":"Swiftly","SupportsRemoteControl":true,"LastActivityDate":"2027-01-15T08:00:00.0000000Z",
              "NowPlayingItem":{"Id":"m1","Name":"Erster Film","Type":"Movie"},
              "PlayState":{"PositionTicks":6000000000,"IsPaused":false}}]
            """
        try controller.polled(sessionsJson: Data(sessions.utf8), now: 1_800_000_000)
        guard case .badge(let rows) = controller.card else {
            Issue.record("expected the badge, got \(controller.card)")
            return
        }
        #expect(rows.map(\.id) == ["s1"])
        controller.tapped()
        guard case .taking(let row) = controller.card else {
            Issue.record("a single session is taken at once, got \(controller.card)")
            return
        }
        #expect(row.id == "s1")
        controller.failed("kaputt")
        #expect(controller.card == .failed(message: "kaputt"))
        controller.cancelled()
        #expect(controller.card != .failed(message: "kaputt"))
    }

    @Test func theTakeoverRulesAndTheSubtitleLookRoundTrip() {
        #expect(!takeoverIsHandoff(hintPre: nil))
        let look = subtitleLookStandard()
        #expect(subtitleLookIsStandard(look: look))
        #expect(subtitleLookRead(data: subtitleLookWrite(look: look)) == look)
        #expect(subtitleLookRead(data: nil) == look)
        let selection = lookSelectionRead(data: nil)
        #expect(lookSelectionRead(data: lookSelectionWrite(selection: selection)) == selection)
        #expect(!lookCatalog().isEmpty)
    }

    @Test @MainActor func theImageLoaderAnswersAndPixelsBecomeAPicture() throws {
        let core = makeCore()
        let images = ImageLoaderController(core: core, cacheDir: nil, device: .phone)
        #expect(images.border(forDisplayEdge: 100) > 0)
        #expect(images.cached("http://127.0.0.1:1/none.jpg") == nil)
        #expect(images.stats.fetches == 0)
        let pixels = ImagePixels(width: 1, height: 1, rgba: Data([255, 0, 0, 255]))
        let picture = try #require(pixels.cgImage)
        #expect(picture.width == 1)
        #expect(ImagePixels(width: 2, height: 2, rgba: Data([0])).cgImage == nil)
    }
}
