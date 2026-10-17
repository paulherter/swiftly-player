import Foundation

/// What the tech badge shows: the rules, not the presentation.
///
/// **Why this lives here and not in the view.** Four platforms show the same badge, and
/// each would otherwise have its own version of "how to spell hevc" and "from when it is
/// Mbit/s". That is how copies have drifted apart before. Here it exists once and can be
/// checked without a simulator.
public enum TechDetails {

    // MARK: Codec names

    /// How a codec is written when a human reads it.
    ///
    /// The server returns lowercase container names such as `hevc`, `eac3`,
    /// `hdmv_pgs_subtitle`. That is the container's spelling, not a human's; a badge that
    /// helps with troubleshooting should show what an error message would show.
    public static func codecNameValue(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "h264", "avc":               return "H.264"
        case "hevc", "h265":              return "HEVC"
        case "av1":                       return "AV1"
        case "vp9":                       return "VP9"
        case "mpeg2video":                return "MPEG-2"
        case "vc1":                       return "VC-1"
        case "aac", "aac_latm":           return "AAC"
        case "ac3":                       return "AC-3"
        case "eac3":                      return "E-AC-3"
        case "dts", "dca":                return "DTS"
        case "dtshd":                     return "DTS-HD"
        case "truehd":                    return "TrueHD"
        case "mlp":                       return "MLP"
        case "flac":                      return "FLAC"
        case "alac":                      return "ALAC"
        case "opus":                      return "Opus"
        case "mp3":                       return "MP3"
        case "hdmv_pgs_subtitle", "pgssub": return "PGS"
        case "dvd_subtitle", "dvdsub":    return "VobSub"
        case "subrip", "srt":             return "SRT"
        case "ass", "ssa":                return "ASS"
        case "mov_text":                  return "MOV-Text"
        case "webvtt", "vtt":             return "WebVTT"
        case "ttml", "stpp":              return "TTML"
        // Jellyfin writes `DVBSUB`, ffprobe `dvb_subtitle`.
        case "dvbsub", "dvb_subtitle":    return "DVB"
        default:                          return raw.uppercased()
        }
    }

    /// Codec name from libVLC's ID (`i_codec`), e.g. `mp4a` to "AAC".
    ///
    /// The four characters are **least significant byte first** (measured on VLCKit; `mp4a`
    /// comes out that way). libVLC's own `codecName()` writes "MPEG AAC Audio", hence this
    /// table.
    public static func codecNameValue(vlcId identifier: UInt32) -> String? {
        let bytes = [identifier, identifier >> 8, identifier >> 16, identifier >> 24].map { UInt8($0 & 0xFF) }
        guard let symbolText = String(bytes: bytes, encoding: .ascii)?
            .lowercased().trimmingCharacters(in: .whitespaces) else { return nil }
        let raw: String? = switch symbolText {
        case "mp4a":         "aac"
        case "a52":          "ac3"
        case "eac3":         "eac3"
        case "dts":          "dts"
        // libVLC 4 reports TrueHD as `mlpa`, libVLC 3 as `trhd`.
        case "trhd", "mlpa": "truehd"
        case "mlp":          "mlp"
        case "flac":         "flac"
        case "alac":         "alac"
        case "opus":         "opus"
        case "mp3":          "mp3"
        case "vorb":         "vorbis"
        // Subtitles, for the cross-check in ``Spurzuordnung``.
        case "subt":         "subrip"
        case "ssa":          "ass"
        case "bdpg":         "hdmv_pgs_subtitle"
        case "spu":          "dvd_subtitle"
        case "tx3g":         "mov_text"
        case "wvtt":         "webvtt"
        case "stpp":         "ttml"
        case "dvbs":         "dvbsub"
        default:             nil
        }
        return codecNameValue(raw)
    }

    /// An audio track in one line, e.g. "German · AAC · 5.1".
    ///
    /// For tracks the player reports itself. The language comes as "ger", "deu" or "German"
    /// depending on the file; what `Locale` does not know is resolved by
    /// ``Sprache/erkannt(in:)``.
    public static func audioTrackName(language raw: String?, codec: String?, channels: Int?) -> String? {
        var languageWord: String?
        if let raw, !raw.isEmpty {
            let hasRead = language(raw)
            languageWord = hasRead != raw ? hasRead : (Language.detected(in: raw) ?? raw)
        }
        let parts = [languageWord, codec, channelWord(channels)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How many channels, in the notation everyone knows.
    ///
    /// 6 means 5.1 and 8 means 7.1; the channel count is not the number on the box.
    public static func channelWord(_ count: Int?) -> String? {
        switch count {
        case .some(1): "Mono"
        case .some(2): "Stereo"
        case .some(6): "5.1"
        case .some(8): "7.1"
        case .some(let n) where n > 0: "\(n) ch"
        default: nil
        }
    }

    /// A track's language, as a human reads it.
    ///
    /// The server returns the ISO code, and `und` there is not the conjunction but
    /// "undetermined", the value a file carries when nobody set a language. The badge used
    /// to read "Audio AAC · 5.1 · und", which looks like a truncated sentence.
    public static func language(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let code = raw.lowercased()
        // `mis` means "miscellaneous", `zxx` "no linguistic content".
        if ["und", "unknown", "unbekannt", "mis", "zxx"].contains(code) {
            return translated("unbekannt")
        }
        return Locale.current.localizedString(forLanguageCode: code) ?? raw
    }

    // MARK: Numbers

    /// Bits per second as text. From one megabit in Mbit/s, below that in kbit/s, where the
    /// decimal place becomes arbitrary.
    public static func bitrate(_ bitPerSecond: Double?) -> String? {
        guard let b = bitPerSecond, b > 0 else { return nil }
        if b >= 1_000_000 {
            return String(format: "%.1f Mbit/s", b / 1_000_000)
        }
        return String(format: "%.0f kbit/s", b / 1_000)
    }

    /// Frame rate with at most three decimal places, but without the zeros nobody reads:
    /// 23.976 stays, 59.94 stays 59.94 and does not become 59.940, and 25.000 becomes 25.
    ///
    /// Dropping the zeros is not polish: the badge sits over the picture and has little
    /// room, and a digit that is always zero tells nothing.
    public static func frameRate(_ value: Double?) -> String? {
        guard let w = value, w > 0 else { return nil }
        var text = String(format: "%.3f", (w * 1000).rounded() / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Resolution plus bit depth and range, as far as known.
    public static func imageRow(width: Int?, height: Int?,
                                 depth: Int?, reach: String?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        var text = "\(width)×\(height)"
        if let depth, depth > 0 { text += " · \(depth) bit" }
        if let reach, !reach.isEmpty, reach.uppercased() != "SDR" {
            text += " · \(reach.uppercased())"
        }
        return text
    }

    // MARK: Dynamic range

    /// **Which HDR kind the file carries**: "HDR10", "HDR10+", "HLG", "SDR" or "Dolby
    /// Vision P8.1 · HDR10" (profile and, after the dot, the base layer a device without
    /// Dolby Vision falls back to).
    ///
    /// **The file's format, not the output.** Whether the device outputs the signal as HDR
    /// or VLC maps it to SDR is not reliably known on any platform, so this line claims
    /// nothing about it. It sits in the upper part of the badge, which describes the file.
    ///
    /// The names are format names and are not translated. `nil` if the server says nothing
    /// usable; no guessing (``Farbauskunft``).
    public static func dynamics(_ track: MediaStream?) -> String? {
        guard let track else { return nil }
        var reach = ColorInfo.reach(type: track.videoRangeType,
                                         curve: track.colorTransfer,
                                         primaries: track.colorPrimaries)
        // Invalid DV data is played by every player as the base layer; then what the raw
        // data says about it counts.
        if reach == .dolbyVisionInvalid {
            reach = ColorInfo.reach(type: nil, curve: track.colorTransfer,
                                         primaries: track.colorPrimaries)
        }
        let base: String?
        switch reach {
        case .unknown, .dolbyVisionInvalid: return nil
        case .sdr:       return "SDR"
        case .hdr10:     return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .hlg:       return "HLG"
        case .dolbyVision:            base = nil
        case .dolbyVisionHDR10:       base = "HDR10"
        case .dolbyVisionHLG:         base = "HLG"
        case .dolbyVisionSDR:         base = "SDR"
        case .dolbyVisionEL:          base = "EL"
        case .dolbyVisionHDR10Plus:   base = "HDR10+"
        case .dolbyVisionElHdr10Plus: base = "EL · HDR10+"
        }
        var text = "Dolby Vision"
        if let profile = dvProfileWord(profile: track.dvProfile,
                                     compatible: track.dvBlSignalCompatibilityId) {
            text += " P\(profile)"
        }
        if let base { text += " · \(base)" }
        return text
    }

    /// "8.1", "5", "7". The part after the dot exists only for the profiles that carry it
    /// (8 and 10); a "5.0" or "7.6" appears nowhere.
    static func dvProfileWord(profile: Int?, compatible: Int?) -> String? {
        guard let profile, profile > 0 else { return nil }
        if [8, 10].contains(profile), let compatible, compatible >= 0,
           !(profile == 8 && compatible == 0) {
            return "\(profile).\(compatible)"
        }
        return "\(profile)"
    }

    // MARK: Delivery

    /// How much the delivery method weighs; the color depends on it.
    ///
    /// Direct Play and Direct Stream are both lossless and so look the same. Only
    /// transcoding is the exception this app promises to avoid, and only it stands out in
    /// color.
    public enum WeightValue: Sendable, Equatable { case good, cautionary }

    public static func weight(_ art: DeliveryMethod) -> WeightValue {
        art.isLossless ? .good : .cautionary
    }

    /// The word on the badge.
    public static func delivery(_ art: DeliveryMethod) -> String {
        switch art {
        case .directPlay:   translated("Direct Play")
        case .directStream: translated("Direct Stream")
        case .transcode:    translated("Transkodiert")
        }
    }
}
