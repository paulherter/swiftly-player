import AppKit
import CoreGraphics
import JellyfinKit
import SwiftUI

/// The player inside the window.
///
/// Mirrors the iOS player (`Sources/iOS/PlayerScreen.swift`, `PlayerLayers.swift`),
/// adapted to mouse, keyboard and window:
/// - Controls appear when the pointer moves, not on tap.
/// - Seeking uses the arrow keys instead of double-tap zones.
/// - Instead of Picture in Picture there is a small window (`WindowHolder`).
///   This is not a choice: VLC does not expose an `AVSampleBufferDisplayLayer`
///   on macOS.
/// - A dedicated full-screen button, because a window has full screen and a
///   phone does not.
struct PlayerScreen: View {
    let model: AppModel
    let beginning: PlayRequest
    let close: () -> Void

    /// Title and plan carry over on episode change; the player stays put and only
    /// what it plays changes.
    @State private var title: Item
    @State private var plan: PlaybackPlan
    @State private var nextEpisode: Item?
    /// Intro, recap, outro. Empty if the server knows nothing.
    @State private var sections: [JellyfinKit.Segment] = []
    /// The file's chapters; they split the scrubber. Empty means one segment.
    @State private var chapter: [Chapter] = []
    /// "Skip intro" and "Next episode" above the picture, without the controls having
    /// to open. `OfferingLayer` decides what applies when. The next-episode card waits
    /// while the controls are deliberately open (click on the picture); it is
    /// dismissed with the X or Esc (``EpisodeCardsView``), as on iPhone.
    @State private var layer: OfferingLayer = {
        var e = OfferingLayer()
        e.cardWaitsControls = true
        return e
    }()
    /// Mirrors the latch of `episodesSwitch` for the view.
    @State private var switches = false
    /// "Skip intro and outro automatically" (settings). Off by default.
    @AppStorage("introAbspannAuto") private var autoSkip = false
    /// Sections already skipped on their own in this episode (by start second): once per section.
    @State private var autoSkipped: Set<Double> = []
    @State private var episodesSwitch = EpisodeSwitch()
    /// Plan and file start of the next episode, fetched in the last minutes. Same
    /// preparation as on iPhone (``Prebuffer``).
    @State private var preparation = EpisodePreparation()
    /// **The next-episode card** (``EpisodeCard``, variant C): held while it zooms
    /// into the picture, with the episode and countdown state from just before, so
    /// nothing flashes when the switch removes the offer.
    @State private var cardsSwitch: CardsSwitch?
    @State private var cardsEpisode: Item?
    @State private var cardsClock: FillClock?
    @State private var cardsZoom: Double = 0
    @State private var cardImage: Double = 1
    /// Which title is already counted as watched to the end. `finish` and the
    /// disappearance both fire, so the count happens only once.
    @State private var counted: String?
    @State private var hint: String?
    /// The next plan comes from a quality choice; used for the hint.
    @State private var qualitySwitched = false
    @State private var area: VLCPlayerView?
    /// Counts only while the badge is on; see `TechBadge`.
    @AppStorage("technikschild") private var techBadge = false
    @State private var playValues: PlayValues?
    @State private var state: PlaybackTick.Snapshot

    /// **What the button shows until the tick catches up.**
    ///
    /// `state.running` comes from the tick, which fires every 500 ms
    /// (`PlaybackTick.tickLength`). The button used to depend on it, so it flipped
    /// up to half a second after the click. Together with the picture lagging
    /// slightly, the player looked unresponsive.
    ///
    /// It is set by `VLCPlayerView.runsReported`, i.e. at the moment VLC itself
    /// switches (measured 17 to 25 ms after the press). Button and picture
    /// therefore stop together.
    @State private var runsDisplay: Bool?

    private var runsNow: Bool { runsDisplay ?? state.running }
    @State private var atSlider = false
    /// Volume 0 to 1, kept across titles; `davor` remembers the value for unmuting.
    @AppStorage("playerLautstaerke") private var volume = 1.0
    @AppStorage("playerLautstaerkeDavor") private var volumePrior = 1.0
    @State private var volumePulls = false
    @State private var volumeShort = false
    @State private var volumeClock: Task<Void, Never>?
    /// Which of the three layers is open: audio and subtitles, episodes, settings.
    /// `nil` means none.
    @State private var openLayer: PlayerLayer?
    /// Where the pointer was last. Without this comparison every redraw resets the
    /// timer, and the loop redraws every 500 ms, so the timer would never expire.
    @State private var pointerLast: CGPoint?
    /// Only for the fade: `state.firstImagePresent` says *whether*; this flag makes the
    /// removal fade smoothly.
    @State private var screenDistance = false
    /// As on iOS: seeks set `state.sprung` via `jumped(on:)`, and the tick holds
    /// the target position until VLC has arrived. This is the seek currently being
    /// acknowledged (direction and distance).
    ///
    /// iPhone and iPad show a marker at the edge when seeking (`Sprungmarke`). On the
    /// Mac there are buttons and arrow keys, but one still wants to see **that** a
    /// seek happened and how far; otherwise a key looks dead until the picture
    /// catches up.
    @State private var jumpDisplay: (bearing: Int, seconds: Int)?
    @State private var jumpTick = 0
    /// **Hide the video surface first when closing.**
    ///
    /// On the Mac the video output is a `VLCOpenGLVideoView`. An OpenGL view draws
    /// into its **own** surface and sits above everything later in the SwiftUI
    /// stack, so the order in the `ZStack` does not matter (see the comment at
    /// `MacVideoSurface`).
    ///
    /// For the close animation that means the SwiftUI layers slide down properly,
    /// but the OpenGL surface stays in place until SwiftUI actually removes the view,
    /// showing up as a black layer that disappears after a few seconds.
    ///
    /// `isHidden` acts at the AppKit level and thus immediately. So hide first, then
    /// animate.
    @State private var areaOut = false
    /// One counter per direction; otherwise the effect plays on the wrong button when
    /// alternating between forward and back seeks.
    @State private var tickBack = 0
    @State private var tickPre = 0
    @State private var sleepMinutes: Int?
    @State private var sleepTask: Task<Void, Never>?
    @State private var sinceStart = Date()
    @State private var controlsPresent = true
    /// The picture is currently being handed off as a card to another device.
    @State private var handoverRuns = false
    /// The card's fill as one continuous motion (`FillClock`).
    @State private var fillClock = FillClock()
    @State private var holder = WindowHolder()
    @State private var hub = PlaybackHub()
    @State private var idleTask: Task<Void, Never>?
    /// Check once per title whether the server has thumbnails; same package as on iOS
    /// (`Sources/Shared/TrickplayImages.swift`).
    @State private var trickplay = TrickplayImages()

    /// **Watch together.** Set on open when the title is the one the group is
    /// watching. The group itself is held by ``SharedModel``.
    @State private var sharedAn = false
    @State private var bridge = SharedPlayer()
    private var gemeinsam: SharedModel { .shared }
    /// Is this player currently in a group? Then pause, resume and seeking go to the
    /// server as requests instead of to VLC, whether they come from buttons, space,
    /// arrow keys, media keys or remote commands.
    private var inGroup: Bool { sharedAn && gemeinsam.group != nil }

    init(model: AppModel, wish: PlayRequest, close: @escaping () -> Void) {
        self.model = model
        self.beginning = wish
        self.close = close
        _title = State(initialValue: wish.item)
        _plan = State(initialValue: wish.plan)
        // **The clock starts at the resume position, not at zero.**
        //
        // `Snapshot()` starts at 0, and that zero would be in effect for about 2.5 seconds
        // until VLC has settled. Hiding it is not enough: the scrubber would be bound to
        // a zero during that time, so dragging it would jump relative to 0 instead of
        // the real position. `EpisodeEnd.buttonShow` would also receive it, which makes
        // a difference for an episode that is 97% watched.
        //
        // The iPhone version does the same (`_position = State(initialValue: startAt)`).
        _state = State(initialValue: .init(position: wish.startAt))
    }

    /// Fill the frame instead of showing the whole picture; same choice as the
    /// gesture on iPhone and the card on tvOS, under the same key.
    @AppStorage("bildfuellend") private var fillFrame = false
    /// Prevents a single pinch from toggling several times.
    @State private var zoomAlreadySwitched = false

    private var mass: PlayerMetric { PlayerMetric() }

    var body: some View {
        ZStack {
            Color.black

            MacVideoSurface(url: beginning.plan.url, startAt: beginning.startAt,
                         container: beginning.plan.container,
                         covered: !screenDistance || areaOut,
                         buffer: model.bufferLevel,
                         subtitle: model.subtitleFiles(beginning.plan),
                         softwareDecoder: beginning.plan.softwareDecoder,
                         tracks: trackRequest(title, beginning.plan)) { new in
                area = new
                new.volumeSet(Int((volume * 100).rounded()))
                // The button follows VLC's own report, not the tick and not the click; see
                // `runsDisplay`. The server is told at the same moment. `model` is
                // captured here because the callback outlives this view.
                let reporter = model
                new.runsReported = { [weak new] running in
                    runsDisplay = running
                    reporter.runStateReported(running: running, seconds: new?.positionSeconds ?? 0)
                }
                new.jumpReported = { target in reporter.jumpReported(target: target) }
                new.tracksReported = { tracks in reporter.tracksSelected(tracks) }
                // Whatever was chosen once also applies to the next episode; same key as the
                // gesture on iPhone and the card on tvOS.
                new.fillFrame(fillFrame)
            }
            .ignoresSafeArea()
            // Without this, the controls' animation drags the video surface along, and it
            // visibly grew from small to large on every fade-in. A flaw inherited from the
            // iPhone version, unrelated to Picture in Picture, and it affects the Mac too.
            .transaction { $0.animation = nil }
            // **Pinching on the trackpad toggles the aspect mode.**
            //
            // Same as the gesture on iPhone, with two fingers on the trackpad; on tvOS a
            // card in the sheet does this. Two states: whole picture with bars, or fill with
            // cropping. A third would only be a stretch.
            //
            // The latch is needed because `onChanged` fires dozens of times during a
            // gesture; without it a single spread would flicker between the two states.
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.05)
                    .onChanged { value in
                        guard !zoomAlreadySwitched else { return }
                        if value.magnification > 1.15, !fillFrame {
                            zoomAlreadySwitched = true
                            fillFrame = true
                            area?.fillFrame(true)
                        } else if value.magnification < 0.85, fillFrame {
                            zoomAlreadySwitched = true
                            fillFrame = false
                            area?.fillFrame(false)
                        }
                    }
                    .onEnded { _ in zoomAlreadySwitched = false }
            )
            // **A click on the picture** deliberately brings up the controls, which also
            // dismisses a running "Next episode" card, unlike pointer movement.
            .simultaneousGesture(TapGesture().onEnded { controlsShow() })
            // **Double-click on the picture: full screen** (as in QuickTime, IINA, VLC). A
            // single click only shows the controls and toggles nothing, so it harmlessly
            // runs twice during a double-click.
            .simultaneousGesture(TapGesture(count: 2).onEnded { holder.fullscreenToggle() })

            // **Opaque**, not just a spinner. Previously a transparent `Loader()` was used
            // and the video played visibly underneath: VLC could be seen starting at the
            // beginning and then seeking to the remembered position.
            // When the card zooms into the picture it covers the switch, with no loading
            // screen on top (as on iOS).
            if !screenDistance, cardsSwitch == nil { startScrim }
            // During the switch the old episode keeps playing; the ring shows that the click
            // arrived.
            if screenDistance, switches, cardsSwitch == nil { Loader() }

            // The seek marker is shown **independently of the controls**: anyone seeking
            // with the arrow keys usually has them closed.
            if screenDistance, let jumpDisplay {
                HStack(spacing: 0) {
                    if jumpDisplay.bearing > 0 { Spacer() }
                    JumpMark(bearing: jumpDisplay.bearing,
                                seconds: jumpDisplay.seconds)
                        // Without its own identity SwiftUI does not rebuild the view for two seeks in a
                        // row, and the rotation would not play.
                        .id(jumpTick)
                    if jumpDisplay.bearing < 0 { Spacer() }
                }
                .padding(.horizontal, 44)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // **What happens in the group, briefly at the top**, so nobody wonders why the
            // film is paused.
            if inGroup, let event = gemeinsam.event {
                GroupsEvent(symbol: event.symbol, text: event.text)
                    .padding(.top, mass.top + mass.button + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .id(event.id)
                    .zIndex(4)
            }
            // What went wrong with the group, at the bottom above the scrubber.
            SharedError()
                .padding(.bottom, mass.bottom + mass.bar + mass.overBar)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .zIndex(7)

            if screenDistance {
                // **Flat dimming, no gradient.** Same as iOS `Playerschleier`
                // (Sources/iOS/PlayerScreen.swift): rgba(11,11,13,.42), no gradient, as in the
                // design. While the next-episode card is up it dims the picture the same way,
                // and the card sits in front (as on iOS).
                Theme.reason.opacity(0.42)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .opacity(dimmed ? 1 : 0)
                    .animation(dimmed ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.34),
                               value: dimmed)
            }

            // **Above the scrim, below the controls.** See ``EpisodeCardsView`` for why it
            // sits above the scrubber.
            cardsLayer

            // **The tech badge.** Information, not a control: it takes no clicks.
            // **Directly on the film**: above the dimming, below title, buttons and
            // scrubber, and therefore also below the layers.
            // **It slides with the controls**: open below the title row, closed at the top
            // edge where it used to sit. Motion rather than a fade, same curve as the
            // controls; with reduced motion it jumps. Outside `screenDistance`, so it is already
            // visible while loading.
            if techBadge {
                TechBadge(plan: plan, values: playValues, area: area)
                    .padding(.leading, mass.page)
                    .padding(.top, mass.top + mass.button + Theme.tileSpacing)
                    .offset(y: controlsPresent && openLayer == nil ? 0 : -(mass.button + Theme.tileSpacing))
                    .animation(Theme.motionReduced ? nil
                               : controlsPresent ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.34),
                               value: controlsPresent && openLayer == nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if screenDistance {
                Group {
                    centerControls
                        .opacity(atSlider ? 0 : 1)
                        .allowsHitTesting(!atSlider)
                    VStack(spacing: 0) {
                        header
                        Spacer(minLength: 0)
                        footer
                    }
                }
                .opacity(controlsPresent && openLayer == nil ? 1 : 0)
                .allowsHitTesting(controlsPresent && openLayer == nil)
                .animation(controlsPresent ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.34),
                           value: controlsPresent)
            }

            // **The skip pill sits in the same place whether or not the controls are open**
            // (as on iOS). The footer only reserves its space. Skip stays for six seconds on
            // its own, afterwards only with the controls (`OfferingLayer.buttonDuration`),
            // including the ones the pointer brings up.
            //
            // **Fade out, don't snap out**, as on iPhone: removal from the tree was abrupt
            // despite a transition. The pill stays in the tree as long as there is an offer
            // and comes and goes through opacity. `disabled` so an invisible pill takes
            // neither clicks nor keyboard focus. When the next-episode card is there, the
            // pill yields to it.
            if offering.visible {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        offeringButton
                            .disabled(!buttonPresent)
                    }
                }
                .padding(.horizontal, mass.page)
                .padding(.bottom, mass.bottom + mass.bar + mass.overBar)
                .opacity(buttonPresent ? 1 : 0)
                .allowsHitTesting(buttonPresent)
                .accessibilityHidden(!buttonPresent)
                .animation(buttonPresent ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.34),
                           value: buttonPresent)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18)),
                                        removal: .opacity.animation(.easeInOut(duration: 0.34))))
            }

            if let openLayer {
                layersView(openLayer)
                    .transition(.opacity)
                    .zIndex(5)
            }

            stateTitle
                .zIndex(6)
        }
        .animation(Theme.reveal, value: techBadge)
        .animation(Theme.reveal, value: gemeinsam.event)
        .animation(.easeInOut(duration: 0.2), value: openLayer)
        .task(id: techBadge) {
            guard techBadge else { return }
            while !Task.isCancelled {
                // The rate is derived from the difference to the last time; see `PlayValues`.
                playValues = PlayValues(area?.statistics, spot: area?.positionSeconds ?? 0,
                                        running: area?.isPlaying ?? false, before: playValues)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .background(WindowHandle(holder: holder))
        // The pointer brings up the controls, not a click; a click on the picture would
        // do nothing expected on the Mac. `onContinuousHover` reports not only movement
        // but also every redraw with an unchanged position. Hence the comparison: only
        // real movement brings up the controls.
        .onContinuousHover { status in
            guard case let .active(spot) = status else {
                // **Pointer leaves the window: hide immediately.**
                //
                // The four seconds exist so the controls do not vanish while still in use. If
                // the pointer is no longer in the window nobody needs them, and waiting is just
                // delay. While paused they stay, since there they are the state rather than a
                // leftover.
                pointerLast = nil
                holder.setPointerTop(false)
                if state.running, !atSlider { controlsImmediateDistance() }
                return
            }
            defer { pointerLast = spot }
            // **The window traffic lights follow this zone, not the controls.** Otherwise
            // they sit permanently above the picture and get in the way. This way they
            // appear when sought at the top and stay away otherwise.
            holder.setPointerTop(spot.y < Theme.signalZone)
            guard let before = pointerLast else { return }
            let distance = hypot(spot.x - before.x, spot.y - before.y)
            // Incidentally: movement brings up the controls but does not dismiss the
            // "Next episode" card.
            if distance > 2 { controlsShow(through: .beside) }
        }
        .onAppear { controlsShow() }
        .onChange(of: volume) { _, new in
            area?.volumeSet(Int((new * 100).rounded()))
        }
        // After a layer closes, the four-second timer restarts.
        .onChange(of: openLayer) { _, opened in if opened == nil { controlsShow() } }
        // The fade follows the controls. Only a sync: whether opening cancels the card is
        // decided by `controlsShow(through:)`.
        .onChange(of: controlsPresent, initial: true) { _, opened in
            layer.controls(opened: opened, through: .beside)
            fillSet()
        }
        .onChange(of: cardPresent) { _, present in
            guard cardsSwitch == nil else { return }
            AppLog.writeOut(present ? "[Karte] erscheint bei \(Int(state.position)) s von \(Int(state.duration)) s"
                                 : "[Karte] geht (abgesagt oder Steuerung)")
        }
        .onAppear {
            model.playerOpen = true
            // In front of the hub: its handlers ask the group.
            if gemeinsam.belongsGroup(title.id) {
                bridgeCatchUp()
                gemeinsam.plugIn(bridge)
                sharedAn = true
            }
            hubAdopt()
            // **Remote control too, not just the lock screen.**
            //
            // Both get the same handlers but arrive from different directions: the hub from
            // this computer's media keys, `remoteCommand` over Jellyfin's socket from another
            // device. The Mac was missing the second half entirely.
            model.remoteCommand = execute
            holder.setPlayer(true)
            // The poll rests while a player is open; one question for "Übergeben an …".
            Task { await PlayOutputs.shared.refresh(model) }
        }
        .onChange(of: state.running) { _, new in
            fillSet()
            if runsDisplay == new { runsDisplay = nil }
        }
        .onChange(of: sleepMinutes) { sleepTimeSet(sleepMinutes) }
        .task {
            let opened = title
            // **No next episode in a group.** Everyone would otherwise advance on their own
            // and the group would drift apart.
            await episodesSwitch.lookUp(fetch: { await model.episodePost(opened) },
                                             adopt: { nextEpisode = sharedAn ? nil : $0 })
            await episodesSwitch.lookUp(fetch: { await model.sections(for: opened.id) },
                                             adopt: { sections = $0 })
        }
        // Check once per title whether the server has thumbnails.
        .task(id: title.id) { await trickplay.load(model: model, item: title, plan: plan) }
        // **Per version, not per title**: a director's cut has different chapters. Until
        // they arrive, the scrubber shows none from another version.
        .task(id: [title.id, plan.mediaSourceID]) {
            chapter = []   // also when only the version changes, without a new title
            let found = await model.chapter(for: title.id, source: plan.mediaSourceID)
            guard !Task.isCancelled else { return }
            chapter = found
        }
        // Have the next-episode image ready for a possible handoff; the giving side's
        // card needs it in the first frame (``Uebergabeabgang``).
        .task(id: title.id) { await HandoffExit.preload(title, model: model) }
        .onDisappear {
            HandoffStage.shared.playerDistance(title.id)
            idleTask?.cancel()
            sleepTask?.cancel()
            holder.cleanUp()
            hub.handIn()
            model.remoteCommand = nil
            // Closing means leaving (design A).
            if sharedAn { gemeinsam.detach() }
            // Without closing `finish()`: window closed, account or server switch. A running
            // switch must not apply anything afterwards, and the server still learns about
            // the end. If `finish` came first, its call counts and this one
            // does nothing.
            tally(at: state.position)
            episodesSwitch.close(stopNow: stopMessage(at: state.position))
            // The pointer must come back as soon as the player is gone.
            NSCursor.unhide()
            model.playerOpen = false
        }
        .task { await withRun() }
        // **Safeguard, not a fix for a proven bug:** whether SwiftUI reliably calls
        // `onDisappear` when the window closes (Cmd-W) has not been measured. If the
        // window closes during playback, this silences the audio and reports position and
        // end, using the same calls as in `finish()`, which do nothing a second time
        // (`zaehlen` is once-only, `pause` is cheap).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { n in
            guard let window = n.object as? NSWindow, window === holder.window else { return }
            let spot = state.position
            tally(at: spot)
            area?.pause()
            episodesSwitch.close(stopNow: stopMessage(at: spot))
        }
        // The "Wiedergabe" menu: the same actions as the keys.
        .onReceive(NotificationCenter.default.publisher(for: CommandPost.name)) { post in
            guard openLayer == nil, let command = CommandPost.receive(post) else { return }
            switch command {
            case .playToggle: toggle()
            case .playBack: vault(-Double(model.backSeconds))
            case .playForward: vault(Double(model.forwardSeconds))
            case .playPause: if runsNow { toggle() }
            case .playFullscreen: holder.fullscreenToggle()
            case .louder: volumeLevel(0.05)
            case .quieter: volumeLevel(-0.05)
            case .muted: volumeMuted(); volumeShortShow()
            default: break
            }
        }
        // Keyboard shortcuts. They also appear in the menu bar so they can be found
        // without knowing them.
        .background {
            VStack {
                // **While a layer is open, the keys belong to it.**
                //
                // These buttons sit invisibly in the background and therefore always applied,
                // even while a layer was open. Anyone browsing audio tracks paused the film with
                // space and jumped around in it with the arrows.
                //
                // Escape stays: it then closes the layer, not the player. First close the
                // selection, then leave.
                Group {
                    Button("") { toggle() }.keyboardShortcut(.space, modifiers: [])
                    Button("") { vault(-Double(model.backSeconds)) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { vault(Double(model.forwardSeconds)) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .disabled(openLayer != nil)
                // Volume: up/down arrows +/-5%, M mutes.
                Group {
                    Button("") { volumeLevel(0.05) }.keyboardShortcut(.upArrow, modifiers: [])
                    Button("") { volumeLevel(-0.05) }.keyboardShortcut(.downArrow, modifiers: [])
                    Button("") { volumeMuted(); volumeShortShow() }
                        .keyboardShortcut("m", modifiers: [])
                }
                .disabled(openLayer != nil)
                // **Delay as in VLC:** G/H subtitles, J/K audio, 50 ms each. Not while a layer is
                // open: the row is displayed there and would not know about the key press.
                Group {
                    Button("") { postpone(subtitle: true, -1) }.keyboardShortcut("g", modifiers: [])
                    Button("") { postpone(subtitle: true, 1) }.keyboardShortcut("h", modifiers: [])
                    Button("") { postpone(subtitle: false, -1) }.keyboardShortcut("j", modifiers: [])
                    Button("") { postpone(subtitle: false, 1) }.keyboardShortcut("k", modifiers: [])
                }
                .disabled(openLayer != nil || area == nil)

                Button("") { escapeKey() }.keyboardShortcut(.escape, modifiers: [])
                // As on a TV without focus: when the overlay is showing, Return triggers it
                // (Jellyfin Android TV).
                Button("") { if offeringPresent, layer.display.visible { offeringRun() } }
                    .keyboardShortcut(.return, modifiers: [])
                // Full screen without having to hit the button; the same key the window traffic
                // lights offer.
                Button("") { holder.fullscreenToggle() }.keyboardShortcut("f", modifiers: [])
                // "Small window" is currently removed from the UI; the shortcut goes with it,
                // otherwise there would be a way in with no way back.
                Button("") { }
                    .keyboardShortcut("p", modifiers: [.command, .option])
            }
            .opacity(0)
        }
    }

    private var startScrim: some View {
        ZStack {
            Color.black
            Loader()
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    // MARK: - Header, middle, footer

    /// For an episode the series, otherwise the title itself; the same rule as iOS.
    private var titleLine: String {
        if title.type == "Episode", let series = title.seriesName, !series.isEmpty { return series }
        return title.name
    }

    /// "Season 1 - Episode 3" (shown in the UI as "Staffel 1 · Folge 3"); for a movie
    /// year, runtime and genre.
    private var metaText: String? {
        if title.type == "Episode" {
            if let season = title.parentIndexNumber, let episode = title.indexNumber {
                return String(localized: "Staffel \(season) · Folge \(episode)")
            }
            return title.contextLine
        }
        let row = title.secondaryLine
        return row.isEmpty ? nil : row
    }

    /// Only episodes of a series have an episode list.
    private var hasEpisodes: Bool { title.type == "Episode" && title.seriesId != nil }

    /// **Title at the top left, only icons at the top right.** No Picture in Picture
    /// button and no speed control. While scrubbing the icons make way for the
    /// preview.
    private var iconRail: some View {
        HStack(spacing: 4) {
            VolumeSlider(mass: mass, value: $volume,
                              expanded: volumeShort, pulls: $volumePulls,
                              mutedToggle: volumeMuted,
                              wheelRotated: { volumeWheel($0) })
            IconButton(symbol: "captions.bubble", label: "Audio & Untertitel",
                        mass: mass) { unfoldLayer(.tracks) }
            if hasEpisodes {
                IconButton(symbol: "rectangle.stack", label: "Folgen",
                            mass: mass) { unfoldLayer(.episodes) }
            }
            IconButton(symbol: "slider.horizontal.3", label: "Einstellungen",
                        mass: mass) { unfoldLayer(.settings) }
            IconButton(symbol: holder.isFullscreen ? "arrow.down.right.and.arrow.up.left"
                                                    : "arrow.up.left.and.arrow.down.right",
                        label: holder.isFullscreen ? "Vollbild verlassen" : "Vollbild",
                        mass: mass) { holder.fullscreenToggle() }
            handOverMenu
            IconButton(symbol: "xmark", label: "Player schließen",
                        mass: mass) { finish() }
        }
    }

    /// **"Übergeben an …"**: the TVs a film can be sent to, see ``PlayOutputs``.
    /// Not in a group: the group watches here, and handing over would leave it
    /// without a word.
    @ViewBuilder private var handOverMenu: some View {
        let targets = PlayOutputs.shared.targets.compactMap(PlayOutput.init(session:))
        if !inGroup, !targets.isEmpty {
            Menu {
                Section {
                    ForEach(targets, id: \.deviceID) { target in
                        Button { handOver(to: target) } label: {
                            Label { Text(verbatim: target.name) } icon: { Image(systemName: "tv") }
                        }
                    }
                } header: {
                    Text("Übergeben an …")
                }
            } label: {
                Image(systemName: "tv")
                    .font(.system(size: mass.symbol, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: mass.button, height: mass.button)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Übergeben an …"))
            .accessibilityLabel(Text("Übergeben an …"))
        }
    }

    /// **Send the running title to the TV and leave**, at this position, with these
    /// tracks. Paused at once so the TV does not start behind where this device has
    /// got to; if the TV does not take it, it plays on here. The exit is the
    /// takeover's (``HandoffExit``).
    private func handOver(to target: PlayOutput) {
        guard !handoverRuns, let area else { return }
        let spot = state.position
        let wasRunning = state.running
        area.pause()
        Task {
            let taken = await PlayOutputs.shared.handOver(title, plan: plan, at: spot,
                                                          tracks: model.playingTracks,
                                                          to: target, model: model)
            guard taken else {
                if wasRunning { resume() }
                return
            }
            handIn(an: target.name, area: area)
        }
    }

    /// **The title at the top left, a layer above everything.** With the episode layer
    /// open it stays exactly here; if it were part of the header it would fade out
    /// with the controls and back in inside the layer, flickering. Same as
    /// `stateTitle` on iOS.
    private var stateTitle: some View {
        let present = (controlsPresent && openLayer == nil) || openLayer == .episodes
        return HStack(alignment: .top, spacing: 12) {
            Text(verbatim: titleLine)
                .font(.system(size: mass.title, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            iconRail
                .hidden()
                .accessibilityHidden(true)
        }
        .padding(.horizontal, mass.page)
        .padding(.top, mass.top)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .opacity(present ? 1 : 0)
        .animation(present ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.34), value: present)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // Placeholder only: what is shown is the title from `stateTitle`, which stays
                // put while the episode layer is open.
                Text(verbatim: titleLine)
                    .font(.system(size: mass.title, weight: .semibold))
                    .lineLimit(1)
                    .opacity(0)
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    // **In a group the group is shown here** (design A), where year and runtime
                    // otherwise go. It is state, hence accent.
                    if inGroup, let group = gemeinsam.group {
                        GroupsRow(name: group.name, withWhom: gemeinsam.withWhom,
                                     size: mass.meta)
                    } else if let metaText { Text(verbatim: metaText) }
                    if !plan.isLossless {
                        Label(plan.method.rawValue, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    }
                }
                .font(.system(size: mass.meta))
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
            }
            .foregroundStyle(.white)

            Spacer(minLength: 0)

            iconRail
                .opacity(atSlider ? 0 : 1)
                .allowsHitTesting(!atSlider)
        }
        .padding(.horizontal, mass.page)
        .padding(.top, mass.top)
        .overlay(alignment: .bottom) {
            // Below the header row, centered: there it gets in the way of neither the
            // scrubber nor the skip button.
            if let hint {
                Text(verbatim: hint)
                    // `.caption2` is 11 regular; 11 exists in the scale only as semibold. A sentence
                    // is information, so 12.
                    .font(Theme.small).foregroundStyle(Theme.font)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, mass.page)
                    .offset(y: 22)
            }
        }
    }

    private func unfoldLayer(_ target: PlayerLayer) {
        openLayer = target
    }

    private func layerClose() {
        openLayer = nil
    }

    @ViewBuilder
    private func layersView(_ which: PlayerLayer) -> some View {
        switch which {
        case .tracks:
            TracksLayer(area: area, mass: mass, close: layerClose)
        case .settings:
            SettingLayer(area: area, mass: mass, sleepMinutes: $sleepMinutes,
                              quality: qualitySelection,
                              gemeinsam: inGroup ? gemeinsam : nil,
                              groupLeave: { finish() },
                              close: layerClose)
        case .episodes:
            EpisodesLayer(model: model, item: title, title: titleLine, mass: mass,
                        close: layerClose) { episode in
                layerClose()
                // Clicking the current episode means: keep watching.
                guard episode.id != title.id else { return }
                // In a group nobody switches alone: the choice sets the queue and everyone loads
                // the episode (as on iOS).
                if inGroup { gemeinsam.bitTitle(episode.id); return }
                toNextEpisode(episode)
            }
        }
    }

    /// Centered in the picture. The mouse has to go there anyway, unlike a thumb
    /// resting at the edge.
    private var centerControls: some View {
        HStack(spacing: 80) {
            JumpButton(symbol: "gobackward.\(model.backSeconds)", large: 30, tick: tickBack,
                        label: "\(model.backSeconds) Sekunden zurück") {
                vault(-Double(model.backSeconds))
            }
            JumpButton(symbol: runsNow ? "pause.fill" : "play.fill", large: 40, snappy: true,
                        label: runsNow ? "Anhalten" : "Abspielen") { toggle() }
            // Forward goes further than back: forward skips intros and ads, backward looks
            // for a line of dialogue.
            JumpButton(symbol: "goforward.\(model.forwardSeconds)", large: 30, tick: tickPre,
                        label: "\(model.forwardSeconds) Sekunden vor") {
                vault(Double(model.forwardSeconds))
            }
        }
    }

    /// Only the scrubber, full width: elapsed time on the left, remaining time on the
    /// right.
    private var footer: some View {
        TimeRow(position: $state.position, duration: state.duration, atSlider: $atSlider,
                  mass: mass, marks: sections.flatMap { [$0.from, $0.until] }, chapter: chapter,
                  preview: { trickplay.image(at: $0, model: model) }) { target in
            if inGroup { gemeinsam.bitJump(on: target) }
            else { area?.seek(toSeconds: target) }
            jumped(on: target)
        }
        .padding(.horizontal, mass.page)
        .padding(.bottom, mass.bottom)
    }

    private var offeringButton: some View {
        OfferingButton(offering: offering, action: offeringRun)
            .accessibilityAction(.escape) { _ = layer.close() }
    }

    // MARK: Actions

    /// When time runs out, playback is paused and the reason is given, not silently
    /// stopped. Same as the iPhone version.
    private func sleepTimeSet(_ minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes else { return }
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            area?.pause()
            controlsShow()
            notify(String(localized: "Schlafzeit abgelaufen."))
        }
    }

    /// Click on the speaker and key M: mute, and a second time restore the previous
    /// value.
    private func volumeMuted() {
        if volume > 0 {
            volumePrior = volume
            volume = 0
        } else {
            volume = volumePrior > 0 ? volumePrior : 1
        }
    }

    private func volumeLevel(_ step: Double) {
        volume = min(max((volume + step).rounded(toPlaces: 2), 0), 1)
        volumeShortShow()
    }

    /// Mouse wheel over the slider: continuous, unrounded, 0 to 1.
    private func volumeWheel(_ step: Double) {
        volume = min(max(volume + step, 0), 1)
        volumeShortShow()
    }

    /// Opens the slider for 1.2 s and holds the controls open so the value is visible.
    private func volumeShortShow() {
        controlsShow()
        volumeShort = true
        volumeClock?.cancel()
        volumeClock = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            volumeShort = false
        }
    }

    private func toggle() {
        guard let area else { return }
        // In a group this is a request: the button flips only when the command comes
        // back, then simultaneously for everyone.
        if inGroup {
            gemeinsam.bitToggle(runningCurrently: runsNow)
            controlsShow()
            return
        }
        if area.isPlaying { area.pause() } else { resume() }
        controlsShow()
    }

    /// Resume at the viewer's request, after a long pause a little way back
    /// (``Pausenruecksprung``), as on iPhone. The time takes the target at once so the
    /// scrubber does not first show the old position. In a group this is not reached:
    /// there resuming is a request.
    private func resume() {
        guard let target = area?.resume(jumpBack: !inGroup) else { return }
        jumped(on: target)
    }

    private func vault(_ seconds: Double) {
        let target = PlaybackTick.target(um: seconds, state: state)
        if inGroup {
            // Request to the group; the seek happens when the command arrives.
            gemeinsam.bitJump(on: max(0, target))
        } else {
            area?.jump(seconds: Int32(seconds))
        }
        jumped(on: target)
        controlsShow()

        if seconds < 0 { tickBack += 1 } else { tickPre += 1 }
        jumpTick += 1
        let tick = jumpTick
        // **Pressed repeatedly, it counts up**: +10 s, +20 s, +30 s, as long as the
        // display of the previous seeks in the same direction is still showing. Same rule
        // as double-tap on iPhone, here for arrow keys and buttons.
        let bearing = seconds < 0 ? -1 : 1
        let untilFrom = jumpDisplay.flatMap { $0.bearing == bearing ? $0.seconds : nil } ?? 0
        withAnimation(.easeInOut(duration: 0.15)) {
            jumpDisplay = (bearing, untilFrom + Int(abs(seconds)))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard jumpTick == tick else { return }
            withAnimation(.easeInOut(duration: 0.15)) { jumpDisplay = nil }
        }
    }

    /// What another device triggers here.
    ///
    /// The same handlers as in ``hubAdopt``, but over Jellyfin's socket
    /// instead of the media keys. `.stop` closes the player, which handoff relies
    /// on: closed there, continuing here.
    private func execute(_ command: RemoteCommand) {
        if inGroup {
            switch command {
            case .pause:  if runsNow { gemeinsam.bitToggle(runningCurrently: true) }
            case .proceed: if !runsNow { gemeinsam.bitToggle(runningCurrently: false) }
            case .toggle: toggle()
            case .stop: finish()
            case let .jumpOn(seconds):
                gemeinsam.bitJump(on: seconds)
                jumped(on: seconds)
            case .forward:     vault(Double(model.forwardSeconds))
            case .back: vault(-Double(model.backSeconds))
            case .next, .previous: break
            }
            controlsShow()
            return
        }
        switch command {
        case .pause:     area?.pause()
        case .proceed:    resume()
        case .toggle: toggle()
        // **Another device takes over** (hint arrived shortly before): the picture leaves
        // as a card. Otherwise (dashboard, other app) as usual.
        case .stop:
            if let target = model.handoffTargetTake(), let area { handIn(an: target, area: area) }
            else { finish() }
        case let .jumpOn(seconds):
            area?.seek(toSeconds: seconds)
            jumped(on: seconds)
        case .forward:       vault(Double(model.forwardSeconds))
        case .back:   vault(-Double(model.backSeconds))
        case .next:
            if let episode = nextEpisode { toNextEpisode(episode) }
        case .previous:    break
        }
        controlsShow()
    }

    /// **Every seek:** time and button immediately show the target, and the tick hands
    /// back to VLC's time once VLC is there (a seek-confirmation bug).
    private func jumped(on target: Double) {
        PlaybackTick.jumped(&state, target: target)
        // A seek into the outro or to the end restarts the card's countdown, as on
        // iPhone (seeked to the end, advance immediately).
        layer.jumped()
        if countdownShare != nil { fillClock = FillClock() }
        offeringCatchUp(elapsed: 0)
    }

    /// Adjust the overlay to the displayed position: with `elapsed: 0` right after a
    /// seek, otherwise once per tick.
    @discardableResult
    private func offeringCatchUp(elapsed: Double) -> Bool {
        guard !switches else { return false }
        var new = layer
        let done = new.tick(offering: offering,
                          cardDue: SectionLogic.cardDue(position: state.position,
                                                                     duration: state.duration,
                                                                     sections: sections,
                                                                     hasNextEpisode: nextEpisode != nil,
                                                                     remainingWindow: EpisodeCard.remainingWindow),
                          running: state.running && screenDistance && !atSlider,
                          elapsed: elapsed,
                          countdown: SectionLogic.countdown(position: state.position, duration: state.duration,
                                                               sections: sections,
                                                               remainingWindow: EpisodeCard.remainingWindow),
                          // At the end of the file the countdown keeps running.
                          atEnd: EpisodeEnd.atEnd(position: state.position, duration: state.duration)
                              && !atSlider)
        // When the skip button hides by itself (`buttonDuration`) it should leave as softly as
        // it came. The tick runs without animation, so the visibility change is animated
        // explicitly here.
        if new.display.visible != layer.display.visible {
            withAnimation(Theme.reveal) { layer = new }
        } else {
            layer = new
        }
        fillSet()
        return done
    }

    private func fillSet() {
        fillClock.set(share: countdownShare, running: state.running && screenDistance && !atSlider,
                             length: layer.countdownLength)
    }

    /// Which button currently applies. Same rule as on iOS.
    private var offering: ButtonOffering {
        guard !switches else { return .nobody }
        return SectionLogic.offering(position: state.position, duration: state.duration,
                                       sections: sections,
                                       hasNextEpisode: nextEpisode != nil)
    }

    /// **One place, whether or not the controls are open** (as iOS): while the section
    /// runs, skipping; with the controls closed the card, with them open the normal
    /// "Next episode" button.
    private var offeringPresent: Bool {
        guard offering.visible, screenDistance, !switches, openLayer == nil else { return false }
        return layer.display.visible || (controlsPresent && offering == .nextEpisode)
    }

    private var countdownShare: Double? {
        if case let .card(share) = layer.display { return share }
        return nil
    }

    /// The next-episode card is up (or just zooming).
    private var cardPresent: Bool {
        cardsSwitch != nil || (offeringPresent && countdownShare != nil)
    }

    /// The pill at the bottom right, not while the card is there.
    private var buttonPresent: Bool {
        offeringPresent && countdownShare == nil && cardsSwitch == nil
    }

    /// The scrim lies on the picture while the controls are open, and while the card
    /// is up so that it reads in the foreground.
    private var dimmed: Bool {
        (controlsPresent && openLayer == nil) || (cardPresent && cardsSwitch == nil)
    }

    /// Springs from the design, critically damped (``EpisodeCard``).
    private static func spring(_ omega: Double) -> Animation {
        if Theme.motionReduced { return Theme.fadeReduced }
        let f = EpisodeCard.spring(omega)
        return .interpolatingSpring(mass: 1, stiffness: f.stiffness, damping: f.damping)
    }

    /// The card at the bottom right stays in the tree as long as there is a next
    /// episode, so entering and leaving are springs from the current state.
    @ViewBuilder
    private var cardsLayer: some View {
        if screenDistance || cardsSwitch != nil, let episode = cardsEpisode ?? nextEpisode, !inGroup {
            EpisodeCardsView(
                episode: episode,
                imageAddress: model.imageURL(for: episode, maxHeight: 1080)
                    ?? model.landscapeImageURL(for: episode, width: 1920),
                mass: mass,
                present: cardPresent, zoom: cardsZoom,
                detailsPresent: cardPresent && cardsSwitch == nil,
                image: cardImage,
                fillContent: cardsClock ?? fillClock,
                rest: layer.countdownRest,
                onTap: {
                    layer.pressed()
                    toNextEpisode(episode, fromCard: true)
                },
                cancel: cardCancel)
            .allowsHitTesting(cardPresent && cardsSwitch == nil)
            .animation(cardPresent ? Self.spring(EpisodeCard.appearOmega)
                                .delay(cardsSwitch == nil ? EpisodeCard.appearLag : 0)
                               : Self.spring(EpisodeCard.distanceOmega),
                       value: cardPresent)
        }
    }

    /// Watch the credits: countdown gone, no auto-advance at the end of the file
    /// (`OfferingLayer.nextCancelled`). X on the card, Esc, drag away.
    private func cardCancel() {
        layer.close()
        fillSet()
    }

    /// The setting "Skip intro and outro automatically": the same step as the press on the button, once per section.
    private func autoSkipRun() {
        guard autoSkip, !switches, state.running, screenDistance,
              let step = SectionLogic.automatic(position: state.position, duration: state.duration,
                                                sections: sections,
                                                hasNextEpisode: nextEpisode != nil),
              autoSkipped.insert(step.segment.from).inserted
        else { return }
        offeringRun()
    }

    private func offeringRun() {
        layer.pressed()
        switch offering {
        case .nobody:
            break
        case let .skip(to, _):
            if inGroup { gemeinsam.bitJump(on: to) }
            else { area?.seek(toSeconds: to) }
            jumped(on: to)
            controlsShow()
        case .nextEpisode:
            // From the card (Return) it zooms into the picture, from the pill of the open
            // controls it does not.
            if let episode = nextEpisode { toNextEpisode(episode, fromCard: cardPresent) }
        }
    }

    /// The stop for whatever is running now, only if its start was reported. Once for
    /// `finish` and once for disappearing without it.
    private func stopMessage(at spot: Double) -> @Sendable () async -> Void {
        let ongoing = (item: title, plan: plan, reported: state.startReported)
        let model = model
        return {
            guard ongoing.reported else { return }
            await model.reportStopped(item: ongoing.item, plan: ongoing.plan, seconds: spot)
        }
    }

    /// Watched to the end? Counts for rating and the Discord hint
    /// (`AppModel.doneWatch`), once per title.
    private func tally(at spot: Double) {
        guard counted != title.id else { return }
        counted = title.id
        model.doneWatch(position: spot, duration: state.duration)
    }

    /// **Playback goes to another device** (``Uebergabeabgang``). The position goes to
    /// the server immediately (the other side waits for it), the controls go away, the
    /// picture stops at 0.12 s and leaves as a card; then the player closes as usual.
    private func handIn(an target: String, area: VLCPlayerView) {
        guard !handoverRuns else { return }
        handoverRuns = true
        let spot = state.position
        Task { await stopMessage(at: spot)() }
        var without = Transaction()
        without.disablesAnimations = true
        withTransaction(without) { controlsPresent = false }
        HandoffExit.start(area: area, target: target, title: title, model: model,
                                halt: { area.pause() },
                                done: { finish() })
    }

    private func finish() {
        // Read **before** pausing; afterwards the time is zero and "Continue watching"
        // would lose the position.
        let spot = state.position
        tally(at: spot)

        // First remove the OpenGL surface, otherwise it stays as a black rectangle while
        // the page above slides down.
        areaOut = true

        // **Pause now, tear down later.**
        //
        // This used to call `area?.stop()` right before `close()`. `stop` tears
        // down the decoder and visibly takes time, on the main thread, in the same
        // operation in which the downward motion starts. That is why opening was smooth
        // and closing was abrupt: opening has nothing to tear down.
        //
        // `pause` is cheap and silences the audio immediately. Teardown follows once the
        // motion is done.
        area?.pause()

        // About the switch: if one is running it is aborted, and if the new episode's
        // start is on its way, the stop follows after it.
        episodesSwitch.close(stopNow: stopMessage(at: spot))
        close()
        // Teardown happens in `MacVideoSurface.dismantleNSView`, i.e. when SwiftUI really
        // removes the view, after the motion. A separate timer for this was a guess and
        // only roughly hit the moment.
    }

    /// Esc first leaves an open layer, then full screen, and only then closes the
    /// film. The other way round, trying to leave full screen would lose playback,
    /// which matters in the middle of a film.
    private func escapeKey() {
        // **First the selection, then the player.** Back first means "this layer closes",
        // The same rule as on iOS and tvOS.
        if openLayer != nil {
            layerClose()
            return
        }
        // Then the overlay; the film keeps running.
        if offeringPresent, layer.display.visible {
            layer.close()
            fillSet()
            return
        }
        if holder.isFullscreen {
            holder.fullscreenToggle()
        } else {
            finish()
        }
    }

    /// Four seconds of quiet, then it withdraws, but not while paused. Same rule as on
    /// iPhone. The second variant has no four seconds, for when the pointer leaves
    /// the window.
    private func controlsImmediateDistance() {
        // Here too an open layer stays. Moving the pointer out of the window is no reason
        // to clear a decision that is being made.
        guard openLayer == nil else { return }
        idleTask?.cancel()
        withAnimation(.easeInOut(duration: 0.34)) {
            controlsPresent = false
            holder.setControls(false)
        }
    }

    /// `.deliberate` (click, key, button) dismisses a running "Next episode" card,
    /// `.beside` (pointer movement) does not.
    private func controlsShow(through art: OfferingLayer.Opening = .deliberate) {
        withAnimation(.easeOut(duration: 0.18)) { controlsPresent = true }
        layer.controls(opened: true, through: art)
        fillSet()
        holder.setControls(true)
        NSCursor.unhide()
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .seconds(4))
            // **While a layer is open, nothing is taken away.**
            //
            // It used to be part of the hiding: anyone who opened settings and left the mouse
            // alone saw everything vanish after four seconds, the selection included. An
            // open layer counts as attention, like a hand on the slider.
            //
            // The timer restarts after closing (see below). This latch sits after the sleep,
            // so the task ends here without starting a new one.
            guard !Task.isCancelled, state.running, !atSlider, !volumePulls, openLayer == nil else { return }
            withAnimation(.easeInOut(duration: 0.34)) {
                controlsPresent = false
                holder.setControls(false)
            }
            // The pointer goes along. `setHiddenUntilMouseMoves` is the right way, not
            // `hide()`: it comes back by itself on the next movement without us having to
            // re-enable it, and it does not stay hidden if the app crashes.
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// Now Playing and the keyboard's media keys. Both go through
    /// `MPRemoteCommandCenter`, which needs nothing special on the Mac.
    private func hubAdopt() {
        sinceStart = Date()
        // In a group, media keys go out as requests; the group is asked at press time,
        // not when the handlers are created.
        hub.adopt(.init(
            play: { if inGroup { gemeinsam.bitToggle(runningCurrently: false) }
                         else { resume() } },
            halt:  { if inGroup { gemeinsam.bitToggle(runningCurrently: true) }
                         else { area?.pause() } },
            toggle: { toggle() },
            jumpOn: { target in
                if inGroup { gemeinsam.bitJump(on: target); jumped(on: target) }
                else { area?.seek(toSeconds: target); jumped(on: target) } },
            forward:     { vault(Double(model.forwardSeconds)) },
            back: { vault(-Double(model.backSeconds)) },
            next: inGroup ? nil : nextEpisode.map { episode in { toNextEpisode(episode) } }))
    }

    /// Switches inside the running player without returning to the overview.
    ///
    /// **The sequence lives in the package** (`EpisodeSwitch`), shared with iOS and
    /// tvOS. Here the switch used to reset the state only after `await reportStart`;
    /// if a report tick fell in between, the **new** episode got the old episode's
    /// position as resume position, and the loading screen did not come
    /// back.
    /// Direct Play or cap: only when playing from the server and the account may
    /// transcode.
    private var qualitySelection: QualitySelection? {
        // **No choice in a group** (as iOS): the switch used to reload the title past the
        // group, after which one continued alone.
        guard model.downloads.file(for: title.id) == nil, model.convertAllowed,
              !inGroup else { return nil }
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
            AppLog.writeOut("[Qualität] \(model.alwaysDirectPlay ? "Direct Play" : "\(model.bitratesLimit) Mbit/s") — neu laden bei \(Int(state.position)) s")
            let spot = state.position
            layerClose()
            // A prepared plan for the next episode carries the old choice.
            preparation.forget()
            qualitySwitched = true
            toNextEpisode(title, since: spot)
        }
    }

    private func toNextEpisode(_ episode: Item, since: Double = 0, fromCard: Bool = false) {
        guard !switches else { return }
        switches = true
        // **From the card: it zooms to the whole picture** and covers the switch (as
        // iOS). Not in a group, not for the same episode (quality choice).
        let zooms = fromCard && !inGroup && episode.id != title.id
        if zooms {
            cardsEpisode = episode
            cardsClock = fillClock
            cardsSwitch = CardsSwitch(episodeID: episode.id)
            AppLog.writeOut("[Karte] Start → \(episode.id)")
            withAnimation(Self.spring(EpisodeCard.zoomOmega)) { cardsZoom = 1 }
            if let beginning = cardsSwitch?.beginning { Task { await cardGuard(beginning) } }
        }
        let swapOff = zooms ? Date().addingTimeInterval(EpisodeCard.swap) : nil
        tally(at: state.position)
        let alt = (item: title, plan: plan, spot: state.position)
        // Already fetched in the last minutes (``EpisodePreparation``)? Then the switch
        // does not wait for the server again.
        let prepared = preparation.take(episode.id)
        AppLog.writeOut("[Wechsel] Beginn → \(episode.id) · Plan vorbereitet: \(prepared != nil ? "ja" : "nein")")
        Task {
            let result = await episodesSwitch.execute(.init(
                stopNow: { await model.reportStopped(item: alt.item, plan: alt.plan,
                                                     seconds: alt.spot) },
                planOut: {
                    let newPlan: PlaybackPlan?
                    if let prepared { newPlan = prepared }
                    else { newPlan = await model.plan(for: episode.id) }
                    // Only swap once the card covers the picture; otherwise black would show around
                    // it.
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
                    notify(String(localized: "Nächste Folge konnte nicht geladen werden."))
                    // The old episode keeps playing, but the server already considers it finished.
                    // The loop reports it again.
                    state.startReported = false
                }))
            AppLog.writeOut("[Wechsel] \(result) → \(episode.id)")
            // **The switch is done here, so the latch is released here**, not after the
            // follow-up. While it is held there are no buttons, and a good minute without
            // buttons feels dead.
            switches = false
            guard result == .switched else {
                if cardsSwitch != nil { cardBack() }
                return
            }
            await episodesSwitch.lookUp(fetch: { await model.episodePost(episode) },
                                             adopt: { nextEpisode = sharedAn ? nil : $0 })
            await episodesSwitch.lookUp(fetch: { await model.sections(for: episode.id) },
                                             adopt: { sections = $0 })
            // **Stays at the end.** The hub carries the "next episode" command, which needs
            // `nextEpisode`.
            hubAdopt()
        }
    }

    /// The first frame of the new episode is up: the preview image fades out, with the
    /// episode already playing underneath, from the swap at the earliest.
    private func cardHandOver() async {
        guard let k = cardsSwitch, let imageSince = k.imageSince else { return }
        let wait = EpisodeCard.fadeOff(imageSince: imageSince) - k.since
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        withAnimation(Theme.motionReduced ? Theme.fadeReduced
                      : .easeInOut(duration: EpisodeCard.imageFade)) { cardImage = 0 }
        try? await Task.sleep(for: .seconds(EpisodeCard.imageFade))
        guard cardsSwitch?.beginning == k.beginning else { return }
        AppLog.writeOut("[Karte] Ende nach \(Int(k.since * 1000)) ms")
        cardCleanUp()
    }

    /// The switch failed: the card goes back to the corner and out.
    private func cardBack() {
        AppLog.writeOut("[Karte] Wechsel gescheitert, zurück")
        withAnimation(Self.spring(EpisodeCard.distanceOmega)) { cardsZoom = 0 }
        cardCleanUp()
    }

    /// **Without a first frame the card yields to the loading screen.** While it is
    /// zoomed there are neither controls nor loading screen, hence no way out; if the
    /// frame does not arrive (``Folgenkarte/weicht``), the regular loading screen,
    /// including close, takes over. The switch continues underneath.
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

    /// Take over the new episode **before** `play` and before any `await`.
    /// Track selection for opening: the same inputs as `wendeLanguagesAn`, but already
    /// before `play` so that VLC starts with the right track.
    private func trackRequest(_ title: Item, _ plan: PlaybackPlan) -> VLCPlayerView.TrackRequest {
        VLCPlayerView.TrackRequest(audio: model.audioLanguage, subtitle: model.subtitleLanguage,
                                 automatic: model.subtitleAutomatic, source: plan.source,
                                 title: TrackMemory.title(for: title),
                                 ordered: title.id == beginning.item.id ? beginning.tracks : nil)
    }

    private func episodeApply(_ episode: Item, _ newPlan: PlaybackPlan, since: Double = 0) {
        if let cardsSwitch {
            AppLog.writeOut("[Karte] Tausch nach \(Int(cardsSwitch.since * 1000)) ms")
        }
        // Delay: the same series keeps it, otherwise zero.
        area?.delayForNewTitle(oldTitle: title.id, oldSeries: title.seriesId,
                                            newTitle: episode.id, addedSeries: episode.seriesId)
        title = episode
        plan = newPlan
        // A cap was chosen but the original is playing: either the file already fits or
        // the server does not transcode. Say so instead of staying silent.
        if qualitySwitched {
            qualitySwitched = false
            if !model.alwaysDirectPlay, newPlan.method == .directPlay {
                notify(String(localized: "Läuft in Originalqualität. Der Server wandelt nichts um."))
            }
        }
        // Reset position, tracks, start report and first frame; `true` because the switch
        // reports the start.
        PlaybackTick.newTitle(&state, startReported: true)
        // **Starting mid-episode is a seek**, as on iOS.
        if since > 0 { jumped(on: since) }
        // The loading screen returns until VLC shows the new episode.
        screenDistance = false
        // **The clock too.** Without it `TimeAssumption` takes the new episode for an old,
        // long-settled title. On tvOS exactly this skipped an episode.
        // (`hubAdopt` sets it as well.)
        sinceStart = Date()
        // **Nothing points at the old episode any more**.
        nextEpisode = nil
        sections = []
        autoSkipped = []
        chapter = []
        layer.newEpisode()
        hubAdopt()
        // **Here too before `play`.** Without it the next episode would keep the buffer
        // level from opening.
        area?.buffer = model.bufferLevel
        area?.trackRequest = trackRequest(episode, newPlan)
        area?.play(url: newPlan.url, offSeconds: since, container: newPlan.container,
                      subtitle: model.subtitleFiles(newPlan),
                      softwareDecoder: newPlan.softwareDecoder)
    }

    /// Shortcuts G/H/J/K: shift one step and announce the new value.
    private func postpone(subtitle: Bool, _ bearing: Int) {
        guard let area else { return }
        if subtitle {
            area.subtitleDelay = area.subtitleDelay.shifted(bearing)
            notify(String(localized: "Untertitelverzögerung \(area.subtitleDelay.text())"))
        } else {
            area.audioDelay = area.audioDelay.shifted(bearing)
            notify(String(localized: "Tonverzögerung \(area.audioDelay.text())"))
        }
    }

    /// Writes the current state into the bridge to the group and gives it the tick;
    /// see ``Gemeinsamspieler`` for why an object and not a closure.
    private func bridgeCatchUp() {
        bridge.area = area
        bridge.titleID = title.id
        bridge.isReady = (area?.startReady ?? false) && screenDistance && !switches
        bridge.jumpShow = { target in jumped(on: target) }
        bridge.switchTitle = { episode, _, since in toNextEpisode(episode, since: since) }
        gemeinsam.playerTick()
    }

    private func notify(_ text: String) {
        hint = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { hint = nil }
        }
    }

    /// One tick every half second; the rules live in `PlaybackTick`, shared with
    /// iPhone and TV. This only holds **how** the Mac executes the four jobs.
    private func withRun() async {
        var beats = 0
        var onlyTime = false
        while !Task.isCancelled {
            try? await Task.sleep(for: PlaybackTick.displayTick)
            guard let area else { continue }
            if sharedAn { bridgeCatchUp() }

            // **In between, only the time**, as on iOS: running on the half-second tick it
            // started late and advanced unevenly.
            onlyTime.toggle()
            if onlyTime {
                if !switches {
                    PlaybackTick.timeAdopt(&state, reported: area.positionSeconds,
                                                   atPush: atSlider, sinceStart: sinceStart)
                }
                continue
            }

            // Whether VLC is at the target of a seek is decided by `PlaybackTick` based on
            // `state.sprung`.

            let job = PlaybackTick.compute(
                &state,
                measurement: .init(duration: area.durationSeconds,
                               position: area.positionSeconds,
                               goodPoint: area.goodPoint,
                               showsImage: area.showsImage,
                               seeksToStart: area.seeksToStart,
                               running: area.isPlaying,
                               // **Read the track list only while it is needed.** `PlaybackTick` asks
                               // `hasAudioTracks` alone until the tracks are set; afterwards the value is unused.
                               // It was still being read, twice a second for the whole film.
                               // `player.audioTracks` rebuilds the list each time, under the lock of the running
                               // player. Exactly the constant access that the comment on
                               // `FrameTick.stillPostMeasure` a few lines up warns about; the `||` short-circuits
                               // it once it carries nothing.
                               hasAudioTracks: state.tracksSet || !area.audioTracks.isEmpty),
                restoring: false,
                // No finger, but a pointer: the same question.
                atPush: atSlider,
                sinceStart: sinceStart)

            if job.loadingScreenGone {
                StartMeasurement.shared.mark("Ladeschirm weicht")
                // If the card is zooming into the picture, it now hands over to the new episode
                // (as iOS).
                if let k = cardsSwitch, k.imageSince == nil {
                    cardsSwitch?.imageSince = k.since
                    AppLog.writeOut("[Karte] erstes Bild nach \(Int(k.since * 1000)) ms")
                    Task { await cardHandOver() }
                }
                withAnimation(.easeOut(duration: 0.3)) { screenDistance = true } completion: {
                    StartMeasurement.shared.mark("Ladeschirm ausgeblendet")
                }
                // From a handoff: the card now zooms onto the picture.
                HandoffStage.shared.imagePresent(title.id)
            }
            if job.tracksApply {
                area.wendeLanguagesAn(audio: model.audioLanguage,
                                        subtitle: model.subtitleLanguage,
                                        automatic: model.subtitleAutomatic,
                                        source: plan.source,
                                        title: TrackMemory.title(for: title))
            }
            // Stay silent during the switch, as on iOS. Dispatched, not awaited (see tvOS).
            if job.startReport, !switches {
                model.reportStart(item: title, plan: plan,
                                  seconds: state.position)
                hub.report(item: title, position: state.position,
                                duration: state.duration, tempo: area.tempo,
                                running: state.running,
                                jumpDistance: (model.backSeconds, model.forwardSeconds),
                                imageUrl: model.lockImageURL(for: title))
            }
            if job.progressReport, !switches {
                model.reportProgress(item: title, plan: plan,
                                     seconds: state.position,
                                     paused: !state.running)
            }

            autoSkipRun()

            // **The overlay** (card countdown). While stationary it pauses.
            let cardBefore = cardPresent
            if offeringCatchUp(elapsed: PlaybackTick.tickLength / .seconds(1)),
               let episode = nextEpisode {
                AppLog.writeOut("[Karte] Countdown abgelaufen")
                toNextEpisode(episode, fromCard: cardBefore)
            }

            // **Prepare the next episode** while this one is still running; not in a group,
            // which advances by itself. Once per episode; when and over which network is
            // decided by `Prebuffer`.
            if let episode = nextEpisode, !inGroup, !switches,
               Prebuffer.now(position: state.position, duration: state.duration,
                               creditsFrom: sections.first { $0.art == .credits }?.from,
                               networkFavorable: preparation.networkFavorable) {
                preparation.prepare(episode) { await model.plan(for: episode.id, still: true) }
            }

            // Advance by itself at the end only with a card (outro section from the server),
            // not if it was dismissed. **If the card is counting, it owns the advance**
            // (as iOS: when seeked to the end, the end of file switched immediately).
            if layer.nextAtEnd, let episode = nextEpisode, !switches,
               EpisodeEnd.advance(position: state.position, duration: state.duration,
                                         sinceOpen: Date().timeIntervalSince(sinceStart),
                                         cardCounts: layer.cardCounts) {
                AppLog.writeOut("[Wechsel] Dateiende ohne Karte")
                toNextEpisode(episode)
            }

            beats += 1
            // The Now Playing field needs the position only once per second.
            if beats % 2 == 0, state.startReported {
                hub.stateCatchUp(position: state.position,
                                         running: state.running, tempo: area.tempo)
            }
        }
    }

}

// MARK: - The video surface

/// The counterpart of `VideoSurfaceHost` on iOS. Same job, but as
/// `NSViewRepresentable`; the view itself comes unchanged from
/// `Sources/Shared/VLCPlayer.swift`.
struct MacVideoSurface: NSViewRepresentable {
    let url: URL
    let startAt: Double
    let container: String?
    /// While true, the surface is **hidden** rather than covered.
    ///
    /// This is where macOS differs from iOS: VLC's video output here is a
    /// `VLCOpenGLVideoView`. An OpenGL view draws into its own surface and sits above
    /// everything later in the SwiftUI stack, so the order in the `ZStack` does not
    /// matter. A black scrim on top therefore had no effect, and VLC could be seen
    /// jumping to the start and seeking from there.
    ///
    /// `isHidden` acts at the AppKit level and is therefore reliable. VLC keeps
    /// decoding; nothing is shown.
    let covered: Bool
    /// **Before `play`, not after.** The buffer is attached to the media as an option;
    /// adding it afterwards means opening has already used the old level.
    let buffer: BufferLevel
    /// External subtitles, also before `play`.
    var subtitle: [SubtitleFile] = []
    /// Open directly with the software decoder: ``PlaybackPlan/softwareDekoder``.
    var softwareDecoder = false
    /// The requested tracks, also before `play`.
    var tracks: VLCPlayerView.TrackRequest?
    let whenCreating: (VLCPlayerView) -> Void

    func makeNSView(context: Context) -> VLCPlayerView {
        let viewRef = VLCPlayerView()
        viewRef.isHidden = covered
        viewRef.buffer = buffer
        viewRef.trackRequest = tracks
        viewRef.play(url: url, offSeconds: startAt, container: container, subtitle: subtitle,
                     softwareDecoder: softwareDecoder)
        DispatchQueue.main.async { whenCreating(viewRef) }
        return viewRef
    }

    func updateNSView(_ viewRef: VLCPlayerView, context: Context) {
        if viewRef.isHidden != covered { viewRef.isHidden = covered }
    }

    /// **Missing here, present on iOS from the start.**
    ///
    /// Without it the watchdog timer of the torn-down view runs forever. `stop()` on
    /// disappearing cannot be relied on: it hits the view `area` points to, not
    /// necessarily every view SwiftUI created.
    static func dismantleNSView(_ viewRef: VLCPlayerView, coordinator: ()) {
        MainActor.assumeIsolated { viewRef.stop() }
    }
}

// MARK: - Player building blocks

/// Round button in the middle: -10, pause/play, +10. Unlike the old version there
/// is no shortcut label underneath: the same look as iOS, which shows no keyboard
/// hints in the player.
struct JumpButton: View {
    let symbol: String
    /// Edge length of the symbol itself: 30 for +/-10, 40 for play/pause.
    let large: CGFloat
    /// Counts every press. A **value**, not a switch: the effect replays on every
    /// change, even on the tenth seek in a row.
    var tick: Int = 0
    /// The quick replace instead of the sliding one.
    var snappy = false
    let label: LocalizedStringKey
    let action: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                // **Without this SwiftUI cross-fades the two symbols**, which looks like a bug,
                // not intent.
                //
                // `.downUp` slides both symbols past each other and visibly takes time. For pause
                // that is too long: the button must flip at the same moment the audio stops,
                // otherwise the whole player feels sluggish. So the plain replace is used there.
                .contentTransition(.symbolEffect(snappy ? .replace.offUp
                                                       : .replace.downUp))
                .font(.system(size: large, weight: .medium))
                .foregroundStyle(Theme.font)
                // Discrete SF Symbols effect: plays once and returns to rest by itself. No
                // bounce with reduced motion; the setting is already queried nearby for the
                // scale.
                .symbolEffect(.bounce, options: .speed(1.7),
                              value: Theme.motionReduced ? 0 : tick)
                .frame(width: large * 1.8, height: large * 1.8)
                .scaleEffect(hovers ? 1.06 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityLabel(Text(label))
    }
}

/// Time on the left, slider, remaining time on the right.
private struct TimeRow: View {
    @Binding var position: Double
    let duration: Double
    @Binding var atSlider: Bool
    let mass: PlayerMetric
    /// Intro, recap, outro: start and end as notches.
    let marks: [Double]
    /// The chapters: segments on the scrubber, their name in the preview.
    let chapter: [Chapter]
    /// The trickplay image for the position, or `nil`.
    let preview: (Double) -> CGImage?
    /// On release: where to seek.
    let vault: (Double) -> Void

    /// **Remaining time or end time; a click toggles**, like the tap on iPhone:
    /// "-12:34" or "Ends at 22:41". The choice persists under the same key. No
    /// separate button, no second line.
    @AppStorage("restzeitAlsEnde") private var asEnd = false

    var body: some View {
        HStack(spacing: 14) {
            Text(PlayTime.text(position))
            TimeSlider(position: $position, duration: duration, atSlider: $atSlider, mass: mass,
                       marks: marks, chapter: chapter, preview: preview, vault: vault)
            remainingTime
        }
        .font(.system(size: mass.time).monospacedDigit())
        .foregroundStyle(Theme.fontQuiet)
    }

    private var end: Text {
        let rest = max(duration - position, 0)
        return Text("Endet um \(Date().addingTimeInterval(rest).formatted(date: .omitted, time: .shortened))")
    }

    private var remainingTime: some View {
        Button {
            asEnd.toggle()
        } label: {
            Group {
                if asEnd { end } else { Text(verbatim: "−" + PlayTime.text(max(duration - position, 0))) }
            }
            .lineLimit(1)
            .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .help(Text("Wechselt zwischen Restzeit und Ende"))
        .accessibilityLabel(asEnd ? end : Text("Restzeit"))
        .accessibilityHint(Text("Wechselt zwischen Restzeit und Ende"))
    }
}

/// The time slider: 4 pt bar, 6 pt while dragging with an accent handle; the same
/// rule as iOS (`Zeitregler` in `Sources/Shared/Style.swift`).
///
/// **Unlike there: the preview appears on mere hover** with the mouse, not only
/// while dragging. A mouse can hover and a finger cannot, and this is what it
/// should respond to. The bar itself stays calm; only the preview above the
/// pointer follows.
private struct TimeSlider: View {
    @Binding var position: Double
    let duration: Double
    @Binding var atSlider: Bool
    let mass: PlayerMetric
    /// Section boundaries in seconds, drawn as notches; while dragging the handle
    /// snaps to them (``Kerbenfang``).
    let marks: [Double]
    /// **Chapters split the scrubber into segments**; while dragging, the one under
    /// the handle rises, as on iPhone. Not on mere hover: the bar stays calm and only
    /// the preview names the chapter.
    let chapter: [Chapter]
    let preview: (Double) -> CGImage?
    let vault: (Double) -> Void

    @State private var pulls = false
    /// The notch the handle is currently snapped to, so the tick plays once on
    /// snapping, not on every movement there.
    @State private var inSnapped: Double?

    /// The boundaries as a fraction, without the two at the edges, as on iPhone.
    private var notches: [CGFloat] {
        guard duration > 0 else { return [] }
        return marks.map { CGFloat($0 / duration) }.filter { $0 > 0.01 && $0 < 0.99 }
    }

    /// Gap and smallest segment as on iPhone (`Zeitregler` in
    /// `Sources/Shared/Style.swift`).
    private static let gap: CGFloat = 2
    private static let minWidth: CGFloat = 8
    private static let thickness: CGFloat = 4
    private static let thicknessRaised: CGFloat = 6

    private func pieces(width: CGFloat) -> [ChapterBar.Piece] {
        ChapterBar.pieces(limits: ChapterBar.limits(chapter, duration: duration), duration: duration,
                              width: Double(width), minWidth: Double(Self.minWidth))
    }

    /// Snapping happens at the notches and at the cuts with space beside them
    /// (``Kapitelleiste/fangschnitte(_:dauer:breite:)``), as on iPhone.
    private func snapMarks(_ pieces: [ChapterBar.Piece], width: CGFloat) -> [Double] {
        marks + ChapterBar.snapCuts(pieces, duration: duration, width: Double(width))
    }

    /// For VoiceOver: position, length and, if there is one, the chapter.
    private var spokenValue: String {
        let spot = String(localized: "\(PlayTime.text(position)) von \(PlayTime.text(duration))")
        guard let name = ChapterBar.chapter(at: position, in: chapter)?.name, !name.isEmpty
        else { return spot }
        return String(localized: "\(spot), \(name)")
    }
    @State private var pullShare: CGFloat = 0
    /// Fraction under the pointer, independent of dragging; `nil` while the pointer is
    /// not over the scrubber.
    @State private var hoverShare: CGFloat?
    /// How wide the box above the pointer really is. With a chapter name but no
    /// thumbnail it depends on the name.
    @State private var boxWidth: CGFloat = 0

    private var displayShare: CGFloat {
        pulls ? pullShare : (duration > 0 ? CGFloat(min(max(position / duration, 0), 1)) : 0)
    }

    /// Which fraction currently shows a preview: the handle while dragging, otherwise
    /// the pointer.
    private var watchShare: CGFloat? { pulls ? pullShare : hoverShare }

    var body: some View {
        GeometryReader { space in
            let share = displayShare
            let pieces = pieces(width: space.size.width)
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    // The same light track as on iPhone. White at 28% is too weak a contrast.
                    Rectangle().fill(Color.white.opacity(0.18))
                    Capsule().fill(.white)  // Accent only on the handle, as on iOS and tvOS
                        .frame(width: space.size.width * share,
                               height: pulls ? Self.thicknessRaised : Self.thickness)
                    // **Notches at the section boundaries**, two points in `reason`, visible on track
                    // and bar, as on iPhone.
                    ForEach(notches, id: \.self) { spot in
                        Rectangle().fill(Theme.reason)
                            .frame(width: 2)
                            .offset(x: space.size.width * spot - 1)
                    }
                }
                .frame(height: Self.thicknessRaised)
                // Four points at rest, six while dragging; with chapters only the segment under
                // the handle (``ChapterMask``). Without animation: the Mac switches the
                // thickness, it does not spring.
                .mask(alignment: .leading) {
                    ChapterMask(pieces: pieces, width: space.size.width, gap: Self.gap,
                                 thickness: Self.thickness,
                                 elevated: pulls
                                     ? ChapterBar.piece(at: Double(share), in: pieces) : nil,
                                 thicknessRaised: Self.thicknessRaised, motion: nil)
                }
                if pulls {
                    Circle().fill(Theme.accent).frame(width: 18, height: 18)
                        .offset(x: space.size.width * share - 9)
                }
            }
            .frame(height: mass.bar)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if let watchShare {
                    previewBox(share: watchShare)
                }
            }
            .onContinuousHover { status in
                guard !pulls else { return }
                switch status {
                case let .active(point):
                    hoverShare = min(max(point.x / space.size.width, 0), 1)
                case .ended:
                    hoverShare = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        pulls = true
                        atSlider = true
                        let raw = min(max(value.location.x / space.size.width, 0), 1)
                        // **It snaps to the notches** (`NotchesSnap`), with the trackpad's tick instead of
                        // the iPhone's haptics; a mouse without Force Touch snaps silently.
                        if duration > 0,
                           let notch = NotchesSnap.notch(value: Double(raw) * duration, until: duration,
                                                         marks: snapMarks(pieces,
                                                                            width: space.size.width),
                                                         width: Double(space.size.width)) {
                            pullShare = CGFloat(notch / duration)
                            if inSnapped != notch {
                                inSnapped = notch
                                NSHapticFeedbackManager.defaultPerformer
                                    .perform(.alignment, performanceTime: .now)
                            }
                        } else {
                            pullShare = raw
                            inSnapped = nil
                        }
                    }
                    .onEnded { _ in
                        inSnapped = nil
                        let target = duration * pullShare
                        position = target
                        vault(target)
                        pulls = false
                        atSlider = false
                        hoverShare = nil
                    }
            )
        }
        .frame(height: mass.bar)
        // For VoiceOver a slider with position and length, not a nameless surface.
        .accessibilityElement()
        .accessibilityLabel("Abspielstelle")
        .accessibilityValue(spokenValue)
        .accessibilityAdjustableAction { bearing in
            let step = max(duration / 20, 10)
            switch bearing {
            case .increment: let z = min(duration, position + step); position = z; vault(z)
            case .decrement: let z = max(0, position - step); position = z; vault(z)
            @unknown default: break
            }
        }
    }

    /// **Above the pointer or handle: thumbnail, time below.** Without trickplay on
    /// the server only the time, with no empty box. Same as iOS `vorschauKasten`.
    ///
    /// **As its own `GeometryReader`, not with the width from outside**, exactly as on
    /// iOS: `.position(x:y:)` sets the center within its own frame, so that frame must
    /// itself span the full scrubber width, not just the narrow width of the box.
    ///
    /// **With chapters its name comes before the time**, on one line and at most as
    /// wide as the thumbnail, as on iPhone.
    private func previewBox(share: CGFloat) -> some View {
        GeometryReader { g in
            let spot = duration * share
            let image = preview(spot)
            let box: CGFloat = 170
            let height = box * 9 / 16
            let name = ChapterBar.chapter(at: spot, in: chapter)?.name ?? ""
            let half = image != nil ? box / 2 : max(name.isEmpty ? 40 : boxWidth / 2, 40)
            let x = min(max(g.size.width * share, half), max(g.size.width - half, half))
            VStack(spacing: 6) {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: box, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.corner,
                                                    style: .continuous))
                        // `rand` is the token for the few places that truly need an edge; a thumbnail over
                        // moving video is one of them.
                        .overlay(RoundedRectangle(cornerRadius: Theme.corner,
                                                  style: .continuous)
                            .strokeBorder(Theme.margin, lineWidth: 1))
                }
                HStack(spacing: 6) {
                    if !name.isEmpty {
                        Text(verbatim: name)
                            .font(.system(size: mass.time))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(PlayTime.text(spot))
                        .font(.system(size: mass.time, weight: .semibold).monospacedDigit())
                        .layoutPriority(1)
                }
                .foregroundStyle(.white)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .frame(maxWidth: box)
            .fixedSize(horizontal: false, vertical: true)
            .position(x: x, y: -((image == nil ? 0 : height + 6) + mass.time) / 2 - 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// **"Skip intro" / "Next episode": the same button.** Same look as iOS
/// `Angebotsknopf`: white pill, dark text. The accent color belongs in the player
/// only to the scrubber handle while dragging. The countdown is carried by the card
/// (``EpisodeCardsView``), no longer by a fill of the pill.
private struct OfferingButton: View {
    private static let dark = Theme.reason
    let offering: ButtonOffering
    let action: () -> Void

    var body: some View {
        if offering.visible {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "forward.end.fill")
                        .accessibilityHidden(true)
                    Text(verbatim: offering.label)
                }
                .font(Theme.listTitle)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(.white, in: RoundedRectangle(cornerRadius: Theme.cornerField,
                                                         style: .continuous))
            }
            .buttonStyle(Theme.PressButton())
            .foregroundStyle(Self.dark)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: offering.label))
        }
    }
}

// MARK: - The small window

/// The handle on the window: full screen, small window, pointer.
///
/// Deliberately the **same** window, just smaller and above all others: if the
/// player moved to a second window, VLC would need a new drawing surface, which
/// means a rebuild and a jump to the start.
@MainActor
@Observable
final class WindowHolder {
    @ObservationIgnored private(set) weak var window: NSWindow?

    /// The window arrives from `viewDidMoveToWindow` and so **later** than
    /// `setPlayer(true)` from `.onAppear`. Without catching up here, the traffic
    /// lights would stay in the player: `signalCatchUp` ran into the void because
    /// there was no window yet, and nobody called it afterwards.
    func takeOver(_ newItem: NSWindow?) {
        guard window !== newItem else { return }
        // The state **before** the player, remembered once; see `aufraeumen`.
        if fullscreenBefore == nil, let newItem {
            fullscreenBefore = newItem.styleMask.contains(.fullScreen)
        }
        window = newItem
        fullscreenObserve()
        signalCatchUp()
    }

    /// Was the window already full screen when the player opened?
    ///
    /// `nil` until the window exists. The state is remembered, not the way in: whether
    /// the button in the header, the F key or the green traffic light turned full
    /// screen on does not matter for the way back.
    @ObservationIgnored private var fullscreenBefore: Bool?

    @ObservationIgnored private var fullscreenGuard: [NSObjectProtocol] = []

    /// **Decide anew on entering and leaving full screen.**
    ///
    /// In full screen we leave the traffic lights to the system; when the window comes
    /// back, our rule must apply again. Without this they would stay visible after
    /// leaving full screen even though the controls are long gone.
    /// **And the full-screen button in the header must swap its symbol**, otherwise it
    /// keeps showing "enter" after the change where only "exit" can exist.
    private func fullscreenObserve() {
        fullscreenGuard.forEach(NotificationCenter.default.removeObserver)
        fullscreenGuard.removeAll()
        guard let window else { return }
        for name: Notification.Name in [NSWindow.didEnterFullScreenNotification,
                                        NSWindow.didExitFullScreenNotification] {
            fullscreenGuard.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.signalCatchUp() }
                })
        }
    }
    @ObservationIgnored private var before: NSRect?
    private(set) var isSmall = false
    /// Whether the player currently fills the window.
    private(set) var inPlayer = false

    var isFullscreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    /// **One expression, not two switches.**
    ///
    /// Whether the pointer is at the top of the player, where the traffic lights are.
    private(set) var pointerTop = false

    /// The traffic lights vanish in the small window, where they do not belong, **and in
    /// the player they leave with the controls.**
    ///
    /// That is right: they are controls, and controls withdraw after four seconds of
    /// quiet. A film with three colored dots stuck on it is not full screen.
    ///
    /// **In full screen we do not touch them.** There macOS hides the whole title bar
    /// including the traffic lights by itself and slides it down when the pointer
    /// reaches the top edge, as is familiar from the Mac, and it should stay so. If we
    /// also intervened in the opacity, the bar would be empty while sliding down.
    ///
    /// The player's close control (now the X at the top right) closes the **player**,
    /// the traffic lights the **window**. Two actions, two places.
    private var signalVisible: Bool {
        if isFullscreen { return true }
        return !isSmall && (!inPlayer || pointerTop)
    }

    private func signalCatchUp(soft: Bool = false) {
        guard let window else { return }
        // **Nothing at all in full screen.** Not just "leave visible" but do not touch the
        // buttons at all.
        //
        // There macOS slides the title bar down itself when the pointer reaches the top
        // edge, animating exactly these views. If our own `NSAnimationContext` group is
        // put on their opacity at the same moment, two animations fight over the same
        // views and the system freezes for a moment.
        guard !isFullscreen else { return }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let viewRef = window.standardWindowButton(button) else { continue }
            // **Fade, don't hide.** `isHidden` removes them abruptly; the controls next to
            // them fade over 180 ms. Two different speeds at the same corner are noticed
            // immediately.
            viewRef.isHidden = false
            if soft {
                NSAnimationContext.runAnimationGroup { run in
                    run.duration = 0.18
                    run.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    viewRef.animator().alphaValue = signalVisible ? 1 : 0
                }
            } else {
                viewRef.alphaValue = signalVisible ? 1 : 0
            }
        }
    }

    /// The player reports whether the pointer is in the traffic-light zone at the top.
    func setPointerTop(_ top: Bool) {
        guard !isFullscreen, pointerTop != top else { return }
        pointerTop = top
        signalCatchUp(soft: true)
    }

    /// When the controls go, the traffic lights go too, even if the pointer stays at
    /// the top, e.g. because it is not moving.
    func setControls(_ present: Bool) {
        guard !present, pointerTop else { return }
        pointerTop = false
        signalCatchUp(soft: true)
    }

    /// The player registers and unregisters.
    func setPlayer(_ an: Bool) {
        guard inPlayer != an else { return }
        inPlayer = an
        signalCatchUp()
        // **Paint only when opening, not when closing.**
        //
        // AppKit restores the title bar material from time to time; when the player
        // opens, it then shows as a light stripe over the picture. So the paint must run
        // once more there.
        //
        // On closing it must not: `aufraeumen()` hangs on `.onDisappear`, which fires
        // **when the motion starts**, not when it is done.
        if an, let window { WindowLine.highlight(window) }
    }

    func fullscreenToggle() { window?.toggleFullScreen(nil) }

    /// Small window on or off.
    ///
    /// **First out of full screen.** There macOS ignores both `setFrame` and the window
    /// level, so the small window would stay screen-filling. The way back waits for the
    /// notification that full screen has really been left; before that the window
    /// still has the old size.
    func setSmall(_ small: Bool) {
        guard let window, small != isSmall else { return }
        isSmall = small

        if small, isFullscreen {
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window, queue: .main) { [weak self] _ in
                    if let observer { NotificationCenter.default.removeObserver(observer) }
                    MainActor.assumeIsolated { self?.smallApply(true) }
                }
            window.toggleFullScreen(nil)
            return
        }
        smallApply(small)
    }

    private func smallApply(_ small: Bool) {
        guard let window else { return }

        signalCatchUp()
        // Without a title bar to grab, the window is dragged by its picture.
        window.isMovableByWindowBackground = small
        window.level = small ? .floating : .normal

        // **No `contentAspectRatio`.** A set ratio has to be removed when switching back,
        // and `.zero` is not a valid value for that: AppKit keeps computing with it and
        // crashes while dragging (`_resizeWithEvent:`, brk 1). Measured, happened once.
        // The picture letterboxes anyway when the window does not match.
        if small {
            before = window.frame
            window.contentMinSize = NSSize(width: 320, height: 180)
            let content = NSRect(origin: .zero, size: NSSize(width: 480, height: 270))
            var frameRect = window.frameRect(forContentRect: content)
            if let screen = window.screen?.visibleFrame {
                frameRect.origin = CGPoint(x: screen.maxX - frameRect.width - 24,
                                        y: screen.minY + 24)
            }
            window.setFrame(frameRect, display: true, animate: true)
        } else {
            window.contentMinSize = NSSize(width: Theme.windowMinWidth,
                                            height: Theme.windowMinHeight)
            if let before { window.setFrame(before, display: true, animate: true) }
        }
    }

    /// On leaving the player, undo everything; otherwise the main window would stay
    /// without traffic lights and above all others.
    func cleanUp() {
        if isSmall { isSmall = false; smallApply(false) }
        // **The app leaves the player the way it entered it.**
        //
        // The player always undid the small window, but not full screen. Anyone who went
        // full screen in the player and then closed it ended up with the whole app in
        // full screen.
        //
        // Only go back if the player caused it: if the app was already full screen
        // beforehand, it stays there; someone set it up that way on purpose.
        if isFullscreen, fullscreenBefore == false {
            window?.toggleFullScreen(nil)
        }
        setPlayer(false)
    }
}

/// Passes the AppKit window on to the holder.
///
/// **Via `viewDidMoveToWindow`, not in `makeNSView`.** At creation the view is not
/// in any window yet, `window` is `nil`, and the small window silently ran into the
/// void because `setSmall` bailed out at the `guard`. It happened once, and from
/// outside it looked as if the button did nothing.
struct WindowHandle: NSViewRepresentable {
    let holder: WindowHolder

    final class Probe: NSView {
        var found: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found?(window)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let viewRef = Probe(frame: .zero)
        viewRef.found = { window in
            MainActor.assumeIsolated { holder.takeOver(window) }
        }
        return viewRef
    }

    func updateNSView(_ viewRef: Probe, context: Context) {}
}

/// Feedback when seeking: the same rotation as on the buttons, so button and key
/// press do not feel like two different things.
///
/// Taken from the iPhone version (`Sprungmarke` in `Sources/iOS/PlayerScreen.swift`),
/// only without the double-tap, which the Mac does not have. The marker sits on the
/// same side as the direction of the seek.
private struct JumpMark: View {
    let bearing: Int
    let seconds: Int
    @State private var rotated = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: bearing < 0 ? "gobackward" : "goforward")
                .font(.system(size: 32, weight: .medium))
                .symbolEffect(.bounce, options: .speed(1.7),
                              value: Theme.motionReduced ? false : rotated)
            Text(verbatim: "\(seconds) s").font(Theme.tile)
        }
        .foregroundStyle(.white)
        .frame(width: 108, height: 108)
        .background(.black.opacity(0.45), in: Circle())
        .onAppear { rotated = true }
    }
}

private extension Double {
    func rounded(toPlaces set: Int) -> Double {
        let f = pow(10.0, Double(set))
        return (self * f).rounded() / f
    }
}
