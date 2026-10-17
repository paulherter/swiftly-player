import CGtk
import Foundation
import JellyfinKit

// MARK: - Watch together

/// **Watch together, on Linux and Windows.**
///
/// The flow lives in the package (``SyncPlaySession``) and is the same as on
/// iPhone, Mac, TV and Android: create a group, join, leave, the clock, the
/// queue, timed commands, buffering and "ready". Only what depends on this
/// UI is here: the mirror of ``SyncPlayStatus``, the panels, loading a title
/// into the player and the icons for the notices. The template is iOS
/// (`Sources/Shared/SharedModel.swift`,
/// `Sources/iOS/SharedViews.swift`), adapted to desktop: panels
/// anchored to a button instead of sheets (pointer interaction).
///
/// **Everything here belongs to the GTK thread**, like the rest of the app
/// (see `DiscordState.swift`). Only the session itself is an actor; what it
/// needs from the app it fetches via ``fetchOnMainThread(_:)``.
final class SharedState: @unchecked Sendable {
    /// The latest state from the package.
    var status = SyncPlayStatus()
    /// One for the lifetime of the app; at each step it asks for the client that
    /// currently applies.
    var session: SyncPlaySession?
    var hearOut: Task<Void, Never>?
    /// Fetch the permission and poll for groups at the pace of the takeover check.
    var tick: Task<Void, Never>?
    /// Attach, detach and end in the order they happened here; two loose tasks
    /// could overtake each other.
    var chain: Task<Void, Never>?
    /// The open player belongs to the group (iOS: `sharedAn`).
    var an = false
    /// The title the group set last. Until the player is on it, it counts as not
    /// ready.
    var expects: String?
    var player: SharedPlayer?
    /// While the timeline is dragged: the target. The request is only sent on
    /// release, otherwise there would be one per mouse movement.
    var sliderTarget: Double?

    /// The "Gemeinsam schauen" or "Beitreten" panel while it is open.
    var panel: Widget?
    var panelButton: Widget?

    /// The notice at the top of the player.
    var eventWrapper: Widget?
    var eventImage: Widget?
    var eventText: Widget?
    var eventID: UUID?
    /// What the meta line in the player showed last; it is only rebuilt when
    /// that changes.
    var metaState = ""

    /// "Filmabend verlassen · Wieder beitreten" (left the group, with a rejoin
    /// action).
    var strip: Widget?
    var stripText: Widget?

    /// Group error, above everything, including the player.
    var hint: Widget?
    var hintTick = 0
}

/// **What the player provides to the group** (iOS: `SharedPlayer`).
///
/// The session always reads the **current** state; each accessor hops to the
/// GTK thread and reads what applies there.
final class SharedPlayer: SyncPlayPlayer, @unchecked Sendable {
    let app: App
    init(app: App) { self.app = app }

    func title() async -> String {
        await fetchOnMainThread { [app] in app.runningTitle?.id ?? "" }
    }

    /// Is the picture up, and no title change in progress? Not ready while the
    /// group has set a different title than the player shows; otherwise "ready"
    /// would go out for the old one before the new one loads.
    func ready() async -> Bool {
        await fetchOnMainThread { [app] in
            guard let title = app.runningTitle, app.runningPlan != nil else { return false }
            if let expects = app.gemeinsam.expects, expects != title.id { return false }
            return app.playState.firstImagePresent && app.playerLoadingScreen == nil
                && !app.episodesSwitch.running
        }
    }

    func spot() async -> Double {
        await fetchOnMainThread { [app] in app.mediaPlayer.position }
    }

    func proceed() async {
        await fetchOnMainThread { [app] in app.sharedRunState(true) }
    }

    func halt() async {
        await fetchOnMainThread { [app] in app.sharedRunState(false) }
    }

    /// Seeks, and the timeline and button follow right away.
    func jump(_ target: Double) async {
        await fetchOnMainThread { [app] in app.jumpDirect(on: target) }
    }
}

/// `onMainThread` with a result: for the session, which runs as an actor off
/// the main thread and needs a UI value. Never call from the GTK thread.
func fetchOnMainThread<T: Sendable>(_ block: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
        onMainThread { done.resume(returning: block()) }
    }
}

extension App {

    // MARK: The session

    var sharedSession: SyncPlaySession {
        if let s = gemeinsam.session { return s }
        let s = SyncPlaySession(
            client: { [self] in await fetchOnMainThread { self.client } },
            ich: { [self] in
                await fetchOnMainThread { self.username.isEmpty ? nil : self.username }
            },
            titleLoad: { [self] title, since in await self.sharedTitleLoad(title, since: since) })
        gemeinsam.session = s
        gemeinsam.hearOut = Task.detached { [self] in
            for await m in s.withPart {
                onMainThread { self.sharedMessage(m) }
            }
        }
        return s
    }

    /// The group is running in this player (iOS: `inGroup`).
    var inGroup: Bool { gemeinsam.an && gemeinsam.status.group != nil }

    /// Groups on the server that the badge offers; none while the user is in one
    /// or is not allowed to join.
    var sharedOfferings: [SyncPlayGroup] {
        gemeinsam.status.group == nil && gemeinsam.status.mayJoin ? gemeinsam.status.offerings : []
    }

    /// After sign-in, alongside the takeover check: the permission once, the
    /// groups at the same pace, and not while the player is running here.
    func sharedStart() {
        let session = sharedSession
        gemeinsam.tick?.cancel()
        // **End the previous account's session first, then fetch the new account's
        // permission**, otherwise a late `finish()` would clear the permission just
        // fetched.
        let before = gemeinsam.chain
        gemeinsam.tick = Task.detached { [self] in
            await before?.value
            await session.rightFetch()
            while !Task.isCancelled {
                let playsNow = await fetchOnMainThread { self.runningTitle != nil }
                if !playsNow { await session.offeringsAsk() }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// On sign-out and account switch: leave the group, forget everything.
    func sharedEnd() {
        gemeinsam.tick?.cancel()
        gemeinsam.tick = nil
        gemeinsam.an = false
        gemeinsam.expects = nil
        // Leave with the old account's client; the caller sets the new one right
        // afterwards, and the `Leave` would go out in its name.
        let alt = client
        sharedChain { await $0.finish(oldClient: alt) }
    }

    private func sharedChain(_ step: @escaping @Sendable (SyncPlaySession) async -> Void) {
        let session = sharedSession
        let before = gemeinsam.chain
        gemeinsam.chain = Task.detached {
            await before?.value
            await step(session)
        }
    }

    // MARK: What comes from the package

    private func sharedMessage(_ m: SyncPlayMessage) {
        switch m {
        case let .status(new):
            gemeinsam.status = new
            // The group is gone and the player continues alone, so its own buttons
            // apply again.
            if new.group == nil { gemeinsam.sliderTarget = nil }
            takeoverShow()
            sharedEventShow()
            sharedMetaRowUpdate()
            sharedStripShow()
        case let .error(f):
            AppLog.writeOut("[Gemeinsam] Meldung: \(f.text)")
            fflush(nil)
            sharedHint(f.text)
            // The panel stays open; its button works again.
            if let button = gemeinsam.panelButton, let t = gemeinsam.panel, t == openPanel {
                gtk_widget_set_sensitive(button, 1)
            }
        }
    }

    /// **The group sets a title**: switch in the open player, otherwise open the
    /// player. The same title in the open player does not arrive here; the
    /// session seeks itself. `false` if the title or plan cannot be fetched.
    func sharedTitleLoad(_ titleID: String, since: Double) async -> Bool {
        let (client, limit) = await fetchOnMainThread { (self.client, self.selection.profileBitrate) }
        guard let client else { return false }
        // Separate tasks instead of `async let` (see ``nebenher(_:)``).
        let titleFetch = besideFrom { try? await client.item(id: titleID) }
        let planFetch = besideFrom {
            try? await client.playbackPlan(for: titleID, profile: .vlc(maxBitrate: limit))
        }
        let titleFetched = await titleFetch.value
        let planFetched = await planFetch.value
        guard let title = titleFetched, let plan = planFetched else { return false }
        await fetchOnMainThread {
            if self.gemeinsam.an, self.runningTitle != nil {
                // Switch in the open player, the same path as an episode from the episode
                // level (iOS: `switchTitle` -> `toNextEpisode`).
                self.changeInto(title, since: since)
            } else {
                self.playerOpen(title, since: since, prePlanned: plan, group: true)
            }
            // **Only afterwards**: `playerOpen` closes an old player and forgets
            // what the group expects.
            self.gemeinsam.expects = title.id
        }
        return true
    }

    // MARK: From the player

    /// The player is open and belongs to the group.
    func sharedConnect() {
        let s = gemeinsam.player ?? SharedPlayer(app: self)
        gemeinsam.player = s
        gemeinsam.an = true
        gemeinsam.metaState = ""
        sharedChain { await $0.plugIn(s) }
    }

    /// The player closes. **That is leaving the group.**
    func sharedDetach() {
        gemeinsam.an = false
        gemeinsam.expects = nil
        gemeinsam.sliderTarget = nil
        sharedChain { await $0.detach() }
    }

    /// Pause and resume go to the server as requests. The button only flips when
    /// the command comes back, then for everyone at the same time.
    func sharedBitToggle(runningCurrently: Bool) {
        let session = sharedSession
        Task.detached { await session.bitToggle(runningCurrently: runningCurrently) }
        controlsShow()
    }

    func sharedBitJump(on seconds: Double) {
        let session = sharedSession
        Task.detached { await session.bitJump(on: max(0, seconds)) }
    }

    /// Episode choice in the player, in a group: for everyone.
    func sharedBitTitle(_ titleID: String) {
        let session = sharedSession
        Task.detached { await session.bitTitle(titleID) }
    }

    /// Once per player tick: report buffering.
    func sharedTick() {
        let session = sharedSession
        Task.detached { await session.playerTick() }
    }

    /// A group command pauses or resumes; the button and tile of the work
    /// environment follow.
    func sharedRunState(_ running: Bool) {
        guard runningTitle != nil else { return }
        if running { mediaPlayer.play() } else { mediaPlayer.halt() }
        playState.running = running
        playerPlayMarker?.setDown(running)
        mediaStateReport()
    }

    // MARK: Create

    /// "Gemeinsam schauen" for this title: a panel anchored to the button that
    /// opened it (iOS: the sheet in `SharedSheets.create`).
    func sharedCreateShow(_ title: Item, an button: Widget!) {
        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(list, 300, -1)
        gtk_widget_set_margin_start(list, 12)
        gtk_widget_set_margin_end(list, 12)
        gtk_widget_set_margin_top(list, 8)
        gtk_widget_set_margin_bottom(list, 8)

        let header = label(translated("Gemeinsam schauen"), style: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(header), 0)
        append(list, header)
        // Title and episode from the server, verbatim.
        let row = label(Self.sharedTitleRow(title), style: "swiftly-zweitzeile")
        gtk_widget_add_css_class(row, "dim-label")
        gtk_label_set_xalign(OpaquePointer(row), 0)
        gtk_label_set_ellipsize(OpaquePointer(row), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(row), 1)
        gtk_widget_set_margin_top(row, 2)
        gtk_widget_set_margin_bottom(row, 14)
        append(list, row)

        let fieldName = label(translated("Name der Gruppe"), style: "swiftly-uebernahmezeile")
        gtk_label_set_xalign(OpaquePointer(fieldName), 0)
        gtk_widget_set_margin_bottom(fieldName, 6)
        append(list, fieldName)
        let inputField: Widget! = gtk_entry_new()
        gtk_entry_set_placeholder_text(asField(inputField), translated("Filmabend"))
        gtk_editable_set_text(OpaquePointer(inputField), translated("Filmabend"))
        gtk_widget_set_size_request(inputField, -1, Int32(Theme.fieldHeight))
        gtk_widget_set_hexpand(inputField, 1)
        caption(inputField, translated("Name der Gruppe"))
        append(list, inputField)

        let hint = label(
            translated("Alle auf deinem Server sehen die Gruppe und können mit einsteigen. Pause und Springen gelten dann für alle."),
            style: "swiftly-zweitzeile", wrap: true)
        gtk_widget_add_css_class(hint, "dim-label")
        gtk_label_set_xalign(OpaquePointer(hint), 0)
        gtk_label_set_max_width_chars(OpaquePointer(hint), 1)
        gtk_widget_set_margin_top(hint, 14)
        gtk_widget_set_margin_bottom(hint, 18)
        append(list, hint)

        let main = primaryButton(translated("Gruppe öffnen"), symbol: "system-users-symbolic")
        gtk_widget_set_size_request(main, -1, Int32(Theme.primaryButtonHeight))
        gtk_widget_set_halign(main, GTK_ALIGN_FILL)
        append(list, main)

        let panel = panelOpen(an: button)
        gtk_popover_set_child(asPanel(panel), Scaling.wrapped(list))
        gemeinsam.panel = panel
        gemeinsam.panelButton = main
        let fieldBox = PointerBox(inputField)
        signal(main, "clicked") { [weak self] in
            guard let self else { return }
            let name = String(cString: gtk_editable_get_text(OpaquePointer(fieldBox.widget)))
            gtk_widget_set_sensitive(self.gemeinsam.panelButton, 0)
            let session = self.sharedSession
            AppLog.writeOut("[Gemeinsam] Gruppe anlegen fuer \(title.id)")
            fflush(nil)
            Task.detached { [self] in
                await session.create(name: name, title: title.id, accepted: {
                    await fetchOnMainThread { self.sharedPanelClosed() }
                })
            }
        }
        gtk_popover_popup(asPanel(panel))
        gtk_widget_grab_focus(inputField)
    }

    // MARK: Join and choose

    /// The join panel, at the badge (iOS: `SharedSheets.join`).
    func sharedJoinShow(_ g: SyncPlayGroup, an button: Widget!) {
        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(list, 300, -1)
        gtk_widget_set_margin_start(list, 12)
        gtk_widget_set_margin_end(list, 12)
        gtk_widget_set_margin_top(list, 8)
        gtk_widget_set_margin_bottom(list, 8)

        // Name and participants come from the server, verbatim.
        let header = label(g.name, style: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(header), 0)
        gtk_label_set_ellipsize(OpaquePointer(header), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(header), 1)
        append(list, header)
        let wer = label(sharedWer(g), style: "swiftly-zweitzeile", wrap: true)
        gtk_widget_add_css_class(wer, "dim-label")
        gtk_label_set_xalign(OpaquePointer(wer), 0)
        gtk_label_set_max_width_chars(OpaquePointer(wer), 1)
        gtk_widget_set_margin_top(wer, 2)
        append(list, wer)
        if let condition = Self.sharedStateText(g.condition) {
            let z = label(condition, style: "swiftly-uebernahmezeile")
            gtk_widget_add_css_class(z, "swiftly-akzentschrift")
            gtk_label_set_xalign(OpaquePointer(z), 0)
            gtk_widget_set_margin_top(z, 6)
            append(list, z)
        }
        let rule = label(translated("Pause und Springen gelten für alle."),
                                 style: "swiftly-uebernahmezeile", wrap: true)
        gtk_label_set_xalign(OpaquePointer(rule), 0)
        gtk_label_set_max_width_chars(OpaquePointer(rule), 1)
        gtk_widget_set_margin_top(rule, 10)
        gtk_widget_set_margin_bottom(rule, 18)
        append(list, rule)

        let main = primaryButton(translated("Beitreten"), symbol: "system-users-symbolic")
        gtk_widget_set_size_request(main, -1, Int32(Theme.primaryButtonHeight))
        gtk_widget_set_halign(main, GTK_ALIGN_FILL)
        append(list, main)

        let panel = panelOpen(an: button)
        gtk_popover_set_child(asPanel(panel), Scaling.wrapped(list))
        gemeinsam.panel = panel
        gemeinsam.panelButton = main
        signal(main, "clicked") { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(self.gemeinsam.panelButton, 0)
            self.sharedJoin(g)
        }
        gtk_popover_popup(asPanel(panel))
    }

    private func sharedJoin(_ g: SyncPlayGroup) {
        let session = sharedSession
        AppLog.writeOut("[Gemeinsam] beitreten \(g.id)")
        fflush(nil)
        Task.detached { [self] in
            await session.join(g, accepted: {
                await fetchOnMainThread { self.sharedPanelClosed() }
            })
        }
    }

    /// **If something is playing elsewhere and a group exists**, a panel asks
    /// what is meant (iOS: `SharedSheets.pick`): devices get "Hier
    /// weiterschauen", groups get "Beitreten".
    func sharedSelectionShow(devices: [RemoteSession], groups: [SyncPlayGroup],
                                an button: Widget!) {
        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_size_request(list, 320, -1)
        let header = label(translated("Läuft gerade"), style: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(header), 0)
        gtk_widget_set_margin_start(header, 12)
        gtk_widget_set_margin_top(header, 6)
        gtk_widget_set_margin_bottom(header, 4)
        append(list, header)

        let panel = panelOpen(an: button)
        gtk_popover_set_child(asPanel(panel), Scaling.wrapped(list))
        gemeinsam.panel = panel
        gemeinsam.panelButton = nil
        for s in devices {
            append(list, sharedOfferingRow(
                symbol: devicesCharacter(s.devicesKind),
                title: s.deviceName ?? translated("Gerät"), under: s.titleLine,
                action: translated("Hier weiterschauen")) { [weak self] in
                gtk_popover_popdown(asPanel(panel))
                self?.adopt(s)
            })
        }
        for g in groups {
            append(list, sharedOfferingRow(
                symbol: "system-users-symbolic", title: g.name, under: sharedWer(g),
                action: translated("Beitreten")) { [weak self] in
                self?.sharedJoin(g)
            })
        }
        AppLog.writeOut("[Gemeinsam] Auswahl mit \(devices.count) Geraeten, \(groups.count) Gruppen")
        fflush(nil)
        gtk_popover_popup(asPanel(panel))
    }

    /// Icon, name with a line below, the action on the right in the accent
    /// color; 58 high like the row in the sheet on iPhone.
    private func sharedOfferingRow(symbol: String, title: String, under: String,
                                        action: String,
                                        perform: @escaping () -> Void) -> Widget! {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-handlung")
        gtk_widget_add_css_class(button, "swiftly-angebotszeile")
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        let image: Widget! = gtk_image_new_from_icon_name(symbol)
        gtk_image_set_pixel_size(OpaquePointer(image), 16)
        gtk_widget_add_css_class(image, "swiftly-akzentzeichen")
        gtk_widget_set_size_request(image, 26, -1)
        append(rail, image)
        let text = stack(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(text, 1)
        let top = label(title, style: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(top), 0)
        gtk_label_set_ellipsize(OpaquePointer(top), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(top), 1)
        append(text, top)
        let bottomRow = label(under, style: "swiftly-uebernahmezeile")
        gtk_label_set_xalign(OpaquePointer(bottomRow), 0)
        gtk_label_set_ellipsize(OpaquePointer(bottomRow), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(bottomRow), 1)
        append(text, bottomRow)
        append(rail, text)
        let actionLabel = label(action, style: "swiftly-kacheltitel")
        gtk_widget_add_css_class(actionLabel, "swiftly-akzentschrift")
        append(rail, actionLabel)
        gtk_button_set_child(asButton(button), rail)
        caption(button, "\(title), \(under), \(action)")
        signal(button, "clicked", perform)
        return button
    }

    /// Close the panel because the server said yes, but only if it is still ours.
    private func sharedPanelClosed() {
        if let t = gemeinsam.panel, t == openPanel { gtk_popover_popdown(asPanel(t)) }
        gemeinsam.panel = nil
        gemeinsam.panelButton = nil
    }

    // MARK: In the player

    /// Briefly at the top of the picture: who joined, who left, why playback
    /// stopped (iOS: `GroupsEvent`). Takes no clicks.
    func sharedEventBuild() -> Widget! {
        let wrapper = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_add_css_class(wrapper, "swiftly-gruppenereignis")
        gtk_widget_set_halign(wrapper, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(wrapper, GTK_ALIGN_START)
        gtk_widget_set_margin_top(wrapper, PlayerMetric.top + PlayerMetric.button + 8)
        gtk_widget_set_can_target(wrapper, 0)
        gtk_widget_set_opacity(wrapper, 0)
        let image: Widget! = gtk_image_new_from_icon_name("system-users-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(image), 15)
        gtk_widget_add_css_class(image, "swiftly-akzentzeichen")
        append(wrapper, image)
        let text = label("", style: "swiftly-koerper")
        append(wrapper, text)
        gemeinsam.eventWrapper = wrapper
        gemeinsam.eventImage = image
        gemeinsam.eventText = text
        gemeinsam.eventID = nil
        signal(wrapper, "destroy") { [weak self] in
            guard let self else { return }
            // Only forget it if it is still this notice; the new player page is already
            // up when the old one is torn down.
            if self.gemeinsam.eventWrapper == wrapper {
                self.gemeinsam.eventWrapper = nil
                self.gemeinsam.eventImage = nil
                self.gemeinsam.eventText = nil
            }
        }
        return wrapper
    }

    private func sharedEventShow() {
        guard let wrapper = gemeinsam.eventWrapper else { return }
        guard inGroup, let e = gemeinsam.status.event else {
            if gemeinsam.eventID != nil {
                gemeinsam.eventID = nil
                crossfade(wrapper, on: 0, duration: 0.2, curve: .easeInOut)
            }
            return
        }
        guard e.id != gemeinsam.eventID else { return }
        gemeinsam.eventID = e.id
        gtk_image_set_from_icon_name(OpaquePointer(gemeinsam.eventImage), Self.sharedCharacter(e.art))
        gtk_label_set_text(OpaquePointer(gemeinsam.eventText), e.text)
        caption(wrapper, e.text)
        crossfade(wrapper, on: 1, duration: 0.2, curve: .easeOut)
    }

    /// The icon per notice: the platform chooses, the text comes from the
    /// package. Names checked against breeze-dark.
    static func sharedCharacter(_ art: SyncPlayEvent.Art) -> String {
        switch art {
        case .present, .gone: "system-users-symbolic"
        case .waitsOnAll: "content-loading-symbolic"
        case .halted: "media-playback-pause-symbolic"
        case .goesNext: "media-playback-start-symbolic"
        case .jumped: "media-seek-forward-symbolic"
        case .noAccess, .notPlayable: "dialog-warning-symbolic"
        }
    }

    /// "Filmabend · mit Anna und Ben" where season and episode otherwise are
    /// (iOS: `GroupsRow`). The name carries the accent: being in a group is a
    /// state.
    func sharedGroupsRow(_ row: Widget!) -> Bool {
        guard inGroup, let g = gemeinsam.status.group else { return false }
        let image: Widget! = gtk_image_new_from_icon_name("system-users-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(image), Int32(Theme.secondLine + 1))
        gtk_widget_add_css_class(image, "swiftly-akzentzeichen")
        append(row, image)
        // Name and participants from the server, verbatim.
        let name = label(g.name, style: "swiftly-spielerzeile")
        gtk_widget_add_css_class(name, "swiftly-gruppenname")
        append(row, name)
        let wer = label("· " + sharedWithWhom, style: "swiftly-spielerzeile")
        gtk_label_set_ellipsize(OpaquePointer(wer), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(wer), 0)
        append(row, wer)
        return true
    }

    private func sharedMetaRowUpdate() {
        let state = inGroup ? "\(gemeinsam.status.group?.name ?? "")|\(sharedWithWhom)" : ""
        guard state != gemeinsam.metaState else { return }
        gemeinsam.metaState = state
        metaRowRefresh()
    }

    /// The "Gemeinsam · Filmabend" column in the player settings: who is in,
    /// and the exit below it. The names do nothing (iOS: `PlayerLayers.swift`).
    func sharedColumn() -> Widget? {
        guard inGroup, let g = gemeinsam.status.group else { return nil }
        return layersColumn(String(format: translated("Gemeinsam · %@"), g.name)) { space in
            for name in g.participant {
                let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
                gtk_widget_add_css_class(rail, "swiftly-teilnehmer")
                let image: Widget! = gtk_image_new_from_icon_name("avatar-default-symbolic")
                gtk_image_set_pixel_size(OpaquePointer(image), 14)
                gtk_widget_set_size_request(image, 18, -1)
                gtk_widget_add_css_class(image, "swiftly-sehrleise")
                append(rail, image)
                let l = label(name)
                gtk_label_set_xalign(OpaquePointer(l), 0)
                gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
                gtk_label_set_max_width_chars(OpaquePointer(l), 1)
                gtk_widget_set_hexpand(l, 1)
                append(rail, l)
                append(space, rail)
            }
            let button: Widget! = gtk_button_new()
            gtk_widget_add_css_class(button, "swiftly-ebenenzeile")
            gtk_widget_add_css_class(button, "swiftly-verlassen")
            let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let image: Widget! = gtk_image_new_from_icon_name("system-log-out-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(image), 14)
            gtk_widget_set_size_request(image, 18, -1)
            append(rail, image)
            let l = label(translated("Gruppe verlassen"))
            gtk_label_set_xalign(OpaquePointer(l), 0)
            gtk_widget_set_hexpand(l, 1)
            append(rail, l)
            gtk_button_set_child(asButton(button), rail)
            caption(button, translated("Gruppe verlassen"))
            // Leaving means closing the player.
            signal(button, "clicked") { [weak self] in self?.playerClose() }
            append(space, button)
        }
    }

    // MARK: The way back

    /// "Filmabend verlassen · Wieder beitreten": undo instead of a prompt, for
    /// eight seconds (iOS: `ReturnPathStrip`). Same place as every notice:
    /// bottom center, above everything.
    private func sharedStripShow() {
        guard let alt = gemeinsam.status.lastLeave else {
            if let s = gemeinsam.strip {
                gtk_widget_set_can_target(s, 0)
                crossfade(s, on: 0, duration: 0.2, curve: .easeInOut)
            }
            return
        }
        let strip = gemeinsam.strip ?? sharedStripBuild()
        guard let strip else { return }
        gtk_label_set_text(OpaquePointer(gemeinsam.stripText),
                           String(format: translated("%@ verlassen"), alt.name))
        gtk_widget_set_can_target(strip, 1)
        crossfade(strip, on: 1, duration: 0.2, curve: .easeOut)
    }

    private func sharedStripBuild() -> Widget? {
        guard let cover = windowCover else { return nil }
        let strip = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_widget_add_css_class(strip, "swiftly-rueckweg")
        gtk_widget_set_halign(strip, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(strip, GTK_ALIGN_END)
        gtk_widget_set_margin_bottom(strip, 34)
        gtk_widget_set_margin_start(strip, 24)
        gtk_widget_set_margin_end(strip, 24)
        gtk_widget_set_opacity(strip, 0)
        let text = label("", style: "swiftly-rueckwegtext")
        gtk_label_set_ellipsize(OpaquePointer(text), PANGO_ELLIPSIZE_END)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        append(strip, text)
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-rueckwegknopf")
        gtk_button_set_child(asButton(button), label(translated("Wieder beitreten")))
        caption(button, translated("Wieder beitreten"))
        signal(button, "clicked") { [weak self] in
            guard let self else { return }
            let session = self.sharedSession
            Task.detached { await session.againJoin() }
        }
        append(strip, button)
        gtk_overlay_add_overlay(OpaquePointer(cover), strip)
        gemeinsam.strip = strip
        gemeinsam.stripText = text
        return strip
    }

    // MARK: Errors

    /// **A group error must be visible wherever the user is**, in the main window
    /// and in the player. Same building block as ``report(_:)``
    /// (`swiftly-hinweis`, three seconds), but above the whole window:
    /// `hintField` hangs on the detail page, which is not always there.
    private func sharedHint(_ text: String) {
        guard let cover = windowCover else { return }
        let inputField: Widget
        if let present = gemeinsam.hint {
            inputField = present
        } else {
            let new: Widget! = label("", style: "swiftly-hinweis", wrap: true)
            gtk_label_set_max_width_chars(OpaquePointer(new), 60)
            gtk_widget_set_halign(new, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(new, GTK_ALIGN_END)
            gtk_widget_set_margin_bottom(new, 32)
            gtk_widget_set_margin_start(new, 24)
            gtk_widget_set_margin_end(new, 24)
            gtk_widget_set_can_target(new, 0)
            gtk_overlay_add_overlay(OpaquePointer(cover), new)
            gemeinsam.hint = new
            inputField = new
        }
        gtk_label_set_text(OpaquePointer(inputField), text)
        gtk_widget_set_visible(inputField, 1)
        gtk_widget_set_opacity(inputField, 1)
        gemeinsam.hintTick += 1
        let mine = gemeinsam.hintTick
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            onMainThread {
                guard self.gemeinsam.hintTick == mine, let inputField = self.gemeinsam.hint
                else { return }
                gentle(on: inputField, from: 1, to: 0) { gtk_widget_set_opacity(inputField, $0) }
            }
        }
    }

    // MARK: Texts

    /// "mit Anna und Ben", without the user themselves.
    var sharedWithWhom: String {
        guard let g = gemeinsam.status.group else { return "" }
        let other = g.other(asValue: username.isEmpty ? nil : username)
        guard !other.isEmpty else { return translated("noch niemand dabei") }
        return String(format: translated("mit %@"), Self.sharedList(other))
    }

    /// "Anna und Ben schauen gerade".
    func sharedWer(_ g: SyncPlayGroup) -> String {
        var watched = Set<String>()
        let names = g.participant.filter { watched.insert($0).inserted }
        guard !names.isEmpty else { return translated("Noch niemand dabei") }
        let list = Self.sharedList(names)
        return String(format: translated(names.count == 1 ? "%@ schaut gerade" : "%@ schauen gerade"),
                      list)
    }

    /// "Anna, Ben und Carla" in the UI language. `ListFormatter` does not exist
    /// on Linux, but the format style of the new Foundation does.
    static func sharedList(_ names: [String]) -> String {
        names.formatted(.list(type: .and).locale(Locale(identifier: upperAreasCatalog.language)))
    }

    /// For an episode, the series with season and episode; otherwise the panel
    /// does not say which episode the group will watch.
    static func sharedTitleRow(_ title: Item) -> String {
        guard title.type == "Episode", let series = title.seriesName, !series.isEmpty else {
            return title.name
        }
        if let season = title.parentIndexNumber, let episode = title.indexNumber {
            return "\(series) · " + String(format: translated("Staffel %lld · Folge %lld"), season, episode)
        }
        return "\(series) · \(title.name)"
    }

    static func sharedStateText(_ z: SyncPlayGroup.Phase?) -> String? {
        switch z {
        case .running: translated("Läuft gerade")
        case .halted: translated("Angehalten")
        case .waits: translated("Wartet auf alle")
        case .empty, nil: nil
        }
    }
}
