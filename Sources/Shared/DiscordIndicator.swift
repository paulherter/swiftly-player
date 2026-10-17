import Foundation
import JellyfinKit

/// **Between the player and Discord, and the place where it is decided whether
/// anything goes out at all.**
///
/// The bridge in the package can send; whether it may is decided here. Keeping
/// them apart is intentional: a class that serves a socket connection should not
/// read settings, and a place that reads a setting should not know what a frame
/// looks like.
///
/// **Driven by ``PlaybackHub``**, not by one call in every player. Every
/// version reports title, position and whether it is playing there on every state
/// change anyway; that is exactly what is needed here, and it costs the platforms
/// no line. The same reasoning as ``Spielstand``: one shared place instead of a
/// callback per version that one of them can forget.
@MainActor
final class DiscordIndicator {

    static let shared = DiscordIndicator()

    /// **Its own application, not the notification bot's.**
    ///
    /// Technically one container carries both. But the application name is exactly
    /// what Discord shows as the heading of the presence; if bot and presence hang on
    /// the same one, changing one changes the other. Two unrelated things on one
    /// screw.
    private static let hostApp = "1547651294335078534"

    private let bridge = DiscordBridge(hostApp: hostApp)
    /// What went out last. Discord does not want the same thing again on every tick,
    /// and the player reports several times per second.
    private var recent: DiscordDisplay?
    private var ran = false

    private init() {}

    /// Called by the path via ``PlaybackHub``.
    /// **This place reads the switch itself.**
    ///
    /// It could also be passed through, but then every version would have to hand it
    /// to `PlaybackHub.report`, a signature that iPhone, iPad, TV and Mac call
    /// together. For a boolean that sits in the same store anyway, that would be four
    /// changes to other people's files for nothing.
    func report(title: String, subline: String?, spot: Double, duration: Double,
                running: Bool) {
        guard UserDefaults.standard.bool(forKey: "discordAnzeigen") else {
            tidyAway()
            return
        }

        // **Paused means: no bar, but still visible.** A bar that runs while the picture
        // stands is worse than none, as it claims something untrue. The title stays
        // anyway; someone who pauses is still watching.
        // **Without a runtime, send nothing.**
        //
        // The number always starts at zero and keeps running, even when paused. The
        // cause is here: as long as VLC does not know the runtime yet, `dauer` is zero,
        // so start and end went out as `nil`, and in that case Discord shows its **own**
        // counter. It starts at zero when the presence appears and just keeps running;
        // it looks like our number but is its own and knows nothing about the episode.
        //
        // So report only once the runtime is known. A few ticks later is better than
        // immediately and wrong.
        guard duration > 0 else { return }

        // **Paused: no bar, but the position in the text.**
        //
        // Discord has no "paused". If start and end are left out, its own counter
        // appears and happily keeps running, exactly what was reported. So all that is
        // left is to omit the bar **and** say where it stands; then nothing claims
        // anything false.
        let now = Date()
        let addition = running ? nil : "\(PlayTime.text(spot)) / \(PlayTime.text(duration))"
        let row = [subline, addition].compactMap { $0 }.joined(separator: " · ")
        let display = DiscordDisplay(
            title: title,
            subline: row.isEmpty ? nil : row,
            from: running ? now.addingTimeInterval(-spot) : nil,
            until: running ? now.addingTimeInterval(duration - spot) : nil)

        // **Send only on a real change.**
        //
        // Without this comparison a frame would go out on every tick, several times per
        // second. The timestamps drift by fractions because they derive from `Date()`
        // and the position, so `DiscordDisplay` compares them to the second, not to the
        // instant. Otherwise every comparison would differ and the guard would do
        // nothing.
        guard display != recent else { return }
        recent = display
        ran = true
        Task { await bridge.showItem(display) }
    }

    /// Show nothing anymore: when switched off, on leaving the player, on quit.
    func tidyAway() {
        guard ran else { return }
        ran = false
        recent = nil
        Task { await bridge.showItem(nil) }
    }
}
