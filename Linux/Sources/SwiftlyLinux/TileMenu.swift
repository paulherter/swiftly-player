import CGtk
import Foundation
import JellyfinKit

/// What a tile's menu needs to know: the title, whether it is landscape, the
/// image it already shows, and whether it is in "Weiterschauen".
struct TileMenuDetail {
    let item: Item
    var landscape = false
    /// Same URL and edge as the tile: the image cache answers immediately, so the
    /// preview never opens empty.
    var image: URL?
    var border: Int?
    var continueWatching = false
    /// "Zur Übersicht" only for "Weiterschauen", where a click starts playback.
    var overview: (() -> Void)?
    /// **In the player: watch state only.** No "Abspielen" or "Gemeinsam
    /// schauen": the row itself already starts the episode, and both would have to
    /// replace the running player. No "Laden": the sheet would open under the
    /// player. Same rule as on Apple (`TileMenu.inPlayer`).
    var inPlayer = false
    /// After a watch-state change, with the freshly fetched title, so the page
    /// updates (Apple `nachher`).
    var afterwards: ((Item) -> Void)?
}

/// **Right-click on any movie, show and episode tile: a menu with preview**,
/// the pointer equivalent of long-press on iPhone
/// (`Sources/Shared/TileMenu.swift`). On top the preview in the tile's shape
/// (2:3, 16:9 in "Weiterschauen"), only larger, below it: Play or Resume, in
/// "Weiterschauen" "Zur Übersicht", watched and unwatched (both always, as on
/// iPhone: an episode merely skipped through counts as started), Download,
/// Watch together, and in "Weiterschauen" "Aus Weiterschauen entfernen".
///
/// **Right-click instead of long-press** (input method): the mouse has its own
/// button for it; the menu key and Shift+F10 cover the keyboard.
extension App {

    static func tileMenuCarries(_ item: Item) -> Bool {
        ["Movie", "Series", "Episode"].contains(item.type ?? "")
    }

    func tileMenuCreate(_ button: Widget!, _ detail: TileMenuDetail) {
        tileMenuCreate(button) { detail }
    }

    /// **With a value that is only resolved on opening**, for rows whose title
    /// updates after the player (``episodeRow``). Right-click, long-press, menu
    /// key.
    func tileMenuCreate(_ button: Widget!, detail: @escaping () -> TileMenuDetail) {
        guard Self.tileMenuCarries(detail().item) else { return }
        rightClick(button) { [weak self] in self?.tileMenuShow(button, detail()) }
        longPress(button) { [weak self] in self?.tileMenuShow(button, detail()) }
        let watcher = gtk_event_controller_key_new()
        let job = Unmanaged.passRetained(WorkItem { [weak self] in
            self?.tileMenuShow(button, detail())
        }).toOpaque()
        g_signal_connect_data(UnsafeMutableRawPointer(watcher), "key-pressed",
                              unsafeBitCast(menuKey, to: GCallback.self),
                              job, jobSharePublic, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(button, watcher)
    }

    func tileMenuShow(_ button: Widget!, _ detail: TileMenuDetail) {
        let item = detail.item
        let width = detail.landscape ? 320 : 220
        let height = detail.landscape ? width * 9 / 16 : width * 3 / 2
        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(list, Int32(width), -1)
        let panel = panelOpen(an: button)
        gtk_widget_add_css_class(panel, "swiftly-kachelmenue")
        gtk_popover_set_child(asPanel(panel), Scaling.wrapped(list))

        // The preview: image without border, title and row below.
        let (wrapper, image) = framedImage(width: width, height: height, style: "swiftly-kachelvorschau")
        if let address = detail.image {
            imageLoad(image, url: address, key: ImageKey.of(address), immediate: true,
                      border: detail.border, fallbackSeries: item.seriesId != nil || item.type == "Series")
        } else {
            characterPut(wrapper, series: item.seriesId != nil || item.type == "Series")
        }
        append(list, wrapper)
        let text = stack(GTK_ORIENTATION_VERTICAL, spacing: 3)
        gtk_widget_add_css_class(text, "swiftly-kachelvorschautext")
        let title = label(item.seriesName ?? item.name, style: "swiftly-kachelvorschautitel")
        gtk_label_set_xalign(OpaquePointer(title), 0)
        gtk_label_set_ellipsize(OpaquePointer(title), PANGO_ELLIPSIZE_END)
        append(text, title)
        let row = Self.previewRow(item)
        if !row.isEmpty {
            let z = label(row, style: "swiftly-kachelvorschauzeile", wrap: true)
            gtk_label_set_xalign(OpaquePointer(z), 0)
            gtk_label_set_lines(OpaquePointer(z), 2)
            gtk_label_set_ellipsize(OpaquePointer(z), PANGO_ELLIPSIZE_END)
            append(text, z)
        }
        append(list, text)
        let line = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_add_css_class(line, "swiftly-trennlinie")
        append(list, line)

        func entryRecord(_ symbol: String, _ word: String, _ perform: @escaping () -> Void) {
            append(list, actionRow(symbol, word) {
                gtk_popover_popdown(asPanel(panel))
                perform()
            })
        }
        let series = item.type == "Series"
        let inPlayer = detail.inPlayer
        if !inPlayer {
            entryRecord("media-playback-start-symbolic",
                    !series && item.resumeFrom != nil ? translated("Fortsetzen") : translated("Abspielen")) {
                [weak self] in self?.tilePlay(item)
            }
        }
        if detail.continueWatching, let overview = detail.overview {
            entryRecord("dialog-information-symbolic", translated("Zur Übersicht"), overview)
        }
        let afterwards = detail.afterwards
        entryRecord("object-select-symbolic", translated("Als gesehen markieren")) { [weak self] in
            self?.tileWatched(item, an: true, afterwards: afterwards)
        }
        entryRecord("edit-undo-symbolic", translated("Als ungesehen markieren")) { [weak self] in
            self?.tileWatched(item, an: false, afterwards: afterwards)
        }
        if !series, !inPlayer, downloadButtonShow, downloads.entries(for: item.id) == nil {
            entryRecord("folder-download-symbolic", translated("Laden")) { [weak self] in
                self?.tileLoad(item, an: button)
            }
        }
        if !series, !inPlayer, gemeinsam.status.mayCreate {
            entryRecord("system-users-symbolic", translated("Gemeinsam schauen")) { [weak self] in
                self?.sharedCreateShow(item, an: button)
            }
        }
        if detail.continueWatching {
            entryRecord("list-remove-symbolic", translated("Aus Weiterschauen entfernen")) { [weak self] in
                self?.fromContinueWatchingTake(item)
            }
        }
        AppLog.writeOut("[Kachelmenü] \(item.id) · Vorschau \(width)×\(height) · Bild im Speicher: "
            + (detail.image.map { ImageCache.fetch(ImageKey.of($0) + (detail.border.map { "@\($0)" } ?? "")) != nil } == true ? "ja" : "nein"))
        gtk_popover_popup(asPanel(panel))
    }

    /// The row under the title: for an episode, abbreviation, name and runtime
    /// (iOS `Kachelvorschau.row`).
    static func previewRow(_ item: Item) -> String {
        if item.type == "Episode" {
            var parts: [String] = []
            if let abbreviation = item.episodeCode { parts.append(abbreviation) }
            parts.append(item.name)
            if let s = item.runtimeSeconds, s > 0 { parts.append(runtime(s)) }
            return parts.joined(separator: " · ")
        }
        return item.secondaryLine
    }

    /// Play: for a show, where the server left off (`stateInSeries`, like the main
    /// button of the show page).
    private func tilePlay(_ item: Item) {
        guard item.type == "Series" else { launch(item); return }
        guard let client else { return }
        Task.detached { [self] in
            let episode = await client.stateInSeries(item.id)
            onMainThread {
                guard let episode else {
                    self.tileMessage(translated("Danach kommt nichts mehr."))
                    return
                }
                self.launch(episode)
            }
        }
    }

    private func tileWatched(_ item: Item, an: Bool, afterwards: ((Item) -> Void)? = nil) {
        guard let client else { return }
        // The callback holds widgets and lives on GTK's thread; it crosses the
        // thread boundary only inside the box and is never called there.
        let afterwards = afterwards.map(TileAfter.init)
        Task.detached { [self] in
            do {
                try await client.setWatched(itemID: item.id, an: an)
                // With a page: refetch the title so that checkmark and bar update where the
                // menu opened.
                let freshValue: Item?
                if afterwards != nil { freshValue = try? await client.item(id: item.id) } else { freshValue = nil }
                onMainThread {
                    self.watchStateForget(item)
                    self.homeLoad()
                    if let freshValue { afterwards?.perform(freshValue) }
                }
            } catch {
                let text = readableError(error)
                onMainThread { self.tileMessage(text) }
            }
        }
    }

    /// **Remove from "Weiterschauen"**: set the position to zero
    /// (``JellyfinClient/pointBackSet(itemID:)``); watched state stays
    /// unchanged.
    private func fromContinueWatchingTake(_ item: Item) {
        guard let client else { return }
        Task.detached { [self] in
            do {
                try await client.pointBackSet(itemID: item.id)
                onMainThread {
                    self.watchStateForget(item)
                    self.homeLoad()
                }
            } catch {
                let text = readableError(error)
                onMainThread { self.tileMessage(text) }
            }
        }
    }

    /// Download: fetch the full item (the tile carries no source), then show the
    /// same confirmation as the detail page's download button, at the tile.
    private func tileLoad(_ item: Item, an button: Widget!) {
        guard let client else { return }
        let anchor = held(button)
        Task.detached { [self] in
            let full = (try? await client.item(id: item.id)) ?? item
            onMainThread { [self] in
                defer { letGo(anchor) }
                guard gtk_widget_get_root(anchor.widget) != nil else { return }
                self.loadPanelShow(full, an: anchor.widget)
            }
        }
    }

    /// What a tile menu could not do: shown in the banner on a detail page, else
    /// as a short notice in the window.
    private func tileMessage(_ text: String) {
        AppLog.writeOut("[Kachelmenü] \(text)")
        report(text)
    }
}

/// Carries a tile menu's callback across the thread boundary.
final class TileAfter: @unchecked Sendable {
    let perform: (Item) -> Void
    init(_ perform: @escaping (Item) -> Void) { self.perform = perform }
}

/// Menu key (0xFF67) or Shift+F10: the keyboard ways to a context menu.
nonisolated(unsafe) private let menuKey: @convention(c) (
    OpaquePointer?, UInt32, UInt32, GdkModifierType, gpointer?
) -> gboolean = { _, value, _, condition, data in
    guard let data else { return 0 }
    let shift = (condition.rawValue & GDK_SHIFT_MASK.rawValue) != 0
    guard value == 0xFF67 || (value == 0xFFC7 && shift) else { return 0 }
    Unmanaged<WorkItem>.fromOpaque(data).takeUnretainedValue().block()
    return 1
}
