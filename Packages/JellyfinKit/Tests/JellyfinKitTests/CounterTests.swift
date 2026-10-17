import Foundation
import Testing
@testable import JellyfinKit

@Suite("Zaehlwerk")
struct CounterTests {

    private func raw(shown: UInt64 = 0, decoded: UInt64 = 0,
                     hasRead: UInt64 = 0, unpacked: UInt64 = 0) -> Counter.RawValues {
        .init(hasRead: hasRead, unpacked: unpacked, shown: shown, videoBlocks: decoded)
    }

    @Test("Speicherschrott wird nicht als Messung ausgegeben")
    func junkRejected() {
        // `statistics` returns the structure even when the media has none
        // yet; the fields then hold whatever happened to be in
        // memory.
        var r = raw()
        r.shown = Counter.limit + 1
        #expect(Counter(r, spot: 0, running: true) == nil)
    }

    @Test("Vor dem Mindestfenster wird nichts gemeldet")
    func tooEarly() {
        let start = Date()
        let a = Counter(raw(shown: 0), spot: 0, running: true, now: start)!
        let b = Counter(raw(shown: 48), spot: 2, running: true, before: a,
                          now: start.addingTimeInterval(2))!
        // Two seconds are about forty-eight frames, and still not a
        // measurement: a short window catches VLC's bursts by chance.
        #expect(b.showsProSecond == nil)
        #expect(b.runShare == nil)
    }

    @Test("Ueber dem Mindestfenster stimmen die Raten")
    func rateMatches() {
        let start = Date()
        let a = Counter(raw(shown: 0, decoded: 0), spot: 0, running: true, now: start)!
        let b = Counter(raw(shown: 240, decoded: 240), spot: 10, running: true,
                          before: a, now: start.addingTimeInterval(10))!
        #expect(abs((b.showsProSecond ?? 0) - 24) < 0.001)
        #expect(abs((b.decodedProSecond ?? 0) - 24) < 0.001)
        // Ten seconds of film in ten seconds of clock: real time.
        #expect(abs((b.runShare ?? 0) - 1) < 0.001)
    }

    @Test("Haengen zeigt sich am Lauf, nicht an den gezeigten Bildern")
    func hangingVisible() {
        // The actual reason for `runShare`: VLC redraws a frozen
        // picture and counts every repeat, so while stalling `shown`
        // runs *faster*. This once showed 1015 displayed frames at
        // position 0:28 where 671 would have been right.
        let start = Date()
        let a = Counter(raw(shown: 0), spot: 0, running: true, now: start)!
        let b = Counter(raw(shown: 1015), spot: 28, running: true, before: a,
                          now: start.addingTimeInterval(28))!
        #expect((b.showsProSecond ?? 0) > 30)     // looks healthy
        #expect((b.runShare ?? 0) == 1)          // and is here too
        // If the position falls behind, only the run share says so.
        let c = Counter(raw(shown: 2000), spot: 42, running: true, before: a,
                          now: start.addingTimeInterval(56))!
        #expect((c.runShare ?? 0) < 0.8)
    }

    @Test("Ein Sprung setzt das Fenster zurueck")
    func jumpSetsBack() {
        let start = Date()
        let a = Counter(raw(shown: 100), spot: 10, running: true, now: start)!
        // From 10 s to 600 s: the counters keep running, the position jumps.
        let b = Counter(raw(shown: 220), spot: 600, running: true, before: a,
                          now: start.addingTimeInterval(5))!
        #expect(b.runShare == nil)
        #expect(b.basePoint == 600)
    }

    @Test("Im Stillstand faengt das Fenster von vorn an")
    func pauseCountsNot() {
        // The ramp-up once counted too: `Run` stayed at 70 percent for the
        // whole intro without anything stalling.
        let start = Date()
        let a = Counter(raw(shown: 0), spot: 0, running: false, now: start)!
        let b = Counter(raw(shown: 0), spot: 0, running: false, before: a,
                          now: start.addingTimeInterval(25))!
        #expect(b.runShare == nil)
        #expect(b.baseTime == b.measuredAt)
    }

    @Test("Der Vorrat ist gelesen minus entpackt")
    func preAdvice() {
        let w = Counter(raw(hasRead: 18_000_000, unpacked: 2_000_000),
                          spot: 5, running: true)!
        #expect(w.preAdviceBytes == 16_000_000)
        // 16 MiB at 100 kB/s is 160 seconds.
        #expect(abs((w.reserveSeconds(bytesJeSecond: 100_000) ?? 0) - 160) < 0.001)
        #expect(w.reserveSeconds(bytesJeSecond: 0) == nil)
    }

    @Test("Beim ersten Mal steht kein Strich fuer eine Null")
    func firstMeasurementWithoutRate() {
        let w = Counter(raw(hasRead: 5000), spot: 0, running: true)!
        #expect(w.input == nil)
        #expect(w.demuxer == nil)
    }

    @Test("Die Eingangsrate rechnet aus zwei Summen")
    func inputRate() {
        let start = Date()
        let a = Counter(raw(hasRead: 0), spot: 0, running: true, now: start)!
        let b = Counter(raw(hasRead: 125_000), spot: 1, running: true, before: a,
                          now: start.addingTimeInterval(1))!
        // 125,000 bytes in one second is one million bits.
        #expect(abs((b.input ?? 0) - 1_000_000) < 1)
    }
}
