import SwiftUI

/// **The one gate for everything that lands on a page while it slides in.**
///
/// The Mac's push is a SwiftUI `.offset` that the main thread advances frame by frame. Whatever else writes view
/// state in that time (a server answer, a model update, a picture stepping from placeholder to picture, the tint)
/// makes SwiftUI rebuild and lay out part of the page in the same pass, the slide stops for that block, then jumps.
/// So every such write goes through `land`: while a slide runs it is queued, and all queued writes run together,
/// in order, in ONE transaction without animation right after the slide ends. Without a slide it runs at once.
/// Fetching and decoding keep running during the slide (off the main thread); only the write waits.
/// Slots and skeletons of final size keep the layout, so nothing jumps when the writes land.
@MainActor
final class TravelGate {
    private var end: ContinuousClock.Instant
    private var queue: [@MainActor () -> Void] = []
    private var flusher: Task<Void, Never>?
    private let clock = ContinuousClock()

    init() { end = clock.now }

    /// A slide is running.
    var travelling: Bool { end > clock.now }
    /// How many writes wait for the end of the slide.
    var waiting: Int { queue.count }

    /// A page starts sliding for `duration`.
    /// A second slide that begins during the first (back or forward in a hurry) pushes the end out.
    func begins(for duration: Duration) {
        let new = clock.now + duration
        if new > end { end = new }
    }

    /// The slide has really ended (its animation reports completion): everything that waited lands now.
    func ends() {
        end = clock.now
        flusher?.cancel()
        flush()
    }

    /// Runs `work` now, or right after the slide has ended, together with everything else that waited.
    func land(_ work: @escaping @MainActor () -> Void) {
        guard travelling || !queue.isEmpty else { work(); return }
        queue.append(work)
        arm()
    }

    private func arm() {
        guard flusher == nil else { return }
        flusher = Task { @MainActor [weak self] in
            // A slide that began meanwhile moved the end; sleep again until it has really passed.
            while let self, self.end > self.clock.now {
                try? await Task.sleep(until: self.end, clock: .continuous)
            }
            self?.flush()
        }
    }

    /// Runs everything that waited, in order, in one transaction.
    func flush() {
        flusher = nil
        let work = queue
        queue.removeAll()
        guard !work.isEmpty else { return }
        withTransaction(Transaction(animation: nil)) { work.forEach { $0() } }
    }
}

/// The Mac's page slide (`Navigator`, `MainView`): the gate every page-kind loader writes through.
@MainActor
enum InTravel {
    static let gate = TravelGate()

    /// Called by `MainView` when a new page starts sliding in.
    static func begins(seconds: Double = 0.45) {
        // One frame of slack: the last frame of the slide still belongs to it.
        gate.begins(for: .milliseconds(Int(seconds * 1000) + 30))
    }

    /// The slide's animation completed: waiting writes land now, not at the failsafe end `begins` set.
    static func ends() { gate.ends() }

    /// Applies `work` once no page is sliding (at once when none is), together with all other waiting writes.
    static func land(_ work: @escaping @MainActor () -> Void) { gate.land(work) }

    /// Returns as soon as no page is sliding (after the writes that waited have landed).
    static func waitFor() async {
        guard gate.travelling || gate.waiting > 0 else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in gate.land { done.resume() } }
    }
}
