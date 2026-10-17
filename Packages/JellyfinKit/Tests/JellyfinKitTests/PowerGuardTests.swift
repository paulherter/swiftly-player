import Foundation
import Testing
@testable import JellyfinKit

@Suite("Stromwacht")
struct PowerGuardTests {

    /// The normal case: nothing going on, the picture has stood long enough, no jump,
    /// no buffer; that is a drop.
    private func rat(standstill: TimeInterval, change: TimeInterval? = nil,
                     jumpOpen: Bool = false, jumpForward: TimeInterval = 999,
                     bufferForward: TimeInterval = 999) -> StreamWatch.Rat {
        StreamWatch.rat(standstillSince: standstill, networkChangeForward: change,
                       jumpOpen: jumpOpen, lastJumpForward: jumpForward,
                       bufferGrewPre: bufferForward)
    }

    // MARK: - How long to wait

    @Test("Ohne Netzwechsel sechs Sekunden")
    func six() {
        #expect(rat(standstill: 5.9) == .notYet)
        #expect(rat(standstill: 6) == .newConnect)
    }

    @Test("Nach einem Netzwechsel nur zwei")
    func two() {
        // The reason is known, waiting brings nothing.
        #expect(rat(standstill: 1.9, change: 3) == .notYet)
        #expect(rat(standstill: 2, change: 3) == .newConnect)
    }

    @Test("Ein alter Netzwechsel erklärt nichts mehr")
    func oldSwitch() {
        // 91 s ago: no longer counts as fresh, so six seconds again.
        #expect(rat(standstill: 3, change: 91) == .notYet)
        #expect(rat(standstill: 3, change: 89) == .newConnect)
    }

    // MARK: - Nothing is torn down while alive

    @Test("Ein offener Sprung ist kein Abriss")
    func jumpOpen() {
        #expect(rat(standstill: 30, jumpOpen: true) == .jumpRunning)
    }

    @Test("Und zwanzig Sekunden nach dem Befehl auch nicht")
    func jumpIdle() {
        #expect(rat(standstill: 30, jumpForward: 19.9) == .jumpRunning)
        #expect(rat(standstill: 30, jumpForward: 20) == .newConnect)
    }

    @Test("Ein wachsender Puffer schlägt den Abriss")
    func buffer() {
        // The case where the brake once caused the hang.
        #expect(rat(standstill: 60, bufferForward: 3.9) == .bufferGrows)
        #expect(rat(standstill: 60, bufferForward: 4) == .newConnect)
    }

    @Test("Der Sprung schlägt den Puffer")
    func railsEpisode() {
        // Both apply: the message should name the jump, because that
        // is the shorter explanation.
        #expect(rat(standstill: 60, jumpForward: 1, bufferForward: 1) == .jumpRunning)
    }

    // MARK: - Edges

    @Test("Ohne Stillstand passiert nie etwas")
    func noStandstill() {
        #expect(rat(standstill: 0) == .notYet)
        #expect(rat(standstill: 0, change: 1) == .notYet)
    }

    @Test("Ohne je ein Bild kein Bildstillstand — Titel ohne Bildspur baut nie neu auf")
    func noImageNoStandstill() {
        #expect(StreamWatch.imagesState(before: nil, now: 0) == nil)
        #expect(StreamWatch.imagesState(before: 0, now: 0) == nil)
        #expect(StreamWatch.imagesState(before: 120, now: 120) == true)
        #expect(StreamWatch.imagesState(before: 120, now: 121) == false)
    }

    @Test("Byte-Zuwachs läuft nie unter null")
    func growthWithoutUnderRun() {
        #expect(StreamWatch.growth(500, since: 200) == 300)
        #expect(StreamWatch.growth(100, since: 90_000) == 0)
    }
}
