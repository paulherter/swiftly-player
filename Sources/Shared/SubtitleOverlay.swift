import AVFoundation
import CoreMedia
import CoreText
import JellyfinKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if canImport(UIKit)
private typealias PlatformFont = UIFont
#else
private typealias PlatformFont = NSFont
#endif

// MARK: - What the player surface lists

/// **One entry of the audio or subtitle list.** The tracks are the server's streams; the panels
/// only need the id and the names.
struct SurfaceTrack {
    let trackId: String
    let trackName: String
    let prettyName: String
    var stream: MediaStream?
    var isSelected = false

    init(stream: MediaStream, name: String, selected: Bool) {
        trackId = "av-\(stream.type ?? "")-\(stream.index ?? -1)"
        trackName = name
        prettyName = name
        self.stream = stream
        isSelected = selected
    }
}

// MARK: - The request a play brings along

/// **Everything the engine needs besides the address**, set with the track request before
/// `play`: what the server (or the download's stored metadata) says about the file.
struct EngineRequest: Sendable {
    let itemID: String
    /// The unchanged file, as the server describes it.
    let source: MediaSource
    /// The text subtitles the app draws itself, one file per track.
    let subtitleFiles: [SubtitleFile]
    /// The server converts the video (plan method transcode): no Dolby Vision reaches the engine.
    var transcoded = false
}

// MARK: - Subtitle text drawn by the app
/// **The app draws the subtitles itself** (text and pictures) over the picture, in the saved
/// look: size relative to the picture height, outline in percent of the font height, shadow
/// straight down, bottom margin 16 plus the raised step.
@MainActor
final class SubtitleOverlay {
    let layer = CALayer()
    /// The line as saved. For a line with Arabic, Hebrew, Indic ... runs these runs are only the
    /// (thinner) outline, and ``fill`` draws the letters on top of it.
    private let text = CATextLayer()
    private let fill = CATextLayer()
    private var shown: String?
    private var shownRuns: [ASSRun] = []
    private var shownIn: (CGRect, CGRect)?
    /// The saved look. Taken from the store when the overlay is made and **again whenever the store changes**: the
    /// settings of the other devices arrive from the server a moment after launch, and the look can be changed
    /// while a title plays. An overlay made with an explicit look (tests) keeps it.
    private(set) var look: SubtitleLook {
        didSet {
            #if DEBUG
            Self.probe?("changed", look)
            #endif
        }
    }
    #if DEBUG
    /// The live run's window into the overlay: called with "made" and "changed" and the look drawn from then on.
    nonisolated(unsafe) static var probe: ((String, SubtitleLook) -> Void)?
    #endif
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var lastLine: (line: String?, styled: [ASSRun], bounds: CGRect, picture: CGRect)?

    /// "Use the file's subtitle style" is on: ASS / SSA cues (and SRT with colour or italic tags) are
    /// drawn in what the file says, the saved look only fills what the file leaves open. Off: the saved
    /// look for everything.
    var keepsFileStyle: Bool { look.keepFileStyle }

    private var pictures: [CALayer] = []
    private var picturesShown: [Int] = []
    private var picturesIn: (CGRect, CGRect)?
    private var lastImages: (images: [(id: Int, cgImage: CGImage, position: CGRect, canvas: CGSize)], bounds: CGRect, picture: CGRect)?

    /// **The scale of the screen the picture is on** (set by the player view from its window or trait collection).
    /// Text and bitmaps are drawn at this scale and placed on whole device pixels, so a line is never rasterised at
    /// 1x and stretched, and no letter edge sits on half a pixel. Unset: the main screen.
    var displayScale: CGFloat? {
        didSet {
            guard displayScale != oldValue else { return }
            shown = nil
            shownRuns = []
            shownIn = nil
            picturesShown = []
            picturesIn = nil
            if let last = lastImages { show(images: last.images, in: last.bounds, picture: last.picture) }
            if let last = lastLine { show(last.line, styled: last.styled, in: last.bounds, picture: last.picture) }
        }
    }
    private var scale: CGFloat { displayScale ?? Self.scale }
    private func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }

    // MARK: Position (the reference for every platform)

    /// **Distance of the text from the bottom edge of the picture: 16 pt, and with "raised" 7 % of the picture
    /// height more.** Apple's value; Android, Windows and Linux follow it (contract `subtitles.md`).
    static let bottomMargin: CGFloat = 16
    static let raisedShare: CGFloat = 0.07
    static func margin(raised: Bool, pictureHeight: CGFloat) -> CGFloat {
        bottomMargin + (raised ? pictureHeight * raisedShare : 0)
    }

    /// **Picture subtitles (PGS, DVD, DVB)**: the engine hands over rendered bitmaps with a
    /// position normalised against the subtitle canvas. The canvas is mapped width-aligned and
    /// centred onto the video rect, so a cue lands where the disc authored it.
    func show(images: [(id: Int, cgImage: CGImage, position: CGRect, canvas: CGSize)], in bounds: CGRect, picture: CGRect) {
        let ids = images.map(\.id)
        lastImages = (images, bounds, picture)
        if ids == picturesShown, let picturesIn, picturesIn.0 == bounds, picturesIn.1 == picture { return }
        layer.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        picturesShown = ids
        picturesIn = (bounds, picture)
        let video = picture.isEmpty ? bounds : picture
        while pictures.count < images.count {
            let bitmap = CALayer()
            // Smooth both ways: a cue authored for a 1080p canvas is scaled down on a phone and up on a 4K screen.
            bitmap.magnificationFilter = .linear
            bitmap.minificationFilter = .trilinear
            layer.addSublayer(bitmap)
            pictures.append(bitmap)
        }
        for (position, bitmap) in pictures.enumerated() {
            guard position < images.count, video.width > 1, video.height > 1 else { bitmap.isHidden = true; continue }
            let image = images[position]
            let canvas = image.canvas.width > 1 && image.canvas.height > 1
                ? image.canvas : CGSize(width: video.width, height: video.height)
            let fit = video.width / canvas.width
            let canvasHeight = canvas.height * fit
            let top = (video.height - canvasHeight) / 2
            let width = image.position.width * canvas.width * fit
            let height = image.position.height * canvas.height * fit
            let x = video.minX + image.position.minX * canvas.width * fit
            let offset = top + image.position.minY * canvasHeight
            #if canImport(UIKit)
            let y = video.minY + offset
            #else
            let y = video.maxY - offset - height
            #endif
            bitmap.contents = image.cgImage
            bitmap.contentsScale = scale
            bitmap.frame = CGRect(x: pixel(x), y: pixel(y), width: max(1 / scale, pixel(width)), height: max(1 / scale, pixel(height)))
            bitmap.isHidden = false
        }
    }

    init(look: SubtitleLook? = nil) {
        self.look = look ?? SubtitleStyle.look
        if look == nil {
            var seen = UserDefaults.standard.data(forKey: "utAussehen")
            observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    let now = UserDefaults.standard.data(forKey: "utAussehen")
                    guard now != seen else { return }
                    seen = now
                    self?.apply(look: SubtitleLook.read(now))
                }
            }
        }
        for part in [text, fill] {
            part.alignmentMode = .center
            part.isWrapped = true
            part.truncationMode = .none
            part.isHidden = true
            layer.addSublayer(part)
        }
        layer.isHidden = false
        #if DEBUG
        Self.probe?("made", self.look)
        #endif
    }

    /// A new saved look: drawn at once, the line on screen too.
    func apply(look new: SubtitleLook) {
        guard new != look else { return }
        look = new
        shown = nil
        shownRuns = []
        shownIn = nil
        picturesShown = []
        picturesIn = nil
        if let last = lastLine { show(last.line, styled: last.styled, in: last.bounds, picture: last.picture) }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// `picture` is where the video really is inside the layer (`AVPlayerLayer.videoRect`).
    /// `styled` are the pieces of the line with the look the file gave them (empty: the saved look; the
    /// text of the pieces is then `line`).
    func show(_ line: String?, styled: [ASSRun] = [], in bounds: CGRect, picture: CGRect) {
        // Called ten times a second: the same line in the same place costs nothing.
        if shown == line, shownRuns == styled, let shownIn, shownIn.0 == bounds, shownIn.1 == picture { return }
        lastLine = (line, styled, bounds, picture)
        layer.frame = bounds
        guard let line, !line.isEmpty else {
            text.isHidden = true
            fill.isHidden = true
            shown = nil
            shownRuns = []
            shownIn = nil
            return
        }
        let visible = (picture.isEmpty ? bounds : picture.intersection(bounds))
        guard visible.width > 1, visible.height > 1 else { return }
        let size = visible.height * 0.0625 * CGFloat(SubtitleStyle.size(for: look))
        let runs = SubtitleScript.runs(in: line)
        let strongest = SubtitleScript.strongest(in: runs)
        let (string, fillString) = Self.strings(line, runs: runs, look: look, size: size, styled: styled)
        let room = CGSize(width: visible.width * 0.9, height: visible.height * 0.6)
        let box = string.boundingRect(with: room, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).integral
        let margin = Self.margin(raised: look.position == .raised, pictureHeight: visible.height)
        let width = min(room.width, box.width + size)
        let frame: CGRect
        #if canImport(UIKit)
        frame = CGRect(x: pixel(visible.midX - width / 2), y: pixel(visible.maxY - margin - box.height),
                       width: pixel(width), height: box.height)
        #else
        // AppKit layers have their origin at the bottom.
        frame = CGRect(x: pixel(visible.midX - width / 2), y: pixel(visible.minY + margin),
                       width: pixel(width), height: box.height)
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.contentsScale = scale
        text.frame = frame
        text.string = string
        fill.contentsScale = scale
        fill.frame = frame
        fill.string = fillString
        fill.isHidden = fillString == nil
        // One shadow per layer: a line with a connected or dense script gets the calmer one as a whole.
        // The file's shadow (its first piece decides, one layer has one shadow) replaces the saved one.
        if let first = styled.first, let depth = first.shadowEm {
            let colour = first.back ?? SubtitleColour(rgb: 0)
            text.shadowColor = Self.cgColor(colour, opacity: 1)
            text.shadowOpacity = depth > 0 ? Float(colour.opacity * strongest.shadowScale) : 0
            text.shadowRadius = size * strongest.shadowBlur
            let down = size * min(depth, 0.2)
            #if canImport(UIKit)
            text.shadowOffset = CGSize(width: down, height: down)
            #else
            text.shadowOffset = CGSize(width: down, height: -down)
            #endif
        } else {
            text.shadowColor = CGColor(gray: 0, alpha: 1)
            text.shadowOpacity = look.shadow ? Float(0.63 * strongest.shadowScale) : 0
            text.shadowRadius = size * strongest.shadowBlur
            #if canImport(UIKit)
            text.shadowOffset = CGSize(width: 0, height: size * 0.04 * (strongest == .plain ? 1 : 0.6))
            #else
            text.shadowOffset = CGSize(width: 0, height: -size * 0.04 * (strongest == .plain ? 1 : 0.6))
            #endif
        }
        if let first = styled.first, first.borderStyle == 3 {
            // ASS "opaque box": the box is the outline colour.
            let box = first.outline ?? SubtitleColour(rgb: 0, opacity: 0.63)
            text.backgroundColor = Self.cgColor(box, opacity: 1)
        } else {
            text.backgroundColor = look.background ? CGColor(gray: 0, alpha: 0.63) : nil
        }
        text.isHidden = false
        CATransaction.commit()
        shown = line
        shownRuns = styled
        shownIn = (bounds, picture)
    }

    private static func cgColor(_ colour: SubtitleColour, opacity: CGFloat) -> CGColor {
        CGColor(srgbRed: CGFloat(colour.red) / 255, green: CGFloat(colour.green) / 255, blue: CGFloat(colour.blue) / 255,
                alpha: CGFloat(colour.opacity) * opacity)
    }

    private static var scale: CGFloat {
        #if canImport(UIKit)
        // No trait collection outside a layout pass: the main screen is what the host sits on.
        UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale
            : max(UIScreen.main.scale, 2)
        #else
        NSScreen.main?.backingScaleFactor ?? 2
        #endif
    }

    /// **The two strings of a line.** The first is the outline only (stroke, no fill), the second draws all
    /// letters on top of it, so the outline can never eat the letter. Runs of connected or dense scripts get
    /// a thinner outline. No outline: one string, no second layer.
    /// `styled` are the pieces the file gave their own look (its text is `line`); without them the line
    /// is one piece in the saved look.
    static func strings(_ line: String, runs: [SubtitleScript.Run], look: SubtitleLook, size: CGFloat,
                        styled: [ASSRun] = [])
        -> (outline: NSAttributedString, fill: NSAttributedString?) {
        let outline: NSMutableAttributedString
        if styled.isEmpty {
            outline = NSMutableAttributedString(string: line, attributes: attributes(look: look, size: size))
        } else {
            outline = NSMutableAttributedString()
            for run in styled {
                outline.append(NSAttributedString(string: run.text, attributes: attributes(look: look, size: size, run: run)))
            }
        }
        // Without an outline there is nothing to keep out of the letters: one layer, as always.
        var outlined = false
        outline.enumerateAttribute(.strokeWidth, in: NSRange(location: 0, length: outline.length)) { value, _, stop in
            if value != nil { outlined = true; stop.pointee = true }
        }
        // **The outline lies outside the letter** (as VLC and libass draw it), for the saved look and the file's:
        // stroke only in the first string, the letters in a second layer on top. A stroke centred on the
        // letter's edge and painted over it (the old Latin look) ate half the stroke width out of every letter:
        // thin letters inside a thick outline.
        let letters = NSMutableAttributedString(attributedString: outline)
        let whole = NSRange(location: 0, length: letters.length)
        letters.removeAttribute(.strokeWidth, range: whole)
        letters.removeAttribute(.strokeColor, range: whole)
        for run in runs where run.density != .plain {
            var pieces: [(NSRange, Double)] = []
            outline.enumerateAttribute(.strokeWidth, in: run.range) { value, range, _ in
                if let width = value as? Double { pieces.append((range, abs(width))) }
            }
            for (range, legacy) in pieces {
                outline.addAttribute(.strokeWidth, value: legacy * run.density.outlineScale, range: range)
            }
        }
        return (outline, letters)
    }

    private static var clear: Any {
        #if canImport(UIKit)
        UIColor.clear
        #else
        NSColor.clear
        #endif
    }

    /// Bold and italic of a piece. Inter ships here in one weight and no italic cut: bold only where the
    /// family has one, italic as a slant of the same glyphs (what the system does for a font without one).
    private static func styled(_ font: PlatformFont, run: ASSRun?) -> PlatformFont {
        guard let run, run.bold == true || run.italic == true else { return font }
        var ct: CTFont = font
        if run.bold == true,
           let bold = CTFontCreateCopyWithSymbolicTraits(ct, CTFontGetSize(ct), nil, .traitBold, .traitBold) {
            ct = bold
        }
        if run.italic == true {
            var slant = CGAffineTransform(a: 1, b: 0, c: 0.2126, d: 1, tx: 0, ty: 0)   // 12 degrees
            ct = CTFontCreateCopyWithAttributes(ct, CTFontGetSize(ct), &slant, nil)
        }
        return unsafeBitCast(ct, to: PlatformFont.self)
    }

    private static func attributes(look: SubtitleLook, size: CGFloat, run: ASSRun? = nil)
        -> [NSAttributedString.Key: Any] {
        let rgb = look.colour.rgb
        // The file's fill colour (with its opacity) wins when it gave one.
        let colour: CGColor
        if let file = run?.primary {
            colour = cgColor(file, opacity: 1)
        } else {
            // sRGB, not the device-independent "generic" space CGColor(red:...) uses on the Mac (it shifted yellow
            // and made the grey lighter than the design's).
            colour = CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                             blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        #if canImport(UIKit)
        var font = UIFont(name: SubtitleStyle.fontName, size: size) ?? UIFont.systemFont(ofSize: size, weight: .semibold)
        font = styled(font, run: run)
        let fill = UIColor(cgColor: colour)
        var stroke = UIColor(white: 0, alpha: 0.9)
        #else
        var font = NSFont(name: SubtitleStyle.fontName, size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
        font = styled(font, run: run)
        let fill = NSColor(cgColor: colour) ?? .white
        var stroke = NSColor(white: 0, alpha: 0.9)
        #endif
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: fill, .paragraphStyle: style,
        ]
        // Thickness in percent of the font height: the file's (outline pixels / its font size) or the saved one.
        var thickness = Double(look.outline.thickness)
        if let file = run, let em = file.outlineEm {
            thickness = file.borderStyle == 3 ? 0 : min(em * 100, 8)
            if let edge = file.outline {
                if edge.opacity <= 0.01 { thickness = 0 }
                #if canImport(UIKit)
                stroke = UIColor(cgColor: cgColor(edge, opacity: 1))
                #else
                stroke = NSColor(cgColor: cgColor(edge, opacity: 1)) ?? stroke
                #endif
            }
        }
        if thickness > 0.05 {
            // Percent of the font size, centred on the edge, so the visible outline (outside the letter) is
            // about half of it. Positive: stroke only; the letters come from the layer on top (see `strings`).
            attributes[.strokeColor] = stroke
            attributes[.strokeWidth] = thickness * 2
        }
        return attributes
    }
}
