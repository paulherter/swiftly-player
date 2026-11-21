/// **Where a page model's writes land.** The host sets `gate` to hold them while a page slides in (the Mac's push runs
/// on the main thread, and every state write in that time stops the slide for one frame block); all gated writes then
/// land together right after the slide. Unset, a write runs at once.
public enum PageLanding {
    @MainActor public static var gate: @MainActor (@escaping @MainActor () -> Void) -> Void = { $0() }
}

/// The loop every adapter shares: wait for the next change of the view model, re-read only the
/// parts whose bit is set. Returns when the calling Task is cancelled (or the model is gone).
@MainActor
func observeChanges(
    from seen: UInt64,
    changed: @escaping @Sendable (UInt64) async throws -> Change,
    apply: @MainActor (Change) -> Void
) async {
    var seen = seen
    while !Task.isCancelled {
        do {
            let change = try await changed(seen)
            seen = change.version
            apply(change)
        } catch {
            return  // cancelled
        }
    }
}

/// The same loop for the page models (`DetailModel`, `SeriesModel`): each change is applied through `PageLanding.gate`,
/// so while a page slides in the writes wait and land together right after.
@MainActor
func observePageChanges(
    from seen: UInt64,
    changed: @escaping @Sendable (UInt64) async throws -> Change,
    apply: @escaping @MainActor (Change) -> Void
) async {
    var seen = seen
    while !Task.isCancelled {
        do {
            let change = try await changed(seen)
            seen = change.version
            PageLanding.gate { apply(change) }
        } catch {
            return  // cancelled
        }
    }
}

/// Polls `ready` after every change of the view model until it says yes. `false` after `timeout`, on
/// cancel, or when the view model is gone.
@MainActor
func settle(
    timeout: Duration,
    ready: @escaping @MainActor () -> Bool,
    changed: @escaping @Sendable (UInt64) async throws -> UInt64,
    version: @escaping @Sendable () -> UInt64
) async -> Bool {
    let work = Task { @MainActor () -> Bool in
        while !Task.isCancelled {
            let seen = version()
            if ready() { return true }
            do { _ = try await changed(seen) } catch { return false }
        }
        return false
    }
    let timer = Task {
        try? await Task.sleep(for: timeout)
        work.cancel()
    }
    let done = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    timer.cancel()
    return done
}
