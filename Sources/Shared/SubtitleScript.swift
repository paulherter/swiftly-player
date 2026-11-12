import Foundation

/// **How much outline a script can take.** A heavy outline centred on the glyph edge is fine for Latin,
/// but it fills the dots, joins and small counters of connected and dense scripts (Arabic, Hebrew, the
/// Indic and South-East Asian scripts) and the letters clot. The overlay asks per text run:
/// Latin and everything else keeps today's look to the pixel; the others get a thinner outline drawn
/// behind the fill and a softer shadow. Foundation only, so the table is testable anywhere.
enum SubtitleScript {

    enum Density: Equatable {
        /// Latin, Cyrillic, Greek, CJK ...: the look as saved.
        case plain
        /// Hebrew, Indic and South-East Asian scripts: many small marks and counters.
        case dense
        /// Arabic and its relatives (Syriac, Thaana, N'Ko): letters join and carry dots.
        case connected

        /// Share of the saved outline thickness that is drawn.
        var outlineScale: Double {
            switch self { case .plain: 1; case .dense: 0.75; case .connected: 0.6 }
        }

        /// Share of the saved shadow strength (opacity) that is drawn.
        var shadowScale: Double {
            switch self { case .plain: 1; case .dense: 0.7; case .connected: 0.55 }
        }

        /// The calmer shadow also gets a little blur, as a share of the font size (0 keeps the hard
        /// offset copy Latin has).
        var shadowBlur: Double {
            switch self { case .plain: 0; case .dense: 0.015; case .connected: 0.025 }
        }
    }

    /// A stretch of the line with one density, in UTF-16 offsets (what `NSAttributedString` wants).
    struct Run: Equatable {
        let range: NSRange
        let density: Density
    }

    /// The density of one character, or `nil` when it takes its neighbour's (spaces, punctuation,
    /// digits, combining marks of other scripts), so a run never breaks inside one word.
    static func density(of scalar: Unicode.Scalar) -> Density? {
        let v = scalar.value
        switch v {
        case 0x0600...0x06FF, 0x0700...0x074F, 0x0750...0x077F, 0x0780...0x07BF, 0x07C0...0x07FF,
             0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return .connected
        case 0x0590...0x05FF, 0xFB1D...0xFB4F,                  // Hebrew
             0x0900...0x0DFF,                                    // Devanagari ... Sinhala
             0x0E00...0x0EFF,                                    // Thai, Lao
             0x0F00...0x0FFF,                                    // Tibetan
             0x1000...0x109F, 0x1780...0x17FF, 0x19E0...0x19FF:  // Myanmar, Khmer
            return .dense
        default:
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                return .plain
            default:
                return nil
            }
        }
    }

    /// The line cut into runs of one density. Neutral characters join the run before them; leading
    /// ones join the first run. An empty line gives no runs.
    static func runs(in line: String) -> [Run] {
        var result: [Run] = []
        var start = 0
        var offset = 0
        var current: Density?
        for scalar in line.unicodeScalars {
            let width = scalar.utf16.count
            if let found = density(of: scalar) {
                if let now = current, now != found {
                    result.append(Run(range: NSRange(location: start, length: offset - start), density: now))
                    start = offset
                }
                current = found
            }
            offset += width
        }
        if offset > start {
            result.append(Run(range: NSRange(location: start, length: offset - start), density: current ?? .plain))
        }
        return result
    }

    /// The most demanding density in the line (`connected` over `dense` over `plain`): the layer-wide
    /// shadow follows it, because one text layer has one shadow.
    static func strongest(in runs: [Run]) -> Density {
        if runs.contains(where: { $0.density == .connected }) { return .connected }
        if runs.contains(where: { $0.density == .dense }) { return .dense }
        return .plain
    }

    /// `strokeWidth` for one run, in percent of the font size, for the saved thickness (percent of
    /// the font height, 0 = off). Always positive (stroke only), drawn behind the fill layer, so the outside edge
    /// keeps `thickness * outlineScale` and nothing is eaten from the letter (`plain` has scale 1).
    static func strokeWidth(thickness: Int, density: Density) -> Double {
        guard thickness > 0 else { return 0 }
        let legacy = Double(thickness) * 2
        return legacy * density.outlineScale
    }
}
