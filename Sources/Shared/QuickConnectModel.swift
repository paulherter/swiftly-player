import Foundation
import JellyfinKit
import Observation

/// The flow behind Quick Connect: fetch a code, wait, approved.
///
/// This used to live in `QuickConnectLogin`, a view only the iPhone
/// compiles. But it is flow, not appearance: how often to ask, how long a code
/// is valid, how a superseded wait loop notices it was superseded. The same flow
/// applies on TV, where Quick Connect is the more important path because typing a
/// password with a remote is a burden.
///
/// What the view does afterwards is its own decision: the iPhone closes the sheet
/// first and then signs in, the TV signs in directly.
@MainActor
@Observable
final class QuickConnectModel {
    private(set) var preGait: LoginCode?
    private(set) var error: String?
    private(set) var secondsLeft = QuickConnectDeadline.seconds
    /// Set as soon as someone has approved the code. The view signs in with it.
    private(set) var released: LoginCode?
    /// On the server currently being added, instead of the one the app is connected
    /// to. See `ServerOnboardingView`.
    var newServer = false

    /// Counts up when a new code is fetched; a superseded start sees by it that it
    /// was superseded and stops.
    private var run = 0
    /// The running wait. Cancelled on stop so no more polls go out and a late
    /// approval signs nobody in.
    private var waitTask: Task<Void, Never>?

    func newStart(_ model: AppModel) async {
        halt()
        let myOwn = run
        error = nil
        preGait = nil
        released = nil
        secondsLeft = QuickConnectDeadline.seconds
        do {
            let new = try await (newServer ? model.quickConnectStartAtNewServer()
                                             : model.quickConnectStart())
            guard myOwn == run else { return }
            preGait = new
            let task = Task { await wait(on: new, run: myOwn, model: model) }
            waitTask = task
            // The view's `.task` cancels, and so does the wait.
            await withTaskCancellationHandler { await task.value }
                onCancel: { task.cancel() }
        } catch {
            guard myOwn == run else { return }
            self.error = model.readable(error)
        }
    }

    /// **The flow lives in the core** (`AccountsModel.quickConnectWait`): deadline on the
    /// clock, polling on a tick, a network error does not end the wait, and the sign-in
    /// happens there the moment someone approves. Before, the first failed request aborted
    /// everything, on the iPhone exactly when coming back from Safari with the
    /// connection dropped in the background.
    private func wait(on preGait: LoginCode, run myOwn: Int, model: AppModel) async {
        let outcome = await model.quickConnectWait(preGait, atNewServer: newServer) { [weak self] seconds in
            Task { @MainActor in
                guard let self, myOwn == self.run else { return }
                self.secondsLeft = Int(seconds)
            }
        }
        guard myOwn == run, !Task.isCancelled else { return }
        switch outcome {
        case .approved:
            run += 1
            released = preGait
        case let .ended(text):
            secondsLeft = 0
            error = text
        case let .failed(text):
            error = text
        case .stopped:
            break
        }
    }

    /// Stops a running wait loop, when the view closes.
    func halt() {
        run += 1
        waitTask?.cancel()
        waitTask = nil
    }
}
