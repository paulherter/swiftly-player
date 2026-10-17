import CGtk
import Foundation
import JellyfinKit

/// **The technical info badge: information that stays put.**
///
/// Verbatim the version of `Sources/Shared/TechBadge.swift`, only drawn
/// in GTK. The numbers come from ``JellyfinKit/Zaehlwerk`` and the wording
/// from ``JellyfinKit/Technikangaben``, both in the package so the platforms
/// do not drift apart.
///
/// **One line is missing on purpose:** "zu spaet" does not exist.
/// `libvlc_media_stats_t` has no late-picture count; VLCKit provides it via
/// `latePictures`, the C interface does not. Writing a zero would state
/// something that is not known.
/// **Measuring mode: all lines, no maximum height** (Mac: `@AppStorage
/// ("technikschildMessen")`, set as launch argument `-technikschildMessen
/// YES`). No settings switch: this is a debugging tool, not for viewers. The
/// same launch argument is read here; GTK never sees the command line
/// (`g_application_run` gets `argc` 0), so it bothers nobody. Alternatively
/// `SWIFTLY_TECHNIKSCHILD_MESSEN=1`.
private let techBadgeMeasure: Bool = {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "-technikschildMessen"), i + 1 < a.count,
       ["yes", "true", "1"].contains(a[i + 1].lowercased()) { return true }
    return ProcessInfo.processInfo.environment["SWIFTLY_TECHNIKSCHILD_MESSEN"] == "1"
}()

/// Up to here, extra lines may lengthen the badge; core lines count towards
/// it but are shown beyond it too (Mac: `maxShare`).
private let techBadgeMaxShare = 0.55
/// Column width (Mac: `.frame(width: 260)`). Without it no line wraps, and
/// the reason could not be shortened to two lines.
private let techBadgeWidth: Int32 = 260
/// Line spacing (Mac: `spacing` 4).
private let techBadgeSpacing: Int32 = 4

/// One line of the badge. `kern` is always shown; the maximum height trims
/// the others by priority (Mac: `TruncatedList`, `kern()`).
private struct BadgeRow {
    enum Art { case header, reason, text, line }
    var art: Art = .text
    var markup = ""
    var kern = false
}

extension App {

    /// Where the badge starts at the top when the controls are open: fixed below
    /// the title row (Mac: `mass.top + mass.button + Theme.tileSpacing`).
    private var badgeTop: Int32 { PlayerMetric.top + PlayerMetric.button + Int32(Theme.tileSpacing) }

    /// Adds or removes the badge.
    func techBadgeSet(_ an: Bool) {
        if an {
            guard techBadge == nil, playerFrame != nil else { return }
            let inputField = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_widget_add_css_class(inputField, "swiftly-technikschild")
            let column = stack(GTK_ORIENTATION_VERTICAL, spacing: techBadgeSpacing)
            gtk_widget_set_size_request(column, techBadgeWidth, -1)
            append(inputField, column)
            gtk_widget_set_halign(inputField, GTK_ALIGN_START)
            gtk_widget_set_valign(inputField, GTK_ALIGN_START)
            // Mac: `.padding(.leading, mass.page)`,
            // `.padding(.top, mass.top + mass.button + Theme.tileSpacing)`.
            gtk_widget_set_margin_start(inputField, PlayerMetric.page)
            // **Intercept nothing.** The badge lies over the picture and must not
            // swallow a click meant for the controls.
            gtk_widget_set_can_target(inputField, 0)
            techBadge = inputField
            gtk_overlay_add_overlay(OpaquePointer(playerFrame), inputField)
            // **Directly on the movie**: below title, buttons and bar, and therefore
            // also below the layers and the fixed title. GTK has no "send to back", so
            // it is inserted in front of the controls. Dimming is part of the controls
            // here (`.swiftly-steuerung`), so the badge sits below it; on the Mac it
            // sits above.
            if let prior = playerControls ?? openLayer ?? playerTitleState {
                gtk_widget_insert_before(inputField, playerFrame, prior)
            }
            techBadgeStatus(immediate: true)
            techBadgeUpdate()
        } else {
            if let inputField = techBadge, playerFrame != nil {
                gtk_overlay_remove_overlay(OpaquePointer(playerFrame), inputField)
            }
            techBadge = nil
            techCounter = nil
        }
    }

    /// **It slides with the controls**: open below the title row, closed at the
    /// top edge where they were, by `button + tileSpacing` upward. Movement
    /// instead of a fade, same curve and duration as the controls
    /// (`controlsVisibility`, `titleStateUpdate`). With reduced motion it
    /// slides as briefly as the controls' fade (`Theme.timeReduced`) instead of
    /// travelling along.
    func techBadgeStatus(duration: Double? = nil, immediate: Bool = false) {
        guard let inputField = techBadge else { return }
        let opened = controlsOpen && openLayerArt == nil
        let target = badgeTop - (opened ? 0 : PlayerMetric.button + Int32(Theme.tileSpacing))
        let full = duration ?? (opened ? 0.18 : 0.34)
        let time = motionReduced() ? min(full, Theme.timeReduced) : full
        badgeGlide(inputField, on: target, duration: immediate ? 0 : time,
                      curve: duration != nil || opened ? .easeOut : .easeInOut)
    }

    /// Called at playback pace: 500 ms, the same as everywhere.
    func techBadgeUpdate() {
        guard let inputField = techBadge, let column = gtk_widget_get_first_child(inputField) else { return }
        techCounter = mediaPlayer.countValues.flatMap {
            Counter($0, spot: mediaPlayer.position, running: mediaPlayer.running,
                      before: techCounter)
        }
        wipe(column)
        let rows = techBadgeRows()
        var widgets: [(Widget, Bool)] = []
        for z in rows {
            let w = badgeWidget(z)
            append(column, w)
            widgets.append((w, z.kern))
        }
        // **Core lines always show, only the rest is trimmed** (Mac: `TruncatedList`).
        // The column takes the extra lines from the top as long as they fit in 55 %
        // of the height below the title row, and stops at the first one that does
        // not. No scrolling.
        guard !techBadgeMeasure, let frameRect = playerFrame else { return }
        // The offered height is the Mac badge's: frame minus the offset from the top
        // minus the inner padding (10 top, 10 bottom).
        let offering = Double(gtk_widget_get_height(frameRect) - badgeTop - 20)
        guard offering > 0 else { return }
        let limit = offering * techBadgeMaxShare
        var sum = 0.0
        var full = false
        for (w, kern) in widgets {
            var natural: Int32 = 0
            gtk_widget_measure(w, GTK_ORIENTATION_VERTICAL, techBadgeWidth,
                               nil, &natural, nil, nil)
            let new = sum + (sum == 0 ? 0 : Double(techBadgeSpacing)) + Double(natural)
            if !kern && (full || new > limit) {
                full = true
                gtk_widget_set_visible(w, 0)
                continue
            }
            sum = new
        }
    }

    private func badgeWidget(_ z: BadgeRow) -> Widget {
        if z.art == .line {
            // **A hairline, not spacing.** Above it the file, below it what counts up
            // while playing. Mac: 150 × 1, vertical `abstand / 2`.
            let l = divider()!
            gtk_widget_set_size_request(l, 150, 1)
            gtk_widget_set_halign(l, GTK_ALIGN_START)
            gtk_widget_set_margin_top(l, techBadgeSpacing / 2)
            gtk_widget_set_margin_bottom(l, techBadgeSpacing / 2)
            return l
        }
        let l: Widget = label("")
        gtk_label_set_markup(OpaquePointer(l), z.markup)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_label_set_wrap(OpaquePointer(l), 1)
        gtk_label_set_wrap_mode(OpaquePointer(l), PANGO_WRAP_WORD_CHAR)
        // Without this, a wrapping label requests the width of its whole text and
        // the column would overflow. This way its width applies.
        gtk_label_set_max_width_chars(OpaquePointer(l), 1)
        if z.art == .header { gtk_widget_add_css_class(l, "swiftly-technikkopf") }
        // Two lines are enough for type and codec; the rest of the parenthesis is
        // truncated, outside measuring mode (Mac: `lineLimit(measure ? nil : 2)`).
        if z.art == .reason, !techBadgeMeasure {
            gtk_label_set_lines(OpaquePointer(l), 2)
            gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
        }
        return l
    }

    /// The lines in the Mac's priority order (`Sources/Shared/TechBadge.swift`,
    /// `body`): core always, everything for debugging only in measuring mode.
    private func techBadgeRows() -> [BadgeRow] {
        let measure = techBadgeMeasure
        var rows: [BadgeRow] = []
        let plan = runningPlan
        let source = plan?.source
        let video = source.flatMap(FileDetails.videoTrack)
        let audio = source.flatMap { FileDetails.audioTracks($0).first }
        let subtitle = source.flatMap { FileDetails.subtitleTracks($0).first }

        if let plan {
            // **The word carries the colour**: accent when nothing is converted,
            // warning orange otherwise.
            rows.append(BadgeRow(art: .header, markup: tint(
                TechDetails.delivery(plan.method),
                TechDetails.weight(plan.method) == .good ? Theme.accent : Theme.warning),
                kern: true))
            // **And the reason sits directly below**: whoever reads "Transkodiert"
            // wants to know next what caused it.
            if plan.method == .transcode, let reason = plan.reasons.first {
                rows.append(BadgeRow(art: .reason, markup: tint(reason.text, Theme.warning),
                                          kern: true))
            }
        }

        // Codec, resolution and HDR type; frame rate only in measuring mode.
        let image = [
            TechDetails.codecNameValue(video?.codec),
            TechDetails.imageRow(width: video?.width, height: video?.height,
                                     depth: nil, reach: nil),
            TechDetails.dynamics(video),
            measure ? TechDetails.frameRate(video?.frameRate).map { "\($0) fps" } : nil
        ].compactMap { $0 }
        if !image.isEmpty {
            rows.append(detail(translated("Bild"), image.joined(separator: " · ")))
        }
        if let name = TechDetails.codecNameValue(audio?.codec) {
            var t = name
            if let k = TechDetails.channelWord(audio?.channels) { t += " · \(k)" }
            if let s = TechDetails.language(audio?.language) { t += " · \(s)" }
            rows.append(detail(translated("Ton"), t))
        }
        if let name = TechDetails.codecNameValue(subtitle?.codec) {
            var t = name
            if let s = TechDetails.language(subtitle?.language) { t += " · \(s)" }
            rows.append(detail(translated("Untertitel"), t))
        }
        // Container, size and the file's average bitrate.
        let jeSecond = bytesJeSecond()
        if let source, let c = FileDetails.container(source) {
            let t = TechDetails.bitrate(jeSecond.map { $0 * 8 }).map { "\(c) · Ø \($0)" } ?? c
            rows.append(detail(translated("Datei"), t))
        }

        let w = techCounter
        if let w {
            // **How much buffer lies ahead of the playhead, and what arrives.**
            // Under two seconds it gets tight.
            let seconds = jeSecond.flatMap { w.reserveSeconds(bytesJeSecond: $0) }
            var parts: [String] = []
            if let seconds { parts.append(comma(seconds) + " s") }
            if measure { parts.append("\(w.preAdviceBytes / 1024) KiB") }
            parts.append("\(translated("Eingang")) \(TechDetails.bitrate(w.input) ?? "—")")
            rows.append(detail(translated("Puffer"), parts.joined(separator: " · "),
                                 conspicuous: (seconds ?? .infinity) < 2))
            // Outside measuring mode only if something was lost.
            let loss = w.raw.discarded > 0 || w.raw.audioLost > 0
            if measure || loss {
                rows.append(measureRow("\(translated("Verworfen")) \(w.raw.discarded)"
                                        + " · \(translated("Ton weg")) \(w.raw.audioLost)",
                                        conspicuous: loss))
            }
        }

        // Always, not just in measuring mode: whoever looks here because of
        // stutter should be able to read the cause (see ``Abspieler/rendererReport()``).
        if mediaPlayer.drawsWithoutGPU {
            rows.append(measureRow(translated("Ohne Grafikbeschleunigung"), conspicuous: true))
        }

        guard measure else { return rows }
        // Where in the movie playback is, so a screenshot names a position.
        if mediaPlayer.duration > 1 {
            rows.append(measureRow("\(translated("Stelle")) \(PlayTime.text(mediaPlayer.position))"
                                    + " / \(PlayTime.text(mediaPlayer.duration))", conspicuous: false))
        }
        guard let w else { return rows }
        rows.append(BadgeRow(art: .line))
        let should = video?.frameRate
        rows.append(measureRow("\(translated("Demuxer")) \(TechDetails.bitrate(w.demuxer) ?? "—")",
                                conspicuous: false))
        // Two frames apart: below that it is the edge of the measuring window and
        // not an event.
        let showsLags = if let actualValue = w.showsProSecond, let should { actualValue < should - 2 } else { false }
        rows.append(measureRow("\(translated("Zeigt Ø")) \(figure(w.showsProSecond)) fps"
                                + " · \(translated("Gezeigt")) \(w.raw.shown)", conspicuous: showsLags))
        // Below 97 % there is no measurement noise anymore.
        rows.append(measureRow("\(translated("Lauf")) \(share(w.runShare))",
                                conspicuous: (w.runShare ?? 1) < 0.97))
        let decoderLags = if let actualValue = w.decodedProSecond, let should { actualValue < should - 2 } else { false }
        rows.append(measureRow("\(translated("Dekodiert Ø")) \(figure(w.decodedProSecond)) fps",
                                conspicuous: decoderLags))
        rows.append(measureRow("\(translated("Beschädigt")) \(w.raw.beschaedigt)"
                                + " · \(translated("Sprünge")) \(w.raw.jumps)",
                                conspicuous: w.raw.beschaedigt > 0 || w.raw.jumps > 0))
        return rows
    }

    /// A viewer-facing entry: name quiet, value bright. If it stands out, it is
    /// entirely in `warning`, like `measureRow`. Core line.
    private func detail(_ name: String, _ value: String, conspicuous: Bool = false) -> BadgeRow {
        if conspicuous {
            var z = measureRow("\(name) \(value)", conspicuous: true)
            z.kern = true
            return z
        }
        return BadgeRow(markup: tint(name, Theme.fontQuiet) + tint(" \(value)", Theme.font),
                           kern: true)
    }

    /// An extra line: quiet, or warning in orange.
    private func measureRow(_ text: String, conspicuous: Bool) -> BadgeRow {
        BadgeRow(markup: tint(text, conspicuous ? Theme.warning : Theme.fontQuiet))
    }

    /// Size divided by runtime. `nil` while one of them is missing.
    private func bytesJeSecond() -> Double? {
        guard let bytes = runningPlan?.source?.size, bytes > 0,
              mediaPlayer.duration > 1 else { return nil }
        return Double(bytes) / mediaPlayer.duration
    }

    /// A piece of text in a given colour.
    private func tint(_ text: String, _ color: String) -> String {
        "<span foreground=\"\(color)\">\(protection(text))</span>"
    }

    /// Pango reads `&`, `<` and `>` as markup. A file name with an ampersand
    /// would otherwise break the whole badge.
    private func protection(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func comma(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    private func figure(_ w: Double?) -> String {
        guard let w else { return "—" }
        return comma(w)
    }

    private func share(_ w: Double?) -> String {
        guard let w else { return "—" }
        return "\(Int((w * 100).rounded())) %"
    }
}

// MARK: - Sliding

/// A run of the top edge. Per widget only the latest counts: a new one
/// replaces the old, starting from the **current** state, as in `blenden`.
private final class GlideRun {
    let from: Double, to: Double, duration: Double
    let curve: IdLine
    let number: Int
    let key: UnsafeMutableRawPointer
    let beginning = Date()
    init(from: Double, to: Double, duration: Double, curve: IdLine, number: Int,
         key: UnsafeMutableRawPointer) {
        self.from = from; self.to = to; self.duration = duration
        self.curve = curve; self.number = number; self.key = key
    }
}

nonisolated(unsafe) private var glideState: [UnsafeMutableRawPointer: Int] = [:]
nonisolated(unsafe) private var glideCounter = 0

nonisolated(unsafe) private let glideTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { widget, _, data in
    guard let widget, let data else { return 0 }
    let l = Unmanaged<GlideRun>.fromOpaque(data).takeUnretainedValue()
    let key = UnsafeMutableRawPointer(widget)
    guard glideState[key] == l.number else { return 0 }
    let t = min(Date().timeIntervalSince(l.beginning) / l.duration, 1)
    let value = l.from + (l.to - l.from) * l.curve.value(t)
    gtk_widget_set_margin_top(widget, Int32(value.rounded()))
    if t >= 1 {
        glideState[key] = nil
        return 0
    }
    return 1
}

nonisolated(unsafe) private let glideShare: @convention(c) (gpointer?) -> Void = { data in
    guard let data else { return }
    // **Even if the run never reached its target.** If the badge closes with
    // the player mid-slide, GTK removes the tick callback without it ever seeing
    // `t >= 1`; the entry then stayed in `glideState` forever, one per closed
    // player.
    let run = Unmanaged<GlideRun>.fromOpaque(data)
    let l = run.takeUnretainedValue()
    if glideState[l.key] == l.number { glideState[l.key] = nil }
    run.release()
}

/// Moves the top edge at the window's frame rate. If the widget is not
/// mapped, the value applies immediately, since there would be no tick.
private func badgeGlide(_ widget: Widget, on target: Int32, duration: Double, curve: IdLine) {
    let key = UnsafeMutableRawPointer(widget)
    glideCounter += 1
    let number = glideCounter
    glideState[key] = number
    let from = gtk_widget_get_margin_top(widget)
    guard duration > 0, from != target, gtk_widget_get_mapped(widget) != 0 else {
        glideState[key] = nil
        gtk_widget_set_margin_top(widget, target)
        return
    }
    let run = GlideRun(from: Double(from), to: Double(target), duration: duration,
                         curve: curve, number: number, key: key)
    _ = gtk_widget_add_tick_callback(widget, glideTick,
                                     Unmanaged.passRetained(run).toOpaque(), glideShare)
}
