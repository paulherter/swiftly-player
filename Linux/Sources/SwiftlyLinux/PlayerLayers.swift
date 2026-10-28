import CGtk
import Foundation
import JellyfinKit

/// The three layers over the picture, modelled on `Sources/macOS/PlayerLayers.swift`:
/// audio & subtitles, settings, episodes. Each fills the whole screen.
///
/// **A forced deviation:** GTK's CSS has no `backdrop-filter`, so the blur
/// behind the layer (`.ultraThinMaterial`) is missing. The layer darkens
/// slightly more instead (black 78 % rather than 72 %) so text stays just as
/// readable over a bright picture.
///
/// **Pitfalls:**
/// - After closing a layer nothing reacted: `unfoldLayer` removed
///   `can-target` from the controls and nothing gave it back.
/// - The title disappeared: `obenHalten` removed it from the overlay and
///   re-added it; removing dropped the last reference, GTK freed the widget,
///   and the field pointed to nothing. Now it is only reordered
///   (`gtk_widget_insert_before`), never removed.
/// - Every choice in a layer rebuilt the whole layer (jumping, flicker); now
///   only the checkmark moves.
enum PlayerLayer: Equatable, Hashable {
    case tracks, settings, episodes
}

/// Player measurements, copied verbatim from `Playermass` on the Mac.
enum PlayerMetric {
    static let page: Int32 = 40
    static let top: Int32 = 28
    static let bottom: Int32 = 24
    static let button: Int32 = 38
    static let symbol: Int32 = 22   // Box for an 18-point SF symbol
    static let overBar: Int32 = 20
    static let bar: Int32 = 32
    static let railsSpacing: Int32 = 4
}

/// The checkmarks of a column. A choice only repaints the checkmarks instead
/// of rebuilding the layer.
final class SelectionGroup {
    private var rows: [(identifier: String, button: Widget, checkmark: Widget)] = []

    func record(_ identifier: String, button: Widget, checkmark: Widget) {
        rows.append((identifier, button, checkmark))
    }

    func choose(_ identifier: String) {
        for z in rows {
            let an = z.identifier == identifier
            gtk_widget_set_opacity(z.checkmark, an ? 1 : 0)
            if an { gtk_widget_add_css_class(z.button, "swiftly-gewaehlt") }
            else { gtk_widget_remove_css_class(z.button, "swiftly-gewaehlt") }
            help(z.button, selected: an)
        }
    }
}

extension App {

    // MARK: Building blocks

    /// One of the icon buttons at the top right: 38 × 38, transparent, a subtle
    /// fill on hover (Mac: `IconButton`).
    func iconButton(_ name: String, label text: String,
                     action: @escaping () -> Void) -> (button: Widget?, symbolText: PlayerCharacter) {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-symbolknopf")
        gtk_widget_set_size_request(button, PlayerMetric.button, PlayerMetric.button)
        gtk_widget_set_valign(button, GTK_ALIGN_START)
        let symbolText = PlayerCharacter(name, size: PlayerMetric.symbol)
        gtk_button_set_child(asButton(button), symbolText.display)
        gtk_widget_set_tooltip_text(button, text)
        caption(button, text)
        signal(button, "clicked", action)
        return (button, symbolText)
    }

    /// Width of the icon row at the top right; the fixed title keeps that space
    /// free, like `iconRail.hidden()` on the Mac.
    func iconRailsWidth() -> Int32 {
        let count: Int32 = hasEpisodesLayer ? 6 : 5
        return count * PlayerMetric.button + (count - 1) * PlayerMetric.railsSpacing
    }

    var hasEpisodesLayer: Bool {
        runningTitle?.type == "Episode" && runningTitle?.seriesId != nil
    }

    /// Background of every layer: flat black. Accepts every click so nothing
    /// underneath seeks (Mac: `Ebenengrund`, `.onTapGesture {}`).
    private func layerBackground() -> Widget! {
        let reason = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(reason, "swiftly-ebenengrund")
        gtk_widget_set_hexpand(reason, 1)
        gtk_widget_set_vexpand(reason, 1)
        return reason
    }

    /// Header of a layer: what it shows on the left, the X on the right, with
    /// the same measurements as the player's header so both X's line up.
    private func layersHeader(left: Widget?) -> Widget! {
        let header = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_widget_set_valign(header, GTK_ALIGN_START)
        gtk_widget_set_margin_top(header, PlayerMetric.top)
        gtk_widget_set_margin_start(header, PlayerMetric.page)
        gtk_widget_set_margin_end(header, PlayerMetric.page)
        let left = left ?? stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(left, 1)
        append(header, left)
        let (x, _) = iconButton("close", label: translated("Schließen")) {
            [weak self] in self?.layerClose()
        }
        playerLayersX = x
        append(header, x)
        return header
    }

    /// A column with a fixed heading; only the rows below scroll on their own,
    /// so with 50 or more subtitles the other column stays still (Mac:
    /// `SelectionColumn`). Short choices take `Theme.layerColumnWidth`, the track
    /// columns `Theme.trackColumnWidth`.
    func layersColumn(_ title: String, width: Int = Theme.layerColumnWidth,
                      _ fill: (Widget?) -> Void) -> Widget! {
        let outer = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(outer, Int32(width), -1)
        gtk_widget_set_vexpand(outer, 1)

        let header = label(title, style: "swiftly-spaltentitel")
        gtk_label_set_xalign(OpaquePointer(header), 0)
        gtk_label_set_ellipsize(OpaquePointer(header), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(header), 1)
        gtk_widget_set_margin_start(header, 10)
        gtk_widget_set_margin_end(header, 10)
        gtk_widget_set_margin_bottom(header, 9)
        append(outer, header)

        let content = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_valign(content, GTK_ALIGN_START)
        gtk_widget_set_margin_bottom(content, 12)
        let role: Widget! = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(role), GTK_POLICY_NEVER, GTK_POLICY_EXTERNAL)
        gtk_widget_set_vexpand(role, 1)
        gtk_scrolled_window_set_child(OpaquePointer(role), content)
        softScroll(role)
        append(outer, role)
        fill(content)
        return outer
    }

    /// Checkmark and name. Selected: white and semibold; otherwise 62 % white
    /// (Mac: `LayersRow`).
    func layerRow(_ text: String, identifier: String, group: SelectionGroup, selected: Bool,
                     pick: @escaping () -> Void) -> Widget! {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-ebenenzeile")
        if selected { gtk_widget_add_css_class(button, "swiftly-gewaehlt") }
        help(button, name: text, selected: selected)
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 9)
        let checkmark = PlayerCharacter("checkmark", size: 15)
        let checkmarkSpace = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_size_request(checkmarkSpace, 17, -1)
        append(checkmarkSpace, checkmark.display)
        gtk_widget_set_opacity(checkmarkSpace, selected ? 1 : 0)
        append(rail, checkmarkSpace)
        let l = label(text)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
        // One character of width requested, so a long name does not push the column
        // beyond its width; `hexpand` gives it the rest.
        gtk_label_set_max_width_chars(OpaquePointer(l), 1)
        gtk_widget_set_hexpand(l, 1)
        append(rail, l)
        gtk_button_set_child(asButton(button), rail)
        gtk_widget_set_tooltip_text(button, text)
        group.record(identifier, button: button, checkmark: checkmarkSpace!)
        signal(button, "clicked") {
            group.choose(identifier)
            pick()
        }
        return button
    }

    /// Columns side by side, centered, below the header (Mac: `ColumnsRail`,
    /// spacing 45, top `top + button + 6`).
    private func columnsLayer(_ columns: [Widget?]) -> Widget! {
        let over: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(over), layerBackground())
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 45)
        gtk_widget_set_halign(rail, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(rail, GTK_ALIGN_FILL)
        gtk_widget_set_margin_top(rail, PlayerMetric.top + PlayerMetric.button + 6)
        for s in columns { append(rail, s) }
        gtk_overlay_add_overlay(OpaquePointer(over), rail)
        gtk_overlay_add_overlay(OpaquePointer(over), layersHeader(left: nil))
        return over
    }

    // MARK: Opening and closing

    /// Opens a layer: it fades in over 0.2 s, the controls fade out at the same
    /// pace (Mac: `.animation(.easeInOut(duration: 0.2), value: openLayer)`).
    func unfoldLayer(_ target: PlayerLayer) {
        guard runningTitle != nil, let frameRect = playerFrame, openLayerArt != target else { return }
        if let alt = openLayer { layerTearDown(alt) }
        openLayerArt = target
        let content: Widget!
        switch target {
        case .tracks:        content = tracksLayerBuild()
        case .settings: content = settingsLayerBuild()
        case .episodes:        content = episodesLayerBuild()
        }
        openLayer = content
        gtk_widget_set_opacity(content, 0)
        gtk_overlay_add_overlay(OpaquePointer(frameRect), content)
        // Above everything, only below the fixed title.
        if let state = playerTitleState { gtk_widget_insert_before(content, frameRect, state) }
        crossfade(content, on: 1, duration: 0.2, curve: .easeOut)
        controlsVisibility(duration: 0.2)
        previewHide()
        showPointer(true)
        offeringUpdate()
        if let x = playerLayersX { gtk_widget_grab_focus(x) }
        AppLog.writeOut("[Ebene] auf: \(target)")
        fflush(nil)
    }

    /// Closes the open layer: it fades out over 0.2 s, the controls fade back in
    /// at the same pace, and **everything is operable again**: clicks
    /// (`can-target`), keys (the layer holds none anymore) and focus, which
    /// returns to the button that opened the layer.
    func layerClose() {
        guard let art = openLayerArt else { return }
        if let alt = openLayer { layerTearDown(alt) }
        openLayer = nil
        openLayerArt = nil
        playerEpisodesList = nil
        playerEpisodesScroller = nil
        playerEpisodesTarget = nil
        playerLayersX = nil
        guard playerControls != nil else { return }
        controlsOpen = true
        controlsVisibility(duration: 0.2)
        controlsShow()
        if let button = playerLayersButtons[art] { gtk_widget_grab_focus(button) }
        AppLog.writeOut("[Ebene] zu: \(art), Steuerung klickbar: \(gtk_widget_get_can_target(playerControls) != 0)")
        fflush(nil)
    }

    /// Takes a layer out of play: immediately no clicks, then fade out, then
    /// remove from the overlay. It is only removed if still attached; the widget
    /// itself is not touched if the player has been torn down meanwhile.
    private func layerTearDown(_ alt: Widget!) {
        gtk_widget_set_can_target(alt, 0)
        gtk_widget_set_can_focus(alt, 0)
        let address = Int(bitPattern: alt)
        crossfade(alt, on: 0, duration: 0.2, curve: .easeOut) {
            gtk_widget_set_visible(alt, 0)
            onMainThread { [weak self] in
                guard let self, let frameRect = self.playerFrame else { return }
                var kind = gtk_widget_get_first_child(frameRect)
                while let k = kind {
                    if Int(bitPattern: k) == address {
                        gtk_overlay_remove_overlay(OpaquePointer(frameRect), k)
                        return
                    }
                    kind = gtk_widget_get_next_sibling(k)
                }
            }
        }
    }

    /// The fixed title: shown while the controls are shown, and over the
    /// episode layer; otherwise not (Mac: `stateTitle`).
    func titleStateUpdate(duration: Double? = nil) {
        guard let state = playerTitleState else { return }
        let present = (controlsOpen && openLayerArt == nil) || openLayerArt == .episodes
        crossfade(state, on: present ? 1 : 0, duration: duration ?? (present ? 0.18 : 0.34),
                curve: duration != nil || present ? .easeOut : .easeInOut)
    }

    // MARK: Audio & subtitles

    private func tracksLayerBuild() -> Widget! {
        let audioNow = mediaPlayer.audioTrack
        let audioGroup = SelectionGroup()
        let audio = layersColumn(translated("Audio"), width: Theme.trackColumnWidth) { space in
            for track in audioTrackNames() {
                append(space, layerRow(track.name, identifier: "\(track.identifier)", group: audioGroup,
                                            selected: track.identifier == audioNow) {
                    [weak self] in self?.audioTrackSelected(track.identifier)
                })
            }
            append(space, delayRow(subtitle: false))
        }
        let subtitleNow = mediaPlayer.subtitleTrack
        let subGroup = SelectionGroup()
        let subtitle = layersColumn(translated("Untertitel"), width: Theme.trackColumnWidth) { space in
            append(space, layerRow(translated("Aus"), identifier: "aus", group: subGroup,
                                        selected: subtitleNow < 0) {
                [weak self] in self?.subtitleSelected(nil)
            })
            for track in subtitleNames() {
                append(space, layerRow(track.name, identifier: "\(track.identifier)", group: subGroup,
                                            selected: track.identifier == subtitleNow) {
                    [weak self] in self?.subtitleSelected(track.identifier)
                })
            }
            append(space, delayRow(subtitle: true))
        }
        return columnsLayer([audio, subtitle])
    }

    // MARK: Delay

    /// **Delay: last row of the Audio and Subtitles columns.**
    ///
    /// Counterpart to `Verzoegerungszeile` on the Mac: a small label, below it
    /// − value +, and on the right an arrow to reset, visible only when ≠ 0 but
    /// keeping its space so − value + does not jump. − and + repeat while held,
    /// and ``Verzoegerung/Haltezaehler`` speeds them up.
    func delayRow(subtitle: Bool) -> Widget! {
        let row = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_margin_top(row, 10)
        let title = label(translated("Verzögerung"), style: "swiftly-verzugstitel")
        gtk_label_set_xalign(OpaquePointer(title), 0)
        gtk_widget_set_margin_start(title, 10)
        append(row, title)

        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        append(row, rail)
        let mediaPlayer = self.mediaPlayer
        var hold = Delay.HoldCounter()
        func value() -> Delay {
            subtitle ? mediaPlayer.subtitleDelay : mediaPlayer.audioDelay
        }
        var displayed: () -> Void = {}
        func setDown(_ new: Delay) {
            if subtitle { mediaPlayer.subtitleDelay = new } else { mediaPlayer.audioDelay = new }
            displayed()
        }
        let earlier = delayKey("minus", translated("Früher")) {
            setDown(value().shifted(-1, steps: hold.press()))
        }
        append(rail, earlier.button)
        let figure = label(value().text(), style: "swiftly-verzugswert")
        gtk_widget_set_hexpand(figure, 1)
        append(rail, figure)
        let later = delayKey("plus", translated("Später")) {
            setDown(value().shifted(1, steps: hold.press()))
        }
        append(rail, later.button)
        let back = delayKey("reset", translated("Zurücksetzen"), redo: false) {
            setDown(.null)
        }
        append(rail, back.button)

        displayed = {
            let v = value()
            gtk_label_set_text(OpaquePointer(figure), v.text())
            if v.isNull { gtk_widget_add_css_class(figure, "swiftly-null") }
            else { gtk_widget_remove_css_class(figure, "swiftly-null") }
            earlier.lockOut(v.atStart)
            later.lockOut(v.atEnd)
            // The space stays: invisible, not gone.
            gtk_widget_set_opacity(back.button, v.isNull ? 0 : 1)
            gtk_widget_set_sensitive(back.button, v.isNull ? 0 : 1)
        }
        displayed()
        return row
    }

    /// − / + / reset of the delay row: 38 × 38 like the icon buttons, with their
    /// hover fill.
    private func delayKey(_ name: String, _ text: String, redo: Bool = true,
                              action: @escaping () -> Void) -> LagKey {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-symbolknopf")
        gtk_widget_set_size_request(button, PlayerMetric.button, PlayerMetric.button)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        let symbolText = PlayerCharacter(name, size: PlayerMetric.symbol - 3)
        gtk_button_set_child(asButton(button), symbolText.display)
        gtk_widget_set_tooltip_text(button, text)
        caption(button, text)
        let keyButton = LagKey(button: button, symbolText: symbolText, action: action)
        signal(button, "clicked") { keyButton.clicked() }
        if redo {
            onGrip(button) { pressed in pressed ? keyButton.hold() : keyButton.release() }
        }
        signal(button, "destroy") { keyButton.release() }
        return keyButton
    }

    /// **G/H subtitles, J/K audio, 50 ms each, as in VLC and on the Mac**
    /// (`PlayerScreen.postpone`). Only when no layer is open; the new value is
    /// shown briefly as a hint.
    func postpone(subtitle: Bool, _ bearing: Int) {
        if subtitle {
            mediaPlayer.subtitleDelay = mediaPlayer.subtitleDelay.shifted(bearing)
            report(String(format: translated("Untertitelverzögerung %@"),
                          mediaPlayer.subtitleDelay.text()))
        } else {
            mediaPlayer.audioDelay = mediaPlayer.audioDelay.shifted(bearing)
            report(String(format: translated("Tonverzögerung %@"), mediaPlayer.audioDelay.text()))
        }
    }

    // MARK: Settings

    private func settingsLayerBuild() -> Widget! {
        let imageGroup = SelectionGroup()
        let image = layersColumn(translated("Bild")) { space in
            for (identifier, filling) in [("original", false), ("fuellen", true)] {
                append(space, layerRow(translated(filling ? "Füllen" : "Original"),
                                            identifier: identifier, group: imageGroup,
                                            selected: selection.fillFrame == filling) {
                    [weak self] in
                    guard let self else { return }
                    self.selection.fillFrame = filling
                    self.selection.secure()
                    self.mediaPlayer.fillFrame(filling)
                })
            }
        }
        let sleepGroup = SelectionGroup()
        let sleep = layersColumn(translated("Schlafzeit")) { space in
            append(space, layerRow(translated("Aus"), identifier: "aus", group: sleepGroup,
                                        selected: sleepMinutes == nil) {
                [weak self] in
                guard let self else { return }
                self.sleepMinutes = nil
                self.sleepTick += 1
            })
            for minutes in SleepTimes.values {
                append(space, layerRow(String(format: translated("%lld Min."), minutes),
                                            identifier: "\(minutes)", group: sleepGroup,
                                            selected: sleepMinutes == minutes) {
                    [weak self] in self?.sleepTimeSet(minutes)
                })
            }
        }
        let techGroup = SelectionGroup()
        let tech = layersColumn(translated("Technikschild")) { space in
            for (identifier, an) in [("aus", false), ("an", true)] {
                append(space, layerRow(translated(an ? "An" : "Aus"), identifier: identifier,
                                            group: techGroup,
                                            selected: selection.techBadge == an) {
                    [weak self] in
                    guard let self else { return }
                    self.selection.techBadge = an
                    self.selection.secure()
                    self.techBadgeSet(an)
                })
            }
        }
        var columns = [image, sleep, tech]
        // **Shared first**: who is in the group, and the exit.
        if let gemeinsam = sharedColumn() { columns.insert(gemeinsam, at: 0) }
        // **Quality: Direct Play or a cap.** A cap means the server may transcode,
        // so Direct Play is off. Only for playback from the server, and only if the
        // account may transcode. Works like the setting in the app and reloads the
        // movie at the same position.
        // **And not in a group**: the switch would bypass the group (iOS
        // `qualitySelection`).
        if convertAllowed, runningPlan?.url.isFileURL == false, !inGroup {
            let qualityGroup = SelectionGroup()
            let quality = layersColumn(translated("Qualität")) { space in
                append(space, layerRow(translated("Direct Play"), identifier: "direct",
                                            group: qualityGroup,
                                            selected: selection.alwaysDirectPlay) {
                    [weak self] in
                    guard let self else { return }
                    self.selection.alwaysDirectPlay = true
                    self.selection.secure()
                    self.qualityChanged()
                })
                for rung in Bitrate.levels {
                    append(space, layerRow(Bitrate.text(rung.value), identifier: "\(rung.value)",
                                                group: qualityGroup,
                                                selected: !selection.alwaysDirectPlay
                                                    && selection.bitratesLimit == rung.value) {
                        [weak self] in
                        guard let self else { return }
                        self.selection.alwaysDirectPlay = false
                        self.selection.bitratesLimit = rung.value
                        self.selection.secure()
                        self.qualityChanged()
                    })
                }
            }
            columns.append(quality)
        }
        return columnsLayer(columns)
    }

    // MARK: Episodes

    /// The series' episodes: same rows as on the series page (`episodeRow`).
    /// The title stays where it was in the player; the season picker replaces
    /// the meta line. **On opening, the list is shown immediately** (from the
    /// series page's cache); it only cross-fades on a season change (Mac:
    /// `EpisodesLayer`).
    private func episodesLayerBuild() -> Widget! {
        let over: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(over), layerBackground())
        let pillar = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_overlay_add_overlay(OpaquePointer(over), pillar)

        let left = stack(GTK_ORIENTATION_VERTICAL, spacing: 3)
        let slot = label(runningTitleRow, style: "swiftly-spielertitel")
        gtk_label_set_ellipsize(OpaquePointer(slot), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(slot), 0)
        gtk_widget_set_opacity(slot, 0)
        append(left, slot)
        let seasonPickerRoom = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_halign(seasonPickerRoom, GTK_ALIGN_START)
        append(left, seasonPickerRoom)
        append(pillar, layersHeader(left: left))

        let role: Widget! = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(role), GTK_POLICY_NEVER, GTK_POLICY_EXTERNAL)
        gtk_widget_set_vexpand(role, 1)
        gtk_widget_set_margin_top(role, 10)
        let inner = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_margin_top(inner, 12)
        gtk_widget_set_margin_bottom(inner, 12)
        gtk_scrolled_window_set_child(OpaquePointer(role), inner)
        softScroll(role)
        append(pillar, role)
        playerEpisodesList = inner
        playerEpisodesScroller = role

        guard let ongoing = runningTitle, let seriesKeyID = ongoing.seriesId else { return over }
        playerSeasonSelection = seasonPickerRoom
        if let already = seasonCache[seriesKeyID], !already.isEmpty {
            seasonSelectionFill(already, ongoing: ongoing, seriesKeyID: seriesKeyID)
        }
        if let client {
            Task.detached { [self] in
                let seasons = (try? await client.seasons(seriesID: seriesKeyID)) ?? []
                onMainThread {
                    guard self.openLayerArt == .episodes, self.runningTitle?.seriesId == seriesKeyID,
                          !seasons.isEmpty else { return }
                    let before = self.seasonCache[seriesKeyID]?.map(\.id)
                    self.seasonCache[seriesKeyID] = seasons
                    guard before != seasons.map(\.id) else { return }
                    self.seasonSelectionFill(seasons, ongoing: ongoing, seriesKeyID: seriesKeyID)
                }
            }
        }
        return over
    }

    /// The title as shown at the top left: the series name for episodes.
    var runningTitleRow: String {
        guard let item = runningTitle else { return "" }
        let series = item.type == "Episode" ? item.seriesName : nil
        return (series?.isEmpty == false ? series : nil) ?? item.name
    }

    private func episodesListDraw(_ episodes: [Item], ongoing: Item, scroll: Bool) {
        guard let inner = playerEpisodesList else { return }
        playerEpisodesTarget = nil
        wipe(inner)
        for episode in episodes {
            let row = episodeRow(episode, running: episode.id == ongoing.id) {
                [weak self] selectedEpisode in
                guard let self else { return }
                self.layerClose()
                // Clicking the current episode means: keep watching.
                guard selectedEpisode.id != self.runningTitle?.id else { return }
                // In a group nobody switches alone: the choice sets the queue, and
                // everyone loads the episode (as on iOS).
                if self.inGroup { self.sharedBitTitle(selectedEpisode.id); return }
                self.changeInto(selectedEpisode)
            }
            append(inner, row)
            if scroll, episode.id == ongoing.id { playerEpisodesTarget = row }
        }
        guard let role = playerEpisodesScroller,
              let adj = gtk_scrolled_window_get_vadjustment(OpaquePointer(role)) else { return }
        gtk_adjustment_set_value(adj, 0)
        guard playerEpisodesTarget != nil else { return }
        // **The current episode centered** as soon as the list is laid out; before
        // that, neither the row knows its position nor the scroller its height. In
        // the first frame the layer is still nearly transparent.
        var completed = false
        runningCount(on: inner, duration: 1.0, step: { [weak self] _ in
            guard !completed, let self, let row = self.playerEpisodesTarget,
                  let list = self.playerEpisodesList else { return }
            var r = graphene_rect_t()
            let page = gtk_adjustment_get_page_size(adj)
            guard page > 0, gtk_widget_compute_bounds(row, list, &r) != 0,
                  r.size.height > 0 else { return }
            completed = true
            self.playerEpisodesTarget = nil
            let target = Double(r.origin.y) + 12 + Double(r.size.height) / 2 - page / 2
            let atMost = gtk_adjustment_get_upper(adj) - page
            gtk_adjustment_set_value(adj, min(max(target, 0), max(atMost, 0)))
        }, done: {})
    }

    private func episodesListShow(_ episodes: [Item], ongoing: Item, crossfade fade: Bool) {
        episodesListDraw(episodes, ongoing: ongoing, scroll: true)
        guard fade, let inner = playerEpisodesList else { return }
        gtk_widget_set_opacity(inner, 0)
        crossfade(inner, on: 1, duration: 0.25, curve: .easeOut)
    }

    private func episodesSeasonLoad(_ season: Item, seriesKeyID: String, ongoing: Item,
                                        crossfade fade: Bool) {
        let shown = episodeStore[season.id]?.map(\.id)
        if let already = episodeStore[season.id] {
            episodesListShow(already, ongoing: ongoing, crossfade: fade)
        }
        guard let client else { return }
        playerEpisodesSeason = season.id
        Task.detached { [self] in
            let loaded = (try? await client.episodes(seriesID: seriesKeyID, seasonID: season.id)) ?? []
            onMainThread {
                guard self.openLayerArt == .episodes, self.playerEpisodesSeason == season.id else { return }
                self.episodeStore[season.id] = loaded
                // Building the same list again would reload images and reset the scroll
                // position, a visible twitch for nothing.
                guard shown != loaded.map(\.id) else { return }
                self.episodesListShow(loaded, ongoing: ongoing,
                                         crossfade: shown == nil ? false : fade)
            }
        }
    }

    /// The series page's season picker, replacing the meta line. With only one
    /// season, just its name is shown.
    private func seasonSelectionFill(_ seasons: [Item], ongoing: Item, seriesKeyID: String) {
        guard let space = playerSeasonSelection else { return }
        wipe(space)
        guard !seasons.isEmpty else { return }
        let initialSelection = seasons.first { $0.id == ongoing.seasonId }
            ?? seasons.first { $0.indexNumber != nil && $0.indexNumber == ongoing.parentIndexNumber }
            ?? seasons[0]

        let pill: Widget! = gtk_button_new()
        gtk_widget_add_css_class(pill, "swiftly-chip")
        gtk_widget_set_halign(pill, GTK_ALIGN_START)
        let content = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let text = label(initialSelection.name)
        append(content, text)
        if seasons.count > 1 {
            append(content, PlayerCharacter("chevron", size: 12).display)
        }
        gtk_button_set_child(asButton(pill), content)
        append(space, pill)

        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(list, "swiftly-staffelliste")
        gtk_widget_set_size_request(list, 220, -1)
        gtk_widget_set_halign(list, GTK_ALIGN_START)
        let expand: Widget! = gtk_revealer_new()
        gtk_revealer_set_transition_type(asExpand(expand), GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN)
        gtk_revealer_set_transition_duration(asExpand(expand), 220)
        gtk_revealer_set_child(asExpand(expand), list)
        gtk_widget_set_margin_top(expand, 8)
        gtk_widget_set_halign(expand, GTK_ALIGN_START)
        append(space, expand)

        var rows: [String: Widget?] = [:]
        for season in seasons {
            let row = seasonRow(season.name, selected: season.id == initialSelection.id) {
                [weak self] in
                guard let self else { return }
                gtk_label_set_text(OpaquePointer(text), season.name)
                for (identifier, w) in rows { self.seasonRowDraw(w, selected: identifier == season.id) }
                gtk_revealer_set_reveal_child(asExpand(expand), 0)
                self.episodesSeasonLoad(season, seriesKeyID: seriesKeyID, ongoing: ongoing, crossfade: true)
            }
            rows[season.id] = row
            append(list, row)
        }
        signal(pill, "clicked") {
            guard seasons.count > 1 else { return }
            let opened = gtk_revealer_get_reveal_child(asExpand(expand)) == 0
            gtk_revealer_set_reveal_child(asExpand(expand), opened ? 1 : 0)
        }
        episodesSeasonLoad(initialSelection, seriesKeyID: seriesKeyID, ongoing: ongoing, crossfade: false)
    }
}

/// **A delay-row button that repeats while held.**
///
/// GTK's button does not repeat by itself (Apple: `buttonRepeatBehavior`).
/// When pressed it waits 0.4 s, then fires every 0.1 s; the
/// ``Verzoegerung/Haltezaehler`` counts them as one series and speeds up.
/// The `clicked` on release no longer counts after a repeat; without a
/// repeat it is the single step, including via keyboard.
final class LagKey: @unchecked Sendable {
    let button: Widget!
    private let symbolText: PlayerCharacter
    private let action: () -> Void
    private var source: guint = 0
    private var beats = 0
    private var repeated = false

    init(button: Widget!, symbolText: PlayerCharacter, action: @escaping () -> Void) {
        self.button = button
        self.symbolText = symbolText
        self.action = action
    }

    /// Disabled and paler at the limit (±10 s).
    func lockOut(_ yes: Bool) {
        gtk_widget_set_sensitive(button, yes ? 0 : 1)
        gtk_widget_set_opacity(symbolText.display, yes ? 0.4 : 1)
        if yes { release() }
    }

    func clicked() {
        if repeated { repeated = false; return }
        action()
    }

    func hold() {
        release()
        repeated = false
        beats = 0
        source = g_timeout_add_full(0, 100, delayTick,
                                    Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func release() {
        if source != 0 { g_source_remove(source); source = 0 }
    }

    fileprivate func tick() -> Bool {
        beats += 1
        guard beats > 4 else { return true }
        guard gtk_widget_get_sensitive(button) != 0 else { source = 0; return false }
        repeated = true
        action()
        return source != 0
    }
}

nonisolated(unsafe) private let delayTick: @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    return Unmanaged<LagKey>.fromOpaque(data).takeUnretainedValue().tick() ? 1 : 0
}
