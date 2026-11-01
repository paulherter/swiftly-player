import Foundation

/// **How text subtitles look**, as one value that travels with the profile
/// settings (`SettingsSync`, name `utAussehen`).
///
/// Seven fields, all of them steps and switches, no free numbers: a step fits every
/// device, a point size would not. The value is plain data without any Apple type,
/// so Apple, Linux and Windows share ``vlcOptions(look:baseScale:outputHeight:engine:)``
/// and its tests; Android mirrors the same table in Kotlin.
///
/// Raw values are part of the stored format (JSON, synced to other devices); an
/// unknown word reads as the default instead of failing.
public struct SubtitleLook: Codable, Sendable, Equatable {

    public enum Size: String, Codable, Sendable, CaseIterable {
        case small, normal, large, huge
        /// Factor on the base scale.
        public var factor: Double {
            switch self { case .small: 0.8; case .normal: 1.0; case .large: 1.2; case .huge: 1.45 }
        }
    }

    public enum Colour: String, Codable, Sendable, CaseIterable {
        case white, yellow, grey
        /// `0xRRGGBB` as VLC wants it, decimal.
        public var rgb: Int {
            switch self { case .white: 0xFFFFFF; case .yellow: 0xFFE45C; case .grey: 0xCCCCCC }
        }
    }

    public enum Outline: String, Codable, Sendable, CaseIterable {
        case off, thin, normal
        /// Percent of the font height.
        public var thickness: Int {
            switch self { case .off: 0; case .thin: 2; case .normal: 3 }
        }
    }

    public enum Position: String, Codable, Sendable, CaseIterable {
        case bottom, raised
    }

    public var size: Size
    public var colour: Colour
    public var outline: Outline
    public var shadow: Bool
    public var background: Bool
    public var position: Position
    /// On: ASS and SSA are drawn by their own file (libass), as before. Off: the
    /// server's SRT version is loaded instead and this look applies.
    public var keepFileStyle: Bool

    public init(size: Size = .normal, colour: Colour = .white, outline: Outline = .normal,
                shadow: Bool = false, background: Bool = false, position: Position = .bottom,
                keepFileStyle: Bool = true) {
        self.size = size; self.colour = colour; self.outline = outline
        self.shadow = shadow; self.background = background; self.position = position
        self.keepFileStyle = keepFileStyle
    }

    public static let standard = SubtitleLook()

    /// Everything on its default, including the file-style switch.
    public var isStandard: Bool { self == .standard }

    // MARK: Storage

    private enum Key: String, CodingKey {
        case size, colour, outline, shadow, background, position, keepFileStyle
    }

    /// Tolerant: a missing or unknown field falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let d = SubtitleLook.standard
        size = (try? c.decodeIfPresent(Size.self, forKey: .size)) ?? d.size
        colour = (try? c.decodeIfPresent(Colour.self, forKey: .colour)) ?? d.colour
        outline = (try? c.decodeIfPresent(Outline.self, forKey: .outline)) ?? d.outline
        shadow = (try? c.decodeIfPresent(Bool.self, forKey: .shadow)) ?? d.shadow
        background = (try? c.decodeIfPresent(Bool.self, forKey: .background)) ?? d.background
        position = (try? c.decodeIfPresent(Position.self, forKey: .position)) ?? d.position
        keepFileStyle = (try? c.decodeIfPresent(Bool.self, forKey: .keepFileStyle)) ?? d.keepFileStyle
    }

    /// Stable JSON (sorted keys), so equal looks give equal text.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }

    /// Reads a stored look; anything unreadable gives the default.
    public static func read(_ data: Data?) -> SubtitleLook {
        guard let data, let look = try? JSONDecoder().decode(SubtitleLook.self, from: data) else {
            return .standard
        }
        return look
    }

    // MARK: VLC

    /// Which VLC the options are for.
    public enum Engine: Sendable {
        /// VLC 4 (VLCKit on Apple). Keeps `background-opacity` at 1 minimum, see
        /// ``vlcOptions(look:baseScale:outputHeight:engine:)``. The size does not
        /// go in as an option here; the player takes ``textScalePercent(look:baseScale:)``.
        case vlc4Apple
        /// VLC 3 (Android, Linux, Windows). Size goes in as `--sub-text-scale`.
        case vlc3
    }

    /// Percent for VLC's text scale: base scale times step times 100, rounded
    /// (iPhone 66 / 82 / 98 / 119, iPad and Mac 62 / 78 / 94 / 113, TV 70 / 88 / 106 / 128).
    public static func textScalePercent(look: SubtitleLook, baseScale: Double) -> Int {
        Int((baseScale * look.size.factor * 100).rounded())
    }

    /// Extra margin of "raised": 7 % of the output height in pixels (1080 gives 76,
    /// 2160 gives 151).
    public static func raisedMargin(outputHeight: Int) -> Int {
        Int((Double(outputHeight) * 0.07).rounded())
    }

    /// **The library options for a look**, without the font (platform specific).
    ///
    /// - Outline: thickness per step, opacity 230, black.
    /// - Shadow: off is opacity 0. On is black, opacity 160, 4 % of the font height,
    ///   straight down (angle -90): VLC only does a hard copy, and a slanted one reads
    ///   as a crooked outline.
    /// - Background: on is black at 160. **Off is 1 on Apple, 0 elsewhere.** Above 0
    ///   VLC 4 pads the subtitle picture by a quarter of the font height; without
    ///   the padding a glyph can reach above the picture and `BlendGlyphToARGB`
    ///   crashes. `--freetype-shadow-opacity=0` is not the cause: the build that
    ///   shipped it together with background opacity 1 ran without the crash, and
    ///   the crash report in `LISTE.md` of 30.10. names it as an unproven suspect only.
    ///   So the 1 stays (also with the background on, 160 pads too) until Patch 0039
    ///   is part of the shipped VLCKit.
    /// - Position: `sub-margin` in output pixels. Bottom 16 on Apple, 0 elsewhere;
    ///   raised adds ``raisedMargin(outputHeight:)``.
    public static func vlcOptions(look: SubtitleLook, baseScale: Double, outputHeight: Int,
                                  engine: Engine = .vlc4Apple) -> [String] {
        var options: [String] = []
        if engine == .vlc3 {
            options.append("--sub-text-scale=\(textScalePercent(look: look, baseScale: baseScale))")
        }
        options += [
            "--freetype-color=\(look.colour.rgb)",
            "--freetype-outline-thickness=\(look.outline.thickness)",
            "--freetype-outline-opacity=230",
            "--freetype-outline-color=0",
        ]
        if look.shadow {
            options += [
                "--freetype-shadow-opacity=160",
                "--freetype-shadow-angle=-90",
                "--freetype-shadow-distance=0.04",
                "--freetype-shadow-color=0",
            ]
        } else {
            options.append("--freetype-shadow-opacity=0")
        }
        if look.background {
            options += ["--freetype-background-opacity=160", "--freetype-background-color=0"]
        } else {
            options.append("--freetype-background-opacity=\(engine == .vlc4Apple ? 1 : 0)")
        }
        let base = engine == .vlc4Apple ? 16 : 0
        let margin = base + (look.position == .raised ? raisedMargin(outputHeight: outputHeight) : 0)
        // VLC 3 has no `sub-margin` by default; 0 would be the same as leaving it out.
        if margin > 0 || engine == .vlc4Apple { options.append("--sub-margin=\(margin)") }
        return options
    }
}
