import JellyfinKit
import SwiftUI
import UIKit

/// The frame around everything: four sections and the bar at the **top**.
///
/// Structure as on iPhone (four separate navigation stacks, only visited ones are
/// created), with one tvOS-specific difference: invisible stacks must also be
/// **unfocusable**. `opacity(0)` only hides them from the eye; focus moves on into them
/// and the remote ends up in a view nobody sees. `disabled` prevents that.
/// The current play request, passed down to every subpage.
///
/// Why through the environment and not per page: the player must lie over everything,
/// including the top bar, and the rest of the app must take no focus meanwhile. Both can
/// only be guaranteed in one place. When the restriction lived in the page, it applied
/// differently to the home page than to the detail page, which caused the bug where the
/// player could not be left.
private struct PlayKey: EnvironmentKey {
    static let defaultValue: Binding<PlayRequest?> = .constant(nil)
}

/// An open sheet must also disable the top bar.
///
/// Same reasoning as for the play request, one level smaller. A page can disable itself
/// while an `Handlungstafel` is open, but the bar above it does not belong to it. On
/// detail and series pages this never showed, since the bar is gone there (they sit in
/// the stack). On movies and series the bar stays, and focus climbed out of the open
/// sheet up into the section buttons: sheet open, focus elsewhere.
private struct PanelKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    var playRequest: Binding<PlayRequest?> {
        get { self[PlayKey.self] }
        set { self[PlayKey.self] = newValue }
    }

    /// If a page sets this, the top bar takes no focus.
    var panelOpen: Binding<Bool> {
        get { self[PanelKey.self] }
        set { self[PanelKey.self] = newValue }
    }
}

struct MainView: View {
    let model: AppModel

    @State private var section: Region = .start
    @State private var visited: Set<Region> = [.start]
    /// One per section, derived rather than counted.
    ///
    /// There used to be four fixed entries. Once the watchlist was added there are five
    /// sections and `search` has raw value 4, so every access to `pfade[section.rawValue]`
    /// went out of bounds. The app crashed on tapping "Search" (`Array._checkSubscript`).
    ///
    /// On iPhone a comment says `allCases.count` is tempting but dangerous because it grows
    /// silently. That is true and still weighs less than a crash: growing silently means it
    /// works; not growing means it breaks, only when the last tab is tapped.
    @State private var paths = Array(repeating: NavigationPath(),
                                     count: Region.allCases.count)

    /// The player belongs here, not in the page.
    ///
    /// From the detail page it opens cleanly because the top bar yields there (`anRoot`
    /// is false as soon as a path exists). On the home page the bar stays, and an overlay
    /// **inside** the stack lies beneath it: the video ran, the bar stayed in the way, and
    /// since focus sat in it, the Menu button did nothing either.
    ///
    /// So the request lives in the frame and the player on top of everything.
    @State private var play: PlayRequest?

    /// On subpages the top bar yields: content counts there, and Menu goes back.
    ///
    /// `nil` means do not touch Menu, let it fall through: on Start, on subpages and in the
    /// player.
    private var backStart: (() -> Void)? {
        // While a sheet is open, Menu belongs to it.
        //
        // Back first means "this selection closes", then "I leave". The sheet has its own
        // `onExitCommand`, but only receives it if this handler does not intercept the command
        // first. `nil` lets it through.
        guard !panelOpen else { return nil }
        guard section != .start, paths[section.rawValue].isEmpty,
              play == nil else { return nil }
        return { section = .start }
    }

    /// Starts a title from the Top Shelf directly. `false` if that is not possible; the
    /// caller then opens the title page as on select.
    ///
    /// Only what is playable itself. A series or season on the shelf ("Recently Added") has
    /// no single position; there the series page decides which episode is next. If
    /// something is already playing it is not replaced; the app just comes to the front.
    private func shelfStart(_ title: Item) async -> Bool {
        guard play == nil else { return true }
        guard !["Series", "Season", "BoxSet", "Playlist", "Folder", "CollectionFolder"].contains(title.type ?? "")
        else { return false }
        guard let plan = await model.plan(for: title.id) else { return false }
        AppLog.writeOut("[Regal] direkt abspielen: \(title.name) ab \(Int(title.resumeFrom ?? 0)) s")
        play = PlayRequest(item: title, plan: plan, startAt: title.resumeFrom ?? 0)
        return true
    }

    private var anRoot: Bool { paths[section.rawValue].isEmpty && play == nil }

    /// A press on the badge.
    ///
    /// With one session, act at once; with several, ask first. Guessing between two devices
    /// is wrong half the time, and the price is that the movie stops elsewhere.
    ///
    /// Since 1.0.5 also for open groups: with no group as before; exactly one group and
    /// nothing else opens "Join" directly; otherwise the choice with both.
    private func badgePressed() {
        if groupsOfferings.isEmpty {
            if takeover.multiplePresent { fromEmblem = true; selectionOpen = true }
            else if let a = takeover.offering { hereContinueWatching(a) }
        } else if takeover.offerings.isEmpty, groupsOfferings.count == 1,
                  let g = groupsOfferings.first {
            fromEmblem = true
            gemeinsam.sheet = .join(g)
        } else {
            fromEmblem = true
            gemeinsam.sheet = .pick
        }
    }

    /// The sheet grows out of the badge's center, otherwise it fades. `fromEmblem` holds
    /// until after closing, so it shrinks back there too.
    private var panelEntrance: AnyTransition {
        fromEmblem ? .outPoint(BadgeOrigin.point) : .opacity
    }

    /// Groups one could join; only while in none.
    private var groupsOfferings: [SyncPlayGroup] {
        gemeinsam.group == nil && gemeinsam.mayJoin ? gemeinsam.offerings : []
    }

    /// A sheet for "Watch together" is open.
    private var sharedPanel: Bool {
        gemeinsam.createFor != nil || gemeinsam.sheet != nil
    }

    /// Stop the other device and continue here at the same position.
    ///
    /// The order is the whole point: stop there first, then fetch the plan here, then start.
    /// If stopping fails, nothing happens here; otherwise two audio tracks would play in the
    /// room.
    ///
    /// The card grows out of the badge at once; the player opens under it without a fade
    /// (``HandoffStage``).
    private func hereContinueWatching(_ session: RemoteSession) {
        selectionOpen = false
        gemeinsam.sheet = nil
        let stage = HandoffStage.shared
        handoffTask?.cancel()
        stage.start(title: session.running, model: model)
        handoffTask = Task {
            let wish = await takeover.wish(for: session, model: model)
            // Superseded: the newer choice belongs to the stage, not this answer.
            guard !Task.isCancelled else { return }
            guard let wish else {
                stage.cancel("kein Plan oder Stopp abgelehnt")
                return
            }
            stage.playerComes(wish.item.id)
            var without = Transaction()
            without.disablesAnimations = true
            withTransaction(without) { play = wish }
        }
    }

    /// Whether the top bar is shown: its own state, not derived.
    ///
    /// Derived, it could not fade out: the path is set without animation (see the binding in
    /// `stack`), and whatever depends on it jumps with it.
    ///
    /// As its own state set in an `onChange`, the change runs in a new transaction, which may
    /// animate.
    @State private var barPresent = true
    @State private var panelOpen = false
    /// What is playing on another device.
    @State private var takeover = TakeoverModel()
    /// If something plays on several devices, ask instead of guessing.
    @State private var selectionOpen = false
    /// The running takeover; only one counts. Choosing twice before the first answer
    /// arrives cancels the first, and its late answer must not overwrite the newer choice.
    @State private var handoffTask: Task<Void, Never>?
    /// Watch together: one for the whole app, see ``SharedModel``.
    @State private var gemeinsam = SharedModel.shared
    /// Counts up when a badge sheet closes; see `Kopfleiste`.
    @State private var badgeFocus = 0
    /// The open sheet came from the badge, not from a page.
    @State private var fromEmblem = false
    /// What a tile menu ordered: play or a message (``Kachelwunsch``, as on iPhone).
    @State private var tileRequest = TileRequest.shared
    /// Counts up when focus belongs on the profile image at the top after an account
    /// switch; see `Kopfleiste`.
    @State private var profileFocus = 0

    // The bar deliberately does not scroll away. Apple's guideline allows it ("people can
    // scroll the tab bar offscreen when the current tab contains a single main view") and it
    // was built, but it looked wrong: the bar moved half out of the picture and the gradient
    // went with it, leaving the content at the top unprotected. Allowed is not better.

    var body: some View {
        ZStack {
            // The player is a sibling, not a child.
            //
            // `.disabled` used to sit in the chain before `.overlay`, so the player inherited the
            // lock: visible but dead, nothing focusable, every key press unhandled, and Menu fell
            // through, which tvOS read as exit. It vanished on the first press, and no fix inside
            // the player could take effect.
            //
            // Also lock for the selection sheet, not only the player.
            //
            // Otherwise everything behind stays focusable: visibly covered does not mean
            // unreachable on a TV, since the focus engine searches geometrically and knows no
            // layers.
            frameRect
                .disabled(play != nil || selectionOpen || sharedPanel)

            // The scrim fades, the selection grows out of the badge (as on iPhone): if it came from
            // there, it emerges from its center and shrinks back on closing. The background catches
            // the press so nothing behind reacts; the frame is locked anyway.
            if selectionOpen || sharedPanel {
                Color.black.opacity(0.72)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(2.9)
            }

            if selectionOpen {
                TVTakeoverSelection(sessions: takeover.offerings,
                                  select: { hereContinueWatching($0) },
                                  cancel: { selectionOpen = false })
                    .transition(panelEntrance)
                    .zIndex(3)
            }

            // Create, join and the selection with both. Above everything except the player, since
            // any page can open it.
            if sharedPanel {
                TVSharedPanel(continueWatching: takeover.offerings,
                                  hereContinueWatching: { hereContinueWatching($0) },
                                  gemeinsam: gemeinsam)
                    .transition(panelEntrance)
                    .zIndex(4)
            }

            // "Leave movie night / Rejoin" after the player closes. Not over the player, where one
            // is in the group anyway.
            if play == nil, !sharedPanel, let alt = gemeinsam.lastLeave {
                TVReturnPathStrip(name: alt.name) { gemeinsam.againJoin() }
                    .transition(.opacity)
                    .zIndex(4)
            }

            if let wish = play {
                PlayerScreen(model: model, item: wish.item, plan: wish.plan,
                             startAt: wish.startAt) { play = nil }
                // The fade belongs to the shell (`.animation` below), not the content: whatever in the
                // player changes size or position on entry or exit (safe area, video area) would
                // otherwise open and close with the fade.
                .transaction(value: play?.id) { $0.animation = nil }
                .transition(.opacity)
                // Without a fixed layer it did not fade out. A child in a ZStack without `zIndex` slips
                // behind its siblings on removal; the fade ran invisibly behind the home page and the
                // player seemed to vanish abruptly.
                .zIndex(10)
            }
        }
        .environment(\.playRequest, $play)
        .environment(\.panelOpen, $panelOpen)
        // The same fade as on iPhone and Mac.
        .animation(Theme.motion(.easeInOut(duration: 0.3)), value: play?.id)
        .animation(fromEmblem ? Theme.spring : Theme.motion(.easeInOut(duration: 0.2)),
                   value: selectionOpen)
        .animation(fromEmblem ? Theme.spring : Theme.motion(.easeInOut(duration: 0.2)),
                   value: sharedPanel)
        .animation(Theme.reveal, value: gemeinsam.lastLeave?.id)
        // Closing returns to the trigger. If the sheet came from the badge, focus is back there;
        // if from a page, the page takes it itself (see `gemeinsamZu` in the detail and series
        // pages).
        .onChange(of: sharedPanel || selectionOpen) { _, opened in
            guard !opened, fromEmblem else { return }
            fromEmblem = false
            if play == nil { badgeFocus += 1 }
        }
        .task { gemeinsam.start(model) }
        // The group starts the player, not the page: whoever creates, whoever joins, and when
        // someone in the group sets a new title, it always arrives as a queue from the server.
        // What a tile menu orders: "Play" and "Resume" start here in the frame, like any other
        // request.
        .onChange(of: tileRequest.play?.id) { _, new in
            guard new != nil, let wish = tileRequest.play else { return }
            tileRequest.play = nil
            play = wish
        }
        .onChange(of: gemeinsam.wish?.id) { _, new in
            guard new != nil, let wish = gemeinsam.wish else { return }
            gemeinsam.wish = nil
            play = wish
        }
        .task { await model.remoteControlStart() }
        // Once per launch; without an answer nothing happens.
        //
        // `DownloadItem.watched` and `stillOnTheServer` were never set: the low-storage escape
        // always offered an empty list, and the "no longer available" note appeared on no row
        // although the view draws it. One query answers both: what comes back carries progress,
        // what is missing is gone. `MainView` is per platform, so each needs its own call.
        .task { await model.downloadsCatchUp() }
        #if DEBUG
        // Offline self-test; the shared logic underneath is used by all Apple targets.
        .task {
            guard OfflineRun.an else { return }
            try? await Task.sleep(for: .seconds(3))
            guard let wish = await OfflineRun.wish(model) else {
                await OfflineRun.cleanUp(model)
                return
            }
            play = wish
            await OfflineRun.flow(model) { play = nil }
        }
        #endif
        // Only while nothing is playing. In the player the query is pointless: the bar is gone,
        // and the server would answer one more request every ten seconds while the picture
        // matters.
        .task(id: play == nil) {
            if play == nil { takeover.start(model) } else { takeover.finish() }
        }
        .onDisappear { takeover.finish() }
        #if DEBUG
        .task { await debugJump() }
        #endif
        .onDisappear {
            Task { await model.remoteControlEnd() }
            gemeinsam.finish()
        }
        .onChange(of: section) { _, new in visited.insert(new) }
        // Switched off while open, the watchlist must not stay on screen without its tab.
        .onChange(of: model.watchlistShown) { _, shown in
            if !shown, section == .watchlist { section = .start }
        }
        // the page stack is emptied on account switch.
        //
        // iPhone and iPad empty their `pfade` and the Mac calls `navigator.emptyAll()`; only
        // the TV kept what was open. A stack belongs to an account: a detail page hangs on
        // `.task(id: title.id)`, a series page on the season, and neither identifier changes on
        // a switch. Without emptying, the previous account's checkmarks and progress bars would
        // show, and pressing Play would start from its position and report it to the new one.
        .onChange(of: model.accountSwitch) { _, _ in
            // From the profile picker it is already emptied, on the press; see below.
            guard !AccountSwitchTransition.shared.stackAlreadyEmpty() else { return }
            emptyStack()
        }
        // On the press in the profile picker (as on iPhone) a still image of the page fades out;
        // underneath the stack jumps back without animation and focus goes to the profile image
        // at the top, so the profile is reachable again at once.
        .onChange(of: AccountSwitchTransition.shared.back) { _, _ in
            var without = Transaction()
            without.disablesAnimations = true
            withTransaction(without) { emptyStack() }
            profileFocus += 1
            #if DEBUG
            if AccountSwitchRun.an, let ms = AccountSwitchRun.profileTip {
                Task {
                    try? await Task.sleep(for: .milliseconds(ms))
                    AccountSwitchTransition.note("selbsttest: profil oben gedrückt (+\(ms) ms)")
                    paths[section.rawValue].append(ProfileRoute())
                }
            }
            #endif
        }
        #if DEBUG
        // Account switch self-test: open the profile after start, the same way as a press on
        // the profile image.
        .task {
            guard AccountSwitchRun.an else { return }
            try? await Task.sleep(for: .seconds(3))
            AccountSwitchTransition.note("selbsttest: profil oeffnen")
            paths[section.rawValue].append(ProfileRoute())
        }
        #endif
        // Top Shelf: `title` opens the page (select), `play` starts at once and resumes at
        // the remembered position (play button), as Apple expects for launches from the system
        // (HIG, Playing video).
        .onOpenURL { address in
            guard address.scheme == "swiftly",
                  address.host == "titel" || address.host == "abspielen" else { return }
            let identifier = address.lastPathComponent
            guard PathPart.isId(identifier) else { return }
            let direct = address.host == "abspielen"
            Task {
                // Fetch fresh: the position on the shelf is as old as the home page.
                guard let title = await model.item(id: identifier) else { return }
                if direct, await shelfStart(title) { return }
                section = .start
                visited.insert(.start)
                paths[Region.start.rawValue].append(title)
            }
        }
    }

    /// Every stack back to its root; a stack belongs to an account.
    private func emptyStack() {
        for i in paths.indices where !paths[i].isEmpty {
            paths[i] = NavigationPath()
        }
    }

    /// Everything except the player: sections, top bar, error note.
    private var frameRect: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()

            ZStack {
                ForEach(Region.allCases) { b in
                    if visited.contains(b) {
                        stack(b)
                            .opacity(section == b ? 1 : 0)
                            .disabled(section != b)
                            // `disabled` keeps focus away, VoiceOver not. Swiping walked through movies and series
                            // nobody sees: two or three whole screens of invisible tiles between two visible ones.
                            // The Mac already does it this way.
                            .accessibilityHidden(section != b)
                    }
                }
            }
            // The side margin is dropped in the pages themselves, not here: the `NavigationStack` in
            // `stack(b)` resets the safe area for its content, and the setting here had no effect
            // (tried and measured).
            // Plain cross-fade, no movement.
            //
            // The earlier version let the new section rise and the old one sink. That was invented,
            // not copied: the system bar on tvOS only cross-fades. Two heavy pages shifting against
            // each other at once look like a bug, and that is what showed.
            //
            // Top bar and gradient stay out of it; they belong to the frame, not the page.
            .animation(Theme.pagesSwitch, value: section)

            // Between content and top bar: the gradient darkens the content but not the bar itself.
            //
            // Not needed on the home page. It dates from when the rows ran under the bar. Now they
            // start at 560 and are clipped, so nothing comes up that would need darkening. Only its
            // own falloff remained, and on a bright landscape image that shows as an edge.
            //
            // On the other pages tiles keep scrolling under the bar, so it stays there.
            //
            // Not on the home page, and by now not at all there: from here it would necessarily lie
            // on top and turn the title grey, so the home page was always exempt. It had a softer
            // one under its text instead. That is gone too: it shows the same tinted background as a
            // detail page, and the gradient was the last thing making it look different.
            //
            // On the remaining sections it stays: tiles scroll under the bar, and without it they
            // hit it bright.
            if (barPresent || anRoot), section != .start {
                // Only a quiet shadow: the look's glow lies behind the page and must shine through.
                HeaderHistory(soft: true, strength: 0.3).zIndex(1).opacity(barPresent ? 1 : 0)
            }

            if barPresent || anRoot {
                HeaderBar(section: $section, model: model,
                           onProfile: {
                               paths[section.rawValue].append(ProfileRoute())
                           },
                           takeover: takeover.offerings,
                           groups: groupsOfferings,
                           badgePressed: { badgePressed() },
                           badgeFocus: badgeFocus,
                           profileFocus: profileFocus)
                // Without its own section, focus does not jump cleanly from the content into the bar
                // but looks for the horizontally nearest button.
                .focusSection()
                // tvOS lifts the focused view above its siblings. The bar lies on top anyway, but that
                // should not be relied on.
                .zIndex(2)
                .opacity(barPresent ? 1 : 0)
                // Hidden, it is no longer a target: focus should not jump into something that is
                // disappearing. Likewise while a sheet is open; see `panelOpen`.
                .disabled(!barPresent || panelOpen)
            }
        }
        // The change runs here in its own transaction; the path itself is deliberately set
        // without animation, see `stack`.
        .onChange(of: anRoot, initial: true) { _, now in
            withAnimation(Theme.motion(.easeInOut(duration: 0.26))) { barPresent = now }
        }
        // Make server errors visible. `AppModel` collects them in `errorMessage`; on tvOS
        // nobody read it so far.
        .overlay(alignment: .top) {
            if let error = model.errorMessage {
                HintStrip(text: error) { model.errorMessage = nil }
                    .padding(.top, Theme.barBottom + 20)
                    .zIndex(3)
            } else if let message = tileRequest.message {
                // What a tile menu has to say; the same place.
                HintStrip(text: message) { tileRequest.message = nil }
                    .padding(.top, Theme.barBottom + 20)
                    .zIndex(3)
            } else if let error = gemeinsam.error {
                // What went wrong with "Watch together": its own message, the same place.
                HintStrip(text: error) { gemeinsam.error = nil }
                    .padding(.top, Theme.barBottom + 20)
                    .zIndex(3)
            }
        }
        // No focus in the background while playing.
        //
        // `opacity` alone never suffices on tvOS: focus moves on into views nobody sees. Without
        // this the top bar took it, direction keys never reached the player, and Menu fell
        // through to the system, which tvOS understood as leaving the app. Same rule as for the
        // invisible stacks.
        //
        // Menu goes back one level, not out of the app.
        //
        // Unhandled, the command falls through at a section's root to the system, and tvOS
        // closes the app, even from "Search". The expected path is to Start; only from there
        // does Menu leave the app. `nil` means do not touch, let it fall through.
        //
        // On subpages the navigation stack handles it first, being closer to focus. The player
        // likewise; it has its own handling.
        .onExitCommand(perform: backStart)
        .animation(Theme.motion(.easeInOut(duration: 0.2)), value: model.errorMessage)
        .animation(Theme.motion(.easeInOut(duration: 0.2)), value: gemeinsam.error)
    }

    #if DEBUG
    /// Jumps to a page at launch; for debugging only.
    ///
    /// The simulator accepts no remote input from outside: screenshots work, input does not.
    /// Without this, nothing but the home page can be inspected without someone clicking.
    ///
    ///     xcrun simctl launch <device> <bundle-id> -zeige serie
    ///     xcrun simctl launch <device> <bundle-id> -zeige film
    private func debugJump() async {
        let arguments = ProcessInfo.processInfo.arguments
        if let j = arguments.firstIndex(of: "-bereich"), j + 1 < arguments.count {
            switch arguments[j + 1] {
            case "filme":  section = .movies
            case "serien": section = .seriesList
            case "suche":  section = .search
            default:       break
            }
            visited.insert(section)
        }
        if arguments.contains("-messlauf") { await measurementRun(); return }
        if arguments.contains("-folgenende") { await episodesEndRun(); return }
        if arguments.contains("-spurlauf") { await trackRun(); return }
        guard let i = arguments.firstIndex(of: "-zeige"), i + 1 < arguments.count
        else { return }
        if model.views.isEmpty { await model.loadViews() }
        let art = arguments[i + 1] == "film" ? "movies" : "tvshows"
        guard let bib = model.views.first(where: { $0.collectionType == art }),
              let page = await model.items(in: bib.id),
              let firstOne = page.title.first
        else { return }
        paths[section.rawValue].append(firstOne)
    }

    /// Measurement run for server reports, driven by the log instead of the remote.
    ///
    ///     xcrun simctl launch <device> <bundle-id> -messlauf [-meldungenHaengen]
    ///
    /// Plays the first movie from a third in, pauses at +15 s, resumes at +20 s, seeks to
    /// 200 s after the start at +25 s, closes at +40 s and then reads the position back from
    /// the server. Every second the player's tick writes a `[Takt]` line; if they are
    /// missing, it stalled. `-messagesHanging` makes every report wait 30 s for an answer,
    /// like a server that does not respond.
    private func measurementRun() async {
        if model.views.isEmpty { await model.loadViews() }
        guard let bib = model.views.first(where: { $0.collectionType == "movies" }),
              let page = await model.items(in: bib.id),
              let film = page.title.first,
              let plan = await model.plan(for: film.id)
        else { AppLog.writeOut("[Messlauf] kein Film"); return }
        // A third in: below Jellyfin's minimum share (5 %) the server discards the position on
        // stop, and the comparison showed 0.
        let since = ((film.runTimeTicks).map { Double($0) / 10_000_000 } ?? 1200) / 3
        AppLog.writeOut("[Messlauf] oeffne \(film.id) ab \(Int(since)) s")
        play = PlayRequest(item: film, plan: plan, startAt: since)
        // Until the picture is up.
        for _ in 0..<60 where !PlayState.playerRuns {
            try? await Task.sleep(for: .seconds(1))
        }
        func step(_ s: Int, _ command: RemoteCommand) async {
            try? await Task.sleep(for: .seconds(s))
            AppLog.writeOut("[Messlauf] Befehl \(command)")
            model.remoteCommand?(command)
        }
        await step(15, .pause)
        await step(5, .proceed)
        await step(5, .jumpOn(since + 200))
        await step(15, .stop)
        let before = model.playbackEnded
        for _ in 0..<40 where model.playbackEnded == before {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let state = await model.item(id: film.id)
        let ticks = state?.userData?.playbackPositionTicks ?? -1
        AppLog.writeOut("[Messlauf] Server-Stelle \(String(format: "%.2f", Double(ticks) / 10_000_000)) s")
    }

    /// Probe for track selection.
    ///
    ///     xcrun simctl launch <device> <bundle-id> -spurlauf
    ///
    /// Finds an episode with a successor and several tracks (one with an external subtitle
    /// file first), picks audio and subtitles by hand, switches to the next episode and
    /// writes to `[Spurlauf]`, `[Spuren]` and `[Melden]` what was chosen and reported there.
    private func trackRun() async {
        if model.views.isEmpty { await model.loadViews() }
        var multiple: (Item, PlaybackPlan)?
        var extern: (Item, PlaybackPlan)?
        for art in ["tvshows", "movies"] {
            guard let bib = model.views.first(where: { $0.collectionType == art }),
                  let page = await model.items(in: bib.id) else { continue }
            for title in page.title.prefix(40) {
                let candidate = art == "movies" ? [title]
                    : Array((await model.episodes(series: title.id, season: nil) ?? []).prefix(1))
                for episode in candidate {
                    guard let plan = await model.plan(for: episode.id) else { continue }
                    let streams = plan.source?.mediaStreams ?? []
                    let audio = streams.filter { $0.type == "Audio" }.count
                    let ut = streams.filter { $0.type == "Subtitle" }
                    let ex = ut.filter { $0.isExternal == true }
                    AppLog.writeOut("[Spurlauf] \(title.name) · Ton \(audio) · Untertitel \(ut.count) · extern \(ex.count)"
                        + " · Vorgaben \(plan.source?.defaultAudioStreamIndex ?? -9)/\(plan.source?.defaultSubtitleStreamIndex ?? -9)"
                        + (ex.isEmpty ? "" : " · \(ex.map { "\($0.index ?? -1) \($0.codec ?? "") \($0.deliveryUrl ?? "ohne Adresse")" })"))
                    let proceed = art == "movies" ? false : await model.episodePost(episode) != nil
                    if !ex.isEmpty, extern == nil { extern = (episode, plan) }
                    if proceed, audio >= 2, ut.count >= 2, multiple == nil { multiple = (episode, plan) }
                }
                if extern != nil, multiple != nil { break }
            }
        }
        let arguments = ProcessInfo.processInfo.arguments
        guard let (episode, plan) = arguments.contains("-extern") ? (extern ?? multiple) : (multiple ?? extern) else {
            AppLog.writeOut("[Spurlauf] nichts gefunden"); return
        }
        AppLog.writeOut("[Spurlauf] oeffne \(episode.name) \(episode.id)")
        play = PlayRequest(item: episode, plan: plan, startAt: 60)
        for _ in 0..<60 where !PlayState.playerRuns { try? await Task.sleep(for: .seconds(1)) }
        try? await Task.sleep(for: .seconds(6))
        guard let area = VLCPlayerView.recent else { AppLog.writeOut("[Spurlauf] keine Flaeche"); return }
        let names = area.subtitleNames()
        AppLog.writeOut("[Spurlauf] Ton \(area.audioTracks.map { "\($0.trackId)=\($0.prettyName)" })")
        AppLog.writeOut("[Spurlauf] Untertitel \(area.subtitleTracks.map { "\($0.trackId)=\(names[$0.trackId] ?? "?")" })")
        // Manual pick: with equal names the second, otherwise a file, otherwise the last.
        let tracks = area.subtitleTracks
        let double = tracks.enumerated().first { pair in
            tracks.prefix(pair.offset).contains { $0.trackName == pair.element.trackName }
        }?.element
        let file = tracks.first { PlayerTrack(identifier: $0.trackId, name: "", language: nil, codec: nil, channels: nil).additionId != nil }
        if let audio = area.audioTracks.last { area.selectAudioTrack(audio) }
        if let choice = (arguments.contains("-extern") ? file : double) ?? file ?? double ?? tracks.last {
            area.selectSubtitle(choice)
        }
        try? await Task.sleep(for: .seconds(12))
        AppLog.writeOut("[Spurlauf] Befehl naechste")
        model.remoteCommand?(.next)
        try? await Task.sleep(for: .seconds(30))
        if let new = VLCPlayerView.recent {
            AppLog.writeOut("[Spurlauf] danach Ton \(new.selectedAudioTrack?.trackId ?? "—") Untertitel \(new.selectedSubtitle.map { new.subtitleNames()[$0.trackId] ?? $0.trackId } ?? "aus")")
        }
        model.remoteCommand?(.stop)
    }

    /// Probe for the end-of-episode prompt.
    ///
    ///     xcrun simctl launch <device> <bundle-id> -folgenende [-ab <s>]
    ///
    /// Opens the first episode with a successor, without `-ab` 25 s before the end, with
    /// `-ab` at that second (negative: before the end). What the prompt does is in the log
    /// under `[Angebot]`.
    private func episodesEndRun() async {
        if model.views.isEmpty { await model.loadViews() }
        let arguments = ProcessInfo.processInfo.arguments
        let wish = arguments.firstIndex(of: "-ab").flatMap { i in
            i + 1 < arguments.count ? Double(arguments[i + 1]) : nil
        } ?? -25
        guard let bib = model.views.first(where: { $0.collectionType == "tvshows" }),
              let page = await model.items(in: bib.id) else {
            AppLog.writeOut("[Probe] keine Serien"); return
        }
        for series in page.title.prefix(10) {
            for episode in (await model.episodes(series: series.id, season: nil) ?? []).prefix(3) {
                guard let ticks = episode.runTimeTicks, await model.episodePost(episode) != nil,
                      let plan = await model.plan(for: episode.id) else { continue }
                let duration = Double(ticks) / 10_000_000
                let since = wish < 0 ? duration + wish : wish
                AppLog.writeOut("[Probe] oeffne \(episode.id) ab \(Int(since)) von \(Int(duration)) s")
                play = PlayRequest(item: episode, plan: plan, startAt: since)
                return
            }
        }
        AppLog.writeOut("[Probe] keine Folge mit Nachfolger")
    }
    #endif

    // No `@ViewBuilder`: the function first computes the binding and then returns **one**
    // view. With a builder in front, Swift warns that the explicit `return` disables it; it
    // has no job here.
    private func stack(_ b: Region) -> some View {
        // No cross-fade on page change, at the binding.
        //
        // It is no single layer anymore: header block, backdrop fade, tinted background and
        // header shadow are now the same. It is SwiftUI's own transition, which fades the new
        // page over the old and **both change opacity**. At the midpoint neither is fully
        // opaque, so brightness dips. That shows even with identical content: it does not fade
        // between two images, it fades both against the background.
        //
        // At the call site it was too far out. A `transaction` on the view containing the stack
        // does not reach the animation the stack keeps internally for its change. The binding is
        // the narrowest point every change must pass: tiles with their `NavigationLink`, Menu
        // going back, deep links. Whoever sets it sets it without animation.
        let path = Binding<NavigationPath>(
            get: { paths[b.rawValue] },
            set: { new in
                // And additionally at the UIKit level.
                //
                // The SwiftUI transaction alone is not enough: on tvOS the `NavigationStack` performs
                // its change through a UIKit navigation controller, which does not see it. It shows in
                // the text: white text briefly turns grey during the change, which is nothing but half
                // opacity over a dark background.
                //
                // Disabled for one pass and re-enabled in the next; longer would be dangerous, since
                // focus movement depends on it too.
                UIView.setAnimationsEnabled(false)
                var without = Transaction()
                without.disablesAnimations = true
                withTransaction(without) { paths[b.rawValue] = new }
                DispatchQueue.main.async { UIView.setAnimationsEnabled(true) }
            }
        )
        return NavigationStack(path: path) {
            Group {
                switch b {
                case .start:
                    HomeView(model: model)
                case .movies:
                    LibraryView(model: model, art: "movies")
                case .seriesList:
                    // Without "Unwatched": the server filter works at episode level there and hides
                    // partly watched series. "Watchlist" is back, as on iPhone, since it no longer has its
                    // own tab.
                    LibraryView(model: model, art: "tvshows",
                                   filter: [.all, .begun, .watchlist])
                case .watchlist:
                    WatchlistView(model: model)
                case .search:
                    SearchView(model: model, active: section == .search)
                }
            }
            .targetPlace(model: model)
        }
    }
}

// MARK: - Shared destinations

extension View {
    /// The destinations hang on the stack, not on the single page; otherwise every section
    /// would have to know them individually.
    func targetPlace(model: AppModel) -> some View {
        self
            .navigationDestination(for: LibraryRoute.self) { route in
                LibraryView(model: model, library: route.item)
            }
            .navigationDestination(for: SeerrHit.self) { hit in
                SeerrDetailView(model: model, hit: hit)
            }
            // The same switch as on iPhone: a series leads to the series page, a single episode to
            // the season it belongs to. A page just for one episode adds nothing the list does not
            // already show.
            .navigationDestination(for: Item.self) { item in
                if item.type == "Series" {
                    SeriesView(model: model, series: item)
                } else if item.type == "Episode" {
                    SeasonTarget(model: model, episode: item)
                } else if item.type == "Playlist" {
                    PlaylistView(model: model, playlist: item, art: nil)
                } else if item.type == "BoxSet" {
                    // A collection from search or watchlist: without a section, so everything in it, as on
                    // iPhone.
                    LibraryView(model: model, collection: item)
                } else {
                    DetailView(model: model, item: item)
                }
            }
            .navigationDestination(for: SeasonRoute.self) { route in
                SeriesView(model: model, series: route.series,
                           startSeasonID: route.season.id)
            }
            .navigationDestination(for: ProfileRoute.self) { _ in
                ProfileView(model: model)
            }
            .navigationDestination(for: PersonRoute.self) { route in
                PersonView(model: model, route: route)
            }
            .navigationDestination(for: GenreRoute.self) { route in
                GenreView(model: model, name: route.name)
            }
            .navigationDestination(for: PlaylistRoute.self) { route in
                PlaylistView(model: model, playlist: route.playlist, art: route.art)
            }
            .navigationDestination(for: CollectionRoute.self) { route in
                LibraryView(model: model, art: route.art, collection: route.collection)
            }
    }
}


// MARK: - Detour from an episode to its series

/// Fetches the series for an episode and shows the series page, with the episode's
/// season already selected.
///
/// List entries carry only `seriesId`, not the series itself, hence this intermediate
/// step. Same approach as on iPhone.
struct SeasonTarget: View {
    let model: AppModel
    let episode: Item

    @State private var series: Item?

    /// Fetch the season fresh; do not trust the tile's.
    ///
    /// The list entry carries the season it had when the home page loaded. Someone who
    /// finishes a season and adds the next still sees the old one there: the page opened with
    /// "Play S6E1" at the top and season 5 in the episode list. Same pattern as the resume
    /// position in `HomeView.starte`, same remedy.
    @State private var freshSeasonID: String?

    /// The series is shown at once if it was fetched before.
    ///
    /// Otherwise this view showed a spinner on black on every episode open and then swapped
    /// it for the series page. While the page change cross-faded that lay underneath; without
    /// the cross-fade it is the first thing one sees.
    @MainActor init(model: AppModel, episode: Item) {
        self.model = model
        self.episode = episode
        _series = State(initialValue:
            episode.seriesId.flatMap { SeriesCache.shared.state($0, with: model)?.series }
            ?? SeasonTarget.provisional(toward: episode))
    }

    /// A provisional series built from what the episode carries anyway.
    ///
    /// Not the image, the **series**. An episode's list entry carries only `seriesId` and
    /// `seriesName`, and `SeriesView` needs an `Item`. That used to take a server request,
    /// and that was the wait.
    ///
    /// Almost nothing is needed on opening: `id` for further requests, `name` for the
    /// heading, `type` for the switches. The backdrop is the same anyway: `landscapeImageURL`
    /// builds it from `seriesId ?? id`, so for episode and series from the same identifier,
    /// and it is already decrypted.
    ///
    /// Everything else (description, rating, season count) `SeriesView.load()` fetches
    /// itself and writes over this state (`frisch ?? series`). So nothing waits for anything.
    ///
    /// Via JSON and not an initializer, because `Item` has no public one: all fields are
    /// `let` and the initializer comes from `Codable`. Adding `Item(id:name:type:)` would be
    /// cleaner and belongs in the package, and by the rule first on iOS. Until then it lives
    /// here, where it affects nobody else.
    @MainActor
    private static func provisional(toward episode: Item) -> Item? {
        guard let id = episode.seriesId, let name = episode.seriesName else { return nil }
        let fields: [String: String] = ["Id": id, "Name": name, "Type": "Series"]
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        return try? JSONDecoder().decode(Item.self, from: data)
    }

    var body: some View {
        ZStack {
            if let series {
                // The episode one came in through is also where playback continues; see
                // `SeriesView.startEpisodeValue`.
                SeriesView(model: model, series: series,
                           startSeasonID: freshSeasonID ?? episode.seasonId,
                           startEpisodeValue: episode)
            } else {
                // No opaque black. The first time the wait is real (the series must be fetched), but it
                // should not sit on black. The episode's tinted background is ready, so it stands here
                // too, and the transition to the series page is just the content, not the whole screen.
                // No spinner: the tinted background is already up and the page follows by itself.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .imageReason(url: model.landscapeImageURL(for: episode, width: 1600)
                                    ?? model.headerImageURL(for: episode))
            }
        }
        .task {
            guard let id = episode.seriesId else { return }
            async let freshValue = model.item(id: episode.id)
            if series == nil { series = await model.item(id: id) }
            freshSeasonID = await freshValue?.seasonId
        }
    }
}


