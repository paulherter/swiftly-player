import CGtk
import Foundation
import JellyfinKit

/// **"Senden an": a title from here to a TV running Swiftly** (Apple
/// `PlayOutputs`, Android `PlayOn.kt`).
///
/// An action on the title (its tile, its page, the running player), not a mode:
/// "play" always plays here. The rules are in the package (``PlayTargets``,
/// ``PlayOrder``); here only the lists, the TV button in the player and the
/// receiving end. The list comes from the takeover poll, not from a timer of its
/// own.
extension App {

    // MARK: List

    /// From the takeover poll.
    func playTargetsTake(_ sessions: [RemoteSession]) {
        let fresh = PlayTargets.targets(from: sessions, ownDevicesIdentifier: Device.identifier,
                                        ownUserIdentifier: userIdentifier)
        if fresh.map(\.id) != playTargets.map(\.id) {
            AppLog.writeOut("[Abspielen auf] \(fresh.count) Ziele: "
                + fresh.map { PlayTargets.name(of: $0) }.joined(separator: ", "))
        }
        playTargets = fresh
    }

    // MARK: Choosing

    /// **"Senden an" on a tile or a detail page**: the TVs in reach, in the
    /// centered window. A series goes as the episode the viewer is at, as "play"
    /// on its tile does.
    func playSendShow(_ item: Item) {
        guard !playTargets.isEmpty else { return }
        // The title heads the window; "Senden an" was on the button that opened it.
        playTargetsWindow(Self.sharedTitleRow(item)) { [weak self] output in
            self?.playSendTitle(item, to: output)
        }
    }

    /// **One row per TV, the same window wherever it opens** (Mac `sendList`):
    /// device, what it plays (a TV that plays nothing has no second line) and
    /// "Senden". The window closes before the choice runs.
    private func playTargetsWindow(_ heading: String, closed: (() -> Void)? = nil,
                                   choose: @escaping (PlayOutput) -> Void) {
        let list = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        var first: Widget?
        for session in playTargets {
            guard let output = PlayOutput(session: session) else { continue }
            append(list, divider())
            let row = sharedOfferingRow(
                symbol: devicesCharacter(session.devicesKind), title: output.name,
                under: session.running == nil ? "" : session.titleLine,
                action: translated("Senden")) { [weak self] in
                self?.panelWindowClose()
                choose(output)
            }
            append(list, row)
            if first == nil { first = row }
        }
        panelWindowOpen(heading, content: list, closed: closed)
        // The keyboard starts in the window, not on the button behind the veil.
        if let first { gtk_widget_grab_focus(first) }
    }

    private func playSendTitle(_ item: Item, to output: PlayOutput) {
        guard item.type == "Series" else { playSend(item, since: nil, sourceID: nil, to: output); return }
        guard let client else { return }
        Task.detached { [self] in
            let episode = await client.stateInSeries(item.id)
            onMainThread {
                guard let episode else { self.report(translated("Danach kommt nichts mehr.")); return }
                self.playSend(episode, since: nil, sourceID: nil, to: output)
            }
        }
    }

    // MARK: Sending

    /// **The current session of the chosen device**, from a fresh list: the one
    /// in the menu may be five seconds old, and the TV may have restarted since.
    ///
    /// Gone means a message and nothing playing here instead: a film starting here
    /// while the viewer looks at the TV is not what was asked for.
    private func playSession(_ output: PlayOutput, client: JellyfinClient) async -> RemoteSession? {
        let sessions: [RemoteSession]
        do {
            sessions = try await client.remoteSession()
        } catch {
            // Not "gone": the server did not answer.
            AppLog.writeOut("[Abspielen auf] Abfrage fehlgeschlagen: \(error)")
            let text = readableError(error)
            onMainThread { self.report(text) }
            return nil
        }
        let user = userIdentifier
        let targets = PlayTargets.targets(from: sessions, ownDevicesIdentifier: Device.identifier,
                                          ownUserIdentifier: user)
        if let session = PlayTargets.session(for: output, in: targets) {
            onMainThread { self.playTargets = targets }
            return session
        }
        AppLog.writeOut("[Abspielen auf] \(output.name) nicht mehr da")
        onMainThread {
            self.playTargets = targets
            self.report(String(format: translated("„%@“ ist nicht mehr erreichbar."), output.name))
        }
        return nil
    }

    /// **"Play" here, played on the chosen device.** Only IDs, position and track
    /// indices go out: the TV fetches its own plan with its own profile
    /// (``PlayOrder``). The title is fetched fresh for its position and its
    /// `MediaSources`; a list entry carries neither reliably.
    func playSend(_ item: Item, since: Double?, sourceID: String?, to output: PlayOutput) {
        guard let client else { return }
        let memory = trackMemory()
        let audioLanguage = selection.audioLanguage, subtitleLanguage = selection.subtitleLanguage
        let automatic = selection.subtitleAutomatic
        Task.detached { [self] in
            guard let session = await self.playSession(output, client: client) else { return }
            let fresh = (try? await client.item(id: item.id)) ?? item
            let key = TrackMemory.title(for: fresh)
            let order = PlayOrder.title(fresh, start: since ?? fresh.resumeFrom ?? 0, sourceID: sourceID,
                                        rememberedAudio: memory.audio(for: key),
                                        rememberedSubtitle: memory.subtitle(for: key),
                                        automatic: automatic, audioLanguage: audioLanguage,
                                        subtitleLanguage: subtitleLanguage)
            _ = await self.playDeliver(order, to: session, client: client)
        }
    }

    private func playDeliver(_ order: PlayOrder, to session: RemoteSession,
                             client: JellyfinClient) async -> Bool {
        let name = PlayTargets.name(of: session)
        do {
            try await client.playOn(session: session.id, order: order)
        } catch {
            AppLog.writeOut("[Abspielen auf] an \(name) fehlgeschlagen: \(error)")
            let text = readableError(error)
            onMainThread { self.report(text) }
            return false
        }
        AppLog.writeOut("[Abspielen auf] \(order.itemID ?? "?") ab \(Int(order.start)) s an \(name)"
            + " · Ton \(order.audioIndex.map(String.init) ?? "—")"
            + " · Untertitel \(order.subtitleIndex.map(String.init) ?? "—")")
        onMainThread { self.report(String(format: translated("Spielt auf „%@“"), name)) }
        return true
    }

    // MARK: From the player

    /// **Whether the player offers "Übergeben an …"**: only with a TV in reach, not
    /// in a group (the film belongs to everyone, who would be left without a
    /// word) and not for a file on this computer (the TV cannot open it). The same
    /// rule as `handOverMenu` on the Mac and iOS.
    var playHandOverShown: Bool {
        !playTargets.isEmpty && !inGroup && runningPlan?.url.isFileURL == false
    }

    /// **The TV button and the title's reserved width move together.** Called
    /// whenever one of the conditions changes; otherwise the title would run
    /// under a button that appeared, or stop short of one that left. An open TV
    /// window closes with its button.
    func playHandOverRefresh() {
        guard let button = playerHandOverButton else { return }
        let shown = playHandOverShown
        if !shown, handOverOpen { panelWindowClose() }
        gtk_widget_set_visible(button, shown ? 1 : 0)
        if let slot = playerRailsSlot { gtk_widget_set_size_request(slot, iconRailsWidth(), 1) }
    }

    /// **"Übergeben an …" from the player's icon row** (Mac and iOS `handOverMenu`,
    /// Android `HandOverButton`): the TVs in reach, in the centered window over
    /// the film. Same position, same version, the tracks that are playing.
    func playHandOverShow() {
        guard playHandOverShown else { return }
        // The heading says what the window is for: the button carries only an icon.
        playTargetsWindow(translated("Übergeben an …"), closed: { [weak self] in
            guard let self else { return }
            self.handOverOpen = false
            // The clock starts again from here, not from the click that opened the window.
            self.controlsShow()
        }) { [weak self] output in
            self?.playHandOver(to: output)
        }
        // Only once it stands: opening closed any earlier window, and its "closed"
        // cleared the flag.
        handOverOpen = panelWindow != nil
    }

    /// The player closes only once the TV took it; the picture then leaves as a
    /// card, as for a takeover (`handoffHandIn(an:)`).
    private func playHandOver(to output: PlayOutput) {
        guard let client, let title = runningTitle, let plan = runningPlan else { return }
        let seconds = playState.leap?.target ?? mediaPlayer.position
        let order = PlayOrder(itemID: title.id, start: seconds, mediaSourceID: plan.mediaSourceID,
                              tracks: trackStatus.reported)
        Task.detached { [self] in
            guard let session = await self.playSession(output, client: client),
                  await self.playDeliver(order, to: session, client: client) else { return }
            onMainThread { self.handoffHandIn(an: output.name) }
        }
    }

    // MARK: Receiving

    /// **A title another device sent here**: the same path as a click on "play",
    /// with position, version and tracks from the order. A running film is
    /// replaced, as the Jellyfin web client does; it closes through its own stop,
    /// so its end is reported like any other.
    func playReceived(_ order: PlayOrder) {
        guard let client, let id = order.itemID else { return }
        if runningTitle != nil { playerClose() }
        Task.detached { [self] in
            guard let item = try? await client.item(id: id) else {
                onMainThread { self.report(translated("Der Titel vom anderen Gerät ließ sich nicht laden.")) }
                return
            }
            onMainThread {
                self.playOrderedTracks = (id, order.tracks)
                self.launch(item, since: order.start, sourceID: order.mediaSourceID)
            }
        }
    }
}
