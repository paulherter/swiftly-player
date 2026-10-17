import Foundation
import Testing
@testable import JellyfinKit

/// The queue against a simulated server: slow, dead or faulty.
@Suite("Meldewarteschlange")
struct ReportQueueTests {

    typealias Rail = ReportQueue<Double>

    /// What the "server" received, in which order.
    final class WithFont: @unchecked Sendable {
        private let lock = NSLock()
        private var _rows: [String] = []
        func write(_ row: String) {
            lock.lock(); _rows.append(row); lock.unlock()
        }
        var rows: [String] { lock.lock(); defer { lock.unlock() }; return _rows }
    }

    static func row(_ m: Rail.Message) -> String {
        switch m.art {
        case .start: return "start \(Int(m.payload))"
        case let .progress(paused): return "fortschritt \(Int(m.payload))\(paused ? " pause" : "")"
        case .stop: return "stopp \(Int(m.payload))"
        }
    }

    static func message(_ art: Rail.Art, _ seconds: Double, session: String = "a") -> Rail.Message {
        .init(art: art, key: StopLock.key(itemID: "t", playSessionID: session),
              payload: seconds)
    }

    @Test("Start → Fortschritt → Stopp bleibt, auch wenn der Start langsam ist")
    func orderOnSlowStart() async {
        let withFont = WithFont()
        let rail = Rail { m in
            try? await Task.sleep(for: .milliseconds(m.art == .start ? 300 : 100))
            withFont.write(Self.row(m))
        }
        // Stop right behind the slow start: only after it.
        rail.report(Self.message(.start, 0))
        #expect(await rail.reportAndWait(Self.message(.stop, 1)) == .sent)
        // Progress already on its way, stop follows behind.
        rail.report(Self.message(.start, 1))
        async let progress = rail.reportAndWait(Self.message(.progress(paused: false), 10))
        try? await Task.sleep(for: .milliseconds(350))
        let result = await rail.reportAndWait(Self.message(.stop, 12))
        #expect(await progress == .sent)
        #expect(result == .sent)
        #expect(withFont.rows == ["start 0", "stopp 1", "start 1", "fortschritt 10", "stopp 12"])
    }

    @Test("Stopp der alten Sitzung vor Start der neuen")
    func switchRailsEpisode() async {
        let withFont = WithFont()
        let rail = Rail { m in
            if m.art == .stop { try? await Task.sleep(for: .milliseconds(200)) }
            withFont.write(Self.row(m) + " " + m.key)
        }
        rail.report(Self.message(.stop, 1400, session: "alt"))
        let result = await rail.reportAndWait(Self.message(.start, 0, session: "neu"))
        #expect(result == .sent)
        #expect(withFont.rows == ["stopp 1400 sitzung:alt", "start 0 sitzung:neu"])
    }

    @Test("Melden kehrt sofort zurück, auch wenn der Server hängt")
    func reportDoesNotBlock() async {
        let rail = Rail(deadline: .seconds(5)) { _ in
            try await Task.sleep(for: .seconds(60))
        }
        let clock = ContinuousClock()
        let duration = clock.measure {
            rail.report(Self.message(.start, 0))
            for s in 1...20 { rail.report(Self.message(.progress(paused: false), Double(s))) }
        }
        #expect(duration < .milliseconds(50))
    }

    @Test("Fortschritt wird zusammengefasst, nicht gestapelt")
    func merge() async {
        let withFont = WithFont()
        let rail = Rail { m in
            if m.art == .start { try? await Task.sleep(for: .milliseconds(200)) }
            withFont.write(Self.row(m))
        }
        rail.report(Self.message(.start, 0))
        for s in [10.0, 20, 30, 40] {
            rail.report(Self.message(.progress(paused: false), s))
        }
        let result = await rail.reportAndWait(Self.message(.progress(paused: true), 41))
        #expect(result == .sent)
        #expect(withFont.rows == ["start 0", "fortschritt 41 pause"])
    }

    @Test("Ein ersetzter Fortschritt, auf den jemand wartet, bekommt das Ergebnis des neuen")
    func setsWaiting() async {
        let rail = Rail { m in
            if m.art == .start { try? await Task.sleep(for: .milliseconds(200)) }
        }
        rail.report(Self.message(.start, 0))
        async let firstOne = rail.reportAndWait(Self.message(.progress(paused: false), 10))
        try? await Task.sleep(for: .milliseconds(50))
        rail.report(Self.message(.progress(paused: false), 20))
        #expect(await firstOne == .sent)
    }

    @Test("Frist: ein toter Server hält die nächste Meldung nicht auf")
    func deadlineWithoutBlockade() async {
        let withFont = WithFont()
        let rail = Rail(deadline: .milliseconds(150)) { m in
            if m.art == .start { try await Task.sleep(for: .seconds(60)) }
            withFont.write(Self.row(m))
        }
        let clock = ContinuousClock()
        let beginning = clock.now
        async let start = rail.reportAndWait(Self.message(.start, 0))
        let progress = await rail.reportAndWait(Self.message(.progress(paused: false), 10))
        let lapsed = clock.now - beginning
        #expect(await start == .timeOverStep)
        #expect(progress == .sent)
        #expect(lapsed < .seconds(2))
        #expect(withFont.rows == ["fortschritt 10"])
    }

    @Test("Ein Fehler blockiert nichts")
    func errorDoesNotBlock() async {
        struct Broken: Error {}
        let withFont = WithFont()
        let rail = Rail { m in
            if m.art == .start { throw Broken() }
            withFont.write(Self.row(m))
        }
        async let start = rail.reportAndWait(Self.message(.start, 0))
        let progress = await rail.reportAndWait(Self.message(.progress(paused: false), 10))
        #expect(await start == .failed)
        #expect(progress == .sent)
    }

    @Test("Stoppsperre: doppelter Stopp und Fortschritt danach verworfen, Start gibt frei")
    func barrier() async {
        let withFont = WithFont()
        let rail = Rail { m in withFont.write(Self.row(m)) }
        rail.report(Self.message(.start, 0))
        #expect(await rail.reportAndWait(Self.message(.stop, 5)) == .sent)
        #expect(await rail.reportAndWait(Self.message(.stop, 5)) == .discarded)
        #expect(rail.report(Self.message(.progress(paused: true), 6)) == false)
        #expect(rail.progressAllowed(StopLock.key(itemID: "t", playSessionID: "a")) == false)
        rail.report(Self.message(.start, 5))
        #expect(await rail.reportAndWait(Self.message(.progress(paused: false), 7)) == .sent)
        #expect(withFont.rows == ["start 0", "stopp 5", "start 5", "fortschritt 7"])
    }

    @Test("Ein gescheiterter Stopp gibt frei, der nächste geht")
    func failedStop() async {
        struct Broken: Error {}
        let attempts = WithFont()
        let rail = Rail { m in
            attempts.write(Self.row(m))
            if attempts.rows.count == 1 { throw Broken() }
        }
        #expect(await rail.reportAndWait(Self.message(.stop, 5)) == .failed)
        #expect(await rail.reportAndWait(Self.message(.stop, 5)) == .sent)
        #expect(attempts.rows == ["stopp 5", "stopp 5"])
    }

    @Test("Der Stopp nimmt den ungesendeten Fortschritt seiner Sitzung mit")
    func stopTakesProgressWith() async {
        let withFont = WithFont()
        let rail = Rail { m in
            if m.art == .start { try? await Task.sleep(for: .milliseconds(200)) }
            withFont.write(Self.row(m))
        }
        rail.report(Self.message(.start, 0))
        async let progress = rail.reportAndWait(Self.message(.progress(paused: false), 10))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await rail.reportAndWait(Self.message(.stop, 11)) == .sent)
        #expect(await progress == .discarded)
        #expect(withFont.rows == ["start 0", "stopp 11"])
    }
}
