import CGtk
import Foundation
import JellyfinKit

/// **The downloads page on Linux and Windows.**
///
/// Same behavior as on the Mac: same header with the storage line, the same
/// two sections ("Laedt gerade" and what is stored here), and the same edit
/// mode with checkmarks and a remove button that only appears once something
/// is selected.
///
/// Editing is ported, not replaced. A per-row button would be less code but
/// a second way to operate the same thing, with no reason in input type,
/// distance or window size to justify it.
///
/// The rules (which item downloads next, what is expendable, how items are
/// grouped) live in `DownloadRules` in the package, not here.
extension App {

    // MARK: Layout

    func downloadsPageBuild() -> Widget! {
        let turnPages: Widget! = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(turnPages),
                                       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_vexpand(turnPages, 1)

        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        // Same metrics as every other page: 52 top, 24 sides.
        gtk_widget_set_margin_start(block, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(block, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_top(block, Int32(Theme.contentTop))
        gtk_widget_set_margin_bottom(block, 40)

        // Header: title on the left, buttons on the right.
        let header = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        let titleBlock = stack(GTK_ORIENTATION_VERTICAL, spacing: 4)
        gtk_widget_set_hexpand(titleBlock, 1)
        // **`swiftly-titel-gross`, with hyphens.** Without them the class does not
        // exist and the heading rendered as body text.
        let title = label(translated("Downloads"), style: "swiftly-titel-gross")
        gtk_label_set_xalign(OpaquePointer(title), 0)
        append(titleBlock, title)
        // **No storage line under the title anymore**: the header was the only one
        // with two lines. The field stays so ``downloadsPageFill`` can keep
        // writing into it; it is just not in the page.
        downloadAllocation = label("", style: "swiftly-zweitzeile")
        append(header, titleBlock)

        downloadRemove = chip(translated("Entfernen"), symbol: "user-trash-symbolic")
        gtk_widget_set_valign(downloadRemove, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(downloadRemove, 0)
        signal(downloadRemove, "clicked") { [weak self] in
            guard let self else { return }
            let distance = Array(self.downloadSelected)
            self.downloadSelected = []
            self.downloadsRemove(distance)
            self.downloadEditPut()
        }
        append(header, downloadRemove)

        downloadEditButton = chip(translated("Bearbeiten"), symbol: "document-edit-symbolic")
        gtk_widget_set_valign(downloadEditButton, GTK_ALIGN_CENTER)
        signal(downloadEditButton, "clicked") { [weak self] in
            self?.downloadEditPut()
        }
        append(header, downloadEditButton)
        append(block, header)

        list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_margin_top(list, 18)
        append(block, list)

        // **The iPhone wording, verbatim**: the factual second sentence is gone there.
        downloadEmpty = emptyState("folder-download-symbolic",
                                   translated("Noch nichts geladen"),
                                   translated("Lad was runter, bevor der Zug ins Funkloch fährt."))
        gtk_widget_set_visible(downloadEmpty, 0)
        append(block, downloadEmpty)

        gtk_scrolled_window_set_child(OpaquePointer(turnPages), block)
        // **Reading width, not window width** (`maxWidth: 900` on the Mac): a row of
        // image, title and ring has nothing to say in the middle of 1600 pt.
        cap(block, in: turnPages, on: 900)
        return turnPages
    }

    // MARK: Fill

    /// **Rebuild only when something visible changed.**
    ///
    /// The list is short, and a list patched in three places drifts apart, so it
    /// is rebuilt completely. But not on every progress report: those arrive once
    /// per second, and the row keeps counting in between (``downloadCount``).
    /// A rebuild per report would restart the estimator each time.
    ///
    /// Called from `DownloadManager.change`; the page of a downloaded
    /// series hooks into it too.
    func downloadsPageFill() {
        downloadEstimatorUpdate()
        downloadSeriesUpdate()
        guard list != nil else { return }

        let a = DownloadDisplay.shared
        let all = downloads.entries
        let symbolText = "\(UInt(bitPattern: list))|" + downloadCharacter(all)
            + "|\(downloadEdit)|\(downloadSelected.sorted())|\(a.listsTravel)"
        guard symbolText != a.listsCharacter else { return }
        a.listsCharacter = symbolText

        wipe(list)
        let ongoing = all.filter { $0.state != .done }
        let finished = DownloadRules.grouped(all.filter { $0.state == .done })

        gtk_label_set_text(OpaquePointer(downloadAllocation), allocationRow())
        gtk_widget_set_visible(downloadEditButton, all.isEmpty ? 0 : 1)
        gtk_widget_set_visible(downloadRemove,
                               downloadEdit && !downloadSelected.isEmpty ? 1 : 0)
        gtk_widget_set_visible(downloadEmpty, all.isEmpty ? 1 : 0)

        if !ongoing.isEmpty {
            append(list, downloadCategory(translated("Lädt gerade")))
            for (i, p) in ongoing.enumerated() {
                append(list, downloadListsRow(p))
                if i < ongoing.count - 1 { append(list, rowsLine()) }
            }
        }

        if !finished.isEmpty {
            // **No heading above the downloaded items.** It used to say "Auf diesem
            // Rechner", which says nothing on a page where everything is on this
            // machine. The spacing to "Lädt gerade" stays.
            append(list, paddingHigh(ongoing.isEmpty ? 4 : 26))
            for (i, g) in finished.enumerated() {
                switch g {
                case let .single(p):
                    append(list, downloadListsRow(p))
                case let .series(sid, title, episodes):
                    append(list, downloadSeriesGroup(sid, title, episodes))
                }
                if i < finished.count - 1 { append(list, rowsLine()) }
            }
        }
    }

    /// What a row shows, without the progress (which counts on its own), plus
    /// whether an image exists on disk; that arrives later.
    func downloadCharacter(_ entries: [DownloadItem]) -> String {
        entries.map { p in
            "\(p.id):\(p.state):\(p.watched):\(p.stillOnTheServer):\(p.bytes)"
                + ":\(downloads.image(for: p) != nil):\(downloads.image(for: p, asGroup: true) != nil)"
                + (p.state == .done ? ":\(p.loaded)" : "")
        }.joined(separator: ",")
    }

    /// **The estimator per item, kept across rebuilds.** A new report feeds it;
    /// an item that is not downloading stops immediately (paused means standing).
    private func downloadEstimatorUpdate() {
        let a = DownloadDisplay.shared
        let now = Date()
        var present = Set<String>()
        for p in downloads.entries {
            present.insert(p.id)
            var s = a.estimator[p.id] ?? ProgressEstimator()
            if a.reported[p.id] != p.loaded {
                s.report(p.loaded, total: p.bytes, um: now)
                a.reported[p.id] = p.loaded
            }
            if p.state != .loads { s.halt() }
            a.estimator[p.id] = s
        }
        for id in a.estimator.keys where !present.contains(id) {
            a.estimator[id] = nil
            a.reported[id] = nil
        }
    }

    private func downloadCategory(_ text: String) -> Widget! {
        // **20 semibold in `font`, 26 above, 10 below**: the section style of
        // `DownloadsView` on the Mac, not the sidebar's.
        let r = label(text, style: "swiftly-reihe")
        gtk_label_set_xalign(OpaquePointer(r), 0)
        gtk_widget_set_margin_top(r, 26)
        gtk_widget_set_margin_bottom(r, 10)
        return r
    }

    /// "12 Titel · 42,8 GB · 310 GB frei": the numbers come from the package so
    /// they look like the system settings.
    private func allocationRow() -> String {
        let b = DownloadRules.allocation(downloads.entries)
        guard b.count > 0 || downloads.entries.contains(where: { $0.state != .done }) else {
            return translated("Nichts auf diesem Rechner")
        }
        let count = numberWord(b.count, one: translated("1 Titel"), many: translated("%lld Titel"))
        // **And what is still free.** The Mac shows it in the same line; without
        // the number the used space has no reference.
        return count + " · " + DownloadRules.size(b.bytes)
            + " · " + DownloadRules.size(downloads.freeSpace)
            + " " + translated("frei")
    }

    // MARK: One row

    /// One row of the download list, with its edit mode.
    private func downloadListsRow(_ p: DownloadItem) -> Widget! {
        downloadRow(p, edit: downloadEdit,
                      selected: downloadSelected.contains(p.id),
                      travel: DownloadDisplay.shared.listsTravel) { [weak self] in
            self?.downloadCheckmarkPut([p.id])
        }
    }

    /// **Sizes follow the Mac.** An episode is landscape (142 x 80), a movie and
    /// a series row are portrait (76 x 114): `MacDownloadRow.landscape`.
    ///
    /// The same row appears on the page of a downloaded series; the caller says
    /// which ones are selected.
    func downloadRow(_ p: DownloadItem, edit: Bool, selected: Bool,
                       travel: DownloadDisplay.CircleTravel,
                       flip: @escaping () -> Void) -> Widget! {
        let landscape = p.art == .episode
        let running = p.state == .loads || p.state == .halted
        // When paused the number stays where the estimator last was, never ahead
        // of the reported value.
        var loaded = p.loaded
        if running, var s = DownloadDisplay.shared.estimator[p.id] {
            loaded = max(s.value(um: Date()), p.loaded)
            DownloadDisplay.shared.estimator[p.id] = s
        }
        return downloadReasonRow(
            title: p.title,
            bottom: p.state == .loads ? downloadLoadText(loaded, from: p.bytes, estimated: p.converted)
                                     : downloadStateWord(p),
            cautionary: p.state == .error,
            landscape: landscape,
            image: downloadImage(p),
            series: landscape,
            edit: edit, selected: selected, travel: travel, flip: flip,
            // **The bar only while running or paused.** For "waiting" there is nothing
            // to show, and on an error a half-filled bar looks like progress.
            share: running ? (p.bytes > 0 ? Double(loaded) / Double(p.bytes) : p.share) : nil,
            tally: p.state == .loads ? (p.id, p.bytes) : nil,
            right: downloadButton(p),
            // **Watched state as in the episode list**, also offline: the state is
            // stored in the item. Only on a single row; a series row stands for many
            // episodes.
            watched: p.watched,
            // **Clicking the row plays it.** Plays, not the detail page: that needs the
            // server, and someone on this page may not have one.
            clicked: { [weak self] in
                if edit { flip() }
                else if p.state == .done { self?.downloadPlay(p) }
            })
    }

    /// A series is **one** row and **opens its page**: large image, name, play
    /// button, and the episodes by season below. The row used to expand in place
    /// with a list under the name, without image or play button; the Mac
    /// dropped that version.
    private func downloadSeriesGroup(_ sid: String, _ title: String,
                                      _ episodes: [DownloadItem]) -> Widget! {
        let bytes = episodes.reduce(Int64(0)) { $0 + $1.bytes }
        let bottom = numberWord(episodes.count, one: translated("1 Folge"), many: translated("%lld Folgen"))
            + " · " + DownloadRules.size(bytes)
            + (DownloadQuality.gemeinsam(episodes).map { " · " + $0.name } ?? "")

        // On the right the chevron, 36 wide, where the button otherwise sits.
        let angle: Widget! = gtk_image_new_from_icon_name("pan-end-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(angle), 13)
        gtk_widget_add_css_class(angle, "swiftly-leise")
        gtk_widget_set_size_request(angle, 36, -1)
        gtk_widget_set_valign(angle, GTK_ALIGN_CENTER)

        let ids = episodes.map(\.id)
        let flip: () -> Void = { [weak self] in self?.downloadCheckmarkPut(ids) }
        return downloadReasonRow(
            title: title, bottom: bottom, cautionary: false, landscape: false,
            image: episodes.first.flatMap { downloadImage($0, asGroup: true) },
            series: true,
            edit: downloadEdit,
            selected: !ids.isEmpty && ids.allSatisfy { downloadSelected.contains($0) },
            travel: DownloadDisplay.shared.listsTravel, flip: flip,
            share: nil, tally: nil, right: angle,
            clicked: { [weak self] in
                guard let self else { return }
                if self.downloadEdit { flip() }
                else { self.downloadSeriesOpen(sid, title: title) }
            })
    }

    private func downloadCheckmarkPut(_ ids: [String]) {
        if ids.allSatisfy({ downloadSelected.contains($0) }) {
            downloadSelected.subtract(ids)
        } else {
            downloadSelected.formUnion(ids)
        }
        downloadsPageFill()
    }

    /// Edit mode on or off. **The circle slides in from the left**
    /// (`.move(edge: .leading)` in `sprung`, 0.22 s) and slides back out when
    /// editing ends, before the list is rebuilt without it.
    func downloadEditPut() {
        let a = DownloadDisplay.shared
        downloadEdit.toggle()
        if !downloadEdit { downloadSelected = [] }
        a.listsTravel = downloadEdit ? .inward : .out
        downloadsPageFill()
        a.listsTravel = .stands
        guard !downloadEdit, list != nil else { return }
        a.listsTravel = .out
        runningCount(on: list, duration: 0.22, step: { _ in }, done: { [weak self] in
            a.listsTravel = .stands
            self?.downloadsPageFill()
        })
    }

    /// The shared body of all rows: circle, image, text, bar, right button. One
    /// row, not two nearly identical ones.
    private func downloadReasonRow(title: String, bottom: String, cautionary: Bool,
                                    landscape: Bool, image: URL?, series: Bool,
                                    edit: Bool, selected: Bool,
                                    travel: DownloadDisplay.CircleTravel,
                                    flip: @escaping () -> Void,
                                    share: Double?, tally: (String, Int64)?,
                                    right: Widget!,
                                    watched: Bool = false,
                                    clicked: @escaping () -> Void) -> Widget! {
        let button: Widget! = gtk_button_new()
        // **Own class, not `swiftly-zeile`** (`Abdunkeln` on the Mac): pressing
        // dims the content instead of putting a gray area behind the row.
        // `swiftly-zeile` is the sidebar row and stays as it is.
        gtk_widget_add_css_class(button, "swiftly-dlzeile")
        if edit { gtk_widget_add_css_class(button, "swiftly-bearbeiten") }
        signal(button, "clicked") { clicked() }

        let outer = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_margin_top(outer, 12)
        gtk_widget_set_margin_bottom(outer, 12)
        gtk_widget_set_margin_start(outer, 10)
        gtk_widget_set_margin_end(outer, 10)

        // **The circle slides in from the left and pushes the row ahead of it.** It
        // sits in a revealer that grows its width from zero to full; the 16 of
        // spacing after it belong to it, otherwise a gap would show while sliding
        // in.
        if edit || travel == .out {
            let checkmark = downloadCheckmark(an: selected, flip: flip)
            gtk_widget_set_margin_end(checkmark, 16)
            let driver: Widget! = gtk_revealer_new()
            gtk_revealer_set_transition_type(asExpand(driver),
                                             GTK_REVEALER_TRANSITION_TYPE_SLIDE_RIGHT)
            gtk_revealer_set_child(asExpand(driver), checkmark)
            gtk_widget_set_valign(driver, GTK_ALIGN_CENTER)
            gtk_revealer_set_transition_duration(asExpand(driver), 0)
            gtk_revealer_set_reveal_child(asExpand(driver), travel == .inward ? 0 : 1)
            gtk_revealer_set_transition_duration(asExpand(driver), 220)
            if travel != .stands {
                let container = held(driver)
                let inward = travel == .inward
                onMainThread {
                    defer { letGo(container) }
                    gtk_revealer_set_reveal_child(asExpand(container.widget), inward ? 1 : 0)
                }
            }
            append(outer, driver)
        }

        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 16)
        gtk_widget_set_hexpand(row, 1)
        append(outer, row)

        let (wrapper, inputField) = framedImage(width: landscape ? 142 : 76,
                                           height: landscape ? 80 : 114, style: "swiftly-plakat")
        if let image {
            imageLoad(inputField, url: image, key: "dl-\(image.lastPathComponent)", immediate: true)
        } else {
            characterPut(wrapper, series: series)
        }
        if watched { watchedCheckmarkPut(wrapper, an: true) }
        append(row, wrapper)

        let text = stack(GTK_ORIENTATION_VERTICAL, spacing: 4)
        gtk_widget_set_hexpand(text, 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        let t = label(title, style: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(t), 0)
        gtk_label_set_ellipsize(OpaquePointer(t), PANGO_ELLIPSIZE_END)
        append(text, t)

        let u = label(bottom, style: "swiftly-zweitzeile")
        gtk_label_set_xalign(OpaquePointer(u), 0)
        gtk_label_set_ellipsize(OpaquePointer(u), PANGO_ELLIPSIZE_END)
        gtk_widget_add_css_class(u, cautionary ? "swiftly-warnung" : "dim-label")
        append(text, u)

        var stripe: LoadingBar?
        if let share {
            let b = LoadingBar(share: share)
            gtk_widget_set_margin_top(b.display, 4)
            append(text, b.display)
            stripe = b
        }
        if let z = tally {
            downloadCount(z.0, bytes: z.1, estimated: downloads.entries(for: z.0)?.converted ?? false,
                            row: u, stripe: stripe)
        }
        append(row, text)
        append(row, right)

        gtk_button_set_child(asButton(button), outer)
        return button
    }

    /// **No `GtkCheckButton`.** This UI uses no standard controls; it draws its
    /// own switches, and everywhere else `object-select-symbolic` sits in a
    /// custom capsule. A GTK checkbox here would be as out of place as a system
    /// dialog in the middle of the app.
    private func downloadCheckmark(an: Bool, flip: @escaping () -> Void) -> Widget! {
        let checkmark = secondaryButton("object-select-symbolic",
                               name: an ? translated("Abwählen") : translated("Auswählen"),
                               active: an)
        help(checkmark, checkmark: an ? .an : .off)
        gtk_widget_set_valign(checkmark, GTK_ALIGN_CENTER)
        signal(checkmark, "clicked") { flip() }
        return checkmark
    }

    /// **One button, six states**: the same statements as the ring on the Mac,
    /// as a drawn button because there is no drawn ring here.
    private func downloadButton(_ p: DownloadItem) -> Widget! {
        let (symbol, name, actionLabel): (String, String, () -> Void)
        switch p.state {
        case .loads:
            symbol = "media-playback-pause-symbolic"
            name = translated("Anhalten")
            actionLabel = { [weak self] in self?.downloads.halt(p.id) }
        // **Waiting is not running.** `.waits` used to be grouped with `.loads` and
        // triggered "pause" on something that is not running yet. The Mac groups
        // `.halted`, `.error` and `.waits` and resumes.
        case .halted, .waits:
            symbol = "media-playback-start-symbolic"
            name = translated("Fortsetzen")
            actionLabel = { [weak self] in self?.downloads.resume(p.id) }
        case .error:
            symbol = "view-refresh-symbolic"
            name = translated("Nochmal versuchen")
            actionLabel = { [weak self] in self?.downloads.resume(p.id) }
        case .done:
            symbol = "media-playback-start-symbolic"
            name = translated("Abspielen")
            actionLabel = { [weak self] in self?.downloadPlay(p) }
        }
        let button = secondaryButton(symbol, name: name)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        signal(button, "clicked") { actionLabel() }
        return button
    }

    /// " · 720p" for a converted file, nothing otherwise.
    private func rung(_ p: DownloadItem) -> String {
        p.converted ? " · " + p.guete.name : ""
    }

    private func downloadStateWord(_ p: DownloadItem) -> String {
        switch p.state {
        case .waits:     return translated("Wartet") + rung(p)
        case .loads:
            guard p.bytes > 0 else { return DownloadRules.size(p.loaded) }
            return DownloadRules.size(p.loaded) + " / " + DownloadRules.size(p.bytes)
        case .halted: return translated("Angehalten") + rung(p)
        case .error:     return p.reason ?? translated("Fehler")
        case .done:
            // If the title disappears from the server, the file stays and the row shows
            // a quiet notice. Deleting along with it would be a nasty surprise on a
            // plane, which is the case this feature exists for.
            var pieces = [DownloadRules.size(p.loaded)]
            // The chosen quality is shown where the container is otherwise shown.
            if p.converted {
                pieces.append(p.guete.name)
            } else if let container = p.container, !container.isEmpty {
                pieces.append(container.uppercased())
            }
            if !p.stillOnTheServer {
                pieces.append(translated("nicht mehr auf dem Server"))
            }
            return pieces.joined(separator: " · ")
        }
    }

    /// The image comes **from disk**, not from the server; otherwise the page
    /// would be empty in exactly the case it exists for. If missing, the
    /// placeholder icon stays.
    private func downloadImage(_ p: DownloadItem, asGroup: Bool = false) -> URL? {
        if let present = downloads.image(for: p, asGroup: asGroup) { return present }
        // **Otherwise from the server**, as long as one is reachable. The Mac falls
        // back to `posterURL` at the same point; without it the area would stay
        // empty although the image is just one request away.
        return addresses?.construct(itemID: asGroup ? (p.seriesIdentifier ?? p.id) : p.id,
                               mass: .atMostHigh(300))
    }

    // MARK: Playback

    /// **From the file, not from the server.**
    ///
    /// The player gets the same `Item` shape as usual (built by
    /// `DownloadItem.asItem` in the package), with the path on disk instead of
    /// a server URL. Everything else is the same path.
    func downloadPlay(_ p: DownloadItem) {
        guard let path = downloads.file(for: p.id) else { return }
        // At the remembered position, the same with or without network.
        playerOpen(p.asItem, since: downloads.entries(for: p.id)?.resumeFrom ?? 0,
                       fromFile: path)
    }
}
