import AVKit
import CoreMedia
import OSLog
import UIKit
import JellyfinKit
import VLCKit

/// Tells the TV which frame rate the film runs at.
///
/// Without it playback felt choppy although nothing was missing: 4 late frames out of
/// 4888, all from seeking. Nothing was dropped; frames just reached the screen unevenly.
///
/// Why: a film is 23.976 or 24 fps, but the Apple TV outputs 60 Hz. 24 does not divide
/// into 60, so every other frame is shown three times and the rest twice (3:2 pulldown).
/// Motion alternates between too fast and too slow. Pans show it at once, still shots
/// not at all, and no counter reports anything because no frame is lost.
///
/// Why phones don't show it: a ProMotion iPhone runs at 120 Hz, and 24 divides into 120
/// five times, so every frame stays equally long. Same file, same player, only the output differs.
///
/// Why Netflix doesn't show it: it does what is set here.
/// `AVDisplayManager.preferredDisplayCriteria` asks tvOS to switch the output to the
/// content's frame rate, so 24p plays at 24 Hz.
///
/// It depends on a device setting: without Settings > Video and Audio > Match Content >
/// Match Frame Rate the request is ignored; `allowed` says whether it arrives. Other apps judder then too.
@MainActor
enum FrameTick {
    private static let log = Logger(subsystem: "de.paulherter.swiftly", category: "Bildtakt")

    /// What was set last. Setting the same rate again triggers a second mode switch, and
    /// every switch blacks out the screen for a few seconds.
    private static var recent: Float?

    /// The key window, not just any.
    ///
    /// `windows.first` is creation order, not on-screen order. If it hits a window not tied to
    /// a screen, no display manager comes out, which looks exactly like the user having turned
    /// matching off. Two very different causes with the same symptom.
    private static var window: UIWindow? {
        let all = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return all.first(where: \.isKeyWindow) ?? all.first
    }

    private static var handler: AVDisplayManager? { window?.avDisplayManager }

    /// Why nothing is switched.
    enum Snapshot {
        /// The TV switches along.
        case ready
        /// "Match Frame Rate" is off in the device settings.
        case disabled
        /// No display manager reachable, so the cause is on our side, not the device.
        case unreachable
        /// Turned off in Swiftly: Settings > Playback.
        case inSwiftlyOut
    }

    static var state: Snapshot {
        // The app's own switch first: it is the one the viewer just flipped, so its answer should show first.
        guard userAllowed else { return .inSwiftlyOut }
        guard let handler else { return .unreachable }
        return handler.isDisplayCriteriaMatchingEnabled ? .ready : .disabled
    }

    /// The rate the output was set to; `nil` if nothing was switched.
    static var demanded: Double? { recent.map(Double.init) }

    /// Whether the device allows mode switches at all.
    static var allowed: Bool { state == .ready }

    /// When the current switch was started.
    private static var switchSince: Date?

    /// The measured rate, kept once measured.
    ///
    /// `rate(from:)` queries `media.videoTracks`. That is not a field read: VLCKit rebuilds the
    /// track list on every access. Called every half second, as the playback tick used to do,
    /// it constantly reaches into a medium that is playing, and returns garbage statistics
    /// from a structure VLC never filled.
    ///
    /// A file's frame rate does not change; reading once is enough.
    private static var measured: Double?
    /// So a medium without readable tracks is not queried forever.
    private static var attempts = 0

    /// During the switch the picture is black, so the loading screen must stay up or playback
    /// looks crashed.
    ///
    /// With a deadline: Apple says itself that the value depends on the hardware and the
    /// switch may take longer than it reports, so it is unreliable the other way too. If it
    /// stuck, it would hold the loading screen forever and a short black frame would become a
    /// film that never starts. A visible flash is the better failure.
    static var flipsOver: Bool {
        guard handler?.isDisplayModeSwitchInProgress == true else { return false }
        guard let switchSince else { return false }
        return Date().timeIntervalSince(switchSince) < 8
    }

    /// Adopt the frame rate of the running file.
    ///
    /// Returns the detected rate if something was set, otherwise `nil`. VLC knows the tracks
    /// once the stream is open, well before the first frame, so the switch happens behind the
    /// loading screen and is not seen.
    /// The running file's frame rate, as soon as VLC knows the tracks.
    ///
    /// Also for the tech info: it is the line that explains "it stutters but nothing is missing".
    static func rate(from player: VLCMediaPlayer) -> Double? {
        if let measured { return measured }
        guard attempts < 40 else { return nil }
        attempts += 1
        guard let image = player.media?.videoTracks.first?.video,
              image.frameRateDenominator > 0
        else { return nil }
        let rate = Double(image.frameRate) / Double(image.frameRateDenominator)
        // Nonsense values occur while the stream is still sorting itself out.
        guard rate > 1, rate < 250 else { return nil }
        measured = rate
        return rate
    }

    /// Whether anything is left to measure. If not, the tick may leave the medium alone.
    static var stillPostMeasure: Bool { measured == nil && attempts < 40 }

    /// From the server's data, before the stream opens.
    ///
    /// Why so early: the switch costs the TV a few seconds of black. If it only starts once
    /// VLC knows the tracks, it sticks out behind the loading screen. Here it starts at the
    /// same moment as the stream setup and both take about as long, so the black frame falls
    /// in time when nothing is visible anyway. What the server doesn't say, `anpassen(an:)` catches up.
    @discardableResult
    static func adapt(loud detail: MediaStream?) -> Double? {
        // Into the file log, not only the system log. Nobody can reach Apple's log on a TV; same
        // trap as with VLC's own lines. And it is the number that explains judder without dropped
        // frames: if the output doesn't switch, 23.976 fps run on 60 Hz and judder visibly with no frame missing.
        AppLog.writeOut("[Takt] Server sagt: real=\(detail?.realFrameRate.map { String(format: "%.3f", $0) } ?? "—")"
            + " mittel=\(detail?.averageFrameRate.map { String(format: "%.3f", $0) } ?? "—")"
            + " → benutzbar=\(detail?.frameRate.map { String(format: "%.3f", $0) } ?? "nein")")
        guard let detail, let rate = detail.frameRate else { return nil }
        return setDown(rate: rate,
                      width: Int32(detail.width ?? 1920),
                      height: Int32(detail.height ?? 1080),
                      codec: identifier(text: detail.codec),
                      reach: ColorInfo.reach(type: detail.videoRangeType,
                                                  curve: detail.colorTransfer,
                                                  primaries: detail.colorPrimaries))
    }

    @discardableResult
    static func adapt(an player: VLCMediaPlayer) -> Double? {
        guard stillPostMeasure, let rate = rate(from: player) else { return nil }
        guard let track = player.media?.videoTracks.first, let image = track.video
        else { return nil }
        // VLC does not expose the color range, so only the frame rate is re-measured here. The
        // server already set the range if it knew it.
        return setDown(rate: rate,
                      width: Int32(image.width),
                      height: Int32(image.height),
                      codec: identifier(track.codec),
                      reach: .unknown)
    }

    /// Whether we may switch at all.
    ///
    /// Measured on a device: the same episode plays smoothly in Swiftfin, which does not
    /// switch the frame rate. Ours showed stutter while every counter read zero: no dropped
    /// frame, none late, nothing damaged. The only tangible difference between the two
    /// players was this switch.
    ///
    /// So the viewer decides, not us. 24 Hz native is right on paper, every frame equally
    /// long, but on a TV whose motion processing smooths at 60 Hz it can still look worse.
    /// That depends on the device, not the file, so it is a setting and not a rule.
    ///
    /// On is the default: for most TVs it is right.
    private static var userAllowed: Bool {
        UserDefaults.standard.object(forKey: "bildrateAnpassen") as? Bool ?? true
    }

    private static func setDown(rate: Double, width: Int32, height: Int32,
                               codec: CMVideoCodecType,
                               reach: ColorRange) -> Double? {
        guard userAllowed else {
            log.info("Bildratenanpassung ist in Swiftly abgeschaltet — \(rate, privacy: .public) fps bleibt ungenutzt")
            return nil
        }

        // Do not switch when it brings nothing. Every switch costs a few seconds of black. If the
        // frame rate divides evenly into the current mode, every frame already lasts equally long
        // and switching would be pure loss: 30 in 60 is twice, 60 in 60 once. 24, 23.976, 25, 48
        // and 50 are the awkward ones, and exactly those judder.
        if fits(rate) {
            log.info("\(rate, privacy: .public) fps geht im laufenden Modus auf — kein Wechsel")
            return rate
        }

        guard allowed else {
            log.info("Bildratenanpassung ist am Gerät abgeschaltet — \(rate, privacy: .public) fps bleibt ungenutzt")
            return nil
        }

        // Compare with a tolerance, not exactly. The server says 23.976023976..., VLC computes a
        // slightly different value from numerator and denominator. An equality check would cause a
        // second mode switch for nothing, costing three seconds of black. A twentieth of a frame is no difference.
        let wished = Float(rate)
        if let recent, abs(recent - wished) < 0.05 { return rate }

        // With color info when the server gives any. Once the range of the file was unknown here,
        // which held until `VideoRangeType` was in the model. Now the description can carry the
        // transfer function and tvOS can switch the HDMI output.
        //
        // The old rule still holds: if the server says nothing, nothing is set. HDR in SDR looks
        // washed out, SDR in HDR looks flat; a guess is worse than leaving it.
        //
        // What this cannot do: Dolby Vision. An output requested through a format description goes
        // to HDR10, not DV, so a DV film lands in HDR10: right in transfer function and primaries,
        // without the dynamic metadata. Better than SDR, but not the same.
        var description: CMVideoFormatDescription?
        var colors: CFDictionary?
        if let curve = reach.curve {
            colors = [
                kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_2020,
                kCVImageBufferTransferFunctionKey: curve == .pq
                    ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                    : kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            ] as CFDictionary
        }

        let result = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: width,
            height: height,
            extensions: colors,
            formatDescriptionOut: &description)

        guard result == noErr, let description else {
            log.error("Formatbeschreibung fehlgeschlagen: \(result, privacy: .public)")
            return nil
        }

        handler?.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: wished,
                                                                formatDescription: description)
        recent = wished
        StartMeasurement.shared.mark("Ausgang umgestellt auf \(String(format: "%.3f", rate)) Hz")
        switchSince = Date()
        log.info("Ausgang auf \(rate, privacy: .public) Hz gestellt (\(width, privacy: .public)×\(height, privacy: .public))")
        AppLog.writeOut("[Takt] Ausgang auf \(String(format: "%.3f", rate)) Hz gestellt"
            + " (\(width)×\(height), \(reach.rawValue)"
            + "\(reach.curve.map { $0 == .pq ? ", PQ" : ", HLG" } ?? ", ohne Farbangaben"))")
        return rate
    }

    /// Back to the UI mode. Only if we really set something, otherwise the cleanup itself triggers a switch.
    static func resolve() {
        // The measurement is always reset, the output only when needed. Both used to hang on the
        // same condition, which failed exactly when nothing was switched. Watching a series whose
        // frame rate already divided evenly carried its value into the next title, and for that one
        // nothing was switched although it needed it. Two things, one condition.
        measured = nil
        attempts = 0

        guard recent != nil else { return }
        handler?.preferredDisplayCriteria = nil
        recent = nil
        switchSince = nil
        log.info("Ausgang wieder freigegeben")
    }

    /// What the output is running at now.
    ///
    /// The only number that really says whether the TV switched. Everything else is intent.
    /// Taken from the same window as the manager, not `UIScreen.main`: two answers about the same display should share a source.
    static var screenTick: Int {
        window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
    }

    /// Whether the frame rate divides evenly into the current display mode.
    ///
    /// `maximumFramesPerSecond` on a TV is the rate the output really runs at, not an upper bound as on a phone.
    private static func fits(_ rate: Double) -> Bool {
        let tick = Double(screenTick)
        guard tick > 1 else { return false }
        let factor = tick / rate
        // 23.976 is not 24: a tight tolerance, otherwise the most common film rate falls through and we switch for nothing.
        return abs(factor - factor.rounded()) < 0.01
    }

    /// VLC's four-character code to CoreMedia's.
    ///
    /// For choosing the display mode the frame rate counts; the code only needs to be
    /// plausible. Unknown goes as HEVC, the most common case with Direct Play.
    /// The same from Jellyfin's codec names: the server sends text, not a four-character code.
    private static func identifier(text: String?) -> CMVideoCodecType {
        switch text?.lowercased() {
        case "h264", "avc", "avc1": return kCMVideoCodecType_H264
        case "hevc", "h265":        return kCMVideoCodecType_HEVC
        case "mpeg4", "msmpeg4v3":  return kCMVideoCodecType_MPEG4Video
        case "vp9":                 return kCMVideoCodecType_VP9
        case "av1":                 return kCMVideoCodecType_AV1
        default:                    return kCMVideoCodecType_HEVC
        }
    }

    /// VLC's code is little-endian (`VLC_FOURCC`). An own big-endian reading used to be here and
    /// turned `h264` into `462h`, so every file went as HEVC. The reading now lives tested in
    /// the package (`VLCId`); the mapping is the same as for the server's text.
    private static func identifier(_ fourcc: UInt32) -> CMVideoCodecType {
        identifier(text: VLCId.videoCodecName(fourcc))
    }
}
