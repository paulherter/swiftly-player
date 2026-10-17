import CGtk
import Foundation
import JellyfinKit

/// **The running state of a handover**, receiver or sender, between click
/// or stop and the stage being torn down.
final class HandoffRun {
    enum Role { case receiver, giver }

    let role: Role
    let reduced: Bool
    /// As on the Mac: a desktop carries the Mac's measurements.
    let metrics = HandoffCard.mac
    let beginning = g_get_monotonic_time()
    var titleID: String?

    /// The layer over everything, as an overlay on ``App/fensterdecke``.
    var stage: Widget!
    var reason: Widget!
    var black: Widget!
    var fixed: Widget!
    var card: Widget!
    var image: Widget!
    var rows: Widget!
    var line: Widget!
    var stripe: Widget!
    var tick: guint = 0
    /// The corner step currently attached to the card as a CSS class.
    var corner = -1
    var screen = (width: 0.0, height: 0.0)

    var from = HandoffCard.Status(x: 0, y: 0, width: 1)
    var idle = HandoffCard.Status(x: 0, y: 0, width: 1)
    var full = HandoffCard.Status(x: 0, y: 0, width: 1)
    /// When the (last) flight began; restarts after a resize.
    var transitionOut = HandoffCard.cardsStart

    // Receiver
    var ready: Double?
    var zoomOff: Double?
    var zoomFrom = HandoffCard.Status(x: 0, y: 0, width: 1)
    var zoomMomentum = HandoffCard.Status(x: 0, y: 0, width: 0)
    var lineOff: Double?
    var cancelled = false

    // Sender
    /// Aspect ratio of the outgoing picture (width over height).
    var pages = 16.0 / 9
    var bearing = HandoffCard.Direction.top
    var out = 0.0
    /// From here the background fades out to the page (the player is closed).
    var reasonOutOff: Double?

    init(role: Role, reduced: Bool, titleID: String?) {
        self.role = role
        self.reduced = reduced
        self.titleID = titleID
    }

    /// Seconds since the click (receiver) or the stop (sender).
    var now: Double { Double(g_get_monotonic_time() - beginning) / 1_000_000 }
}

/// **"Hier weiterschauen" as a card** (design B), the Linux and Windows
/// version of `Sources/Shared/HandoffStage.swift`.
///
/// **Receiver:** click on the badge. The page steps back, a card with the
/// episode image grows from the badge to the center, title and episode
/// below. It hovers until the player underneath has its first frame, then
/// zooms to the full picture.
///
/// **Sender:** the mirror image. The still frame shrinks to a card, hovers
/// briefly and flies out (up toward a larger device, down toward a smaller
/// one, ``Uebergabekarte/departurePostTop(von:nach:)``); then the player closes
/// under the stage.
///
/// All timings and springs come from the package (``HandoffCard``). Only
/// **position, size and opacity** move, at the window's frame rate
/// (`gtk_widget_add_tick_callback`); the corner follows the size in whole
/// steps as a class. The steps of the sequence hang on the clock
/// (``postDeadline(_:_:)``), not on the frame tick, which stops when the window
/// does not draw. With reduced motion it only cross-fades.
extension App {

    /// How this device is named in the handover hint; for the flight direction
    /// on the other end it counts as a desktop, like a Mac.
    static var handoffName: String { Platform.system }

    // MARK: Receiver

    /// **On click**, before the network has even been asked.
    func handoffStart(title: Item?) {
        handoffCleanUp()
        let run = HandoffRun(role: .receiver, reduced: motionReduced(),
                                 titleID: title?.id)
        guard handoffStageBuild(run) else { return }
        let (b, h) = run.screen
        run.full = HandoffCard.fullscreen(width: b, height: h)
        run.idle = HandoffCard.idleStatus(width: b, height: h, metrics: run.metrics)
        run.from = run.idle
        // From the badge, as wide as on the Mac (32).
        if !run.reduced, let cover = windowCover, let row = takeoverRow {
            var r = graphene_rect_t()
            if gtk_widget_compute_bounds(row, cover, &r) != 0, r.size.width > 0 {
                run.from = .init(x: Double(r.origin.x + r.size.width / 2),
                                 y: Double(r.origin.y + r.size.height / 2), width: 32)
            }
        }
        if let title {
            handoffRowsSet(run, title)
            if let url = handoffCardImage(title) {
                imageLoad(run.image, url: url, key: ImageKey.of(url),
                          immediate: true, border: 1280)
            }
        }
        handoff = run
        handoffTickStart(run)
        handoffTime(run, run.reduced ? "blendet auf (reduziert)" : "wächst aus dem Abzeichen")

        // The loading line only if the picture is still missing at 0.75 s.
        postDeadline(HandoffCard.loadingBarOut) { [weak self] in
            guard let self, self.handoff === run, run.zoomOff == nil, !run.reduced,
                  HandoffCard.loadLine(ready: run.ready) else { return }
            run.lineOff = run.now
            self.handoffTime(run, "Ladelinie")
        }
    }

    /// **The player is up** (invisible under the card). From here the card waits
    /// at most ``Uebergabekarte/hoechstensWarten`` for the first frame.
    func handoffPlayerComes(_ itemID: String) {
        guard let run = handoff, run.role == .receiver, !run.cancelled else { return }
        run.titleID = itemID
        handoffTime(run, "Player geöffnet")
        postDeadline(HandoffCard.atMostWait) { [weak self] in
            guard let self, self.handoff === run, run.zoomOff == nil, !run.cancelled else { return }
            self.handoffTime(run, "kein erstes Bild — Karte gibt trotzdem frei")
            self.handoffZoom(run, ready: run.now)
        }
    }

    /// **The first frame is up**: now the card zooms (at the earliest at
    /// ``Uebergabekarte/schweben``) and releases the picture.
    func handoffImagePresent(_ itemID: String) {
        guard let run = handoff, run.role == .receiver, !run.cancelled,
              run.zoomOff == nil, itemID == run.titleID else { return }
        handoffTime(run, "erstes Bild")
        handoffZoom(run, ready: run.now)
    }

    /// The player closed before the card released it.
    func handoffPlayerDistance(_ itemID: String) {
        guard let run = handoff, run.role == .receiver, run.zoomOff == nil,
              itemID == run.titleID else { return }
        handoffCancel("Player geschlossen")
    }

    /// **The handover failed** (stop rejected) or the player was closed while
    /// waiting: the stage fades out.
    func handoffCancel(_ reason: String) {
        guard let run = handoff, run.role == .receiver, !run.cancelled else { return }
        run.cancelled = true
        handoffTime(run, "abgebrochen: \(reason)")
        if run.tick != 0 { gtk_widget_remove_tick_callback(run.stage, run.tick); run.tick = 0 }
        crossfade(run.stage, on: 0, duration: HandoffCard.fade, curve: .easeInOut)
        postDeadline(HandoffCard.fade + 0.05) { [weak self] in
            guard let self, self.handoff === run else { return }
            self.handoffCleanUp()
        }
    }

    private func handoffZoom(_ run: HandoffRun, ready t: Double) {
        run.ready = t
        let z = run.reduced ? t : HandoffCard.zoomStart(ready: t)
        run.zoomOff = z
        let duration: Double
        if run.reduced {
            duration = HandoffCard.fadeOut + 0.05
        } else {
            // From position **and momentum** of the waiting card, no stop.
            run.zoomFrom = HandoffCard.wait(z, from: run.from, to: run.idle, since: run.transitionOut)
            run.zoomMomentum = HandoffCard.momentum(z, from: run.from, to: run.idle, since: run.transitionOut)
            duration = HandoffCard.end
        }
        handoffTime(run, "Zoom ab +\(Int(z * 1000)) ms")
        postDeadline(max(0, z + duration - run.now) + 0.02) { [weak self] in
            guard let self, self.handoff === run else { return }
            self.handoffTime(run, "fertig")
            self.handoffCleanUp()
        }
    }

    private func receiverImage(_ run: HandoffRun, _ t: Double) {
        let status: HandoffCard.Status
        if run.reduced {
            status = run.idle
            gtk_widget_set_opacity(run.reason, handoffLinear(t, 0, HandoffCard.fade))
            let an = handoffLinear(t, HandoffCard.cardsStart,
                                     HandoffCard.cardsStart + HandoffCard.fade)
            gtk_widget_set_opacity(run.card, an)
            gtk_widget_set_opacity(run.rows, an)
            if let z = run.zoomOff {
                gtk_widget_set_opacity(run.stage,
                                       1 - handoffLinear(t, z, z + HandoffCard.fadeOut))
            }
        } else {
            gtk_widget_set_opacity(run.reason, HandoffCard.pagesCoverage(t))
            if let z = run.zoomOff, t >= z {
                let u = t - z
                status = HandoffCard.zoom(u, from: run.zoomFrom, momentum: run.zoomMomentum,
                                           to: run.full)
                gtk_widget_set_opacity(run.card, 1)
                gtk_widget_set_opacity(run.black, handoffLinear(u, 0, HandoffCard.blackDuration))
                gtk_widget_set_opacity(run.stage, HandoffCard.stageCoverage(toZoom: u))
            } else {
                status = HandoffCard.wait(t, from: run.from, to: run.idle, since: run.transitionOut)
                gtk_widget_set_opacity(run.card, HandoffCard.cardsCoverage(t))
            }
            gtk_widget_set_opacity(run.rows, HandoffCard.rowsCoverage(t, zoomOff: run.zoomOff))
        }
        handoffCardSet(run, status, height: status.height)

        // The loading line: fades in, a 30 % bar sweeps through.
        if let since = run.lineOff {
            let coverage = handoffLinear(t, since, since + HandoffCard.loadingBarShow)
            gtk_widget_set_opacity(run.line, coverage)
            let b = run.idle.width, w = b * 0.3
            let share = ((t - since) / HandoffCard.loadingBarTick).truncatingRemainder(dividingBy: 1)
            gtk_fixed_move(asFixed(run.line), run.stripe, -w + share * (b + w), 0)
        }
    }

    // MARK: Sender

    /// **Playback moves to another device.** The position goes to the server
    /// immediately (the other end waits for it), the still frame leaves as a
    /// card, and only when it is out does the player close.
    ///
    /// **The card lies over everything**, including the controls: it is an
    /// overlay of the window deck, not part of the player. A nearly black still
    /// frame does not count; the episode image flies instead.
    func handoffHandIn(an target: String) {
        guard let title = runningTitle, handoff?.role != .giver else { return }
        handoffCleanUp()
        let run = HandoffRun(role: .giver, reduced: motionReduced(), titleID: title.id)
        handoffTime(run, "an \(target)\(run.reduced ? " (reduziert)" : "")")

        // **The position immediately**, not only on closing, which takes almost two
        // seconds: the other device waits at most one and a half for it. After that
        // this player reports nothing more, not even the pause that follows
        // (``runStateReported(running:)`` checks `reportTitle`).
        if playState.startReported, let client, let plan = runningPlan {
            let ticks = Int64(playState.position * 10_000_000)
            let account = userIdentifier
            playState.startReported = false
            reportTitle = nil
            Task.detached { [self] in
                await self.reportStop(client, title: title, plan: plan, ticks: ticks, account: account)
            }
        }
        tickEnd()
        mediaPlayer.halt()

        // The still frame: the texture the video area is currently showing.
        var stillImage: OpaquePointer?
        if let inputField = mediaPlayer.display, let p = gtk_picture_get_paintable(OpaquePointer(inputField)) {
            g_object_ref(UnsafeMutableRawPointer(p))
            stillImage = p
            if let bright = Self.brightness(p), bright < 0.04 {
                handoffTime(run, "Standbild schwarz (Helligkeit \(String(format: "%.3f", bright))) — Folgenbild")
                g_object_unref(UnsafeMutableRawPointer(p))
                stillImage = nil
            } else {
                handoffTime(run, "Standbild da")
            }
        }
        let episodeImage = stillImage == nil ? handoffCardImage(title) : nil
        guard stillImage != nil || episodeImage != nil, handoffStageBuild(run) else {
            if let stillImage { g_object_unref(UnsafeMutableRawPointer(stillImage)) }
            handoffTime(run, "weder Standbild noch Folgenbild — Player schließt wie sonst")
            playerClose()
            return
        }
        if let stillImage {
            gtk_picture_set_paintable(OpaquePointer(run.image), stillImage)
            let w = Double(gdk_texture_get_width(stillImage)), h = Double(gdk_texture_get_height(stillImage))
            if w > 0, h > 0 { run.pages = w / h }
            g_object_unref(UnsafeMutableRawPointer(stillImage))
        } else if let episodeImage {
            imageLoad(run.image, url: episodeImage, key: ImageKey.of(episodeImage),
                      immediate: true, border: 1280)
            handoffTime(run, "Folgenbild")
        }
        handoffRowsSet(run, title)

        // Where the video was: fitted into the picture area, according to the
        // picture itself.
        let (sb, sh) = run.screen
        var frameRect = (x: 0.0, y: 0.0, b: sb, h: sh)
        if let inputField = mediaPlayer.display, let cover = windowCover {
            var r = graphene_rect_t()
            if gtk_widget_compute_bounds(inputField, cover, &r) != 0, r.size.width > 1, r.size.height > 1 {
                frameRect = (Double(r.origin.x), Double(r.origin.y), Double(r.size.width), Double(r.size.height))
            }
        }
        let vb = min(frameRect.b, frameRect.h * run.pages)
        run.full = .init(x: frameRect.x + frameRect.b / 2, y: frameRect.y + frameRect.h / 2, width: vb)
        run.idle = HandoffCard.idleStatus(width: sb, height: sh, metrics: run.metrics)
        let top = HandoffCard.departurePostTop(from: Self.handoffName, to: target)
        run.bearing = top ? .top : .bottom
        if run.reduced {
            run.out = HandoffCard.fadeOut
        } else {
            run.out = HandoffCard.exitOut(full: run.full, card: run.idle, bearing: run.bearing)
            handoffTime(run, "fliegt nach \(top ? "oben" : "unten"), draußen nach \(Int(run.out * 1000)) ms")
        }
        // Opaque from the first frame: nothing of the player is visible anymore.
        gtk_widget_set_opacity(run.reason, 1)
        gtk_widget_set_opacity(run.black, 1)
        gtk_widget_set_opacity(run.card, 1)
        handoff = run
        handoffTickStart(run)
        handoffTime(run, "Bühne deckt den Player ab ihrem ersten Bild")

        // Card out: the player closes under the stage, then the background fades
        // out to the page.
        let closeDuration = 0.5
        postDeadline(run.out) { [weak self] in
            guard let self, self.handoff === run else { return }
            self.handoffTime(run, "Karte draußen — Player schließt unter der Bühne")
            if self.runningTitle?.id == title.id { self.playerClose() }
            run.reasonOutOff = run.now + closeDuration
        }
        postDeadline(run.out + closeDuration + HandoffCard.fade + 0.1) { [weak self] in
            guard let self, self.handoff === run else { return }
            self.handoffTime(run, "fertig")
            self.handoffCleanUp()
        }
    }

    private func giverImage(_ run: HandoffRun, _ t: Double) {
        let status: HandoffCard.Status
        if run.reduced {
            status = run.full
            let from = 1 - handoffLinear(t, 0, HandoffCard.fadeOut)
            gtk_widget_set_opacity(run.card, from)
            gtk_widget_set_opacity(run.black, from)
        } else {
            status = HandoffCard.exit(t, full: run.full, card: run.idle, bearing: run.bearing)
            // Mirror of the receiver: black goes when the card shrinks.
            gtk_widget_set_opacity(run.black, 1 - handoffLinear(
                t, HandoffCard.exitStart, HandoffCard.exitStart + HandoffCard.blackDuration))
            gtk_widget_set_opacity(run.rows, HandoffCard.exitRowsCoverage(t))
        }
        if let g = run.reasonOutOff {
            gtk_widget_set_opacity(run.reason, 1 - handoffLinear(t, g, g + HandoffCard.fade))
        }
        handoffCardSet(run, status, height: status.width / run.pages)
    }

    /// Mean brightness 0…1 over 16 × 16 points.
    private static func brightness(_ texture: OpaquePointer) -> Double? {
        let w = Int(gdk_texture_get_width(texture)), h = Int(gdk_texture_get_height(texture))
        guard w > 0, h > 0 else { return nil }
        var points = [UInt8](repeating: 0, count: w * h * 4)
        points.withUnsafeMutableBufferPointer {
            gdk_texture_download(texture, $0.baseAddress, gsize(w * 4))
        }
        // `gdk_texture_download` returns B, G, R, A.
        let n = 16
        var sum = 0.0
        for j in 0 ..< n {
            for i in 0 ..< n {
                let x = (2 * i + 1) * w / (2 * n), y = (2 * j + 1) * h / (2 * n)
                let o = (y * w + x) * 4
                sum += 0.0722 * Double(points[o]) + 0.7152 * Double(points[o + 1])
                    + 0.2126 * Double(points[o + 2])
            }
        }
        return sum / Double(n * n) / 255
    }

    // MARK: Stage

    /// Background, black and above it a `GtkFixed` with card and rows, as the
    /// topmost overlay of the window deck, without hit-testing or focus.
    private func handoffStageBuild(_ run: HandoffRun) -> Bool {
        guard let cover = windowCover else { return false }
        let b = Double(gtk_widget_get_width(cover)), h = Double(gtk_widget_get_height(cover))
        guard b > 1, h > 1 else { return false }
        run.screen = (b, h)

        let stage: Widget! = gtk_overlay_new()
        gtk_widget_set_can_target(stage, 0)
        gtk_widget_set_can_focus(stage, 0)
        let reason = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(reason, "swiftly-uebergabegrund")
        gtk_widget_set_opacity(reason, 0)
        gtk_overlay_set_child(OpaquePointer(stage), reason)
        let black = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(black, "swiftly-uebergabeschwarz")
        gtk_widget_set_opacity(black, 0)
        gtk_overlay_add_overlay(OpaquePointer(stage), black)
        // **A `GtkFixed` gives its children their minimum size**: the card is exactly
        // as large as the frame tick requests it, and sits on fractions of a point.
        // Whatever flies out of the window is clipped by it.
        let fixed: Widget! = gtk_fixed_new()
        gtk_widget_set_overflow(fixed, GTK_OVERFLOW_HIDDEN)
        gtk_overlay_add_overlay(OpaquePointer(stage), fixed)

        let card = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(card, "swiftly-uebergabekarte")
        gtk_widget_set_overflow(card, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_opacity(card, 0)
        let image: Widget! = gtk_picture_new()
        gtk_picture_set_can_shrink(OpaquePointer(image), 1)
        gtk_picture_set_content_fit(OpaquePointer(image), GTK_CONTENT_FIT_COVER)
        gtk_widget_set_hexpand(image, 1)
        gtk_widget_set_vexpand(image, 1)
        append(card, image)
        gtk_fixed_put(asFixed(fixed), card, 0, 0)

        // Title and episode, left-aligned at card width; the loading line on top.
        let rows = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(rows, Int32(run.metrics.width), -1)
        gtk_widget_set_opacity(rows, 0)
        let line: Widget! = gtk_fixed_new()
        gtk_widget_add_css_class(line, "swiftly-uebergabelinie")
        gtk_widget_set_overflow(line, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_size_request(line, Int32(run.metrics.width), 2)
        gtk_widget_set_opacity(line, 0)
        let stripe = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_add_css_class(stripe, "swiftly-uebergabebalken")
        gtk_widget_set_size_request(stripe, Int32((run.metrics.width * 0.3).rounded()), 2)
        gtk_fixed_put(asFixed(line), stripe, 0, 0)
        append(rows, line)
        gtk_fixed_put(asFixed(fixed), rows, 0, 0)

        gtk_overlay_add_overlay(OpaquePointer(cover), stage)

        run.stage = stage
        run.reason = reason
        run.black = black
        run.fixed = fixed
        run.card = card
        run.image = image
        run.rows = rows
        run.line = line
        run.stripe = stripe
        return true
    }

    /// "The Mentalist" and "Staffel 6 · Folge 7" (Apple `HandoffStyle.rows`).
    private func handoffRowsSet(_ run: HandoffRun, _ title: Item) {
        var top = title.name
        var under: String?
        if let series = title.seriesName, !series.isEmpty {
            top = series
            if let s = title.parentIndexNumber, let f = title.indexNumber {
                under = String(format: translated("Staffel %lld · Folge %lld"), s, f)
            } else {
                under = title.name
            }
        }
        let text = stack(GTK_ORIENTATION_VERTICAL, spacing: Int32((run.metrics.spacing * 0.25).rounded()))
        gtk_widget_set_margin_top(text, Int32((run.metrics.spacing * 0.35).rounded()))
        let pairs: [(String?, String)] = [(top, "swiftly-uebergabetitel"), (under, "swiftly-uebergabeunter")]
        for (word, style) in pairs {
            guard let word else { continue }
            let l = label(word, style: style)
            gtk_label_set_xalign(OpaquePointer(l), 0)
            gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(OpaquePointer(l), 1)
            append(text, l)
        }
        append(run.rows, text)
    }

    /// **The card image**: for episodes the episode's image (it shows *where*
    /// one is), otherwise the title's landscape image (Apple
    /// `TakeoverModel.cardImageURL`).
    func handoffCardImage(_ title: Item) -> URL? {
        guard let addresses else { return nil }
        if title.seriesId != nil, let mark = title.imageTags?["Primary"] {
            return addresses.construct(itemID: title.id, mark: mark, mass: .atMostWide(1280))
        }
        return ImageSelection.landscape(title, addresses: addresses, width: 1280)?.url
    }

    /// Position and size of the card, the rows below, the corner as a step.
    private func handoffCardSet(_ run: HandoffRun, _ l: HandoffCard.Status, height: Double) {
        let w = max(1, l.width.rounded()), h = max(1, height.rounded())
        gtk_widget_set_size_request(run.card, Int32(w), Int32(h))
        gtk_fixed_move(asFixed(run.fixed), run.card, l.x - w / 2, l.y - h / 2)
        gtk_fixed_move(asFixed(run.fixed), run.rows, l.x - run.metrics.width / 2,
                       HandoffCard.rowsTop(l, metrics: run.metrics))
        let rung = min(max(Int(HandoffCard.corner(l, metrics: run.metrics, full: run.full).rounded()), 0), 12)
        if rung != run.corner {
            if run.corner >= 0 { gtk_widget_remove_css_class(run.card, "swiftly-uebergabeecke-\(run.corner)") }
            gtk_widget_add_css_class(run.card, "swiftly-uebergabeecke-\(rung)")
            run.corner = rung
        }
    }

    private func handoffTickStart(_ run: HandoffRun) {
        _ = handoffStep()
        run.tick = gtk_widget_add_tick_callback(run.stage, handoffTick,
                                                 Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// One frame of the handover, at the window's frame rate.
    fileprivate func handoffStep() -> Bool {
        guard let run = handoff, !run.cancelled, let cover = windowCover else { return false }
        let t = run.now
        // **The window changes size** (fullscreen on or off): the stage follows by
        // itself, and the card flies from where it is to the new resting position
        // (Apple `newAlign`).
        let b = Double(gtk_widget_get_width(cover)), h = Double(gtk_widget_get_height(cover))
        if b > 1, h > 1, b != run.screen.width || h != run.screen.height {
            run.screen = (b, h)
            if run.role == .receiver {
                let oldIdle = run.idle
                run.full = HandoffCard.fullscreen(width: b, height: h)
                run.idle = HandoffCard.idleStatus(width: b, height: h, metrics: run.metrics)
                if !run.reduced, run.zoomOff == nil {
                    run.from = HandoffCard.transition(t, from: run.from, to: oldIdle, since: run.transitionOut)
                    run.transitionOut = t
                }
                handoffTime(run, "Größe \(Int(b))×\(Int(h))")
            }
        }
        switch run.role {
        case .receiver: receiverImage(run, t)
        case .giver: giverImage(run, t)
        }
        return true
    }

    func handoffCleanUp() {
        guard let run = handoff else { return }
        handoff = nil
        if run.tick != 0 { gtk_widget_remove_tick_callback(run.stage, run.tick); run.tick = 0 }
        if let cover = windowCover, let stage = run.stage {
            gtk_overlay_remove_overlay(OpaquePointer(cover), stage)
        }
    }

    private func handoffTime(_ run: HandoffRun, _ was: String) {
        let wer = run.role == .receiver ? "Karte" : "Abgang"
        AppLog.writeOut("[Uebergabe] \(wer) +\(Int(run.now * 1000)) ms \(was)")
    }
}

private func handoffLinear(_ t: Double, _ a: Double, _ b: Double) -> Double {
    min(max((t - a) / (b - a), 0), 1)
}

nonisolated(unsafe) private let handoffTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, data in
    guard let data else { return 0 }
    let app = Unmanaged<App>.fromOpaque(data).takeUnretainedValue()
    let proceed = app.handoffStep()
    if !proceed, let run = app.handoff { run.tick = 0 }
    return proceed ? 1 : 0
}
