import CGtk
import Foundation
import JellyfinKit

/// **The detail page.** Movie and series share the same header, as decided on
/// iPhone. Only what stands below differs.
///
/// Every number below comes from `Sources/macOS/DetailView.swift`, `Backdrop.swift`
/// and `MacComponents.swift`. Where something deviates, the reason is next to it.
extension App {

    // MARK: - In and out

    /// Opens a title on the stack of the visible area.
    ///
    /// **An episode gets no page of its own**: every path to an episode leads to the
    /// series page with the episode's season selected. ``detailShow(_:)`` decides
    /// this when building.
    func openIt(_ item: Item) {
        // **A collection is not a detail page.** If the server groups movies into
        // collections, they appear as a tile in the library; this used to open the movie
        // page and show it empty. As on iPhone (`MainView`, `CollectionView(art: nil)`):
        // the collection page, without a kind, so everything in it.
        if item.type == "BoxSet" {
            collectionOpen(item, art: nil)
            return
        }
        // **A playlist** (search, watchlist): its page, all entries (macOS `PlaylistPage(art: nil)`).
        if item.type == "Playlist" {
            playlistOpen(item, art: nil)
            return
        }
        // **An episode gets no page of its own.** Every path to an episode (from "Zuletzt
        // hinzugefügt", from "Nächste Folge") leads to the **series page**, with the
        // episode's season already selected. A page for a single episode would show nothing
        // that is not in the episode list already.
        guard item.type == "Episode", let seriesKeyID = item.seriesId, let client else {
            startSeason = nil
            startSeasonNumber = nil
            pagesStack[section, default: []].append(item)
            detailShow(item)
            return
        }
        // **Fetch the season fresh; do not trust the tile.** The list entry carries the
        // season it had when loaded; after finishing a season and adding the next, it would
        // still show the old one. Same remedy as on the Mac (`SeasonTarget`).
        // **What hovering already fetched is available immediately**, see
        // ``seriesPrefetch(_:)``. Without that, every click repeated the same request.
        let already = fullCache[seriesKeyID]
        Task.detached { [self] in
            // Separate tasks instead of `async let` (see ``nebenher(_:)``).
            let freshValue = besideFrom { try? await client.item(id: item.id) }
            let series = already == nil ? besideFrom { try? await client.item(id: seriesKeyID) } : nil
            let f = await freshValue.value
            let s = await series?.value ?? already
            onMainThread {
                guard let s else { return }
                // **Fetch both fresh, ID and number.** The Mac used to refetch only the ID
                // (`SeasonTarget.freshSeasonID`); if the server returns no `SeasonId` on an
                // episode (a measured case), only the number carries the comparison, and that
                // would have been the stale one. The Mac now refreshes both.
                self.startSeason = f?.seasonId ?? item.seasonId
                self.startSeasonNumber = f?.parentIndexNumber ?? item.parentIndexNumber
                self.pagesStack[self.section, default: []].append(s)
                self.detailShow(s)
            }
        }
    }

    func back() {
        guard var myOwn = pagesStack[section], !myOwn.isEmpty else { return }
        myOwn.removeLast()
        pagesStack[section] = myOwn
        if let top = myOwn.last {
            detailShow(top, push: .back)
        } else {
            sectionShow(section.identifier, push: .back)
        }
    }

    /// Starts a title. **Only "Weiterschauen" takes this path**; everything else opens
    /// the overview first.
    ///
    /// **Without `since`, the server's position applies, fetched fresh** (as iOS
    /// `HomeView.starte`): the position in the tile is often stale, and someone who
    /// continued on the phone would otherwise see a stretch twice.
    func launch(_ item: Item, since: Double? = nil) {
        playerOpen(item, since: since ?? item.resumeFrom ?? 0, pointFresh: since == nil)
    }

    // MARK: - Layout

    func detailShow(_ item: Item, push: Push = .deeper) {
        // **A person is not a detail page**: no main button, no action row, no file. The
        // switch sits here and not at the caller, so every path to a person yields the same
        // page no matter who takes it.
        if item.type == "Person" {
            personPageShow(item, push: push)
            return
        }
        if item.type == "Playlist" {
            playlistPageShow(item, push: push)
            return
        }
        detailTouched = false
        sections = []
        let disc = nextDisc()

        let page = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        // **One box paints the tone, not two.**
        //
        // Header zone and lower part used to carry it separately: two same-colored surfaces
        // that abut. A line appeared exactly at their edge, persistently: on open, on
        // scrolling, and gone after scrolling back and forth. That is not a color error, it
        // is the edge itself: GTK draws the edges of two boxes separately, and where they
        // meet the background shows through on half a pixel.
        //
        // Without the edge, nothing can show through. The gradient is now **one** paint over
        // the whole page: tone over the header zone's height, then 260 points to `reason`,
        // the same length as on the Mac.
        // **The header image's color under the whole page** (as iPhone and Mac `MoodReason`):
        // one class per page, so the new page does not slide in with the previous page's
        // color (``Tonblatt``). `swiftly-bildton` carries what applies on image colors:
        // buttons white at 8 %.
        let classKind = AudioSheet.newClass()
        gtk_widget_add_css_class(page, "swiftly-bildton")
        gtk_widget_add_css_class(page, classKind)

        // **The tone sits on its own layer under the page** and fades in when it arrives
        // after opening, as on Apple (`MoodLoader`, 0.55 s). The page used to carry it as
        // a background image and it jumped: a `transition` on `background-image` does not
        // take effect in GTK when a rule is newly added. A layer's opacity fades reliably.
        // The ground below (`situations`) is `reason`; the page itself is transparent. The page
        // measures, the layer follows it.
        let audioStatus: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_add_css_class(audioStatus, "swiftly-seitenton")
        gtk_widget_add_css_class(audioStatus, classKind)
        gtk_widget_set_can_target(audioStatus, 0)
        let situations: Widget! = gtk_overlay_new()
        gtk_widget_add_css_class(situations, "swiftly-seitenton")
        gtk_overlay_set_child(OpaquePointer(situations), audioStatus)
        gtk_overlay_add_overlay(OpaquePointer(situations), page)
        gtk_overlay_set_measure_overlay(OpaquePointer(situations), page, 1)
        AudioSheet.statusRemember(audioStatus, classKind: classKind)
        if let already = AudioSheet.remembers(item.id) {
            AudioSheet.setDown(already, classKind: classKind)
        } else {
            gtk_widget_set_opacity(audioStatus, 0)
        }

        // **The tone belongs to the header, not the page.**
        //
        // On the Mac it is a `.background` on the `ScrollView` and stays put while the content
        // scrolls away. That works there because the fades **mask** the image: it becomes
        // transparent, so what lies underneath does not matter.
        //
        // Here it is painted over. So the color must match the background at every point, and
        // a fixed background under a scrolling image cannot guarantee that. That is the line
        // at the bottom edge.
        //
        // So the header zone carries its tone itself, uniformly, and below it sits its own
        // fade-out of 260 points to `reason`, the same length as on the Mac. Both scroll with
        // the content, so nothing is ever beside anything. Difference from the Mac: there the
        // tone stays at the window's top edge on long scrolls; here it disappears with the header zone.

        let scroller = pagesScroller()
        gtk_scrolled_window_set_child(OpaquePointer(scroller), situations)
        detailScroller = scroller
        signal(scroller, "destroy") { [weak self] in
            if self?.detailScroller == scroller { self?.detailScroller = nil }
        }

        // **The back path belongs in the content, not the system bar.** It floats over the
        // page so it stays during scrolling; the title next to it fades in as soon as the
        // large title below disappears.
        let over: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(over), scroller)
        gtk_overlay_add_overlay(OpaquePointer(over), detailHeaderBuild(item))

        hintField = label("", style: "swiftly-hinweis")
        gtk_widget_set_visible(hintField, 0)
        gtk_widget_set_halign(hintField, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(hintField, GTK_ALIGN_END)
        gtk_widget_set_margin_bottom(hintField, 32)
        gtk_overlay_add_overlay(OpaquePointer(over), hintField)
        // **The field dies with the page.** Without this, `hintField` pointed into the void
        // after leaving the page, and a late error (series page, ``report(_:)`` after a
        // response) or the fade-out deadline touched freed memory: a crash that only happens
        // when going back fast enough.
        let it = hintField
        signal(hintField, "destroy") { [weak self] in
            if self?.hintField == it { self?.hintField = nil }
        }
        append(detailWrapper, over)

        // The thin list entry shows immediately, the full record follows. **The header has
        // fixed positions**: nothing moves when text arrives, so it may arrive whenever.
        buildUpWith(item, in: page, thin: true)
        titleLoadMore(item, in: page)
        // Fade in the title at the top once the large one disappears under the bar: from
        // 98 − 24 = 74, over the 42 points of its height.
        let verticalRight = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))!
        signalRaw(UnsafeMutableRawPointer(verticalRight), "value-changed") { [weak self] in
            guard let self, let header = self.detailHeaderTitle else { return }
            let v = gtk_adjustment_get_value(verticalRight)
            // **Where the bar starts, derived rather than estimated.** The large title begins 98
            // below the hero image's top edge and is 42 high; the bar is 24 high. Its top edge
            // reaches the bar's bottom edge at 98 − 24 = 74, and 42 later it is fully below.
            // The bar fades in over exactly this range.
            let strength = min(max((v - 74) / 42, 0), 1)
            gtk_widget_set_opacity(header, strength)
            if let bar = self.detailHeaderBar { gtk_widget_set_opacity(bar, strength) }
            if let history = self.detailHeaderHistory {
                gtk_widget_set_opacity(history, 1 - strength)
            }
        }

        // **Lay out first, then slide.** A page that still re-wraps during the slide stutters;
        // same as the Mac's "start once the page really stands".
        shove(toward: disc, bearing: push)
    }

    /// **A short message that goes away by itself.**
    ///
    /// The Mac has `Hinweisstreifen` for this: three seconds, then gone. Linux had nothing:
    /// "progress reset", "no trailer", "nothing comes after" were silently dropped and the
    /// user saw a button that seemingly did nothing.
    func report(_ text: String) {
        guard let inputField = hintField else { return }
        gtk_label_set_text(OpaquePointer(inputField), text)
        gtk_widget_set_visible(inputField, 1)
        gtk_widget_set_opacity(inputField, 1)
        hintTick += 1
        let mine = hintTick
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            onMainThread {
                guard self.hintTick == mine, self.hintField != nil else { return }
                gentle(on: self.hintField, from: 1, to: 0) {
                    gtk_widget_set_opacity(self.hintField, $0)
                }
            }
        }
    }

    /// **Everything below the description arrives at once** (iPhone
    /// `ItemDetailView.bottomPresent`).
    ///
    /// Cast, extras, part of the collection, similar titles and the file summary each had
    /// their own place and request; they arrived one by one, pressed into the page and
    /// pushed the rest ahead. Now the page waits for all responses and the plan and fades
    /// them in together with the evidence in the header: no placeholders, no empty hint
    /// while still loading. What is missing is missing as a row; there was no error notice
    /// here before either.
    private func bottomLoadMore(_ title: Item, in block: Widget!, proof: Widget!) {
        guard let client else { return }
        let blockBox = held(block)
        let genre = LibraryGenre.art(toType: title.type)
        // Same request as the badge above: no second POST.
        let plannedJob = planJob(title)
        Task.detached { [self] in
            // Separate tasks instead of `async let` (see ``nebenher(_:)``).
            let extraRaw = besideFrom { try? await client.extras(itemID: title.id) }
            let similarRaw = besideFrom { try? await client.similar(itemID: title.id, toward: title) }
            let collectionRaw = besideFrom {
                await self.collectionRailsFetch(title, art: genre, client: client)
            }
            let plan = await plannedJob?.value
            // Extras are not a section with a statement: if missing, the row is missing.
            let extras = (await extraRaw.value) ?? []
            // Drop duplicate IDs: same rule as search, home and watchlist (iPhone `ItemDetailView`).
            let similar = ListRules.withoutDouble((await similarRaw.value) ?? [])
            let collections = await collectionRaw.value
            postPush {
                defer { letGo(blockBox) }
                guard let block = blockBox.widget else { return }
                if !title.actors.isEmpty {
                    append(block, self.castRail(title.actors, origin: title.name))
                }
                if !extras.isEmpty {
                    append(block, self.extraRail(extras, title: translated("Extras")))
                }
                // Above "Ähnliches": the collection is the closer relation.
                for (collection, other) in collections {
                    if let genre {
                        append(block, self.collectionRail(collection, title: other, art: genre))
                    }
                }
                if !similar.isEmpty {
                    append(block, self.railBuild(title: translated("Ähnliches"), art: .new,
                                                     items: similar))
                }
                // **The file summary at the very bottom**: it answers a question asked only later.
                // The same plan carries the source, so the summary costs no second request.
                if let source = plan?.source {
                    let space = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
                    gtk_widget_set_margin_start(space, Int32(Theme.edgeSpacing))
                    gtk_widget_set_margin_end(space, Int32(Theme.edgeSpacing))
                    append(space, self.fileRow(source))
                    append(block, space)
                }
                // **One fade-in, not five.** The badge at the top comes on its own
                // (``planLoadMore``); it would otherwise wait for everything here.
                if gtk_widget_get_first_child(block) != nil {
                    gtk_widget_set_opacity(block, 0)
                    gtk_widget_set_visible(block, 1)
                    crossfade(block, on: 1, duration: Theme.timeFadeFromIn)
                }
            }
        }
    }

    /// **"Teil der Sammlung"**: the other titles of the collection in their order, above
    /// "Ähnliches", since the collection is the closer relation (Mac `Sammlungsreihe`).
    /// The header opens the collection page. At most two rows; if a movie is in more
    /// collections, the rest are usually auto-created duplicates. If the collection is
    /// missing, the row is missing, as with extras.
    ///
    /// The directory comes via ``offeringLoad(dann:)``, which calls back on the main
    /// thread; this request waits for it while the others run alongside.
    private func collectionRailsFetch(_ title: Item, art genre: String?,
                                      client: JellyfinClient) async -> [(ItemCollection, [Item])] {
        guard let genre else { return [] }
        let collections: [ItemCollection] = await withCheckedContinuation { done in
            onMainThread {
                self.offeringLoad {
                    guard self.offeringFor != nil, let directory = self.collectionDirectory else {
                        done.resume(returning: [])
                        return
                    }
                    done.resume(returning: Array(directory.collections(with: title).prefix(2)))
                }
            }
        }
        var found: [(ItemCollection, [Item])] = []
        for collection in collections {
            let source = ShelfSource(parent: collection.id, art: genre, collection: true)
            guard let list = try? await client.items(parentID: source.parent, limit: 100,
                                                      sortBy: Sorting.erscheinung.inputField,
                                                      sortOrder: source.bearing(.erscheinung),
                                                      recursive: source.recursive,
                                                      includeItemTypes: source.types).items
            else { continue }
            let other = ListRules.withoutDouble(list).filter { $0.id != title.id }
            if !other.isEmpty { found.append((collection, other)) }
        }
        return found
    }

    /// Header "Teil der Sammlung" with chevron, the name below, then the row.
    private func collectionRail(_ collection: ItemCollection, title: [Item], art genre: String) -> Widget! {
        let rail = railBuild(title: translated("Teil der Sammlung"), art: .new, items: title)
        // The row's heading becomes a button: title and chevron, the collection name below
        // (Mac: 5 between title and chevron, 2 between the lines, chevron 13 semibold, very
        // quiet, white under the pointer).
        guard let heading = gtk_widget_get_first_child(rail) else { return rail }
        g_object_ref(UnsafeMutableRawPointer(heading))
        gtk_box_remove(asBox(rail), heading)
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-sammlungskopf")
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        gtk_widget_set_margin_start(button, Int32(Theme.edgeSpacing))
        gtk_widget_set_margin_start(heading, 0)
        gtk_widget_set_margin_end(heading, 0)
        let column = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
        let top = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 5)
        append(top, heading)
        g_object_unref(UnsafeMutableRawPointer(heading))
        let angle: Widget! = gtk_image_new_from_icon_name("go-next-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(angle), 13)
        gtk_widget_set_valign(angle, GTK_ALIGN_CENTER)
        append(top, angle)
        append(column, top)
        let name = label(collection.item.name, style: "swiftly-koerper")
        gtk_widget_add_css_class(name, "dim-label")
        gtk_label_set_xalign(OpaquePointer(name), 0)
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        append(column, name)
        gtk_button_set_child(asButton(button), column)
        let item = collection.item
        signal(button, "clicked") { [weak self] in self?.collectionOpen(item, art: genre) }
        gtk_box_prepend(asBox(rail), button)
        // The row has a fixed height for a title line of 24; the name line comes on top.
        gtk_widget_set_size_request(rail, -1, -1)
        return rail
    }

    /// **The file summary: the evidence for this app's promise.**
    ///
    /// Container, resolution, codec, size, subtitle languages: this shows **why** direct
    /// play works. It was missing on Linux because `FileDetails` lived in `Sources/Shared`
    /// and was unreachable from here; it now lives in the package.
    ///
    /// The values come from the same source that carries the plan; nothing extra is fetched.
    func fileRow(_ source: MediaSource) -> Widget! {
        var parts: [String] = []
        // As on the Mac: the size is part of "MKV · 10,3 GB" and appears separately only if
        // the server names no container.
        if let container = FileDetails.container(source) {
            parts.append(container)
        } else {
            parts.append(FileDetails.size(source))
        }
        if let track = FileDetails.videoTrack(source) {
            parts.append(FileDetails.video(track, source))
        }
        let ut = FileDetails.subtitle(FileDetails.subtitleTracks(source))
        if !ut.isEmpty { parts.append(ut) }

        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 22)
        gtk_widget_add_css_class(rail, "swiftly-dateizeile")
        for text in parts where !text.isEmpty {
            let l = label(text, style: "swiftly-zweitzeile")
            gtk_widget_add_css_class(l, "swiftly-leise")
            append(rail, l)
        }
        return rail
    }

    private func titleLoadMore(_ item: Item, in page: Widget!) {
        guard let client else { return }
        // **The pointer crosses a thread boundary**, and Swift 6 insists on the box. It is
        // unpacked only in `onMainThread`, i.e. back on the thread GTK owns, which is the
        // guarantee ``Zeigerkiste`` gives.
        let container = held(page)
        Task.detached { [self] in
            let full = try? await client.item(id: item.id)
            // **Only once the page stands.** The full record rebuilds the whole page, header and
            // backdrop included, and almost always arrived mid-slide. That cost the frames in
            // which the page stopped after one or two centimeters (Mac: `InTravel`).
            postPush {
                defer { letGo(container) }
                // Only fill in if this page is still the topmost one.
                // **What the user has already chosen is not thrown away.** The full record arrives
                // later and replaced the whole page; anyone who had picked a season or tab meanwhile
                // saw it jump back. The Mac swaps only the title and keeps the state; here the page
                // is simply not rebuilt once someone has touched anything.
                guard self.pagesStack[self.section]?.last?.id == item.id else { return }
                // **Without a rebuild, the thin version loads its lower part itself.** Otherwise all
                // requests below would run twice: once for the thin page that vanishes right away,
                // and once for the full one.
                guard let full, !self.detailTouched else {
                    self.likesBase?()
                    self.likesBase = nil
                    return
                }
                self.likesBase = nil
                wipe(container.widget)
                self.buildUpWith(full, in: container.widget)
            }
        }
    }

    /// **Branch on `item.type`**, not on the fetched record: the kind is already in the
    /// list, and switching branches midway would mean discarding and rebuilding half the page.
    ///
    /// - Parameter mager: the list entry before the full record. The lower part then
    ///   stays a placeholder; it is built and loaded only when ``titleLoadMore``
    ///   returns without a rebuild (``likesBase``).
    private func buildUpWith(_ title: Item, in page: Widget!, thin: Bool = false) {
        // The full record as currently shown. The ``Fernsteuerpult`` needs it, because only
        // the thin list entry lies on the page stack, and that carries no cast.
        lastFullTitle = title
        occupiedRoom = nil
        append(page, heroHeader(title, classKind: AudioSheet.classKind(from: page)))


        // **The fade-out is a paint, not a widget.**
        //
        // It used to be its own box in an overlay behind the lower part, and a `GtkOverlay`
        // takes the height of its **main child**. That capped the whole page at 260 points
        // and scrolling stopped working. A background gradient on the lower part itself does
        // the same, lies behind the content on its own and measures nothing.
        let bottom = stack(GTK_ORIENTATION_VERTICAL, spacing: 26)
        // The space after the header zone. It may be a margin again: the tone lies on the
        // page, not on this box.
        gtk_widget_set_margin_top(bottom, 26)
        gtk_widget_set_margin_bottom(bottom, Int32(Theme.edgeSpacing))
        append(page, bottom)

        let proof = occupiedRoom
        likesBase = nil
        guard !thin else {
            // Held until the task runs or is discarded; the wrapper releases on discard.
            let slot = Retained(bottom)
            let occupiedSpot = proof.map(Retained.init)
            likesBase = { [weak self] in
                self?.baseBuild(title, in: slot.widget, proof: occupiedSpot?.widget)
            }
            return
        }
        baseBuild(title, in: bottom, proof: proof)
    }

    private func baseBuild(_ title: Item, in bottom: Widget!, proof: Widget!) {
        if title.type == "Series" {
            seriesBase(title, in: bottom)
        } else {
            // **One block for everything below the header**: cast, extras, part of the
            // collection, similar titles, and at the very bottom the file summary, in this order
            // as on the Mac. It stays invisible until all responses are in (``bottomLoadMore``).
            // The file summary only for movies: a series has no file, only its episodes do.
            let block = stack(GTK_ORIENTATION_VERTICAL, spacing: 26)
            gtk_widget_set_visible(block, 0)
            append(bottom, block)
            bottomLoadMore(title, in: block, proof: proof)
        }
    }

    // MARK: - Header bar with arrow

    /// Not `private`: the person page lives in its own file and needs the same header.
    /// `private` in an `extension` applies file-wide, and a second header would be the
    /// copied function the rule forbids.
    func detailHeaderBuild(_ item: Item) -> Widget! {
        // Height as on the Mac: 24 air, 40 button, 10 below the text.
        let header: Widget! = gtk_overlay_new()
        gtk_widget_set_valign(header, GTK_ALIGN_START)
        gtk_widget_set_halign(header, GTK_ALIGN_FILL)

        // While at the top: a soft gradient so the arrow stays readable on a bright image.
        // It is the main child and sets the height.
        let history: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_add_css_class(history, "swiftly-kopfverlauf")
        gtk_widget_set_size_request(history, -1, 74)
        gtk_overlay_set_child(OpaquePointer(header), history)

        // And the bar above it when scrolling.
        detailHeaderBar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_add_css_class(detailHeaderBar, "swiftly-kopfleiste")
        gtk_widget_set_opacity(detailHeaderBar, 0)
        gtk_overlay_add_overlay(OpaquePointer(header), detailHeaderBar)
        detailHeaderHistory = history

        let bar = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 4)
        gtk_widget_set_valign(bar, GTK_ALIGN_START)
        // Flush with the content: 24 minus the button's 8 inner padding.
        gtk_widget_set_margin_start(bar, Int32(Theme.edgeSpacing - 8))
        gtk_widget_set_margin_end(bar, Int32(Theme.edgeSpacing))
        // 24 puts the arrow at the same height where the sidebar carries its wordmark.
        gtk_widget_set_margin_top(bar, 24)

        let arrow: Widget! = gtk_button_new()
        gtk_widget_add_css_class(arrow, "swiftly-zurueck")
        caption(arrow, translated("Zurück"))
        gtk_button_set_child(asButton(arrow), gtk_image_new_from_icon_name("go-previous-symbolic"))
        signal(arrow, "clicked") { [weak self] in self?.back() }
        append(bar, arrow)

        detailHeaderTitle = label(item.seriesName ?? item.name, style: "swiftly-leistentitel")
        gtk_label_set_ellipsize(OpaquePointer(detailHeaderTitle), PANGO_ELLIPSIZE_END)
        gtk_widget_set_valign(detailHeaderTitle, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(detailHeaderTitle, 8)
        gtk_widget_set_opacity(detailHeaderTitle, 0)
        append(bar, detailHeaderTitle)

        gtk_overlay_add_overlay(OpaquePointer(header), bar)
        return header
    }

    // MARK: - Hero header

    /// Backdrop on the right, block on the left. Height 380 (`Theme.heroHeightValue`).
    private func heroHeader(_ title: Item, classKind: String?) -> Widget! {
        let header: Widget! = gtk_overlay_new()
        gtk_widget_set_hexpand(header, 1)

        // **The backdrop is the main child**: it sets the size (380 high) and paints itself,
        // masked instead of painted over. Why that makes the difference is explained in
        // ``Backdrop``.
        // **As tall as the header zone.**
        //
        // On the Mac the image is `heroHeightValue * 1,62` and so also lies behind the content below;
        // there it is a layer in the stack that measures nothing. In GTK the backdrop is the
        // overlay's main child and sets the height: with 1.62, tabs and episode list slid down
        // by 236 points. The mask ends the image softly anyway; the missing stretch behind it
        // is the smaller error. A faithful port needs a layer **under** the scroller, not in
        // the header.
        let image = Backdrop()
        image.withRemembered(title.id)
        gtk_overlay_set_child(OpaquePointer(header), image.display)
        gtk_overlay_add_overlay(OpaquePointer(header), heroBlock(title))

        audioAndImageLoadMore(title, in: image, classKind: classKind)
        return header
    }

    /// Fetches the header image and, from a tiny copy, its tone.
    ///
    /// **Both sizes from one hand.** There used to be two paths side by side: the large
    /// image via `headerImageFallback` with its fallback, the tiny one directly via
    /// `ImageSelection.landscape`. For a series without a backdrop, the first found the next episode's
    /// still and the second found nothing: image present, tone not, and a hard edge against
    /// the bare ground under the backdrop. The Mac does not have the case: **one** URL
    /// (`AppModel.headerImageURL`) serves both.
    private func audioAndImageLoadMore(_ title: Item, in backdrop: Backdrop, classKind: String?) {
        guard let addresses, let client else { return }
        Task.detached { [self] in
            // Small as on Apple: 48 points suffice for the tone histogram (`ImageTone.audioOut`).
            guard let pair = await client.headerImagePair(for: title, addresses: addresses, small: 48)
            else { return }
            if let classKind,
               let data = await ImageStorage.shared.load(pair.small,
                                                        key: ImageKey.of(pair.small)),
               let tones = ImageColor.tones(from: data) {
                // Reloading the stylesheet restyles every widget of the app (``Schubsperre``), so not
                // while the page is sliding. The layer fades in afterwards anyway.
                postPush {
                    let already = AudioSheet.remembers(title.id)
                    AudioSheet.remember(title.id, tones)
                    if already != tones { AudioSheet.setDown(tones, classKind: classKind) }
                    AudioSheet.reveal(classKind)
                }
            }
            guard let data = await ImageStorage.shared.load(pair.large,
                                                           key: ImageKey.of(pair.large))
            else { return }
            let large = pair.large
            onMainThread { backdrop.setDown(data, from: large) }
        }
    }

    /// **Fixed positions instead of fixed heights.**
    ///
    /// A stack with fixed row heights should have been enough, but on the Mac it was not:
    /// buttons moved depending on the server's answer. So each row sits at a computed
    /// position; anything that grows too large is clipped and moves nothing.
    ///
    ///     0    Title        42
    ///     54   Details      20
    ///     92   Description  66   (three lines)
    ///     182  Button row   48
    ///     230  End
    private func heroBlock(_ title: Item) -> Widget! {
        let inputField: Widget! = gtk_fixed_new()
        gtk_widget_set_halign(inputField, GTK_ALIGN_START)
        gtk_widget_set_valign(inputField, GTK_ALIGN_START)
        gtk_widget_set_size_request(inputField, 640, 230)
        gtk_widget_set_margin_start(inputField, Int32(Theme.edgeSpacing))
        // titleHeight (52) + 98, minus the header bar. On the Mac the distance is measured
        // from the window's top edge; there is no title bar there, here there is, and its
        // height is added.
        gtk_widget_set_margin_top(inputField, Int32(Theme.titleHeight + 98 - Theme.headerRowHeight))

        // **Each row in its own slot.** The four positions and heights match the Mac;
        // without a fixed slot every label would grow past its height (Inter sets taller than
        // SF Pro) and the gaps between would grow with it. Anything too large is clipped and
        // moves nothing.
        let name = label(title.name, style: "swiftly-heldtitel")
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(name), 0)
        // A logo fades over the text and stays in the slot of 42.
        let titleCompartment = compartment(name, width: 640, height: 42)
        attachTitleMark(titleCompartment, text: name, title: title)
        gtk_fixed_put(asField2(inputField), titleCompartment, 0, 0)

        // **26, not 20**: badge and evidence are 13 point type with 4 points of air above and
        // below; at 20 they were clipped top and bottom.
        gtk_fixed_put(asField2(inputField), compartment(detailsRail(title), width: 640, height: 26),
                      0, 54)

        // **`description`, not `overview`.** Jellyfin returns HTML, and `<br>` and `&amp;`
        // appeared literally on the page. `Description.lesbar` in the package cleans that
        // up and was simply never called here.
        let text = label(title.description ?? "", style: "swiftly-koerper", wrap: true)
        gtk_label_set_xalign(OpaquePointer(text), 0)
        gtk_label_set_yalign(OpaquePointer(text), 0)
        gtk_label_set_lines(OpaquePointer(text), 3)
        gtk_label_set_ellipsize(OpaquePointer(text), PANGO_ELLIPSIZE_END)
        gtk_label_set_justify(OpaquePointer(text), GTK_JUSTIFY_LEFT)
        gtk_widget_add_css_class(text, "swiftly-beschreibung")
        gtk_fixed_put(asField2(inputField), compartment(text, width: 640, height: 66,
                                           verticalRight: GTK_ALIGN_START), 0, 92)

        gtk_fixed_put(asField2(inputField), compartment(buttonRail(title), width: 640,
                                           height: Theme.primaryButtonHeight), 0, 182)
        return inputField
    }

    /// Year, runtime, genres, rating, certification and the badge: **one line**, not three.
    private func detailsRail(_ title: Item) -> Widget! {
        // **8 between the marks, 14 after the text**, as the Mac (`FilmView.detailsRail`)
        // and `ProofRow` on iPhone. 14 everywhere left a gap between three small badges.
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(rail, GTK_ALIGN_START)

        let row = label(title.secondaryLine, style: "swiftly-angaben")
        gtk_widget_add_css_class(row, "dim-label")
        gtk_widget_set_margin_end(row, 6)
        append(rail, row)

        // **In the same shell as Direct Play** (Mac `DetailView.swift` `mark`): star and
        // number in `schriftLeise`, surface at 15 percent of the same color. Before, the
        // rating was the only item in the row that stood bare.
        if let rating = title.communityRating {
            let pair = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
            let star: Widget! = gtk_image_new_from_icon_name("starred-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(star), 11)
            append(pair, star)
            let value = label(comma(rating), style: "swiftly-kacheltitel")
            append(pair, value)
            gtk_widget_add_css_class(pair, "swiftly-belegmarke")
            gtk_widget_add_css_class(pair, "swiftly-bewertung")
            gtk_widget_set_valign(pair, GTK_ALIGN_CENTER)
            append(rail, pair)
        }

        if let sharing = title.ageRating { append(rail, badge(sharing)) }

        // **The badge goes last**: year · runtime · stars · certification · Direct Play, as on
        // TV (`ProofMarks(proofLast:)`). It comes last, so its appearance moves nothing:
        // everything before it is already placed and nothing follows. If everything is lossless,
        // "Direct Play" shows in the accent color, otherwise the deviation in warning orange.
        //
        // **The plan no longer arrives with everything below the header.** It used to wait for
        // extras, similar titles and the collection and then popped in. Now it is fetched on
        // open, or already when hovering the tile (``planPrefetchBald(_:)``); if available, it
        // is in the first frame.
        let proof = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_visible(proof, 0)
        gtk_widget_add_css_class(proof, "swiftly-belegmarke")
        gtk_widget_set_valign(proof, GTK_ALIGN_CENTER)
        append(rail, proof)
        if let done = planReady[planKey(title)] {
            proofShow(done, in: proof, immediate: true)
        } else {
            planLoadMore(title, in: proof)
        }
        return rail
    }

    /// **The plan belongs to the episode, not the series.** For a series the server names
    /// no MediaSource, so the call would return empty, and `PlaybackInfo` is a POST in which
    /// the server touches the file: the app's most expensive request, wasted here.
    private func planLoadMore(_ title: Item, in proof: Widget!) {
        guard let job = planJob(title) else { return }
        let container = held(proof)
        Task.detached {
            let plan = await job.value
            onMainThread {
                defer { letGo(container) }
                self.proofShow(plan, in: container.widget)
            }
        }
    }

    /// The key under which a plan is valid: title and bitrate limit.
    func planKey(_ title: Item) -> String { "\(title.id)|\(selection.profileBitrate)" }

    /// **One request per title, shared.** Badge, file summary and the hover prefetch wait
    /// for the same task. Main thread only.
    func planJob(_ title: Item) -> Task<PlaybackPlan?, Never>? {
        guard let client else { return nil }
        let key = planKey(title)
        if let running = planJobs[key] { return running }
        let limit = selection.profileBitrate
        let job = Task.detached { [self] () -> PlaybackPlan? in
            let plan = await self.fetchPlan(title, client: client, limit: limit)
            onMainThread {
                if let plan { self.planReady[key] = plan }
                // A failed request may retry on the next open.
                else { self.planJobs[key] = nil }
            }
            return plan
        }
        planJobs[key] = job
        return job
    }

    /// **Prefetch on hover, with a delay.** The plan is a POST in which the server touches
    /// the file; moving the pointer across a grid should not trigger twenty of them. Only
    /// after 0.3 s on the same tile.
    func planPrefetchBald(_ item: Item) {
        guard item.type == "Movie" || item.type == "Series" else { return }
        planRequest = item.id
        postDeadline(0.3) { [weak self] in
            guard let self, self.planRequest == item.id else { return }
            _ = self.planJob(item)
        }
    }

    /// For a series, the plan of the episode that would play next.
    private func fetchPlan(_ title: Item, client: JellyfinClient, limit: Int) async -> PlaybackPlan? {
        let target: Item?
        if title.type == "Series" {
            target = try? await client.nextEpisodeSeries(seriesID: title.id)
        } else {
            target = title
        }
        guard let target else { return nil }
        return try? await client.playbackPlan(for: target.id, profile: .vlc(maxBitrate: limit))
    }

    /// Sets the badge and fades it in. Without a plan it stays hidden.
    private func proofShow(_ plan: PlaybackPlan?, in proof: Widget!, immediate: Bool = false) {
        guard let plan, let target = proof, gtk_widget_get_visible(target) == 0 else { return }
        let symbolText: Widget! = gtk_image_new_from_icon_name(
            plan.isLossless ? "object-select-symbolic" : "dialog-warning-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(symbolText), 11)
        append(target, symbolText)
        let text = label(plan.isLossless ? "Direct Play" : plan.method.rawValue,
                                style: "swiftly-kacheltitel")
        append(target, text)
        gtk_widget_add_css_class(target, plan.isLossless ? "swiftly-beleg" : "swiftly-warnung")
        gtk_widget_set_visible(target, 1)
        guard !immediate else { gtk_widget_set_opacity(target, 1); return }
        // Opacity only, 0.2 s: it sits at the end, so nothing shifts.
        gtk_widget_set_opacity(target, 0)
        crossfade(target, on: 1, duration: Theme.timeProof)
    }

    /// Four targets as on Apple TV: Resume, From start, Watchlist, More.
    ///
    /// **Fixed width for the main button, but no placeholder.** Otherwise it would grow with
    /// its label ("Fortsetzen" is longer than "Abspielen") and push everything behind it.
    /// "Von vorn" exists only for started titles; an empty gap would be worse than the small shift.
    private func buttonRail(_ title: Item) -> Widget! {
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)

        // **The main button starts where the server says**: a started episode at its position,
        // else the next unwatched, else episode 1. For a series this is not in the entry;
        // Jellyfin answers both in one call (`Shows/NextUp`).
        //
        // It used to be the series itself, which has no MediaSource: the server named no source
        // and the button did nothing but show an error. For a movie the title itself is the target.
        let target = PlayTarget()
        target.title = title.type == "Series" ? nil : title
        openTarget = target

        let begun = title.resumeFrom
        let main = primaryButton(begun != nil ? translated("Fortsetzen") : translated("Abspielen"),
                               symbol: "media-playback-start-symbolic")
        gtk_widget_set_size_request(main, Int32(Theme.primaryButtonWidth),
                                    Int32(Theme.primaryButtonHeight))
        signal(main, "clicked") { [weak self] in
            guard let self, let was = target.title else { return }
            self.launch(was, since: was.resumeFrom ?? 0)
        }
        // While the target is not settled, there is nothing to start.
        gtk_widget_set_sensitive(main, target.title == nil ? 0 : 1)
        append(rail, main)
        // **Right click or long press: the title's tile menu**, as on its tile (Apple:
        // `.tileMenu(title, …)` on the main button). Afterwards the button asks for its target again.
        let poster = addresses.flatMap { ImageSelection.portrait(title, addresses: $0,
                                                          maxHeight: Scaling.requestEdge(Theme.tileHeight)) }
        tileMenuCreate(main, TileMenuDetail(
            item: title, image: poster, border: Scaling.imageEdge(Theme.tileHeight),
            afterwards: { [weak self] _ in self?.headerRefresh?.perform() }))

        // **"Von vorn" only for started titles.** Where it does not exist, the rest moves up;
        // leaving an empty gap would be worse than the small shift.
        let front = secondaryButton("view-refresh-symbolic", name: translated("Von vorn abspielen"))
        gtk_widget_set_visible(front, begun != nil ? 1 : 0)
        signal(front, "clicked") { [weak self] in
            guard let self, let was = target.title else { return }
            self.launch(was, since: 0)
        }
        append(rail, front)

        // **After the player, only re-query this target**, do not rebuild the page, which
        // would jump to the top (``postPlayerRefresh``). For a movie that is the title
        // itself with its new position.
        let targetFetch: () -> Void = { [weak self] in
            guard let self, let client = self.client else { return }
            let buttonBox = held(main)
            let frontBox = held(front)
            let series = title.type == "Series"
            Task.detached {
                // **`stateInSeries`, not `nextEpisodeSeries`**: the main button starts where the
                // server says: a started episode at its position, else the next unwatched, **else
                // episode 1**. The bare NextUp request returns nothing for a fully watched series,
                // leaving the button disabled forever while every episode below could be played.
                // The fallback now lives in the package.
                let episode = series ? await client.stateInSeries(title.id)
                                  : try? await client.item(id: title.id)
                onMainThread {
                    defer { letGo(buttonBox); letGo(frontBox) }
                    guard let episode else { return }
                    target.title = episode
                    gtk_widget_set_sensitive(buttonBox.widget, 1)
                    let proceed = episode.resumeFrom != nil
                    primaryButtonLabel(buttonBox.widget,
                                          proceed ? translated("Fortsetzen") : translated("Abspielen"))
                    gtk_widget_set_visible(frontBox.widget, proceed ? 1 : 0)
                }
            }
        }
        if title.type == "Series" { targetFetch() }
        let mark = nextWatchStateMark()
        headerRefresh = (mark, targetFetch)
        signal(main, "destroy") { [weak self] in
            if self?.headerRefresh?.mark == mark { self?.headerRefresh = nil }
        }

        // **The watchlist toggles immediately, without confirmation.** The button's state is
        // the answer. The icon is a bookmark, not a star; on the Mac it is `bookmark`.
        //
        // **Drawn, not looked up.** Breeze has a ribbon with a plus under
        // `bookmark-new-symbolic`, which means "create new bookmark", not "on the
        // watchlist", and has no filled variant. See ``Merkzeichen``.
        // **The state lives in a class, not a local variable.** The fallback after a server
        // error comes back from a detached task, and a `var` must not cross the thread
        // boundary: same reasoning as with ``Spielziel``.
        let state = RememberState(title.userData?.isFavorite ?? false)
        let rememberCharacter = RememberCharacter(filled: state.an)
        rememberCharacter.onLightBackground(state.an)
        let memo = secondaryButton("", name: translated("Merkliste"), active: state.an,
                              drawing: rememberCharacter.display)
        signal(memo, "clicked") { [weak self] in
            guard let self, let client = self.client else { return }
            state.an.toggle()
            if state.an { gtk_widget_add_css_class(memo, "swiftly-aktiv") }
            else        { gtk_widget_remove_css_class(memo, "swiftly-aktiv") }
            rememberCharacter.setDown(state.an)
            rememberCharacter.onLightBackground(state.an)
            let new = state.an
            // **A failure turns the button back** (the button's state **is** the answer, so it
            // must be correct). Here there was `try?`: the button stayed toggled, the server knew
            // nothing and nobody noticed. The watched button three lines on has always done this
            // right, and so does the Mac (`DetailView.swift:506-515`).
            // The pointer crosses the thread boundary in the ``Zeigerkiste``, as everywhere here.
            let container = held(memo)
            Task.detached { [self] in
                do {
                    try await client.setWatchlist(itemID: title.id, an: new)
                    onMainThread { letGo(container); self.listenRefresh() }
                } catch {
                    onMainThread {
                        defer { letGo(container) }
                        let back = !new
                        state.an = back
                        let button = container.widget
                        if back { gtk_widget_add_css_class(button, "swiftly-aktiv") }
                        else       { gtk_widget_remove_css_class(button, "swiftly-aktiv") }
                        rememberCharacter.setDown(back)
                        rememberCharacter.onLightBackground(back)
                        self.report(readableError(error))
                    }
                }
            }
        }
        // The drawing area holds its icon; without this access it dies when the call returns.
        signal(rememberCharacter.display, "destroy") { _ = rememberCharacter }
        append(rail, memo)

        // **The download button only exists with the switch on**, and only if the account may
        // download (`DownloadPermission`). Anyone who has not enabled downloads sees nothing of it,
        // same rule as with Seerr.
        // **Also on the series page**: download sits in the row, not in a hidden chip. For a
        // series it opens the choice: whole series, season, single episode.
        if downloadButtonShow, title.type == "Series" {
            let load = secondaryButton("folder-download-symbolic", name: translated("Laden"))
            signal(load, "clicked") { [weak self] in
                self?.loadSelectionShow(title, an: load)
            }
            append(rail, load)
        }
        if downloadButtonShow, title.type != "Series" {
            let state = downloads.entries(for: title.id)
            let symbol = loadButtonIcon(state)
            let load = secondaryButton(symbol, name: translated("Laden"),
                                   active: state?.state == .done)
            signal(load, "clicked") { [weak self] in
                self?.loadPanelShow(title, an: load)
            }
            append(rail, load)
        }

        // **Four targets, not five.** "Gesehen" and "Trailer" moved into the More list; five
        // labeled buttons were too many for one row. This matches Apple TV and the Mac.
        let more = secondaryButton("view-more-horizontal-symbolic", name: translated("Mehr"))
        signal(more, "clicked") { [weak self] in self?.moreShow(title, an: more) }
        append(rail, more)
        return rail
    }

    // MARK: More

    /// **Small decisions open where they were triggered.** A `GtkPopover` is GTK's tool
    /// for this: it carries no shape of its own that we could not override, and closes by
    /// itself when clicking elsewhere.
    private func moreShow(_ title: Item, an button: Widget!) {
        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        // 260, like `Handlungsliste` on the Mac (`MacComponents.swift:591`).
        gtk_widget_set_size_request(list, 260, -1)

        var watched = title.isWatched
        let firstRow = watched ? translated("Als ungesehen markieren") : translated("Als gesehen markieren")

        // Right-aligned under the button, growing from the top-right corner, like
        // `.expand(from: .topTrailing)` on the Mac.
        let panel = panelOpen(an: button, flush: GTK_ALIGN_END)
        gtk_popover_set_child(asPanel(panel), Scaling.wrapped(list))

        append(list, actionRow("object-select-symbolic", firstRow) {
            [weak self] in
            guard let self, let client = self.client else { return }
            watched.toggle()
            let new = watched
            gtk_popover_popdown(asPanel(panel))
            // **The button's state is the answer**, but if the server refuses, the answer is wrong.
            // Then it takes itself back and says why; the Mac does the same. Here there is nothing
            // to take back: the list is rebuilt from `title.isWatched` on every open. It must be
            // said anyway, or it looks as if it worked.
            Task.detached { [self] in
                do {
                    try await client.setWatched(itemID: title.id, an: new)
                    onMainThread { self.watchStateForget(title) }
                }
                catch { onMainThread { self.report(readableError(error)) } }
            }
        })
        // **"Von vorn" only if there is something to reset**: for a movie at zero it would be
        // a line without effect. Wording and condition from `TitleActions.forMovie`.
        //
        // **"Trailer" is second, not third.** The Mac orders Watched, Trailer, then the
        // type-specific entries (`DetailView.swift:597-618`); here Trailer came after. The
        // entries themselves were already the same, only the order differed, and a hand-synced
        // list drifts apart exactly like that.
        append(list, actionRow("video-x-generic-symbolic", translated("Trailer")) {
            [weak self] in
            gtk_popover_popdown(asPanel(panel))
            self?.trailerStart(title)
        })
        if title.type == "Series" {
            if let state = openTarget?.title {
                append(list, actionRow("media-playback-start-symbolic",
                                                translated("Folge von vorn abspielen")) {
                    [weak self] in
                    gtk_popover_popdown(asPanel(panel))
                    self?.launch(state, since: 0)
                })
                // **"Nächste Folge" yields to "Gemeinsam schauen"** (as `TitleActions.forSeries`
                // on iOS): the list should not grow longer, and the next episode is reachable via the
                // episodes anyway.
                if gemeinsam.status.mayCreate {
                    append(list, actionRow("system-users-symbolic",
                                                    translated("Gemeinsam schauen")) {
                        [weak self] in
                        gtk_popover_popdown(asPanel(panel))
                        guard let self else { return }
                        // After the signal: the new panel replaces this one.
                        let anchor = PointerBox(button), lives = LifeCharacter(button)
                        onMainThread(during: lives) { [self] in self.sharedCreateShow(state, an: anchor.widget) }
                    })
                } else {
                append(list, actionRow("media-skip-forward-symbolic",
                                                translated("Nächste Folge abspielen")) {
                    [weak self] in
                    gtk_popover_popdown(asPanel(panel))
                    guard let self, let client = self.client,
                          let series = state.seriesId else { return }
                    // Without a server, the next downloaded episode (`DownloadRules`).
                    let entries = self.downloads.entries
                    Task.detached { [self] in
                        guard let next = await DownloadRules.episodePost(
                            state, from: entries, withoutNetwork: false, server: {
                                try await client.episodePost(itemID: state.id, seriesID: series)
                            }) else {
                            onMainThread { self.report(translated("Danach kommt nichts mehr.")) }
                            return
                        }
                        onMainThread { self.launch(next, since: 0) }
                    }
                })
                }
            }
            // **"Zufällig abspielen"** (`TitleActions.forSeries`): all episodes mixed once, unwatched
            // first (``ShuffleRun``); "Next episode" in the player then follows that order.
            append(list, actionRow("media-playlist-shuffle-symbolic", translated("Zufällig abspielen")) {
                [weak self] in
                gtk_popover_popdown(asPanel(panel))
                guard let self, let client = self.client else { return }
                Task.detached { [self] in
                    let all = try? await client.episodes(seriesID: title.id)
                    onMainThread {
                        guard let all, !all.isEmpty else {
                            self.report(translated("Die Folge konnte nicht geladen werden."))
                            return
                        }
                        let run = ShuffleRun.mixed(all)
                        self.shuffleRun = run
                        if let first = run.episodes.first { self.launch(first, since: 0) }
                    }
                }
            })
            if let season = openSeason {
                append(list, actionRow("object-select-symbolic",
                                                String(format: translated("%@ als gesehen"), season.name)) {
                    [weak self] in
                    gtk_popover_popdown(asPanel(panel))
                    guard let self, let client = self.client else { return }
                    // `[self]` as at the nine other places in this file. A second `[weak self]` **inside**
                    // a closure that already did `guard let self` does not compile under Swift 6:
                    // "reference to captured var 'self'". `App` lives as long as the program anyway.
                    Task.detached { [self] in
                        try? await client.setWatched(itemID: season.id, an: true)
                        onMainThread { self.watchStateForget(season) }
                    }
                    self.report(String(format: translated("%@ ist als gesehen vermerkt."), season.name))
                })
            }
        } else if title.resumeFrom != nil {
            append(list, actionRow("media-playback-start-symbolic",
                                            translated("Von vorn abspielen")) {
                [weak self] in
                gtk_popover_popdown(asPanel(panel))
                self?.launch(title, since: 0)
            })
            append(list, actionRow("view-refresh-symbolic",
                                            translated("Fortschritt zurücksetzen")) {
                [weak self] in
                gtk_popover_popdown(asPanel(panel))
                guard let self, let client = self.client else { return }
                Task.detached { [self] in
                    try? await client.setWatched(itemID: title.id, an: false)
                    onMainThread { self.watchStateForget(title) }
                }
                self.report(translated("Der Fortschritt ist zurückgesetzt."))
            })
        }
        // **Gemeinsam schauen**, before the metadata: same place as in `TitleActions.forMovie`.
        if title.type != "Series", gemeinsam.status.mayCreate {
            append(list, actionRow("system-users-symbolic", translated("Gemeinsam schauen")) {
                [weak self] in
                gtk_popover_popdown(asPanel(panel))
                guard let self else { return }
                let anchor = PointerBox(button), lives = LifeCharacter(button)
                onMainThread(during: lives) { [self] in self.sharedCreateShow(title, an: anchor.widget) }
            })
        }
        append(list, actionRow("view-refresh-symbolic", translated("Metadaten auffrischen")) {
            [weak self] in
            guard let client = self?.client else { return }
            Task.detached { try? await client.metadataRefresh(title.id) }
            gtk_popover_popdown(asPanel(panel))
        })
        gtk_popover_popup(asPanel(panel))
    }

    func actionRow(_ symbol: String, _ text: String,
                                _ pick: @escaping () -> Void) -> Widget! {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-handlung")
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        let image: Widget! = gtk_image_new_from_icon_name(symbol)
        gtk_image_set_pixel_size(OpaquePointer(image), 14)
        append(rail, image)
        let l = label(text, style: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        append(rail, l)
        gtk_button_set_child(asButton(button), rail)
        signal(button, "clicked", pick)
        return button
    }

    private func trailerStart(_ title: Item) {
        guard let client else { return }
        Task.detached { [self] in
            let movies = (try? await client.trailer(toward: title.id)) ?? []
            onMainThread {
                // **Silence is not an answer.** Without this line, pressing "Trailer" simply did
                // nothing and one could not tell whether the button was broken or the server had none.
                if let film = movies.first {
                    self.launch(film, since: 0)
                    return
                }
                // **The server has none, the web may.** The Mac falls back to `remoteTrailers` and
                // opens the URL in the browser (`DetailView.swift:618-621`); here there was only the
                // refusal. `remoteTrailers` was never read in the whole file.
                if let address = title.remoteTrailers?.compactMap(\.url).first,
                   let target = URL(string: address) {
                    browser(target)
                    return
                }
                self.report(translated("Für diesen Titel liegt kein Trailer vor."))
            }
        }
    }
}


/// Where the main button points. A class, so the callback sees the same value as the
/// reload: for a series it is settled only once the server has answered.
///
/// **`@unchecked Sendable` for the same reason as ``Zeigerkiste``:** read and written
/// only on GTK's main thread; the reload returns there via ``onMainThread``. Swift
/// cannot see that, only we can.
/// Whether a title is on the watchlist: a class, so the fallback after a server error
/// sees the same value as the click.
final class RememberState: @unchecked Sendable {
    var an: Bool
    init(_ an: Bool) { self.an = an }
}

final class PlayTarget: @unchecked Sendable {
    var title: Item?
}

// MARK: - Download

/// **The confirmation is a panel at the button**: same rule as the More list and
/// verbatim the Mac's decision: "On the desktop there is a pointer; what belongs to a
/// button appears at it."
///
/// It first states what the title costs and what is free, and only then offers the
/// button. A download that fails after twenty minutes on a full disk is the worse answer.
extension App {

    func loadButtonIcon(_ p: DownloadItem?) -> String {
        switch p?.state {
        case nil:          return "folder-download-symbolic"
        case .waits:      return "media-playback-pause-symbolic"
        case .loads:       return "media-playback-pause-symbolic"
        case .halted:  return "media-playback-start-symbolic"
        case .error:      return "dialog-warning-symbolic"
        case .done:      return "object-select-symbolic"
        }
    }

    func loadPanelShow(_ title: Item, an button: Widget!) {
        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(list, 280, -1)

        let panel = panelOpen(an: button)
        gtk_popover_set_child(asPanel(panel), Scaling.wrapped(list))

        // If it is already in the list, it is not about starting.
        if let available = downloads.entries(for: title.id) {
            append(list, loadDetail(translated("Auf diesem Rechner"),
                                        DownloadRules.size(available.loaded)))
            switch available.state {
            case .loads, .waits:
                append(list, actionRow("media-playback-pause-symbolic",
                                                translated("Anhalten")) { [weak self] in
                    gtk_popover_popdown(asPanel(panel))
                    self?.downloads.halt(title.id)
                })
            case .halted, .error:
                append(list, actionRow("media-playback-start-symbolic",
                                                translated("Fortsetzen")) { [weak self] in
                    gtk_popover_popdown(asPanel(panel))
                    self?.downloads.resume(title.id)
                })
            case .done:
                append(list, actionRow("media-playback-start-symbolic",
                                                translated("Ohne Netz abspielen")) { [weak self] in
                    gtk_popover_popdown(asPanel(panel))
                    guard let self, let p = self.downloads.entries(for: title.id) else { return }
                    self.downloadPlay(p)
                })
            }
            append(list, actionRow("user-trash-symbolic",
                                            translated("Vom Rechner entfernen")) { [weak self] in
                gtk_popover_popdown(asPanel(panel))
                self?.downloads.remove(title.id)
            })
            gtk_popover_popup(asPanel(panel))
            return
        }

        loadPanelNew(title, list: list, panel: panel, choice: .original, opened: false)
        gtk_popover_popup(asPanel(panel))
    }

    /// The content of the confirmation for a new download, **redrawn when another quality
    /// is chosen**, so size and "Danach frei" follow along.
    private func loadPanelNew(_ title: Item, list: Widget!, panel: Widget!,
                              choice: DownloadQuality, opened: Bool) {
        wipe(list)
        // **The size comes from the source the player would use.** If there is none, it still
        // downloads, just without a bar, only the growing number. `DownloadItem.share`
        // returns `nil` for that, and the row handles it.
        //
        // **In the chosen quality** (Mac `LoadPanel.version`): for the original the real size,
        // otherwise the estimate from bitrate times runtime, prefixed with "≈".
        let source = title.mediaSources?.first
        let original = source?.size ?? 0
        let bytes = choice.estimatedBytes(original: original, runtimeTicks: title.runTimeTicks)
        let converted = !choice.isOriginal
        let inquiry = downloads.inquiry(for: bytes)
        let offered = DownloadQuality.offered(
            selectable: downloadQualitySelectable,
            sourceBitrateOf: DownloadQuality.bitrate(bytes: original, runtimeTicks: title.runTimeTicks))
        let selectionShow = downloadQualitySelectable && offered.count > 1
        let new: (DownloadQuality, Bool) -> Void = { [weak self] q, on in
            self?.loadPanelNew(title, list: list, panel: panel, choice: q, opened: on)
        }
        let qualityRow: () -> Void = { [weak self] in
            guard let self else { return }
            let inputField = self.qualitySelectionBuild(
                choice: choice, offered: offered, selectable: true, opened: opened,
                size: { $0.estimatedBytes(original: original, runtimeTicks: title.runTimeTicks) },
                toggle: { new(choice, !opened) }, select: { new($0, false) })
            gtk_widget_set_margin_start(inputField, 14)
            gtk_widget_set_margin_end(inputField, 14)
            gtk_widget_set_margin_bottom(inputField, 6)
            append(list, inputField)
        }

        append(list, loadDetail(translated("Diese Datei"),
                                    bytes > 0 ? (converted ? "≈ " : "") + DownloadRules.size(bytes)
                                              : translated("Unbekannt")))
        if !inquiry.suffices {
            append(list, loadDetail(translated("Frei auf diesem Rechner"),
                                        DownloadRules.size(max(0, inquiry.freeAfter
                                                                   + bytes
                                                                   + DownloadRules.padding)),
                                        cautionary: true))
            // The obvious way out is a smaller version.
            if selectionShow { qualityRow() }
            if inquiry.sufficesToCleanUp, !inquiry.dispensable.isEmpty {
                let text = String(format: translated("%d gesehene Titel könnten weichen (%@)."),
                                  inquiry.dispensable.count,
                                  DownloadRules.size(inquiry.dispensableBytes))
                append(list, loadHint(text))
            } else {
                append(list, loadHint(translated("Nicht genug Platz")))
                return
            }
        }

        // **And the case in between: space yes, connection metered.** The Mac has its own branch
        // with a warning icon and a "In die Warteschlange" button (`MacDownloads.swift:161-166`);
        // here there were only "does not fit" and "downloads", although the measurement exists.
        else if !DownloadRules.mayLoad(wLAN: downloads.wLAN,
                                          onlyOverWLAN: downloads.onlyOverWLAN) {
            append(list, loadDetail(translated("Kein WLAN"),
                                        translated("Mobilfunk"), cautionary: true))
            append(list, actionRow("folder-download-symbolic",
                                            translated("In die Warteschlange")) { [weak self] in
                gtk_popover_popdown(asPanel(panel))
                self?.loadTrigger(title, source: source, bytes: original, quality: choice)
            })
            return
        }
        // **Three numbers, one button.** Size, quality and what is free afterwards, as the panel
        // looks on the Mac (`MacDownloads.swift:168-176`). Here the normal case showed only the
        // size; "Frei auf diesem Rechner" appeared only when space got tight, and the sentence
        // explaining the original quality was missing entirely, although it is the reason there
        // is no quality choice.
        else {
            if selectionShow {
                qualityRow()
            } else if let c = source?.container, !c.isEmpty {
                append(list, loadDetail(translated("Qualität"), c.uppercased()))
            }
            append(list, loadDetail(translated("Danach frei"),
                                        DownloadRules.size(inquiry.freeAfter)))
        }

        append(list, actionRow("folder-download-symbolic",
                                        translated("Laden")) { [weak self] in
            gtk_popover_popdown(asPanel(panel))
            self?.loadTrigger(title, source: source, bytes: original, quality: choice)
        })
        if inquiry.suffices {
            append(list, loadHint(converted
                ? translated("Der Server wandelt die Datei beim Laden um. Die Größe ist geschätzt.")
                : translated("Swiftly lädt die Originaldatei, in derselben Qualität wie beim Streamen.")))
        }
    }

    private func loadDetail(_ was: String, _ value: String, cautionary: Bool = false) -> Widget! {
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_set_margin_start(row, 14)
        gtk_widget_set_margin_end(row, 14)
        gtk_widget_set_margin_top(row, 9)
        gtk_widget_set_margin_bottom(row, 9)
        let l = label(was, style: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        if cautionary { gtk_widget_add_css_class(l, "swiftly-warnung") }
        append(row, l)
        let w = label(value, style: "swiftly-koerper")
        append(row, w)
        return row
    }

    private func loadHint(_ text: String) -> Widget! {
        let l = label(text, style: "swiftly-zweitzeile", wrap: true)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_margin_start(l, 14)
        gtk_widget_set_margin_end(l, 14)
        gtk_widget_set_margin_bottom(l, 10)
        return l
    }

    /// The entry becomes an item. What goes in must suffice to show and play the title
    /// **without a server**, hence runtime, container and the series details.
    func loadTrigger(_ title: Item, source: MediaSource?, bytes: Int64,
                        quality: DownloadQuality = .original) {
        // No account, no item. Empty here means "not signed in", and a download without an
        // account would run under the same file as a second user's.
        guard !userIdentifier.isEmpty else { return }
        let entries = DownloadItem(
            id: title.id,
            account: userIdentifier,
            art: title.type == "Episode" ? .episode : .film,
            title: title.name ?? "",
            series: title.seriesName,
            seriesIdentifier: title.seriesId,
            season: title.parentIndexNumber,
            episode: title.indexNumber,
            runtimeTicks: title.runTimeTicks,
            container: source?.container,
            source: source?.id,
            bytes: bytes,
            // The whole watch state, not just the flag: offline, the download list starts at the
            // position the server knew.
            watchState: title.userData,
            videoCodec: source?.videoCodec).inQuality(quality)

        var images: [String: URL] = [:]
        if let addresses {
            if let (url, _) = ImageSelection.landscape(title, addresses: addresses, width: 400) {
                images[title.id] = url
            }
        }
        downloads.trigger(entries, images: images)
        report(translated("Wird geladen."))
    }

    /// **The whole season, in order.**
    ///
    /// The chip next to the season picker was missing on Linux; there was only a download per
    /// episode, and anyone wanting a season had to click twenty-two times. The Mac has had it
    /// for a long time (`SeriesView.swift:103-110`, `:317-322`).
    ///
    /// **What is already there is not queued again**, and the order is set by
    /// `DownloadRules.nextOne`; here things are only enqueued.
    func seasonLoad(_ episodes: [Item], quality: DownloadQuality = .original) {
        let openOnes = episodes.filter { downloads.entries(for: $0.id) == nil }
        guard !openOnes.isEmpty else { return }
        for episode in openOnes {
            loadTrigger(episode, source: episode.mediaSources?.first,
                           bytes: episode.mediaSources?.first?.size ?? 0, quality: quality)
        }
        report(numberWord(openOnes.count, one: translated("1 Folge wird geladen."),
                        many: translated("%d Folgen werden geladen.")))
    }
}
