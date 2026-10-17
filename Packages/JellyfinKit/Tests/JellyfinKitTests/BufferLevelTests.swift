import Testing
@testable import JellyfinKit

@Suite("Pufferstufe")
struct BufferLevelTests {

    @Test("Normal faesst VLCs Zeitvorlauf nicht an")
    func normalLetsVLCInIdle() {
        #expect(BufferLevel.normal.networkLeadMilliseconds == nil)
        #expect(BufferLevel.normal.prefetchKiB == 16_384)
    }

    @Test("Jede Stufe haelt mehr als die davor")
    func levelsGrow() {
        let levels = BufferLevel.allCases
        for (a, b) in zip(levels, levels.dropFirst()) {
            #expect(a.prefetchKiB < b.prefetchKiB)
        }
    }

    /// The point the user's question hangs on: the same setting
    /// holds much less time at 4K than for a series.
    @Test("Dieselben Bytes sind je nach Bitrate ganz verschiedene Sekunden")
    func secondsAttachToBitrate() {
        let rung = BufferLevel.normal
        let series = rung.approxSeconds(bitsPerSecond: 5_000_000)
        let fourK = rung.approxSeconds(bitsPerSecond: 80_000_000)
        #expect(series != nil && fourK != nil)
        #expect(series! > 20 && series! < 30)
        #expect(fourK! < 3)
    }

    @Test("Ohne Bitrate keine erfundene Zahl")
    func withoutBitrateNil() {
        #expect(BufferLevel.bad.approxSeconds(bitsPerSecond: 0) == nil)
    }

    @Test("Die hoechste Stufe traegt auch bei 4K ueber eine halbe Minute")
    func veryRealCarriesAlso4K() {
        let s = BufferLevel.veryBad.approxSeconds(bitsPerSecond: 40_000_000)
        #expect(s != nil && s! >= 30)
    }
    /// **The naming first lived in the iPhone view.** The TV would not
    /// have seen it and would have rebuilt it, so it lives in the
    /// package, and that is why this test exists.
    @Test("Jede Stufe hat einen eigenen Namen")
    func namesPresentAndDistinct() {
        let names = BufferLevel.allCases.map(\.name)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == BufferLevel.allCases.count)
    }

}
