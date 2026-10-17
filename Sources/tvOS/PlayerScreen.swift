import GameController
import JellyfinKit
import SwiftUI
import VLCKit

/// The player, modeled on the iPhone version.
///
/// Top right: icon buttons (episodes, settings). Bottom left: title and context
/// line. Bottom right: "Next episode", with the timeline below it and the times
/// at its left and right. Picture-in-picture is omitted; tvOS has none.
///
/// **Focus sits on the timeline, not on a button.** It is the control needed
/// most; left/right seek, up moves to the buttons. The remote's Play/Pause
/// button pauses; there is deliberately no pause button on screen, as in
/// Apple's own player.
struct PlayerScreen: View {
    let model: AppModel
    /// The title at open time. The video surface hangs off it and must not change, or SwiftUI recreates the surface and the stream restarts.
    let startPlan: PlaybackPlan
    let startAt: Double
    /// Closes the player. A callback rather than `dismiss`, because the player is shown as an overlay, not a sheet.
    let close: () -> Void

    /// The current title. **Changes when switching to the next episode.**
    ///
    /// Declared as `let`, everything kept pointing at the old episode after a switch: sheet title, episode list and, above all, the server reports.
    @State private var item: Item
    @State private var plan: PlaybackPlan

    @State private var area: VLCPlayerView?
    /// Counts only while the badge is on; see `TechBadge`.
    @AppStorage("technikschild") private var techBadge = false
    @State private var playValues: PlayValues?
    @State private var position: Double
    /// When the player opened; `TimeAssumption` uses it to tell load-time flicker from real motion.
    @State private var sinceStart = Date()
    @State private var restoring = false
    @State private var duration: Double = 0
    @State private var running = true
    @State private var firstImagePresent = false
    @State private var controlsVisible = true
    /// The picture is currently being cast to another device.
    @State private var handoverRuns = false
    @State private var fadeOutMark = 0
    /// One of the three layers: audio and subtitles, episodes, settings.
    @State private var openLayer: PlayerLayer?
    /// Preview images above the bar while scrubbing.
    @State private var trickplay = TrickplayImages()
    @State private var tracksSet = false
    @State private var startReported = false
    /// Intro, recap, outro; empty if the server knows none.
    @State private var sections: [JellyfinKit.Segment] = []
    /// The file's chapters; they divide the bar. Empty: one segment.
    @State private var chapter: [Chapter] = []
    /// "Skip intro" and "Next episode" over the picture, without controls. What shows when is defined in `OfferingLayer` in the package. The next-episode card waits while the controls are open and returns when they close; Menu cancels it.
    @State private var layer: OfferingLayer = {
        var e = OfferingLayer()
        e.cardWaitsControls = true
        return e
    }()
    /// The switch is already running; mirrors the latch of `episodesSwitch`.
    @State private var switches = false
    @State private var episodesSwitch = EpisodeSwitch()
    /// Plan and file start of the next episode, fetched in the last minutes, as on iPhone (``EpisodePreparation``, rules in `Vorpuffer`).
    @State private var preparation = EpisodePreparation()
    /// Since when the next episode has been loading; for the switch time in the log.
    @State private var switchStart: Date?
    /// Incremented on every title change; the loop resets its state via `PlaybackTick.newTitle`, as on iOS. Without it `sinceMessage` survived the switch and the first report of the new episode came after seconds instead of ten.
    @State private var titleSwitch = 0
    /// Start position of an episode chosen in the episode layer, until the loop takes over.
    @State private var startPostSwitch: Double?
    /// "Next episode could not be loaded." and similar.
    @State private var hint: String?
    /// The next plan comes from a quality choice; used for the hint.
    @State private var qualitySwitched = false
    @State private var tempo: Float = 1.0
    /// Remote playback buttons and the Now Playing display.
    ///
    /// More important on TV than on the phone: the Siri Remote has its own playback buttons, and without a central handler they do nothing while the app is not frontmost.
    @State private var hub = PlaybackHub()
    /// **The switch lives in a class, not in the view.**
    ///
    /// It holds `recent`, which is needed because **one key press arrives twice**: as `onPlayPauseCommand` on the focused view and as `togglePlayPauseCommand` from the playback center. Two toggles cancel out. On the phone this goes unnoticed, since only the center path exists.
    ///
    /// Callbacks that linger somewhere (playback center, system) capture the view as it was when registered, so every `running` in them is stale. A class is read by reference and is always current.
    @State private var switchgear = Switchgear()


    /// The target being aimed at while tapping, **separate from `position`**. While set, the bar shows the target rather than the current position, and playback continues.
    @State private var seekTarget: Double?
    /// Waits until tapping stops, then seeks once.
    @State private var seekTask: Task<Void, Never>?
    /// When the last step arrived. It only decides between collecting and seeking immediately; the growing step size is gone, see `jump`.
    @State private var lastStep = Date.distantPast
    @State private var sleepMinutes: Int?
    @State private var sleepTask: Task<Void, Never>?
    /// Whether a finger is currently dragging across the surface.
    ///
    /// A swipe **also** fires step commands, the same ones the ring sends on press. Without this distinction every swipe seeked twice: once by distance, once by step.
    @State private var swipes = false
    @State private var swipeEnd = Date.distantPast
    /// Where the marker came from. A grabbed marker waits for the middle button; a tapped one seeks by itself once tapping rests.
    @State private var markSwipe = false
    /// Was the film playing before scrubbing paused it? Then it resumes after confirm or cancel, as in the system player.
    @State private var ranBeforeScrubbing = false
    /// The marker coasting after a fast swipe.
    @State private var rollOut: Task<Void, Never>?
    /// Holding left/right on the click ring: runs while held.
    @State private var sampleTask: Task<Void, Never>?
    /// **Deferred focus placement, only one at a time.** Every place that sets focus again a beat later used to run freely. If a second trigger came within the 80 to 600 ms, the old run then set its stale target and pulled focus away from where the new one had just put it.
    @State private var focusPostPull: Task<Void, Never>?
    @State private var probing = false
    @State private var clickRing = ClickRing()
    /// This swipe fetched the controls and does nothing else.
    ///
    /// **The swipe that opens the menu does not seek.** Before, it did both: `swipeStart` shows the controls, so `controlsPresent` became true in the same step and the same finger's motion already moved the timeline. The user only wanted to see where they were and ended up elsewhere.
    @State private var swipeOnlyOpened = false
    @State private var next: Item?
    /// **The next-episode card** (``EpisodeCard``, variant C), kept with its episode and countdown while it zooms into view.
    @State private var cardsSwitch: CardsSwitch?
    @State private var cardsEpisode: Item?
    @State private var cardsClock: FillClock?
    @State private var cardsZoom: Double = 0
    @State private var cardImage: Double = 1
    /// A seek VLC has not reached yet; until then the bar shows the target (`PlaybackTick.Jump`).
    @State private var leap: PlaybackTick.Jump?
    /// The card's fill as one continuous motion (`FillClock`).
    @State private var fillClock = FillClock()

    /// **Whether something is loading although playback should run.**
    ///
    /// Three cases that all occur and used to look the same, namely like nothing: after a seek VLC rebuilds the stream; after returning from the background the picture is frozen while audio already plays; and on a network dropout both stand still.
    @State private var stalls = false
    @State private var stillSince: Date?
    @State private var lastVLCTime: Double = -1

    /// **Where focus is, and whether it is anywhere at all.**
    ///
    /// This used to be a `Bool` for the bar alone. "On the settings button" then looked the same as "nowhere", and restoring focus while stopped kept tearing it off the button, so settings became unreachable. With the targets as an enum, `nil` really means "nowhere", and only then is anything done.
    @FocusState private var focus: FocusTarget?
    /// Where focus goes when the controls appear: the bar, unless "up" asked for the buttons.
    @State private var targetShow: FocusTarget = .bar

    /// **Watching together.** Set at open if the title is the one the group is watching. The group itself is held by ``SharedModel``.
    ///
    /// Stored twice, for the same reason as `Switchgear`: the view draws from `@State`, while the retained callbacks of the playback center read `switchgear.gemeinsam`. Otherwise pause and seek would bypass the group from there.
    @State private var sharedAn = false
    @State private var bridge = SharedPlayer()
    private var gemeinsam: SharedModel { .shared }
    /// Is this player currently in a group? Then pause, resume and seek go to the server as requests, not to VLC.
    private var inGroup: Bool { switchgear.gemeinsam && gemeinsam.group != nil }
    /// The same for display; held in `@State` so it updates.
    private var groupShow: Bool { sharedAn && gemeinsam.group != nil }
    /// Playback pauses when the app is left; see below.
    @Environment(\.scenePhase) private var phase

    enum FocusTarget: Hashable { case idle, bar, tracks, settings, episodes, offering }

    init(model: AppModel, item: Item, plan: PlaybackPlan, startAt: Double,
         close: @escaping () -> Void) {
        self.model = model
        self.startPlan = plan
        self.startAt = startAt
        self.close = close
        // **Do not start at zero.**
        //
        // Otherwise the bar briefly sits at the start and jumps forward once the stream has its position. Barely visible for episodes, clear for movies, which take longer to start.
        _position = State(initialValue: startAt)
        _item = State(initialValue: item)
        _plan = State(initialValue: plan)
    }

    private var controlsPresent: Bool {
        controlsVisible && firstImagePresent && !layerOpen
    }

    private var layerOpen: Bool { openLayer != nil }

    /// **The overlay above the picture**, only without controls and without a sheet. With controls open, the same offer sits in the bar.
    private var cardPresent: Bool {
        layer.display.visible && firstImagePresent && !controlsPresent
            && !layerOpen && !switches
    }

    /// The next-episode card is showing (or zooming in); the countdown case of `cardPresent`.
    private var episodesCardPresent: Bool {
        cardsSwitch != nil || (cardPresent && countdownShare != nil)
    }

    /// The pill at the bottom right, except while the card is there.
    private var pillPresent: Bool {
        offeringPresent && countdownShare == nil && cardsSwitch == nil
    }

    private static func spring(_ omega: Double) -> Animation {
        let f = EpisodeCard.spring(omega)
        return Theme.motion(.interpolatingSpring(mass: 1, stiffness: f.stiffness,
                                                  damping: f.damping))
    }

    /// **The offer button is in one place whether or not the controls are open** (as on iOS). Skipping shows for the first six seconds of the section, afterwards only with the controls (`OfferingLayer.buttonDuration`). When it fades out, `cardPresent` becomes false and focus returns to the rest layer via `onChange(of: cardPresent)`. With the controls closed the card shows; with them open, the normal "Next episode" button. The bar only keeps the space free. `cardPresent` stays the question of whether it shows *without* controls; focus and Back depend on it.
    private var offeringPresent: Bool {
        // While scrubbing it gives way to the preview above the bar.
        guard offering.visible, firstImagePresent, !layerOpen, !switches, seekTarget == nil else { return false }
        return layer.display.visible || (controlsPresent && offering == .nextEpisode)
    }

    /// Whether the focus rest is active: no controls, no sheet, no overlay. If the overlay is up, focus belongs to it; otherwise it drifts by swiping onto the invisible surface and a click pauses instead of skipping.
    private var idlePresent: Bool { !controlsPresent && !layerOpen && !cardPresent }

    var body: some View {
        ZStack {
            Color.black

            // **A home for focus even when nothing is visible.**
            //
            // `itemWitness.opacity(0)` removes the controls not just from the picture but **from the focus system**. Once they vanish after four seconds, focus sits nowhere, and without focus tvOS accepts no input at all: the film keeps playing, the remote is dead, and the Menu key falls through to the system and leaves the app instead of closing the player.
            //
            // The same applied **before the first frame**, which is why Back in the first seconds went to the Apple TV home screen. Whoever paused early noticed nothing: hiding depends on `running`, so while paused the controls and their focus stayed.
            //
            // This layer is always present and holds focus when nobody else does. It is focusable only then; otherwise it takes focus from the bar when the bar is needed.
            Color.clear
                // **And focusable while it has focus.** If it became unfocusable in the same step in which the controls appeared, and SwiftUI dropped the move to the bar, focus sat on a surface that no longer received commands: up, left, right did nothing. This way the next press arrives here again and fetches the controls.
                .focusable(idlePresent || focus == .idle)
                .focused($focus, equals: .idle)
                // **Up leads upward.** After opening, focus is still here, not on the bar; a press up landed on the bar first, and only the second reached the buttons.
                .onMoveCommand { bearing in
                    if bearing == .up {
                        // The target is noted and applied when the controls appear; see `onChange(of: controlsPresent)`.
                        targetShow = .tracks
                        // If they are already up because a focus move was dropped, nothing will apply it later, so do it here.
                        if controlsPresent { focus = .tracks }
                        showItem()
                    } else {
                        wakeControls()
                    }
                }
                .onTapGesture { wakeControls() }

            VideoSurface(url: startPlan.url, startAt: startAt,
                         container: startPlan.container,
                         buffer: model.bufferLevel,
                         subtitle: model.subtitleFiles(startPlan),
                         softwareDecoder: startPlan.softwareDecoder,
                         tracks: trackRequest(item, startPlan)) { new in
                area = new
                // What was chosen under "Picture" in the sheet also applies to the next episode; same key as the gesture on iPhone.
                new.fillFrame(UserDefaults.standard.bool(forKey: "bildfuellend"))
                new.onRestoration = { restoring = $0 }
                // **The button follows VLC's report, not the press.**
                //
                // Measured: from the click until VLC reports "paused" takes 17-25 ms, until the film time actually stands 26-36 ms. Setting the button in the press flips it **before** the picture, which looks like an unresponsive player. A 500 ms tick would be too late.
                //
                // On this report button and picture stop at the same moment; the gap disappears because there are no longer two points in time. The server is told at the same moment; `model` is captured here because the callback outlives this view.
                let reporter = model
                new.runsReported = { [weak new] an in
                    runsReported(an)
                    reporter.runStateReported(running: an, seconds: new?.positionSeconds ?? 0)
                }
                new.jumpReported = { target in reporter.jumpReported(target: target) }
                new.tracksReported = { tracks in reporter.tracksSelected(tracks) }
            }

            // **Opaque, not just a ring.**
            //
            // Before, a bare `Loader()` floated above the running picture. VLC applies the resume position only after the first frame, and in that time the start of the film was visible; the loading screen did not cover it because it covered nothing. The iPhone version has always put black underneath.
            //
            // The mode switch belongs here and **not** on `firstImagePresent`: that value means "VLC delivers frames" and is read by the shared tick logic, among other things to align `running` with VLC. Repurposing it as a display switch would also stop the aligner on a hanging switch, which may have caused the twisted pause state.
            if !firstImagePresent || FrameTick.flipsOver, cardsSwitch == nil {
                ZStack {
                    Color.black
                    Loader.far
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }

            // Lies above everything and takes nothing: the recognizer is attached to the window, not to this surface.
            SwipeField(begins: swipeStart, moved: swiped, ends: swipeFinish)
                .allowsHitTesting(false)

            // **Only the ring, no pause icon.** Paused shows the controls, which stay up while stopped; the design has no center icon, since input is on the clickpad. The pause icon also covered the technical badge.
            if firstImagePresent, stalls || switches, cardsSwitch == nil {
                Loader(size: 86, strength: 7)
                    .frame(width: 190, height: 190)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
                    .zIndex(3)
            }

            // While the card is up, the scrim dims the picture as with open controls, and the card lies in front.
            scrim.opacity(controlsPresent || (episodesCardPresent && cardsSwitch == nil) ? 1 : 0)
                .animation(Theme.controlsFade, value: episodesCardPresent)

            cardsLayer

            // **The technical badge.** Information only, not a control: it takes neither focus nor input. **Directly on the film**: above the scrim, below title, buttons and bar, and so below the layers. **It slides with the controls**: open, under the title row; closed, at the top edge. Motion instead of a fade, same curve as the controls; with reduced motion it jumps.
            //
            // **Without `.focusable(false)`.** That sounds like "takes no focus" but makes the badge a focus participant that can never be focused, and because of its frame it covers the whole screen up to all edges. The focus search ran into it and found nothing: with the badge on, one could not get from the bar to the buttons or between buttons (measured in the simulator: with the badge all four directions had no target, without it all four did). It is not focusable anyway, since it contains only text.
            if techBadge {
                TechBadge(plan: plan, values: playValues, area: area, far: true)
                    .padding(.leading, Theme.edgePage)
                    .padding(.top, Theme.edgeTop + PlayerMetric.button + Theme.tileSpacing)
                    .offset(y: controlsPresent ? 0 : -(PlayerMetric.button + Theme.tileSpacing))
                    .animation(Theme.controlsFade, value: controlsPresent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            itemWitness.opacity(controlsPresent ? 1 : 0)
                // No focus target under a layer; otherwise focus drifts sideways out of the layer into the invisible controls.
                .disabled(layerOpen)

            // **Fade out softly, not abruptly**, as on iPhone: removing it from the tree ran hard despite the transition. The pill stays in the tree as long as there is an offer and comes and goes via opacity. The focus search already skips it when invisible (measured while paused: Up from the bar lands on the buttons at the top, with and without the block). **`disabled` on the pill itself** catches the rest: if it still holds focus it takes no click, and `onChange(of: offeringPresent)` releases it. No `.focusable(false)` on the layer: it reaches all edges and would block the focus search like the technical badge did.
            if offering.visible {
                offeringLayer
                    .opacity(pillPresent ? 1 : 0)
                    .allowsHitTesting(pillPresent)
                    .accessibilityHidden(!pillPresent)
                    // Same fade as the controls (`.animation` on `controlsPresent`).
                    .animation(Theme.motion(.easeInOut(duration: 0.2)), value: pillPresent)
                    .transition(.opacity.animation(Theme.motion(.easeInOut(duration: 0.2))))
            }

            // **The three layers.** Fullscreen over the picture; the controls beneath yield (`controlsPresent`), the auto-hider rests, and Back closes the layer, not the player.
            if let openLayer {
                layersView(openLayer)
                    .transition(.opacity)
                    .zIndex(5)
            }

            stateTitle
                .zIndex(6)

            // **What happens in the group, briefly at the top**, so nobody wonders why the film stopped. Under the title row, centered, where nothing needs focus.
            if groupShow, let event = gemeinsam.event {
                TVGroupsEvent(symbol: event.symbol, text: event.text)
                    .padding(.top, Theme.edgeTop + PlayerMetric.button + Theme.tileSpacing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .id(event.id)
                    .zIndex(7)
            }
        }
        .animation(Theme.reveal, value: gemeinsam.event)
        // What went wrong in "Watch together" shows here too; the page beneath is covered.
        .overlay(alignment: .top) {
            if sharedAn, let error = gemeinsam.error {
                HintStrip(text: error) { gemeinsam.error = nil }
                    .padding(.top, Theme.edgeTop)
                    .transition(.opacity)
            }
        }
        .animation(Theme.reveal, value: gemeinsam.error)
        .overlay(alignment: .bottom) {
            if let hint {
                Text(verbatim: hint)
                    // `.callout` is Apple's size, not part of our scale. Body text, so `Theme.body`.
                    .font(Theme.body)
                    .foregroundStyle(Theme.font)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, Theme.edgeTop)
                    .allowsHitTesting(false)
                    // No `.focusable(false)`: same as the technical badge, it blocks the focus search over the surface, and the bar lies right above. It shows for seconds only and is not focusable, so VoiceOver would never read it without the explicit label.
                    .accessibilityAddTraits(.updatesFrequently)
                    .transition(.opacity)
            }
        }
        .animation(Theme.reveal, value: hint)
        // **Spoken, not just shown.** Messages such as "Intro skipped" and "No subtitles" appeared and vanished without VoiceOver noticing: the message is not focusable, so nobody navigates to it.
        .onChange(of: hint) { _, new in
            guard let new else { return }
            AccessibilityNotification.Announcement(new).post()
        }
        .animation(Theme.reveal, value: techBadge)
        .task(id: techBadge) {
            guard techBadge else { return }
            while !Task.isCancelled {
                // The rate is derived from the difference to the last time; see `PlayValues`.
                playValues = PlayValues(area?.statistics, spot: area?.positionSeconds ?? 0,
                                        running: area?.isPlaying ?? false, before: playValues)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .ignoresSafeArea()
        // **Focus does not arrive by itself.**
        //
        // As an overlay, the player is at first decoration to the focus engine: nothing in it is set, and focus stays where it was. The result was twofold: no direction key arrived, so the controls never appeared, and `onExitCommand` hung on no focused view and fell through to the system, which treated Menu as "leave app". In a navigation stack the player was handed focus; that was borrowed, not built.
        .focusSection()
        // Initially the rest layer: the bar exists only from the first frame, and assigning to something unfocusable does nothing.
        .onAppear { focus = .idle }
        // **Focus moves with the controls** instead of vanishing with them. While a sheet opens the block applies: the sheet takes focus, and we would be taking it away.
        //
        // **And re-applied on appearance.** The assignment falls into the pass in which the controls first become focusable, and SwiftUI sometimes drops it. Measured: focus stayed on the rest layer, which became unfocusable in the same step, and sat there stuck: up, left and right found no target and nothing responded. As with the overlay (`cardPresent`), it is set again until it sticks.
        .onChange(of: controlsPresent) { _, present in
            guard !layerOpen else { return }
            guard present else { focus = cardPresent ? .offering : .idle; return }
            let target = targetShow
            targetShow = .bar
            focus = target
            focusCatchUp {
                for wait in [80, 250, 600] {
                    try? await Task.sleep(for: .milliseconds(wait))
                    guard !Task.isCancelled, controlsPresent, !layerOpen else { return }
                    guard focus == nil || focus == .idle else { return }
                    focus = target
                    AppLog.writeOut("[Fokus] nachgesetzt auf \(target) nach \(wait) ms")
                }
            }
        }
        // **A hidden pill does not hold focus.** It stays in the tree for the soft fade-out; if focus was on it, it stayed there on a button nobody sees (measured while paused: still `.offering` after hiding). Without controls `onChange(of: cardPresent)` below handles it; with them open, focus goes to the bar right below the pill.
        .onChange(of: offeringPresent) { _, present in
            guard !present, controlsPresent, !layerOpen, focus == .offering else { return }
            focus = .bar
        }
        // **The overlay takes focus and hands it back to the surface.**
        //
        // Set again a beat later: the first assignment falls into the same pass in which the button is first attached, and SwiftUI drops it. Focus returns to the rest layer, not the bar, so the next click pauses instead of opening the controls.
        .onChange(of: episodesCardPresent) { _, present in
            guard cardsSwitch == nil else { return }
            AppLog.writeOut(present ? "[Karte] erscheint bei \(Int(position)) s von \(Int(duration)) s"
                                 : "[Karte] geht (Menü oder Steuerung)")
        }
        .onChange(of: cardPresent) { _, present in
            AppLog.writeOut("[Angebot] \(present ? "ein" : "aus") \(layer.display)")
            if present {
                focus = .offering
                focusCatchUp {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled, cardPresent else { return }
                    focus = .offering
                    AppLog.writeOut("[Angebot] Fokus \(String(describing: focus))")
                }
            } else if !controlsPresent, !layerOpen {
                focus = .idle
                focusCatchUp {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled, idlePresent else { return }
                    if focus == nil || focus == .offering { focus = .idle }
                    AppLog.writeOut("[Angebot] Fokus zurück \(String(describing: focus))")
                }
            }
        }
        // **Reclaim focus after pausing.**
        //
        // No click, no direction, nothing. This is not a play/pause bug but lost focus: without a focused element tvOS accepts no input at all, and the player stands as a still frame. Focus does not arrive by itself; it has to be placed.
        .onChange(of: running) { _, _ in
            guard !layerOpen else { return }
            focus = .bar
            // **And once more a beat later.**
            //
            // `wakeControls` does exactly that: it puts focus back on the bar. Without focus tvOS accepts no input and the player stands as a still frame.
            //
            // The assignment above is not enough: SwiftUI clears focus in the same pass and drops it. So it is repeated once everything has settled.
            focusCatchUp {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, !layerOpen else { return }
                focus = .bar
            }
        }
        // The overlay follows the intended controls state: at open it is already "on", and its first hide is not a look inside that should dismiss "Skip recap".
        .onChange(of: controlsVisible, initial: true) { _, opened in
            layer.controls(opened: opened)
            fillSet()
        }
        .onPlayPauseCommand { playbackKey() }
        .onExitCommand {
            // Menu cancels scrubbing first, not playback. Someone who overshot wants to return to their place, not leave the film.
            if seekTarget != nil { markDiscard() }
            // An open layer is closed by Back, not the player.
            else if openLayer != nil { layerClose() }
            // **If the controls are showing, they go first**; only the second press leaves the film. Whoever just woke them wants to keep watching.
            else if controlsPresent {
                controlsVisible = false
                AppLog.writeOut("[Zurück] Steuerung aus")
            }
            // Back closes only the overlay; the film keeps playing.
            else if cardPresent {
                layer.close()
                AppLog.writeOut("[Angebot] Zurück schließt")
            }
            else { leave() }
        }
        // **After a sheet the controls must come back.**
        //
        // A sheet takes focus. If it closes and nobody takes focus back, it sits nowhere, and then no motion command arrives to wake the controls. The bar was gone and stayed gone.
        .animation(Theme.controlsFade, value: controlsPresent)
        .animation(Theme.motion(.easeInOut(duration: 0.22)), value: running)
        .animation(Theme.motion(.easeInOut(duration: 0.22)), value: stalls)
        // **Leaving the app must stop the sound.**
        //
        // `onDisappear` does not fire: the view does not disappear when tvOS backgrounds the app, it stays and VLC keeps playing, so the sound continued on the Apple TV home screen.
        //
        // Only `.background`, not `.inactive`: that also occurs when the system briefly overlays something, and pausing then would be intrusive.
        // Coming back does **not** resume by itself. Whoever returns presses play; that is a decision, not a side effect.
        .onChange(of: phase) { _, new in
            // **In a group, leaving means leaving.** Pausing alone would let the others keep playing while this player stands, out of step on return. The badge and the strip lead back in.
            if new == .background, inGroup { leave(); return }
            guard new == .background, let area, area.isPlaying else { return }
            // **Report first, then pause.** VLC's confirmation may only arrive after tvOS has frozen the app, leaving the server with "playing" at an old position for up to ten seconds.
            if startReported, !switches {
                model.backgroundReport(item: item, plan: plan, seconds: position, paused: true)
            }
            area.pause()
            runsSet(false)
            showItem()
        }
        .onChange(of: sleepMinutes) { _, new in sleepTimeSet(new) }
        .animation(Theme.motion(.easeInOut(duration: 0.2)), value: openLayer)
        .onAppear {
            model.playerOpen = true
            model.remoteCommand = execute
            if gemeinsam.belongsGroup(item.id) {
                switchgear.gemeinsam = true
                sharedAn = true
                bridgeCatchUp()
                gemeinsam.plugIn(bridge)
            }
            // **Before the first frame, not after.** The server already knows the frame rate, so the TV can switch while the stream is being set up rather than afterwards. Whatever the server does not say, the tick fills in later from VLC's tracks.
            FrameTick.adapt(loud: plan.source.flatMap(FileDetails.videoTrack))
            clickRing.observe(begins: holdBegins, ends: holdEnds)
        }
        .onDisappear {
            HandoffStage.shared.playerDistance(item.id)
            clickRing.resolve()
            sampleTask?.cancel()
            focusPostPull?.cancel()
            // The output goes back to the UI, which is drawn for 60 Hz.
            FrameTick.resolve()
            sleepTask?.cancel()
            seekTask?.cancel()
            model.remoteCommand = nil
            // Closing means leaving.
            if switchgear.gemeinsam {
                switchgear.gemeinsam = false
                gemeinsam.detach()
            }
            // Before `stop()`: `position` is the view's state, but whoever swaps the lines should not trip over VLC's zero.
            model.doneWatch(position: position, duration: duration)
            area?.stop()
            hub.handIn()
            model.playerOpen = false
            // Over the switch: if one is running it is aborted, and if the new episode's start is under way, the stop follows after it.
            let ongoing = (item: item, plan: plan, spot: position)
            episodesSwitch.close {
                await model.reportStopped(item: ongoing.item, plan: ongoing.plan,
                                          seconds: ongoing.spot)
            }
        }
        .task { await observe() }
        .task { await lookUp(for: item) }
        // Check once per title whether the server has preview images.
        .task(id: item.id) { await trickplay.load(model: model, item: item, plan: plan) }
        // **Per version, not per title**: a director's cut has different chapters. Until they arrive, the bar shows no foreign ones.
        .task(id: [item.id, plan.mediaSourceID]) {
            chapter = []   // also when the version changes without a new title
            let found = await model.chapter(for: item.id, source: plan.mediaSourceID)
            guard !Task.isCancelled else { return }
            chapter = found
        }
        // The episode image is ready for a possible handover; the donor's card needs it in the first frame (``Uebergabeabgang``).
        .task(id: item.id) { await HandoffExit.preload(item, model: model) }
        // The episode layer should already stand when opened.
        .task(id: item.id) {
            if hasEpisodes { await EpisodesLayer.preload(model: model, item: item) }
        }
        .onChange(of: duration) { _, _ in hubReport() }
        .task(id: fadeOutMark) {
            // Take nothing away while paused: whoever paused is not looking at the picture but wants to know where they are.
            guard controlsVisible, running else { return }
            // 8 s instead of 4: the bar disappeared noticeably faster than in other Apple TV clients (Swiftfin uses 10 s).
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, !layerOpen else { return }
            // A marker nobody sees is no longer intended. If it stayed, the bar would show its old time instead of the position the next time it appears; see `markDiscard`.
            markDiscard()
            controlsVisible = false
        }

        // **The auto-hider must restart when VLC reports the state.**
        //
        // The rocker only commands; `running` is set by the callback 17-25 ms later (see `setzen`). But `show` starts the task immediately, and it still reads the state from *before* the press and exits at `guard running` on "resume". After that nothing stirs: the marker only changes in `show`, and the controls stayed up.
        //
        // iOS had this line from the start (`iOS/PlayerScreen.swift`), tvOS never did; it was missed when deriving. There `hubAdopt()` sits next to it; tvOS does not need that, because `haltOrNext` reads from `switchgear` and not from the captured view.
        //
        // Pause also stops the card's fill at once.
        .onChange(of: running) { _, _ in fadeOutMark += 1; fillSet() }
    }

    // MARK: - Scrim

    /// **Flat, no gradients**: rgba(11,11,13,.42) as in the design and on iPhone. Without dimming, white text over bright scenes would be unreadable.
    /// **Pure black**: `Theme.reason` lifted dark scenes in the TV's HDR mode; see `Ebenengrund`.
    private var scrim: some View {
        // **The surface carries only the middle, the edges carry bands.**
        //
        // This used to be a flat 0.42 over the whole picture. That bought legibility at two edges by darkening the **middle of the film** whenever the controls show, which is more noticeable on a TV than on a phone. Same solution as on iPhone: a light surface for the center symbol, plus a gradient band at top and bottom for title and time row.
        //
        // The bands are double the iPhone sizes (400 instead of 200, 520 instead of 260), the same rule as for type.
        //
        // As an `overlay` on the surface they do not count towards its size; on iPhone exactly that blew up the player when they sat in a stack.
        Color.black.opacity(0.30)
            .overlay(alignment: .top) {
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                       .init(color: .black.opacity(0.55), location: 0.45),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 400)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black.opacity(0.42), location: 0.55),
                                       .init(color: .black.opacity(0.62), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 520)
            }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: - Header and bar

    /// For an episode the series, otherwise the title itself.
    private var titleLine: String {
        if item.type == "Episode", let series = item.seriesName, !series.isEmpty { return series }
        return item.name
    }

    /// "Season 1 · Episode 3"; for a movie year, runtime and genre.
    private var metaText: String? {
        if item.type == "Episode" {
            if let season = item.parentIndexNumber, let episode = item.indexNumber {
                return String(localized: "Staffel \(season) · Folge \(episode)")
            }
            return item.contextLine
        }
        let row = item.secondaryLine
        return row.isEmpty ? nil : row
    }

    /// Only episodes of a series have an episode list.
    private var hasEpisodes: Bool { item.type == "Episode" && item.seriesId != nil }

    /// While scrubbing a marker is set; then only the bar counts.
    private var seeks: Bool { seekTarget != nil }

    private var iconCount: Int { hasEpisodes ? 3 : 2 }

    /// **Title top left, bar at the bottom, nothing between.** No pause button or skip buttons in the middle: input is on the clickpad. No close button: the Back key does that.
    private var itemWitness: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Spacer(minLength: 0)

            TimeBar(position: position, duration: duration, mark: seekTarget,
                       back: Double(model.backSeconds),
                       forward: Double(model.forwardSeconds),
                       jump: jump, wake: showItem, click: click,
                       running: running,
                       preview: { trickplay.image(at: $0, model: model) },
                       // Both bounds, not just the start: where the intro starts does not say where it ends.
                       sectionLimits: sections.flatMap { [$0.from, $0.until] },
                       chapter: chapter)
                .focused($focus, equals: .bar)
                // The bar is a drawing: the position exists only as bar length. Without a value it would be silent.
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Abspielstelle")
                .accessibilityValue(Text(verbatim: spokenState))
        }
        .padding(.horizontal, Theme.edgePage)
        .padding(.vertical, Theme.edgeTop)
    }

    /// For VoiceOver: position, length and, if there is one, the chapter.
    private var spokenState: String {
        let spot = String(localized: "\(PlayTime.text(position)) von \(PlayTime.text(duration))")
        guard let name = ChapterBar.chapter(at: position, in: chapter)?.name, !name.isEmpty
        else { return spot }
        return String(localized: "\(spot), \(name)")
    }

    /// Space on the left for the title with the meta line below, the icons on the right. `stateTitle` shows the title itself. While scrubbing, the icons give way to the preview.
    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: PlayerMetric.titleSpacing) {
                Text(verbatim: titleLine)
                    .font(PlayerMetric.title)
                    .tracking(Theme.lockTitle)
                    .lineLimit(1)
                    .hidden()
                    .accessibilityHidden(true)
                HStack(spacing: 16) {
                    // **In a group, the group shows here**, where season and episode otherwise stand. It is state, so accent color.
                    if groupShow, let group = gemeinsam.group {
                        TVGroupsRow(name: group.name, withWhom: gemeinsam.withWhom)
                    } else if let metaText { Text(verbatim: metaText) }
                    if !plan.isLossless {
                        Label(plan.method.rawValue, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    }
                }
                .font(PlayerMetric.meta)
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            iconRail
                .opacity(seeks ? 0 : 1)
                .disabled(seeks)
        }
        .focusSection()
    }

    /// Audio & subtitles, episodes (episodes only), settings.
    private var iconRail: some View {
        HStack(spacing: PlayerMetric.buttonSpacing) {
            IconButton(symbol: "captions.bubble", label: "Audio & Untertitel") {
                unfoldLayer(.tracks)
            }
            .focused($focus, equals: .tracks)
            if hasEpisodes {
                IconButton(symbol: "rectangle.stack", label: "Folgen") {
                    unfoldLayer(.episodes)
                }
                .focused($focus, equals: .episodes)
            }
            IconButton(symbol: "slider.horizontal.3", label: "Einstellungen") {
                unfoldLayer(.settings)
            }
            .focused($focus, equals: .settings)
        }
    }

    /// **The title top left, one layer above everything.** With the episode layer open it stays right here; if it lived in the header it would fade out with the controls and back in within the layer, flickering.
    private var stateTitle: some View {
        let present = controlsPresent || openLayer == .episodes
        return HStack(alignment: .top, spacing: 24) {
            Text(verbatim: titleLine)
                .font(PlayerMetric.title)
                .tracking(Theme.lockTitle)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
            Spacer(minLength: 0)
            // Same space as the header icons, so the title gets the same width here.
            Color.clear.frame(width: PlayerMetric.iconRail(count: iconCount), height: 1)
        }
        .padding(.horizontal, Theme.edgePage)
        .padding(.top, Theme.edgeTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .opacity(present ? 1 : 0)
        .animation(Theme.motion(.easeInOut(duration: 0.2)), value: present)
    }

    // MARK: - Layers

    private func unfoldLayer(_ target: PlayerLayer) {
        AppLog.writeOut("[Ebene] auf \(target)")
        openLayer = target
    }

    /// Back to the button that opened the layer; a layer is not a change of place. The controls return and the auto-hider restarts.
    private func layerClose() {
        guard let was = openLayer else { return }
        AppLog.writeOut("[Ebene] zu \(was)")
        openLayer = nil
        showItem()
        let target: FocusTarget = switch was {
        case .tracks: .tracks
        case .episodes: hasEpisodes ? .episodes : .bar
        case .settings: .settings
        }
        focus = target
        focusCatchUp {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, openLayer == nil, controlsPresent else { return }
            focus = target
        }
    }

    /// Cancels the previous deferred placement and remembers the new one; see `focusPostPull`.
    private func focusCatchUp(_ labor: @escaping @MainActor () async -> Void) {
        focusPostPull?.cancel()
        focusPostPull = Task { @MainActor in await labor() }
    }

    @ViewBuilder
    private func layersView(_ which: PlayerLayer) -> some View {
        switch which {
        case .tracks:
            TracksLayer(area: area)
        case .settings:
            SettingLayer(area: area, sleepMinutes: $sleepMinutes, quality: qualitySelection,
                              gemeinsam: groupShow ? gemeinsam : nil,
                              groupLeave: { leave() })
        case .episodes:
            EpisodesLayer(model: model, item: item, title: titleLine) { episode in
                layerClose()
                // Choosing the current episode means: keep watching.
                guard episode.id != item.id else { return }
                // In a group nobody switches alone: the choice sets the queue and everyone loads the episode (as on iOS).
                if inGroup { gemeinsam.bitTitle(episode.id); return }
                changeInto(episode, since: episode.resumeFrom ?? 0)
            }
            // **Not on every tick**; see `EpisodesLayer.==`.
            .equatable()
        }
    }

    // MARK: - Skip

    /// **The offer button**, right above the bar, in the same place whether the controls are open or closed. During the countdown the pill fills from the left. A click executes; Back closes only the overlay.
    private var offeringLayer: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                offeringPill
                    .disabled(!pillPresent)
                    .focused($focus, equals: .offering)
                    // Without controls a direction key fetches them, otherwise focus would be trapped in the pill. A "Next episode" card is thereby cancelled (`OfferingLayer.controls`), a skip button stays. With the controls open, focus moves as usual.
                    .onMoveCommand { _ in
                        guard !controlsPresent else { return }
                        AppLog.writeOut("[Angebot] Richtung holt die Steuerung")
                        wakeControls()
                    }
                    .accessibilityValue(countdownShare.map {
                        _ in Text("Startet in \(layer.countdownRest) Sekunden")
                    } ?? Text(verbatim: ""))
            }
        }
        .padding(.horizontal, Theme.edgePage)
        // Same dimensions as the controls' bar, so the pill never overlaps it, open or not.
        .padding(.bottom, Theme.edgeTop + PlayerMetric.bar + PlayerMetric.overBar)
    }

    private var offeringPill: some View {
        Button(action: offeringRun) {
            // **White pill with the skip icon**, for both offers, as in the design and on iPhone. The label is built as a `String` in the package; `verbatim` prevents a second lookup.
            HStack(spacing: 14) {
                Image(systemName: "forward.end.fill")
                Text(verbatim: offering.label)
            }
        }
        .buttonStyle(PillsStyle(fillContent: nil))
        .accessibilityLabel(Text(verbatim: offering.label))
    }

    private var countdownShare: Double? {
        if case let .card(share) = layer.display { return share }
        return nil
    }

    /// Which button applies. Same rule as on iOS; it lives in the package so the four platforms do not drift apart.
    private var offering: ButtonOffering {
        // No button during the switch: a second press meant two switches.
        guard !switches else { return .nobody }
        return SectionLogic.offering(position: position, duration: duration,
                                sections: sections,
                                hasNextEpisode: next != nil)
    }

    private func offeringRun() {
        layer.pressed()
        AppLog.writeOut("[Angebot] gedrückt \(offering)")
        switch offering {
        case .nobody:
            break
        case let .skip(to, _):
            jumpRun(to)
        case .nextEpisode:
            if let episode = next { changeInto(episode) }
        }
    }

    // MARK: - Commands

    /// **Release the output before the view goes away.**
    ///
    /// The TV needs a few seconds for the mode switch, during which it is black. If the release sat in `onDisappear`, the black fell onto the already returned UI: you were back in the overview and then the picture vanished. Here it falls into the transition, where the screen is dark anyway.
    ///
    /// `resolve` can be called repeatedly; the safeguard in `onDisappear` remains for paths that do not pass here.
    private func leave() {
        FrameTick.resolve()
        close()
    }

    /// **Playback moves to another device** (``Uebergabeabgang``). The position goes to the server at once (the other side waits for it), the controls go, and the picture stops at 0.12 s and leaves as a card.
    private func handIn(an target: String, area: VLCPlayerView) {
        guard !handoverRuns else { return }
        handoverRuns = true
        let spot = position
        Task { await model.reportStopped(item: item, plan: plan, seconds: spot) }
        var without = Transaction()
        without.disablesAnimations = true
        withTransaction(without) { controlsVisible = false }
        HandoffExit.start(area: area, target: target, title: item, model: model,
                                halt: { area.pause() },
                                done: { leave() })
    }

    /// Focus back to the bar and show the controls.
    private func wakeControls() {
        focus = .bar
        showItem()
    }

    private func showItem() {
        controlsVisible = true
        fadeOutMark += 1
    }

    /// Pause or resume: **one path for everything**.
    ///
    /// Two pitfalls are explicitly switched off here:
    ///
    /// 1. **What the system sends decides nothing.** On Apple TV the Play/Pause press arrives via the playback center, and tvOS chooses itself between "play", "pause" and "toggle". It always chose "pause": the first press paused, every further one had nothing to do. So **all three** commands lead here, and the toggle happens here.
    ///
    /// 2. **The state is not read from the view.** `area` is a class and tells the truth, even from a callback that could be weeks old. `running` in a captured view copy only says what applied at registration.
    private func haltOrNext(_ source: String = "Klick") {
        // **Follow our own state, not VLC's**; see `Switchgear.running`. Read from the class, not from `@State`, since this is also called from retained callbacks.
        //
        // And without setting the state at once: the rocker only says "the other one", so it may only command. VLC reports how it turned out; see `runsReported`.
        //
        // **Toggling is against the intended state, not VLC's report.** The report comes after the command; whoever pressed twice quickly toggled against the old state, so the second press commanded the same again and was lost.
        //
        // **In a group this is a request.** The button flips only when the command comes back from the server, then for everyone at once.
        if inGroup {
            AppLog.writeOut("[Taste] \(source): Bitte an die Gruppe")
            markDiscard(resume: false)
            gemeinsam.bitToggle(runningCurrently: switchgear.running)
            showItem()
            return
        }
        AppLog.writeOut("[Taste] \(source): \(switchgear.wanted ? "anhalten" : "abspielen")")
        setDown(running: !switchgear.wanted, immediateShow: false)
    }

    /// **The remote's Play/Pause key.** It arrives twice: here and via the playback center (`fromHub`). This path wins; the other is discarded if it falls close to it.
    private func playbackKey() {
        switchgear.lastKey = Date()
        haltOrNext("Wiedergabetaste")
    }

    /// **Playback center commands, with a short wait.**
    ///
    /// A 0.4 s window used to block every second command to catch the doubly delivered key press. That also swallowed genuine quick presses. And if the center came **first**, tvOS chose there between "play" and "pause" according to the Control Center display; if that still showed the old state it commanded the same again, and the block then discarded the correct press.
    ///
    /// Now the center waits 150 ms and steps back if the key itself arrived within 300 ms. Without a key (Control Center, iPhone as remote) it passes through unchanged afterwards.
    private func fromHub(_ name: String, _ perform: @escaping () -> Void) {
        let an = Date()
        let mediaWork = switchgear
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            let spacing = abs(mediaWork.lastKey.timeIntervalSince(an))
            guard spacing > 0.3 else {
                AppLog.writeOut("[Taste] Zentrale \(name) verworfen, Taste \(Int(spacing * 1000)) ms daneben")
                return
            }
            AppLog.writeOut("[Taste] Zentrale \(name)")
            perform()
        }
    }

    /// **A command that would change nothing is a toggle.**
    ///
    /// Every press of Play/Pause arrives by **one** path, sometimes as the key, sometimes via the center. Via the center tvOS chooses between "play" and "pause" itself, based on the last state it was told. That lags briefly after a change: after "play" by key, "play" came via the center half a second later; the film was already running and the press fizzled. Whoever presses wants to change the state, so when the center commands the one that already holds, it toggles.
    private func hubWill(runningCount should: Bool) {
        if should == switchgear.wanted {
            AppLog.writeOut("[Taste] Zentrale veraltet (\(should ? "abspielen" : "anhalten")), schalte um")
            haltOrNext("Zentrale")
        } else {
            setDown(running: should)
        }
    }

    /// Both halves of the run state at once: the view draws from `@State`, the callbacks read from the class.
    private func runsSet(_ new: Bool) {
        running = new
        switchgear.running = new
        switchgear.wanted = new
    }

    /// **VLC's report.** Shortly after a command it is that command's echo or an older one's; only afterwards does it update the intended state, because then it is something VLC did by itself (end, interruption).
    private func runsReported(_ new: Bool) {
        running = new
        switchgear.running = new
        if Date().timeIntervalSince(switchgear.recent) > 1 { switchgear.wanted = new }
    }

    /// Pause or resume, **absolute**, not toggling.
    ///
    /// `play`, `halt` and `toggle` used to all become the same toggle. While both sides hold the same state, that goes unnoticed. When they diverge, it is why it can no longer be straightened out: the phone sends "pause", we switch to play, and the more you press the more twisted it gets.
    ///
    /// An explicit command therefore sets a state; only the rocker on the remote toggles.
    ///
    /// `immediateShow` separates command from display: an explicit "play" or "pause" from outside says what should hold and may set the state. The rocker only says "the other one", so there the display waits for VLC's report.
    private func setDown(running should: Bool, immediateShow: Bool = true) {
        guard let area else { return }
        // In a group an explicit play/pause is a request, and only if it would change something.
        if inGroup {
            markDiscard(resume: false)
            if should != switchgear.running {
                gemeinsam.bitToggle(runningCurrently: switchgear.running)
            }
            showItem()
            return
        }
        // In the Schaltwerk, not in the state: otherwise an old callback reads an old value.
        switchgear.recent = Date()
        switchgear.wanted = should
        // Pause/resume means "here", not "there": the marker is discarded, not confirmed. Confirming stays with the middle button.
        markDiscard(resume: false)

        if should { resume() } else { area.pause() }
        if immediateShow { runsSet(should) }
        hub.stateCatchUp(position: position, running: should, tempo: tempo)
        showItem()
    }

    /// Resume at the viewer's request, a bit earlier after a long pause (``Pausenruecksprung``, as on iPhone). The display takes the target at the same moment. Not in a group (`setzen` does not get this far there) and not at the end of scrubbing, which calls `resume()` without it.
    private func resume() {
        guard let target = area?.resume(jumpBack: !inGroup) else { return }
        jumped(on: target)
    }

    /// Whether VLC still delivers what it should.
    ///
    /// Two signs, because there are two kinds of stall. **The time stands still**: data is missing, after a seek or a network dropout. **There is no video output**: audio keeps playing and only the picture is frozen; this is how VLC returns from the background when tvOS has taken away its access to the picture.
    ///
    /// Only after just under a second: every seek stalls briefly, and a spinner flashing on every key press is worse than none.
    private func checkStall(_ area: VLCPlayerView) {
        guard running, firstImagePresent else {
            stillSince = nil
            stalls = false
            lastVLCTime = area.positionSeconds
            return
        }

        let now = area.positionSeconds
        if abs(now - lastVLCTime) < 0.05 {
            stillSince = stillSince ?? Date()
        } else {
            stillSince = nil
        }
        lastVLCTime = now

        // **Only the clock, not `showsImage`.**
        //
        // `hasVideoOut` says whether an output module is attached, not whether frames arrive. Used as a second sign, a module that reports nothing for other reasons would have left the spinner up permanently, and a spinner that is always there says nothing. The stalled clock is unambiguous: with no data, time does not advance.
        let timeStands = stillSince.map { Date().timeIntervalSince($0) > 0.9 } ?? false
        let new = timeStands || restoring
        if new != stalls {
            withAnimation(Theme.motion(.easeInOut(duration: 0.22))) { stalls = new }
        }
    }

    private func hubAdopt() {
        hub.adopt(.init(
            // **Explicit commands set a state, the rocker toggles.**
            //
            // Before, all three did the same. That was right against the problem of the time: callbacks read a frozen state, so none of them could ask. Now the state lives in the `Switchgear` and is always current by reference, so asking is allowed again.
            //
            // And necessary: toggling commands make a diverged state incurable. Whoever presses "pause" on the phone and gets playback cannot fix it with any number of attempts.
            play:   { fromHub("abspielen") { hubWill(runningCount: true) } },
            halt:    { fromHub("anhalten") { hubWill(runningCount: false) } },
            toggle:  { fromHub("umschalten") { haltOrNext("Zentrale") } },
            jumpOn: { target in hubJump(target) },
            forward:         { jump(Double(model.forwardSeconds)) },
            back:     { jump(-Double(model.backSeconds)) },
            // No next episode in a group; see `lookUp`.
            next:    inGroup ? nil : next.map { episode in { changeInto(episode) } }))
        hubReport()
    }

    /// A seek from the playback center; in a group a request. Reads `switchgear` because the callback is retained.
    private func hubJump(_ target: Double) {
        if inGroup { gemeinsam.bitJump(on: target) }
        else { area?.seek(toSeconds: target) }
        jumped(on: target)
    }

    private func hubReport() {
        hub.report(item: item, position: position, duration: duration, tempo: tempo,
                        running: running,
                        jumpDistance: (model.backSeconds, model.forwardSeconds),
                        imageUrl: model.lockImageURL(for: item))
    }

    /// Seeking: collect, accelerate, jump **once**.
    ///
    /// Four rules; the third is where it failed twice.
    ///
    /// 1. **The first press with hidden controls only shows them.** On the phone you tap a visible button; here you press a direction blind, and that must not seek at once.
    ///
    /// 2. **A single press seeks immediately**: ten back, thirty forward, as on the phone. Before, even a single press first collected a marker; you pressed and nothing happened until you confirmed.
    ///
    /// 3. **Fast tapping still collects.** VLC rebuilds the stream on every seek; one seek per press made the player audibly rush through the file. So continued tapping only moves the marker, and the seek happens once when tapping rests. How fast that is exists nowhere as a number; it is in the times below the bar.
    ///
    /// 4. **Swipe beats step.** A swipe across the surface produces the same step commands as a press on the ring. During and shortly after a swipe the step is therefore ignored, or every swipe would seek twice.
    private func jump(_ seconds: Double) {
        guard duration > 0, !probing else { return }
        guard controlsPresent else { showItem(); return }
        guard !swipes, Date().timeIntervalSince(swipeEnd) > 0.35 else { return }

        let sinceLast = Date().timeIntervalSince(lastStep)
        lastStep = Date()
        showItem()

        let target = min(max((seekTarget ?? position) + seconds, 0), duration)

        // A grabbed marker waits for the middle button. The ring then only moves it; it must not confirm it behind the back of someone still searching.
        if markSwipe {
            seekTarget = target
            showItem()
            return
        }

        seekTask?.cancel()
        if seekTarget == nil, sinceLast > 0.45 {
            jumpRun(target)
            return
        }

        seekTarget = target
        seekTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let spot = seekTarget else { return }
            jumpRun(spot)
        }
    }

    // MARK: - Holding

    /// **Holding left/right seeks in steps**, as in the system player.
    ///
    /// Holding used to collect only single jumps. Now, after half a second the film pauses and the marker runs: 10, then 30, then 90 seconds of film per second, a step faster every two seconds. Releasing jumps there and lets it play; Menu cancels.
    ///
    /// **The marker, not the playback rate.** Apple plays faster when fast-forwarding; VLC cannot do that backwards at all, and with 4K HEVC in direct play forwards only stutteringly. This way both directions behave the same and the decoder is left alone.
    private func holdBegins(_ bearing: Int) {
        guard duration > 0, !layerOpen else { return }
        sampleTask?.cancel()
        sampleTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            probing = true
            seekTask?.cancel()
            seekTask = nil
            rollOut?.cancel()
            // In a group scrubbing does not pause: that would be a pause bypassing the group. The seek happens on release, as a request.
            if !ranBeforeScrubbing, !inGroup, switchgear.running, let area {
                area.pause()
                runsSet(false)
                ranBeforeScrubbing = true
            }
            markSwipe = true
            if seekTarget == nil { seekTargetSet(leap?.target ?? position) }
            let beginning = Date()
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(beginning)
                let tempo: Double = t < 2 ? 10 : (t < 4 ? 30 : 90)
                seekTargetSet((seekTarget ?? position) + Double(bearing) * tempo * 0.1)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func holdEnds() {
        sampleTask?.cancel()
        sampleTask = nil
        guard probing else { return }
        probing = false
        if let target = seekTarget { jumpRun(target) }
    }

    // MARK: - Swiping

    /// A finger on the surface sets a marker and the middle button confirms it, as the system player and Infuse do.
    private func swipeStart() {
        guard duration > 0, !layerOpen else { return }
        guard focus == .bar || focus == .idle else { return }
        // **Note before `show()`.** Afterwards `controlsPresent` is true and "was it already there?" can no longer be answered.
        swipeOnlyOpened = !controlsPresent
        swipes = true
        showItem()
    }

    /// **Dragging slowly means hitting a spot, swiping fast means arriving.**
    ///
    /// A fixed scale suits neither: map the whole file onto the surface and the smallest wobble moves half a minute; map finely and a two-hour film needs a dozen swipes. The finger's speed decides, weighted quadratically so a steady hand keeps the fine step.
    private func swiped(distance: CGFloat, tempo: CGFloat) {
        guard swipes, duration > 0 else { return }
        guard controlsPresent else { showItem(); return }
        // This finger fetched the controls. It may keep them up but not seek; the next swipe is for that.
        guard !swipeOnlyOpened else { showItem(); return }

        seekTask?.cancel()
        seekTask = nil
        rollOut?.cancel()
        // **Scrubbing pauses, as in the system player.** Before, the film kept playing while the bar was somewhere else entirely: picture and sound said one thing, the marker another (Apple's player and Swiftfin both pause). Not in a group; see `holdBegins`.
        if !markSwipe, !inGroup, switchgear.running, let area {
            area.pause()
            runsSet(false)
            ranBeforeScrubbing = true
        }
        markSwipe = true
        markPush(distance: distance, tempo: tempo)
    }

    /// Move the marker by a finger distance. The finger's speed decides, weighted quadratically (see `swiped`).
    private func markPush(distance: CGFloat, tempo: CGFloat) {
        let fine = 0.10
        let coarse = max(duration / 1600, fine)
        let share = min(Double(abs(tempo)) / 3000, 1)
        let tick = fine + (coarse - fine) * share * share
        seekTargetSet((seekTarget ?? position) + Double(distance) * tick)
    }

    /// Also when the click has already disarmed swiping: `swipeEnd` holds back the step commands the same swipe triggered.
    private func swipeFinish(tempo: CGFloat) {
        let rolling = swipes && markSwipe && seekTarget != nil && abs(tempo) > 600
        swipes = false
        swipeEnd = Date()
        swipeOnlyOpened = false
        guard rolling else { return }
        // **After a fast swipe the marker coasts and slows**, as in Apple's player and Swiftfin (x0.78 every 30 ms there). Without it the marker stopped dead under the finger and felt harsh.
        rollOut?.cancel()
        rollOut = Task {
            var v = tempo
            while !Task.isCancelled, abs(v) > 60, seekTarget != nil {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled, seekTarget != nil else { return }
                markPush(distance: v * 0.03, tempo: v)
                v *= 0.78
            }
        }
    }

    /// The middle button.
    ///
    /// **Two meanings, as in the system player.** If a marker is set, it is confirmed and only then does the seek happen. If none is set, the click pauses or resumes.
    ///
    /// Before, the player seeked by itself once tapping rested for 350 ms. It then walked through the episode in steps instead of staying at one spot until you decided, and because VLC rebuilds the stream on every seek, it audibly stuttered.
    private func click() {
        if let target = seekTarget {
            jumpRun(target)
        } else {
            haltOrNext()
        }
    }

    /// **A marker must not hide the position permanently.**
    ///
    /// The bar shows time and head at the marker while one is set, with the light stretch to the real position between. It was only confirmed or discarded with the middle button or Menu. Whoever rested a thumb on the surface while paused (swipe, marker at the current position) and then resumed with Play/Pause kept it for the rest of the film: time frozen, head at 4 %, the light stretch growing with the film. VLC and `TimeAssumption` were innocent: against a server that closes idle connections after 25 s, `time` kept advancing without gaps after the pause.
    private func markDiscard(resume: Bool = true) {
        seekTask?.cancel()
        seekTask = nil
        rollOut?.cancel()
        rollOut = nil
        seekTarget = nil
        markSwipe = false
        // Discarded means: back to the old position and carry on as before.
        if resume, ranBeforeScrubbing, let area {
            area.resume()
            runsSet(true)
        }
        ranBeforeScrubbing = false
    }

    /// Set the target, display it, keep the controls up; do not seek.
    private func seekTargetSet(_ raw: Double) {
        guard duration > 0 else { return }
        let target = min(max(raw, 0), duration)
        seekTarget = target
        showItem()
    }

    private func jumpRun(_ target: Double) {
        guard let area else { return }

        let before = leap?.target ?? position
        // **Record before `jumped` whether the previous seek is still in flight.** `jumped` registers the new seek as open; asked afterwards, one was always open: its own. Every seek then waited for itself until the 3 s cap hit: the time stood at the target at once, the picture kept playing and jumped seconds later.
        let previousTarget = leap?.target
        jumped(on: target)
        seekTarget = nil
        markSwipe = false
        seekTask?.cancel()
        seekTask = nil
        rollOut?.cancel()
        rollOut = nil
        // **In a group this is a request.** The display is already at the target; the seek happens when the command comes from the server, for everyone.
        if inGroup {
            ranBeforeScrubbing = false
            swipes = false
            swipeEnd = Date()
            gemeinsam.bitJump(on: target)
            return
        }
        // Confirmed: seek and, if it was playing before, resume.
        if ranBeforeScrubbing {
            ranBeforeScrubbing = false
            area.resume()
            runsSet(true)
        }

        // **The finger is still on the surface at the click.**
        //
        // On the remote the middle button is the surface itself: clicking presses it down and it slips a little. That aftershock arrived as `changed`, set a new marker, and the bar stayed in scrubbing state with frozen times until the player was left.
        //
        // A new swipe starts again at `began`; until then it is disarmed.
        swipes = false
        swipeEnd = Date()

        // Under one second it is not a seek but a stream rebuild for nothing.
        guard abs(target - before) >= 1 else { return }

        // **Never two seeks on top of each other.**
        //
        // `seek(toSeconds:)` computes the distance from VLC's **own** time. Until the previous seek has landed, that still sits at the old position; the second computed from there and landed too far. VLC then corrected itself: it played, jumped a bit, then played on.
        //
        // **Wait until the previous one has arrived, not sit out a fixed delay.** Measured against VLC's own time, not `sprung`: `jumped` above has already set that to the new target. The cap exists only so a seek that never arrives does not swallow the next.
        if let previousTarget {
            seekTask = Task {
                let cap = Date().addingTimeInterval(3)
                while !Task.isCancelled, Date() < cap,
                      abs(area.positionSeconds - previousTarget) > 2 {
                    try? await Task.sleep(for: .milliseconds(80))
                }
                guard !Task.isCancelled else { return }
                jumped(on: target)
                area.seek(toSeconds: target)
            }
            return
        }

        area.seek(toSeconds: target)
    }

    /// **Every seek:** bar and button stand at the target at once, and the tick hands over to VLC's time as soon as VLC is there.
    private func jumped(on target: Double) {
        var state = PlaybackTick.Snapshot(position: position, duration: duration)
        PlaybackTick.jumped(&state, target: target)
        position = state.position
        leap = state.leap
        // A seek into the outro or to the end: the countdown starts over, as on iPhone.
        layer.jumped()
        if countdownShare != nil { fillClock = FillClock() }
        offeringCatchUp(elapsed: 0)
    }

    /// Align the overlay with the displayed position: with `elapsed: 0` right after a seek, otherwise once per tick.
    @discardableResult
    private func offeringCatchUp(elapsed: Double) -> Bool {
        guard !switches else { return false }
        var new = layer
        let done = new.tick(offering: offering,
                          cardDue: SectionLogic.cardDue(position: position, duration: duration,
                                                                     sections: sections,
                                                                     hasNextEpisode: next != nil,
                                                                     remainingWindow: EpisodeCard.remainingWindow),
                          // Count only while it could be seen, not under the loading screen.
                          running: running && firstImagePresent && !FrameTick.flipsOver,
                          elapsed: elapsed,
                          countdown: SectionLogic.countdown(position: position, duration: duration,
                                                               sections: sections,
                                                               remainingWindow: EpisodeCard.remainingWindow),
                          atEnd: EpisodeEnd.atEnd(position: position, duration: duration) && seekTarget == nil)
        // If the skip button fades out by itself (`buttonDuration`), it should go as softly as it came. The tick runs without animation, so animate the visibility change explicitly here.
        if new.display.visible != layer.display.visible {
            withAnimation(Theme.motion(.smooth(duration: 0.34))) { layer = new }
        } else {
            layer = new
        }
        fillSet()
        return done
    }

    private func fillSet() {
        fillClock.set(share: countdownShare,
                             running: running && firstImagePresent && !FrameTick.flipsOver,
                             length: layer.countdownLength)
    }

    /// Switch to the next episode in the running player instead of jumping back to the overview.
    ///
    /// **The flow lives in the package** (`EpisodeSwitch`), shared with iOS and macOS. This used to lack the latch: a second press started a second switch, leaving two sessions open on the server. Stop and plan ran one after the other instead of side by side, and a failed switch said nothing.
    /// - Parameter ab: start position, from the episode layer the resume position, otherwise the beginning.
    /// Direct play or ceiling, only if played from the server and the account may convert.
    ///
    /// **And not in a group** (as on iOS): the switch reloads the title and reports stop and start bypassing the group.
    private var qualitySelection: QualitySelection? {
        guard model.downloads.file(for: item.id) == nil, model.convertAllowed,
              !groupShow else { return nil }
        return QualitySelection(directPlay: model.alwaysDirectPlay, limit: model.bitratesLimit) { value in
            // The group can join while the layer is open.
            guard !inGroup else { return }
            let before = (model.alwaysDirectPlay, model.bitratesLimit)
            if let value {
                model.alwaysDirectPlay = false
                model.bitratesLimit = value
            } else {
                model.alwaysDirectPlay = true
            }
            guard before != (model.alwaysDirectPlay, model.bitratesLimit) else { return }
            AppLog.writeOut("[Qualität] \(model.alwaysDirectPlay ? "Direct Play" : "\(model.bitratesLimit) Mbit/s") — neu laden bei \(Int(position)) s")
            // A prepared plan for the next episode carries the old choice.
            preparation.forget()
            qualitySwitched = true
            changeInto(item, since: position)
        }
    }

    private func changeInto(_ episode: Item, since: Double = 0, fromCard: Bool = false) {
        guard !switches else { return }
        switches = true
        openLayer = nil
        // From the card: it zooms over the whole picture and covers the switch.
        let zooms = fromCard && !inGroup && episode.id != item.id
        if zooms {
            cardsEpisode = episode
            cardsClock = fillClock
            cardsSwitch = CardsSwitch(episodeID: episode.id)
            AppLog.writeOut("[Karte] Start → \(episode.id)")
            withAnimation(Self.spring(EpisodeCard.zoomOmega)) { cardsZoom = 1 }
            if let beginning = cardsSwitch?.beginning { Task { await cardGuard(beginning) } }
        }
        let swapOff = zooms ? Date().addingTimeInterval(EpisodeCard.swap) : nil
        // **The scrub marker belongs to the old episode.**
        //
        // It shows a position *in this* title; the next episode starts at zero and knows nothing of it. If it stayed, the timeline in the new title kept showing the old time and the button at its spot: the display stood still while the picture played. It used to be cleared only by click, Menu, pause or when the controls hid (`markDiscard`), and hiding rests while paused: whoever paused, swiped, opened the episode list and chose the next episode carried the marker over.
        markDiscard()
        model.doneWatch(position: position, duration: duration)
        let alt = (item: item, plan: plan, spot: position)
        // Already fetched in the last minutes (``EpisodePreparation``)? Then the switch does not wait for the server again.
        let prepared = preparation.take(episode.id)
        switchStart = Date()
        AppLog.writeOut("[Wechsel] Beginn → \(episode.id) · Plan vorbereitet: \(prepared != nil ? "ja" : "nein")")
        Task {
            let result = await episodesSwitch.execute(.init(
                stopNow: { await model.reportStopped(item: alt.item, plan: alt.plan,
                                                     seconds: alt.spot) },
                planOut: {
                    let newPlan: PlaybackPlan?
                    if let prepared { newPlan = prepared }
                    else { newPlan = await model.plan(for: episode.id) }
                    // Swap only once the card covers the picture.
                    if let swapOff, newPlan != nil {
                        let rest = swapOff.timeIntervalSinceNow
                        if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
                    }
                    return newPlan
                },
                apply: { newPlan in episodeApply(episode, newPlan, since: since) },
                start: { newPlan in await model.reportStart(item: episode, plan: newPlan,
                                                           seconds: since) },
                failed: {
                    hintShow(String(localized: "Nächste Folge konnte nicht geladen werden."))
                    // The old episode keeps playing but the server already knows it as finished. The loop registers it again.
                    startReported = false
                }))
            AppLog.writeOut("[Wechsel] \(result) → \(episode.id)")
            switches = false
            guard result == .switched else {
                if cardsSwitch != nil { cardBack() }
                return
            }
            // After the switch focus would otherwise sit nowhere: the episode list is closed and the bar never had it. From the card the controls stay closed, so focus goes to the rest layer.
            if cardsSwitch == nil { wakeControls() } else { focus = .idle }
            await lookUp(for: episode)
        }
    }

    /// The new episode's first frame is up: the preview image fades out, at the earliest from the swap. Same flow as on iPhone.
    private func cardHandOver() async {
        guard let k = cardsSwitch, let imageSince = k.imageSince else { return }
        let wait = EpisodeCard.fadeOff(imageSince: imageSince) - k.since
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        withAnimation(Theme.motion(.easeInOut(duration: EpisodeCard.imageFade))) { cardImage = 0 }
        try? await Task.sleep(for: .seconds(EpisodeCard.imageFade))
        guard cardsSwitch?.beginning == k.beginning else { return }
        AppLog.writeOut("[Karte] Ende nach \(Int(k.since * 1000)) ms")
        cardCleanUp()
    }

    private func cardBack() {
        AppLog.writeOut("[Karte] Wechsel gescheitert, zurück")
        cardCleanUp()
        wakeControls()
    }

    /// **Without a first frame the card yields to the loading screen.** While it is zoomed there is neither control nor loading screen, so no way out; if the frame does not come (``Folgenkarte/weicht``), the ordinary loading screen with close takes over. The switch continues underneath.
    private func cardGuard(_ beginning: Date) async {
        try? await Task.sleep(for: .seconds(EpisodeCard.atMostCovers))
        guard let k = cardsSwitch, k.beginning == beginning,
              EpisodeCard.yields(since: k.since, imageSince: k.imageSince) else { return }
        AppLog.writeOut("[Karte] kein Bild nach \(Int(k.since * 1000)) ms, Ladeschirm übernimmt")
        cardCleanUp()
    }

    private func cardCleanUp() {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            cardsSwitch = nil
            cardsEpisode = nil
            cardsClock = nil
            cardsZoom = 0
            cardImage = 1
        }
    }

    /// The card at the bottom right stays in the tree as long as there is a next episode, so entering and leaving are springs from the current state.
    @ViewBuilder
    private var cardsLayer: some View {
        if let episode = cardsEpisode ?? next, !inGroup {
            TVEpisodesCard(
                episode: episode,
                imageAddress: model.imageURL(for: episode, maxHeight: 1080)
                    ?? model.landscapeImageURL(for: episode, width: 1920),
                present: episodesCardPresent, zoom: cardsZoom,
                detailsPresent: episodesCardPresent && cardsSwitch == nil,
                image: cardImage,
                fillContent: cardsClock ?? fillClock,
                rest: layer.countdownRest,
                focus: $focus,
                onTap: {
                    layer.pressed()
                    AppLog.writeOut("[Karte] geklickt")
                    changeInto(episode, fromCard: true)
                })
            .animation(episodesCardPresent ? Self.spring(EpisodeCard.appearOmega)
                                        .delay(cardsSwitch == nil ? EpisodeCard.appearLag : 0)
                                     : Self.spring(EpisodeCard.distanceOmega),
                       value: episodesCardPresent)
        }
    }

    /// Adopt the new episode: everything that belonged to the old one goes back.
    /// Track choice at open: same inputs as `wendeLanguagesAn`, but before `play`, so VLC starts with the right track.
    private func trackRequest(_ title: Item, _ plan: PlaybackPlan) -> VLCPlayerView.TrackRequest {
        VLCPlayerView.TrackRequest(audio: model.audioLanguage, subtitle: model.subtitleLanguage,
                                 automatic: model.subtitleAutomatic, source: plan.source,
                                 title: TrackMemory.title(for: title))
    }

    private func episodeApply(_ episode: Item, _ newPlan: PlaybackPlan, since: Double = 0) {
        if let cardsSwitch {
            AppLog.writeOut("[Karte] Tausch nach \(Int(cardsSwitch.since * 1000)) ms")
        }
        // **State first, then the stream.**
        //
        // `item` and `plan` are the running title, not the opened one. If they stay, the loop keeps reporting the old episode to the server, the sheet shows its name and the episode list highlights the wrong row.
        //
        // Delay: the same series keeps it, otherwise zero.
        area?.delayForNewTitle(oldTitle: item.id, oldSeries: item.seriesId,
                                            newTitle: episode.id, addedSeries: episode.seriesId)
        item = episode
        plan = newPlan
        // A limit was chosen but the original plays: either the file already fits or the server does not convert. Say so rather than stay silent.
        if qualitySwitched {
            qualitySwitched = false
            if !model.alwaysDirectPlay, newPlan.method == .directPlay {
                hintShow(String(localized: "Läuft in Originalqualität. Der Server wandelt nichts um."))
            }
        }

        // A new title in the same loop: position, tracks, start report, first frame. `startReported: true` because the switch reports the start.
        var state = PlaybackTick.Snapshot(position: position, duration: duration,
                                         running: running, firstImagePresent: firstImagePresent,
                                         tracksSet: tracksSet,
                                         startReported: startReported)
        PlaybackTick.newTitle(&state, startReported: true)
        position = state.position
        leap = state.leap
        tracksSet = state.tracksSet
        startReported = state.startReported
        firstImagePresent = state.firstImagePresent
        // **Starting mid-episode is a seek**, as on iOS. The display stands at the start position at once and holds it until VLC is there; the loop sets the same after its restart.
        if since > 0 {
            position = since
            leap = PlaybackTick.Jump(target: since)
            startPostSwitch = since
        }
        titleSwitch += 1
        // **The clock starts over.**
        //
        // `TimeAssumption` measures everything against this point. If it stayed at the player's opening, the new episode counted as long since set up from the first tick, while VLC still reported the end of the old one. The display took it over, and advancing jumped again at once, from episode three to five.
        sinceStart = Date()
        // **Nothing points at the old episode any more.**
        next = nil
        sections = []
        chapter = []
        layer.newEpisode()
        hubAdopt()

        // **Here too, or the next episode keeps the level from opening.** Whoever changes it during an episode means the next one as well, and `play` reads the value at setup.
        area?.buffer = model.bufferLevel
        area?.trackRequest = trackRequest(episode, newPlan)
        area?.play(url: newPlan.url, offSeconds: since, container: newPlan.container,
                      subtitle: model.subtitleFiles(newPlan),
                      softwareDecoder: newPlan.softwareDecoder)
    }

    /// Next episode and sections for the running title. A result arriving after the next switch is discarded by `EpisodeSwitch`.
    private func lookUp(for title: Item) async {
        // **No next episode in a group.** Otherwise everyone would advance on their own and the group would drift apart.
        await episodesSwitch.lookUp(fetch: { await model.episodePost(title) },
                                         adopt: { next = switchgear.gemeinsam ? nil : $0 })
        // **The new episode has its own sections.** Otherwise it would carry its predecessor's and the button would appear at its positions.
        await episodesSwitch.lookUp(fetch: { await model.sections(for: title.id) },
                                         adopt: { sections = $0 })
        // Only now is it settled whether a "Continue" handle may exist.
        hubAdopt()
    }

    /// A short notice at the bottom of the picture that goes by itself.
    private func hintShow(_ text: String) {
        hint = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if hint == text { hint = nil }
        }
    }

    /// Commands from the Jellyfin dashboard, and later from the iPhone when playback is handed over.
    private func execute(_ command: RemoteCommand) {
        guard let area else { return }
        if inGroup {
            switch command {
            case .pause:      if switchgear.running { gemeinsam.bitToggle(runningCurrently: true) }
            case .proceed:     if !switchgear.running { gemeinsam.bitToggle(runningCurrently: false) }
            case .toggle: gemeinsam.bitToggle(runningCurrently: switchgear.running)
            case .stop:      leave()
            case let .jumpOn(seconds): gemeinsam.bitJump(on: seconds)
            case .forward:        jump(Double(model.forwardSeconds))
            case .back:    jump(-Double(model.backSeconds))
            case .next, .previous: break
            }
            showItem()
            return
        }
        switch command {
        case .pause:      markDiscard(resume: false); area.pause();  runsSet(false); showItem()
        case .proceed:     markDiscard(resume: false); resume(); runsSet(true);  showItem()
        case .toggle: haltOrNext("Fernbefehl")
        // **Another device takes over** (notice came shortly before): the picture leaves as a card. Otherwise (dashboard, other app) as usual.
        case .stop:
            if let target = model.handoffTargetTake() { handIn(an: target, area: area) } else { leave() }
        case .forward:        jump(Double(model.forwardSeconds))
        case .back:    jump(-Double(model.backSeconds))
        case let .jumpOn(seconds):
            jumped(on: seconds)
            area.seek(toSeconds: seconds)
            showItem()
        case .next:
            if let episode = next { changeInto(episode) }
        case .previous:
            break
        }
    }

    /// Pauses after this many minutes and leaves the player open so you know where you were.
    private func sleepTimeSet(_ minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes else { return }
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            area?.pause()
            runsSet(false)
            showItem()
        }
    }

    /// Carries the current state into the bridge to the group and gives it the tick; see ``Gemeinsamspieler`` for why an object and not a closure.
    private func bridgeCatchUp() {
        bridge.area = area
        bridge.titleID = item.id
        bridge.isReady = (area?.startReady ?? false) && firstImagePresent
            && !FrameTick.flipsOver && !switches
        bridge.jumpShow = { target in jumped(on: target) }
        bridge.switchTitle = { episode, _, since in changeInto(episode, since: since) }
        gemeinsam.playerTick()
    }

    // MARK: - Observing and reporting

    private func observe() async {
        // The rules live in `PlaybackTick`, shared with the other platforms. Only what the TV does differently stays here.
        var state = PlaybackTick.Snapshot()
        var lastSwitch = titleSwitch
        var beats = 0

        var onlyTime = false
        while !Task.isCancelled {
            try? await Task.sleep(for: PlaybackTick.displayTick)
            guard let area else { continue }
            if switchgear.gemeinsam { bridgeCatchUp() }

            // **In between, only the time**, as on iOS.
            onlyTime.toggle()
            if onlyTime {
                if !switches {
                    state.position = position
                    state.leap = leap
                    state.firstImagePresent = firstImagePresent
                    PlaybackTick.timeAdopt(&state, reported: restoring ? area.goodPoint : area.positionSeconds,
                                                   atPush: false, sinceStart: sinceStart)
                    position = state.position
                    leap = state.leap
                }
                continue
            }

            // **Only while something is open.** The call reads the track list, which VLCKit rebuilds each time; at half-second intervals that is no longer a look but a constant grip into a running medium. Once the rate is measured, VLC is left alone.
            if FrameTick.stillPostMeasure {
                FrameTick.adapt(an: area.player)
            }

            // **Arrived means arrived.** Whether VLC is at a seek's target is decided by `PlaybackTick` from `state.sprung`. The latch before it fell after 1.2 or 2 s even when VLC was not there yet, and the bar jumped back.

            checkStall(area)

            // Take the view's state: seek, episode switch and pause change it between two ticks.
            state.position = position
            state.leap = leap
            state.duration = duration
            state.running = running
            state.firstImagePresent = firstImagePresent
            state.tracksSet = tracksSet
            state.startReported = startReported
            if titleSwitch != lastSwitch {
                lastSwitch = titleSwitch
                PlaybackTick.newTitle(&state, startReported: true)
                // From the episode layer into the middle of an episode: see `episodeApply`.
                if let since = startPostSwitch {
                    startPostSwitch = nil
                    state.afterChange = false
                    state.position = since
                    state.leap = PlaybackTick.Jump(target: since)
                }
            }

            let job = PlaybackTick.compute(
                &state,
                measurement: .init(duration: area.durationSeconds,
                               position: area.positionSeconds,
                               goodPoint: area.goodPoint,
                               showsImage: area.showsImage,
                               seeksToStart: area.seeksToStart,
                               running: area.isPlaying,
                               // **Read the track list only while it is needed.** `PlaybackTick` asks `hasAudioTracks` alone until the tracks are set; afterwards the value is unused. It was read anyway, twice a second for the whole film. `player.audioTracks` rebuilds the list each time, under the lock of the running player: exactly the constant grip that the comment on `FrameTick.stillPostMeasure` warns about. The `||` short-circuits it once it carries nothing.
                               hasAudioTracks: tracksSet || !area.audioTracks.isEmpty),
                restoring: restoring,
                // On a TV there is no finger on a slider.
                atPush: false,
                sinceStart: sinceStart)

            position = state.position
            leap = state.leap
            duration = state.duration
            // **The tick is the aligner.** `PlaybackTick` pulls the state from `area.isPlaying` once a frame is up. Both halves must receive it, or the class drifts against the view and the old bug reappears elsewhere.
            runsSet(state.running)
            tracksSet = state.tracksSet
            startReported = state.startReported

            // During the mode switch the output is black. Removing the loading screen then would show a dead picture.
            if job.loadingScreenGone {
                StartMeasurement.shared.mark("Ladeschirm weicht")
                if let beginning = switchStart {
                    switchStart = nil
                    AppLog.writeOut("[Wechsel] erstes Bild nach \(Int(Date().timeIntervalSince(beginning) * 1000)) ms")
                }
                withAnimation(Theme.motion(.easeOut(duration: 0.3))) { firstImagePresent = true } completion: {
                    StartMeasurement.shared.mark("Ladeschirm ausgeblendet")
                }
                // From a handover: the card now zooms over the picture.
                HandoffStage.shared.imagePresent(item.id)
                if let k = cardsSwitch, k.imageSince == nil {
                    cardsSwitch?.imageSince = k.since
                    AppLog.writeOut("[Karte] erstes Bild nach \(Int(k.since * 1000)) ms")
                    Task { await cardHandOver() }
                }
            }
            if job.tracksApply {
                area.wendeLanguagesAn(audio: model.audioLanguage,
                                        subtitle: model.subtitleLanguage,
                                        automatic: model.subtitleAutomatic,
                                        source: plan.source,
                                        title: TrackMemory.title(for: item))
            }
            // Stay silent during the switch, as on iOS: otherwise progress for the old episode goes out after the stop.
            //
            // **Detached, not awaited**: this had an `await`, and the timeline stood still while the server did not answer, up to 20 s without network, up to 40 at start.
            if job.startReport, !switches {
                // The position reached, not the target: if the start seek misses, the first report is wrong otherwise.
                model.reportStart(item: item, plan: plan, seconds: position)
            }
            if job.progressReport, !switches {
                model.reportProgress(item: item, plan: plan,
                                     seconds: position, paused: !running)
            }

            // **Keep focus while paused.**
            //
            // The detour through settings does exactly this: the sheet closes and `wakeControls` puts focus back on the bar, after which playback works again. Doing it once on toggle was not enough; SwiftUI clears focus afterwards. So while paused and with no sheet open, it is set again on every tick.
            //
            // Only while paused: during playback focus should be free to move to the buttons at the top. And only if it is **nowhere**; on a button it belongs there.
            if !running, !layerOpen, focus == nil {
                focus = .bar
            }

            beats += 1
            // The display needs the position only once a second.
            if beats % 2 == 0 {
                hub.stateCatchUp(position: position, running: running, tempo: tempo)
                #if DEBUG
                // Heartbeat for the measurement run (`-measurementRun` of MainView): if the tick stands, lines are missing here.
                if ProcessInfo.processInfo.arguments.contains("-messlauf") {
                    AppLog.writeOut("[Takt] \(String(format: "%.1f", position)) laeuft \(running)")
                }
                if OfflineRun.an {
                    AppLog.writeOut("[Sprungtakt] \(item.id) Anzeige \(String(format: "%.1f", position)) · Angebot \(offering)")
                }
                #endif
            }

            // **Prepare the next episode** while this one still plays, not in a group, which advances by itself. Once per episode; when and over which network is decided by `Prebuffer`.
            if let episode = next, !inGroup, !switches,
               Prebuffer.now(position: position, duration: duration,
                               creditsFrom: sections.first { $0.art == .credits }?.from,
                               networkFavorable: preparation.networkFavorable) {
                preparation.prepare(episode) { await model.plan(for: episode.id, still: true) }
            }

            // **The overlay.** The countdown runs only while the film plays; paused, it holds.
            let cardBefore = episodesCardPresent
            if offeringCatchUp(elapsed: PlaybackTick.tickLength / .seconds(1)),
               let episode = next {
                AppLog.writeOut("[Karte] Countdown abgelaufen")
                changeInto(episode, fromCard: cardBefore)
            }

            // Continue by itself at the end, only with the card (outro section from the server) and not if it was cancelled. "Next episode automatically" no longer matters here.
            if layer.nextAtEnd, let episode = next, !switches,
               // Only once the new episode is really up. Otherwise the old one's time still counts, and that is naturally at the end.
               firstImagePresent,
               EpisodeEnd.advance(position: position, duration: duration,
                                         sinceOpen: Date().timeIntervalSince(sinceStart),
                                         cardCounts: layer.cardCounts) {
                AppLog.writeOut("[Wechsel] Dateiende ohne Karte")
                changeInto(episode)
            }
        }
    }
}

// MARK: - Timeline

/// Time at the left, remaining time at the right, the bar between: the layout of the iPhone version.
///
/// It is the only focusable piece in the lower area, and left/right seek on it. A slider that has to be focused first would be one step too many on the remote.
///
/// **Paused: only the line; while scrubbing a handle in accent color**, the only place in the player where the accent color appears. Above it the preview image from Jellyfin's trickplay with the target time; without trickplay just the time.
struct TimeBar: View {
    /// Where the film really is.
    let position: Double
    let duration: Double
    /// The target while a marker is set, when swiping and tapping fast. `nil` means the bar shows the position, not an intention.
    let mark: Double?
    /// From the settings, not hardwired; the same values the remote control uses.
    let back: Double
    let forward: Double
    let jump: (Double) -> Void
    let wake: () -> Void
    /// The middle button: confirms a marker, otherwise pause/resume.
    let click: () -> Void
    /// While paused, the pause icon sits before the time.
    var running = true
    /// The trickplay image for the position, or `nil`.
    var preview: (Double) -> CGImage? = { _ in nil }
    /// **Section boundaries in seconds: notches on the bar.**
    ///
    /// The player loads them anyway, for the skip card and the countdown; the bar knew nothing of them. A bar with notches shows at a glance how the film is built: where the intro ends and the outro begins. Same addition as on iPhone.
    var sectionLimits: [Double] = []
    /// **Chapters divide the bar into pieces.** While scrubbing, the one containing the target is raised, and its name appears above the preview. Same addition as on iPhone.
    var chapter: [Chapter] = []

    private var seeks: Bool { mark != nil }

    /// Gap like the notch here: four points, at three meters double the iPhone's. The smallest piece in the same ratio.
    private static let gap: CGFloat = 4
    private static let minWidth: CGFloat = 16

    private func pieces(width: CGFloat) -> [ChapterBar.Piece] {
        ChapterBar.pieces(limits: ChapterBar.limits(chapter, duration: duration), duration: duration,
                              width: Double(width), minWidth: Double(Self.minWidth))
    }

    /// The boundaries as fractions, without those at the two edges: a notch right at the edge reads as fraying.
    private func notches() -> [Double] {
        guard duration > 0 else { return [] }
        return sectionLimits.map { $0 / duration }.filter { $0 > 0.01 && $0 < 0.99 }
    }
    /// Where the handle points: the target, otherwise the position.
    private var shown: Double { mark ?? position }

    private func share(_ seconds: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(seconds / duration, 0), 1)
    }

    /// Eight points when paused, twelve while scrubbing; with chapters only the piece containing the target (``ChapterMask``).
    private let barHeight: CGFloat = 8
    private let barHeightRaised: CGFloat = 12
    private let grip: CGFloat = 36
    /// How wide the box above the handle really is: with a chapter name but without a preview image it depends on the name.
    @State private var boxWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 28) {
            // **Paused shows here**, at the start of the bar, not in the middle of the picture where it lay over the technical badge. Only the pause icon: whoever plays needs no sign for it.
            HStack(spacing: 16) {
                if !running {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(Theme.font)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
                Text(PlayTime.text(position))
            }
            .animation(Theme.motion(.easeInOut(duration: 0.18)), value: running)

            GeometryReader { frameRect in
                let width = frameRect.size.width
                let state = share(position)
                let target = share(shown)
                let pieces = pieces(width: width)

                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(PlayerMetric.barReason)

                        // Up to the real position: that has been seen. In the bar's thickness, not the mask's; otherwise its end would be a flat arc instead of a round one when paused.
                        Capsule().fill(Theme.font)
                            .frame(width: width * min(state, target),
                                   height: seeks ? barHeightRaised : barHeight)

                        // **The stretch between position and target.** Without it the bar says only where you want to go while scrubbing, not how far that is from here.
                        if seeks {
                            Capsule().fill(Color.white.opacity(0.55))
                                .frame(width: width * abs(target - state), height: barHeightRaised)
                                .offset(x: width * min(state, target))
                        }

                        // **Notches at section boundaries.** Four points wide (at three meters double the iPhone notch), in `reason` because they must be visible on both the light track and the white bar.
                        ForEach(notches(), id: \.self) { spot in
                            Rectangle().fill(Theme.reason)
                                .frame(width: 4)
                                .offset(x: width * spot - 2)
                        }
                    }
                    .frame(height: barHeightRaised)
                    .mask(alignment: .leading) {
                        ChapterMask(pieces: pieces, width: width, gap: Self.gap,
                                     thickness: barHeight,
                                     elevated: seeks ? ChapterBar.piece(at: target, in: pieces) : nil,
                                     thicknessRaised: barHeightRaised,
                                     motion: Theme.motion(.easeInOut(duration: 0.18)))
                    }

                    Circle()
                        .fill(Theme.accent)
                        .frame(width: grip, height: grip)
                        .scaleEffect(seeks ? 1 : 0.4)
                        .opacity(seeks ? 1 : 0)
                        .offset(x: width * target - grip / 2)
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if seeks { previewBox(width: width, share: target) }
                }
            }
            .frame(height: PlayerMetric.bar)

            remainingTime
        }
        .font(.system(size: PlayerMetric.time).monospacedDigit())
        .foregroundStyle(Theme.fontQuiet)
        .focusable()
        // The middle button lands on the focused view.
        .onTapGesture { click() }
        .animation(Theme.motion(.easeInOut(duration: 0.18)), value: seeks)
        .onMoveCommand { bearing in
            switch bearing {
            case .left:  jump(-back)
            case .right: jump(forward)
            // **Down toggles the remaining time**, the counterpart of tapping the remaining time on iPhone. Nothing under the bar could take focus; the time itself is not a focus target, or there would be one more step between bar and seeking.
            case .down:  asEnd.toggle(); wake()
            default:     wake()
            }
        }
    }

    /// **Remaining time or end**, as on iPhone: "-12:34" or "Ends at 22:41", same place, same type; the choice is kept.
    @AppStorage("restzeitAlsEnde") private var asEnd = false

    private var remainingTime: some View {
        let rest = max(duration - position, 0)
        return Group {
            if asEnd {
                Text("Endet um \(Date().addingTimeInterval(rest).formatted(date: .omitted, time: .shortened))")
            } else {
                Text(verbatim: "−" + PlayTime.text(rest))
            }
        }
        .lineLimit(1)
    }

    /// **Above the handle: preview image, below it the time.** At the edge the box stays fully on the bar; without trickplay only the time, no empty box.
    ///
    /// **With chapters its name precedes the time**, on one line and at most as wide as the preview image, as on iPhone.
    private func previewBox(width: CGFloat, share: Double) -> some View {
        let image = preview(shown)
        let imageWidthValue: CGFloat = 400
        let imageHeightValue = imageWidthValue * 9 / 16
        let timeHeight: CGFloat = 40
        let name = ChapterBar.chapter(at: shown, in: chapter)?.name ?? ""
        let half = image != nil ? imageWidthValue / 2 : max(name.isEmpty ? 70 : boxWidth / 2, 70)
        let x = min(max(width * share, half), max(width - half, half))
        let height = (image == nil ? 0 : imageHeightValue + 12) + timeHeight
        return VStack(spacing: 12) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: imageWidthValue, height: imageHeightValue)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 2))
            }
            HStack(spacing: 12) {
                if !name.isEmpty {
                    Text(verbatim: name)
                        .font(.system(size: PlayerMetric.previewTime))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(PlayTime.text(shown))
                    .font(.system(size: PlayerMetric.previewTime, weight: .semibold).monospacedDigit())
                    .layoutPriority(1)
            }
            .foregroundStyle(Theme.font)
            .frame(height: timeHeight)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
        .frame(maxWidth: imageWidthValue)
        .fixedSize(horizontal: false, vertical: true)
        // Bottom edge just above the bar's row.
        .position(x: x, y: -height / 2 - 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// **The skip pill:** dark surface with white text at rest, white surface with dark text when focused, like the icon buttons.
///
struct PillsStyle: ButtonStyle {
    /// Countdown: the fill's clock from the left. `nil` without.
    var fillContent: FillClock? = nil

    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration, fillContent: fillContent)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        let fillContent: FillClock?
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .font(Theme.button)
                // **Focus = the surface turns white**, as with the icon buttons (`IconButtonStyle`): dark surface with white text at rest, white surface with dark text and magnification when focused. Before, the pill was always white and focus was only a 6 % magnification, which at three meters barely showed whether a click would hit it.
                .foregroundStyle(focus ? Theme.reason : Theme.font)
                .padding(.horizontal, 32)
                .frame(height: 72)
                // **The countdown as a fill, not as a number.** Dark on white, not in accent color: in the player that belongs to the bar's handle while scrubbing.
                .background {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                            .fill(focus ? Theme.font : Color.black.opacity(0.55))
                        if let fillContent {
                            TimelineView(.animation) { time in
                                GeometryReader { g in
                                    Rectangle()
                                        .fill((focus ? Theme.reason : Theme.font).opacity(0.16))
                                        .frame(width: g.size.width * fillContent.share(now: time.date))
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                }
                // **No shadow.** The brand rule: no shadows, not on iPhone, not under the focused tile on TV, nowhere. Magnification and surface already do the job; a soft shadow turns to mud at three meters.
                .scaleEffect(configuration.isPressed ? 0.97 : (focus ? Theme.focusMagnifier : 1))
                .animation(Theme.focusAnimation, value: focus)
        }
    }
}

// MARK: - Drawing surface

/// Hosts VLC's video surface in SwiftUI.
///
/// Without `dismantleUIView` the watchdog timer of the torn-down view runs forever, the same trap as on iPhone. `stop()` in `onDisappear` cannot be relied on: it hits the view the state points to, not necessarily every one SwiftUI created.
struct VideoSurface: UIViewRepresentable {
    let url: URL
    let startAt: Double
    let container: String?
    /// **Before `play`, not after.** The level goes to libvlc as a start option; set afterwards it only applies at the next open.
    let buffer: BufferLevel
    /// External subtitles, also before `play`.
    var subtitle: [SubtitleFile] = []
    /// Open with the software decoder at once; ``PlaybackPlan/softwareDekoder``.
    var softwareDecoder = false
    /// The wanted tracks, also before `play`.
    var tracks: VLCPlayerView.TrackRequest?
    /// Where in the title the delivered stream begins; see `PlaybackPlan`.
    let created: (VLCPlayerView) -> Void

    func makeUIView(context: Context) -> VLCPlayerView {
        let view = VLCPlayerView()
        view.buffer = buffer
        view.trackRequest = tracks
        view.play(url: url, offSeconds: startAt, container: container, subtitle: subtitle,
                  softwareDecoder: softwareDecoder)
        DispatchQueue.main.async { created(view) }
        return view
    }

    func updateUIView(_ view: VLCPlayerView, context: Context) {}

    static func dismantleUIView(_ view: VLCPlayerView, coordinator: ()) {
        MainActor.assumeIsolated { view.stop() }
    }
}


/// The player's switch, as a class.
///
/// Everything a lingering callback must **read** belongs here. `@State` in a view is copied when captured; a class is read by reference and is therefore always current.
@MainActor
final class Switchgear {
    /// When a command last went to VLC.
    var recent = Date.distantPast
    /// When the Play/Pause key last arrived directly; against its second delivery via the playback center.
    var lastKey = Date.distantPast
    /// **What was last intended.** Toggling follows it; VLC's report (`running`) comes only afterwards.
    var wanted = true

    /// **Whether it is playing now, as the viewer sees it.**
    ///
    /// This used to exist only as `@State` in the view, and `haltOrNext` asked `area.isPlaying` instead. The comment above it already said the right thing ("follow `laeuft`, not VLC"), but the code did the opposite.
    ///
    /// The consequence: `isPlaying` lags the command; whoever asks then chooses the direction from a state that no longer exists and toggles back what was just toggled. If VLC is rebuilding its video output, the lag lasts seconds instead of milliseconds, and then it diverges for good.
    ///
    /// Here and not in the view, because the remote reads from retained callbacks. See the explanation at the top of this class.
    var running = true
    /// The player belongs to a group (watching together); see `PlayerScreen.inGroup`.
    var gemeinsam = false
}

/// The remote's swipe surface.
///
/// **Why UIKit.** SwiftUI reports only `onMoveCommand` from the trackpad: one step per swipe, without distance or speed. Seeking needs the finger movement itself, which tvOS releases only through a `UIPanGestureRecognizer` with indirect touches.
///
/// **Why on the window.** Indirect touches have no location on the picture; tvOS delivers them to the focused view and lets them travel up the chain. A layer in the ZStack is a sibling of the bar, not its ancestor, so nothing would ever arrive there. The window is the only point where both meet. The player fills it entirely, and `dismantleUIView` removes the recognizer on teardown.
struct SwipeField: UIViewRepresentable {
    let begins: () -> Void
    /// Distance since the last call and the speed, both in points.
    let moved: (CGFloat, CGFloat) -> Void
    let ends: (CGFloat) -> Void

    func makeUIView(context: Context) -> Carrier {
        let carrier = Carrier()
        carrier.isUserInteractionEnabled = false
        let recognizer = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Reporter.swiped(_:)))
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        // Focus must keep moving: the same swipe moves it too, and a recognizer that swallows the touch cripples the controls.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delegate = context.coordinator
        carrier.recognizer = recognizer
        return carrier
    }

    func updateUIView(_ carrier: Carrier, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ carrier: Carrier, coordinator: Reporter) {
        guard let recognizer = carrier.recognizer else { return }
        recognizer.view?.removeGestureRecognizer(recognizer)
    }

    func makeCoordinator() -> Reporter { Reporter(self) }

    /// Attaches the recognizer to the window as soon as there is one.
    final class Carrier: UIView {
        var recognizer: UIPanGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let recognizer else { return }
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
    }

    final class Reporter: NSObject, UIGestureRecognizerDelegate {
        var parent: SwipeField
        private var last: CGFloat = 0
        /// Only a clearly horizontal swipe is seeking.
        private var active = false

        init(_ parent: SwipeField) { self.parent = parent }

        /// **Only horizontal seeks.** Before, any touch sufficed: whoever swiped up to reach "Next episode" or settings got the scrub marker. Now seeking starts only after 40 points that go at least twice as far sideways as up or down. Everything else is left to focus.
        @objc func swiped(_ recognizer: UIPanGestureRecognizer) {
            let t = recognizer.translation(in: nil)
            switch recognizer.state {
            case .began:
                active = false
                last = 0
            case .changed:
                if !active {
                    guard abs(t.x) > 40, abs(t.x) > abs(t.y) * 2 else { return }
                    active = true
                    last = t.x
                    parent.begins()
                    return
                }
                let distance = t.x - last
                last = t.x
                parent.moved(distance, recognizer.velocity(in: nil).x)
            case .ended:
                if active { parent.ends(recognizer.velocity(in: nil).x) }
                active = false
            case .cancelled, .failed:
                if active { parent.ends(0) }
                active = false
            default:
                break
            }
        }

        // Alongside the focus system, not instead of it.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Reads the Siri Remote's click ring directly, on press **and** release.
///
/// SwiftUI's `onMoveCommand` reports single steps only; whether someone is holding it does not learn. GameController delivers the press with its location on the surface: far left, far right, or middle (which stays with focus).
@MainActor
final class ClickRing {
    private var begins: ((Int) -> Void)?
    private var ends: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var held = false

    func observe(begins: @escaping (Int) -> Void, ends: @escaping () -> Void) {
        self.begins = begins
        self.ends = ends
        allSetUp()
        observer = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            // Do not pass the device from the notification; that crosses the actor boundary. Just set all up again; it is cheap and idempotent.
            MainActor.assumeIsolated { self?.allSetUp() }
        }
    }

    func resolve() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for c in GCController.controllers() {
            c.microGamepad?.buttonA.pressedChangedHandler = nil
            c.microGamepad?.reportsAbsoluteDpadValues = false
        }
        begins = nil
        ends = nil
    }

    private func allSetUp() {
        GCController.controllers().forEach(setUp)
    }

    private func setUp(_ c: GCController) {
        guard let pad = c.microGamepad else { return }
        pad.reportsAbsoluteDpadValues = true
        // **Right here, not one turn later.** GameController calls on its `handlerQueue`, which is the main queue, the same guarantee as for the observer above. `DispatchQueue.main.async` pushed every press back by a turn and bypassed the check on which actor it arrives.
        pad.buttonA.pressedChangedHandler = { [weak self, weak pad] _, _, pressed in
            MainActor.assumeIsolated {
                let x = pad?.dpad.xAxis.value ?? 0
                self?.pressed(x: x, an: pressed)
            }
        }
    }

    private func pressed(x: Float, an: Bool) {
        if an {
            guard abs(x) > 0.5 else { return }
            held = true
            begins?(x < 0 ? -1 : 1)
        } else if held {
            held = false
            ends?()
        }
    }
}
