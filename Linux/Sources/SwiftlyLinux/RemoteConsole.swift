import JellyfinKit
import CGtk
import Foundation

/// **A file tells the app where to go.**
///
/// Counterpart to `WindowOffPull` on the Mac (`touch abzug.now`), the other way
/// round: on Linux `spectacle` takes screenshots; what was missing is the way *to*
/// a page.
///
/// **Why it exists.** Checking a result before reporting it costs thirty seconds, while
/// building blind costs whole rounds of rework. On Linux that was not possible:
/// `ydotool` does not reach the app on this Wayland session, whatever the coordinates.
///
/// **Debug builds only.** The release build has neither the file nor the timer; an app
/// that jumps through its pages on command is a remote control nobody asked for.
///
/// ```bash
/// echo profil > /tmp/swiftly-zeige      # profile
/// echo serie:<id> > /tmp/swiftly-zeige  # a series page
/// echo reiter:besetzung > /tmp/swiftly-zeige
/// ```
/// The timer itself, as a free function because a C pointer cannot take a closure with
/// captured context.
private nonisolated(unsafe) let deskTicks: @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    let app = Unmanaged<App>.fromOpaque(data).takeUnretainedValue()
    guard let word = try? String(contentsOf: RemoteConsole.kickoff, encoding: .utf8)
    else { return 1 }
    try? FileManager.default.removeItem(at: RemoteConsole.kickoff)
    app.remoteCommand(word.trimmingCharacters(in: .whitespacesAndNewlines))
    return 1
}

enum RemoteConsole {

    /// On Windows `C:\tmp` is not writable without administrator rights;
    /// there the file lives in the user's temp folder.
    #if os(Windows)
    static let kickoff = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swiftly-zeige")
    #else
    static let kickoff = URL(fileURLWithPath: "/tmp/swiftly-zeige")
    #endif

    /// A one-and-a-half-second tick, the same as on the Mac and for the same reason: slow
    /// enough not to be noticed in operation, fast enough not to wait for.
    static func eavesdrop(_ app: App) {
        #if DEBUG
        // The log says where the console listens: on Windows the location hangs off
        // `NSTemporaryDirectory()`, which need not be the `$env:TEMP` of the session writing
        // the command. If the line is missing, it is not a debug build.
        AppLog.writeOut("[Pult] horcht auf \(kickoff.path)")
        _ = g_timeout_add_seconds(2, deskTicks, Unmanaged.passUnretained(app).toOpaque())
        #endif
    }
}

extension App {

    /// Runs a command from the ``Fernsteuerpult``.
    func remoteCommand(_ word: String) {
        let parts = word.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "start":       show(.start)
        case "filme":       show(.movies)
        case "serien":      show(.seriesList)
        case "suche":       show(.search)
        case "merkliste":   show(.watchlist)
        case "downloads":   show(.downloads)
        case "profil":      subpageOpen(.profile)
        case "einstellungen": subpageOpen(.settings)
        case "wiedergabe":  subpageOpen(.playback)
        case "darstellung": subpageOpen(.presentation)
        case "quickconnect": subpageOpen(.quickConnect)
        case "zurueck":     back()

        #if DEBUG
        /// The test page for frame time (``Messprobe``): `probe:60`.
        case "probe":
            _ = MeasureProbe.pageShow(self, tiles: Int(parts.count > 1 ? parts[1] : "") ?? 60)

        /// Factors 1.0 and 1.5, each with 4, 20 and 60 tiles: scrolling and a single tile.
        /// `messreihe:1.5` measures only that factor.
        case "messreihe":
            guard MeasureProbe.ongoing == nil else { break }
            // `messreihe:1.5:withoutImage,ohneEcke`: factor, then options.
            let part = word.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let factors = part.count > 1 && !part[1].isEmpty ? [Double(part[1]) ?? 1] : [1.0, 1.5]
            let options = Set(part.count > 2 ? part[2].split(separator: ",").map(String.init) : [])
            let tiles = options.contains("nur60") ? [60] : [4, 20, 60]
            MeasureProbe(app: self, steps: factors.flatMap { f in tiles.map { (f, $0) } },
                      options: options).start()

        /// Show a page of the main stack, even without sign-in: `stack:start`. This is how a
        /// machine without an account reaches the settings pages.
        case "stapel":
            gtk_stack_set_visible_child_name(OpaquePointer(pages), parts.count > 1 ? parts[1] : "start")
        #endif

        /// UI size as at the slider: `size:1.2`.
        case "groesse":
            scaleSurface(Double(parts.count > 1 ? parts[1] : "") ?? 1)

        /// Open the first title of a row without knowing its ID.
        case "ersterTitel":
            if let firstOne = gridItems[section]?.first ?? lastStartRail.first {
                openIt(firstOne)
            }

        /// Open a collection by the start of its name, like a click on its tile in a library that
        /// groups movies into collections. `grid` then says what is in it.
        case "sammlung":
            let name = parts.count > 1 ? parts[1] : ""
            let art = section == .seriesList ? "tvshows" : "movies"
            guard let s = collectionDirectory?.collections(art: art)
                    .first(where: { $0.item.name.hasPrefix(name) }) else {
                print("[Fern] keine Sammlung \(name) (\(collectionDirectory?.all.count ?? -1) bekannt)")
                fflush(nil)
                break
            }
            openIt(s.item)

        /// What is in the grid of the visible area.
        case "raster":
            print("[Fern] \(section): \(gridItems[section]?.count ?? -1) Titel, "
                  + (gridItems[section] ?? []).prefix(5).map(\.name).joined(separator: " | "))
            fflush(nil)

        /// Play the first title of the first home row: the only way into the player without a click.
        case "spielen":
            if let firstOne = lastStartRail.first { launch(firstOne) }

        /// Name the first titles of the first home row, so a measurement run knows what `play`
        /// would start before it does so.
        case "startreihe":
            print("[Fern] Startreihe: " + lastStartRail.prefix(5)
                .map { ($0.seriesName ?? $0.name) + " (\($0.type ?? "?"))" }.joined(separator: " | "))
            fflush(nil)

        /// Pause or resume, like the space bar. A measurement run pauses right away so the
        /// remembered position stays on the server.
        case "pause":
            guard runningTitle != nil else { break }
            mediaPlayer.toggle()
            playState.running.toggle()
            playerPlayMarker?.setDown(playState.running)
            mediaStateReport()

        /// Show the controls; they otherwise disappear after a few seconds, and a screenshot
        /// would never see them.
        /// Trigger the update check without clicking through settings. Windows only, since the
        /// row exists only there.
        case "update":
            #if os(Windows)
            updateSearch()
            #else
            // **On Linux without UI, but with the same query.** The button does not exist here; the
            // chain behind it (ask GitHub, read the answer, pick the installer, compare) is the
            // same and can be checked this way without needing a Windows machine.
            Task.detached {
                do {
                    if let state = try await Update.searching() {
                        AppLog.writeOut("[Update] neuer Stand \(state.version), Bau \(state.build.map(String.init) ?? "—"), \(state.size) Bytes, \(state.address.lastPathComponent)")
                    } else {
                        AppLog.writeOut("[Update] nichts Neueres (hier \(Version.full))")
                    }
                } catch {
                    AppLog.writeOut("[Update] Abfrage fehlgeschlagen: \(error)")
                }
            }
            #endif

        /// Open the first movie of a Seerr search (`seerrfilm:Dune`); the page otherwise sits
        /// behind search, typing and a tile.
        case "seerrfilm":
            guard let client = seerrClient, parts.count > 1 else { break }
            let term = parts[1]
            Task.detached { [self] in
                let hit = await client.searching(term).first { !$0.isSeries }
                onMainThread {
                    guard let hit else { AppLog.writeOut("[Fern] Seerr: kein Film"); return }
                    self.seerrPageOpen(hit)
                }
            }

        /// Press the Seerr page's button and report what is there afterwards.
        case "seerrknopf":
            guard seerrButtonRail != nil, let button = gtk_widget_get_first_child(seerrButtonRail),
                  gtk_widget_get_first_child(button) != nil else { break }
            gtk_widget_activate(button)
        case "seerrreihe":
            AppLog.writeOut("[Fern] Seerr-Knopfreihe: " + widgetTexts(seerrButtonRail).joined(separator: " | "))

        /// Type a term into the search field as if typed (`searching:Dune`).
        case "suchen":
            show(.search)
            gtk_editable_set_text(OpaquePointer(searchField), parts.count > 1 ? parts[1] : "")
        /// What the search currently shows: tiles per grid, and how many are drawn.
        case "suchstand":
            func tally(_ r: Widget!) -> String {
                guard r != nil else { return "-" }
                var n = 0, drawn = 0
                while let k = gtk_flow_box_get_child_at_index(OpaquePointer(r), Int32(n)) {
                    if gtk_widget_get_mapped(unsafeBitCast(k, to: Widget.self)) != 0 { drawn += 1 }
                    n += 1
                }
                var children = 0
                var k = gtk_widget_get_first_child(r)
                while let w = k { children += 1; k = gtk_widget_get_next_sibling(w) }
                return "\(n) Kacheln, \(drawn) gezeichnet, \(children) Kinder, sichtbar=\(gtk_widget_get_visible(r))"
            }
            AppLog.writeOut("[Fern] Suche eigen: \(tally(searchGrid)) · Seerr: \(tally(seerrGrid)) Zahl=\(widgetTexts(seerrNumber).joined()) leer=\(gtk_widget_get_visible(searchEmpty)) gestoert=\(gtk_widget_get_visible(searchDisturbance))")

        case "steuerung":  controlsShow()

        /// Close the player again.
        case "spielerZu":  playerClose()

        /// **Measure delay without a server.** `verzugdatei:/pfad.mkv` plays a local file (no
        /// reporting, no playback state); the same file a second time is the same title and keeps
        /// the value. `lag:u:250` / `verzug:t:-500` sets subtitle or audio delay in ms. The log
        /// shows what libVLC reads afterwards.
        case "verzugdatei" where parts.count > 1:
            playerOpen(Item(id: "verzugtest", name: "Verzögerung", type: "Movie"), since: 0,
                           fromFile: URL(fileURLWithPath: parts[1]))
        case "verzug" where parts.count > 1:
            let rest = parts[1].split(separator: ":").map(String.init)
            guard rest.count == 2, let ms = Int(rest[1]) else { break }
            if rest[0] == "u" { mediaPlayer.subtitleDelay = Delay(milliseconds: ms) }
            else { mediaPlayer.audioDelay = Delay(milliseconds: ms) }

        /// Expand or collapse the playback panel in the player.
        case "spurwahl":   unfoldLayer(.tracks)
        case "einstellungenEbene": unfoldLayer(.settings)
        case "folgenEbene": unfoldLayer(.episodes)
        case "ebeneZu":    layerClose()

        /// Load the open title, like the "Laden" button in the panel.
        case "laden":
            if let t = lastFullTitle {
                loadTrigger(t, source: t.mediaSources?.first,
                               bytes: t.mediaSources?.first?.size ?? 0)
            }

        /// Jump to a position (`spot:1331`). A measurement run uses this to restore the
        /// remembered position before closing the player.
        case "stelle":
            if runningTitle != nil, parts.count > 1, let s = Double(parts[1]) { vault(on: s) }

        /// Select a tab of the series page.
        case "reiter":
            switch parts.count > 1 ? parts[1] : "" {
            case "folgen":     tabSelect?(.episodes)
            case "besetzung":  tabSelect?(.cast)
            case "aehnliches": tabSelect?(.similarOne)
            default: break
            }

        /// **Play a title that exercises the whole playback chain**: H.264 or HEVC, audio as
        /// AAC/AC3/DTS, embedded subtitles. Built to prove that the slimmed-down Windows
        /// installer still plays. Only codecs and the ID go into the log, no URL.
        case "pruefspielen":
            guard let client else { break }
            Task.detached { [self] in
                let list = (try? await client.items(limit: 200, recursive: true,
                                                     includeItemTypes: ["Movie", "Episode"]))?.items ?? []
                var substitute: Item?
                for short in list {
                    guard let full = try? await client.item(id: short.id),
                          let streams = full.mediaSources?.first?.mediaStreams else { continue }
                    let image = streams.first { $0.type == "Video" }?.codec ?? ""
                    let audio = streams.first { $0.type == "Audio" }?.codec ?? ""
                    let texts = streams.filter { $0.type == "Subtitle" && $0.isExternal != true }
                        .compactMap(\.codec)
                    guard ["h264", "hevc"].contains(image),
                          ["aac", "ac3", "eac3", "dts"].contains(audio) else { continue }
                    if texts.contains(where: { ["ass", "ssa", "pgssub"].contains($0) }) {
                        print("[Pult] pruefspielen \(full.id): \(full.mediaSources?.first?.container ?? "?") \(image) \(audio) Untertitel \(texts)")
                        fflush(nil)
                        onMainThread { self.playerOpen(full, since: 120) }
                        return
                    }
                    if substitute == nil, !texts.isEmpty { substitute = full }
                }
                if let full = substitute {
                    print("[Pult] pruefspielen Ersatz \(full.id), kein ASS/PGS gefunden")
                    fflush(nil)
                    onMainThread { self.playerOpen(full, since: 120) }
                } else {
                    print("[Pult] pruefspielen: nichts Passendes unter \(list.count) Titeln")
                    fflush(nil)
                }
            }

        /// **Measure episode changes.** `episode:proceed` plays an episode with a successor,
        /// `episode:last` one without, `episode:toward` opens one and closes it immediately (before the
        /// plan exists), `episode:page` plays it from the series page.
        /// `naechsteDoppelt` presses "Nächste Folge" twice in a row.
        case "folge":
            guard let client else { break }
            let art = parts.count > 1 ? parts[1] : "weiter"
            Task.detached { [self] in
                let list = (try? await client.items(limit: art == "abspann" ? 400 : 60, recursive: true,
                                                     includeItemTypes: ["Episode"]))?.items ?? []
                for episode in list {
                    // Without a runtime it is a missing episode without a file.
                    guard let series = episode.seriesId, episode.runTimeTicks != nil else { continue }
                    let to = (try? await client.episodePost(itemID: episode.id, seriesID: series)) ?? nil
                    guard (art == "letzte") == (to == nil) else { continue }
                    // `episode:credits` looks for one with credits, seeks to the end and starts six seconds
                    // before (stage 3, fade-in).
                    var since: Double = 30
                    if art == "abspann" {
                        let marks = await client.sections(for: episode.id)
                        guard let credits = marks.first(where: { $0.art == .credits }),
                              let ticks = episode.runTimeTicks,
                              credits.until >= Double(ticks) / 10_000_000 - SectionLogic.creditsTolerance
                        else { continue }
                        since = max(0, credits.from - 6)
                        print("[Pult] abspann \(Int(credits.from))-\(Int(credits.until)) s")
                    }
                    print("[Pult] folge:\(art) \(episode.id) naechste \(to?.id ?? "keine")")
                    fflush(nil)
                    // `episode:page` first goes to the series page so that the reload after the player
                    // can be measured.
                    if art == "seite" {
                        onMainThread { self.openIt(episode) }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                    }
                    let start = since
                    onMainThread {
                        self.playerOpen(episode, since: start)
                        if art == "zu" { self.playerClose() }
                    }
                    return
                }
                print("[Pult] folge:\(art): nichts unter \(list.count) Folgen")
                fflush(nil)
            }

        /// Scroll the open detail page to a position (`scroll:600`) or just write its position
        /// to the log (`scroll`).
        case "scroll":
            if parts.count > 1, let value = Double(parts[1]), let detailScroller,
               let verticalRight = gtk_scrolled_window_get_vadjustment(OpaquePointer(detailScroller)) {
                gtk_adjustment_set_value(verticalRight, value)
            }
            print("[Pult] scroll \(Int(scrollState()))")
            fflush(nil)

        #if DEBUG
        /// Let reports to the server hang (`messages:hanging`) or send normally again
        /// (`messages:normal`); see ``Meldeprobe``.
        case "meldungen":
            ReportProbe.hanging = parts.count > 1 && parts[1] == "haengen"
            print("[Pult] meldungen haengen \(ReportProbe.hanging)")
            fflush(nil)
        #endif

        /// Timeline to the log (position, VLC time, running).
        case "stelle":
            print("[Pult] stelle \(String(format: "%.1f", playState.position)) vlc \(String(format: "%.1f", mediaPlayer.position)) laeuft \(mediaPlayer.running)")
            fflush(nil)

        /// Pause/resume like the space bar, seek like a remote command.
        case "umschalten":
            mediaPlayer.toggle()
        case "springeAuf":
            if parts.count > 1, let value = Double(parts[1]) { vault(on: value) }

        /// The position the server knows for a title (`serverState:<id>`).
        case "serverstand":
            guard let client, parts.count > 1 else { break }
            let identifier = parts[1]
            Task.detached {
                let title = try? await client.item(id: identifier)
                let ticks = title?.userData?.playbackPositionTicks ?? -1
                print("[Pult] serverstand \(identifier) \(ticks) Ticks = \(String(format: "%.1f", Double(ticks) / 10_000_000)) s")
                fflush(nil)
            }

        /// A key as from the window (`keyButton:eingabe`, `keyButton:escape`); ydotool does not reach
        /// the app under Wayland.
        case "taste":
            let value: UInt32 = parts.count > 1 && parts[1] == "escape" ? 0xFF1B : 0xFF0D
            let needs = keyButton(value, ctrl: false)
            print("[Pult] taste \(parts.count > 1 ? parts[1] : "eingabe") verbraucht \(needs)")
            fflush(nil)

        /// "Next episode automatically": `an`, `aus`, `free` (never toggled).
        case "automatisch":
            let w = parts.count > 1 ? parts[1] : "frei"
            selection.nextAutomaticSelected = w == "an" ? true : w == "aus" ? false : nil
            print("[Pult] automatisch \(w), Konto \(nextAutomaticAccount.map { String($0) } ?? "nil"), gilt \(nextAutomatic)")
            fflush(nil)

        case "naechsteDoppelt":
            nextEpisode()
            nextEpisode()

        /// Play the first finished download from file.
        /// **Play any file**: `dateispielen:/tmp/probe.mkv`. Without a path, the first download.
        /// The route without server and without plan: lets a file with known properties be
        /// measured without touching any real watch state.
        case "dateispielen" where parts.count > 1:
            let path = parts[1]
            // Also a network URL: the same route but with the network options, to measure what a
            // running stream costs when paused, without touching any real watch state.
            if path.hasPrefix("http") {
                guard let address = URL(string: path) else {
                    AppLog.writeOut("[Pult] dateispielen: keine gueltige Adresse \(path)")
                    break
                }
                AppLog.writeOut("[Pult] dateispielen \(path)")
                let item = Item(id: "probe", name: "Probe", type: "Movie")
                playerOpen(item, since: 0, fromFile: address)
                break
            }
            guard FileManager.default.fileExists(atPath: path) else {
                print("[Pult] dateispielen: keine Datei \(path)"); fflush(nil); break
            }
            print("[Pult] dateispielen \(path)"); fflush(nil)
            let item = Item(id: "probe", name: URL(fileURLWithPath: path).lastPathComponent,
                            type: "Movie")
            playerOpen(item, since: 0, fromFile: URL(fileURLWithPath: path))

        case "dateispielen":
            if let p = downloads.entries.first(where: { downloads.file(for: $0.id) != nil }) {
                print("[Pult] dateispielen \(p.id) \(p.container ?? "?")")
                fflush(nil)
                downloadPlay(p)
            } else {
                print("[Pult] dateispielen: kein Download mit Datei")
                fflush(nil)
            }

        /// **Measure track selection** (stage 4). `trackRun:<series>:<episode>` plays the nth
        /// episode (from 1) of the first series the search finds, written `trackRun:Adults/2`.
        case "spurlauf":
            guard let client, parts.count > 1 else { break }
            let detail = parts[1].split(separator: "/").map(String.init)
            let name = detail.first ?? ""
            let number = detail.count > 1 ? Int(detail[1]) ?? 1 : 1
            Task.detached { [self] in
                let hit = (try? await client.search(name)) ?? []
                guard let series = hit.first(where: { $0.type == "Series" }) else {
                    print("[Pult] spurlauf: keine Serie \(name)"); fflush(nil); return
                }
                let episodes = ((try? await client.episodes(seriesID: series.id)) ?? [])
                    .filter { $0.runTimeTicks != nil }
                guard episodes.count >= number else {
                    print("[Pult] spurlauf: \(episodes.count) Folgen"); fflush(nil); return
                }
                let episode = episodes[number - 1]
                print("[Pult] spurlauf \(series.name) \(episode.episodeCode ?? "") \(episode.id)")
                fflush(nil)
                onMainThread { self.playerOpen(episode, since: 60) }
            }

        /// The tracks as the panel shows them, including the selection.
        case "spuren":
            let nowAudio = mediaPlayer.audioTrack, nowUt = mediaPlayer.subtitleTrack
            for s in audioTrackNames() { print("[Pult] Ton \(s.identifier)\(s.identifier == nowAudio ? " *" : "") \(s.name)") }
            for s in subtitleNames() { print("[Pult] Untertitel \(s.identifier)\(s.identifier == nowUt ? " *" : "") \(s.name)") }
            print("[Pult] spuren gemeldet \(trackStatus.reported.audio.map(String.init) ?? "—")/\(trackStatus.reported.subtitle.map(String.init) ?? "—")")
            fflush(nil)

        /// A choice as from the panel: `waehle:ton/<n>`, `waehle:ut/<n>` (nth row from 1) or
        /// `waehle:ut/aus`.
        case "waehle":
            let parts = [parts[0]] + (parts.count > 1 ? parts[1].split(separator: "/").map(String.init) : [])
            guard parts.count > 2 else { break }
            if parts[1] == "ton", let n = Int(parts[2]) {
                let list = audioTrackNames()
                if list.indices.contains(n - 1) { audioTrackSelected(list[n - 1].identifier) }
            } else if parts[1] == "ut" {
                if parts[2] == "aus" { subtitleSelected(nil) }
                else if let n = Int(parts[2]) {
                    let list = subtitleNames()
                    if list.indices.contains(n - 1) { subtitleSelected(list[n - 1].identifier) }
                }
            }

        /// "Next episode", like the button.
        case "naechste":
            nextEpisode()

        /// Toggle "progress on tiles" like the switch (`progress:an|aus`) and count how many
        /// bars were laid since the last call.
        case "fortschritt":
            if parts.count > 1 {
                selection.progressOnTiles = parts[1] == "an"
                homeLoad()
            }
            print("[Pult] fortschritt \(selection.progressOnTiles) balken \(CheckCounter.stripe)"
                  + " erste Reihe \(lastStartRail.count), davon angefangen \(lastStartRail.filter { $0.watchedShare != nil }.count)")
            CheckCounter.stripe = 0
            fflush(nil)

        #if DEBUG
        /// **Hand-over without a second device:** offer two made-up sessions and press the row.
        /// The IDs do not exist; `takeover:2` then selects the second. The server rejects it,
        /// and the error must appear in the row.
        case "uebernahme":
            takeoverProbe(parts.count > 1 ? Int(parts[1]) : nil)
        #endif

        /// Enable the first embedded subtitle track.
        case "untertitel":
            let tracks = mediaPlayer.subtitleTracks.filter { $0.identifier >= 0 }
            if let first = tracks.first { mediaPlayer.setSubtitle(first.identifier) }
            print("[Pult] untertitel: \(tracks.count) Spuren, jetzt \(mediaPlayer.subtitleTrack)")
            fflush(nil)

        /// What is playing right now, in numbers: picture, audio, frames in memory.
        case "bericht":
            let z = mediaPlayer.countValues
            print("[Pult] bericht: laeuft \(mediaPlayer.running) position \(Int(mediaPlayer.position)) " +
                  "videoBloecke \(z?.videoBlocks ?? 0) gezeigt \(z?.shown ?? 0) " +
                  "tonBloecke \(z?.audioBlocks ?? 0) tonGespielt \(z?.audioPlay ?? 0) " +
                  "tonspuren \(mediaPlayer.audioTracks.count) untertitel \(mediaPlayer.subtitleTrack) " +
                  "weg \(runningPlan.map { "\($0.method)" } ?? "Datei") " +
                  "bilder \(ImageCache.count) \(CheckCounter.images)")
            fflush(nil)

        /// **The next-episode card** (variant C): what the layer shows, whether the card is up,
        /// what is on it, and the scrim.
        case "karte":
            let card = playerCard
            let texts = card?.wrapper.map { widgetTexts($0) } ?? []
            print("[Pult] karte anzeige \(offeringLayer.display) angebot \(currentOffering.label) "
                  + "da \(card?.present ?? false) zaehlt \(offeringLayer.cardCounts) "
                  + "abgesagt \(offeringLayer.nextCancelled) rest \(offeringLayer.countdownRest) "
                  + "uhr \(String(format: "%.2f", offeringClock.share())) steuerung \(controlsOpen) "
                  + "schleier \(playerCardsScrim.map { String(format: "%.2f", gtk_widget_get_opacity($0)) } ?? "-") "
                  + "unten \(card?.wrapper.map { gtk_widget_get_margin_bottom($0) } ?? -1) "
                  + "stelle \(Int(playState.position))/\(Int(playState.duration)) texte \(texts)")
            fflush(nil)

        /// Bring up the controls as by pointer (incidentally) instead of deliberately.
        case "zeiger":
            controlsShow(through: .beside)

        /// Press the card's button, or its X.
        case "karteStart":
            offeringLayer.pressed(); offeringUpdate(); nextEpisode()
        case "karteX":
            cardCancel()

        /// Resume like button and space bar, including the rewind after a long pause.
        /// `pausiertVor:900` acts as if paused for 900 s.
        case "weiter":
            playToggle()
        case "pausiertVor" where parts.count > 1:
            #if DEBUG
            if let s = Double(parts[1]) { mediaPlayer.pausedSincePreSet(s) }
            #endif
            print("[Pult] pausiert seit \(mediaPlayer.pausedSince.map { Int(Date().timeIntervalSince($0)) } ?? -1) s")
            fflush(nil)

        /// What is shown at the right under the timeline.
        case "restzeit":
            print("[Pult] restzeit \(widgetTexts(playerRemaining)) alsEnde \(selection.remainingTimeAsEnd)")
            fflush(nil)

        /// The color of the open detail page: class, rules in the stylesheet.
        case "bildton":
            let classKind = detailScroller.flatMap { s in
                gtk_scrolled_window_get_child(OpaquePointer(s)).flatMap { v in
                    AudioSheet.classKind(from: gtk_widget_get_first_child(v) ?? v) } }
            print("[Pult] bildton klasse \(classKind ?? "-") \(AudioSheet.state)")
            fflush(nil)

        /// **Account switch with transition** via the real path: open the profile and trigger the
        /// first account button, like a click. `accountTransition:profile:<ms>` then opens the profile in
        /// the middle of the transition.
        case "kontoflug":
            subpageOpen(.profile)
            let profilePost = parts.count > 1 ? Double(parts[1].split(separator: ":").last ?? "") : nil
            postDeadline(1.0) { [weak self] in
                guard let self, let button = firstButton(self.detailWrapper, classKind: "swiftly-kontoknopf") else {
                    print("[Pult] kontoflug: kein Kontoknopf"); fflush(nil); return
                }
                _ = gtk_widget_activate(button)
                if let ms = profilePost {
                    postDeadline(ms / 1000) { [weak self] in self?.subpageOpen(.profile) }
                }
            }

        /// What the home page shows: number of rows and their opacity.
        case "reihen":
            var rows: [String] = []
            var kind = gtk_widget_get_first_child(railsStack)
            while let k = kind {
                rows.append(String(format: "%.2f%@", gtk_widget_get_opacity(k),
                                     gtk_widget_has_css_class(k, "swiftly-reihe-vor") != 0 ? "v" : ""))
                kind = gtk_widget_get_next_sibling(k)
            }
            print("[Pult] reihen \(rows.count): \(rows.joined(separator: " ")) konto \(username) flug \(accountTransition != nil)")
            fflush(nil)

        /// Open the first person of the cast.
        case "erstePerson":
            // **The full record, not the stack entry.** The stack holds the lean tile, which carries
            // no cast, so the command silently did nothing.
            if let title = lastFullTitle ?? pagesStack[section]?.last,
               let first = title.actors.first {
                openPerson(first, origin: title.name)
            }
        default: break
        }
    }
}

/// Which image formats arrived and whether GTK could read them. Counted in debug builds
/// only, for ``App/fernbefehl(_:)`` "bericht".
enum CheckCounter {
    nonisolated(unsafe) static var images: [String: Int] = [:]
    /// Progress bars laid; Fernsteuerpult `progress`.
    nonisolated(unsafe) static var stripe = 0

    static func image(_ data: Data, hasRead: Bool) {
        let header = [UInt8](data.prefix(12))
        let art: String
        if header.starts(with: [0xFF, 0xD8]) { art = "jpeg" }
        else if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) { art = "png" }
        else if header.count >= 12, header[8] == 0x57, header[9] == 0x45, header[10] == 0x42, header[11] == 0x50 { art = "webp" }
        else { art = "anderes" }
        images["\(art)-\(hasRead ? "ok" : "fehler")", default: 0] += 1
    }
}

/// The first button with this class under a widget, in tree order.
func firstButton(_ w: Widget!, classKind: String) -> Widget? {
    guard let w else { return nil }
    if gtk_widget_has_css_class(w, classKind) != 0 { return w }
    var kind = gtk_widget_get_first_child(w)
    while let k = kind {
        if let hit = firstButton(k, classKind: classKind) { return hit }
        kind = gtk_widget_get_next_sibling(k)
    }
    return nil
}

/// All visible labels under a widget, in tree order, so a measurement run can read what
/// is at a spot without a screenshot.
func widgetTexts(_ w: Widget!) -> [String] {
    guard let w, gtk_widget_get_visible(w) != 0 else { return [] }
    if let name = gtk_widget_get_css_name(w), String(cString: name) == "label",
       let t = gtk_label_get_text(OpaquePointer(w)) {
        return [String(cString: t)]
    }
    var texts: [String] = []
    var kind = gtk_widget_get_first_child(w)
    while let k = kind {
        texts += widgetTexts(k)
        kind = gtk_widget_get_next_sibling(k)
    }
    return texts
}
