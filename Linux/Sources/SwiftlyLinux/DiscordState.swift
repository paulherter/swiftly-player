import Foundation
import JellyfinKit

/// **Between the player and Discord, and the place that decides whether
/// anything is sent at all.**
///
/// Counterpart of `DiscordIndicator` on the Apple versions. Not a copy: the
/// bridge and the display live in the package and are only driven from here.
/// The difference is the driver: there the playback hub reports, here the
/// player's tick.
///
/// **On the Mac this cannot work** because the sandbox does not allow the
/// socket; here there is no sandbox. See ``Discordbruecke`` for details.
///
/// **`nonisolated(unsafe)` instead of `@MainActor`, like the rest of this
/// version.** On the Apple versions everything touching the UI is bound to the
/// main actor. Not here: GTK callbacks come from C and carry no isolation, and
/// `App` itself is `nonisolated(unsafe)` in `main.swift` for the same reason.
/// An `@MainActor` here broke the build in three places, rightly.
///
/// It is still not a free pass: all three callers run in the player's tick or
/// in a switch handler, i.e. on the GTK thread. No second thread enters here.
enum DiscordState {

    /// A **dedicated** application, not the notification bot's. Rich Presence needs
    /// none of its own, and a second one would list the same name twice.
    private static let bridge = DiscordBridge(hostApp: "1547651294335078534")
    nonisolated(unsafe) private static var lastState = ""
    nonisolated(unsafe) private static var recent: DiscordDisplay?
    nonisolated(unsafe) private static var ran = false

    /// **One chain, so the order holds.**
    ///
    /// Symptom: an episode that starts mid-way showed **nothing**, while a seek
    /// within the same episode did.
    ///
    /// Cause: leaving the player clears and starting reports, and both ran as
    /// separate unstructured tasks, which have no ordering between them. If the
    /// clearing arrived second, it deleted the presence just set. A seek clears
    /// nothing, so it worked there.
    ///
    /// Not a rare race: leaving and starting happen in the same step when someone
    /// picks the next episode from inside the player.
    nonisolated(unsafe) private static var chain: Task<Void, Never>?

    private static func inRails(_ labor: @escaping @Sendable () async -> Void) {
        let before = chain
        chain = Task {
            await before?.value
            await labor()
        }
    }

    /// Called by the player's tick on every state change.
    static func report(title: String, subline: String?, spot: Double,
                       duration: Double, running: Bool, allowed: Bool) {
        // **Only send when something changes, not every second.**
        //
        // Both exits of this function used to be silent, so "switch is off", "runtime
        // not ready" and "nothing changed" were indistinguishable. A diagnostic line
        // once per second fixed that, but a paused movie then repeated the same line
        // fifty times and pushed everything else out of the log. A tool that obscures
        // the view it is meant to provide is useless.
        let state = "erlaubt=\(allowed) dauer=\(Int(duration)) laeuft=\(running) titel=\(title)"
        if state != Self.lastState {
            Self.lastState = state
            TrackSupport.sag("[Discord] Stand: \(state) stelle=\(Int(spot))")
        }
        guard allowed else { tidyAway(); return }

        // Paused means: no progress bar, but still visible. A bar that runs while the
        // picture is still claims something false.
        // **Send nothing without a runtime.**
        //
        // While VLC does not yet know the runtime, `dauer` is zero. Start and end
        // would then go out as `nil`, and Discord shows its **own** counter. It starts
        // at zero when the presence appears and keeps running; it looks like ours but
        // is Discord's and knows nothing about the episode.
        //
        // So report only once the runtime is known. A few ticks later is better than
        // immediately and wrong.
        guard duration > 0 else { return }

        // **Paused: no progress bar, but the position in the text.**
        //
        // Discord has no "paused" state. Omitting start and end makes it show its own
        // counter, which keeps running. The only option is to omit the bar **and** say
        // where playback is, so nothing claims anything false.
        let now = Date()
        let addition = running ? nil : "\(PlayTime.text(spot)) / \(PlayTime.text(duration))"
        let row = [subline, addition].compactMap { $0 }.joined(separator: " · ")
        let display = DiscordDisplay(
            title: title,
            subline: row.isEmpty ? nil : row,
            from: running ? now.addingTimeInterval(-spot) : nil,
            until: running ? now.addingTimeInterval(duration - spot) : nil)

        // Only send on a real change; the tick runs several times per second.
        // `DiscordDisplay` compares timestamps to the second, otherwise every
        // comparison would differ.
        guard display != recent else { return }
        recent = display
        ran = true
        inRails { await bridge.showItem(display) }
    }

    /// Show nothing anymore: when switched off, and when leaving the player.
    static func tidyAway() {
        guard ran else { return }
        ran = false
        recent = nil
        inRails { await bridge.showItem(nil) }
    }
}
