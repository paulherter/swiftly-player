import JellyfinKit
import SwiftUI
#if canImport(VLCKit)
import VLCKit
#endif

/// **The bridge from VLCKit to the counter in the package, nothing more.**
///
/// The computation itself lives in ``JellyfinKit/Zaehlwerk``. It used to be
/// here, so only on the Apple versions; Linux and Windows would have needed it a
/// second time, and a copied function is a bug. What stays here is reading the
/// VLCKit structure and formatting for display.
///
/// **Why anyone wants to see this:** this app never transcodes. Whether that
/// works out cannot be seen from playback: a picture that stutters and one that
/// silently drops frames look the same from three meters. `discarded` is the
/// difference.
struct PlayValues {
    let mediaWork: Counter

    // MARK: Passed through, the names the badge knows

    var discarded: UInt64    { mediaWork.raw.discarded }
    var tooLate: UInt64      { mediaWork.raw.tooLate }
    var shown: UInt64      { mediaWork.raw.shown }
    var audioLost: UInt64  { mediaWork.raw.audioLost }
    var videoBlocks: UInt64 { mediaWork.raw.videoBlocks }
    var audioBlocks: UInt64   { mediaWork.raw.audioBlocks }
    var audioPlay: UInt64  { mediaWork.raw.audioPlay }
    /// **Blocks the demuxer recognized as corrupt.** This is the number behind
    /// "there were picture errors".
    var beschaedigt: UInt64  { mediaWork.raw.beschaedigt }
    /// **Discontinuities in the stream.** Timestamps that do not run on; that is
    /// what you see as audio drifting away.
    var jumps: UInt64     { mediaWork.raw.jumps }
    var hasRead: UInt64      { mediaWork.raw.hasRead }
    var unpacked: UInt64     { mediaWork.raw.unpacked }
    var spot: Double       { mediaWork.spot }

    var showsProSecond: Double?     { mediaWork.showsProSecond }
    var decodedProSecond: Double? { mediaWork.decodedProSecond }
    var runShare: Double?          { mediaWork.runShare }
    var measuredAt: Date             { mediaWork.measuredAt }

    /// Bitrates as ready text; all platforms share the wording via
    /// ``JellyfinKit/Technikangaben/bitrate(_:)``.
    var input: String { TechDetails.bitrate(mediaWork.input) ?? "—" }
    var demuxer: String { TechDetails.bitrate(mediaWork.demuxer) ?? "—" }

    func reserveSeconds(bytesJeSecond: Double) -> Double? {
        mediaWork.reserveSeconds(bytesJeSecond: bytesJeSecond)
    }

    #if canImport(VLCKit)
    init?(_ raw: VLCMedia.Stats?, spot: Double, running: Bool, before: PlayValues? = nil) {
        guard let raw else { return nil }
        let values = Counter.RawValues(
            hasRead: raw.readBytes, unpacked: raw.demuxReadBytes,
            shown: raw.displayedPictures, discarded: raw.lostPictures,
            tooLate: raw.latePictures, videoBlocks: raw.decodedVideo,
            audioBlocks: raw.decodedAudio, audioPlay: raw.playedAudioBuffers,
            audioLost: raw.lostAudioBuffers, beschaedigt: raw.demuxCorrupted,
            jumps: raw.demuxDiscontinuity)
        guard let mediaWork = Counter(values, spot: spot, running: running,
                                   before: before?.mediaWork) else { return nil }
        self.mediaWork = mediaWork
    }
    #endif
}
