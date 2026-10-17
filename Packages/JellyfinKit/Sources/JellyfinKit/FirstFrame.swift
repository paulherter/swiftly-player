import Foundation

/// **The clock runs, the audio plays, and no picture ever came.**
///
/// ``Stromwacht/imagesStand(vorher:jetzt:)`` only judges a stream that has
/// already shown pictures; at zero it deliberately returns `nil`, otherwise a
/// title without a video track would be rebuilt as a dead stream. That left the
/// "black with sound" case unreported and without intervention.
///
/// This rule closes the gap, only where the server names a video track: then a
/// picture *must* arrive. It rescues in two stages and then stops; a stream
/// that stays black even with the software decoder is not reopened in a loop.
public enum FirstFrame {

    /// This much **movie time** without a single shown picture before intervening.
    ///
    /// Only counted while the player's clock really advances; buffering, pause and
    /// a seek do not count (see ``zuwachs(before:now:)``). Why four seconds are
    /// enough:
    ///
    /// - The player runs with `--no-drop-late-frames`; every decoded picture
    ///   reaches the output, even a late one. Zero shown pictures therefore means
    ///   the decoder delivered nothing or the output is dead, not "too slow".
    /// - VLC only starts the clock once all tracks are prebuffered; a healthy
    ///   stream shows its first picture when the clock starts. Seeks land on
    ///   keyframes (Matroska cues, MP4 sync samples).
    /// - Waiting longer costs the viewer movie without picture; a false alarm
    ///   costs a rebuild of about one second. The threshold is therefore below
    ///   ``Stromwacht/standstillNormal`` (6 s) but at ``Stromwacht/pufferruhe`` (4 s).
    public static let deadline: TimeInterval = 4

    /// Largest clock step that counts as playing time; the tick asks once per
    /// second. A larger step is a seek, not playback.
    public static let largestStep: TimeInterval = 2

    /// What has already been tried. Applies to a title, not to a rebuild.
    public enum Level: Int, Sendable, Equatable {
        /// Nothing yet.
        case no = 0
        /// Stream and output reopened at the same position.
        case outputNew = 1
        /// Reopened with the software decoder.
        case software = 2
        /// That stayed black too. From here on, leave it alone.
        case givenUp = 3
    }

    /// What the rule advises.
    public enum Rat: Sendable, Equatable {
        /// No case: picture present, no video track, excluded, or already given up.
        case nothing
        /// Not yet ``frist`` of movie time without a picture.
        case wait
        /// First rescue: rebuild stream and output at the same position.
        case outputNew
        /// Second rescue: reopen with the software decoder.
        case softwareDecoder
        /// Both stayed black: log it, show a notice, do nothing more.
        case giveUp
    }

    /// - Parameters:
    ///   - hasVideoTrack: Whether the server names a video track for this title.
    ///     Pure audio files have none and are left out.
    ///   - ausgenommen: Picture-in-picture, AirPlay, pause; a missing picture is
    ///     not this rule's business there.
    ///   - gezeigt: Pictures shown since the last rebuild.
    ///   - laufzeit: Movie time since the last rebuild during which the clock ran.
    ///   - bisher: What has already been tried for this title.
    public static func rat(hasVideoTrack: Bool, excluded: Bool,
                           shown: UInt64, runtime: TimeInterval,
                           untilFrom: Level) -> Rat {
        guard hasVideoTrack, !excluded, shown == 0 else { return .nothing }
        guard untilFrom != .givenUp else { return .nothing }
        guard runtime >= deadline else { return .wait }
        switch untilFrom {
        case .no:      return .outputNew
        case .outputNew: return .softwareDecoder
        case .software:   return .giveUp
        case .givenUp: return .nothing
        }
    }

    /// The stage that applies after an advice.
    public static func next(to rat: Rat, untilFrom: Level) -> Level {
        switch rat {
        case .outputNew:      .outputNew
        case .softwareDecoder: .software
        case .giveUp:        .givenUp
        case .nothing, .wait: untilFrom
        }
    }

    /// How much movie time really passed between two looks.
    ///
    /// Zero if there is no previous value, the clock stood or went backwards, and
    /// for a step above ``largestStep``, which was a seek. Without this limit
    /// a ten-minute seek would count as ten minutes without a picture.
    public static func growth(before: TimeInterval?, now: TimeInterval) -> TimeInterval {
        guard let before else { return 0 }
        let step = now - before
        guard step > 0, step <= largestStep else { return 0 }
        return step
    }

    /// The option that makes VLC decode in software.
    ///
    /// In VLC `codec` applies to all track kinds (decoder_helpers.c:
    /// `module_need_var(dec, type, "codec")`), hence `any` after it: avcodec
    /// first, and where it does not fit (subtitles, audio passthrough) VLC takes
    /// the best module as usual. VideoToolbox or MediaCodec drop out for the
    /// picture because avcodec comes before them.
    public static let softwareOption = ":codec=avcodec,any"

    /// **The same for libVLC 3 on Linux and Windows.** There the hardware is not in
    /// a separate decoder module but in avcodec itself (VA-API, VDPAU, D3D11VA,
    /// DXVA2 via `avcodec-hw`); ``softwareOption`` alone would leave it on.
    /// Measured with libVLC 3.0.23 and an XviD AVI: without `:avcodec-hw=none`
    /// "trying format vaapi" and "vdpau" for `mpeg4`, with the option VLC no longer
    /// looks for a hardware module.
    public static let softwareOptionsDesktop = [softwareOption, ":avcodec-hw=none"]

    /// **MPEG-4 Part 2 (XviD, DivX) in software from the start.**
    ///
    /// VLC 3 never passed XviD to VideoToolbox and took avcodec directly. VLC 4
    /// passes every MPEG-4 Part 2 to VideoToolbox, which rejects Advanced Simple
    /// Profile material frame by frame with `kVTVideoDecoderBadDataErr`. VLC
    /// restarts the session endlessly (decoder.c only counts the color space case)
    /// instead of switching to avcodec: audio plays, the picture stands still or
    /// stays black.
    ///
    /// Measured with an XviD AVI (624×352, B-frames) in the iOS simulator, 30 s
    /// each: unrestricted, 59 pictures decoded and over 400 session restarts; with
    /// ``softwareOption``, 806 pictures, 25 per second, no error. The ``FirstFrame``
    /// rescue came too late or not at all, because an occasional picture does get
    /// through.
    ///
    /// Only when the stream arrives unchanged: when converting, the server
    /// delivers a different format.
    public static func softwareFromStart(videoCodec: String?, method: DeliveryMethod) -> Bool {
        guard method != .transcode, let videoCodec else { return false }
        return videoCodec.lowercased() == "mpeg4"
    }

    /// The notice for the technical badge, or `nil` while there is nothing to say.
    public static func hint(_ rung: Level) -> String? {
        switch rung {
        case .no:      nil
        case .outputNew: translated("Kein Bild vom Dekoder – Wiedergabe neu aufgebaut")
        case .software:   translated("Kein Bild vom Dekoder – Software-Dekoder aktiv")
        case .givenUp: translated("Kein Bild vom Dekoder – auch Software-Dekoder ohne Bild")
        }
    }
}
