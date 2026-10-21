import Testing
@testable import JellyfinKit

@Suite("Trying on looks: what may change, and when")
struct LookTryOnTests {
    let neon = LookSelection(lookID: Look.neonNight.id)

    // MARK: The matrix

    @Test("Not a supporter, no preview: always the original, even with a stored look")
    func nonSupporterIdle() {
        let state = LookTryOn(saved: neon, isSupporter: false)
        #expect(state.shown == .original)
        #expect(!state.isPreviewing)
    }

    @Test("Not a supporter, preview open: starts on what was shown, then the look tried on")
    func nonSupporterPreview() {
        var state = LookTryOn()
        state.begin()
        #expect(state.shown == .original)
        state.tryOn(neon)
        #expect(state.shown == neon)
        #expect(state.saved == .original)
    }

    @Test("The preview opens on exactly the active look", arguments: [false, true])
    func previewStartsOnActive(supporter: Bool) {
        let tuned = LookSelection(lookID: Look.neonNight.id, accentID: LookAccent.gold.id, glow: .bright)
        var state = LookTryOn(saved: tuned, isSupporter: supporter)
        let before = state.shown
        state.begin()
        #expect(state.shown == before)
        state.tryOn(.original)
        state.tryOn(state.saved)
        state.end()
        #expect(state.shown == before)
        #expect(state.saved == tuned)
    }

    @Test("Supporter, no preview: the stored look")
    func supporterIdle() {
        #expect(LookTryOn(saved: neon, isSupporter: true).shown == neon)
    }

    @Test("Supporter, preview open: the look tried on, the stored one untouched")
    func supporterPreview() {
        var state = LookTryOn(saved: neon, isSupporter: true)
        state.begin()
        state.tryOn(.original)
        #expect(state.shown == .original)
        #expect(state.saved == neon)
    }

    // MARK: Leaving the preview

    @Test("Closing the preview changes nothing, for both", arguments: [false, true])
    func closingKeepsNothing(supporter: Bool) {
        var state = LookTryOn(saved: .original, isSupporter: supporter)
        state.begin()
        state.tryOn(LookSelection(lookID: Look.neonNight.id, accentID: LookAccent.coral.id))
        state.end()
        #expect(state.shown == .original)
        #expect(state.saved == .original)
        #expect(state.pendingKeep == nil)
    }

    @Test("Keep without support stores nothing and asks for support")
    func keepWithoutSupport() {
        var state = LookTryOn()
        state.begin()
        state.tryOn(neon)
        let result = state.keep()
        #expect(result == .needsSupport)
        #expect(state.saved == .original)
        #expect(!state.isSupporter)
        // Still trying on behind the sheet.
        #expect(state.isPreviewing)
        state.supportSheetClosed()
        state.end()
        #expect(state.shown == .original)
    }

    @Test("Keep without support, sheet closed, later a tip: the look is not switched")
    func forgottenWish() {
        var state = LookTryOn()
        state.begin()
        state.tryOn(neon)
        _ = state.keep()
        state.supportSheetClosed()
        state.end()
        let kept = state.purchaseCompleted()
        #expect(kept == nil)
        #expect(state.isSupporter)
        #expect(state.shown == .original)
    }

    @Test("Keep without support, then the purchase: now stored and shown")
    func keepThenBuy() {
        var state = LookTryOn()
        state.begin()
        state.tryOn(neon)
        _ = state.keep()
        let kept = state.purchaseCompleted()
        #expect(kept?.lookID == Look.neonNight.id)
        #expect(state.saved.lookID == Look.neonNight.id)
        #expect(state.shown.lookID == Look.neonNight.id)
        #expect(!state.isPreviewing)
    }

    @Test("Keep as a supporter stores right away")
    func keepAsSupporter() {
        var state = LookTryOn(isSupporter: true)
        state.begin()
        state.tryOn(neon)
        let result = state.keep()
        #expect(result == .kept)
        #expect(state.saved.lookID == Look.neonNight.id)
        #expect(!state.isPreviewing)
    }

    @Test("Keep without a preview does nothing")
    func keepIdle() {
        var state = LookTryOn(isSupporter: true)
        let result = state.keep()
        #expect(result == .nothing)
        #expect(state.saved == .original)
    }

    @Test("Trying on outside the preview is ignored")
    func tryOnIdle() {
        var state = LookTryOn()
        state.tryOn(neon)
        #expect(state.shown == .original)
    }

    // MARK: Support changing

    @Test("When support ends the original shows, the choice waits")
    func supportEnds() {
        var state = LookTryOn(saved: neon, isSupporter: true)
        state.setSupporter(false)
        #expect(state.shown == .original)
        #expect(state.saved == neon)
        state.setSupporter(true)
        #expect(state.shown == neon)
    }

    @Test("Choosing directly works only for supporters")
    func chooseDirectly() {
        var state = LookTryOn()
        let refused = state.choose(neon)
        #expect(!refused)
        #expect(state.shown == .original)
        state.setSupporter(true)
        let accepted = state.choose(neon)
        #expect(accepted)
        #expect(state.shown == neon)
    }

    @Test("Reset is a fresh install")
    func reset() {
        var state = LookTryOn(saved: neon, isSupporter: true)
        state.begin()
        state.reset()
        #expect(state == LookTryOn())
    }
}
