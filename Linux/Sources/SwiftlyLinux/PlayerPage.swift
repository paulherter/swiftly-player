import CGtk
import Foundation
import JellyfinKit

/// **The player looks the same on every platform**: the two tools (playback and close,
/// in that order) at top right, title and episode bottom left, timeline below,
/// the three buttons centered.
///
/// The window controls sit in the title bar on GTK, about fifty points above the
/// tools, so the two never collide. Picture-in-picture is omitted, as on the Mac
/// (VLCKit does not support it); there is no counterpart under Wayland.
///
/// What the player does and what the server learns is decided by the package, not
/// this file: ``PlaybackTick``, ``EpisodeEnd`` and ``TimeAssumption``. This file
/// only covers appearance and who is asked when.
extension App {

    /// **The window title bar stays visible, also in the player.**
    ///
    /// Hiding it (as the Mac does with its window controls) does not work: under
    /// Wayland the title bar belongs to the compositor/window, and hiding it changes
    /// the content height **in the middle of the slide-in**, so the whole picture
    /// jumps by that height. That was the stutter.
    ///
    /// This is the one deviation that cannot be removed without losing the window
    /// buttons; it is in the same group as the thin header above the sidebar.
    /// **`fromFile` is the path without a server.**
    ///
    /// A download must play even when the server is off. The plan from `/PlaybackInfo`
    /// is skipped, and with it all reports to the server, since there is nobody to
    /// report to. Everything else (controls, skip markers, tech badge) is the same path.
    /// - Parameter vorgeplant: the plan, if already fetched; the group fetches it to
    ///   know whether the title is playable here.
    /// - Parameter gruppe: the group (watch together) that opens this player.
    func playerOpen(_ item: Item, since: Double, fromFile file: URL? = nil,
                        pointFresh: Bool = false, prePlanned: PlaybackPlan? = nil,
                        group: Bool = false) {
        guard client != nil || file != nil else { return }
        // Volume persists across titles (Mac: `playerLautstaerke`).
        mediaPlayer.volumeSet(Int((selection.volume * 100).rounded()))
        // Delay: the same title or series keeps it, otherwise null. Reset before closing,
        // below, which clears `runningTitle`.
        mediaPlayer.delayForNewTitle(oldTitle: runningTitle?.id ?? "",
                                             oldSeries: runningTitle?.seriesId,
                                             newTitle: item.id, addedSeries: item.seriesId)
        // **The window state from before**: remembered only on first open, not on an
        // episode change inside a running player.
        if runningTitle == nil {
            fullscreenPrePlayer = gtk_window_is_fullscreen(asWindow(window)) != 0
            // A new player counts anew (Mac: `counted` per `PlayerScreen`),
            // and the Discord hint does not sit over the picture.
            countedTitle = nil
            discordCardDistance()
        }
        AppLog.withClock("Player schliessen") {
            playerClose(report: true, windowBack: false)
        }
        // **No picture of the previous title.** Closing keeps the picture, and playback
        // stops only after the 380 ms slide. Anyone opening the next title within that
        // window would otherwise see and hear the old one until the new plan arrives.
        AppLog.withClock("VLC anhalten") { mediaPlayer.finish(onlyMedium: true) }
        episodesSwitch = EpisodeSwitch()
        prefetchedEpisode = nil
        offeringLayer.newEpisode()

        runningTitle = item
        teardowns = 0
        playState = PlaybackTick.Snapshot()
        sinceOpen = Date()
        // **Watch together**: if the title belongs to what the group is watching, the
        // player attaches to the group before building, so the meta line and settings
        // show the group right away (iOS `onAppear`).
        if file == nil, group || gemeinsam.status.belongsGroup(item.id) {
            sharedConnect()
        }
        lastTick = nil
        // **The path from tap to picture, step by step.**
        //
        // These lines log what happens between tapping Play and opening the player.
        // Without them, a slow server and a slow start on our side cannot be told apart.
        AppLog.writeOut("[Spieler] Abspielen gedrueckt, \(item.type ?? "?"), ab \(Int(since)) s"
            + (file != nil ? ", aus Datei" : ""))
        openLayer = nil
        openLayerArt = nil
        // Check once per title whether the server has preview images. File playback
        // (below) has no server to ask.
        playerTrickplay = TrickplayImages()

        let page = AppLog.withClock("Spielerseite bauen") { playerPageBuild(item) }
        // **Every player page gets its own name.** Calling all of them "spieler" only worked
        // while the previous one was removed from the stack immediately on close, which
        // removed its slide-down. With a running counter, old and new page can sit side
        // by side for the duration of the slide without clashing over the name.
        playerCounter += 1
        gtk_stack_add_named(OpaquePointer(pages), page, "spieler-\(playerCounter)")
        // **Cross-fade, 0.3 s**, as on the Mac (`MainView.swift`,
        // `.animation(.easeInOut(duration: 0.3), value: controls.wish?.id)`),
        // iPhone and Apple TV: the player fades in and out. **No fade under the handover
        // card**: the card is the transition.
        gtk_stack_set_transition_type(OpaquePointer(pages),
                                      handoff?.role == .receiver ? GTK_STACK_TRANSITION_TYPE_NONE
                                                                      : GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_set_transition_duration(OpaquePointer(pages), 300)
        PushLock.of(0.3)
        gtk_stack_set_visible_child_name(OpaquePointer(pages), "spieler-\(playerCounter)")

        // **Fetch the plan first, then open.** The URL is not in `Item`; it comes from
        // `/PlaybackInfo`, which also decides whether the server transcodes. No plan, no picture.
        // **Playing from a file starts immediately.** No plan, no sections, no reports:
        // there is no server to know about them.
        if let file {
            runningPlan = nil
            trackStatusNew(item, plan: nil)
            // Without a plan, the video codec comes from the download item (``Downloadposten/bildcodec``).
            mediaPlayer.open(file, since: since, buffer: selection.buffer,
                              softwareDecoder: PlaybackPlan.fromSlab(
                                  file, container: nil,
                                  videoCodec: downloads.entries(for: item.id)?.videoCodec).softwareDecoder,
                              curve: ColorInfo.curve(source: item.mediaSources?.first))
            mediaPlayer.fillFrame(selection.fillFrame)
            techBadgeSet(selection.techBadge)
            playState.position = since
            tickStart()
            // **Sections and next episode also without a server**: the sections are stored
            // on the download item, and the next episode is the next downloaded one.
            // With a server, the package asks it first.
            lookUp(for: item, change: episodesSwitch, client: client)
            return
        }
        guard let client else { return }

        // **Read the limit before leaving the thread.** `selection` belongs to the main
        // thread and must not be touched from the detached task.
        let limit = selection.profileBitrate
        // **Fetch sections while the plan is in flight.** Intro and credits come from
        // the server. Without them only the remaining-time rule decides; with them the
        // button appears at the position stored in the file. `SectionLogic` in the
        // package already handles this.
        let change = episodesSwitch
        AppLog.withClock("Abschnitte anstossen") {
            lookUp(for: item, change: change, client: client)
        }
        // **The response belongs to exactly this open.** The player is already up and the
        // plan arrives later. If the user closes or opens another title meanwhile, the
        // movie would play without a player, or the first title's picture would show in the second.
        let myOwn = playerCounter
        // **And to exactly this account.** If the account changes or the user signs out
        // while waiting, the URL and flags of the previous account would end up in the
        // player while the UI already shows the new one. Remember the state before
        // waiting and compare afterwards, as at the other load sites in `App.swift`.
        let state = accountSwitch
        let pressed = Date()
        AppLog.writeOut("[Spieler] frage Abspielplan beim Server")
        Task.detached { [self] in
            // Alongside the plan, not before it: costs no extra wait time.
            // Separate task instead of `async let` (see ``nebenher(_:)``).
            let freshValue = pointFresh ? besideFrom { try? await client.item(id: item.id) } : nil
            // If the server refuses with a reason (`ErrorCode`), the message states the reason
            // instead of "no data came", as on Apple via `AppModel.plan`. The group may
            // already have fetched the plan.
            let plan: PlaybackPlan?
            var rejection: String?
            if let prePlanned {
                plan = prePlanned
            } else {
                do {
                    plan = try await client.playbackPlan(for: item.id, profile: .vlc(maxBitrate: limit))
                } catch let error as JellyfinError {
                    plan = nil
                    if case .playbackRejected = error { rejection = readableError(error) }
                } catch {
                    plan = nil
                }
            }
            let rejected = rejection
            let planPost = Date().timeIntervalSince(pressed)
            let fetched = await freshValue?.value ?? nil
            let allPost = Date().timeIntervalSince(pressed)
            let spot = fetched.map { $0.resumeFrom ?? 0 } ?? since
            if pointFresh {
                AppLog.writeOut("[Spieler] Stelle frisch \(fetched.map { _ in String(Int(spot)) } ?? "nicht geholt"), Kachel \(Int(since)) s")
                fflush(nil)
            }
            onMainThread {
                guard self.playerCounter == myOwn, self.runningTitle?.id == item.id,
                      self.episodesSwitch === change,
                      self.accountSwitch == state, self.client === client else {
                    AppLog.writeOut("[Spieler] Plan verworfen, Player zu, anderer Titel oder Konto \(item.id)")
                    fflush(nil)
                    return
                }
                guard let plan else {
                    AppLog.writeOut("[Spieler] kein Plan \(item.id)")
                    fflush(nil)
                    // **The error names the server, not just "failed".** With several servers it is
                    // otherwise unclear which one is meant. Wording matches the Mac
                    // (`PlayControls.starte`).
                    if let rejected {
                        self.playerMessage(rejected)
                        return
                    }
                    let wo = self.serverName.isEmpty ? translated("dem Server") : self.serverName
                    self.playerMessage(
                        String(format: translated("Die Wiedergabe hat nicht geklappt. Von %@ kamen keine Daten zum Abspielen."), wo))
                    return
                }
                AppLog.writeOut(String(format:
                    "[Spieler] Plan da nach %.1f s (Stelle frisch nach %.1f s), %@",
                    planPost, allPost,
                    "\(plan.method), \(plan.container ?? "ohne Container")"))
                self.runningPlan = plan
                self.trackStatusNew(item, plan: plan)
                self.playerTrickplay?.load(client: client, item: item, plan: plan)
                self.chapterLoad(client: client, item: item, plan: plan)
                self.warningShow(plan)
                AppLog.withClock("VLC oeffnen") {
                    self.mediaPlayer.open(plan.url, since: spot, buffer: self.selection.buffer,
                                          softwareDecoder: plan.softwareDecoder,
                                          curve: ColorInfo.curve(source: plan.source))
                }
                // What was chosen once also applies to the next episode.
                self.mediaPlayer.fillFrame(self.selection.fillFrame)
                self.techBadgeSet(self.selection.techBadge)
                self.playState.position = spot
                self.tickStart()
            }
        }
    }

    /// **Window closed while a movie plays.**
    ///
    /// GTK used to tear the window down, the app was gone, and the final report never
    /// reached the server; at the next start the movie resumed at the last interim
    /// report, up to half a minute too early. Now the window disappears immediately,
    /// the player closes as via the button, and the app exits only after the final
    /// report (or after five seconds if the server is silent). If the report fails,
    /// it is stored on disk as a deferred report and sent at the next start.
    ///
    /// Downloads need nothing here: an interrupted download resumes at the next start
    /// (``DownloadManager``), continuing from what is on disk.
    func windowCloseRequested() -> Bool {
        guard runningTitle != nil, !closesPostStop else { return false }
        closesPostStop = true
        AppLog.writeOut("[Fenster] zu waehrend der Wiedergabe, erst die Endmeldung")
        gtk_widget_set_visible(window, 0)
        let toward = held(window)
        postStop = {
            AppLog.writeOut("[Fenster] Endmeldung durch, App geht")
            fflush(nil)
            gtk_window_destroy(asWindow(toward.widget))
            letGo(toward)
        }
        playerClose(windowBack: false)
        // Audio must not keep playing from an invisible window.
        mediaPlayer.finish(onlyMedium: true)
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            onMainThread { self.stopDone() }
        }
        return true
    }

    /// Run once, whichever comes first: the final report or the deadline.
    func stopDone() {
        guard let afterThat = postStop else { return }
        postStop = nil
        supportCheckAfterPlayer()
        afterThat()
    }

    func playerClose(report: Bool = true, windowBack: Bool = true) {
        guard runningTitle != nil else { return }
        // After watching, the next episode may be a different file, so the remembered
        // playback plans no longer apply (``planJob``).
        planJobs = [:]
        planReady = [:]
        // Closing means leaving, without confirmation; the "Wieder beitreten" strip leads back.
        if gemeinsam.an { sharedDetach() }
        // **After the player, the window is as it was before.** Same as on the Mac. If
        // the user went fullscreen in the player (button, F, or window manager), closing
        // restores the previous window state. If the app was already fullscreen, it stays
        // there, since that was a deliberate setting.
        if windowBack, !fullscreenPrePlayer,
           gtk_window_is_fullscreen(asWindow(window)) != 0 {
            gtk_window_unfullscreen(asWindow(window))
        }
        // **Report the position before `stop()`**: afterwards VLC's time is zero and the
        // server would record the start instead of the position.
        // **A stop without a start is not a session.** Closing the player before the first
        // picture never opened one; the Mac reports nothing then either
        // (`PlayerScreen.swift:547`).
        //
        // **Across an episode change:** a running one aborts and applies nothing more;
        // if the start of the new episode is in flight, the stop follows it.
        // **Refresh the pages only after the final report** (as on Apple): otherwise the
        // home page would fetch its rows before the server knew the position.
        let hasPlayed = runningTitle!
        supportWatchStop()
        handoffPlayerDistance(hasPlayed.id)
        preparation.forget()
        readyCount(hasPlayed, position: playState.position, duration: playState.duration)
        if report, playState.startReported,
           let client, let plan = runningPlan, let title = runningTitle {
            let ticks = Int64(playState.position * 10_000_000)
            let account = userIdentifier
            episodesSwitch.close { [self] in
                await self.reportStop(client, title: title, plan: plan, ticks: ticks, account: account)
                onMainThread {
                    self.postPlayerRefresh(title)
                    self.stopDone()
                }
            }
        } else {
            // **From a file there was no session**, but the position is still kept: the
            // download item records it, and the queue reports it once the server is reachable.
            // The newer state wins there (`JellyfinClient.reportLater`).
            if report, playState.startReported, runningPlan == nil,
               downloads.entries(for: hasPlayed.id) != nil {
                let ticks = Int64(playState.position * 10_000_000)
                downloads.playbackRemember(hasPlayed.id, ticks: ticks)
                let account = userIdentifier
                PostReportSlip.record(hasPlayed.id, ticks: ticks, account: account)
                AppLog.writeOut("[Melden] Datei \(ticks / 10_000_000) s \(hasPlayed.id) → Nachmeldung")
            }
            episodesSwitch.close {}
            onMainThread {
                self.postPlayerRefresh(hasPlayed)
                self.stopDone()
            }
        }
        tickEnd()
        layerClose()
        techBadgeSet(false)
        GuardHolder.setDown(false, window: window)
        // **Clear the title first, then clean up.** Everything that hides the pointer
        // depends on it; while it is set, a late event could undo the cleanup.
        runningTitle = nil
        DiscordState.tidyAway()
        // Never with the player open (`Community.kickoff`), hence only now.
        discordHintCheck()
        playerControls = nil
        controlsOpen = false
        playerCenter = nil
        playerIconRail = nil
        playerVolume = nil
        volumePulls = false
        playerLayersButtons = [:]
        playerTitleSpace = nil
        playerNext = nil
        playerOffering = nil
        playerCard = nil
        playerCardsScrim = nil
        playerTitleState = nil
        playerTrickplay = nil
        offeringLayer.newEpisode()
        showPointer(true)
        sections = []
        playerChapter = []
        // **A stale timer would otherwise stop a later playback.**
        sleepTick += 1
        sleepMinutes = nil
        runningPlan = nil
        mediaStateReport()
        // Fade out on the same schedule as the open.
        gtk_stack_set_transition_type(OpaquePointer(pages),
                                      GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_set_transition_duration(OpaquePointer(pages), 300)
        PushLock.of(0.3)
        gtk_stack_set_visible_child_name(OpaquePointer(pages), "start")
        // **The picture stays until the slide-down is done.**
        //
        // `finish` used to stop the media immediately, so a black surface slid down
        // instead of the page that was just visible. Now it stops when the slide ends.
        // The pointer crosses a thread boundary, hence the box: same guarantee as everywhere here.
        let then = held(playerFrame)
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            onMainThread {
                defer { letGo(then) }
                // **Stop the media only if no new movie is running meanwhile.** The timer
                // belongs to *this* page; if the next title starts within the 380 ms, it would
                // otherwise stop that title's media. **The old page is removed in every case**:
                // an early `return` here left it on the stack when the new plan arrived faster
                // than the slide. The display is then already attached to the new page.
                if self.runningTitle == nil {
                    self.mediaPlayer.finish(onlyMedium: true)
                }
                if gtk_widget_get_parent(then.widget) != nil {
                    gtk_stack_remove(OpaquePointer(self.pages), then.widget)
                }
                if self.playerFrame == then.widget {
                    self.playerFrame = nil
                    self.playerControls = nil
                }
            }
        }
    }

    /// **Show the new state after the final report.**
    ///
    /// The home page refetches its rows; an episode watched to the end would otherwise
    /// stay in "Weiterschauen" with a progress bar. If the title page or its series
    /// page lies under the player, it is rebuilt: it fetched its state only once on
    /// open and would show the episode as unwatched. If a player runs again meanwhile,
    /// the trigger no longer applies.
    func postPlayerRefresh(_ hasPlayed: Item) {
        guard runningTitle == nil else { return }
        homeLoad()
        watchStateForget(hasPlayed)
        guard openSubpage == nil, let top = pagesStack[section]?.last,
              top.id == hasPlayed.id || top.id == hasPlayed.seriesId else { return }
        // **Do not rebuild, only update the watched state.** Rebuilding via
        // `detailShow(top)` recreated the page at the top, with season 1 and no focus.
        // Now the main button and episode rows query by themselves and redraw in place.
        let before = scrollState()
        AppLog.writeOut("[Spieler] Sehstand nach dem Player \(top.id), Scroll \(Int(before))")
        fflush(nil)
        headerRefresh?.perform()
        guard let client, let series = hasPlayed.seriesId else { return }
        // The season of the played episode and the one currently shown; after moving on
        // these can differ.
        var seasons: [String] = []
        for s in [openSeason?.id, hasPlayed.seasonId] { if let s, !seasons.contains(s) { seasons.append(s) } }
        for season in seasons {
            Task.detached { [self] in
                guard let episodes = try? await client.episodes(seriesID: series, seasonID: season)
                else { return }
                onMainThread {
                    self.episodeStore[season] = episodes
                    if self.openSeason?.id == season { self.seasonEpisodes = episodes }
                    var drawn = 0
                    for episode in episodes {
                        guard let row = self.watchStateRows[episode.id] else { continue }
                        row.refresh(episode)
                        drawn += 1
                    }
                    AppLog.writeOut("[Spieler] Sehstand aufgefrischt: \(drawn) Zeilen, Staffel \(season)")
                    fflush(nil)
                }
                // Check after redraw and layout, not in the same pass.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                onMainThread {
                    AppLog.writeOut("[Spieler] Scroll nach dem Auffrischen \(Int(before)) → \(Int(self.scrollState()))")
                    fflush(nil)
                }
            }
        }
    }

    /// How far the open detail page is scrolled, in points.
    func scrollState() -> Double {
        guard let detailScroller,
              let verticalRight = gtk_scrolled_window_get_vadjustment(OpaquePointer(detailScroller))
        else { return -1 }
        return gtk_adjustment_get_value(verticalRight)
    }

    // MARK: Layout

    /// **Layout follows the Mac** (`Sources/macOS/PlayerScreen.swift`, `body`), bottom
    /// to top: picture, loading screen, skip markers, controls (flat dimming, header,
    /// center, bar), preview, skip pill, tech badge, layer, standing title.
    ///
    /// **The center is its own layer inside the controls**, centered in the whole
    /// picture, not between header and footer, which differ in height and would push it off-center.
    private func playerPageBuild(_ item: Item) -> Widget! {
        let over: Widget! = gtk_overlay_new()
        // **The old page must release its child, not just hand it over.**
        //
        // `gtk_widget_unparent(mediaPlayer.display)` alone detaches the picture from the
        // window tree, but the old `GtkOverlay` keeps its own pointer to it. When the
        // stack removes the old page 380 ms later (see the timer in ``playerClose``),
        // the overlay calls `unparent` a second time, by which point the picture hangs
        // in the new page and is torn away from it.
        //
        // Symptom: `mapped=0 clock=0 parent=0` on the second title. Without a window there
        // is no frame clock, so nobody fetches frames from the bridge. VLC's clock keeps
        // running and `has_vout` reports 1, but the screen shows a still image. From the
        // outside this looks like "starts black, pause brings it back".
        //
        // `playerFrame` still points to the **old** page at this point and is overwritten
        // afterwards, which keeps the call type-safe without bypassing GTK's type check.
        if let oldPage = playerFrame,
           gtk_widget_get_parent(mediaPlayer.display) == oldPage {
            gtk_overlay_set_child(OpaquePointer(oldPage), nil)
        } else if gtk_widget_get_parent(mediaPlayer.display) != nil {
            gtk_widget_unparent(mediaPlayer.display)
        }
        playerFrame = over
        gtk_widget_add_css_class(over, "swiftly-spieler")
        gtk_overlay_set_child(OpaquePointer(over), mediaPlayer.display)

        let scrim = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(scrim, "swiftly-spieler")
        playerLoadingScreen = scrim
        // **While VLC is still loading, say so.** Otherwise a viewer sees a black surface
        // on the very first title after a fresh install and cannot tell whether something
        // is broken. Only in this one case; if VLC is already running, the veil stays silent.
        if !mediaPlayer.ready {
            gtk_widget_set_valign(scrim, GTK_ALIGN_CENTER)
            let hint = label(translated("VLC lädt noch"), style: "swiftly-zweitzeile")
            append(scrim, hint)
        }
        gtk_overlay_add_overlay(OpaquePointer(over), scrim)

        // The skip markers are independent of the controls: with arrow-key seeking the
        // controls are usually not open.
        let left = JumpMark(back: true)
        let right = JumpMark(back: false)
        playerJumpLeft = left
        playerJumpRight = right
        for (mark, page) in [(left, GTK_ALIGN_START), (right, GTK_ALIGN_END)] {
            gtk_widget_set_halign(mark.display, page)
            gtk_widget_set_valign(mark.display, GTK_ALIGN_CENTER)
            gtk_widget_set_margin_start(mark.display, 44)
            gtk_widget_set_margin_end(mark.display, 44)
            gtk_overlay_add_overlay(OpaquePointer(over), mark.display)
        }

        // **Under the controls: the veil of the card** (iOS `dimmed`). While the
        // next-episode card is up, it dims the picture like the open controls, plus a
        // gradient at the bottom right so the text is readable on any credits.
        let cardScrim = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(cardScrim, "swiftly-kartenschleier")
        gtk_widget_set_can_target(cardScrim, 0)
        gtk_widget_set_opacity(cardScrim, 0)
        let history = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_add_css_class(history, "swiftly-kartenverlauf")
        gtk_widget_set_hexpand(history, 1)
        gtk_widget_set_vexpand(history, 1)
        gtk_widget_set_can_target(history, 0)
        append(cardScrim, history)
        gtk_overlay_add_overlay(OpaquePointer(over), cardScrim)
        playerCardsScrim = cardScrim

        let controls: Widget! = gtk_overlay_new()
        gtk_widget_add_css_class(controls, "swiftly-steuerung")
        gtk_widget_set_opacity(controls, 0)
        gtk_widget_set_can_target(controls, 0)
        playerControls = controls
        controlsOpen = false
        let pillar = stack(GTK_ORIENTATION_VERTICAL, spacing: 0)
        append(pillar, playerHeader(item))
        append(pillar, padding())
        append(pillar, playerFoot(item))
        gtk_overlay_set_child(OpaquePointer(controls), pillar)
        let center = playerMiddle()
        playerCenter = center
        gtk_overlay_add_overlay(OpaquePointer(controls), center)
        gtk_overlay_add_overlay(OpaquePointer(over), controls)

        gtk_overlay_add_overlay(OpaquePointer(over), playerPreviewBuild())
        offeringLayerBuild(in: over)
        // What happens in the group, briefly at the top, so nobody wonders why the movie stands still.
        gtk_overlay_add_overlay(OpaquePointer(over), sharedEventBuild())
        gtk_overlay_add_overlay(OpaquePointer(over), playerTitleStateBuild(item))

        onPointer(over, inward: { [weak self] in self?.controlsShow(through: .beside) },
                         out: { [weak self] in self?.controlsHide() })
        onMotion(over) { [weak self] in self?.controlsShow(through: .beside) }
        // **A click in the picture deliberately brings up the controls.** With a layer
        // open, a click on its backdrop does nothing (Mac: `Ebenengrund`,
        // `.onTapGesture {}`); it closes via X or Escape.
        onClick(over) { [weak self] in
            guard let self, self.openLayerArt == nil else { return }
            self.controlsShow()
        }
        controlsShow()
        return over
    }

    /// **Title and meta line at top left, only icons at top right** (Mac: `header`).
    /// The title here is only a placeholder; it is shown by the standing title, which
    /// stays visible while the episode layer is open.
    private func playerHeader(_ item: Item) -> Widget! {
        let header = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_widget_set_margin_top(header, PlayerMetric.top)
        gtk_widget_set_margin_start(header, PlayerMetric.page)
        gtk_widget_set_margin_end(header, PlayerMetric.page)

        let left = stack(GTK_ORIENTATION_VERTICAL, spacing: 3)
        gtk_widget_set_hexpand(left, 1)
        let slot = label(runningTitleRow, style: "swiftly-spielertitel")
        gtk_label_set_ellipsize(OpaquePointer(slot), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(slot), 0)
        gtk_widget_set_opacity(slot, 0)
        playerTitleSpace = slot
        append(left, slot)
        let meta = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        metaRowFill(meta, item)
        playerMetaRow = meta
        append(left, meta)
        append(header, left)

        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: PlayerMetric.railsSpacing)
        gtk_widget_set_valign(rail, GTK_ALIGN_START)
        playerIconRail = rail
        playerLayersButtons = [:]

        // Volume is the first button in the row (Mac: `VolumeSlider`).
        append(rail, volumeBuild())

        let (tracks, _) = iconButton("subtitles", label: translated("Audio & Untertitel")) {
            [weak self] in self?.unfoldLayer(.tracks)
        }
        playerLayersButtons[.tracks] = tracks
        append(rail, tracks)

        if hasEpisodesLayer {
            let (episodes, _) = iconButton("episodes", label: translated("Folgen")) {
                [weak self] in self?.unfoldLayer(.episodes)
            }
            playerLayersButtons[.episodes] = episodes
            append(rail, episodes)
        }

        let (settings, _) = iconButton("settings", label: translated("Einstellungen")) {
            [weak self] in self?.unfoldLayer(.settings)
        }
        playerLayersButtons[.settings] = settings
        append(rail, settings)

        let fullActive = gtk_window_is_fullscreen(asWindow(window)) != 0
        let (fullscreen, fullscreenGlyph) = iconButton(
            fullActive ? "fullscreen-exit" : "fullscreen",
            label: fullActive ? translated("Vollbild verlassen") : translated("Vollbild")) {
            [weak self] in self?.fullscreenToggle()
        }
        playerFullButton = fullscreen
        playerFullscreenImage = fullscreenGlyph
        append(rail, fullscreen)

        let (close, _) = iconButton("close", label: translated("Player schließen")) {
            [weak self] in self?.playerClose()
        }
        append(rail, close)
        append(header, rail)
        return header
    }

    /// **The title at top left, one layer above everything** (Mac: `stateTitle`).
    /// One line, bold, truncated with an ellipsis; on the right it leaves room for the
    /// icon row. Takes no clicks, since it lies over the buttons of the controls and layers.
    private func playerTitleStateBuild(_ item: Item) -> Widget! {
        let state = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_widget_set_valign(state, GTK_ALIGN_START)
        gtk_widget_set_margin_top(state, PlayerMetric.top)
        gtk_widget_set_margin_start(state, PlayerMetric.page)
        gtk_widget_set_margin_end(state, PlayerMetric.page)
        gtk_widget_set_can_target(state, 0)
        gtk_widget_set_opacity(state, 0)

        let title = label(runningTitleRow, style: "swiftly-spielertitel")
        gtk_label_set_ellipsize(OpaquePointer(title), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(title), 0)
        gtk_widget_set_hexpand(title, 1)
        playerTitleRow = title
        append(state, title)

        let slot = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_size_request(slot, iconRailsWidth(), 1)
        append(state, slot)

        playerTitleState = state
        return state
    }

    private func metaRowFill(_ row: Widget!, _ item: Item) {
        var text: String?
        // **In a group, the group is shown here** (instead of season and episode).
        if sharedGroupsRow(row) {
            text = nil
        } else if item.type == "Episode", let season = item.parentIndexNumber, let episode = item.indexNumber {
            text = String(format: translated("Staffel %lld · Folge %lld"), season, episode)
        } else if let t = item.contextLine ?? (item.secondaryLine.isEmpty ? nil : item.secondaryLine) {
            text = t
        }
        if let text {
            let l = label(text, style: "swiftly-spielerzeile")
            gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
            gtk_label_set_xalign(OpaquePointer(l), 0)
            append(row, l)
        }
        // Not lossless: warning icon and method, in the warning color
        // (Mac: `exclamationmark.triangle.fill`, `Theme.warning`).
        let warning = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 5)
        gtk_widget_set_visible(warning, 0)
        let symbolText = PlayerCharacter("warning", size: 14, color: (0.910, 0.514, 0.227, 1))
        append(warning, symbolText.display)
        playerWarnText = label("", style: "swiftly-spielerzeile")
        append(warning, playerWarnText)
        gtk_widget_add_css_class(warning, "swiftly-warnung")
        playerWarning = warning
        append(row, warning)
    }

    /// Only the meta line is refreshed when the group joins, leaves or changes.
    func metaRowRefresh() {
        guard let meta = playerMetaRow, let item = runningTitle else { return }
        wipe(meta)
        metaRowFill(meta, item)
        if let plan = runningPlan { warningShow(plan) }
    }

    /// On an episode change: refresh title, placeholder and meta line.
    private func titleStateRefresh(_ item: Item) {
        let text = runningTitleRow
        if let title = playerTitleRow { gtk_label_set_text(OpaquePointer(title), text) }
        if let slot = playerTitleSpace { gtk_label_set_text(OpaquePointer(slot), text) }
        if let meta = playerMetaRow {
            wipe(meta)
            metaRowFill(meta, item)
            if let plan = runningPlan { warningShow(plan) }
        }
    }

    func fullscreenToggle() {
        let now = gtk_window_is_fullscreen(asWindow(window)) != 0
        if now { gtk_window_unfullscreen(asWindow(window)) }
        else { gtk_window_fullscreen(asWindow(window)) }
        fullscreenShow(full: !now)
        controlsShow()
    }

    /// **The icon follows the window, not the button.** It used to be set only here,
    /// so leaving fullscreen via Escape, the window manager's F11 or a double click
    /// left the wrong icon and hint. Now `notify::fullscreened` also calls this.
    func fullscreenShow(full: Bool) {
        playerFullscreenImage?.setName(full ? "fullscreen-exit" : "fullscreen")
        if let button = playerFullButton {
            let text = full ? translated("Vollbild verlassen") : translated("Vollbild")
            gtk_widget_set_tooltip_text(button, text)
            caption(button, text)
        }
    }

    /// Muted or not: **M** in the player. No overlay: the notice strip (``report(_:)``)
    /// belongs to the detail page and would lie under the player; what you hear is the feedback.
    func mutedToggle() {
        if selection.volume > 0 {
            selection.volumePrior = selection.volume
            volumeApply(0)
        } else {
            volumeApply(selection.volumePrior > 0 ? selection.volumePrior : 1)
        }
        selection.secure()
        AppLog.writeOut("[Player] Ton \(selection.volume > 0 ? "an" : "aus")")
    }

    /// Arrow up and down: ±5 %, the slider briefly opens.
    func volumeLevel(_ step: Double) {
        volumeApply(((selection.volume + step) * 100).rounded() / 100)
        selection.secure()
        volumeShortShow()
    }

    /// Sets the value in player, slider and settings (without saving).
    func volumeApply(_ new: Double) {
        let w = min(max(new, 0), 1)
        selection.volume = w
        mediaPlayer.volumeSet(Int((w * 100).rounded()))
        playerVolume?.setDown(w)
    }

    /// Mouse wheel over the slider: continuous, 0 to 1. Saved only when the slider
    /// collapses again, not on every step.
    func volumeWheel(_ step: Double) {
        volumeApply(selection.volume + step)
        volumeWheelOpen = true
        volumeShortShow()
    }

    /// Opens the slider for 1.2 s and keeps the bar there so the value is visible.
    func volumeShortShow() {
        controlsShow()
        playerVolume?.shortShow(true)
        volumeClock += 1
        let my = volumeClock
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            onMainThread {
                guard self.volumeClock == my else { return }
                self.playerVolume?.shortShow(false)
                if self.volumeWheelOpen {
                    self.volumeWheelOpen = false
                    self.selection.secure()
                }
            }
        }
    }

    /// Speaker button with an expandable slider.
    func volumeBuild() -> Widget! {
        let (button, symbolText) = iconButton("speaker-loud", label: translated("Ton aus")) {
            [weak self] in
            self?.mutedToggle()
            self?.controlsShow()
        }
        let slider = VolumeSlider(value: selection.volume, symbolText: symbolText, button: button!)
        slider.changed = { [weak self] w in
            guard let self else { return }
            self.selection.volume = w
            self.mediaPlayer.volumeSet(Int((w * 100).rounded()))
        }
        slider.drag = { [weak self] an in
            guard let self else { return }
            self.volumePulls = an
            if !an {
                self.selection.secure()
                self.controlsShow()
            }
        }
        slider.wheelRotated = { [weak self] share in self?.volumeWheel(share) }
        playerVolume = slider
        signal(slider.display, "destroy") { [weak self] in
            if self?.playerVolume === slider { self?.playerVolume = nil }
        }
        return slider.display
    }

    /// Centered in the picture: back, play, forward. Spacing 80, icons 30 and 40 in
    /// boxes of 54 and 72 (Mac: `centerControls`, `JumpButton`).
    private func playerMiddle() -> Widget! {
        let rail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 80)
        gtk_widget_set_halign(rail, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(rail, GTK_ALIGN_CENTER)

        let back = PlayerCharacter("back", size: 36, figure: selection.backSeconds)
        playerBackCharacter = back
        append(rail, playKey(back.display, container: 54,
                                    name: String(format: translated("%lld Sekunden zurück"), selection.backSeconds)) {
            [weak self] in
            guard let self else { return }
            self.vault(um: -Double(self.selection.backSeconds))
            self.playerBackCharacter?.nudge()
            self.controlsShow()
        })

        let center = PlayerCharacter("pause", size: 46)
        playerPlayMarker = center
        append(rail, playKey(center.display, container: 72,
                                    name: translated("Anhalten")) {
            [weak self] in self?.playToggle()
        })

        let forward = PlayerCharacter("forward", size: 36, figure: selection.forwardSeconds)
        playerPreCharacter = forward
        append(rail, playKey(forward.display, container: 54,
                                    name: String(format: translated("%lld Sekunden vor"), selection.forwardSeconds)) {
            [weak self] in
            guard let self else { return }
            self.vault(um: Double(self.selection.forwardSeconds))
            self.playerPreCharacter?.nudge()
            self.controlsShow()
        })
        return rail
    }

    private func playKey(_ symbolText: Widget!, container: Int32, name: String,
                            pick: @escaping () -> Void) -> Widget! {
        let button: Widget! = gtk_button_new()
        gtk_widget_add_css_class(button, "swiftly-spieltaste")
        gtk_widget_set_size_request(button, container, container)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        caption(button, name)
        gtk_button_set_child(asButton(button), symbolText)
        signal(button, "clicked", pick)
        return button
    }

    /// Bar only, full width: elapsed time on the left, remaining time on the right
    /// (Mac: `footer`, `TimeRow`). Above it, an invisible pill reserves the space for
    /// the skip pill: right side, 20 above the bar.
    private func playerFoot(_ item: Item) -> Widget! {
        let bottom = stack(GTK_ORIENTATION_VERTICAL, spacing: PlayerMetric.overBar)
        gtk_widget_set_margin_start(bottom, PlayerMetric.page)
        gtk_widget_set_margin_end(bottom, PlayerMetric.page)
        gtk_widget_set_margin_bottom(bottom, PlayerMetric.bottom)

        let spaceRail = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        append(spaceRail, paddingLandscape())
        let proceed = OfferingButton { [weak self] in self?.offeringRun() }
        gtk_widget_set_halign(proceed.button, GTK_ALIGN_END)
        playerNext = proceed
        append(spaceRail, proceed.button)
        append(bottom, spaceRail)

        let bar = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        playerTime = label("0:00", style: "swiftly-spielerzeit")
        gtk_widget_set_size_request(playerTime, 52, -1)
        gtk_label_set_xalign(OpaquePointer(playerTime), 0)
        append(bar, playerTime)
        playerSlider = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.001)
        gtk_scale_set_draw_value(asScale(playerSlider), 0)
        gtk_widget_add_css_class(playerSlider, "swiftly-regler")
        gtk_widget_set_hexpand(playerSlider, 1)
        gtk_widget_set_size_request(playerSlider, -1, PlayerMetric.bar)
        caption(playerSlider, translated("Abspielstelle"))
        g_signal_connect_data(UnsafeMutableRawPointer(playerSlider), "change-value",
                              unsafeBitCast(sliderDragged, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(),
                              nil, GConnectFlags(rawValue: 0))
        // `atSlider` as on the Mac: while dragging, the controls do not fade out, the
        // server's position does not overwrite the dragged one, and the center and icon
        // row make way for the preview.
        onGrip(playerSlider) { [weak self] pressed in
            guard let self else { return }
            self.atSlider = pressed
            // In a group the request is sent only on release: one, not one per mouse move
            // (iOS: `onEditingChanged`).
            if !pressed, let target = self.gemeinsam.sliderTarget {
                self.gemeinsam.sliderTarget = nil
                self.vault(on: target)
            }
            for w in [self.playerCenter, self.playerIconRail] {
                guard let w else { continue }
                gtk_widget_set_opacity(w, pressed ? 0 : 1)
                gtk_widget_set_can_target(w, pressed ? 0 : 1)
            }
            // While dragging, the track is 6 thick, and the notches with it.
            if let k = self.playerNotches { gtk_widget_queue_draw(k) }
            if pressed {
                gtk_widget_add_css_class(self.playerSlider, "swiftly-regler-ziehen")
                self.controlsShow()
            } else {
                gtk_widget_remove_css_class(self.playerSlider, "swiftly-regler-ziehen")
                self.previewHide()
                self.controlsShow()
            }
        }
        // The preview appears on hover, not only on drag (Mac: `onContinuousHover`).
        onMousePosition(playerSlider, moved: { [weak self] x, _ in
            guard let self, !self.atSlider else { return }
            let width = Double(gtk_widget_get_width(self.playerSlider))
            guard width > 0 else { return }
            self.previewShow(share: min(max(x / width, 0), 1))
        }, leave: { [weak self] in
            guard let self, !self.atSlider else { return }
            self.previewHide()
        })
        // **Notches at section boundaries**, two points wide in `reason`, visible on track
        // and bar as on the Mac. Drawn over the slider without hit testing, so the pointer
        // passes through to the slider.
        let sliderWrapper: Widget! = gtk_overlay_new()
        gtk_widget_set_hexpand(sliderWrapper, 1)
        gtk_overlay_set_child(OpaquePointer(sliderWrapper), playerSlider)
        let notches: Widget! = gtk_drawing_area_new()
        gtk_widget_set_can_target(notches, 0)
        gtk_widget_set_can_focus(notches, 0)
        gtk_drawing_area_set_draw_func(asCharacter(notches), notchesDraw,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        gtk_overlay_add_overlay(OpaquePointer(sliderWrapper), notches)
        playerNotches = notches
        notchesDuration = 0
        signal(notches, "destroy") { [weak self] in
            if self?.playerNotches == notches { self?.playerNotches = nil }
        }
        // With chapters the overlay also draws the bar: redraw on every new value.
        signal(playerSlider, "value-changed") { [weak self] in
            if let k = self?.playerNotches, self?.playerChapter.isEmpty == false {
                gtk_widget_queue_draw(k)
            }
        }
        append(bar, sliderWrapper)
        playerRemaining = label("−0:00", style: "swiftly-spielerzeit")
        gtk_widget_set_size_request(playerRemaining, 58, -1)
        gtk_label_set_xalign(OpaquePointer(playerRemaining), 1)
        // **Remaining time or end time: one click toggles** ("−12:34" or "Endet um 22:41"),
        // and the choice persists. No extra button or second line: same spot, same font.
        // Keyboard-accessible like a button.
        onClick(playerRemaining, keyboard: true) { [weak self] in
            guard let self else { return }
            self.selection.remainingTimeAsEnd.toggle()
            self.selection.secure()
            self.timesShow()
            self.controlsShow()
        }
        gtk_widget_set_cursor_from_name(playerRemaining, "pointer")
        gtk_widget_set_tooltip_text(playerRemaining, translated("Wechselt zwischen Restzeit und Ende"))
        append(bar, playerRemaining)
        append(bottom, bar)
        return bottom
    }

    /// Trickplay preview above the handle: 170-wide image at 16:9, time in bold below
    /// (Mac: `vorschauKasten`). Without trickplay, only the time.
    private func playerPreviewBuild() -> Widget! {
        let wrapper = stack(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_set_halign(wrapper, GTK_ALIGN_START)
        gtk_widget_set_valign(wrapper, GTK_ALIGN_END)
        gtk_widget_set_can_target(wrapper, 0)
        gtk_widget_set_opacity(wrapper, 0)

        let (frameRect, image) = framedImage(width: 170, height: 96, style: "swiftly-vorschaubild")
        playerPreviewImage = image
        playerPreviewWrapper = frameRect
        append(wrapper, frameRect)

        // **With chapters the name comes before the time**, on one line; if too long, the
        // name is truncated, never the time (Mac `vorschauKasten`).
        let row = stack(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_halign(row, GTK_ALIGN_CENTER)
        let name = label("", style: "swiftly-vorschauname")
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(name), 18)
        gtk_widget_set_visible(name, 0)
        playerPreviewName = name
        append(row, name)
        let time = label("0:00", style: "swiftly-vorschauzeit")
        playerPreviewTime = time
        append(row, time)
        append(wrapper, row)

        playerPreview = wrapper
        return wrapper
    }

    func previewShow(share: Double) {
        guard openLayerArt == nil, playState.duration > 0, let slider = playerSlider,
              let wrapper = playerPreview, let frameRect = playerFrame,
              let image = playerPreviewImage, let timeField = playerPreviewTime else { return }
        let spot = playState.duration * share
        var r = graphene_rect_t()
        guard gtk_widget_compute_bounds(slider, frameRect, &r) != 0, r.size.width > 0 else { return }

        let hasImage = playerTrickplay?.detail != nil
        if let texture = playerTrickplay?.tile(at: spot, client: client) {
            gtk_picture_set_paintable(OpaquePointer(image), texture)
        }
        gtk_widget_set_visible(playerPreviewWrapper, hasImage ? 1 : 0)
        gtk_label_set_text(OpaquePointer(timeField), PlayTime.text(spot))
        let chapterName = ChapterBar.chapter(at: spot, in: playerChapter)?.name ?? ""
        if let namesField = playerPreviewName {
            gtk_label_set_text(OpaquePointer(namesField), chapterName)
            gtk_widget_set_visible(namesField, chapterName.isEmpty ? 0 : 1)
        }

        // Centered over the position, clamped to the edge; 2 above the bar's hit area.
        // Without an image, the width depends on the name.
        var half = hasImage ? 85.0 : 40.0
        if !hasImage, !chapterName.isEmpty {
            gtk_widget_set_size_request(wrapper, -1, -1)
            var small: Int32 = 0, natural: Int32 = 0
            gtk_widget_measure(wrapper, GTK_ORIENTATION_HORIZONTAL, -1, &small, &natural, nil, nil)
            half = max(Double(natural) / 2, 40)
        }
        let frameWidth = Double(gtk_widget_get_width(frameRect))
        let centerX = Double(r.origin.x) + Double(r.size.width) * share
        let target = min(max(centerX, half), max(frameWidth - half, half))
        gtk_widget_set_margin_start(wrapper, Int32((target - half).rounded()))
        if !hasImage { gtk_widget_set_size_request(wrapper, chapterName.isEmpty ? 80 : -1, -1) }
        else { gtk_widget_set_size_request(wrapper, 170, -1) }
        let bottomOff = Double(gtk_widget_get_height(frameRect)) - Double(r.origin.y) + 2
        gtk_widget_set_margin_bottom(wrapper, Int32(bottomOff.rounded()))
        gtk_widget_set_opacity(wrapper, 1)
    }

    func previewHide() {
        guard let wrapper = playerPreview else { return }
        gtk_widget_set_opacity(wrapper, 0)
    }

    private func warningShow(_ plan: PlaybackPlan) {
        guard let inputField = playerWarning else { return }
        gtk_widget_set_visible(inputField, plan.isLossless ? 0 : 1)
        if !plan.isLossless, let text = playerWarnText {
            gtk_label_set_text(OpaquePointer(text), plan.method.rawValue)
        }
    }

    private func playerMessage(_ text: String) {
        guard let inputField = playerTime else { return }
        gtk_label_set_text(OpaquePointer(inputField), text)
    }

    // MARK: The tick

    private func tickStart() {
        tickEnd()
        // **The number comes from the package**, not this file. There used to be a 500
        // here, while the Mac reads the same size from `PlaybackTick.tickLength`: two
        // places for a value that is meant to be shared.
        // It runs at the display tick (250 ms); every second call is the full tick, in
        // between only the time is updated.
        let ms = UInt32(PlaybackTick.displayTick.components.seconds * 1000
                        + PlaybackTick.displayTick.components.attoseconds / 1_000_000_000_000_000)
        // **Priority 0, not 200.** Same reason as ``onMainThread``: with
        // `G_PRIORITY_DEFAULT_IDLE` this tick starves behind GTK's redraw (120) once the
        // player sets a new paintable for every frame. That is exactly when it is needed,
        // since it removes the loading veil and updates the time.
        playerTick = g_timeout_add_full(0, ms, playerTickCall,
                                         Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// **Evidence for "the picture stays black".**
    ///
    /// Three numbers separate cases that look identical from outside: `vout` says
    /// whether VLC has a video output at all, `images` whether any frames arrive at
    /// the bridge, and `bildDa` whether the app believes it has one. `vout` 1 with
    /// `images` at zero points to the bridge; `images` high with `bildDa` false points
    /// to the assumption logic.
    /// Debug builds only, and only with `SWIFTLY_BILDMESSUNG=1`.
    private func imageMeasurementWrite(_ measurement: PlaybackTick.Reading) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SWIFTLY_BILDMESSUNG"] == "1" else { return }
        print(String(format: "[Bild] %5.2f s  vout=%d  zeit=%.2f  takte=%d  bilder=%d  bildDa=%d  einst=%d  laeuft=%d",
                     Date().timeIntervalSince(sinceOpen), measurement.showsImage ? 1 : 0,
                     measurement.position, mediaPlayer.beats, mediaPlayer.fetchedImages,
                     playState.firstImagePresent ? 1 : 0, measurement.seeksToStart ? 1 : 0,
                     measurement.running ? 1 : 0) + "  " + mediaPlayer.tickStatus)
        fflush(nil)
        #endif
    }

    /// **The path to the first picture, in the log of every build.**
    ///
    /// Unlike ``imageMeasurementWrite(_:)`` this also runs in release builds, because
    /// without it a log contained no line from the player and a "starts black" report
    /// could not be traced.
    ///
    /// It stays short: one line per second until the first picture, then a single line
    /// giving how long it took. A two-hour movie costs two lines; a hanging start
    /// as many as needed.
    /// **If the tick stops, the main thread was blocked.**
    ///
    /// ``Protokoll/withClock(_:_:)`` times individual calls, but the most expensive work
    /// may not be in one of our calls at all but in GTK's drawing. With `GskCairoRenderer`
    /// every frame is rendered in software at window size, and a cross-faded fullscreen
    /// page costs many times more. That escapes any measurement that only wraps our own code.
    ///
    /// This watchdog does not: the tick arrives every 250 ms, and if it is missing for
    /// a second, something held the thread. It does not say what, only that it happened and when.
    private func tickGap() {
        let now = ContinuousClock.now
        defer { lastTick = now }
        guard let before = lastTick else { return }
        let d = now - before
        let ms = Double(d.components.seconds) * 1000
               + Double(d.components.attoseconds) / 1e15
        if ms >= 1000 {
            AppLog.writeOut(String(format: "[Hauptfaden] Takt %.1f s ausgeblieben", ms / 1000))
        }
    }

    private func startHistoryWrite(_ measurement: PlaybackTick.Reading,
                                       job: PlaybackTick.WorkItem) {
        // What a seek achieved: once, at the next full tick.
        if let toIt = mediaPlayer.jumpBalance() {
            AppLog.writeOut(String(format:
                "[Player] nach dem Sprung: Zeit %.0f s, %d Bilder dazu, vout %d",
                measurement.position, toIt, measurement.showsImage ? 1 : 0))
        }
        if job.loadingScreenGone {
            startWait = 0
            AppLog.writeOut(String(format:
                "[Player] erstes Bild nach %.1f s (vout %d, Bilder %d, Takte %d)",
                Date().timeIntervalSince(sinceOpen), measurement.showsImage ? 1 : 0,
                mediaPlayer.fetchedImages, mediaPlayer.beats))
            return
        }
        guard !playState.firstImagePresent else { return }
        // The full tick comes every 500 ms; every second round is one second.
        startWait += 1
        guard startWait % 2 == 0 else { return }
        AppLog.writeOut(String(format:
            "[Player] warte auf das erste Bild, %.0f s (vout %d, puffert %d, laeuft %d, Zeit %.1f, Bilder %d, Takte %d)",
            Date().timeIntervalSince(sinceOpen), measurement.showsImage ? 1 : 0,
            measurement.seeksToStart ? 1 : 0, measurement.running ? 1 : 0, measurement.position,
            mediaPlayer.fetchedImages, mediaPlayer.beats))
    }

    func tickEnd() {
        if playerTick != 0 { g_source_remove(playerTick); playerTick = 0 }
    }

    /// One tick. The calculation itself lives in the package; here things are only
    /// measured, queried and executed.
    func clockOut() {
        guard runningTitle != nil else { return }
        tickGap()
        // The group reads the state via ``Gemeinsamspieler`` itself; here it only gets the
        // tick (iOS `bridgeCatchUp`).
        if gemeinsam.an { sharedTick() }
        // **In between only the time**, as on iOS: at the half-second tick it started late
        // after playing and counted unevenly.
        onlyTimeTick.toggle()
        if onlyTimeTick {
            if !episodesSwitch.running {
                PlaybackTick.timeAdopt(&playState, reported: mediaPlayer.position,
                                               atPush: atSlider, sinceStart: sinceOpen)
                timesShow()
            }
            return
        }
        // Once per second: libVLC forgets the delay with every media.
        mediaPlayer.delayCatchUp()
        // The badge runs on the same tick as everything else: 500 ms. Faster shows only
        // flicker, slower misses the stutter.
        MainActor.assumeIsolated { techBadgeUpdate() }
        let measurement = PlaybackTick.Reading(
            duration: mediaPlayer.duration,
            position: mediaPlayer.position,
            goodPoint: playState.position,
            showsImage: mediaPlayer.showsImage,
            seeksToStart: mediaPlayer.seeksToStart,
            running: mediaPlayer.running,
            // **Read the track list only while it is needed.** `hasAudioTracks` rebuilds and
            // walks the whole VLC list on every call, twice per second for the whole movie.
            // Once the track is set, the `||` short-circuits it. Identical on iOS and macOS.
            hasAudioTracks: playState.tracksSet || mediaPlayer.hasAudioTracks)

        // **`PlaybackTick` is `@MainActor`, this callback is not.** GTK's timer runs on
        // the process's main thread, which is what Swift calls `MainActor`.
        // `assumeIsolated` states exactly that and checks it at runtime instead of just asserting it.
        let job = MainActor.assumeIsolated {
            // **After a seek the state holds the target position until VLC is there**
            // (`playState.sprung`); while dragging, VLC's time is not taken over at all.
            PlaybackTick.compute(&playState, measurement: measurement,
                                   restoring: false,
                                   atPush: atSlider,
                                   sinceStart: sinceOpen)
        }

        timesShow()
        supportWatchTick(isPlaying: playState.running)
        MainActor.assumeIsolated { streamCheck() }
        MainActor.assumeIsolated { audioCheck() }
        imageMeasurementWrite(measurement)
        startHistoryWrite(measurement, job: job)

        // **Until the first picture is up, a veil covers it.** Without it you see the
        // stream setup: blocks, a jerk, sometimes a green frame. When it lifts is decided
        // by ``TimeAssumption`` in the package, not this file.
        // The handover card zooms as soon as the first picture is up.
        if job.loadingScreenGone, let id = runningTitle?.id { handoffImagePresent(id) }
        if job.loadingScreenGone, let scrim = playerLoadingScreen {
            // Mac: `withAnimation(.easeOut(duration: 0.3)) { screenDistance = true }`.
            gtk_widget_set_can_target(scrim, 0)
            crossfade(scrim, on: 0, duration: 0.3, curve: .easeOut)
            playerLoadingScreen = nil
        }
        if job.tracksApply { tracksPreSelect() } else { trackFilesUpdate() }
        if job.startReport { report(.start); mediaStateReport() }
        if job.progressReport { report(.progress) }

        // **The same tick also drives the Discord presence.**
        //
        // On the Apple builds it hangs off the playback hub, where fresh values are present
        // on every state change. There is no such hub here, so this tick does it, and it
        // knows the same three numbers. Whether anything is sent at all is decided by
        // `DiscordState`; the switch is off until someone sets it.
        if let title = runningTitle {
            DiscordState.report(
                title: title.seriesName ?? title.name,
                subline: title.seriesName == nil ? nil
                            : [title.episodeCode, title.name]
                                .compactMap { $0 }.joined(separator: " · "),
                spot: playState.position, duration: playState.duration,
                running: playState.running, allowed: selection.discordShow)
        }

        // The button, and the automatic advance (much more narrowly defined, and earliest
        // `rampUpIdle` seconds after opening).
        //
        // **The button is not always "Next episode".** If the position is in a skippable
        // section, it reads "Skip intro" and jumps to its end, the same decision as on
        // all other platforms, in `SectionLogic`.
        // **While a switch runs, there is nothing to offer.** Otherwise the "Next episode"
        // button stays tappable while the episode is being fetched, and a press would
        // trigger the same switch a second time.
        // **"Next episode" only if there is one**: the prefetched one, not merely "is an
        // episode". Otherwise the button also appeared in the finale's credits and the
        // advance failed on every tick. (Computed in `offeringTick`.)
        // **The overlay** (the card's countdown) is computed in `OfferingLayer`. No clock
        // runs while paused, during dragging, or under the veil.
        if offeringTick(elapsed: Self.tickSeconds), prefetchedEpisode != nil {
            AppLog.writeOut("[Angebot] Countdown abgelaufen bei \(Int(playState.position)) s")
            fflush(nil)
            nextEpisode()
        }
        offeringUpdate()
        // **Prepare the next episode** while this one still plays (iOS `tick`). Not in a
        // group (it advances by itself) and not from a file. Once per episode; when and
        // over which network is decided by `Prebuffer`.
        if let episode = prefetchedEpisode, let client, runningPlan != nil, !inGroup,
           !episodesSwitch.running,
           Prebuffer.now(position: playState.position, duration: playState.duration,
                           creditsFrom: sections.first { $0.art == .credits }?.from,
                           networkFavorable: preparation.networkFavorable) {
            let limit = selection.profileBitrate
            preparation.prepare(episode) {
                try? await client.playbackPlan(for: episode.id, profile: .vlc(maxBitrate: limit))
            }
        }
        // Advance automatically at the end, only with a card (credits section from the
        // server), and not if it was dismissed.
        if offeringLayer.nextAtEnd,
           prefetchedEpisode != nil, !episodesSwitch.running,
           EpisodeEnd.advance(position: playState.position,
                                     duration: playState.duration,
                                     sinceOpen: Date().timeIntervalSince(sinceOpen),
                                     cardCounts: offeringLayer.cardCounts) {
            // **If the card counts down, it owns the advance** (iOS: seeking to the end, with
            // `position >= dauer - 1`, switched immediately).
            AppLog.writeOut("[Wechsel] Dateiende ohne Karte")
            fflush(nil)
            nextEpisode()
        }
    }

    private enum Message { case start, progress }

    private func report(_ was: Message) {
        // **The tick stays silent during a switch**: from the old episode's stop on,
        // progress would still be reported for it and Jellyfin would reopen its session.
        guard episodesSwitch.messagesAllowed,
              let client, let plan = runningPlan, let title = runningTitle else { return }
        let ticks = Int64(playState.position * 10_000_000)
        switch was {
        case .start:
            notifyStart(client, title: title, plan: plan, ticks: ticks)
        case .progress:
            notifyProgress(client, title: title, plan: plan, ticks: ticks,
                             paused: !playState.running)
        }
    }

    // MARK: Reports to the server, the one place

    private func message(_ art: ReportQueue<ReportContent>.Art, _ client: JellyfinClient,
                         title: Item, plan: PlaybackPlan,
                         ticks: Int64) -> ReportQueue<ReportContent>.Message {
        .init(art: art,
              key: StopLock.key(itemID: title.id, playSessionID: plan.playSessionID),
              payload: ReportContent(client: client, title: title, plan: plan, ticks: ticks,
                                    tracks: trackStatus.reported))
    }

    /// Start, progress and stop go out here and only here, into the ``messages`` queue,
    /// **dispatched, not awaited**: the tick never waits for the server. Only the end
    /// waits (``reportStop``).
    func notifyStart(_ client: JellyfinClient, title: Item, plan: PlaybackPlan, ticks: Int64) {
        reportTitle = (client, title, plan)
        reportedPaused = false
        messages.report(message(.start, client, title: title, plan: plan, ticks: ticks))
        traktStart(client, title: title, ticks: ticks)
    }

    func notifyProgress(_ client: JellyfinClient, title: Item, plan: PlaybackPlan,
                          ticks: Int64, paused: Bool) {
        guard messages.report(message(.progress(paused: paused), client,
                                       title: title, plan: plan, ticks: ticks)) else {
            AppLog.writeOut("[Melden] Fortschritt nach Stopp verworfen \(title.id)")
            fflush(nil)
            return
        }
        reportedPaused = paused
    }

    /// **libVLC paused or resumed: report immediately.**
    ///
    /// Hooked to VLC's event (``Abspieler/laufzustand``), not to the press: button,
    /// space bar, media key, remote command and sleep timer all go through here, and
    /// the state VLC actually has is reported, not the one the button expects.
    func runStateReported(running: Bool) {
        guard let reportTitle, reportedPaused == running,
              reportTitle.title.id == runningTitle?.id else { return }
        let spot = playState.leap?.target ?? mediaPlayer.position
        AppLog.writeOut("[Melden] sofort: \(running ? "weiter" : "Pause") bei \(Int(spot)) s")
        fflush(nil)
        traktRunState(running: running, spot: spot)
        notifyProgress(reportTitle.client, title: reportTitle.title, plan: reportTitle.plan,
                         ticks: Int64(spot * 10_000_000), paused: !running)
    }

    /// **Every seek goes through here**: buttons, arrow keys, slider, skip and remote
    /// commands. State and seek latch are set along with it (otherwise "seek to" from
    /// the dashboard set only VLC's time and the tick pulled the display back), and the
    /// target position is reported immediately.
    func vault(on target: Double) {
        // **In a group, a request**; the seek happens when the command arrives. The display
        // already shows the target, as on iOS (`scrub`, `jumped(on:)`).
        if inGroup {
            let target = max(0, target)
            sharedBitJump(on: target)
            PlaybackTick.jumped(&playState, target: target)
            timesShow()
            return
        }
        jumpDirect(on: target)
    }

    /// The seek itself, including the one the group commands.
    func jumpDirect(on target: Double) {
        let target = max(0, target)
        mediaPlayer.setTime(target)
        // Display and offer jump to the target immediately; the tick holds it until VLC arrives.
        PlaybackTick.jumped(&playState, target: target)
        // A seek into the credits or to the end restarts the card's countdown (iOS).
        offeringLayer.jumped()
        if case .card = offeringLayer.display { offeringClock = FillClock() }
        _ = offeringTick(elapsed: 0)
        timesShow()
        offeringUpdate()
        lastJump = Date()
        guard let reportTitle, reportTitle.title.id == runningTitle?.id,
              episodesSwitch.messagesAllowed else { return }
        AppLog.writeOut("[Melden] sofort: Sprung auf \(Int(target)) s")
        fflush(nil)
        traktJump(on: target)
        notifyProgress(reportTitle.client, title: reportTitle.title, plan: reportTitle.plan,
                         ticks: Int64(target * 10_000_000), paused: reportedPaused)
    }

    /// Relative seek. While a seek is in flight, VLC's time is still the old one, so the
    /// position already sought to counts.
    func vault(um seconds: Double) {
        let from = playState.leap?.target ?? mediaPlayer.position
        vault(on: from + seconds)
    }

    /// Adjust offer and overlay to the displayed position, on the tick and with
    /// `elapsed: 0` right after a seek. `true`: countdown expired.
    func offeringTick(elapsed: Double) -> Bool {
        let offering: ButtonOffering = episodesSwitch.running ? .nobody
            : SectionLogic.offering(position: playState.position,
                                      duration: playState.duration,
                                      sections: sections,
                                      hasNextEpisode: prefetchedEpisode != nil)
        currentOffering = offering
        guard !episodesSwitch.running else { return false }
        // **Variant C** (iOS `offeringCatchUp`): without a credits section the card appears
        // in the last ``Folgenkarte/restfenster`` seconds and counts to the end of the file;
        // at the end it keeps counting although nothing plays anymore, except while dragging the slider.
        return offeringLayer.tick(
            offering: offering,
            cardDue: SectionLogic.cardDue(position: playState.position,
                                                       duration: playState.duration,
                                                       sections: sections,
                                                       hasNextEpisode: prefetchedEpisode != nil,
                                                       remainingWindow: EpisodeCard.remainingWindow),
            running: playState.running && playerLoadingScreen == nil && !atSlider,
            elapsed: elapsed,
            countdown: SectionLogic.countdown(position: playState.position,
                                                 duration: playState.duration,
                                                 sections: sections,
                                                 remainingWindow: EpisodeCard.remainingWindow),
            atEnd: EpisodeEnd.atEnd(position: playState.position, duration: playState.duration)
                && !atSlider)
    }

    /// The end, **awaited**, because the pages reload afterwards. The queue sends it
    /// behind a still-running start and never twice. On failure or deadline expiry it goes
    /// to the deferred report.
    func reportStop(_ client: JellyfinClient, title: Item, plan: PlaybackPlan,
                    ticks: Int64, account: String) async {
        let entryRecord = message(.stop, client, title: title, plan: plan, ticks: ticks)
        // Trakt has its own queue and does not wait for Jellyfin.
        traktStop(title: title, ticks: ticks)
        // **With and without network: the download knows its own state**: flag, remembered
        // position, timestamp (as `AppModel.reportStopped`). The list lives on the main thread.
        let moment = Date()
        onMainThread { self.downloads.playbackRemember(title.id, ticks: ticks, moment: moment) }
        // Immediately, not after the response: a pause or seek in the meantime no longer
        // belongs to any title.
        onMainThread {
            if let t = self.reportTitle,
               StopLock.key(itemID: t.title.id, playSessionID: t.plan.playSessionID)
                == entryRecord.key {
                self.reportTitle = nil
            }
        }
        let result = await messages.reportAndWait(entryRecord)
        switch result {
        case .sent:
            AppLog.writeOut("[Melden] Stopped \(ticks / 10_000_000) s \(title.id) session \(plan.playSessionID ?? "nil")")
            // An older position from the offline period must not go out afterwards. `account` is
            // the account from before the wait.
            PostReportSlip.overFetches(title.id, account: account)
        case .discarded:
            AppLog.writeOut("[Melden] Stopped doppelt verworfen \(title.id) session \(plan.playSessionID ?? "nil")")
        case .failed, .timeOverStep:
            // **Second half of the deferred report.** The position is what a download leaves
            // behind and the server does not have.
            PostReportSlip.record(title.id, ticks: ticks, account: account)
            AppLog.writeOut("[Melden] Stopped \(result) → Nachmeldung \(title.id)")
        }
        fflush(nil)
    }

    /// The time of day per the locale ("22:41" or "10:41 PM"), like
    /// `.formatted(date: .omitted, time: .shortened)` on Apple.
    private static let timeOfDay: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private func timesShow() {
        gtk_label_set_text(OpaquePointer(playerTime), PlayTime.text(playState.position))
        if playState.duration > 0 {
            let rest = max(0, playState.duration - playState.position)
            if selection.remainingTimeAsEnd {
                let end = String(format: translated("Endet um %@"),
                                  Self.timeOfDay.string(from: Date().addingTimeInterval(rest)))
                gtk_label_set_text(OpaquePointer(playerRemaining), end)
                caption(playerRemaining, end)
            } else {
                gtk_label_set_text(OpaquePointer(playerRemaining), "−" + PlayTime.text(rest))
                caption(playerRemaining, translated("Restzeit"))
            }
            gtk_range_set_value(asSection(playerSlider),
                                playState.position / playState.duration)
            if playState.duration != notchesDuration, let k = playerNotches {
                notchesDuration = playState.duration
                gtk_widget_queue_draw(k)
            }
        }
        playerPlayMarker?.setDown(playState.running)
    }

    /// **If the stream stalls, rebuild it.** The five thresholds live in the package as
    /// ``StreamWatch``, with tests, and were never called on Linux.
    ///
    /// **Why this is needed although libVLC has `http-reconnect`.** That applies when the
    /// connection *drops*. The case here is the other one: the connection stays up but
    /// nothing arrives anymore, e.g. a server that stops delivering mid-stream. libVLC
    /// then waits indefinitely and the picture freezes.
    ///
    /// **The watchdog is a brake and must not cause a hang itself.** So the package, not
    /// this file, decides: a seek in flight, a growing buffer or a fresh network change
    /// are each a reason to wait. The numbers are explained per constant there.
    private func streamCheck() {
        guard let plan = runningPlan, plan.url.isFileURL == false,
              playState.running, playState.startReported else {
            streamStandsSince = nil
            return
        }
        let now = mediaPlayer.position
        if abs(now - streamLastPoint) > 0.05 {
            streamLastPoint = now
            streamStandsSince = nil
            return
        }
        // If the buffer grows, the stream is alive; then the server is just slow, and
        // nothing is torn down.
        let hasRead = mediaPlayer.countValues?.hasRead ?? 0
        if hasRead > streamRead {
            streamRead = hasRead
            streamBufferGrew = Date()
        }
        let since = streamStandsSince ?? Date()
        streamStandsSince = since

        let rat = StreamWatch.rat(
            standstillSince: Date().timeIntervalSince(since),
            networkChangeForward: nil,
            jumpOpen: playState.leap != nil,
            lastJumpForward: Date().timeIntervalSince(lastJump),
            bufferGrewPre: Date().timeIntervalSince(streamBufferGrew))
        guard rat == .newConnect else { return }

        streamNewBuildUp(reason: "Bild steht")
    }

    /// **Resume at the same position.** `open` rebuilds the stream without touching
    /// the page, so controls, tech badge and tick keep running. The audio output is also
    /// rebuilt, since libVLC opens it fresh with every media, which ``audioCheck()`` and
    /// ``woke()`` rely on.
    func streamNewBuildUp(reason: String, paused: Bool = false) {
        guard let plan = runningPlan else { return }
        AppLog.writeOut("[Strom] neu aufgebaut (\(reason)) bei \(Int(playState.position)) s"
            + (paused ? ", angehalten" : ""))
        streamStandsSince = nil
        audioLossSince = nil
        audioLostLast = nil
        let spot = playState.position
        mediaPlayer.open(plan.url, since: spot, buffer: selection.buffer, paused: paused,
                          softwareDecoder: plan.softwareDecoder,
                          curve: ColorInfo.curve(source: plan.source))
        mediaPlayer.fillFrame(selection.fillFrame)
        playState.tracksSet = false
        trackStatus.newOpened()
    }

    /// **The audio watchdog.** If the audio output breaks (Bluetooth headphones off, KVM
    /// switch, USB card unplugged), the picture keeps going and libVLC discards every audio
    /// block: `audioLost` rises continuously in the counters and it stays silent until
    /// the movie is restarted. Other desktop clients get this bug reported too.
    ///
    /// Three seconds of uninterrupted loss count as broken; then the stream is rebuilt at
    /// the same position and libVLC opens the output on whatever is now the default device.
    /// **At most every 30 s**, so a movie without any audio output does not loop; after a
    /// seek, five seconds of quiet, because VLC briefly discards there.
    private func audioCheck() {
        guard runningPlan != nil, playState.running, playState.startReported,
              Date().timeIntervalSince(lastJump) > 5,
              let lost = mediaPlayer.countValues?.audioLost else {
            audioLossSince = nil
            audioLostLast = nil
            return
        }
        defer { audioLostLast = lost }
        guard let before = audioLostLast, lost > before else {
            audioLossSince = nil
            return
        }
        let since = audioLossSince ?? Date()
        audioLossSince = since
        guard Date().timeIntervalSince(since) >= 3,
              Date().timeIntervalSince(audioNewTried) > 30 else { return }
        audioNewTried = Date()
        streamNewBuildUp(reason: "Tonausgabe verwirft seit 3 s alles, \(lost) Bloecke")
    }

    /// **VLC stops mid-movie**: stop, "end reached" or error, without anyone closing.
    ///
    /// On Apple, `VLCPlayer` then rebuilds the stream at the last good position
    /// (`Sources/Shared/VLCPlayer.swift`); here the event was only logged. If the line
    /// dropped for longer than `http-reconnect` waits, a still image stayed, and after an
    /// error before the first picture the loading veil, both silently.
    ///
    /// It rebuilds only if the title was not at the end yet (more than ten seconds before
    /// the end, same limit as on Apple), and at most three times per title, so a file that
    /// fails at the same spot does not loop.
    func streamTornDown(error: Bool) {
        guard runningTitle != nil, runningPlan != nil, !episodesSwitch.running else { return }
        let spot = playState.position, duration = playState.duration
        if spot <= 1 || mediaPlayer.fetchedImages == 0 {
            guard error else { return }
            AppLog.writeOut("[Player] Fehler vor dem ersten Bild")
            tickEnd()
            let wo = serverName.isEmpty ? translated("dem Server") : serverName
            playerMessage(String(format: translated(
                "Die Wiedergabe hat nicht geklappt. Von %@ kamen keine Daten zum Abspielen."), wo))
            return
        }
        guard duration > 0, spot < duration - 10 else { return }
        guard teardowns < 3 else {
            AppLog.writeOut("[Strom] abgerissen bei \(Int(spot)) s, nach 3 Versuchen aufgegeben")
            return
        }
        teardowns += 1
        streamNewBuildUp(reason: "Strom abgerissen, Versuch \(teardowns)")
    }

    /// Before suspend: pause so the position is on the server (the pause reports it) and
    /// nothing plays into the void after waking.
    func idleStateStart() {
        guard runningTitle != nil else { return }
        AppLog.writeOut("[Ruhe] Rechner schlaeft ein bei \(Int(playState.position)) s")
        fflush(nil)
        guard playState.running else { return }
        mediaPlayer.halt()
        playState.running = false
        playerPlayMarker?.setDown(false)
        mediaStateReport()
    }

    /// After waking: rebuild stream and audio output at the same position. Windows often
    /// reports wake-up twice (automatic, then by the user); the second within ten seconds does not count.
    func woke() {
        guard runningTitle != nil, runningPlan != nil,
              Date().timeIntervalSince(lastWoke) > 10 else { return }
        lastWoke = Date()
        streamNewBuildUp(reason: "aufgewacht", paused: !playState.running)
    }

    // Audio and subtitle selection at start: ``tracksPreSelect()`` in `TrackSelection.swift`.

    /// What the button at the bottom right currently does.
    func offeringRun() {
        offeringLayer.pressed()
        AppLog.writeOut("[Angebot] ausgeloest: \(currentOffering.label) bei \(Int(playState.position)) s")
        fflush(nil)
        offeringUpdate()
        switch currentOffering {
        case .nobody:
            break
        case let .skip(to, _):
            vault(on: to)
            controlsShow()
        case .nextEpisode:
            nextEpisode()
        }
    }

    /// **Pause and resume: button, space bar, one place.** In a group this is a request:
    /// the button flips only when the command arrives.
    func playToggle() {
        if inGroup {
            sharedBitToggle(runningCurrently: playState.running)
            return
        }
        if mediaPlayer.running { mediaPlayer.halt() } else { resumePlaying() }
        playState.running.toggle()
        playerPlayMarker?.setDown(playState.running)
        mediaStateReport()
        controlsShow()
    }

    /// **Resume at the viewer's request, a bit back after a long pause** (iOS
    /// `resume()`, ``Pausenruecksprung``: more than ten minutes, five seconds). The
    /// position is set while VLC is still paused and only then does it start, so the first
    /// new frame is already the earlier one and there is no visible jump back. Display and
    /// report go through ``jumpDirect(on:)`` like any seek. Not in a group, which calls
    /// ``Abspieler/abspielen()`` itself.
    func resumePlaying() {
        let spot = playState.leap?.target ?? mediaPlayer.position
        if let target = PauseJumpBack.target(position: spot, pausedSince: mediaPlayer.pausedSince,
                                             now: Date(), inGroup: inGroup) {
            AppLog.writeOut("[Player] Fortsetzen nach \(Int(Date().timeIntervalSince(mediaPlayer.pausedSince ?? Date()))) s Pause — vorher auf \(Int(target)) s")
            fflush(nil)
            jumpDirect(on: target)
        }
        mediaPlayer.play()
    }

    /// The "Next episode" button: the same prefetched episode the automatic advance uses.
    func nextEpisode() {
        // No next episode in a group: everyone would advance on their own and the group would drift apart.
        guard !inGroup, let episode = prefetchedEpisode else { return }
        changeInto(episode)
    }

    /// **Quality changed in the player**: same title, replanned, at the same position.
    /// Reference: the quality choice in the player on macOS/tvOS/iOS
    /// (`PlayerScreen.qualitySelection`).
    func qualityChanged() {
        // The group can join while the layer is open.
        guard !inGroup, let title = runningTitle else { return }
        AppLog.writeOut("[Qualität] \(selection.alwaysDirectPlay ? "Direct Play" : "\(selection.bitratesLimit) Mbit/s") — neu laden bei \(Int(playState.position)) s")
        fflush(nil)
        qualitySwitched = true
        // A prepared plan for the next episode carries the old choice.
        preparation.forget()
        changeInto(title, since: playState.position)
    }

    /// **Switch to any episode, with the flow from the package.**
    ///
    /// `EpisodeSwitch` holds the latch (one switch at a time), stops the old session and
    /// fetches the plan in parallel, starts only afterwards, and applies nothing after
    /// closing. What stays here is Linux-specific: which states belong to an episode
    /// (``episodeApply``).
    ///
    /// **Not only the prefetched next episode**: this is `toNextEpisode` from the Mac
    /// (`PlayerScreen.swift:899`), so a click on any other episode of the season in the
    /// episode layer also goes through here.
    /// - Parameter ab: start position; empty on an episode change (beginning), set for a
    ///   quality change (resume position), as `toNextEpisode` on macOS/tvOS.
    func changeInto(_ episode: Item, since: Double = 0) {
        // **From file to the next file**: without a plan there is no switch via the server;
        // the player reopens the downloaded episode and records the previous one's position.
        if runningTitle != nil, runningPlan == nil,
           let path = downloads.file(for: episode.id) {
            playerOpen(episode, since: since, fromFile: path)
            return
        }
        guard let client, let title = runningTitle, let plan = runningPlan else { return }
        let change = episodesSwitch
        guard !change.running else {
            AppLog.writeOut("[Wechsel] gesperrt → \(episode.id)")
            fflush(nil)
            return
        }
        readyCount(title, position: playState.position, duration: playState.duration)
        let alt = (title: title, plan: plan, reported: playState.startReported,
                   ticks: Int64(playState.position * 10_000_000))
        let limit = selection.profileBitrate
        let account = userIdentifier
        let applied = Remember()
        // Already fetched in the last minutes (``EpisodePreparation``)? Then use that plan
        // right away, but only for the start of an episode, not for a quality change mid-title.
        let prepared = since == 0 ? preparation.take(episode.id) : nil
        AppLog.writeOut("[Wechsel] Beginn → \(episode.id) · Plan vorbereitet: \(prepared != nil ? "ja" : "nein")")
        fflush(nil)
        Task.detached { [self] in
            let result = await change.execute(EpisodeSwitch.Steps<PlaybackPlan>(
                stopNow: {
                    // A stop without a start is not a session.
                    guard alt.reported else { return }
                    await self.reportStop(client, title: alt.title, plan: alt.plan,
                                          ticks: alt.ticks, account: account)
                },
                planOut: {
                    if let prepared { return prepared }
                    return try? await client.playbackPlan(for: episode.id,
                                                          profile: .vlc(maxBitrate: limit))
                },
                apply: { new in
                    // **On GTK's thread, and checked again here.** The flow runs elsewhere; between its
                    // last check and this task the player may have been closed.
                    waitOnMainThread {
                        guard self.episodesSwitch === change, change.phase == .starts
                        else { return }
                        self.episodeApply(episode, new, since: since)
                        applied.value = true
                    }
                },
                start: { new in
                    guard applied.value else { return }
                    // On GTK's thread: `reportTitle` belongs to it.
                    waitOnMainThread { self.notifyStart(client, title: episode, plan: new, ticks: Int64(since * 10_000_000)) }
                },
                failed: {
                    onMainThread {
                        guard self.episodesSwitch === change else { return }
                        // The old episode keeps playing but the server already knows it as finished. The tick re-registers it.
                        self.playState.startReported = false
                        self.report(translated("Nächste Folge konnte nicht geladen werden."))
                    }
                }))
            AppLog.writeOut("[Wechsel] \(result) → \(episode.id)")
            fflush(nil)
            guard result == .switched else { return }
            // On GTK's thread: `lookUp` reads the download list.
            onMainThread { self.lookUp(for: episode, change: change, client: client) }
        }
    }

    /// Adopt the new episode, **before** the start.
    private func episodeApply(_ episode: Item, _ plan: PlaybackPlan, since: Double = 0) {
        // Delay: the same series keeps it, otherwise null.
        mediaPlayer.delayForNewTitle(oldTitle: runningTitle?.id ?? "",
                                             oldSeries: runningTitle?.seriesId,
                                             newTitle: episode.id, addedSeries: episode.seriesId)
        runningTitle = episode
        teardowns = 0
        runningPlan = plan
        // A limit was chosen but the original plays: either the file already fits or the
        // server does not transcode. Say so instead of staying silent.
        if qualitySwitched {
            qualitySwitched = false
            if !selection.alwaysDirectPlay, plan.method == .directPlay {
                report(translated("Läuft in Originalqualität. Der Server wandelt nichts um."))
            }
        }
        trackStatusNew(episode, plan: plan)
        // Reset position, tracks, start report and first picture; `true`, because the
        // switch reports the start (otherwise only after buffering).
        // `newTitle` also sets `sinceStart` and `firstImagePresent`.
        MainActor.assumeIsolated {
            PlaybackTick.newTitle(&self.playState, startReported: true)
            // **Starting mid-episode is a seek**, as on macOS/tvOS: the display shows the start position at once.
            if since > 0 { PlaybackTick.jumped(&self.playState, target: since) }
        }
        sinceOpen = Date()
        // **Nothing points to the old episode anymore.**
        sections = []
        playerChapter = []
        prefetchedEpisode = nil
        offeringLayer.newEpisode()
        // **Playback speed survives the episode change.** Linux creates a new libVLC player
        // per episode; without this line the next episode would start at 1.0 although the
        // viewer chose 1.25.
        let tempo = mediaPlayer.tempo
        // The next episode starts **from the beginning**.
        mediaPlayer.open(plan.url, since: since, buffer: selection.buffer, softwareDecoder: plan.softwareDecoder,
                          curve: ColorInfo.curve(source: plan.source))
        // What was chosen once also applies to the next episode.
        mediaPlayer.fillFrame(selection.fillFrame)
        techBadgeSet(selection.techBadge)
        mediaPlayer.tempo = tempo
        mediaStateReport()
        // New episode, new sheet: ``TrickplayImages`` notices the changed `titel` id and refetches.
        if let client {
            playerTrickplay?.load(client: client, item: episode, plan: plan)
            chapterLoad(client: client, item: episode, plan: plan)
        }
        // **Update title and meta line**: same series, but "Staffel 1 · Folge 3" becomes "Staffel 1 · Folge 4".
        titleStateRefresh(episode)
    }

    /// **Fetch the chapters of this version.** Per version, not per title: a director's cut
    /// has different chapters. Until they arrive (or without a response) the bar stays one
    /// piece. Adopted only if this title is still playing.
    func chapterLoad(client: JellyfinClient, item: Item, plan: PlaybackPlan) {
        playerChapter = []
        let source = plan.mediaSourceID
        Task.detached { [self] in
            let found = await client.chapter(itemID: item.id, mediaSourceID: source)
            onMainThread {
                guard self.runningTitle?.id == item.id else { return }
                self.playerChapter = found
            }
        }
    }

    /// **Fetch sections and next episode for the running episode**, adopted only if no
    /// switch has begun since, the player is open and still shows this episode
    /// (`EpisodeSwitch.lookUp`).
    func lookUp(for item: Item, change: EpisodeSwitch, client: JellyfinClient?) {
        let applies: @Sendable (App) -> Bool = { app in
            app.episodesSwitch === change && change.phase == .rests
                && app.runningTitle?.id == item.id
        }
        // **Sections stored at download time come first, and without a server the next
        // downloaded episode.** Both rules live in the package (`DownloadRules`), as on Apple.
        // Linux has no network observer; `withoutNetwork` here only means "no account", otherwise an
        // error falls back to the downloaded episode by itself.
        let stored = downloads.entries(for: item.id)?.sections
        let entries = downloads.entries
        Task.detached { [self] in
            await change.lookUp(fetch: {
                await DownloadRules.sections(stored: stored) {
                    await client?.sections(for: item.id) ?? []
                }
            }) { marks in
                onMainThread { if applies(self) { self.sections = marks } }
            }
        }
        guard let series = item.seriesId else { return }
        Task.detached { [self] in
            await change.lookUp(fetch: {
                await DownloadRules.episodePost(item, from: entries, withoutNetwork: client == nil) {
                    try await client?.episodePost(itemID: item.id, seriesID: series)
                }
            }) { episode in
                onMainThread {
                    guard applies(self) else { return }
                    // **No next episode in a group** (iOS `lookUp`): no button, no card, no advance.
                    self.prefetchedEpisode = self.gemeinsam.an ? nil : episode
                    AppLog.writeOut("[Wechsel] naechste Folge \(episode?.id ?? "keine") nach \(item.id)")
                    fflush(nil)
                    self.mediaStateReport()
                }
            }
        }
    }

    // MARK: Show and hide the controls

    /// **While dragging, the slider snaps to the notches** (``Kerbenfang``, as on the Mac,
    /// where it gives a trackpad tick; here silent, like a mouse without Force Touch). Close
    /// enough to a section boundary, it sits exactly on it; `true` means the value is set here
    /// and GTK should not take it over itself.
    func sliderPull(_ raw: Double) -> Bool {
        let duration = playState.duration
        let width = Double(gtk_widget_get_width(playerSlider))
        guard atSlider, duration > 0, width > 0,
              let notch = NotchesSnap.notch(value: raw * duration, until: duration,
                                            marks: sections.flatMap { [$0.from, $0.until] }
                                                + ChapterBar.snapCuts(
                                                    chapterPieces(width: width),
                                                    duration: duration, width: width),
                                            width: width) else {
            sliderSet(raw)
            return false
        }
        let share = notch / duration
        gtk_range_set_value(asSection(playerSlider), share)
        sliderSet(share)
        return true
    }

    /// The bar segments at this width: a single one without chapters. Gap and smallest piece as on the Mac (`Zeitregler`).
    func chapterPieces(width: Double) -> [ChapterBar.Piece] {
        let duration = playState.duration
        return ChapterBar.pieces(limits: ChapterBar.limits(playerChapter, duration: duration),
                                     duration: duration, width: width, minWidth: 8)
    }

    /// The time slider was dragged. **The seek applies immediately** and the state is
    /// carried along: otherwise the next tick would pull it back before VLC arrived at the new position.
    func sliderSet(_ share: Double) {
        guard playState.duration > 0 else { return }
        let target = playState.duration * share
        if inGroup, atSlider {
            gemeinsam.sliderTarget = target
            previewShow(share: share)
            controlsShow()
            return
        }
        vault(on: target)
        controlsShow()
        // The preview follows the handle while dragging.
        if atSlider { previewShow(share: share) }
    }

    /// The skip marker left or right: fades in over 0.15 s, the icon hops, and it fades
    /// out after 0.7 s (Mac: `Sprungmarke`).
    func jumpShow(_ back: Bool) {
        guard let mark = back ? playerJumpLeft : playerJumpRight else { return }
        if let other = back ? playerJumpRight : playerJumpLeft {
            crossfade(other.display, on: 0, duration: 0.15, curve: .easeInOut)
        }
        // **Repeated presses count up** (iOS double-tap counter): 10 s, 20 s, 30 s, as long as
        // the marker of the previous seeks in the same direction is still visible. Here it is the arrow key.
        let step = back ? selection.backSeconds : selection.forwardSeconds
        let untilFrom = jumpSum.flatMap { $0.back == back ? $0.seconds : nil } ?? 0
        let seconds = untilFrom + step
        jumpSum = (back, seconds)
        gtk_label_set_text(OpaquePointer(mark.text), "\(seconds) s")
        mark.symbolText.nudge()
        crossfade(mark.display, on: 1, duration: 0.15, curve: .easeInOut)
        jumpTick += 1
        let mine = jumpTick
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            onMainThread {
                guard self.jumpTick == mine,
                      let mark = back ? self.playerJumpLeft : self.playerJumpRight else { return }
                self.jumpSum = nil
                crossfade(mark.display, on: 0, duration: 0.15, curve: .easeInOut)
            }
        }
    }

    /// **Opacity and clickability of the controls, in one place.**
    ///
    /// They are visible when they should be open and no layer lies above. Fade in 0.18 s
    /// easeOut, fade out 0.34 s easeInOut, opacity only (Mac: `.animation(controlsPresent ?
    ///   .easeOut(duration: 0.18) : .easeInOut(duration: 0.34))`); when a layer opens or
    /// closes, its own timing of 0.2 s. **Clickability always follows**: it was once removed
    /// and never given back, so nothing worked after closing.
    func controlsVisibility(duration: Double? = nil) {
        guard let controls = playerControls else { return }
        let visible = controlsOpen && openLayerArt == nil
        gtk_widget_set_can_target(controls, visible ? 1 : 0)
        crossfade(controls, on: visible ? 1 : 0, duration: duration ?? (visible ? 0.18 : 0.34),
                curve: duration != nil || visible ? .easeOut : .easeInOut)
        titleStateUpdate(duration: duration)
        techBadgeStatus(duration: duration)
    }

    func controlsHide() {
        guard runningTitle != nil, playerControls != nil,
              openLayer == nil, playState.running, !atSlider, !volumePulls else { return }
        controlsTick += 1
        controlsOpen = false
        controlsVisibility()
        showPointer(false)
        offeringUpdate()
    }

    func showPointer(_ an: Bool) {
        guard let window else { return }
        if an {
            gtk_widget_set_cursor(window, nil)
        } else {
            let empty = gdk_cursor_new_from_name("none", nil)
            gtk_widget_set_cursor(window, empty)
            if let empty { g_object_unref(UnsafeMutableRawPointer(empty)) }
        }
    }

    /// Brings up the controls and sets the clock after which they leave again. **They
    /// stay hidden while a layer is open**: otherwise every mouse move brought them back under the layer.
    func controlsShow(through art: OfferingLayer.Opening = .deliberate) {
        guard playerControls != nil else { return }
        showPointer(true)
        guard openLayerArt == nil else { return }
        if !controlsOpen {
            controlsOpen = true
            controlsVisibility()
        }
        if runningTitle != nil { offeringLayer.controls(opened: true, through: art) }
        offeringUpdate()
        controlsTick += 1
        let mine = controlsTick
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            onMainThread {
                guard self.runningTitle != nil, self.playerControls != nil,
                      self.openLayerArt == nil, !self.atSlider, !self.volumePulls,
                      self.controlsTick == mine, self.playState.running else { return }
                self.controlsOpen = false
                self.controlsVisibility()
                self.showPointer(false)
                self.offeringUpdate()
            }
        }
    }

    /// The sleep timer. The steps live in the package. Internal: the settings layer
    /// (`PlayerLayers.swift`) calls it directly.
    func sleepTimeSet(_ minutes: Int) {
        sleepMinutes = minutes
        sleepTick += 1
        let mine = sleepTick
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            onMainThread {
                guard self.sleepTick == mine, self.sleepMinutes == minutes else { return }
                self.mediaPlayer.halt()
                self.sleepMinutes = nil
                self.playState.running = false
                self.playerPlayMarker?.setDown(false)
                self.controlsShow()
                self.report(translated("Schlafzeit abgelaufen."))
            }
        }
    }
}

/// When the time slider is dragged. The signature is `(GtkRange*, GtkScrollType,
/// gdouble, gpointer)`: four arguments, not two.
nonisolated(unsafe) let sliderDragged: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, Double, gpointer?
) -> gboolean = { _, _, share, data in
    guard let data else { return 0 }
    let app = Unmanaged<App>.fromOpaque(data).takeUnretainedValue()
    // false: GTK may take the value itself; true: snapped.
    return app.sliderPull(min(max(share, 0), 1)) ? 1 : 0
}

/// **The notches on the time slider**: start and end of each section, two points wide
/// in `reason`, as thick as the track (4, while dragging 6), omitting the ones at the two edges
/// (Mac `Zeitregler.notches`).
nonisolated(unsafe) let notchesDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    let app = Unmanaged<App>.fromOpaque(data).takeUnretainedValue()
    let duration = app.playState.duration
    let w = Double(width), h = Double(height)
    let withChapters = !app.playerChapter.isEmpty && duration > 0
    guard duration > 0, withChapters || !app.sections.isEmpty else { return }

    // **With chapters: one piece per chapter** (Mac `ChapterMask`). The overlay draws track
    // and bar here, and the slider's own track is transparent. While dragging, only the piece
    // under the handle grows, from four to six points; plain hovering stays calm.
    var elevated: Int?
    var pieces: [ChapterBar.Piece] = []
    if withChapters {
        pieces = app.chapterPieces(width: w)
        let spot = app.playerSlider.map { gtk_range_get_value(asSection($0)) } ?? 0
        if app.atSlider { elevated = ChapterBar.piece(at: spot, in: pieces) }
        let filled = w * min(max(spot, 0), 1)
        for (i, piece) in pieces.enumerated() {
            let frameRect = piece.frameRect(width: w, gap: 2)
            guard frameRect.width > 0 else { continue }
            let d: Double = i == elevated ? 6 : 4
            let y = (h - d) / 2
            cairo_save(cr)
            capsulePath(cr, x: frameRect.x, y: y, width: frameRect.width, height: d)
            cairo_clip(cr)
            // White at 18 % like the slider's track, with the bar over it.
            cairo_set_source_rgba(cr, 1, 1, 1, 0.18)
            cairo_paint(cr)
            let until = min(filled, frameRect.x + frameRect.width)
            if until > frameRect.x {
                cairo_set_source_rgba(cr, 1, 1, 1, 1)
                cairo_rectangle(cr, frameRect.x, y, until - frameRect.x, d)
                cairo_fill(cr)
            }
            cairo_restore(cr)
        }
    }

    // **Notches at section boundaries**, two points in `reason`.
    // `reason` is #101010.
    cairo_set_source_rgba(cr, 16.0 / 255, 16.0 / 255, 16.0 / 255, 1)
    for limit in app.sections.flatMap({ [$0.from, $0.until] }) {
        let share = limit / duration
        guard share > 0.01, share < 0.99 else { continue }
        var thickness: Double = app.atSlider ? 6 : 4
        if withChapters {
            let there = ChapterBar.piece(at: share, in: pieces)
            thickness = (elevated != nil && there == elevated) ? 6 : 4
        }
        cairo_rectangle(cr, (w * share - 1).rounded(), (h - thickness) / 2, 2, thickness)
    }
    cairo_fill(cr)
}

/// A capsule as a path: semicircles at the ends, like the track's `border-radius` (half the thickness).
private func capsulePath(_ cr: OpaquePointer, x: Double, y: Double, width: Double, height: Double) {
    let r = min(height, width) / 2
    cairo_new_sub_path(cr)
    cairo_arc(cr, x + width - r, y + r, r, -Double.pi / 2, Double.pi / 2)
    cairo_arc(cr, x + r, y + r, r, Double.pi / 2, 3 * Double.pi / 2)
    cairo_close_path(cr)
}

/// The timer. Like every C callback, it carries the app as a pointer.
nonisolated(unsafe) let playerTickCall: @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    Unmanaged<App>.fromOpaque(data).takeUnretainedValue().clockOut()
    return 1
}

/// A value touched by exactly one thread at a time; here, whether `anwenden` really
/// applied. `waitOnMainThread` ensures the ordering.
private final class Remember: @unchecked Sendable {
    var value = false
}

/// `onMainThread`, but waiting: `EpisodeSwitch` calls `anwenden` synchronously and
/// reports the start right after. Never call from the main thread.
private func waitOnMainThread(_ block: @escaping @Sendable () -> Void) {
    let done = DispatchSemaphore(value: 0)
    onMainThread {
        block()
        done.signal()
    }
    done.wait()
}

/// What a report to the server needs. The client is captured when queued: if the
/// account changes afterwards, the report still belongs to the one who watched.
struct ReportContent: Sendable {
    let client: JellyfinClient
    let title: Item
    let plan: PlaybackPlan
    let ticks: Int64
    /// The active tracks as Jellyfin indexes, from ``Spurlage``.
    var tracks = TrackIndices()

    var trackText: String {
        "\(tracks.audio.map(String.init) ?? "—")/\(tracks.subtitle.map(String.init) ?? "—")"
    }
}

#if DEBUG
/// Remote control `messages:hanging|normal`: every report waits 60 s, like a server
/// that does not answer. Only to verify that timeline and tick are unaffected and the deadline holds.
enum ReportProbe {
    nonisolated(unsafe) static var hanging = false
}
#endif
