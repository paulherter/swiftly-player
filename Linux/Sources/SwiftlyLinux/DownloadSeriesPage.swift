import CGtk
import Foundation
import JellyfinKit

// MARK: - State the download pages keep across a rebuild

/// **State of the download list and of a downloaded series' page.**
///
/// Both lists are rebuilt on every change (``App/downloadsPageFill()``).
/// Whatever must survive a rebuild (the per-item estimator, whether the
/// selection circle is sliding in or out, what is ticked on the series page)
/// therefore lives here rather than in the rows.
///
/// Touched only on GTK's main thread, hence `@unchecked Sendable`.
final class DownloadDisplay: @unchecked Sendable {
    static let shared = DownloadDisplay()

    /// How the selection circle looks on the next rebuild.
    enum CircleTravel { case stands, inward, out }

    // Progress
    var estimator: [String: ProgressEstimator] = [:]
    var reported: [String: Int64] = [:]

    // The list
    var listsCharacter = ""
    var listsTravel: CircleTravel = .stands

    // The page of a downloaded series
    var series: String?
    var title = ""
    var list: Widget?
    var detail: Widget?
    var play: Widget?
    var remove: Widget?
    var editButton: Widget?
    var backdrop: Backdrop?
    var edit = false
    var selected: Set<String> = []
    var seriesTravel: CircleTravel = .stands
    var seriesCharacter = ""
}

// MARK: - The bar

/// **Progress with rounded ends**, like `MacDownloadRow`: a capsule in
/// 30 % white with the accent capsule inside, 3 high.
///
/// A `GtkProgressBar` is a standard control and, without its own style rule,
/// drew in the system theme (square, theme colour). Drawn like ``Kreiszeichen``.
final class LoadingBar: @unchecked Sendable {
    fileprivate var lives = true
    fileprivate var share: Double
    let display: Widget

    init(share: Double) {
        self.share = share
        let inputField: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(inputField, "swiftly-blank")
        gtk_drawing_area_set_content_height(asCharacter(inputField), 3)
        gtk_widget_set_hexpand(inputField, 1)
        display = inputField!
        gtk_drawing_area_set_draw_func(asCharacter(inputField), barDraw,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        // The drawing area holds the bar, not the other way round (like ``Backdrop``).
        signal(inputField, "destroy") { self.lives = false }
    }

    func setDown(_ new: Double) {
        guard lives, abs(new - share) > 0.0001 else { return }
        share = new
        gtk_widget_queue_draw(display)
    }
}

private func capsule(_ cr: OpaquePointer, _ x: Double, _ width: Double, _ height: Double) {
    let r = height / 2
    cairo_new_path(cr)
    cairo_arc(cr, x + width - r, r, r, -Double.pi / 2, Double.pi / 2)
    cairo_arc(cr, x + r, r, r, Double.pi / 2, 3 * Double.pi / 2)
    cairo_close_path(cr)
}

nonisolated(unsafe) private let barDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    let b = Unmanaged<LoadingBar>.fromOpaque(data).takeUnretainedValue()
    guard b.lives, width > 0, height > 0 else { return }
    let w = Double(width), h = Double(height)
    capsule(cr, 0, w, h)
    cairo_set_source_rgba(cr, Theme.whiteRGB.0, Theme.whiteRGB.1, Theme.whiteRGB.2, 0.3)
    cairo_fill_preserve(cr)
    cairo_clip(cr)
    let full = w * min(max(b.share, 0), 1)
    guard full > 0 else { return }
    capsule(cr, 0, max(full, h), h)
    cairo_set_source_rgba(cr, Theme.accentRGB.0, Theme.accentRGB.1, Theme.accentRGB.2, 1)
    cairo_fill(cr)
}

// MARK: - Counting on between reports

/// **While downloading, the row keeps counting per frame.**
///
/// The download manager reports at most once per second; in between,
/// `ProgressEstimator` from the package extrapolates at the pace of the
/// last few seconds. Number and bar read the **same** value. The tick is
/// attached to the subtitle and goes away with it; when paused it is never
/// installed, so the number is shown immediately.
private final class Counter {
    let id: String
    let bytes: Int64
    let estimated: Bool
    let row: Widget
    let stripe: LoadingBar?
    var recent = Date.distantPast

    init(id: String, bytes: Int64, estimated: Bool, row: Widget, stripe: LoadingBar?) {
        self.id = id; self.bytes = bytes; self.estimated = estimated
        self.row = row; self.stripe = stripe
    }
}

nonisolated(unsafe) private let countTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, data in
    guard let data else { return 0 }
    let z = Unmanaged<Counter>.fromOpaque(data).takeUnretainedValue()
    let now = Date()
    // Thirty frames per second are enough for a number, like
    // `TimelineView(.animation(minimumInterval: 1/30))` on the Mac.
    guard now.timeIntervalSince(z.recent) >= 1.0 / 30 else { return 1 }
    z.recent = now
    let a = DownloadDisplay.shared
    guard var s = a.estimator[z.id] else { return 1 }
    let loaded = s.value(um: now)
    a.estimator[z.id] = s
    gtk_label_set_text(OpaquePointer(z.row), downloadLoadText(loaded, from: z.bytes, estimated: z.estimated))
    // An estimate never reaches completely full before the end (`DownloadItem.share`).
    if z.bytes > 0 { z.stripe?.setDown(min(Double(loaded) / Double(z.bytes), z.estimated ? 0.99 : 1)) }
    return 1
}

nonisolated(unsafe) private let counterResolve: @convention(c) (gpointer?) -> Void = { data in
    guard let data else { return }
    Unmanaged<Counter>.fromOpaque(data).release()
}

/// "0,84 von 2,31 GB": **fixed unit, fixed decimals.** `size` switched
/// mid-download from "845 MB" to "1 GB" and "1,01 GB", so the row changed
/// width at every step. The rule is `DownloadRules.progress` in the
/// package.
///
/// `estimated`: a transcoded file only has a computed size, so "≈" is shown
/// until the end.
func downloadLoadText(_ loaded: Int64, from bytes: Int64, estimated: Bool = false) -> String {
    guard bytes > 0 else { return DownloadRules.size(loaded) }
    let f = DownloadRules.progress(loaded: loaded, from: bytes)
    return String(format: translated("%@ von %@"), f.loaded, (estimated ? "≈ " : "") + f.total)
}

/// Attaches the counting to the subtitle of a running row.
func downloadCount(_ id: String, bytes: Int64, estimated: Bool = false,
                     row: Widget!, stripe: LoadingBar?) {
    let z = Counter(id: id, bytes: bytes, estimated: estimated, row: row, stripe: stripe)
    _ = gtk_widget_add_tick_callback(row, countTick,
                                     Unmanaged.passRetained(z).toOpaque(), counterResolve)
}

// MARK: - The Delete key

private final class KeysJob {
    let block: (UInt32) -> Bool
    init(_ block: @escaping (UInt32) -> Bool) { self.block = block }
}

nonisolated(unsafe) private let keyPage: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UInt32, GdkModifierType, gpointer?
) -> gboolean = { _, value, _, _, data in
    guard let data else { return 0 }
    return Unmanaged<KeysJob>.fromOpaque(data).takeUnretainedValue().block(value) ? 1 : 0
}

nonisolated(unsafe) private let keysJobResolve: @convention(c) (
    gpointer?, UnsafeMutablePointer<_GClosure>?
) -> Void = { data, _ in
    guard let data else { return }
    Unmanaged<KeysJob>.fromOpaque(data).release()
}

// MARK: - A downloaded series

/// **A downloaded series as its own page**, the GTK version of
/// `DownloadSeriesOverviewPage` (`Sources/macOS/MacDownloads.swift`).
///
/// Top: large image, name with episode count and size, a play button;
/// below, the episodes by season. The series row of the download list used
/// to expand in place (a plain list under the name, no image, no play
/// button); that variant was dropped.
///
/// **Everything from disk.** The user may be offline: the image is the saved
/// header image of the series, else the landscape image of the next episode
/// or the poster, and only then a server URL. The play button plays the file
/// (`downloadPlay`), not the title from the server.
///
/// **Removing works via right click on an episode or via Edit** (selection
/// circles, then the trash button or the Delete key). Swipe gestures do not
/// exist with a pointer.
///
/// **The page stack holds a marker**, not a server title: the stack holds
/// `Item`, and the marker carries the series ID with a prefix so no page
/// mistakes it for the series itself (see `postPlayerRefresh`, which
/// compares the series ID).
extension App {

    static let downloadSeriesPreSentence = "downloadserie:"
    static let downloadSeriesArt = "Downloadserie"

    /// Opens the page of a downloaded series on the downloads stack.
    func downloadSeriesOpen(_ seriesIdentifier: String, title: String) {
        let mark = Item(id: Self.downloadSeriesPreSentence + seriesIdentifier, name: title,
                         type: Self.downloadSeriesArt)
        pagesStack[section, default: []].append(mark)
        downloadSeriesShow(mark, push: .deeper)
    }

    /// Builds the page for the marker, on opening and on returning to the
    /// section.
    func downloadSeriesShow(_ mark: Item, push: Push) {
        let sid = String(mark.id.dropFirst(Self.downloadSeriesPreSentence.count))
        let a = DownloadDisplay.shared
        if a.series != sid { a.edit = false; a.selected = [] }
        a.series = sid
        a.title = mark.name ?? ""
        a.seriesCharacter = ""
        a.seriesTravel = .stands

        let disc = nextDisc()
        let page = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        let scroller = pagesScroller()
        gtk_scrolled_window_set_child(OpaquePointer(scroller), page)

        let over: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(over), scroller)
        // Same header as every detail page: back arrow, and the name fades in once
        // the large one below scrolls away.
        gtk_overlay_add_overlay(OpaquePointer(over), detailHeaderBuild(mark))
        append(detailWrapper, over)

        // Header zone: backdrop on the right, block on the left, like ``heldenkopf``.
        let header: Widget! = gtk_overlay_new()
        gtk_widget_set_hexpand(header, 1)
        let backdrop = Backdrop()
        gtk_overlay_set_child(OpaquePointer(header), backdrop.display)
        gtk_overlay_add_overlay(OpaquePointer(header), downloadSeriesBlock(a.title))
        append(page, header)
        a.backdrop = backdrop
        signal(backdrop.display, "destroy") {
            if a.backdrop === backdrop { a.backdrop = nil }
        }

        // The episodes by season, reading width 900 like the download list.
        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_margin_start(list, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(list, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_bottom(list, 40)
        append(page, list)
        cap(list, in: scroller, on: 900)
        a.list = list
        signal(list, "destroy") {
            if a.list == list { a.list = nil; a.detail = nil; a.play = nil
                                  a.remove = nil; a.editButton = nil }
        }

        // Fade the name in at the top, over the same distance as on the detail
        // page: from 98 − 24 = 74, across its 42 pt height.
        let verticalRight = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))!
        signalRaw(UnsafeMutableRawPointer(verticalRight), "value-changed") { [weak self] in
            guard let self, let name = self.detailHeaderTitle else { return }
            let strength = min(max((gtk_adjustment_get_value(verticalRight) - 74) / 42, 0), 1)
            gtk_widget_set_opacity(name, strength)
            if let bar = self.detailHeaderBar { gtk_widget_set_opacity(bar, strength) }
            if let history = self.detailHeaderHistory { gtk_widget_set_opacity(history, 1 - strength) }
        }

        // **The Delete key discards the selection**, the usual way on a desktop.
        // Backspace counts too, since it is the key labelled "delete" on a Mac.
        let watcher = gtk_event_controller_key_new()
        gtk_event_controller_set_propagation_phase(watcher, GTK_PHASE_CAPTURE)
        let job = KeysJob { [weak self] value in
            guard let self, value == 0xFFFF || value == 0xFF9F || value == 0xFF08,
                  a.edit, !a.selected.isEmpty else { return false }
            self.downloadSeriesSelectedRemove()
            return true
        }
        g_signal_connect_data(UnsafeMutableRawPointer(watcher), "key-pressed",
                              unsafeBitCast(keyPage, to: GCallback.self),
                              Unmanaged.passRetained(job).toOpaque(),
                              keysJobResolve, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(over, watcher)

        downloadSeriesUpdate(force: true)
        downloadHeaderImageSet(sid)
        shove(toward: disc, bearing: push)
        downloadHeaderImageCatchUp(sid)
    }

    /// Name and info, buttons below, at the position where the detail page
    /// puts them.
    private func downloadSeriesBlock(_ title: String) -> Widget! {
        let a = DownloadDisplay.shared
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_halign(block, GTK_ALIGN_START)
        gtk_widget_set_valign(block, GTK_ALIGN_START)
        gtk_widget_set_margin_start(block, Int32(Theme.edgeSpacing))
        // Like ``heldenblock``: titleHeight + 98, minus the header bar.
        gtk_widget_set_margin_top(block, Int32(Theme.titleHeight + 98 - Theme.headerRowHeight))

        let name = label(title, style: "swiftly-heldtitel")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_widget_set_size_request(name, 640, 42)
        append(block, name)

        let detail = label("", style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(detail, "dim-label")
        gtk_label_set_xalign(OpaquePointer(detail), 0)
        gtk_widget_set_margin_top(detail, 12)
        append(block, detail)
        a.detail = detail

        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_widget_set_margin_top(rail, 22)
        gtk_widget_set_halign(rail, GTK_ALIGN_START)

        // **The next unwatched episode**, else from the start. The rule is
        // `DownloadRules.nextEpisode`, the label is `Item.seriesButton`
        // ("Abspielen S2 F6"), both in the package.
        let main = primaryButton(translated("Abspielen"), symbol: "media-playback-start-symbolic")
        gtk_widget_set_size_request(main, Int32(Theme.primaryButtonWidth),
                                    Int32(Theme.primaryButtonHeight))
        gtk_widget_set_halign(main, GTK_ALIGN_START)
        signal(main, "clicked") { [weak self] in
            guard let self, let n = DownloadRules.nextEpisode(from: self.downloadSeriesEpisodes())
            else { return }
            self.downloadPlay(n)
        }
        append(rail, main)
        a.play = main

        let edit = chip(translated("Bearbeiten"), symbol: "document-edit-symbolic",
                              active: a.edit)
        signal(edit, "clicked") { [weak self] in
            guard let self else { return }
            a.edit.toggle()
            a.selected = []
            self.downloadSeriesTravel(inward: a.edit)
        }
        append(rail, edit)
        a.editButton = edit

        let distance = chip(translated("Entfernen"), symbol: "user-trash-symbolic")
        gtk_widget_set_visible(distance, 0)
        signal(distance, "clicked") { [weak self] in self?.downloadSeriesSelectedRemove() }
        append(rail, distance)
        a.remove = distance

        append(block, rail)
        return block
    }

    /// The episodes of this series, by season and episode.
    func downloadSeriesEpisodes() -> [DownloadItem] {
        guard let sid = DownloadDisplay.shared.series else { return [] }
        return downloads.entries
            .filter { $0.seriesIdentifier == sid }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }

    /// **Rebuilt when something visible changed**, not on every progress report;
    /// the row counts on by itself.
    func downloadSeriesUpdate(force: Bool = false) {
        let a = DownloadDisplay.shared
        guard let list = a.list, let sid = a.series else { return }
        let episodes = downloadSeriesEpisodes()

        // **Last episode removed, page removed.** A series page without episodes
        // has nothing left to show; go back to the list, but only if it is the
        // page currently shown.
        if episodes.isEmpty {
            if section == .downloads,
               pagesStack[.downloads]?.last?.id == Self.downloadSeriesPreSentence + sid {
                onMainThread { [self] in self.back() }
            }
            return
        }

        let symbolText = downloadCharacter(episodes) + "|\(a.edit)|\(a.selected.sorted())|\(a.seriesTravel)"
        guard force || symbolText != a.seriesCharacter else { return }
        a.seriesCharacter = symbolText

        if let detail = a.detail {
            gtk_label_set_text(OpaquePointer(detail),
                               numberWord(episodes.count, one: translated("1 Folge"),
                                        many: translated("%lld Folgen")) + " · "
                               + DownloadRules.size(episodes.reduce(0) { $0 + $1.bytes }))
        }
        if let main = a.play {
            let next = DownloadRules.nextEpisode(from: episodes)
            primaryButtonLabel(main, Item.seriesButton(episode: next?.asItem, loads: false))
            gtk_widget_set_sensitive(main, next == nil ? 0 : 1)
        }
        if let k = a.editButton {
            if a.edit { gtk_widget_add_css_class(k, "swiftly-aktiv") }
            else { gtk_widget_remove_css_class(k, "swiftly-aktiv") }
        }
        if let distance = a.remove {
            gtk_widget_set_visible(distance, a.edit && !a.selected.isEmpty ? 1 : 0)
        }

        wipe(list)
        var rail: [Int?] = []
        var je: [Int?: [DownloadItem]] = [:]
        for p in episodes {
            if je[p.season] == nil { rail.append(p.season) }
            je[p.season, default: []].append(p)
        }
        for number in rail {
            let ownOnes = je[number] ?? []
            if let n = number {
                let category = label(String(format: translated("Staffel %lld"), n),
                                          style: "swiftly-gruppenrubrik")
                gtk_label_set_xalign(OpaquePointer(category), 0)
                gtk_widget_set_margin_top(category, 26)
                gtk_widget_set_margin_bottom(category, 10)
                append(list, category)
            }
            for (i, p) in ownOnes.enumerated() {
                append(list, downloadSeriesRow(p))
                if i < ownOnes.count - 1 { append(list, rowsLine()) }
            }
        }
    }

    /// An episode on the series page: same row as in the list, with the action
    /// that is "long press" on iPhone. Here it is right click, and the
    /// confirmation is a panel in place.
    private func downloadSeriesRow(_ p: DownloadItem) -> Widget! {
        let a = DownloadDisplay.shared
        let row = downloadRow(p, edit: a.edit,
                                  selected: a.selected.contains(p.id),
                                  travel: a.seriesTravel) { [weak self] in
            if a.selected.contains(p.id) { a.selected.remove(p.id) } else { a.selected.insert(p.id) }
            self?.downloadSeriesUpdate()
        }
        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        let panel = panelAn(row)
        gtk_popover_set_child(asPanel(panel), Scaling.wrapped(list))
        append(list, actionRow("user-trash-symbolic",
                                        translated("Download entfernen")) { [weak self] in
            gtk_popover_popdown(asPanel(panel))
            self?.downloadsRemove([p.id])
        })
        rightClick(row) { gtk_popover_popup(asPanel(panel)) }
        return row
    }

    private func downloadSeriesSelectedRemove() {
        let a = DownloadDisplay.shared
        let distance = Array(a.selected)
        a.selected = []
        a.edit = false
        downloadsRemove(distance)
        downloadSeriesTravel(inward: false)
    }

    /// Removes and rebuilds both lists, not from within the click, which runs
    /// inside a row that gets torn down in the process.
    func downloadsRemove(_ ids: [String]) {
        downloads.remove(ids)
        onMainThread { [self] in self.downloadsPageFill() }
    }

    /// The circle slides in or out (Mac `.move(edge: .leading)`, `sprung`,
    /// 0.22 s); afterwards it stays put.
    private func downloadSeriesTravel(inward: Bool) {
        let a = DownloadDisplay.shared
        a.seriesTravel = inward ? .inward : .out
        downloadSeriesUpdate(force: true)
        a.seriesTravel = .stands
        guard !inward, let list = a.list else { return }
        a.seriesTravel = .out
        runningCount(on: list, duration: 0.22, step: { _ in }, done: { [weak self] in
            a.seriesTravel = .stands
            self?.downloadSeriesUpdate(force: true)
        })
    }

    // MARK: The header image

    /// Required header image width in pixels: the backdrop takes 62 % of the
    /// width, and a 16:9 image needs at least the width that fills the height
    /// (same calculation as `DownloadSeriesOverviewPage.headerPixel` on the Mac).
    /// Multiplied by the scale factor for sharpness.
    func downloadHeaderPixel() -> Int {
        let width = Double(max(gtk_widget_get_width(stage), 1))
        let divider = Scaling.devicesPoints(window)
        let points = max(width * 0.62, Double(Theme.heroHeightValue) * 1.62 * 16 / 9)
        return Int((points * divider).rounded(.up))
    }

    /// **Header image and poster are saved with the first download of a series**
    /// (`SeriesView.loadImages` on the Mac): the header image at window
    /// resolution, the poster 600 high instead of a tile's 300.
    func downloadSeriesImageWithGive(_ series: Item) {
        guard let client, let addresses, !userIdentifier.isEmpty else { return }
        let account = userIdentifier
        let pixel = downloadHeaderPixel()
        let poster = ImageSelection.portrait(series, addresses: addresses, maxHeight: 600)
        let management = downloads
        Task.detached {
            let pair = await client.headerImagePair(for: series, addresses: addresses, large: pixel)
            onMainThread {
                management.seriesImageSafe(series: series.id, account: account,
                                               header: pair?.large, poster: poster)
            }
        }
    }

    /// The image from disk, else from the server. Order as on the Mac: header
    /// image, landscape image of the next episode, poster, server URL.
    private func downloadHeaderImageSet(_ sid: String, caughtUp: URL? = nil) {
        let episodes = downloadSeriesEpisodes()
        guard let p = DownloadRules.nextEpisode(from: episodes) ?? episodes.first,
              let backdrop = DownloadDisplay.shared.backdrop else { return }
        let url = caughtUp
            ?? downloads.headerImage(series: sid, account: p.account)
            ?? downloads.image(for: p)
            ?? downloads.image(for: p, asGroup: true)
            ?? addresses?.construct(itemID: p.seriesIdentifier ?? p.id, mass: .atMostHigh(300))
        guard let url else { return }
        Task.detached {
            let data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                data = await ImageStorage.shared.load(url, key: ImageKey.of(url))
            }
            guard let data else { return }
            onMainThread { backdrop.setDown(data) }
        }
    }

    /// **Older downloads have no large header image.** With a network it is
    /// fetched once here. Offline the request fails silently and the image from
    /// disk stays.
    private func downloadHeaderImageCatchUp(_ sid: String) {
        guard let client, let addresses, let p = downloadSeriesEpisodes().first,
              downloads.headerImage(series: sid, account: p.account) == nil else { return }
        let pixel = downloadHeaderPixel()
        let management = downloads
        Task.detached { [self] in
            guard let series = try? await client.item(id: sid),
                  let pair = await client.headerImagePair(for: series, addresses: addresses,
                                                       large: pixel),
                  let present = await management.headerImageCatchUp(series: sid, account: p.account,
                                                              from: pair.large)
            else { return }
            onMainThread {
                guard DownloadDisplay.shared.series == sid else { return }
                self.downloadHeaderImageSet(sid, caughtUp: present)
            }
        }
    }
}
