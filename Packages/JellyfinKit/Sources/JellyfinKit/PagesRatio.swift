import Foundation

/// **Whether libVLC flipped an anamorphic picture, and what applies instead.**
///
/// libVLC 4 (VLCKit 4.0.0-a23) reads the pixel aspect ratio backwards for
/// Matroska `DisplayUnit = 3` ("aspect ratio"): 64:45 becomes 45:64. ffmpeg
/// writes anamorphic MKV exactly like that, so does everything that goes
/// through libavformat (HandBrake). Measured on a PAL file, 720×576, 16:9: VLC 4
/// asks for a 506×576 window instead of 1024×576, so the picture is squeezed.
/// libVLC 3 (Linux, Windows, Android) computes it correctly. Fixed upstream in
/// VLC `74a3aae62e`, not yet in the VLCKit used here.
///
/// The bug is recognized by its exact shape: VLC's pixel ratio is the
/// **reciprocal** of what follows from Jellyfin's display ratio. Everything
/// else is left to VLC; a correctly read picture is not touched, and once a
/// VLCKit with the fix arrives, this stops applying.
public enum PagesRatio {

    /// "16:9", "2.35:1" → width divided by height.
    static func value(_ text: String?) -> Double? {
        guard let parts = text?.split(separator: ":"), parts.count == 2,
              let a = Double(parts[0]), let b = Double(parts[1]), a > 0, b > 0 else { return nil }
        return a / b
    }

    /// - Parameters:
    ///   - sar: Pixel ratio as VLC reports it (numerator, denominator).
    ///   - breite, hoehe: Image size from the server.
    ///   - anzeige: Jellyfin's `AspectRatio`.
    /// - Returns: the display ratio that VLC must be forced to, or `nil` if
    ///   nothing needs to be done.
    public static func correction(sar: (UInt32, UInt32), width: Int, height: Int,
                                 display: String?) -> String? {
        guard sar.0 > 0, sar.1 > 0, width > 0, height > 0, let dar = value(display) else { return nil }
        let expects = dar * Double(height) / Double(width)
        let vlc = Double(sar.0) / Double(sar.1)
        let near = { (a: Double, b: Double) in abs(a - b) / b < 0.02 }
        guard !near(expects, 1), !near(vlc, expects), near(vlc * expects, 1) else { return nil }
        return display
    }
}
