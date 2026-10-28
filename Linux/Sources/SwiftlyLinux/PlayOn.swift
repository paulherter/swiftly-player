import CGtk
import Foundation
import JellyfinKit

/// **"Übergeben an …": the running title from the player to a TV running
/// Swiftly** (Apple `PlayOutputs`, Android `PlayOn.kt`).
///
/// An action in the player, not a mode: "play" always plays here. The rules are
/// in the package (``PlayTargets``, ``PlayOrder``); here only the list, the TV
/// button in the player and the window. The list comes from the takeover poll,
/// not from a timer of its own.
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

    /// **One row per TV** (Mac `handOverMenu`):
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
}
