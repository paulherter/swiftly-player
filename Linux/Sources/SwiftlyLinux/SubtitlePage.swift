import CGtk
import Foundation
import JellyfinKit

/// **Playback -> "Aussehen der Untertitel" -> the page "Untertitel" (Linux, Windows).**
///
/// The same groups, rows, words and values as the Mac page (`Sources/macOS/
/// MacSubtitleLook.swift`) and the spec (`Notizen/Mehrserver/UNTERTITEL-ENTWURF.md`): size,
/// colour and outline are segments in the row, shadow and background are switches, position
/// is a segment, then "Aufwendige Untertitel" with the file-style switch, then "Zurücksetzen"
/// with a four-second undo strip. Every click is written at once; a running player keeps its
/// core (the look is read when the libVLC core is created, see ``Player``).
///
/// **Two columns when there is room, one column below.** Wide: the picture stands at the left
/// (it does not scroll), the rows scroll at the right. Narrow: the picture stands on top and
/// the rows run below it. One widget tree serves both; ``SubtitleScreen/tick()`` turns the
/// box and sizes the picture.
///
/// **Deviations from the Mac, on purpose:**
/// - The wide layout starts at 900 pt of content width, not 720: here the sidebar is not part
///   of it, and the segment rows need about 450 pt next to a 420 pt picture.
/// - The picture is a scaled screen: the text is `picture height x 6.25 % x base scale x
///   step`, as the player sizes it against the video, instead of the absolute size on the
///   monitor. On a desktop the player window has no fixed size, so there is no "original
///   size" to show; this keeps the proportions right (outline, shadow, box) at any width.
/// - Segments are Tab/Enter buttons; the arrow keys do not step through a strip.
/// - The moving surface of a segment is a colour fade (CSS transition), not a slide.
/// - No "Gilt ab dem nächsten Video." note: the page is not reachable while a video plays.

// MARK: - Words

extension SubtitleLook.Size {
    var name: String {
        switch self {
        case .small: translated("Klein")
        case .normal: translated("Normal")
        case .large: translated("Groß")
        case .huge: translated("Sehr groß")
        }
    }

    /// The style class of the segment's "A": 12, 15, 17, 20 pt.
    var glyphClass: String {
        switch self {
        case .small: "swiftly-seg-12"
        case .normal: "swiftly-seg-15"
        case .large: "swiftly-seg-17"
        case .huge: "swiftly-seg-20"
        }
    }
}

extension SubtitleLook.Colour {
    var name: String {
        switch self {
        case .white: translated("Weiß")
        case .yellow: translated("Gelb")
        case .grey: translated("Grau")
        }
    }

    var tintClass: String {
        switch self {
        case .white: "swiftly-seg-weiss"
        case .yellow: "swiftly-seg-gelb"
        case .grey: "swiftly-seg-grau"
        }
    }
}

extension SubtitleLook.Outline {
    var name: String {
        switch self {
        case .off: translated("Aus")
        case .thin: translated("Dünn")
        case .normal: translated("Normal")
        }
    }
}

extension SubtitleLook.Position {
    var name: String {
        switch self {
        case .bottom: translated("Unten")
        case .raised: translated("Höher")
        }
    }
}

extension SubtitleLook {
    /// The value of the entry row in Playback.
    var entryValue: String {
        isStandard ? translated("Standard") : translated("Eigenes")
    }

    /// The whole setting as one sentence, for assistive technology on the picture.
    var sentence: String {
        [
            size.name,
            colour.name,
            outline == .off ? translated("ohne Rand")
                : outline == .thin ? translated("Rand dünn") : translated("Rand normal"),
            shadow ? translated("mit Schatten") : translated("ohne Schatten"),
            background ? translated("mit Hintergrund") : translated("ohne Hintergrund"),
            position == .bottom ? translated("unten") : translated("höher"),
        ].joined(separator: ", ")
    }

    /// The line under the file switch: it says what applies **now**.
    var fileStyleLine: String {
        keepFileStyle
            ? translated("Bei ASS und SSA bestimmt die Datei Schrift, Farbe und Position. Schilder und Karaoke bleiben im Bild.")
            : translated("Auch ASS und SSA sehen dann aus wie oben. Schilder rutschen als Zeile nach unten.")
    }
}

extension SubtitleStyle {
    /// The face the preview draws with. cairo's toy API knows family and "bold" only, so
    /// the SemiBold of the player is approximated by Bold of the same family.
    static var previewFace: String { "Inter" }
}

extension App {

    /// Whether the signed-in server can hand out ASS as SRT, so the file-style switch means
    /// something. **Jellyfin can.** Where a server kind cannot (Plex for tracks inside the
    /// file, as on Apple), this is the one place to say so; the switch is then locked on
    /// and the line under it says why.
    var fileStyleAdjustable: Bool { true }

    // MARK: Entry row

    /// The last row of the "Sprache" group in Playback.
    func subtitleEntryRow() -> Widget! {
        valuesRow(symbol: "format-text-bold-symbolic", title: translated("Aussehen der Untertitel"),
                  value: selection.subtitleLook.entryValue, arrow: true) { [weak self] in
            self?.subpageOpen(.subtitleLook)
        }
    }

    // MARK: Page

    /// Builds the page into `disc` (an empty page layer).
    func subtitleBuild(into disc: Widget!) {
        let screen = SubtitleScreen(app: self, look: selection.subtitleLook)

        let outer = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(outer, 1)
        gtk_widget_set_vexpand(outer, 1)
        gtk_widget_set_margin_top(outer, Int32(Theme.contentTop))
        gtk_widget_set_margin_start(outer, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(outer, Int32(Theme.edgeSpacing))
        let header = subpageHeader(translated("Untertitel"))
        gtk_widget_set_margin_bottom(header, 14)
        append(outer, header)

        // MARK: Left: the picture and the note below it
        let left = stack(GTK_ORIENTATION_VERTICAL, spacing: 10)
        gtk_widget_set_valign(left, GTK_ALIGN_START)
        let preview = paint(width: 100, height: 236) { _, cr, w, h in
            screen.draw(cr, w, h)
        }
        gtk_widget_set_hexpand(preview, 1)
        help(preview, name: screen.previewName())
        append(left, preview)
        let noteWide = Self.subtitleNote()
        append(left, noteWide)

        // MARK: Right: the rows
        let scroller = pagesScroller()
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_margin_bottom(block, 60)
        gtk_scrolled_window_set_child(OpaquePointer(scroller), block)
        cap(block, in: scroller, on: 640)

        let look = screen.look
        let appearance = settingGroup(translated("Aussehen"))
        append(appearance.space, segmentRow(
            screen, symbol: "zoom-in-symbolic", title: translated("Größe"),
            options: SubtitleLook.Size.allCases.map {
                SegmentOption(value: $0, name: $0.name, text: "A", css: [$0.glyphClass], width: 46)
            },
            current: { $0.size }, choose: { $0.size = $1 }))
        append(appearance.space, rowsLine())
        append(appearance.space, segmentRow(
            screen, symbol: "applications-graphics-symbolic", title: translated("Farbe"),
            options: SubtitleLook.Colour.allCases.map {
                SegmentOption(value: $0, name: $0.name, text: "A",
                              css: ["swiftly-seg-17", $0.tintClass], width: 46)
            },
            current: { $0.colour }, choose: { $0.colour = $1 }))
        append(appearance.space, rowsLine())
        append(appearance.space, segmentRow(
            screen, symbol: "document-edit-symbolic", title: translated("Rand"),
            options: SubtitleLook.Outline.allCases.map {
                SegmentOption(value: $0, name: $0.name, text: nil, css: [], width: 70)
            },
            current: { $0.outline }, choose: { $0.outline = $1 }))
        append(appearance.space, rowsLine())
        append(appearance.space, screen.switchRow(
            symbol: "video-display-symbolic", title: translated("Schatten"), on: look.shadow,
            current: { $0.shadow }, choose: { $0.shadow = $1 }))
        append(appearance.space, rowsLine())
        append(appearance.space, screen.switchRow(
            symbol: "tv-symbolic", title: translated("Dunkler Hintergrund"), on: look.background,
            current: { $0.background }, choose: { $0.background = $1 }))
        append(appearance.space, rowsLine())
        append(appearance.space, segmentRow(
            screen, symbol: "go-down-symbolic", title: translated("Position"),
            options: SubtitleLook.Position.allCases.map {
                SegmentOption(value: $0, name: $0.name, text: nil, css: [], width: 70)
            },
            current: { $0.position }, choose: { $0.position = $1 }))
        append(block, appearance.outer)

        // The foot of the group sits under the picture when the page is wide.
        let noteNarrow = Self.subtitleNote()
        gtk_widget_set_margin_top(noteNarrow, 10)
        append(block, noteNarrow)

        let fancy = settingGroup(translated("Aufwendige Untertitel"))
        let adjustable = fileStyleAdjustable
        let handle = ToggleHandle()
        let fileRow = toggleRow(
            symbol: "text-x-generic-symbolic",
            title: translated("Gestaltung aus der Datei übernehmen"),
            under: adjustable ? look.fileStyleLine
                : translated("Bei Plex-Servern kommt die Gestaltung immer aus der Datei."),
            an: look.keepFileStyle || !adjustable, wrapUnder: true, handle: handle) {
            [weak screen] on in
            screen?.change { $0.keepFileStyle = on }
        }
        if !adjustable { gtk_widget_set_sensitive(fileRow, 0) }
        screen.refreshers.append { look in
            handle.set?(look.keepFileStyle || !adjustable)
            if adjustable { handle.under?(look.fileStyleLine) }
        }
        append(fancy.space, fileRow)
        append(block, fancy.outer)

        // Reset: locked while everything is on its default, quiet instead of translucent.
        let resetGroup = rowsGroup()
        gtk_widget_set_margin_top(resetGroup.outer, 26)
        let reset = valuesRow(symbol: "edit-undo-symbolic", title: translated("Zurücksetzen")) {
            [weak screen] in screen?.reset()
        }
        append(resetGroup.space, reset)
        append(block, resetGroup.outer)
        screen.refreshers.append { look in
            gtk_widget_set_sensitive(reset, look.isStandard ? 0 : 1)
            if look.isStandard {
                gtk_widget_add_css_class(reset, "swiftly-ut-gesperrt")
            } else {
                gtk_widget_remove_css_class(reset, "swiftly-ut-gesperrt")
            }
        }

        // The edge under the picture: the ground runs out, no line.
        let scrolling = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(scrolling), scroller)
        let edge: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(edge, "swiftly-ut-kante")
        gtk_widget_set_size_request(edge, -1, 24)
        gtk_widget_set_valign(edge, GTK_ALIGN_START)
        gtk_widget_set_can_target(edge, 0)
        gtk_overlay_add_overlay(OpaquePointer(scrolling), edge)
        gtk_widget_set_hexpand(scrolling, 1)
        gtk_widget_set_vexpand(scrolling, 1)

        let root = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 28)
        append(root, left)
        append(root, scrolling)

        // The undo strip over the bottom edge.
        let revealer: Widget! = gtk_revealer_new()
        gtk_revealer_set_transition_type(asExpand(revealer), GTK_REVEALER_TRANSITION_TYPE_SLIDE_UP)
        gtk_revealer_set_transition_duration(asExpand(revealer), 280)
        gtk_widget_set_halign(revealer, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(revealer, GTK_ALIGN_END)
        let strip = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_widget_add_css_class(strip, "swiftly-ut-streifen")
        gtk_widget_set_size_request(strip, 360, 48)
        gtk_widget_set_margin_bottom(strip, 16)
        let said = label(translated("Zurückgesetzt"), style: "swiftly-listentitel")
        gtk_label_set_xalign(OpaquePointer(said), 0)
        gtk_widget_set_hexpand(said, 1)
        gtk_widget_set_valign(said, GTK_ALIGN_CENTER)
        append(strip, said)
        let takeBack: Widget! = gtk_button_new()
        gtk_widget_add_css_class(takeBack, "swiftly-ut-zurueck")
        gtk_button_set_child(asButton(takeBack), label(translated("Rückgängig")))
        gtk_widget_set_valign(takeBack, GTK_ALIGN_CENTER)
        signal(takeBack, "clicked") { [weak screen] in screen?.takeBack() }
        append(strip, takeBack)
        gtk_revealer_set_child(asExpand(revealer), strip)

        let shell = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(shell), root)
        gtk_overlay_add_overlay(OpaquePointer(shell), revealer)
        gtk_widget_set_hexpand(shell, 1)
        gtk_widget_set_vexpand(shell, 1)
        append(outer, shell)

        screen.root = root
        screen.left = left
        screen.preview = preview
        screen.noteWide = noteWide
        screen.noteNarrow = noteNarrow
        screen.undoStrip = revealer
        screen.layout(width: 1200)
        screen.refresh()

        append(disc, outer)
        let retained = Unmanaged.passRetained(screen).toOpaque()
        _ = gtk_widget_add_tick_callback(root, subtitleScreenTick, retained, subtitleScreenRelease)
    }

    /// The foot under the "Aussehen" group, which is about text subtitles only.
    private static func subtitleNote() -> Widget! {
        let note = label(translated("Gilt für Untertitel aus Text. Die von Blu-rays sind Bilder und bleiben, wie sie sind."),
                         style: "swiftly-zweitzeile", wrap: true)
        gtk_widget_add_css_class(note, "swiftly-fuss")
        gtk_label_set_justify(OpaquePointer(note), GTK_JUSTIFY_LEFT)
        gtk_label_set_xalign(OpaquePointer(note), 0)
        gtk_label_set_max_width_chars(OpaquePointer(note), 60)
        return note
    }

    /// A row with segments: icon and title at the left, the strip at the right.
    private func segmentRow<V: Equatable>(
        _ screen: SubtitleScreen, symbol: String, title: String, options: [SegmentOption<V>],
        current: @escaping (SubtitleLook) -> V,
        choose: @escaping (inout SubtitleLook, V) -> Void
    ) -> Widget! {
        let strip = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
        gtk_widget_add_css_class(strip, "swiftly-segmente")
        gtk_widget_set_valign(strip, GTK_ALIGN_CENTER)
        var buttons: [Widget] = []
        for option in options {
            let button: Widget! = gtk_button_new()
            gtk_widget_add_css_class(button, "swiftly-segment")
            let text = label(option.text ?? option.name)
            for style in option.css { gtk_widget_add_css_class(text, style) }
            gtk_button_set_child(asButton(button), text)
            gtk_widget_set_size_request(button, Int32(option.width), 24)
            signal(button, "clicked") { [weak screen] in
                screen?.change { choose(&$0, option.value) }
            }
            append(strip, button)
            buttons.append(button)
        }
        screen.refreshers.append { look in
            let now = current(look)
            for (index, option) in options.enumerated() {
                let on = option.value == now
                if on {
                    gtk_widget_add_css_class(buttons[index], "swiftly-aktiv")
                } else {
                    gtk_widget_remove_css_class(buttons[index], "swiftly-aktiv")
                }
                // Each segment names itself ("Größe, Groß"); the chosen one is "selected".
                help(buttons[index], name: "\(title), \(option.name)", selected: on)
            }
        }
        let row = rowBody(symbol: symbol, title: title, under: nil, accent: false, right: strip)
        gtk_widget_add_css_class(row, "swiftly-zeilenrumpf")
        gtk_widget_add_css_class(row, "swiftly-segmentzeile")
        return row
    }
}

/// One choice of a segment strip. `text` nil shows the name; the "A" strips show a letter and
/// carry the name for assistive technology only.
struct SegmentOption<V: Equatable> {
    let value: V
    let name: String
    let text: String?
    let css: [String]
    let width: Int
}

// MARK: - The page's state

/// **Everything the page needs between clicks:** the look, the animation of the picture, the
/// controls to bring up to date after a reset, and the undo.
final class SubtitleScreen {

    /// Content width from which the picture goes to the left.
    static let wideFrom = 900

    /// What the picture is drawn from. Each field moves smoothly to its new value.
    struct Values {
        var scale: Double        // percent, VLC's `--sub-text-scale`
        var outline: Double      // percent of the text height
        var shadow: Double       // 0 ... 1
        var background: Double   // 0 ... 1
        var lift: Double         // 0 ... 1 (the 7 % of "Höher")
        var red: Double, green: Double, blue: Double

        init(_ look: SubtitleLook) {
            scale = Double(SubtitleLook.textScalePercent(look: look, baseScale: SubtitleStyle.baseScale))
            outline = Double(look.outline.thickness)
            shadow = look.shadow ? 1 : 0
            background = look.background ? 1 : 0
            lift = look.position == .raised ? 1 : 0
            let rgb = look.colour.rgb
            red = Double((rgb >> 16) & 255) / 255
            green = Double((rgb >> 8) & 255) / 255
            blue = Double(rgb & 255) / 255
        }

        static func mix(_ a: Values, _ b: Values, _ t: Double) -> Values {
            var v = b
            func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
            v.scale = m(a.scale, b.scale)
            v.outline = m(a.outline, b.outline)
            v.shadow = m(a.shadow, b.shadow)
            v.background = m(a.background, b.background)
            v.lift = m(a.lift, b.lift)
            v.red = m(a.red, b.red)
            v.green = m(a.green, b.green)
            v.blue = m(a.blue, b.blue)
            return v
        }
    }

    weak var app: App?
    private(set) var look: SubtitleLook

    var root: Widget!
    var left: Widget!
    var preview: Widget!
    var noteWide: Widget!
    var noteNarrow: Widget!
    var undoStrip: Widget!
    /// Brings every control in line with a look (after a click, a reset or an undo).
    var refreshers: [(SubtitleLook) -> Void] = []

    private var from: Values
    private var to: Values
    private var started = 0.0
    private var duration = 0.28
    private var linear = false
    private var animating = false

    private var wide = true
    private var lastWidth = -1
    private var lastHeight: Int32 = 0

    private var undoLook: SubtitleLook?
    private var undoToken = 0

    init(app: App, look: SubtitleLook) {
        self.app = app
        self.look = look
        from = Values(look)
        to = from
    }

    // MARK: Changing the look

    /// A click: changes one field, stores the look and moves the picture.
    func change(_ edit: (inout SubtitleLook) -> Void) {
        var next = look
        edit(&next)
        apply(next)
    }

    private func apply(_ next: SubtitleLook) {
        guard next != look else { return }
        let now = LookArt.now
        from = values(at: now)
        to = Values(next)
        started = now
        // With reduced motion only a short, linear fade (`Theme.timeReduced`).
        linear = motionReduced()
        duration = linear ? Theme.timeReduced : 0.28
        animating = true
        look = next
        app?.selection.subtitleLook = next
        app?.selection.secure()
        refresh()
        if let preview { gtk_widget_queue_draw(preview) }
    }

    func refresh() {
        for refresher in refreshers { refresher(look) }
        if let preview { help(preview, name: previewName()) }
    }

    func previewName() -> String {
        "\(translated("Vorschau")): \(look.sentence)"
    }

    // MARK: Reset and undo

    /// "Zurücksetzen" does not ask first, because it can be reversed.
    func reset() {
        let before = look
        guard !before.isStandard else { return }
        apply(.standard)
        undoLook = before
        undoToken += 1
        let token = undoToken
        reveal(true)
        postDeadline(4) { [weak self] in
            guard let self, self.undoToken == token else { return }
            self.undoLook = nil
            self.reveal(false)
        }
    }

    func takeBack() {
        guard let before = undoLook else { return }
        undoToken += 1
        undoLook = nil
        reveal(false)
        apply(before)
    }

    private func reveal(_ on: Bool) {
        guard let undoStrip else { return }
        gtk_revealer_set_reveal_child(asExpand(undoStrip), on ? 1 : 0)
    }

    // MARK: A row with a switch

    /// A switch row whose state follows the look (reset and undo move it too).
    func switchRow(symbol: String, title: String, on: Bool,
                   current: @escaping (SubtitleLook) -> Bool,
                   choose: @escaping (inout SubtitleLook, Bool) -> Void) -> Widget! {
        let handle = ToggleHandle()
        let row = toggleRow(symbol: symbol, title: title, an: on, handle: handle) {
            [weak self] value in
            self?.change { choose(&$0, value) }
        }
        refreshers.append { look in handle.set?(current(look)) }
        return row
    }

    // MARK: Layout and clock

    /// Turns the box between "picture left, rows right" and "picture on top".
    func layout(width: Int) {
        let nowWide = width >= Self.wideFrom
        if nowWide != wide || lastWidth < 0 {
            wide = nowWide
            gtk_orientable_set_orientation(OpaquePointer(root),
                                           nowWide ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL)
            gtk_box_set_spacing(asBox(root), nowWide ? 28 : 10)
            gtk_widget_set_hexpand(left, 0)
            gtk_widget_set_halign(left, nowWide ? GTK_ALIGN_FILL : GTK_ALIGN_START)
            gtk_widget_set_visible(noteWide, nowWide ? 1 : 0)
            gtk_widget_set_visible(noteNarrow, nowWide ? 0 : 1)
        }
        if width != lastWidth {
            lastWidth = width
            // The picture column: 42 % of the page, 420 to 640 wide; on top at most 560.
            let column = nowWide ? min(max(Int(Double(width) * 0.42), 420), 640) : min(width, 560)
            gtk_widget_set_size_request(left, Int32(column), -1)
        }
    }

    /// Every frame: layout from the real width, the picture's height (16:9), the movement.
    func tick() {
        guard let root, let preview else { return }
        let width = Int(gtk_widget_get_width(root))
        if width > 1 { layout(width: width) }
        let pictureWidth = Int(gtk_widget_get_width(preview))
        if pictureWidth > 1 {
            let height = Int32(Double(pictureWidth) * 9 / 16)
            if height != lastHeight {
                lastHeight = height
                gtk_drawing_area_set_content_height(asCharacter(preview), height)
            }
        }
        if animating {
            if LookArt.now - started >= duration { animating = false }
            gtk_widget_queue_draw(preview)
        }
    }

    private func values(at now: Double) -> Values {
        guard animating else { return to }
        let t = min(max((now - started) / duration, 0), 1)
        // easeInOut, the curve of `gentle`; linear with reduced motion.
        let e = linear ? t : (t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
        return .mix(from, to, e)
    }

    // MARK: The picture

    /// **Drawn by the app, not by VLC**, the way VLC calculates the text: outline = step
    /// percent of the text height in black at 230/255; shadow = black 160/255, 4 % of the
    /// height straight down, hard; background = black 160/255 as a box per line with a quarter
    /// of the height around it, no rounded corners. "Höher" lifts the text by 7 % of the
    /// picture height. Not yet compared with VLC's own drawing (spec section 11, point 1).
    func draw(_ cr: OpaquePointer, _ w: Double, _ h: Double) {
        let v = values(at: LookArt.now)
        cairo_save(cr)
        LookArt.rounded(cr, 0, 0, w, h, Double(Theme.cornerArea))
        cairo_clip(cr)
        drawPicture(cr, w, h)
        drawText(cr, w, h, v)
        cairo_restore(cr)
    }

    /// The picture from the bundle, scaled to fill. Missing, a gradient with a light strip
    /// stands in, never an empty surface.
    private func drawPicture(_ cr: OpaquePointer, _ w: Double, _ h: Double) {
        if let surface = LookArt.picture("subtitle-preview") {
            let sw = Double(cairo_image_surface_get_width(surface))
            let sh = Double(cairo_image_surface_get_height(surface))
            let scale = max(w / sw, h / sh)
            cairo_save(cr)
            cairo_translate(cr, (w - sw * scale) / 2, (h - sh * scale) / 2)
            cairo_scale(cr, scale, scale)
            cairo_set_source_surface(cr, surface, 0, 0)
            cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD)
            cairo_paint(cr)
            cairo_restore(cr)
            return
        }
        let gradient = cairo_pattern_create_linear(0, 0, 0, h)!
        cairo_pattern_add_color_stop_rgb(gradient, 0, 0.063, 0.063, 0.063)
        cairo_pattern_add_color_stop_rgb(gradient, 1, 0.227, 0.227, 0.227)
        cairo_set_source(cr, gradient)
        cairo_paint(cr)
        cairo_pattern_destroy(gradient)
        cairo_set_source_rgba(cr, 0.75, 0.75, 0.75, 0.5)
        cairo_rectangle(cr, 0, h - 70, w, 40)
        cairo_fill(cr)
        cairo_set_source_rgb(cr, 0.05, 0.05, 0.05)
        cairo_rectangle(cr, 0, h - 30, w, 30)
        cairo_fill(cr)
    }

    private struct Line {
        let text: String
        let x: Double
        let baseline: Double
        let top: Double
        let advance: Double
    }

    private func drawText(_ cr: OpaquePointer, _ w: Double, _ h: Double, _ v: Values) {
        // The player sizes the text against the picture height: height x 6.25 % x scale.
        let px = h * 0.0625 * v.scale / 100
        cairo_select_font_face(cr, SubtitleStyle.previewFace, CAIRO_FONT_SLANT_NORMAL,
                               CAIRO_FONT_WEIGHT_BOLD)
        cairo_set_font_size(cr, px)
        var face = cairo_font_extents_t()
        cairo_font_extents(cr, &face)
        let lineHeight = face.ascent + face.descent
        let texts = [translated("Hörst du das auch?"), translated("Da hinten am See.")]
        // The gap above the lower edge is VLC's own margin (16 of 1080), "Höher" adds 7 %.
        let bottom = h - (h * 16 / 1080 + h * 0.07 * v.lift)
        var lines: [Line] = []
        for (index, text) in texts.enumerated() {
            var extents = cairo_text_extents_t()
            cairo_text_extents(cr, text, &extents)
            let top = bottom - lineHeight * Double(texts.count - index)
            lines.append(Line(text: text, x: (w - extents.x_advance) / 2,
                              baseline: top + face.ascent, top: top, advance: extents.x_advance))
        }
        let radius = px * v.outline / 100

        // The background: one box per line, drawn together so the overlap does not darken.
        if v.background > 0.001 {
            cairo_push_group(cr)
            cairo_set_source_rgb(cr, 0, 0, 0)
            for line in lines {
                cairo_rectangle(cr, line.x - px / 4, line.top - px / 8,
                                line.advance + px / 2, lineHeight + px / 4)
            }
            cairo_fill(cr)
            cairo_pop_group_to_source(cr)
            cairo_paint_with_alpha(cr, 160.0 / 255 * v.background)
        }
        // The shadow: the outlined text again, black, lowered by 4 % of the height.
        if v.shadow > 0.001 {
            cairo_push_group(cr)
            cairo_set_source_rgb(cr, 0, 0, 0)
            for line in lines {
                cairo_move_to(cr, line.x, line.baseline + px * 0.04)
                cairo_text_path(cr, line.text)
                if radius > 0.01 {
                    cairo_set_line_width(cr, radius * 2)
                    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
                    cairo_stroke_preserve(cr)
                }
                cairo_fill(cr)
            }
            cairo_pop_group_to_source(cr)
            cairo_paint_with_alpha(cr, 160.0 / 255 * v.shadow)
        }
        // The outline: the glyph shape stroked twice as wide as the radius.
        if radius > 0.01 {
            cairo_push_group(cr)
            cairo_set_source_rgb(cr, 0, 0, 0)
            cairo_set_line_width(cr, radius * 2)
            cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
            for line in lines {
                cairo_move_to(cr, line.x, line.baseline)
                cairo_text_path(cr, line.text)
                cairo_stroke(cr)
            }
            cairo_pop_group_to_source(cr)
            cairo_paint_with_alpha(cr, 230.0 / 255)
        }
        cairo_set_source_rgb(cr, v.red, v.green, v.blue)
        for line in lines {
            cairo_move_to(cr, line.x, line.baseline)
            cairo_show_text(cr, line.text)
        }
    }
}

nonisolated(unsafe) private let subtitleScreenTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, data in
    guard let data else { return 0 }
    Unmanaged<SubtitleScreen>.fromOpaque(data).takeUnretainedValue().tick()
    return 1
}

nonisolated(unsafe) private let subtitleScreenRelease: @convention(c) (gpointer?) -> Void = { data in
    guard let data else { return }
    Unmanaged<SubtitleScreen>.fromOpaque(data).release()
}
