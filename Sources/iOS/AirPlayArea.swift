import AVKit
import SwiftUI

/// The player for **real AirPlay**: `AVPlayer`, and only for that.
///
/// **Why there is a second player.** AirPlay transmits video only from
/// `AVPlayer`; libVLC's surface does not support it. The route there is
/// measured and described in `DeviceProfile.airplay()`: for a suitable
/// file the server delivers it unchanged (`DirectPlay`), for Matroska it
/// repackages the container **without** re-encoding. The app's promise
/// stays intact, and whatever arrives here was cleared beforehand by
/// ``AirPlaySuitability``.
///
/// **And why `AVPlayerViewController` instead of own controls.** It brings
/// destination picker, audio and subtitle tracks, Picture in Picture and
/// the lock screen display out of the box, in the form viewers know from
/// every other app. Rebuilt controls would be more code for a worse
/// result. Swiftly's own controls stay reserved for the VLC path, where
/// there is no alternative.
struct AirPlayArea: UIViewControllerRepresentable {

    let url: URL
    let offSeconds: Double
    /// Position and duration, about every second, for reporting to the server.
    var state: (Double, Double) -> Void
    var ended: () -> Void
    /// **AVPlayer's own error message.**
    ///
    /// Without it a black picture on the TV cannot be interpreted: you see that
    /// nothing arrives but not why. `errorLog()` even names the HTTP status of
    /// the segment that failed.
    var error: (String) -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let player = AVPlayer(url: url)

        // **This is the line this is about.** Without it AirPlay transmits only
        // the audio.
        player.allowsExternalPlayback = true

        // If screen mirroring is already running, the right stream should still
        // go to the TV and not the filmed phone picture.
        player.usesExternalPlaybackWhileExternalScreenIsActive = true

        if offSeconds > 1 {
            player.seek(to: CMTime(seconds: offSeconds, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero)
        }

        let disc = AVPlayerViewController()
        disc.player = player
        disc.allowsPictureInPicturePlayback = true
        disc.canStartPictureInPictureAutomaticallyFromInline = true
        disc.videoGravity = .resizeAspect

        context.coordinator.append(an: player, disc: disc)
        player.play()
        return disc
    }

    /// Deliberately empty: the player is built **once**.
    ///
    /// If this reacted to changed values, every redraw of the surrounding view
    /// would produce a new `AVPlayer` object and the film would start over.
    /// Everything changeable goes through the coordinator.
    func updateUIViewController(_ disc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ disc: AVPlayerViewController,
                                          coordinator: Coordinator) {
        coordinator.cleanUp()
        disc.player?.pause()
        disc.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, ended: ended, error: error)
    }

    /// **`@MainActor`, and the callbacks hop individually.**
    ///
    /// `addPeriodicTimeObserver` requires a `@Sendable` block even when given
    /// `.main` as the queue. Without the hop this is a data race in the type
    /// system, the same spot where the lock screen once crashed with
    /// "signal 5".
    @MainActor
    final class Coordinator {
        private let state: (Double, Double) -> Void
        private let ended: () -> Void
        private let error: (String) -> Void
        private var tick: Any?
        private var end: NSObjectProtocol?
        private var wentWrong: NSObjectProtocol?
        private var logEntry: NSObjectProtocol?
        private var condition: NSKeyValueObservation?
        private var sentry: Task<Void, Never>?
        private weak var player: AVPlayer?

        init(state: @escaping (Double, Double) -> Void, ended: @escaping () -> Void,
             error: @escaping (String) -> Void) {
            self.state = state
            self.ended = ended
            self.error = error
        }

        func append(an player: AVPlayer, disc: AVPlayerViewController) {
            self.player = player

            // Every second is enough: it is reported to the server, not drawn. The
            // bar belongs to `AVPlayerViewController` here.
            tick = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                queue: .main
            ) { [weak self, weak player] time in
                MainActor.assumeIsolated {
                    guard let self, let player else { return }
                    let duration = player.currentItem?.duration.seconds ?? 0
                    self.state(time.seconds, duration.isFinite ? duration : 0)
                }
            }

            end = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: player.currentItem, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.ended() }
            }

            guard let piece = player.currentItem else { return }

            // **Watchdog against silent stalling.**
            //
            // The worst case reports nothing: `status` stays `unknown`, `error` is
            // empty, and the TV shows a black picture. Reproduced against the server
            // when it really had to compute: the segments did not arrive, and
            // AVPlayer waits for them without a deadline. Without this timer nobody
            // falls back.
            //
            // Twelve seconds: repackaging is done in two to three, and longer than
            // twelve looks broken even on success.
            sentry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, let self else { return }
                guard piece.status != .readyToPlay else { return }
                self.report("Kein Bild nach 12 s", piece.error)
            }

            // **Three sources, because each knows something different.**
            //
            // `status` says that it failed. `error` says roughly why. `errorLog()`
            // names the address and HTTP status of the segment, and that is the
            // information something can be derived from.
            // **Here no assertion but a hop.**
            //
            // Every neighbor in this file is told its queue:
            // `addPeriodicTimeObserver(queue: .main)`, and both `NotificationCenter`
            // observers with `queue: .main`. KVO has no such parameter, and
            // AVFoundation **nowhere** promises on which thread `observe` delivers.
            //
            // `MainActor.assumeIsolated` is a claim, not a check. If it ever does not
            // hold, that is no silent error but a crash. The price of
            // `Task { @MainActor }` is one pass of delay for a message that only sets
            // a hint or cancels the watchdog anyway.
            //
            // The `assumeIsolated` in `dismantleUIView` (PlayerScreen) stays: there
            // the compiler derives `@MainActor` from the `UIViewRepresentable`
            // conformance, so the guarantee holds.
            condition = piece.observe(\.status, options: [.new]) { [weak self] piece, _ in
                let done = piece.status == .readyToPlay
                let failed = piece.status == .failed
                let reason = piece.error
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if done { self.sentry?.cancel(); return }
                    guard failed else { return }
                    self.report("Status .failed", reason)
                }
            }

            wentWrong = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: piece, queue: .main
            ) { [weak self] postDirection in
                let reason = postDirection.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated { self?.report("Abbruch", reason) }
            }

            logEntry = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.newErrorLogEntryNotification,
                object: piece, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let lastOne = piece.errorLog()?.events.last else { return }
                    let text = [
                        lastOne.errorStatusCode != 0 ? "HTTP \(lastOne.errorStatusCode)" : nil,
                        lastOne.errorComment,
                        lastOne.uri,
                    ].compactMap { $0 }.joined(separator: " · ")
                    AppLog.writeOut("[AirPlay] Protokolleintrag: \(text)")
                    self?.error(lastOne.errorComment ?? "HTTP \(lastOne.errorStatusCode)")
                }
            }
        }

        /// Report once, then nothing more.
        ///
        /// `-12889` keeps arriving every second; passing on every entry would
        /// switch the player several times and overwrite the hint with itself.
        private var reported = false

        private func report(_ whence: String, _ reason: (any Error)?) {
            guard !reported else { return }
            reported = true
            sentry?.cancel()
            let text = reason?.localizedDescription ?? String(localized: "keine Antwort vom Server")
            AppLog.writeOut("[AirPlay] \(whence): \(text)")
            error(text)
        }

        /// Called from `dismantleUIViewController`, not from `deinit`. A `deinit`
        /// is not isolated and must not touch anything here.
        func cleanUp() {
            if let tick { player?.removeTimeObserver(tick) }
            tick = nil
            for b in [end, wentWrong, logEntry].compactMap({ $0 }) {
                NotificationCenter.default.removeObserver(b)
            }
            end = nil; wentWrong = nil; logEntry = nil
            condition?.invalidate(); condition = nil
            sentry?.cancel(); sentry = nil
        }
    }
}
