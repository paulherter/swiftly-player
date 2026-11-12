import Foundation
import Testing

@testable import SwiftlyCore

/// **Stages (d) and (e): the core decides the quality switch and cuts the chapter name and the scrub preview.**
/// Scripted with the fake engine of ``CorePlayerDecisionTests``; the screens only send intents and read.
@Suite(.serialized) struct CorePlayerQualityExtrasTests {
    @MainActor func make() throws -> CorePlayerDecisionTests.Run {
        try CorePlayerDecisionTests().run(
            CorePlayerDecisionTests.Server(), startAt: 600, autoSkip: false, next: false, sections: [])
    }

    private func started(_ effects: [PlayerEffectOut]) -> [(String, Double)] {
        effects.compactMap { if case let .startEpisode(id, _, since) = $0 { (id, since) } else { nil } }
    }

    @Test @MainActor func aQualityChoiceReloadsTheSameTitleOnceAndForgetsThePreparedPlan() async throws {
        var r = try make()
        defer { r.observing.cancel() }
        await r.play(from: 600, seconds: 2)
        r.effects = []
        r.model.send(.quality(limit: 8))
        let effects = r.model.takeEffects()
        #expect(effects.contains(.qualityChosen(directPlay: false, limit: 8)), "\(effects)")
        #expect(effects.contains(.forgetPrepared))
        let reload = started(effects)
        #expect(reload.count == 1 && reload[0].0 == "ep1" && reload[0].1 > 600, "\(reload)")
        // The same choice again changes nothing (an illegal repeat).
        r.model.send(.quality(limit: 8))
        #expect(r.model.takeEffects().isEmpty)
    }

    @Test @MainActor func noQualityChoiceWhenTheServerMayNotConvert() async throws {
        var r = try make()
        defer { r.observing.cancel() }
        var prefs = playerPrefs
        prefs.convertAllowed = false
        r.model.setPrefs(prefs)
        r.model.send(.quality(limit: 8))
        #expect(r.model.takeEffects().isEmpty)
    }

    @Test @MainActor func aReloadedModelSaysWhenTheOriginalPlays() async throws {
        let r = try make()
        defer { r.observing.cancel() }
        var prefs = playerPrefs
        prefs.directPlay = false
        prefs.bitrateLimit = 8
        r.model.setPrefs(prefs)
        #expect(r.model.transport.hint == nil)
        r.model.afterQualitySwitch()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(r.model.transport.hint?.contains("Originalqualität") == true, "\(String(describing: r.model.transport.hint))")
    }

    @Test @MainActor func scrubbingNamesTheChapterAndCutsTheTile() async throws {
        var r = try make()
        defer { r.observing.cancel() }
        r.model.setChapters([PlayerChapter(name: "Anfang", from: 0), PlayerChapter(name: "Mitte", from: 300)])
        r.model.setTrickplay(PlayerTrickplay(width: 320, height: 180, tilesWide: 10, tilesUp: 10, count: 200, interval: 10000))
        await r.play(from: 600, seconds: 1)
        r.model.send(.scrubStart)
        r.model.send(.scrubMove(seconds: 125))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(r.model.transport.chapter == "Anfang", "\(String(describing: r.model.transport.chapter))")
        let tile = try #require(r.model.controls.preview)
        #expect(tile.sheet == 0 && tile.width == 320 && tile.height == 180)
        r.model.send(.scrubEnd(seconds: 125))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(r.model.controls.preview == nil)
    }

    @Test @MainActor func noTrickplayMeansNoTile() async throws {
        let r = try make()
        defer { r.observing.cancel() }
        r.model.setTrickplay(nil)
        r.model.send(.scrubMove(seconds: 50))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(r.model.controls.preview == nil)
    }
}
