#if os(iOS)
import AVFoundation
import Foundation

/// Observes **where** the audio goes, and reports when that is an AirPlay
/// device.
///
/// **Why this is the trigger and not a button.** It is the route people
/// know, and it is one step shorter than any button that has to be found
/// in the controls first. Swiftly does not need to offer the switch, only
/// **notice** it and move the picture along.
///
/// **The audio switches by itself, the picture does not.** The system audio
/// session follows the new destination without our doing; but AirPlay
/// transmits video only from `AVPlayer`, and libVLC's surface does not
/// support it. This notification closes exactly that gap.
///
/// It hangs on the same system notification as the Bluetooth handling in
/// ``PlaybackHub`` but is a separate object: there the job is to
/// rebuild the audio output, here to **swap the player**. Two observers on
/// one notification are cheaper than one class doing two things.
@MainActor
final class RemoteTarget {

    /// Is the audio currently going over AirPlay?
    private(set) var airPlay: Bool

    /// Name of the destination as shown in the picker, e.g. "Living room".
    private(set) var targetName: String?

    /// Called when this has changed. Not on every route change: only on the
    /// transition, otherwise every headphone switch would swap the player.
    var switched: ((Bool) -> Void)?

    private var observer: NSObjectProtocol?

    init() {
        let state = Self.state()
        airPlay = state.airplay
        targetName = state.name
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            // `Notification` is not `Sendable`; nothing is needed from it here
            // anyway, the state is in the session itself.
            MainActor.assumeIsolated { self?.lookUp() }
        }
    }

    /// **No `deinit`.** A `deinit` is not isolated and may no longer touch the
    /// observer, the same Swift 6 rule that once ended the lock screen with
    /// "signal 5". Whoever stops says so themselves; the callback holds `self`
    /// only weakly anyway.
    func quit() {
        switched = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Also callable by hand, when opening the player, because the destination
    /// may already be the TV then.
    func lookUp() {
        let state = Self.state()
        targetName = state.name
        guard state.airplay != airPlay else { return }
        airPlay = state.airplay
        // **Log the destination's audio latency too.** If AirPlay rejects the
        // stream, VLC keeps playing and sends only the audio over; picture and
        // sound then stay together only if VLC compensates this latency
        // (audiounit_ios reads `outputLatency`). A reported offset can be checked
        // with this number on the device instead of guessed.
        let latency = Int(AVAudioSession.sharedInstance().outputLatency * 1000)
        AppLog.writeOut("[Ziel] \(state.airplay ? "AirPlay" : "Gerät") — \(state.name ?? "?")"
            + " · Tonlatenz \(latency) ms")
        switched?(state.airplay)
    }

    /// **The output counts, not the reason.**
    ///
    /// `AVAudioSession.RouteChangeReason` reports `.override`,
    /// `.categoryChange` or `.routeConfigurationChange` for a destination
    /// change depending on the path, so distinguishing by it would be a guess.
    /// The question "does the audio go to an AirPlay device" is answered
    /// unambiguously by the route itself.
    private static func state() -> (airplay: Bool, name: String?) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let far = outputs.first(where: { $0.portType == .airPlay }) else {
            return (false, outputs.first?.portName)
        }
        return (true, far.portName)
    }
}
#endif
