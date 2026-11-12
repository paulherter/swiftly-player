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
