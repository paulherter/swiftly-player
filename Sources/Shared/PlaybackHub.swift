#if !os(macOS)
import AVFoundation
import UIKit
/// What `MPMediaItemArtwork` expects on this platform.
typealias SystemImage = UIImage
#else
import AppKit
typealias SystemImage = NSImage
#endif
import Foundation
import JellyfinKit
import MediaPlayer

/// What the system needs to know about the current playback.
///
/// Two things that were missing although the app claims the audio background
/// mode:
///
/// 1. **Lock screen and Control Center.** Without `MPNowPlayingInfoCenter`
///    nothing shows there and the headphone button does nothing. Apple treats
///    use of this interface as proof the background mode is justifiably
///    claimed - apps without it are regularly flagged.
/// 2. **Interruptions.** On a call iOS takes the audio session away. Without
///    listening, everything stays stopped afterwards while the UI keeps
///    claiming it is playing.
///
/// **The last state a player reported - position and whether it plays.**
///
/// Each platform calls ``Wiedergabezentrale/melden(item:position:dauer:tempo:laeuft:sprungweite:imageUrl:)``
/// on every state change with fresh values so the lock screen is right. That
/// puts here what was missing somewhere else entirely, for all versions at once.
///
/// **What for.** When a remote command arrives from the server - someone presses
/// pause in Jellyfin - the app obeys at once but only reported it to the server
/// at the next regular tick. In the overview the time then ran on for five, six
/// seconds before the pause icon appeared. To report at once you need the
/// **current** position, and only the player knows it. Through this store the
/// state holder knows it too.
///
/// A shared store instead of a callback per platform is deliberate: otherwise
/// every version would have to set a line, and the one that forgets goes
/// unnoticed.
///
/// **Is the app in front right now?** For ticks that only matter while someone
/// is looking (session and group polling every five seconds).
///
/// iOS/tvOS: application state `active`. Mac: app active **and** a window
/// visible (not minimized, not covered).
@MainActor
enum Foreground {
    static var active: Bool {
        #if os(macOS)
        NSApp.isActive && NSApp.occlusionState.contains(.visible)
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    /// Waits `seconds` - or, if the app is not in front, until it is again. After
    /// waiting in the background it returns at once so the caller asks once on
    /// coming back.
    static func wait(seconds: Double) async {
        if active {
            try? await Task.sleep(for: .seconds(seconds))
            return
        }
        #if os(macOS)
        let names: [Notification.Name] = [NSApplication.didBecomeActiveNotification,
                                          NSApplication.didChangeOcclusionStateNotification]
        #else
        let names: [Notification.Name] = [UIApplication.didBecomeActiveNotification]
        #endif
        let center = NotificationCenter.default
        let (feed, proceed) = AsyncStream<Void>.makeStream()
        let observer = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in proceed.yield() }
        }
        defer { observer.forEach { center.removeObserver($0) } }
        for await _ in feed {
            if Task.isCancelled || active { return }
        }
    }
}

@MainActor
enum PlayState {
    private(set) static var spot: Double = 0
    private(set) static var running = false
    /// When this was last written - so nobody uses a state from a cleared-away
    /// playback.
    private(set) static var stamp = Date.distantPast

    static func setDown(spot: Double, running: Bool) {
        Self.spot = spot
        Self.running = running
        Self.stamp = Date()
    }

    /// **Is a player on screen right now?**
    ///
    /// Playback writes this state every second, from every version. Whoever wants
    /// to know whether someone is watching needs no switch of their own that every
    /// view would have to set and unset - and exactly such a switch is the one
    /// someone eventually forgets to set.
    ///
    /// Five seconds, not thirty as with ``frisch``: there it is about a usable
    /// number, here about "right now".
    static var playerRuns: Bool {
        Date().timeIntervalSince(stamp) < 5
    }

    /// `nil` if too much time has passed since the last entry.
    static var freshValue: (spot: Double, running: Bool)? {
        guard Date().timeIntervalSince(stamp) < 30 else { return nil }
        return (spot, running)
    }
}

@MainActor
final class PlaybackHub {

    /// What the hub may trigger on the player.
    struct Handles {
        let play: () -> Void
        let halt: () -> Void
        let toggle: () -> Void
        let jumpOn: (Double) -> Void
        let forward: () -> Void
        let back: () -> Void
        /// `nil` if there is no next episode.
        let next: (() -> Void)?
    }

    private var handles: Handles?

    /// **The hub remembers what is playing itself.**
    ///
    /// Do not ask the view (its copy is stale), not VLC (lags behind), not the
    /// system (on TV it stubbornly sends "pause"). Three truths contradicting each
    /// other were the cause of a whole afternoon. Here is one, updated on every
    /// command and every catch-up.
    private var playCurrent = true
    /// When the hub last toggled playback.
    ///
    /// **The reason it took ten attempts.** `stateCatchUp` runs every second and
    /// wrote the view's state - which stays at "playing" because a command through
    /// the hub never reaches the view. So the fresh decision was overwritten every
    /// second by the stale value, and the next press paused again.
    ///
    /// So the tick has nothing to report here for two seconds.
    private var sinceCommand: Date?
    /// When this player got the hub - for the grace period on route change.
    private var sinceTakeover = Date.distantPast
    #if !os(macOS)
    private var observer: NSObjectProtocol?
    #endif
    /// Whether anything was playing when the interruption began - only then does
    /// playback resume afterwards.
    private var ranBefore = false

    // MARK: - Registering and unregistering

    func adopt(_ handles: Handles) {
        self.handles = handles
        commandsSetUp()
        #if !os(macOS)
        sinceTakeover = Date()
        observeInterruptions()
        routesSwitchObserve()
        #endif
    }

    func handIn() {
        #if !os(macOS)
        if let routesObserver {
            NotificationCenter.default.removeObserver(routesObserver)
            self.routesObserver = nil
        }
        #endif
        let hub = MPRemoteCommandCenter.shared()
        for command in [hub.playCommand, hub.pauseCommand,
                       hub.togglePlayPauseCommand, hub.nextTrackCommand,
                       hub.skipForwardCommand, hub.skipBackwardCommand,
                       hub.changePlaybackPositionCommand] {
            command.removeTarget(nil)
            command.isEnabled = false
        }
        #if !os(macOS)
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        #endif
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        titleImage = nil
        titleImageFor = nil
        handles = nil
        // Otherwise Discord kept showing "watching ..." with an expired counter after
        // closing, until the app quit.
        DiscordIndicator.shared.tidyAway()
    }

    // MARK: - What the lock screen shows

    /// - Parameter sprungweite: the same values as in the player so the lock
    ///   screen buttons do the same as the on-screen ones.
    func report(item: Item, position: Double, duration: Double, tempo: Float,
                running: Bool, jumpDistance: (back: Int, forward: Int),
                // **No default value, on purpose.** With `= nil` all three callers kept
                // compiling but passed nothing - the lock screen stayed grey and nobody
                // noticed. If a fourth platform comes, the compiler should complain, not
                // the user.
                imageUrl: URL?) {
        // The path for the lock screen is the same as for the immediate report to the
        // server - here is the freshest state in the app.
        PlayState.setDown(spot: position, running: running)
        // **And the same path carries the Discord display.**
        //
        // For the same reason as `PlayState`: on every state change the fresh values
        // are here, from every version. Whether anything goes out at all is decided by
        // `DiscordIndicator` - the switch is off until someone turns it on.
        DiscordIndicator.shared.report(
            title: item.seriesName ?? item.name,
            subline: item.seriesName == nil ? nil
                        : [item.episodeCode, item.name].compactMap { $0 }.joined(separator: " · "),
            spot: position, duration: duration, running: running)
        var entryRecord: [String: Any] = [
            MPMediaItemPropertyTitle: item.name,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: running ? Double(tempo) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        // Only report duration when it is known - a zero turns the lock screen bar
        // into a meaningless line.
        if duration > 0 { entryRecord[MPMediaItemPropertyPlaybackDuration] = duration }
        if let series = item.seriesName {
            entryRecord[MPMediaItemPropertyAlbumTitle] = series
            if let abbreviation = item.episodeCode {
                entryRecord[MPMediaItemPropertyArtist] = abbreviation
            }
        }
        // Pass the already loaded cover along at once - otherwise the grey box flashes
        // on every tick, since `nowPlayingInfo` is replaced as a whole and the old
        // entry disappears with it.
        if let image = titleImage, titleImageFor == item.id {
            entryRecord[MPMediaItemPropertyArtwork] = image
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = entryRecord
        entrySince = Date()
        reportState(running)
        titleImageFetch(imageUrl, for: item.id)

        let hub = MPRemoteCommandCenter.shared()
        hub.skipBackwardCommand.preferredIntervals = [NSNumber(value: jumpDistance.back)]
        hub.skipForwardCommand.preferredIntervals = [NSNumber(value: jumpDistance.forward)]
    }

    // MARK: - The cover on the lock screen

    /// The loaded image and the title it belongs to.
    ///
    /// **Both together, not just the image.** `report` runs on the tick and replaces
    /// `nowPlayingInfo` completely; without the pairing the previous episode's image
    /// would stay for a while after an episode change.
    private var titleImage: MPMediaItemArtwork?
    /// When position and rate were last entered - basis of the extrapolation in
    /// `stateCatchUp`.
    private var entrySince = Date.distantPast
    private var titleImageFor: String?

    /// Fetches the cover once per title and adds it later.
    ///
    /// **Why add later instead of passing it right away:** the URL points to the
    /// Jellyfin server, so the image must come over the network. The lock screen
    /// should show title and bar at once, not wait for an image. So report first,
    /// then follow up.
    ///
    /// Until then a grey box showed there - for movies and series alike.
    /// `MPMediaItemPropertyArtwork` was simply never set.
    /// Wraps a loaded image the way `MPMediaItemArtwork` requires.
    ///
    /// **The callback block must deliver the requested size, not the existing one.**
    /// Lock screen, Control Center and CarPlay request different edge lengths;
    /// returning the same image regardless makes MediaPlayer throw - in the debug
    /// build an immediate crash when playback starts.
    ///
    /// **`nonisolated`, and that is the core.** The class is `@MainActor`; a block
    /// written here inherits that isolation. But MediaPlayer calls it from its own
    /// thread and Swift 6 aborts - the log only says "terminated due to signal 5",
    /// without a word about which assertion broke.
    ///
    /// The same trap as with VLCKit's callbacks, see `StateReporter`:
    /// `@MainActor` is an assertion, not a redirect.
    private nonisolated static func itemPiece(from image: SystemImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { size in
            guard size != image.size else { return image }
            #if os(macOS)
            let new = NSImage(size: size)
            new.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: size))
            new.unlockFocus()
            return new
            #else
            let form = UIGraphicsImageRendererFormat.default()
            form.opaque = false
            return UIGraphicsImageRenderer(size: size, format: form).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            #endif
        }
    }

    private func titleImageFetch(_ url: URL?, for id: String) {
        // **At most one attempt per title.** `report` runs on a half-second tick;
        // without this guard a title without an image would fire a request twice a
        // second.
        guard titleImageFor != id else { return }
        titleImageFor = id
        titleImage = nil
        guard let url else { return }

        Task { [weak self] in
            guard let data = try? await URLSession.shared.data(for: .withOwnHeaders(url)).0,
                  let image = SystemImage(data: data) else { return }
            let mediaWork = Self.itemPiece(from: image)
            guard let self, self.titleImageFor == id else { return }
            self.titleImage = mediaWork
            // Only supplement, do not rebuild: between reporting and arrival the position
            // has long moved on.
            guard var entryRecord = MPNowPlayingInfoCenter.default().nowPlayingInfo
            else { return }
            entryRecord[MPMediaItemPropertyArtwork] = mediaWork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = entryRecord
            // The system sets the sent (old) position to now - the next tick should
            // correct it.
            self.entrySince = .distantPast
        }
    }

    /// Only update the position - cheaper than the whole entry, and on pause the
    /// rate must be right at once, otherwise the lock screen clock keeps running.
    ///
    /// **Only write when the system miscalculates.** The lock screen extrapolates
    /// the position from position and rate itself. Previously the whole entry went
    /// as a message to the media service every second, the whole film long. Now only
    /// when the rate changes or the position deviates from the extrapolation by more
    /// than a second - a jump, a stall, a pause.
    func stateCatchUp(position: Double, running: Bool, tempo: Float) {
        guard var entryRecord = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        let rate = running ? Double(tempo) : 0
        let oldRate = entryRecord[MPNowPlayingInfoPropertyPlaybackRate] as? Double
        let oldPoint = entryRecord[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
        let highComputed = (oldPoint ?? 0) + (oldRate ?? 0) * Date().timeIntervalSince(entrySince)
        if oldRate != rate || oldPoint == nil || abs(highComputed - position) > 1 {
            entryRecord[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
            entryRecord[MPNowPlayingInfoPropertyPlaybackRate] = rate
            MPNowPlayingInfoCenter.default().nowPlayingInfo = entryRecord
            entrySince = Date()
        }
        // Do not overwrite while our own decision is fresh.
        if let sinceCommand, Date().timeIntervalSince(sinceCommand) < 2 {
            reportState(playCurrent)
            return
        }
        playCurrent = running
        reportState(running)
    }

    /// **Report the state, not just the rate.**
    ///
    /// The rate is in the entry and describes how fast it plays. Whether it plays at
    /// all is a different piece of information - and the system decides by it which
    /// command to send on a press of the play button.
    ///
    /// Without it tvOS believed throughout it was playing and sent `pauseCommand`
    /// every time. So the first press paused and every further one did nothing: it
    /// never sent `play`, never `togglePlayPause`, only "pause". Found by looking at
    /// the built-in trace - it showed `anhalten - hub` twice in a row.
    private func reportState(_ running: Bool) {
        MPNowPlayingInfoCenter.default().playbackState = running ? .playing : .paused
    }

    /// **All three system commands converge here.**
    ///
    /// On TV, tvOS stubbornly sends `pause` on a press of the play button - even when
    /// already paused. Measured on the device twice in a row. Which of the three
    /// commands the system sends therefore says nothing about what is meant; what is
    /// meant is always "the opposite of now".
    private func toggle() {
        sinceCommand = Date()
        if playCurrent { playCurrent = false; handles?.halt() }
        else            { playCurrent = true;  handles?.play() }
        reportState(playCurrent)
    }

    // MARK: - Commands from outside

    /// **Every command is explicitly hoisted onto the main thread.**
    ///
    /// The class is `@MainActor`, so Swift assumes these callbacks run there too -
    /// otherwise the call to `toggle()` would not compile. But
    /// `MPRemoteCommandCenter` calls them on an arbitrary thread. The assertion
    /// holds without being kept.
    ///
    /// It showed on TV, in a place unrelated to sound: a built-in display appeared
    /// only **after focus had moved**. The state was long set - nobody had set it on
    /// the main thread, so no redraw came. The same hit playback: it paused, but the
    /// UI did not learn of it and accepted nothing more.
    private func commandsSetUp() {
        let hub = MPRemoteCommandCenter.shared()

        // **The system's command is a suggestion, our state is the truth.**
        //
        // On TV, tvOS stubbornly sends `pause` on a press of the play button - even
        // when already paused, and even when we report the state properly and all three
        // commands are enabled. Measured on the device: "pause" twice in a row. Whoever
        // relies on that pauses and never gets going again.
        //
        // So both commands check what currently applies and do the opposite when the
        // system is wrong. For the lock screen on the phone it changes nothing - the
        // command is right there anyway.
        hub.playCommand.removeTarget(nil)
        hub.playCommand.isEnabled = true
        hub.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }

        hub.pauseCommand.removeTarget(nil)
        hub.pauseCommand.isEnabled = true
        hub.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }

        hub.togglePlayPauseCommand.removeTarget(nil)
        hub.togglePlayPauseCommand.isEnabled = true
        hub.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }

        hub.skipForwardCommand.removeTarget(nil)
        hub.skipForwardCommand.isEnabled = true
        hub.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handles?.forward() }
            return .success
        }

        hub.skipBackwardCommand.removeTarget(nil)
        hub.skipBackwardCommand.isEnabled = true
        hub.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handles?.back() }
            return .success
        }

        hub.changePlaybackPositionCommand.removeTarget(nil)
        hub.changePlaybackPositionCommand.isEnabled = true
        hub.changePlaybackPositionCommand.addTarget { [weak self] command in
            guard let target = command as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let spot = target.positionTime
            Task { @MainActor in self?.handles?.jumpOn(spot) }
            return .success
        }

        hub.nextTrackCommand.removeTarget(nil)
        hub.nextTrackCommand.isEnabled = handles?.next != nil
        // **Like the others via the main thread.** Here `next` ran directly on the
        // system's thread - the episode change sets SwiftUI state. Whether there is a
        // next episode is already told by `isEnabled`; it is still checked, but only on
        // the main thread.
        hub.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handles?.next?() }
            return .success
        }

        // There is no previous title - leaving the button grey is more honest than
        // pointing it into the void.
        hub.previousTrackCommand.isEnabled = false
    }

    // MARK: - Calls and unplugged headphones

    // The whole section is omitted on Mac: `AVAudioSession` does not exist there.
    // That is no gap - macOS does not take audio away from an app when something
    // rings alongside, it mixes. So there is nothing to listen for.
    #if !os(macOS)
    /// **When the output device changes, the audio output must be rebuilt.**
    ///
    /// That is exactly the symptom of an unhandled route change. iOS reports it, but
    /// VLC's audio output stays on the old device and remains silent until some other
    /// trigger rebuilds it - when switching back and forth it eventually does by itself.
    ///
    /// So far we listened **only** for interruptions, not route changes. Those are two
    /// different notifications: a call interrupts, headphones change the route.
    private var routesObserver: NSObjectProtocol?

    private func routesSwitchObserve() {
        if let routesObserver { NotificationCenter.default.removeObserver(routesObserver) }
        routesObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] postDirection in
            let raw = postDirection.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.routesSwitch(reason: raw) }
        }
    }

    private func routesSwitch(reason raw: UInt?) {
        guard let raw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        // **Only the two that really are a device change.**
        //
        // There used to be four - `.categoryChange` and `.routeConfigurationChange` were
        // among them. But those fire when the **app itself** sets up its audio session,
        // right at start. On Apple TV that triggered a chain that killed the app,
        // measured on the device:
        //
        // [Ton] Routenwechsel (8) - rebuild output
        // Paused, position 0 s          paused in the middle of starting
        // Playing, position 9 s         nine seconds later
        // picture is too late (missing 8366 ms)   x hundreds
        // clock gap -> new clock context(1) ... (2642)
        // 201 s long, 35 contexts per second -> tvOS kills the app
        //
        // VLC never recovered from the backlog and spun itself to death.
        //
        // For Bluetooth the two here suffice: `.newDeviceAvailable` when headphones are
        // added, `.override` when someone changes the target. Those were the ones
        // meant anyway - the other two were bycatch.
        case .newDeviceAvailable, .override:
            // The rule with grace period is in `AudioWatch` - with the measurement behind it
            // and the note that the five seconds are **guessed**.
            guard AudioWatch.outputNewBuildUp(
                realDeviceSwitch: true,
                playsNow: playCurrent,
                sinceTakeover: Date().timeIntervalSince(sinceTakeover))
            else {
                if playCurrent {
                    AppLog.writeOut("[Ton] Routenwechsel (\(raw)) im Anlauf — übergangen")
                }
                return
            }
            AppLog.writeOut("[Ton] Routenwechsel (\(raw)) — Ausgang neu aufbauen")
            // **Pause and resume at once.** VLC rebuilds the audio output on resume;
            // without this nudge it stays on the old device. A finer way would be to swap
            // only the output - VLCKit does not offer that.
            handles?.halt()
            handles?.play()
        case .oldDeviceUnavailable:
            // Headphones out: pause, as every player does. Otherwise the film suddenly
            // plays over the speaker.
            AppLog.writeOut("[Ton] Ausgabegeraet weg — anhalten")
            handles?.halt()
        default:
            break
        }
    }

    private func observeInterruptions() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] postDirection in
            // Extract the two values here and pass only those: `Notification` is not
            // `Sendable`, and passed across the actor boundary it would be a data race.
            let raw = postDirection.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let hint = postDirection.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            // **Record the reason, do not guess.** Since iOS 14.5 iOS says *why* it
            // interrupted. Without this number we could not tell whether Notification Center
            // counts as a system notice (then the preference set on activation applies) or
            // as something else -- and that decides whether pausing is allowed at all.
            //
            // The key does not exist on tvOS -- there the number is omitted and the rest
            // stays the same.
            #if os(iOS)
            let reason = postDirection.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            #else
            let reason: UInt? = nil
            #endif
            MainActor.assumeIsolated { self?.interruption(art: raw, hint: hint, reason: reason) }
        }
    }

    private func interruption(art raw: UInt?, hint: UInt?, reason: UInt?) {
        guard let raw, let art = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch art {
        case .began:
            AppLog.writeOut("[Ton] Unterbrechung beginnt · Grund \(reason.map(String.init) ?? "—")")
            ranBefore = (MPNowPlayingInfoCenter.default()
                .nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0) > 0
            handles?.halt()
        case .ended:
            // **`shouldResume` must not be a condition.**
            //
            // This used `if ranBefore, shouldNext`. The thought was right - a call during
            // a pause should not start playback - but `ranBefore` alone already does that.
            // iOS only sets `shouldResume` when it *wants* to suggest resuming; for short
            // interruptions it is regularly missing.
            //
            // Measured on the device: pull down Notification Center and close it again.
            // Three times the same gesture, three times "pausing" from VLC - the third time
            // no "resuming" came. The app correctly showed "paused", but nobody resumed, and
            // the pause button no longer helped either.
            //
            // The hint is still recorded: if it is permanently missing for calls too, that
            // would be a different bug.
            let shouldNext = AVAudioSession.InterruptionOptions(rawValue: hint ?? 0)
                .contains(.shouldResume)
            AppLog.writeOut("[Ton] Unterbrechung vorbei — lief vorher "
                + "\(ranBefore), shouldResume \(shouldNext)")
            if ranBefore {
                // **Reactivate the audio session first.** After an interruption it is
                // inactive; a `play` on it fizzles silently, and then the picture just stands
                // for no visible reason.
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    AppLog.writeOut("[Ton] Sitzung liess sich nicht aktivieren: "
                        + error.localizedDescription)
                }
                handles?.play()
            }
            ranBefore = false
        @unknown default:
            break
        }
    }
    #endif
}
