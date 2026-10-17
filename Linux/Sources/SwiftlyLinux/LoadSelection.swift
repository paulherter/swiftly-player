import CGtk
import Foundation
import JellyfinKit

/// **A series' download selection**, the GTK version of `MacLadeauswahl`
/// (`Sources/macOS/MacDownloads.swift`).
///
/// A tree with three levels (whole series, season, episode), each carrying
/// the same round box in three states: empty, partial, full. The switch
/// "Nur ungesehene" selects nothing itself; it decides *what* a checkmark
/// selects. A single episode is ticked here, and its size is visible while
/// doing so.
///
/// **The failure case is part of it.** If a season fetch fails, the error
/// hint is shown instead of an empty selection. Failed fetches are not
/// cached.
final class LoadSelectionState: @unchecked Sendable {
    var seasons: [Item] = []
    var episodes: [String: [Item]] = [:]
    var selected: Set<String> = []
    var openSeason: String?
    /// The season that was just expanded: only it slides in, every other
    /// rebuild appears immediately.
    var freshExpanded: String?
    var onlyUnwatched = false
    /// Original, until someone clicks the badge and picks something else.
    var quality: DownloadQuality = .original
    /// Whether the list of levels under the badge is expanded.
    var qualityOpen = false
    var loads = true
    var disrupted = false
    var allEpisodes: [Item] { seasons.compactMap { episodes[$0.id] }.flatMap { $0 } }
}

/// Holds the callback that redraws the selection; it calls itself again
/// through the buttons inside it. Touched only on GTK's main thread.
final class Painter: @unchecked Sendable {
    var perform: () -> Void = {}
}

extension App {
    /// Opens the selection as a panel below the download button of the series page.
    func loadSelectionShow(_ series: Item, an button: Widget!) {
        guard let client else { return }
        let state = LoadSelectionState()
        let panel = panelOpen(an: button)
        let shell = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(shell, 420, -1)
        gtk_popover_set_child(asPanel(panel), Scaling.wrapped(shell))

        let header = label(series.name, style: "swiftly-leistentitel")
        gtk_label_set_xalign(OpaquePointer(header), 0)
        gtk_label_set_ellipsize(OpaquePointer(header), PANGO_ELLIPSIZE_END)
        gtk_widget_set_margin_start(header, 16)
        gtk_widget_set_margin_end(header, 16)
        gtk_widget_set_margin_top(header, 10)
        gtk_widget_set_margin_bottom(header, 10)
        append(shell, header)

        let content = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        append(shell, content)
        let container = held(content)
        let panelBox = held(panel)
        signal(panel, "closed") { letGo(container); letGo(panelBox) }

        let painter = Painter()
        let draw: @Sendable () -> Void = { painter.perform() }
        painter.perform = { [weak self] in
            guard let self, gtk_widget_get_parent(container.widget) != nil else { return }
            self.loadSelectionDraw(state, series: series, in: container.widget,
                                  panel: panelBox.widget, new: draw,
                                  retry: { [weak self] in
                                      self?.loadSelectionFetch(state, series: series,
                                                             client: client, done: draw)
                                  })
        }
        // The painter keeps itself alive via `malen`; release it on closing.
        signal(panel, "closed") { painter.perform = {} }
        draw()
        loadSelectionFetch(state, series: series, client: client, done: draw)
        gtk_popover_popup(asPanel(panel))
    }

    /// Seasons and all episodes, from memory what is already there.
    private func loadSelectionFetch(_ state: LoadSelectionState, series: Item,
                                  client: JellyfinClient, done: @escaping @Sendable () -> Void) {
        state.loads = true
        state.disrupted = false
        let seasonsPresent = seasonCache[series.id]
        let already = episodeStore
        Task.detached { [self] in
            var seasons = seasonsPresent ?? []
            var disrupted = false
            if seasons.isEmpty {
                if let list = try? await client.seasons(seriesID: series.id) {
                    seasons = list
                } else {
                    disrupted = true
                }
            }
            var episodes: [String: [Item]] = [:]
            for season in seasons {
                if let present = already[season.id] { episodes[season.id] = present; continue }
                guard let list = try? await client.episodes(seriesID: series.id,
                                                           seasonID: season.id)
                else { disrupted = true; continue }
                episodes[season.id] = list
            }
            let result = (seasons, episodes, disrupted)
            onMainThread {
                state.seasons = result.0
                state.episodes = result.1
                state.disrupted = result.2
                state.loads = false
                if !result.0.isEmpty { self.seasonCache[series.id] = result.0 }
                for (k, v) in result.1 { self.episodeStore[k] = v }
                done()
            }
        }
    }

    /// **What a checkmark takes.** Without the switch everything; with it only
    /// what is unwatched. What is already on disk is never taken.
    private func takeable(_ list: [Item], _ state: LoadSelectionState) -> [Item] {
        list.filter { episode in
            guard downloads.entries(for: episode.id) == nil else { return false }
            guard state.onlyUnwatched else { return true }
            return !watched(episode)
        }
    }

    /// **What is in the list.** With "Nur ungesehene", watched episodes are not
    /// listed at all and count nowhere; before, they stayed visible and were
    /// merely not selectable.
    private func visible(_ list: [Item], _ state: LoadSelectionState) -> [Item] {
        state.onlyUnwatched ? list.filter { !watched($0) } : list
    }

    private func watched(_ episode: Item) -> Bool { episode.userData?.played ?? false }

    /// Four states: the three of the selection, and **done** for what already
    /// lies on this machine and can no longer be selected. Before, ``nehmbar(_:_:)``
    /// only hid downloaded items, and an empty circle that did nothing on click
    /// stood in their place.
    private enum CheckboxState { case empty, part, full, present }

    private func boxState(_ all: [Item], _ state: LoadSelectionState,
                             presentCounts: Bool = true) -> CheckboxState {
        let list = visible(all, state)
        if presentCounts, !list.isEmpty,
           list.allSatisfy({ downloads.entries(for: $0.id) != nil }) {
            return .present
        }
        let free = takeable(list, state)
        guard !free.isEmpty else { return .empty }
        let an = free.filter { state.selected.contains($0.id) }.count
        return an == 0 ? .empty : (an == free.count ? .full : .part)
    }

    /// As long as not every season has been read, the series is not "done", even
    /// if the first one read happens to be fully downloaded.
    private func stateAll(_ state: LoadSelectionState) -> CheckboxState {
        boxState(state.allEpisodes, state, presentCounts: !state.loads)
    }

    /// **"Ganze Serie" only names what is still missing** (`seriesRight` on the Mac).
    private func seriesRight(_ state: LoadSelectionState) -> String {
        if state.loads { return translated("wird gelesen …") }
        let all = state.allEpisodes
        if stateAll(state) == .present { return translated("alles da") }
        if !all.isEmpty, visible(all, state).isEmpty { return translated("alles gesehen") }
        let free = takeable(all, state)
        return episodesNumber(free.count) + " · " + DownloadRules.size(bytes(free))
    }

    /// Right side of the season row: what a checkmark there would still take.
    /// **"alles da" only when true**, not while the season is still being read,
    /// and not when "Nur ungesehene" excludes everything.
    private func seasonRight(_ all: [Item]?, visible ownOnes: [Item], _ box: CheckboxState,
                               _ state: LoadSelectionState) -> String {
        guard let all else { return state.loads ? translated("wird gelesen …") : "—" }
        if all.isEmpty { return translated("Keine Folgen") }
        if ownOnes.isEmpty { return translated("alles gesehen") }
        if box == .present { return translated("alles da") }
        let free = takeable(ownOnes, state)
        if free.isEmpty { return translated("alles da") }
        return String(format: translated("%lld Folgen"), free.count)
    }

    /// **Watched is shown before choosing.** Without the switch, watched episodes
    /// stay selectable: circle like any other, but title quiet and "gesehen"
    /// before the size on the right.
    private func episodesRight(_ episode: Item) -> String {
        let size = (episode.mediaSources?.first?.size).flatMap {
            $0 > 0 ? DownloadRules.size(Int64($0)) : nil } ?? "—"
        return watched(episode) ? translated("gesehen") + " · " + size : size
    }

    /// **A downloaded episode says it is there**, showing its state instead of
    /// the size.
    private func loadState(_ entries: DownloadItem) -> String {
        switch entries.state {
        case .done: return translated("geladen")
        case .loads: return translated("lädt")
        default: return translated("wartet")
        }
    }

    private func episodesNumber(_ n: Int) -> String {
        numberWord(n, one: translated("1 Folge"), many: translated("%lld Folgen"))
    }

    private func bytes(_ list: [Item]) -> Int64 {
        list.reduce(0) { $0 + Int64($1.mediaSources?.first?.size ?? 0) }
    }

    private func loadSelectionDraw(_ state: LoadSelectionState, series: Item, in content: Widget!,
                                  panel: Widget!, new: @escaping () -> Void,
                                  retry: @escaping () -> Void) {
        // Where the list was, it stays: it is rebuilt on every checkmark, and
        // nothing should scroll.
        var oldPoint = 0.0
        if let alt = gtk_widget_get_first_child(content),
           gtk_widget_has_css_class(alt, "swiftly-auswahlscroller") != 0,
           let a = gtk_scrolled_window_get_vadjustment(OpaquePointer(alt)) {
            oldPoint = gtk_adjustment_get_value(a)
        }
        wipe(content)
        if state.disrupted, state.allEpisodes.isEmpty {
            let hint = disturbHint(top: 10, retry: retry)
            gtk_widget_set_margin_bottom(hint, 16)
            append(content, hint)
            return
        }

        let toggle: ([Item]) -> Void = { [weak self] list in
            guard let self else { return }
            let free = self.takeable(list, state)
            guard !free.isEmpty else { return }
            let allAn = free.allSatisfy { state.selected.contains($0.id) }
            for f in free {
                if allAn { state.selected.remove(f.id) } else { state.selected.insert(f.id) }
            }
            new()
        }

        let scroller: Widget! = gtk_scrolled_window_new()
        gtk_widget_add_css_class(scroller, "swiftly-auswahlscroller")
        gtk_scrolled_window_set_policy(OpaquePointer(scroller), GTK_POLICY_NEVER,
                                       GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(OpaquePointer(scroller), 1)
        gtk_scrolled_window_set_max_content_height(OpaquePointer(scroller), 360)
        let cards = stack(GTK_ORIENTATION_VERTICAL, spacing: 12)
        gtk_widget_set_margin_start(cards, 16)
        gtk_widget_set_margin_end(cards, 16)
        gtk_widget_set_margin_bottom(cards, 12)
        gtk_scrolled_window_set_child(OpaquePointer(scroller), cards)
        append(content, scroller)

        // The series card: whole series, below it the switch.
        let seriesCard = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(seriesCard, "swiftly-auswahlkarte")
        let all = state.allEpisodes
        append(seriesCard, selectionRowBuild(
            box: stateAll(state), title: translated("Ganze Serie"),
            right: seriesRight(state),
            small: false, inset: 16, expanded: nil,
            perform: { toggle(all) }, expand: nil))
        append(seriesCard, divider())
        let toggleBlock = stack(GTK_ORIENTATION_VERTICAL, spacing: 3)
        gtk_widget_set_margin_start(toggleBlock, 16)
        gtk_widget_set_margin_end(toggleBlock, 16)
        gtk_widget_set_margin_top(toggleBlock, 12)
        gtk_widget_set_margin_bottom(toggleBlock, 12)
        let toggleRail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 13)
        let st = label(translated("Nur ungesehene"), style: "swiftly-listentitel")
        gtk_label_set_xalign(OpaquePointer(st), 0)
        gtk_widget_set_hexpand(st, 1)
        append(toggleRail, st)
        append(toggleRail, smallerToggle(an: state.onlyUnwatched, name: translated("Nur ungesehene")) { [weak self] an in
            guard let self else { return }
            state.onlyUnwatched = an
            let allowed = Set(self.takeable(state.allEpisodes, state).map(\.id))
            state.selected.formIntersection(allowed)
            new()
        })
        append(toggleBlock, toggleRail)
        let su = label(translated("Entscheidet, was ein Haken auswählt."),
                              style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(su, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(su), 0)
        append(toggleBlock, su)
        append(seriesCard, toggleBlock)
        append(cards, seriesCard)

        // The season card: one row per season, expandable to the episodes.
        if !state.seasons.isEmpty {
            let seasonCard = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_widget_add_css_class(seasonCard, "swiftly-auswahlkarte")
            for (nr, season) in state.seasons.enumerated() {
                let ownOnes = visible(state.episodes[season.id] ?? [], state)
                let box = boxState(ownOnes, state)
                let opened = state.openSeason == season.id
                // **The episodes slide in and the panel grows with them** (Mac,
                // `heightSet`). There, rows and height run on the same curve, `sprung`
                // (0.22 s). Here a `GtkRevealer` carries the episodes; the panel measures it
                // every frame and so grows on the same curve by itself.
                let expand: Widget! = gtk_revealer_new()
                gtk_revealer_set_transition_type(asExpand(expand),
                                                 GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN)
                // Not held: the call only comes from the adjacent row, which lives and
                // goes with the expander.
                let expandBox = PointerBox(expand)
                append(seasonCard, selectionRowBuild(
                    box: box, title: season.name,
                    right: seasonRight(state.episodes[season.id], visible: ownOnes,
                                          box, state),
                    small: false, inset: 16, expanded: opened,
                    perform: { toggle(ownOnes) },
                    expand: {
                        guard opened else {
                            state.openSeason = season.id
                            state.freshExpanded = season.id
                            new()
                            return
                        }
                        // Closing: slide in first, then rebuild.
                        let w: Widget! = expandBox.widget
                        gtk_revealer_set_reveal_child(asExpand(w), 0)
                        runningCount(on: w, duration: 0.22, step: { _ in }, done: {
                            guard state.openSeason == season.id else { return }
                            state.openSeason = nil
                            new()
                        })
                    }))
                if opened {
                    let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
                    for episode in ownOnes {
                        append(block, divider())
                        let entries = downloads.entries(for: episode.id)
                        append(block, selectionRowBuild(
                            box: entries != nil ? .present
                                    : (state.selected.contains(episode.id) ? .full : .empty),
                            title: episode.name,
                            right: entries.map(loadState) ?? episodesRight(episode),
                            small: true, inset: 38, quiet: watched(episode),
                            expanded: nil, perform: { toggle([episode]) }, expand: nil))
                    }
                    gtk_revealer_set_child(asExpand(expand), block)
                    if state.freshExpanded == season.id {
                        state.freshExpanded = nil
                        gtk_revealer_set_transition_duration(asExpand(expand), 220)
                        let container = held(expand)
                        onMainThread {
                            defer { letGo(container) }
                            gtk_revealer_set_reveal_child(asExpand(container.widget), 1)
                        }
                    } else {
                        // Every other rebuild (a checkmark) appears immediately.
                        gtk_revealer_set_transition_duration(asExpand(expand), 0)
                        gtk_revealer_set_reveal_child(asExpand(expand), 1)
                        gtk_revealer_set_transition_duration(asExpand(expand), 220)
                    }
                }
                append(seasonCard, expand)
                if nr < state.seasons.count - 1 { append(seasonCard, divider()) }
            }
            append(cards, seasonCard)
        }
        if oldPoint > 0 {
            let spot = oldPoint
            let sk = held(scroller)
            onMainThread {
                defer { letGo(sk) }
                if let a = gtk_scrolled_window_get_vadjustment(OpaquePointer(sk.widget)) {
                    gtk_adjustment_set_value(a, spot)
                }
            }
        }

        // The footer: what is selected, what remains free afterwards, the proof, and
        // the main button.
        let footer = stack(GTK_ORIENTATION_VERTICAL, spacing: 10)
        gtk_widget_set_margin_top(footer, 4)
        gtk_widget_set_margin_bottom(footer, 12)
        append(footer, divider())
        let selectedEpisodes = state.allEpisodes.filter { state.selected.contains($0.id) }
        // **The footer calculates in the chosen quality** (Mac
        // `MacLadeauswahl.bytes(in:)`): the real size for Original, otherwise the
        // estimate from bitrate times runtime.
        func sumIn(_ q: DownloadQuality) -> Int64 {
            selectedEpisodes.reduce(0) {
                $0 + q.estimatedBytes(original: $1.mediaSources?.first?.size ?? 0,
                                        runtimeTicks: $1.runTimeTicks)
            }
        }
        let base = selectedEpisodes.isEmpty ? state.allEpisodes : selectedEpisodes
        let offered = DownloadQuality.offered(
            selectable: downloadQualitySelectable,
            sourceBitrateOf: DownloadQuality.sourceBitrateOf(base.map {
                ($0.mediaSources?.first?.size ?? 0, $0.runTimeTicks)
            }))
        // If the chosen level disappears, Original applies again.
        if !offered.contains(state.quality) { state.quality = .original }
        let sum = sumIn(state.quality)
        let numberRail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_set_margin_start(numberRail, 16)
        gtk_widget_set_margin_end(numberRail, 16)
        let left = label(state.selected.isEmpty ? translated("Nichts gewählt")
                                 : episodesNumber(state.selected.count) + " · "
                                   + DownloadRules.size(sum),
                                 style: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(left), 0)
        gtk_widget_set_hexpand(left, 1)
        append(numberRail, left)
        // **Right side of the footer: free afterwards, or what is missing.** With
        // too little space this used to read "Danach 0 GB frei", correct but
        // misleading, since it did not say it does not fit. Whether it fits is
        // decided by `DownloadRules.footSpace` in the package, with the same
        // reserve as the confirmation afterwards.
        switch DownloadRules.footSpace(for: sum, free: downloads.freeSpace) {
        case .free(let rest):
            let right = label(String(format: translated("Danach %@ frei"),
                                             DownloadRules.size(rest)),
                                      style: "swiftly-zweitzeile")
            gtk_widget_add_css_class(right, "swiftly-leise")
            append(numberRail, right)
        case .few(let missing):
            let warning = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 5)
            gtk_widget_add_css_class(warning, "swiftly-warnung")
            let symbolText: Widget! = gtk_image_new_from_icon_name("dialog-information-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(symbolText), 12)
            gtk_widget_add_css_class(symbolText, "swiftly-warnung")
            append(warning, symbolText)
            let text = label(String(format: translated("%@ zu wenig"),
                                           DownloadRules.size(missing)),
                                    style: "swiftly-zweitzeile")
            gtk_widget_add_css_class(text, "swiftly-warnung")
            append(warning, text)
            append(numberRail, warning)
        }
        append(footer, numberRail)

        // **The badge is also the choice of a smaller version**, if the server may
        // transcode.
        let choice = qualitySelectionBuild(
            choice: state.quality, offered: offered, selectable: downloadQualitySelectable,
            opened: state.qualityOpen,
            size: { state.selected.isEmpty ? 0 : sumIn($0) },
            toggle: { state.qualityOpen.toggle(); new() },
            select: { state.quality = $0; state.qualityOpen = false; new() })
        gtk_widget_set_margin_start(choice, 16)
        gtk_widget_set_margin_end(choice, 16)
        append(footer, choice)

        let button = primaryButton(state.selected.isEmpty ? translated("Laden")
                               : String(format: translated("%@ laden"),
                                        episodesNumber(state.selected.count)),
                               symbol: "folder-download-symbolic")
        gtk_widget_set_size_request(button, 388, Int32(Theme.primaryButtonHeight))
        gtk_widget_set_sensitive(button, state.selected.isEmpty ? 0 : 1)
        let panelBox = held(panel)
        signal(button, "clicked") { [weak self] in
            gtk_popover_popdown(asPanel(panelBox.widget))
            letGo(panelBox)
            guard let self else { return }
            self.seasonLoad(selectedEpisodes, quality: state.quality)
            // Header image and poster come along with the first download of the series,
            // once; what is already there is not fetched again.
            if self.downloads.headerImage(series: series.id, account: self.userIdentifier) == nil {
                self.downloadSeriesImageWithGive(series)
            }
        }
        append(footer, button)
        append(content, footer)
    }

    /// One row of the selection: box on the left, title, on the right the info
    /// and, for a season, the chevron. 58 high, an episode 52: the indented
    /// episode should sit flatter than the season it belongs to.
    private func selectionRowBuild(box: CheckboxState, title: String, right: String,
                                   small: Bool, inset: Int, quiet: Bool = false,
                                   expanded: Bool?,
                                   perform: @escaping () -> Void,
                                   expand: (() -> Void)?) -> Widget! {
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 13)
        gtk_widget_set_margin_start(rail, Int32(inset))
        gtk_widget_set_margin_end(rail, 16)
        gtk_widget_set_size_request(rail, -1, small ? 52 : 58)

        // **Done: quiet, no circle and no button.** An accent checkmark would mean
        // "selected"; this one only says nothing is left to do.
        guard box != .present else {
            let inputField = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            gtk_widget_set_size_request(inputField, 22, 22)
            gtk_widget_set_valign(inputField, GTK_ALIGN_CENTER)
            let checkmark: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(checkmark), 15)
            gtk_widget_add_css_class(checkmark, "swiftly-leise")
            gtk_widget_set_hexpand(checkmark, 1)
            append(inputField, checkmark)
            caption(inputField, translated("geladen"))
            append(rail, inputField)
            return selectionRowRemaining(rail, title: title, right: right, small: small,
                                    quiet: true, expanded: expanded,
                                    perform: perform, expand: expand)
        }
        let boxButton: Widget! = gtk_button_new()
        gtk_widget_add_css_class(boxButton, "swiftly-kasten")
        switch box {
        case .empty, .present: break
        case .part:
            gtk_widget_add_css_class(boxButton, "swiftly-aktiv")
            let b: Widget! = gtk_image_new_from_icon_name("list-remove-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(b), 12)
            gtk_button_set_child(asButton(boxButton), b)
        case .full:
            gtk_widget_add_css_class(boxButton, "swiftly-aktiv")
            let b: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(b), 11)
            gtk_button_set_child(asButton(boxButton), b)
        }
        help(boxButton, name: translated("Auswählen"),
                    checkmark: box == .full ? .an : box == .part ? .partly : .off)
        gtk_widget_set_size_request(boxButton, 22, 22)
        gtk_widget_set_valign(boxButton, GTK_ALIGN_CENTER)
        signal(boxButton, "clicked", perform)
        append(rail, boxButton)
        return selectionRowRemaining(rail, title: title, right: right, small: small,
                                quiet: quiet, expanded: expanded,
                                perform: perform, expand: expand)
    }

    /// Title, info and chevron to the right of the box.
    private func selectionRowRemaining(_ rail: Widget!, title: String, right: String,
                                  small: Bool, quiet: Bool, expanded: Bool?,
                                  perform: @escaping () -> Void,
                                  expand: (() -> Void)?) -> Widget! {
        let row: Widget! = gtk_button_new()
        gtk_widget_add_css_class(row, "swiftly-auswahlzeile")
        gtk_widget_set_hexpand(row, 1)
        let inner = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let t = label(title, style: small ? "swiftly-kacheltitel" : "swiftly-listentitel")
        gtk_label_set_xalign(OpaquePointer(t), 0)
        gtk_label_set_ellipsize(OpaquePointer(t), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(t, 1)
        // Watched or downloaded: title in `schriftLeise`, as on the Mac.
        if quiet { gtk_widget_add_css_class(t, "dim-label") }
        append(inner, t)
        let r = label(right, style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(r, "swiftly-leise")
        append(inner, r)
        if let expanded {
            let w: Widget! = gtk_image_new_from_icon_name(expanded ? "pan-down-symbolic"
                                                                      : "pan-end-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(w), 13)
            gtk_widget_add_css_class(w, "swiftly-leise")
            append(inner, w)
        }
        gtk_button_set_child(asButton(row), inner)
        signal(row, "clicked") { (expand ?? perform)() }
        append(rail, row)
        return rail
    }

    /// **The badge under a download selection, and the quality choice.**
    /// Template: `MacQualityBadge` (`Sources/macOS/MacDownloads.swift`).
    /// Original is the default; if the server may transcode, a click expands the
    /// smaller levels with their estimated size below. Expanded here instead of
    /// a menu: the selection is itself a panel, and GTK loses a panel on a panel
    /// when closing.
    func qualitySelectionBuild(choice: DownloadQuality, offered: [DownloadQuality],
                             selectable: Bool, opened: Bool,
                             size: @escaping (DownloadQuality) -> Int64,
                             toggle: @escaping () -> Void,
                             select: @escaping (DownloadQuality) -> Void) -> Widget! {
        let inputField = stack(GTK_ORIENTATION_VERTICAL, spacing: 6)
        let expandable = selectable && offered.count > 1

        let proof = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_add_css_class(proof, "swiftly-belegmarke")
        gtk_widget_add_css_class(proof, "swiftly-beleg")
        let checkmark: Widget! = gtk_image_new_from_icon_name(choice.isOriginal ? "object-select-symbolic"
                                                                          : "folder-download-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(checkmark), 11)
        append(proof, checkmark)
        append(proof, label(choice.badge(), style: "swiftly-zweitzeile"))
        if expandable {
            let w: Widget! = gtk_image_new_from_icon_name(opened ? "pan-down-symbolic" : "pan-end-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(w), 11)
            append(proof, w)
            let button: Widget! = gtk_button_new()
            gtk_widget_add_css_class(button, "swiftly-auswahlzeile")
            gtk_widget_set_halign(button, GTK_ALIGN_START)
            gtk_button_set_child(asButton(button), proof)
            caption(button, translated("Qualität"))
            signal(button, "clicked", toggle)
            append(inputField, button)
        } else {
            gtk_widget_set_halign(proof, GTK_ALIGN_START)
            append(inputField, proof)
        }

        if expandable, opened {
            for q in offered {
                let row: Widget! = gtk_button_new()
                gtk_widget_add_css_class(row, "swiftly-auswahlzeile")
                let inner = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
                let t = label(q.name + " · " + q.addition(), style: "swiftly-koerper")
                gtk_label_set_xalign(OpaquePointer(t), 0)
                gtk_widget_set_hexpand(t, 1)
                append(inner, t)
                let g = size(q)
                if g > 0 {
                    let r = label((q.isOriginal ? "" : "≈ ") + DownloadRules.size(g),
                                         style: "swiftly-zweitzeile")
                    gtk_widget_add_css_class(r, "swiftly-leise")
                    append(inner, r)
                }
                let h: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
                gtk_image_set_pixel_size(OpaquePointer(h), 13)
                gtk_widget_set_opacity(h, q == choice ? 1 : 0)
                append(inner, h)
                gtk_button_set_child(asButton(row), inner)
                help(row, selected: q == choice)
                signal(row, "clicked") { select(q) }
                append(inputField, row)
            }
        }

        if !selectable {
            let l = label(translated("Kleinere Fassungen gibt der Server für dieses Konto nicht frei."),
                                 style: "swiftly-zweitzeile", wrap: true)
            gtk_label_set_xalign(OpaquePointer(l), 0)
            gtk_label_set_justify(OpaquePointer(l), GTK_JUSTIFY_LEFT)
            gtk_widget_add_css_class(l, "swiftly-leise")
            append(inputField, l)
        }
        return inputField
    }
}
