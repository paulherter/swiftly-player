import UIKit

/// The app's state as a readable word, for the log.
///
/// **For debugging only.** Playback paused as soon as the notification center was
/// pulled down, and twice the wrong source was suspected: first an audio
/// interruption (the log shows none), then `scenePhase`. Switching to
/// `didEnterBackgroundNotification` did not help either; it apparently really
/// fires. Before a third rule is added, the log should show what iOS reports and
/// what state the app is in at the time.
enum StatusWord {
    @MainActor static var now: String {
        switch UIApplication.shared.applicationState {
        case .active: "aktiv"
        case .inactive: "untaetig"
        case .background: "hintergrund"
        @unknown default: "?"
        }
    }
}
