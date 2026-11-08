import AVFoundation
import CoreMedia
import JellyfinKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
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
}

// MARK: - Subtitle text drawn by the app
/// **The app draws the subtitles itself** (text and pictures) over the picture, in the saved
/// look: size relative to the picture height, outline in percent of the font height, shadow
/// straight down, bottom margin 16 plus the raised step.
@MainActor
final class SubtitleOverlay {
    let layer = CALayer()
    private let text = CATextLayer()
    private var shown: String?
    private var shownIn: (CGRect, CGRect)?
    /// Read once per title: the look is chosen in the settings, not while a title plays.
    private let look = SubtitleStyle.look

    private var pictures: [CALayer] = []
    private var picturesShown: [Int] = []
    private var picturesIn: (CGRect, CGRect)?

    /// **Picture subtitles (PGS, DVD, DVB)**: the engine hands over rendered bitmaps with a
    /// position normalised against the subtitle canvas. The canvas is mapped width-aligned and
    /// centred onto the video rect, so a cue lands where the disc authored it.
    func show(images: [(id: Int, cgImage: CGImage, position: CGRect, canvas: CGSize)], in bounds: CGRect, picture: CGRect) {
        let ids = images.map(\.id)
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
            let scale = video.width / canvas.width
            let canvasHeight = canvas.height * scale
            let top = (video.height - canvasHeight) / 2
            let width = image.position.width * canvas.width * scale
            let height = image.position.height * canvas.height * scale
            let x = video.minX + image.position.minX * canvas.width * scale
            let offset = top + image.position.minY * canvasHeight
            #if canImport(UIKit)
            let y = video.minY + offset
            #else
            let y = video.maxY - offset - height
            #endif
            bitmap.contents = image.cgImage
            bitmap.frame = CGRect(x: x, y: y, width: width, height: height)
            bitmap.isHidden = false
        }
    }

    init() {
        text.alignmentMode = .center
        text.isWrapped = true
        text.truncationMode = .none
        layer.addSublayer(text)
        layer.isHidden = false
        text.isHidden = true
    }

    /// `picture` is where the video really is inside the layer (`AVPlayerLayer.videoRect`).
    func show(_ line: String?, in bounds: CGRect, picture: CGRect) {
        // Called ten times a second: the same line in the same place costs nothing.
        if shown == line, let shownIn, shownIn.0 == bounds, shownIn.1 == picture { return }
        layer.frame = bounds
        guard let line, !line.isEmpty else {
            text.isHidden = true
            shown = nil
            shownIn = nil
            return
        }
        let visible = (picture.isEmpty ? bounds : picture.intersection(bounds))
        guard visible.width > 1, visible.height > 1 else { return }
        let size = visible.height * 0.0625 * CGFloat(SubtitleStyle.size(for: look))
        let attributes = Self.attributes(look: look, size: size)
        let string = NSAttributedString(string: line, attributes: attributes)
        let room = CGSize(width: visible.width * 0.9, height: visible.height * 0.6)
        let box = string.boundingRect(with: room, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).integral
        let margin = 16 + (look.position == .raised ? visible.height * 0.07 : 0)
        let width = min(room.width, box.width + size)
        let frame: CGRect
        #if canImport(UIKit)
        frame = CGRect(x: visible.midX - width / 2, y: visible.maxY - margin - box.height,
                       width: width, height: box.height)
        #else
        // AppKit layers have their origin at the bottom.
        frame = CGRect(x: visible.midX - width / 2, y: visible.minY + margin,
                       width: width, height: box.height)
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.contentsScale = Self.scale
        text.frame = frame
        text.string = string
        text.shadowOpacity = look.shadow ? 0.63 : 0
        text.shadowRadius = 0
        #if canImport(UIKit)
        text.shadowOffset = CGSize(width: 0, height: size * 0.04)
        #else
        text.shadowOffset = CGSize(width: 0, height: -size * 0.04)
        #endif
        text.backgroundColor = look.background ? CGColor(gray: 0, alpha: 0.63) : nil
        text.isHidden = false
        CATransaction.commit()
        shown = line
        shownIn = (bounds, picture)
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

    private static func attributes(look: SubtitleLook, size: CGFloat) -> [NSAttributedString.Key: Any] {
        let rgb = look.colour.rgb
        let colour = CGColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                             blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        #if canImport(UIKit)
        let font = UIFont(name: SubtitleStyle.fontName, size: size) ?? UIFont.systemFont(ofSize: size, weight: .semibold)
        let fill = UIColor(cgColor: colour)
        let stroke = UIColor(white: 0, alpha: 0.9)
        #else
        let font = NSFont(name: SubtitleStyle.fontName, size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
        let fill = NSColor(cgColor: colour) ?? .white
        let stroke = NSColor(white: 0, alpha: 0.9)
        #endif
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: fill, .paragraphStyle: style,
        ]
        if look.outline.thickness > 0 {
            // Negative: fill and outline. Percent of the font size, centred on the edge, so the
            // visible outline is about half of it.
            attributes[.strokeColor] = stroke
            attributes[.strokeWidth] = -Double(look.outline.thickness) * 2
        }
        return attributes
    }
}
