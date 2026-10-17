import Foundation

/// Which dynamic range a video track has, as the server reports it.
///
/// **Why.** Apple TV can switch its HDMI output to HDR, but only if told which kind. The
/// value is in Jellyfin's response.
///
/// **Redundancy is intended.** Jellyfin returns `VideoRangeType` *and* the raw
/// `ColorTransfer` and `ColorPrimaries`. The type is more convenient but comes from
/// Jellyfin's own derivation; the raw values come from the file. Where they disagree the
/// file wins, and where the type says `Unknown` the raw values still decide.
/// `Codable`, not just `Decodable`: `MediaStream` is also `Encodable` because it goes back
/// in the device profile.
public enum ColorRange: String, Sendable, Codable {
    case unknown        = "Unknown"
    case sdr              = "SDR"
    case hdr10            = "HDR10"
    case hlg              = "HLG"
    case dolbyVision      = "DOVI"
    case dolbyVisionHDR10 = "DOVIWithHDR10"
    case dolbyVisionHLG   = "DOVIWithHLG"
    case dolbyVisionSDR   = "DOVIWithSDR"
    case dolbyVisionEL    = "DOVIWithEL"
    case dolbyVisionHDR10Plus   = "DOVIWithHDR10Plus"
    case dolbyVisionElHdr10Plus = "DOVIWithELHDR10Plus"
    case dolbyVisionInvalid   = "DOVIInvalid"
    case hdr10Plus        = "HDR10Plus"

    /// Whether this is an extended range at all.
    public var isHDR: Bool {
        switch self {
        case .unknown, .sdr, .dolbyVisionSDR, .dolbyVisionInvalid: false
        default: true
        }
    }

    /// **Which transfer curve the output needs.**
    ///
    /// There are two and they are not interchangeable: PQ (SMPTE ST 2084) for HDR10 and
    /// Dolby Vision, HLG for broadcast material. The wrong one gives a visibly wrong
    /// picture, too dark or washed out.
    public enum IdLine: Sendable, Equatable { case pq, hlg }

    public var curve: IdLine? {
        switch self {
        case .hlg, .dolbyVisionHLG: .hlg
        case .hdr10, .hdr10Plus, .dolbyVision, .dolbyVisionHDR10,
             .dolbyVisionEL, .dolbyVisionHDR10Plus, .dolbyVisionElHdr10Plus: .pq
        case .unknown, .sdr, .dolbyVisionSDR, .dolbyVisionInvalid: nil
        }
    }
}

/// The range, derived from everything the server says.
///
/// **Type first, then the raw values.** If Jellyfin reports `Unknown` (e.g. the file was
/// never analyzed), `ColorTransfer` and `ColorPrimaries` still decide. If neither says
/// anything, **nothing** is set. Guessing is worse: HDR shown as SDR looks washed out, SDR
/// shown as HDR looks flat.
public enum ColorInfo {

    /// - Parameters:
    ///   - typ: Jellyfin's `VideoRangeType`.
    ///   - kennlinie: Jellyfin's `ColorTransfer`, e.g. "smpte2084", "arib-std-b67".
    ///   - primaervalenzen: Jellyfin's `ColorPrimaries`, e.g. "bt2020".
    public static func reach(type: ColorRange?,
                              curve: String?,
                              primaries: String?) -> ColorRange {
        if let type, type != .unknown { return type }

        // The file has the last word when the type is silent.
        switch curve?.lowercased() {
        case "smpte2084", "smpte-st-2084", "pq": return .hdr10
        case "arib-std-b67", "hlg":              return .hlg
        default: break
        }
        // Wide primaries alone are not HDR (BT.2020 exists in SDR too), so only "unknown"
        // here.
        _ = primaries
        return .unknown
    }

    /// **Which transfer curve a track's picture carries**, for players that draw the
    /// picture themselves and must tone-map to SDR themselves (Linux and Windows, libVLC
    /// via raw-frame callbacks).
    ///
    /// Same derivation as the tech badge (``Technikangaben/dynamik(_:)``): invalid Dolby
    /// Vision data is played by every player as the base layer, then the raw values count.
    /// `nil` means SDR or unknown, so the picture stays as it is.
    public static func curve(videoTrack track: MediaStream?) -> ColorRange.IdLine? {
        guard let track else { return nil }
        var art = Self.reach(type: track.videoRangeType, curve: track.colorTransfer,
                              primaries: track.colorPrimaries)
        if art == .dolbyVisionInvalid {
            art = Self.reach(type: nil, curve: track.colorTransfer,
                              primaries: track.colorPrimaries)
        }
        return art.curve
    }

    public static func curve(source: MediaSource?) -> ColorRange.IdLine? {
        curve(videoTrack: source.flatMap(FileDetails.videoTrack))
    }
}
