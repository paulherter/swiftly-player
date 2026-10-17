import CGtk
import Foundation
import JellyfinKit

/// The series page's foundation: tabs, season picker, episode list.
///
/// From `Sources/macOS/SeriesView.swift`. The season pill opens its list
/// **directly below**, with no sheet or panel: a small choice opens where it was
/// triggered.
extension App {

    enum PageTab: CaseIterable {
        case episodes, cast, similarOne, extras
        var label: String {
            switch self {
            case .episodes:     translated("Folgen")
            case .cast:  translated("Besetzung")
            case .similarOne: translated("Ähnliches")
            case .extras:     translated("Extras")
            }
        }
    }

    func seriesBase(_ series: Item, in bottom: Widget!) {
        let tabSpace = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        // **No margin on the tab content.** Otherwise the highlight of an episode row
        // would stop 24 short of the edge, while on the Mac it spans the full width. The
        // rows carry the margin themselves, as padding, so their background runs beneath.

        var selected: PageTab = .episodes
        var tabButtons: [Widget?] = []

        // **Left-aligned with 26 spacing**, like `TabRail` on the Mac
        // (`SeriesView.swift:495`): `HStack(spacing: 26)` with a `Spacer` behind it, and
        // buttons without `maxWidth`.
        //
        // The source is the reference; a screenshot that contradicts it gets re-read, not
        // rebuilt.
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 26)
        gtk_widget_set_margin_start(row, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_end(row, Int32(Theme.edgeSpacing))
        for fall in PageTab.allCases {
            let button = tabButton(fall.label, active: fall == selected)
            tabButtons.append(button)
            // **Only toggle, do not paint it yourself.** The highlight used to be set here and
            // so followed only the click; anyone switching the tab another way (the remote
            // panel, later a key) saw the content change while the underline stayed under
            // "Episodes". It belongs where the switching happens.
            signal(button, "clicked") { [weak self] in
                self?.tabShow?(fall)
            }
            // **"Extras" only once the server provides some** (Mac `SeriesView`,
            // `TabRail`): until then, and without any, the tab does not exist.
            if fall == .extras { gtk_widget_set_visible(button, 0) }
            append(row, button)
        }
        append(tabSpace, row)
        // **The hairline across the full width**, as on the Mac (`SeriesView.swift:504`).
        let tabLine: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(tabLine, "swiftly-trennlinie")
        gtk_widget_set_size_request(tabLine, -1, 1)
        append(tabSpace, tabLine)

        append(bottom, tabSpace)

        // **A stack, not a teardown.**
        //
        // Previously every tab change emptied `inhaltraum` and rebuilt it. The height of
        // the whole scroll content then changed in one step, from a long episode list to a
        // short cast row; GTK redistributes the page and the backdrop's drawing area goes
        // through an intermediate size. From outside the header image briefly vanishes and
        // comes back, which was reported twice.
        //
        // A `GtkStack` keeps the three pages side by side and cross-fades between them;
        // nothing changes above. It also removes the reloading: "Cast" and "Similar"
        // used to fetch again on every switch although they were already there.
        let tabStack: Widget! = gtk_stack_new()
        // Otherwise the `stack` rule in the stylesheet paints it opaque in `reason` and
        // clips the fading edge of the page tint.
        gtk_widget_add_css_class(tabStack, "swiftly-reiterstapel")
        gtk_stack_set_transition_type(asStack(tabStack),
                                      GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_transition_duration(asStack(tabStack),
                                          UInt32(Theme.timeFade * 1000))
        // **Stay the same height.** Without this the stack takes the height of the visible
        // page, and the page jumps on switching anyway.
        gtk_stack_set_vhomogeneous(asStack(tabStack), 0)
        append(bottom, tabStack)

        // **All three pages exist from the start** (iPhone). Previously "Episodes" was
        // created immediately and "Similar" only on first switch, with its own fetch and
        // placeholder. Now state, seasons, the episodes of the selected season and similar
        // titles arrive together (``seriesLoadMore``); the cast is already in the title.
        var pages: [PageTab: Widget?] = [:]
        for fall in PageTab.allCases {
            let space = stack(GTK_ORIENTATION_VERTICAL, spacing: 18)
            gtk_stack_add_named(asStack(tabStack), space, String(describing: fall))
            tabContent(fall, series: series, in: space)
            pages[fall] = space
        }
        seriesLoadMore(series, episodes: pages[.episodes] ?? nil, similarOne: pages[.similarOne] ?? nil)
        extrasLoadMore(series, in: pages[.extras] ?? nil,
                        button: tabButtons[PageTab.allCases.firstIndex(of: .extras) ?? 0])

        let showItem: (PageTab) -> Void = { fall in
            selected = fall
            for (i, f) in PageTab.allCases.enumerated() {
                guard let k = tabButtons[i] else { continue }
                if f == fall { gtk_widget_add_css_class(k, "swiftly-aktiv") }
                else { gtk_widget_remove_css_class(k, "swiftly-aktiv") }
                help(k, selected: f == fall)
            }
            gtk_stack_set_visible_child_name(asStack(tabStack), String(describing: fall))
        }
        tabShow = showItem
        showItem(.episodes)
        // Lets the remote panel switch the tab without clicking.
        tabSelect = showItem
    }

    /// Fetches the series' extras; without any, the tab stays invisible.
    private func extrasLoadMore(_ series: Item, in space: Widget!, button: Widget?) {
        guard let client, let space, let button else { return }
        let spaceBox = held(space)
        let buttonBox = held(button)
        Task.detached { [self] in
            let extras = (try? await client.extras(itemID: series.id)) ?? []
            postPush {
                defer { letGo(spaceBox); letGo(buttonBox) }
                guard !extras.isEmpty, let space = spaceBox.widget,
                      let button = buttonBox.widget else { return }
                append(space, self.extraRail(extras, title: translated("Extras")))
                gtk_widget_set_visible(button, 1)
            }
        }
    }

    /// **The extras as a row** (Mac `TitleRail(play: true)`, tile after
    /// `ExtraTile`): image 210 x 118, name and runtime below. A click plays the
    /// extra from the start with the same plan as any title: direct play, never
    /// transcoding. The series page uses the same heading in the "Extras" tab as the
    /// Mac.
    func extraRail(_ extras: [Item], title: String) -> Widget! {
        let width = 210
        let height = 118
        let tiles: [Widget?] = extras.map { extra in
            let (cage, image) = framedImage(width: width, height: height, style: "swiftly-plakat")
            if let address = addresses.flatMap({ ImageSelection.landscape(extra, addresses: $0, width: Scaling.requestEdge(width))?.url }) {
                imageLoad(image, url: address, key: ImageKey.of(address),
                          border: Scaling.imageEdge(width))
            } else {
                characterPut(cage, series: false)
            }
            // An extra without runtime reports 0, not nothing; then no line is shown.
            let bottom: String? = DisplayRules.runtimeShow(seconds: extra.runtimeSeconds)
                ? extra.runtimeSeconds.map { runtime($0) } : nil
            return tileWrapper(image: cage, width: width, top: extra.name, bottom: bottom) {
                [weak self] in self?.launch(extra, since: 0)
            }
        }
        return railBuild(title: title, imageHeight: height, piece: width + Theme.tileSpacing,
                          tiles: tiles)
    }

    private func tabContent(_ was: PageTab, series: Item, in space: Widget!) {
        wipe(space)
        switch was {
        case .episodes:
            // **Empty, but with reserved space** (iPhone). While loading, the height of the
            // season picker stays free; picker and episodes then fade in at their place. The
            // three episode placeholders are gone: the list is last on the page, so nothing
            // below it jumps.
            append(space, seasonPickerSpace())
        case .cast:
            if series.actors.isEmpty {
                let empty = label(translated("Keine Besetzung hinterlegt."), style: "swiftly-koerper")
                gtk_widget_set_margin_start(empty, Int32(Theme.edgeSpacing))
                append(space, empty)
            } else {
                append(space, castRail(series.actors, origin: series.name))
            }
        case .extras:
            // Stays empty until ``extrasLoadMore`` finds extras.
            break
        case .similarOne:
            // Stays empty until ``seriesLoadMore`` answers: no placeholder and no "Nothing
            // similar" while loading.
            break
        }
    }

    /// The free space of the season picker: chip height 30 plus the 18 below it
    /// (``seasonsShow``).
    private func seasonPickerSpace() -> Widget! {
        let slot = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(slot, -1, 30)
        gtk_widget_set_margin_bottom(slot, 18)
        return slot
    }

    // MARK: Seasons and episodes

    /// **One fade-in, not five** (iPhone `SeriesDetailView.load`).
    ///
    /// The page used to apply each response separately: first the season picker, then
    /// the episodes with their own placeholder, and "Similar" only when someone opened
    /// the tab. Now state, seasons, the episodes of the selected season and similar
    /// titles arrive together and fade in together. The plan runs alongside
    /// (``planLoadMore``) and fades in only the badge whose slot already exists.
    ///
    /// - Parameter aehnliches: `nil` when retrying after a failure; the fetch then
    ///   covers only the seasons.
    private func seriesLoadMore(_ series: Item, episodes space: Widget!, similarOne similarArea: Widget?) {
        guard let client else { return }
        let id = startSeason
        let number = startSeasonNumber
        // **The state only if no hint was given.** A fetch nobody reads costs one request
        // on every series page.
        let needsState = SeasonSelectionRule.needsState(hintID: id, hintNumber: number)

        // **Already fetched means immediately present.** No loader, no jump; "Similar"
        // sits in a different tab and arrives on its own.
        if let already = seasonCache[series.id], !already.isEmpty, !needsState {
            seasonsShow(already, series: series, in: space,
                           selected: SeasonSelectionRule.choose(from: already, hintID: id,
                                                             hintNumber: number))
            if let similarArea { similarLoadMore(series, in: similarArea, wipe: true, asGrid: true) }
            return
        }
        let container = held(space)
        let aBox = similarArea.map(held)
        Task.detached { [self] in
            // All in the background: state, seasons and similar titles do not depend on each
            // other; only the episodes need the selected season.
            //
            // **Separate tasks instead of `async let`** (see ``nebenher(_:)``). Exactly these
            // three as `async let` crashed the Windows app when opening any series.
            let seasonsRaw = besideFrom { try? await client.seasons(seriesID: series.id) }
            let stateRaw = needsState ? besideFrom { await client.stateInSeries(series.id) } : nil
            let similarRaw = aBox == nil ? nil
                : besideFrom { try? await client.similar(itemID: series.id, toward: series) }
            // **`nil` means failed, `[]` means truly empty**, and a failed fetch is not
            // remembered.
            let fetched = await seasonsRaw.value
            let seasons = fetched ?? []
            let state = await stateRaw?.value ?? nil
            let selected = SeasonSelectionRule.choose(from: seasons, hintID: id,
                                                   hintNumber: number, state: state)
            // The episodes of the season that is shown right now; ``seasonsShow`` takes
            // the same.
            let first = selected ?? seasons.first
            let episodes: [Item]? = await {
                guard let first else { return nil }
                return try? await client.episodes(seriesID: series.id, seasonID: first.id)
            }()
            let similar: [Item]?? = if let similarRaw { .some(await similarRaw.value) } else { .none }
            postPush {
                defer {
                    letGo(container)
                    if let aBox { letGo(aBox) }
                }
                if let aBox, let similar {
                    self.similarShow(similar, title: series, in: aBox.widget,
                                         wipe: true, asGrid: true)
                    gtk_widget_set_opacity(aBox.widget, 0)
                    crossfade(aBox.widget, on: 1, duration: Theme.timeFadeFromIn)
                }
                guard fetched != nil else {
                    wipe(container.widget)
                    append(container.widget, self.disturbHint { [weak self] in
                        guard let self, let space = container.widget else { return }
                        wipe(space)
                        append(space, self.seasonPickerSpace())
                        self.seriesLoadMore(series, episodes: space, similarOne: nil)
                    })
                    return
                }
                self.seasonCache[series.id] = seasons
                if let first, let episodes { self.episodeStore[first.id] = episodes }
                self.seasonsShow(seasons, series: series, in: container.widget,
                                    selected: selected)
                gtk_widget_set_opacity(container.widget, 0)
                crossfade(container.widget, on: 1, duration: Theme.timeFadeFromIn)
            }
        }
    }

    private func seasonsShow(_ seasons: [Item], series: Item, in space: Widget!,
                                selected: Item?) {
        wipe(space)
        guard !seasons.isEmpty else {
            append(space, emptyHint(translated("Keine Folgen")))
            return
        }
        // **Which season is shown is decided by how the user got to the page.** The
        // computation lives in the package (`SeasonSelectionRule`) so every platform gives the
        // same answer. Before, it was only an id comparison with fallback to `seasons[0]`,
        // i.e. season 1, while the main button next to it said "Continue S6E1".
        let choice = SeasonSelection()
        choice.now = selected ?? seasons[0]
        openSeason = choice.now

        // **With a chevron, and it shows the state.** On the Mac the chip carries
        // `chevron.down`, open `chevron.up` (`SeriesView.swift:548`); a bare text label
        // gives no hint that it expands.
        let pill: Widget! = gtk_button_new()
        gtk_widget_add_css_class(pill, "swiftly-chip")
        gtk_widget_set_halign(pill, GTK_ALIGN_START)
        let pillsContent = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let pillsText = label(choice.now?.name ?? translated("Staffel"))
        // A chevron, not an arrow; `chevron.down` on the Mac.
        let pillsAngle: Widget! = gtk_image_new_from_icon_name("pan-down-symbolic")
        append(pillsContent, pillsText)
        append(pillsContent, pillsAngle)
        gtk_button_set_child(asButton(pill), pillsContent)
        // A choice exists only with more than one season.
        // **With one season there is nothing to choose.** The Mac hides the pill then;
        // leaving it greyed out looks like a stuck button.
        // The label stays even with one season; only the chevron is dropped, since there
        // is nothing to choose.
        gtk_widget_set_visible(pill, seasons.isEmpty ? 0 : 1)
        gtk_image_set_pixel_size(OpaquePointer(pillsAngle), 11)

        let episodesSpace = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)

        // **An in-place list, not a sheet.**
        //
        // A `GtkPopover` was used here, with a comment claiming the Mac shows a sheet. It
        // does not: `Staffelwahl` (`Sources/macOS/SeriesView.swift:541`) opens the list
        // **in the page flow** below the chip, and its doc comment says why: a `Menu` would
        // be the obvious choice and exactly therefore wrong, as it brings system
        // measurements, corners and material. A GTK popover brings the same three things.
        // That everything below moves along is not a side effect but the template's
        // behaviour.
        //
        // 220 wide, 4 vertical inner padding, `erhoeht` with `eckeFeld` and a hairline, all
        // from `SeriesView.swift:554-566`.
        let selectionBlock = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_halign(selectionBlock, GTK_ALIGN_START)
        append(selectionBlock, pill)

        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(list, "swiftly-staffelliste")
        gtk_widget_set_size_request(list, 220, -1)
        gtk_widget_set_halign(list, GTK_ALIGN_START)

        // The Mac slides it in from above with `Theme.zeitSprung` (snappy, 0.22 s) while
        // fading it in; a `GtkRevealer` with `SLIDE_DOWN` is the closest counterpart.
        let expand: Widget! = gtk_revealer_new()
        gtk_revealer_set_transition_type(asExpand(expand),
                                         // **Grows out of the button** (Mac): fade-in plus the expand animation in the
                                         // stylesheet, no sliding down.
                                         GTK_REVEALER_TRANSITION_TYPE_CROSSFADE)
        gtk_revealer_set_transition_duration(asExpand(expand), 220)
        gtk_revealer_set_child(asExpand(expand), list)
        gtk_widget_set_margin_top(expand, 8)
        gtk_widget_set_halign(expand, GTK_ALIGN_START)
        // **When closed it is gone, not just transparent.** A revealer keeps the full
        // height of its list when closed (measured headless: 336 points with eight
        // seasons), which was the huge gap between season picker and first episode. It
        // becomes visible on expanding and invisible once collapsing finishes.
        gtk_widget_set_visible(expand, 0)
        let expandBox = held(expand)
        onProperty(UnsafeMutableRawPointer(expand), "notify::child-revealed") {
            guard let a = expandBox.widget,
                  gtk_revealer_get_child_revealed(asExpand(a)) == 0,
                  gtk_revealer_get_reveal_child(asExpand(a)) == 0 else { return }
            gtk_widget_set_visible(a, 0)
        }
        signal(expand, "destroy") { letGo(expandBox) }
        append(selectionBlock, expand)

        // **Created once, not on every click.** Previously each click created a new panel
        // that stayed attached to the button; when leaving the page GTK reported
        // "Finalizing GtkButton, but it still has children left" and left a dangling
        // pointer. This is what crashed the app when opening a series.
        var rows: [String: Widget?] = [:]
        for season in seasons {
            let row = seasonRow(season.name,
                                     selected: season.id == choice.now?.id) { [weak self] in
                guard let self else { return }
                choice.now = season
                self.openSeason = season
                self.detailTouched = true
                gtk_label_set_text(OpaquePointer(pillsText), season.name)
                for (identifier, w) in rows {
                    self.seasonRowDraw(w, selected: identifier == season.id)
                }
                gtk_widget_remove_css_class(list, "swiftly-offen")
                gtk_revealer_set_reveal_child(asExpand(expand), 0)
                gtk_image_set_from_icon_name(OpaquePointer(pillsAngle), "pan-down-symbolic")
                self.episodesLoad(series: series, season: season, in: episodesSpace)
            }
            rows[season.id] = row
            append(list, row)
        }

        signal(pill, "clicked") {
            // It opens even with a single season: the chip says which season is shown.
            let opened = gtk_revealer_get_reveal_child(asExpand(expand)) == 0
            if opened { gtk_widget_set_visible(expand, 1) }
            // The class triggers the expand animation in the stylesheet.
            if opened { gtk_widget_add_css_class(list, "swiftly-offen") }
            else { gtk_widget_remove_css_class(list, "swiftly-offen") }
            gtk_revealer_set_reveal_child(asExpand(expand), opened ? 1 : 0)
            gtk_image_set_from_icon_name(OpaquePointer(pillsAngle),
                                         opened ? "pan-up-symbolic" : "pan-down-symbolic")
        }

        // **The season picker stands alone and left-aligned**: the "Download season" chip
        // is gone, and with it the row that held it next to the picker. Downloading goes
        // through the button in the button row (``loadSelectionShow(_:an:)``). 18 below the
        // picker.
        seasonLoadButton = nil
        gtk_widget_set_margin_start(selectionBlock, Int32(Theme.edgeSpacing))
        // 14 to the first row plus its 12 padding, as on the iPhone
        // (`SeriesView.episodesList`) and the Mac. The tab area's spacing (18) does not apply
        // here, otherwise both would stack.
        gtk_box_set_spacing(asBox(space), 0)
        gtk_widget_set_margin_bottom(selectionBlock, 14)
        append(space, selectionBlock)
        append(space, episodesSpace)
        if let now = choice.now {
            episodesLoad(series: series, season: now, in: episodesSpace)
        }
    }

    /// **If the season is already fully downloaded, the chip is dropped**, as on the Mac
    /// (`SeriesView.swift:46-50`, `staffelVollstaendig`).
    func seasonLoadButtonDraw() {
        guard let button = seasonLoadButton else { return }
        let opened = seasonEpisodes.contains { downloads.entries(for: $0.id) == nil }
        gtk_widget_set_visible(button, (downloadButtonShow && !seasonEpisodes.isEmpty && opened) ? 1 : 0)
    }

    /// A row in the season list: name on the left, checkmark for the selected one.
    ///
    /// **The checkmark is always present and only hidden.** The selection must be able
    /// to move without rebuilding the row now that the list is built once instead of on
    /// every click; otherwise the list would show two checkmarks on the second open.
    /// Internal: the player's episode layer (`PlayerLayers.swift`) builds its season
    /// list from the same row, literally, not a copy.
    func seasonRow(_ text: String, selected: Bool,
                              _ pick: @escaping () -> Void) -> Widget! {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-handlung")
        gtk_widget_add_css_class(button, "swiftly-staffelzeile")
        if selected { gtk_widget_add_css_class(button, "swiftly-aktiv") }
        help(button, selected: selected)
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let l = label(text, style: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        append(rail, l)
        // 12 bold, like `SeasonRow` on the Mac (`SeriesView.swift:592`).
        let checkmark: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(checkmark), 12)
        gtk_widget_set_visible(checkmark, selected ? 1 : 0)
        append(rail, checkmark)
        gtk_button_set_child(asButton(button), rail)
        signal(button, "clicked", pick)
        return button
    }

    /// Moves the selection on an existing row: accent on, checkmark on.
    func seasonRowDraw(_ row: Widget?, selected: Bool) {
        guard let row else { return }
        if selected { gtk_widget_add_css_class(row, "swiftly-aktiv") }
        else        { gtk_widget_remove_css_class(row, "swiftly-aktiv") }
        help(row, selected: selected)
        // Button → row → (label, checkmark). The checkmark is the last child.
        guard let rail = gtk_button_get_child(asButton(row)),
              let checkmark = gtk_widget_get_last_child(rail) else { return }
        gtk_widget_set_visible(checkmark, selected ? 1 : 0)
    }

    private func episodesLoad(series: Item, season: Item, in space: Widget!) {
        guard let client else { return }
        if let already = episodeStore[season.id] {
            episodesShow(already, in: space)
            // **The cache shows immediately, the server is right.** What is there comes from
            // the last visit; someone who kept watching on their phone in the meantime saw
            // neither bar nor remaining time. Fetch fresh and update the rows in place, with no
            // rebuild, so the list does not jump.
            Task.detached { [self] in
                guard let freshValue = try? await client.episodes(seriesID: series.id,
                                                            seasonID: season.id) else { return }
                postPush {
                    self.episodeStore[season.id] = freshValue
                    for f in freshValue { self.watchStateRows[f.id]?.refresh(f) }
                }
            }
            return
        }
        // **No placeholders**: the existing list stays until the new one is there, which
        // then fades in.
        let container = held(space)
        Task.detached { [self] in
            let fetched = try? await client.episodes(seriesID: series.id,
                                                  seasonID: season.id)
            postPush {
                defer { letGo(container) }
                // **Failed is not empty**: "No episodes" would claim the server has none, when it
                // just did not answer.
                guard let episodes = fetched else {
                    wipe(container.widget)
                    self.seasonEpisodes = []
                    append(container.widget, self.disturbHint { [weak self] in
                        self?.episodesLoad(series: series, season: season, in: container.widget)
                    })
                    return
                }
                self.episodeStore[season.id] = episodes
                self.episodesShow(episodes, in: container.widget)
                gtk_widget_set_opacity(container.widget, 0)
                crossfade(container.widget, on: 1, duration: Theme.timeFadeFromIn)
            }
        }
    }

    /// Shows an episode list, from the network or from the cache.
    private func episodesShow(_ episodes: [Item], in space: Widget!) {
        wipe(space)
        // The "Download season" chip needs the list it should download.
        seasonEpisodes = episodes
        seasonLoadButtonDraw()
        guard !episodes.isEmpty else {
            // **Empty is information, not an empty box.** Otherwise nothing shows and it looks
            // like an error.
            let l = label(translated("Keine Folgen"), style: "swiftly-koerper")
            gtk_widget_add_css_class(l, "swiftly-leise")
            gtk_widget_set_halign(l, GTK_ALIGN_CENTER)
            gtk_widget_set_margin_top(l, 40)
            gtk_widget_set_margin_bottom(l, 40)
            append(space, l)
            return
        }
        // **Step by step, not all at once.** A loop used to build every row in one go; for
        // a season of forty episodes that is an image, texts and buttons per row, all on the
        // main thread and all before the next frame, which made opening a long series
        // stutter. Now the first rows appear immediately (they are visible) and the rest
        // follows in small chunks, each after the next drawn frame (``postDeadline`` runs on
        // the frame clock).
        episodesLayout += 1
        let number = episodesLayout
        let immediate = App.episodesImmediate
        for episode in episodes.prefix(immediate) { append(space, episodeRow(episode)) }
        guard episodes.count > immediate else { return }
        let container = held(space)
        func proceed(since start: Int) {
            postDeadline(0) { [weak self] in
                guard let self, self.episodesLayout == number, let space = container.widget,
                      gtk_widget_get_parent(space) != nil else {
                    letGo(container)
                    return
                }
                let end = min(start + App.episodesJeStep, episodes.count)
                for episode in episodes[start..<end] { append(space, self.episodeRow(episode)) }
                if end < episodes.count { proceed(since: end) } else { letGo(container) }
            }
        }
        proceed(since: immediate)
    }

    /// This many episodes appear immediately; more do not fit under the header.
    static let episodesImmediate = 8
    /// And this many per step afterwards.
    static let episodesJeStep = 4

    /// An episode in the list. Image 160 × 90 (16 : 9), 18 gap, below it a header line
    /// with runtime on the right and two lines of description.
    ///
    /// **The episode's image, not the series'.** `ImageSelection.landscape` deliberately takes the
    /// series backdrop, which is right for "Continue watching" but wrong here: in an
    /// episode list every row would show the same image.
    /// Internal: the player's episode layer (`PlayerLayers.swift`) builds its list from
    /// the same row, literally, not a copy.
    ///
    /// - Parameter laeuft: Marks the row like the current episode in the player's
    ///   episode layer (`.swiftly-aktiv`, white at 8%).
    /// - Parameter aktion: By default a click starts the title fresh (`starte`, as on
    ///   the series page). The player's episode layer passes the switch in the running
    ///   player (`changeInto`) instead; otherwise a click there would close and reopen the
    ///   player rather than just swapping the episode.
    func episodeRow(_ episode: Item, running: Bool = false,
                     action: ((Item) -> Void)? = nil) -> Widget! {
        // **A gesture, not a button.** The row already contains a button (the toggle
        // checkmark), and a button inside a button is not a safe construction in GTK. The
        // Mac uses `.onTapGesture` for the same reason.
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 18)
        gtk_widget_add_css_class(row, "swiftly-folgenzeile")
        if running { gtk_widget_add_css_class(row, "swiftly-aktiv") }

        let (wrapper, image) = framedImage(width: 160, height: 90, style: "swiftly-plakat")
        gtk_widget_set_valign(wrapper, GTK_ALIGN_START)
        if let addresses, let mark = episode.imageTags?["Primary"],
           let url = addresses.construct(itemID: episode.id, mark: mark,
                                    mass: .atMostHigh(220)) {
            imageLoad(image, url: url, key: ImageKey.of(url))
        } else {
            characterPut(wrapper, series: true)
        }
        // **The thumbnail carries the watch state**, not the column on the right. It
        // already showed the progress bar ("how far am I"), and the checkmark is its end.
        // This puts the watch state in one place instead of two and leaves room on the
        // right for the download. Like this on the Mac (`SeriesView.swift:642`) and the
        // iPhone; on Linux the checkmark used to sit at the far end of the row.
        //
        // **A full bar and a checkmark would be the same information twice**, so the bar
        // shows only while not watched.
        var barParts: [Widget?] = []
        if selection.progressOnTiles, !episode.isWatched,
           let share = episode.watchedShare {
            barParts = barPut(wrapper, width: 160, share: share)
        }
        let imageCheckmark = watchedCheckmarkPut(wrapper, an: episode.isWatched)
        // **A play icon over the image when the pointer is there**; the Mac has it
        // (`SeriesView.swift:665-674`). Without it a still does not look clickable.
        let circle: Widget! = gtk_image_new_from_icon_name("media-playback-start-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(circle), 16)
        gtk_widget_add_css_class(circle, "swiftly-spielkreis")
        gtk_widget_set_halign(circle, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(circle, GTK_ALIGN_CENTER)
        // Always present, only invisible, so it can fade in instead of popping up
        // (`zeitSchweben`). Clicks pass through to the row.
        gtk_widget_set_opacity(circle, 0)
        gtk_widget_set_can_target(circle, 0)
        gtk_overlay_add_overlay(OpaquePointer(wrapper), circle)
        append(row, wrapper)

        let text = stack(GTK_ORIENTATION_VERTICAL, spacing: 5)
        gtk_widget_set_hexpand(text, 1)

        let header = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let number = episode.indexNumber.map { "\($0). " } ?? ""
        let name = label(number + episode.name, style: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(name), 1)
        gtk_widget_set_hexpand(name, 1)
        append(header, name)
        // **Started: remaining time instead of runtime**, like `EpisodesRow` on the iPhone
        // ("24 minutes left"). The bar in the image says how far, the text says how long
        // is left.
        func durationText(_ f: Item) -> String? {
            guard let seconds = f.runtimeSeconds, seconds > 0 else { return nil }
            return (f.isWatched ? nil : f.remainingTimeText) ?? runtime(seconds)
        }
        var durationField: Widget?
        if let text = durationText(episode) {
            let duration = label(text, style: "swiftly-zweitzeile")
            durationField = duration
            gtk_widget_add_css_class(duration, "swiftly-leise")
            append(header, duration)
        }
        append(text, header)

        if let content = episode.description, !content.isEmpty {
            let z = label(content, style: "swiftly-zweitzeile", wrap: true)
            gtk_widget_add_css_class(z, "dim-label")
            gtk_label_set_xalign(OpaquePointer(z), 0)
            gtk_label_set_lines(OpaquePointer(z), 2)
            gtk_label_set_ellipsize(OpaquePointer(z), PANGO_ELLIPSIZE_END)
            gtk_label_set_justify(OpaquePointer(z), GTK_JUSTIFY_LEFT)
            gtk_widget_set_size_request(z, 200, -1)
            append(text, z)
        }
        append(row, text)

        // **No checkmark button at the row end any more** (as on the Mac). It appeared
        // under the pointer and was a second way to set the watch state; the way is now
        // the tile menu (right click). The checkmark as *information* is on the image and
        // stays there, also under the pointer.
        var watched = episode.isWatched
        let calm = imageCheckmark

        // **No spinner per episode any more**: it was one of three ways to download and the
        // worst, with twenty-five episodes giving twenty-five of the same. To download a
        // single episode, tick it in the download selection ("Download" button in the
        // button row).

        // **After the player, the row refreshes itself**: bar, checkmark, button and the
        // target of a click. Previously `postPlayerRefresh` rebuilt the whole series
        // page, which jumped to the top. Now scroll position, season and focus stay.
        var current = episode
        var hovers = false
        // **Keyboard focus counts like the pointer.** The toggle checkmark only shows on
        // hover; someone arriving with Tab would never see it or reach it.
        var focused = false
        // One name instead of four fragments: number, title, and how far.
        func rename() {
            let parts = [number + current.name,
                         watchStateWord(watched: watched, share: current.watchedShare)]
            help(row, name: parts.compactMap { $0 }.joined(separator: ", "),
                        selected: running)
        }
        rename()
        let mark = nextWatchStateMark()
        watchStateRows[episode.id] = (mark, { [weak self] new in
            guard let self else { return }
            current = new
            for part in barParts { gtk_overlay_remove_overlay(OpaquePointer(wrapper), part) }
            barParts = []
            if self.selection.progressOnTiles, !new.isWatched, let share = new.watchedShare {
                barParts = barPut(wrapper, width: 160, share: share)
            }
            watched = new.isWatched
            imageDim(wrapper, watched)
            gtk_widget_set_visible(calm, watched ? 1 : 0)
            if let inputField = durationField, let text = durationText(new) {
                gtk_label_set_text(OpaquePointer(inputField), text)
            }
            rename()
        })
        signal(row, "destroy") { [weak self] in
            if self?.watchStateRows[episode.id]?.mark == mark { self?.watchStateRows[episode.id] = nil }
        }

        // Pointer or focus: same highlight, same checkmark.
        func frontShow() {
            let front = hovers || focused
            if front { gtk_widget_add_css_class(row, "swiftly-schwebt") }
            else { gtk_widget_remove_css_class(row, "swiftly-schwebt") }
            crossfade(circle, on: front ? 1 : 0, duration: Theme.timeFloat)
        }
        // The download button stays. It used to be hidden on leave, and as soon as its
        // panel opened the pointer left the row, the button vanished and took the panel
        // with it. That looked like "nothing happened".
        onPointer(row, inward: { hovers = true; frontShow() },
                         out: { hovers = false; frontShow() })
        focus(row, inward: { focused = true; frontShow() },
                        out: { focused = false; frontShow() })

        // **An episode from the list starts at its own position**, or, in the player's
        // episode layer, the running player switches to it.
        onClick(row, keyboard: true) { [weak self] in
            if let action { action(current) } else { self?.launch(current) }
        }
        // **The tile menu on every episode** (Apple `.tileMenu(episode, …)` in
        // `SeriesView` and in the player's episode list): right click, long press or menu
        // key. On the series page the same entries as on a tile, including "Watch
        // together" which was previously alone; in the player's episode layer only the
        // watch state.
        let imageAddressValue: URL? = addresses.flatMap { a in
            episode.imageTags?["Primary"].flatMap {
                a.construct(itemID: episode.id, mark: $0, mass: .atMostHigh(220))
            }
        }
        let inPlayer = action != nil
        tileMenuCreate(row) { [weak self] in
            TileMenuDetail(item: current, landscape: true, image: imageAddressValue, inPlayer: inPlayer,
                              afterwards: { new in
                                  guard let self else { return }
                                  self.watchStateRows[new.id]?.refresh(new)
                                  // The series' main button may now point elsewhere.
                                  self.headerRefresh?.perform()
                              })
        }
        return row
    }

    // MARK: Cast and similar

    func castRail(_ folks: [Person], origin: String? = nil,
                         margin: Int = Theme.edgeSpacing) -> Widget! {
        let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 14)
        let title = label(translated("Besetzung"), style: "swiftly-listentitel")
        gtk_label_set_xalign(OpaquePointer(title), 0)
        gtk_widget_set_margin_start(title, Int32(margin))
        append(block, title)

        let scroller = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(scroller),
                                       GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 18)
        gtk_widget_set_margin_start(rail, Int32(margin))
        gtk_widget_set_margin_end(rail, Int32(margin))
        for person in folks { append(rail, headerImage(person, origin: origin)) }
        gtk_scrolled_window_set_child(OpaquePointer(scroller), rail)
        append(block, scroller)
        return block
    }

    /// A head: 84 round, name and role below.
    private func headerImage(_ person: Person, origin: String?) -> Widget! {
        // **A button so that `:hover` applies.** GTK tracks the state only on controls; on a
        // plain box the image would never grow. Same wrapper as the tiles.
        let wrapperButton: Widget! = gtk_button_new()
        gtk_widget_add_css_class(wrapperButton, "swiftly-kachel")
        gtk_widget_set_valign(wrapperButton, GTK_ALIGN_START)

        let tile = stack(GTK_ORIENTATION_VERTICAL, spacing: 7)
        gtk_widget_set_size_request(tile, 84, -1)
        gtk_widget_set_valign(tile, GTK_ALIGN_START)

        let (wrapper, image) = framedImage(width: 84, height: 84, style: "swiftly-kopfbild")
        gtk_widget_add_css_class(wrapper, "swiftly-plakat")
        append(tile, wrapper)
        if let addresses, let mark = person.primaryImageTag,
           let url = addresses.construct(itemID: person.id, mark: mark,
                                    mass: .atMostHigh(200)) {
            imageLoad(image, url: url, key: ImageKey.of(url))
        } else {
            characterPut(wrapper, series: false)
        }

        let name = label(person.name, style: "swiftly-zweitzeile")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(name), 1)
        append(tile, name)

        if let role = person.role, !role.isEmpty {
            let r = label(role, style: "swiftly-zweitzeile")
            gtk_widget_add_css_class(r, "swiftly-leise")
            gtk_label_set_xalign(OpaquePointer(r), 0)
            gtk_label_set_ellipsize(OpaquePointer(r), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(OpaquePointer(r), 1)
            append(tile, r)
        }
        gtk_button_set_child(asButton(wrapperButton), tile)
        // **It used to do nothing.** The button was built, lifted on hover and did nothing,
        // the same shape a tester reported on tvOS. The origin is passed along so the
        // person page can say "role in title".
        signal(wrapperButton, "clicked") { [weak self] in
            self?.openPerson(person, origin: origin)
        }
        return wrapperButton
    }

    /// **A grid on the series page, a row on the movie page.**
    ///
    /// The Mac makes the same distinction (`SeriesView.swift:390-411` versus
    /// `DetailView`): under an explicitly chosen tab everything is there at once, and a
    /// row you must scroll through would be in the way. On the movie page "Similar"
    /// runs along under the rest of the content and must not take half the page.
    func similarLoadMore(_ title: Item, in space: Widget!, wipe empty_: Bool = false,
                            margin: Int = Theme.edgeSpacing, asGrid: Bool = false) {
        guard let client else { return }
        let container = held(space)
        Task.detached { [self] in
            // **With the title itself as the seed**: if it is in two libraries, its copy
            // would otherwise appear under "Similar".
            let fetched = try? await client.similar(itemID: title.id, toward: title)
            postPush {
                defer { letGo(container) }
                self.similarShow(fetched, title: title, in: container.widget, wipe: empty_,
                                     margin: margin, asGrid: asGrid)
            }
        }
    }

    /// Fills the slot with a response, from ``similarLoadMore`` or from the series
    /// page's shared fetch (``seriesLoadMore``).
    func similarShow(_ fetched: [Item]?, title: Item, in target: Widget!, wipe empty_: Bool,
                         margin: Int = Theme.edgeSpacing, asGrid: Bool) {
        // Remove duplicate ids, the same rule as in search and home.
        let hit = ListRules.withoutDouble(fetched ?? [])
        if empty_ { wipe(target) }
        // As a tab, the whole content would otherwise be empty, so a failed fetch says so.
        // As a row on the movie page the section simply disappears, as there.
        if fetched == nil, empty_ {
            let container = PointerBox(target)
            append(target, disturbHint { [weak self] in
                guard let self, let space = container.widget else { return }
                self.similarLoadMore(title, in: space, wipe: true,
                                        margin: margin, asGrid: asGrid)
            })
            return
        }
        guard !hit.isEmpty else {
            if empty_ {
                // Centred, with an icon, like every other empty state.
                //
                // **`mail-inbox-symbolic`, not `mail-archive`.** The Mac uses `tray`
                // (`SeriesView.swift:392`), and under Breeze only the inbox has the tray;
                // `mail-archive-symbolic` does not exist there, and GTK showed the fallback image
                // with a red prohibition sign. `EmptyHint`, as on the Mac: an empty section
                // inside the page.
                append(target, self.emptyHint(translated("Nichts Ähnliches gefunden")))
            }
            return
        }
        if asGrid {
            let grid = self.gridBuild()
            gtk_widget_set_margin_start(grid, Int32(margin))
            gtk_widget_set_margin_end(grid, Int32(margin))
            self.gridFill(grid, hit)
            append(target, grid)
        } else {
            append(target, self.railBuild(title: translated("Ähnliches"), art: .new,
                                            items: hit, margin: margin))
            // A separate slot on the movie page stays invisible until here, so it brings no
            // spacing.
            gtk_widget_set_visible(target, 1)
        }
    }
}


/// Which season is selected. A class like ``Spielziel`` so panel and pill see the
/// same value; touched only on GTK's main thread.
final class SeasonSelection: @unchecked Sendable {
    var now: Item?
}
