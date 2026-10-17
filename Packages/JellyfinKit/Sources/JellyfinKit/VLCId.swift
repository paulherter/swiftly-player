import Foundation

/// **libVLC's four-character codec ID, read the right way round.**
///
/// libVLC builds the ID with `VLC_FOURCC(a, b, c, d)` as `a | b << 8 | c << 16 | d << 24`,
/// so the first character is in the **least significant** byte. Measured on VLCKit: `mp4a`
/// comes out that way. Reading from the most significant byte gives `a4pm`, and every table
/// behind it falls back to its default. That is what the tvOS frame-rate code
/// (`FrameTick.identifier`) did, treating every file as HEVC.
///
/// It lives in the package so the byte order is defined and tested in **one** place, next
/// to ``Technikangaben/codecname(vlcKennung:)``.
public enum VLCId {

    /// The four characters, lowercase, without padding spaces (`a52 ` becomes `a52`). `nil`
    /// for 0 or non-ASCII.
    public static func symbolText(_ identifier: UInt32) -> String? {
        guard identifier != 0 else { return nil }
        let bytes = [identifier, identifier >> 8, identifier >> 16, identifier >> 24].map { UInt8($0 & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
              let text = String(bytes: bytes, encoding: .ascii) else { return nil }
        let clean = text.lowercased().trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : clean
    }

    /// The video codec in Jellyfin's spelling (`h264`, `hevc`, `vp9`, ...), so the same
    /// comparison works as for the server's value. `nil` if the ID is unknown.
    public static func videoCodecName(_ identifier: UInt32) -> String? {
        switch symbolText(identifier) {
        case "h264", "avc1", "x264":         "h264"
        case "hevc", "hvc1", "hev1", "h265": "hevc"
        case "vp90", "vp09":                 "vp9"
        case "vp80":                         "vp8"
        case "av01":                         "av1"
        case "mp4v", "divx", "xvid", "dx50": "mpeg4"
        case "mpgv", "mp2v":                 "mpeg2video"
        default:                             nil
        }
    }
}
