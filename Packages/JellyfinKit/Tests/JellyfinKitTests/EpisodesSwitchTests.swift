import Foundation
import Testing
@testable import JellyfinKit

/// Switching episodes as a state machine, covering the cases from the
/// audit, without player and without server.
@MainActor
@Suite("Folgenwechsel")
struct EpisodesSwitchTests {

    /// Holds a request until the test releases it.
    actor Tor {
        private var opened = false
        private var waitingOnes: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waitingOnes.append($0) }
        }
        func open() {
            opened = true
            waitingOnes.forEach { $0.resume() }
            waitingOnes = []
        }
    }

    /// What went to the "server", in order.
    actor Book {
        private(set) var entries: [String] = []
        func writeOut(_ s: String) { entries.append(s) }
        func count(_ s: String) -> Int { entries.filter { $0 == s }.count }
    }

    @MainActor final class HostView {
        var applied: [String] = []
        var failed = 0
    }

    private func steps(book: Book, viewRef: HostView, plan: String? = "plan-2",
                          planTor: Tor? = nil, startTor: Tor? = nil)
        -> EpisodeSwitch.Steps<String> {
        .init(
            stopNow: { await book.writeOut("stopp-1") },
            planOut: {
                await book.writeOut("plant")
                await planTor?.wait()
                return plan
            },
            apply: { viewRef.applied.append($0) },
            start: { p in
                await book.writeOut("start-" + p)
                await startTor?.wait()
                await book.writeOut("gestartet")
            },
            failed: { viewRef.failed += 1 })
    }

    private func until(_ requirement: () async -> Bool) async {
        for _ in 0..<10_000 {
            if await requirement() { return }
            await Task.yield()
        }
        Issue.record("Bedingung nie erreicht")
    }

    @Test("Zweiter Auslöser während des Wechsels wird gesperrt; ein Stopp, ein Start")
    func doubleTrigger() async {
        let w = EpisodeSwitch(), book = Book(), viewRef = HostView(), tor = Tor()
        let firstOne = Task { await w.execute(steps(book: book, viewRef: viewRef, planTor: tor)) }
        await until { await book.count("plant") == 1 }
        #expect(w.running)
        #expect(!w.messagesAllowed)

        let second = await w.execute(steps(book: book, viewRef: viewRef))
        #expect(second == .locked)

        await tor.open()
        #expect(await firstOne.value == .switched)
        #expect(await book.count("stopp-1") == 1)
        #expect(await book.count("start-plan-2") == 1)
        #expect(viewRef.applied == ["plan-2"])
        #expect(!w.running)
        #expect(w.messagesAllowed)
    }

    @Test("Schließen während des Planholens: nichts wird angewandt, nichts gestartet")
    func closePlan() async {
        let w = EpisodeSwitch(), book = Book(), viewRef = HostView(), tor = Tor()
        let run = Task { await w.execute(steps(book: book, viewRef: viewRef, planTor: tor)) }
        await until { await book.count("plant") == 1 }

        w.close { await book.writeOut("stopp-schliessen") }
        await tor.open()

        #expect(await run.value == .cancelled)
        #expect(viewRef.applied.isEmpty)
        #expect(await book.count("start-plan-2") == 0)
        await until { await book.count("stopp-schliessen") == 1 }
        #expect(w.phase == .closed)
        // After closing, no new switch starts.
        #expect(await w.execute(steps(book: book, viewRef: viewRef)) == .locked)
    }

    @Test("Schließen während der Start unterwegs ist: Stopp erst nach dem Start")
    func closeStart() async {
        let w = EpisodeSwitch(), book = Book(), viewRef = HostView(), tor = Tor()
        let run = Task { await w.execute(steps(book: book, viewRef: viewRef, startTor: tor)) }
        await until { await book.count("start-plan-2") == 1 }

        w.close { await book.writeOut("stopp-2") }
        // Not yet: the start has not returned.
        for _ in 0..<50 { await Task.yield() }
        #expect(await book.count("stopp-2") == 0)

        await tor.open()
        #expect(await run.value == .cancelled)
        // Stopping the old episode and fetching the plan run side by side; their
        // order is open, the rest is not.
        let entries = await book.entries
        #expect(Array(entries.suffix(3)) == ["start-plan-2", "gestartet", "stopp-2"])
        #expect(Set(entries.prefix(2)) == ["stopp-1", "plant"])
    }

    @Test("Kein Plan: Hinweis, Riegel fällt, der nächste Versuch geht")
    func planMissing() async {
        let w = EpisodeSwitch(), book = Book(), viewRef = HostView()
        #expect(await w.execute(steps(book: book, viewRef: viewRef, plan: nil)) == .failed)
        #expect(viewRef.failed == 1)
        #expect(viewRef.applied.isEmpty)
        #expect(await book.count("start-plan-2") == 0)
        #expect(!w.running)
        #expect(await w.execute(steps(book: book, viewRef: viewRef)) == .switched)
    }

    @Test("Zweites Schließen tut nichts")
    func twoTimesClose() async {
        let w = EpisodeSwitch(), book = Book()
        w.close { await book.writeOut("stopp") }
        w.close { await book.writeOut("stopp") }
        await until { await book.count("stopp") == 1 }
        for _ in 0..<50 { await Task.yield() }
        #expect(await book.count("stopp") == 1)
    }

    @Test("Nachschlag nach einem neuen Wechsel oder nach dem Schließen wird verworfen")
    func lookupAgain() async {
        let w = EpisodeSwitch(), book = Book(), viewRef = HostView(), tor = Tor()
        var adopted: [String] = []

        await w.lookUp(fetch: { "folge-3" }, adopt: { adopted.append($0) })
        #expect(adopted == ["folge-3"])

        let alt = Task { @MainActor in
            await w.lookUp(fetch: { await tor.wait(); return "alt" },
                                 adopt: { adopted.append($0) })
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(await w.execute(steps(book: book, viewRef: viewRef)) == .switched)
        await tor.open()
        await alt.value
        #expect(adopted == ["folge-3"])

        w.close {}
        await w.lookUp(fetch: { "zu" }, adopt: { adopted.append($0) })
        #expect(adopted == ["folge-3"])
    }
}

@Suite("Stoppsperre")
struct StopLockTests {

    @Test("Stopp genau einmal je Sitzung, Fortschritt danach verworfen")
    func inTimes() {
        let s = StopLock()
        let k = StopLock.key(itemID: "a", playSessionID: "p1")
        #expect(s.progressAllowed(k))
        #expect(s.stopAccept(k))
        #expect(!s.stopAccept(k))
        #expect(!s.progressAllowed(k))
        // Another session of the same title is free.
        #expect(s.stopAccept(StopLock.key(itemID: "a", playSessionID: "p2")))
    }

    @Test("Gescheiterter Stopp und neuer Start geben frei")
    func share() {
        let s = StopLock()
        let k = StopLock.key(itemID: "a", playSessionID: nil)
        #expect(s.stopAccept(k))
        s.stopFailed(k)
        #expect(s.stopAccept(k))
        s.started(k)
        #expect(s.progressAllowed(k))
        #expect(s.stopAccept(k))
    }
}
