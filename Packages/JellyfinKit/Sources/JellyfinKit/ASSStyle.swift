import Foundation

// MARK: - The file's own subtitle style (ASS / SSA), for "use the file's style"

/// **A colour with opacity**, as the file writes it: `&HAABBGGRR` where `AA` 00 is opaque and FF clear.
/// ``opacity`` is the usual way round (1 = opaque).
public struct SubtitleColour: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var opacity: Double

    public init(red: UInt8, green: UInt8, blue: UInt8, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// `0xRRGGBB` plus opacity.
    public init(rgb: Int, opacity: Double = 1) {
        self.init(red: UInt8((rgb >> 16) & 0xFF), green: UInt8((rgb >> 8) & 0xFF), blue: UInt8(rgb & 0xFF),
                  opacity: opacity)
    }

    public var rgb: Int { Int(red) << 16 | Int(green) << 8 | Int(blue) }

    /// One ASS colour value: `&H00FFFF&`, `&HAABBGGRR`, `H00FFFF`, or the decimal form older SSA files
    /// use. `6` digits have no alpha (opaque); fewer digits are padded on the left.
    public static func parse(_ text: String) -> SubtitleColour? {
        var value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let number: UInt32
        let upper = value.uppercased()
        if upper.hasPrefix("&H") || upper.hasPrefix("H") || upper.hasPrefix("&") {
            value = upper.replacingOccurrences(of: "&", with: "")
            if value.hasPrefix("H") { value.removeFirst() }
            guard !value.isEmpty, value.count <= 8, let parsed = UInt32(value, radix: 16) else { return nil }
            number = parsed
        } else if let signed = Int64(value) {
            // Decimal, possibly negative: the bit pattern of a 32-bit value.
            number = UInt32(truncatingIfNeeded: signed)
        } else {
            return nil
        }
        let alpha = Double((number >> 24) & 0xFF)
        return SubtitleColour(red: UInt8(number & 0xFF), green: UInt8((number >> 8) & 0xFF),
                              blue: UInt8((number >> 16) & 0xFF), opacity: 1 - alpha / 255)
    }

    /// `\alpha&H80&`, `\1a&HFF&`: the alpha byte on its own (00 opaque, FF clear).
    static func parseAlpha(_ text: String) -> Double? {
        let value = text.uppercased().replacingOccurrences(of: "&", with: "").replacingOccurrences(of: "H", with: "")
        guard !value.isEmpty, let byte = UInt32(value, radix: 16) ?? UInt32(value, radix: 10), byte <= 255 else { return nil }
        return 1 - Double(byte) / 255
    }
}

/// **One style of the script** (`Style:` line), resolved to what the overlay needs.
public struct ASSStyle: Equatable, Sendable {
    public var name: String
    public var fontSize: Double
    public var primary: SubtitleColour
    public var outline: SubtitleColour
    public var back: SubtitleColour
    public var bold: Bool
    public var italic: Bool
    /// Outline and shadow depth in script pixels (`PlayRes`).
    public var outlineWidth: Double
    public var shadowWidth: Double
    /// 1 = outline and shadow, 3 = opaque box (in the outline colour).
    public var borderStyle: Int

    public init(name: String = "Default", fontSize: Double = 20,
                primary: SubtitleColour = .init(rgb: 0xFFFFFF), outline: SubtitleColour = .init(rgb: 0),
                back: SubtitleColour = .init(rgb: 0, opacity: 0.5), bold: Bool = false, italic: Bool = false,
                outlineWidth: Double = 2, shadowWidth: Double = 0, borderStyle: Int = 1) {
        self.name = name
        self.fontSize = fontSize
        self.primary = primary
        self.outline = outline
        self.back = back
        self.bold = bold
        self.italic = italic
        self.outlineWidth = outlineWidth
        self.shadowWidth = shadowWidth
        self.borderStyle = borderStyle
    }
}

/// **The styles of a script header** (`[Script Info]` + `[V4+ Styles]` or `[V4 Styles]`).
public struct ASSStyleSheet: Equatable, Sendable {
    public var styles: [String: ASSStyle]
    public var playResY: Double

    public init(styles: [String: ASSStyle] = [:], playResY: Double = 288) {
        self.styles = styles
        self.playResY = playResY
    }

    /// The style an event names; unknown names fall back to `Default`, then to nothing (the caller then
    /// uses the app's own look). A leading `*` (an old SSA habit) is ignored, case does not matter.
    public func style(named name: String) -> ASSStyle? {
        let key = Self.key(name)
        return styles[key] ?? styles["default"]
    }

    static func key(_ name: String) -> String {
        var key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if key.hasPrefix("*") { key.removeFirst() }
        return key
    }

    private static let defaultFormat = ["name", "fontname", "fontsize", "primarycolour", "secondarycolour",
                                        "outlinecolour", "backcolour", "bold", "italic", "underline", "strikeout",
                                        "scalex", "scaley", "spacing", "angle", "borderstyle", "outline", "shadow",
                                        "alignment", "marginl", "marginr", "marginv", "encoding"]

    /// **A header that no author wrote**: what libavcodec and the server write when they turn a plain SRT into
    /// ASS (one `Default` style, white, black outline of 1 or 2 pixels, size 16 or 20). It says nothing about
    /// how the subtitle should look, so it never counts as "the file's style": the saved look applies.
    public var isConverterDefault: Bool {
        guard styles.count == 1, let style = styles["default"] else { return false }
        return [16.0, 20.0].contains(style.fontSize)
            && style.primary.rgb == 0xFFFFFF && style.outline.rgb == 0
            && [1.0, 2.0].contains(style.outlineWidth) && style.shadowWidth <= 2
            && style.borderStyle == 1 && !style.bold && !style.italic
    }

    public static func parse(_ header: String) -> ASSStyleSheet {
        var sheet = ASSStyleSheet()
        var format = defaultFormat
        var inStyles = false
        for raw in header.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let section = line.lowercased()
                inStyles = section.hasPrefix("[v4+ styles") || section.hasPrefix("[v4 styles")
                    || section.hasPrefix("[v4++ styles")
                continue
            }
            if let value = line.value(after: "playresy:") {
                if let height = Double(value), height > 0 { sheet.playResY = height }
                continue
            }
            guard inStyles else { continue }
            if let value = line.value(after: "format:") {
                format = value.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard let value = line.value(after: "style:") else { continue }
            let fields = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            func field(_ names: String...) -> String? {
                for name in names {
                    if let index = format.firstIndex(of: name), index < fields.count { return fields[index] }
                }
                return nil
            }
            guard let name = field("name"), !name.isEmpty else { continue }
            var style = ASSStyle(name: name)
            if let size = field("fontsize").flatMap(Double.init), size > 0 { style.fontSize = size }
            if let colour = field("primarycolour").flatMap(SubtitleColour.parse) { style.primary = colour }
            // SSA calls the outline colour "TertiaryColour".
            if let colour = field("outlinecolour", "tertiarycolour").flatMap(SubtitleColour.parse) { style.outline = colour }
            if let colour = field("backcolour").flatMap(SubtitleColour.parse) { style.back = colour }
            style.bold = field("bold").flatMap(Int.init).map { $0 != 0 } ?? false
            style.italic = field("italic").flatMap(Int.init).map { $0 != 0 } ?? false
            if let width = field("outline").flatMap(Double.init) { style.outlineWidth = max(0, width) }
            if let width = field("shadow").flatMap(Double.init) { style.shadowWidth = max(0, width) }
            if let border = field("borderstyle").flatMap(Int.init) { style.borderStyle = border }
            sheet.styles[key(name)] = style
        }
        return sheet
    }
}

private extension String {
    /// The rest of the line after a case-insensitive prefix (`Style:`), trimmed.
    func value(after prefix: String) -> String? {
        guard lowercased().hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - One piece of a line with its look

/// **One stretch of a cue with one look.** Every field is optional: `nil` means "not given by the file,
/// use the app's own look". With a style sheet the style's values fill them in; the override tags
/// (`\c`, `\1c`, `\3c`, `\4c`, `\alpha`, `\1a`...`\4a`, `\b`, `\i`, `\bord`, `\shad`, `\r`) change them
/// run by run.
public struct ASSRun: Equatable, Sendable {
    public var text: String
    public var primary: SubtitleColour?
    public var outline: SubtitleColour?
    public var back: SubtitleColour?
    public var bold: Bool?
    public var italic: Bool?
    /// Outline and shadow as a share of the font height (script pixels / the style's font size), so the
    /// proportion survives the app's own text size.
    public var outlineEm: Double?
    public var shadowEm: Double?
    public var borderStyle: Int?

    public init(text: String, primary: SubtitleColour? = nil, outline: SubtitleColour? = nil,
                back: SubtitleColour? = nil, bold: Bool? = nil, italic: Bool? = nil,
                outlineEm: Double? = nil, shadowEm: Double? = nil, borderStyle: Int? = nil) {
        self.text = text
        self.primary = primary
        self.outline = outline
        self.back = back
        self.bold = bold
        self.italic = italic
        self.outlineEm = outlineEm
        self.shadowEm = shadowEm
        self.borderStyle = borderStyle
    }

    /// True when the file says anything about the look of this run.
    public var isStyled: Bool {
        primary != nil || outline != nil || back != nil || bold != nil || italic != nil
            || outlineEm != nil || shadowEm != nil || borderStyle != nil
    }
}

/// **Reads the event lines the engine hands over** (`ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,
/// Effect,Text`, tags intact) into styled runs.
public enum ASSCue {

    /// The cue text of `body` (one event line per line) as runs, one list per line of the picture.
    /// `sheet` nil (no header known) reads only the override tags. Drawings (`\p1`) are dropped; `\N` is
    /// a line break, `\h` a no-break space. Lines that do not look like event lines are returned as one
    /// plain run each, so a track that is not ASS passes through unchanged.
    public static func runs(eventLines body: String, sheet: ASSStyleSheet?) -> [ASSRun] {
        var all: [ASSRun] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let parsed = parse(eventLine: String(line), sheet: sheet)
            if parsed.isEmpty { continue }
            if !all.isEmpty { all.append(ASSRun(text: "\n")) }
            all += parsed
        }
        return merged(all)
    }

    /// Splits the eight header fields off an event line; nil when it is not one.
    static func split(_ line: String) -> (style: String, text: String)? {
        var fields: [Substring] = []
        var rest = Substring(line)
        for _ in 0..<8 {
            guard let comma = rest.firstIndex(of: ",") else { return nil }
            fields.append(rest[..<comma])
            rest = rest[rest.index(after: comma)...]
        }
        // ReadOrder and Layer are numbers; that is what tells an event line from a line of words.
        guard fields.count == 8, Int(fields[0].trimmingCharacters(in: .whitespaces)) != nil,
              Int(fields[1].trimmingCharacters(in: .whitespaces)) != nil else { return nil }
        return (String(fields[2]), String(rest))
    }

    static func parse(eventLine line: String, sheet: ASSStyleSheet?) -> [ASSRun] {
        guard let (styleName, text) = split(line) else {
            let plain = line.replacingOccurrences(of: "\\N", with: "\n")
            return plain.isEmpty ? [] : [ASSRun(text: plain)]
        }
        let base = sheet?.style(named: styleName)
        var state = State(base: base)
        var runs: [ASSRun] = []
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            if !state.drawing { runs.append(state.run(text: buffer)) }
            buffer = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{", let close = text[index...].firstIndex(of: "}") {
                let block = text[text.index(after: index)..<close]
                flush()
                state.apply(block: block, sheet: sheet, eventStyle: base)
                index = text.index(after: close)
                continue
            }
            if character == "\\", text.index(after: index) < text.endIndex {
                let next = text[text.index(after: index)]
                switch next {
                case "N": buffer.append("\n"); index = text.index(index, offsetBy: 2); continue
                case "n": buffer.append(" "); index = text.index(index, offsetBy: 2); continue
                case "h": buffer.append("\u{00A0}"); index = text.index(index, offsetBy: 2); continue
                default: break
                }
            }
            buffer.append(character)
            index = text.index(after: index)
        }
        flush()
        return runs
    }

    /// Neighbouring runs with the same look become one.
    static func merged(_ runs: [ASSRun]) -> [ASSRun] {
        var out: [ASSRun] = []
        for run in runs where !run.text.isEmpty {
            if var last = out.last {
                var same = run
                same.text = last.text
                if same == last {
                    last.text += run.text
                    out[out.count - 1] = last
                    continue
                }
            }
            out.append(run)
        }
        // Whitespace around the cue is not drawn.
        while let last = out.last, last.text.allSatisfy({ $0 == "\n" || $0 == " " }) { out.removeLast() }
        while let first = out.first, first.text.allSatisfy({ $0 == "\n" || $0 == " " }) { out.removeFirst() }
        return out
    }

    /// The look while walking through one event.
    private struct State {
        var base: ASSStyle?
        var primary: SubtitleColour?
        var outline: SubtitleColour?
        var back: SubtitleColour?
        var bold: Bool?
        var italic: Bool?
        var outlinePixels: Double?
        var shadowPixels: Double?
        var borderStyle: Int?
        var fontSize: Double
        var drawing = false

        init(base: ASSStyle?) {
            self.base = base
            fontSize = base?.fontSize ?? 20
            reset(to: base)
        }

        mutating func reset(to style: ASSStyle?) {
            primary = style?.primary
            outline = style?.outline
            back = style?.back
            bold = style?.bold
            italic = style?.italic
            outlinePixels = style?.outlineWidth
            shadowPixels = style?.shadowWidth
            borderStyle = style?.borderStyle
            fontSize = style?.fontSize ?? fontSize
        }

        func run(text: String) -> ASSRun {
            let size = max(fontSize, 1)
            return ASSRun(text: text, primary: primary, outline: outline, back: back, bold: bold, italic: italic,
                          outlineEm: outlinePixels.map { $0 / size }, shadowEm: shadowPixels.map { $0 / size },
                          borderStyle: borderStyle)
        }

        mutating func apply(block: Substring, sheet: ASSStyleSheet?, eventStyle: ASSStyle?) {
            for tag in tags(in: block) {
                let (name, value) = Self.split(tag)
                switch name {
                case "c", "1c":
                    primary = SubtitleColour.parse(value).map { keepOpacity($0, of: primary) } ?? base?.primary
                case "3c":
                    outline = SubtitleColour.parse(value).map { keepOpacity($0, of: outline) } ?? base?.outline
                case "4c":
                    back = SubtitleColour.parse(value).map { keepOpacity($0, of: back) } ?? base?.back
                case "1a": setOpacity(value, &primary, base?.primary)
                case "3a": setOpacity(value, &outline, base?.outline)
                case "4a": setOpacity(value, &back, base?.back)
                case "alpha":
                    setOpacity(value, &primary, base?.primary)
                    setOpacity(value, &outline, base?.outline)
                    setOpacity(value, &back, base?.back)
                case "bord": outlinePixels = Double(value) ?? base?.outlineWidth
                case "shad": shadowPixels = Double(value) ?? base?.shadowWidth
                case "fs":
                    if let size = Double(value), size > 0 { fontSize = size } else if let size = base?.fontSize { fontSize = size }
                case "b":
                    if value.isEmpty { bold = base?.bold } else if let weight = Int(value) { bold = weight == 1 || weight >= 700 }
                case "i":
                    if value.isEmpty { italic = base?.italic } else if let flag = Int(value) { italic = flag != 0 }
                case "p": drawing = (Int(value) ?? 0) > 0
                case "r":
                    let named = value.isEmpty ? eventStyle : (sheet?.styles[ASSStyleSheet.key(value)] ?? eventStyle)
                    base = named
                    reset(to: named)
                default: break   // position, animation, blur, karaoke, clip ...: not drawn by the overlay
                }
            }
        }

        /// `1c&H00FFFF&` becomes ("1c", "&H00FFFF&"); `bord2` ("bord", "2"); `rDefault` ("r", "Default").
        static func split(_ tag: String) -> (name: String, value: String) {
            let tag = tag.trimmingCharacters(in: .whitespaces)
            if tag.hasPrefix("r"), !tag.lowercased().hasPrefix("rnd") { return ("r", String(tag.dropFirst())) }
            if let first = tag.first, first.isNumber {
                return (String(tag.prefix(2)).lowercased(), String(tag.dropFirst(2)))
            }
            let letters = tag.prefix { $0.isLetter }
            return (letters.lowercased(), String(tag.dropFirst(letters.count)).trimmingCharacters(in: .whitespaces))
        }

        /// `\c` carries no alpha: it keeps what is set.
        private func keepOpacity(_ colour: SubtitleColour, of old: SubtitleColour?) -> SubtitleColour {
            var colour = colour
            colour.opacity = old?.opacity ?? 1
            return colour
        }

        private func setOpacity(_ text: String, _ target: inout SubtitleColour?, _ original: SubtitleColour?) {
            let opacity = SubtitleColour.parseAlpha(text)
            var colour = target ?? original ?? SubtitleColour(rgb: 0xFFFFFF)
            if let opacity { colour.opacity = opacity } else if let original { colour.opacity = original.opacity }
            target = colour
        }

        /// The tags of `{...}`, split at backslashes outside brackets; `\t(...)`, `\move(...)`, `\clip(...)`,
        /// `\fad(...)` and the like are kept whole and then ignored by name.
        private func tags(in block: Substring) -> [String] {
            var out: [String] = []
            var current = ""
            var depth = 0
            for character in block {
                if character == "(" { depth += 1 }
                if character == ")" { depth = max(0, depth - 1) }
                if character == "\\", depth == 0 {
                    if !current.isEmpty { out.append(current) }
                    current = ""
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty { out.append(current) }
            // A text before the first backslash is a comment.
            return block.first == "\\" ? out : Array(out.dropFirst())
        }
    }
}
