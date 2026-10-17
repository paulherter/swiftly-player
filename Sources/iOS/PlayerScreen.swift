import JellyfinKit
import OSLog
import SwiftUI

/// The player.
///
/// Layout: controls centered between the title bar and the scrubber, with a
/// scrim behind them so white symbols stay visible in bright scenes.
/// Double-tap left/right seeks, a single tap toggles the controls.
struct PlayerScreen: View {
    let model: AppModel
    let startAt: Double

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var lifeStatus
    /// `.regular` means portrait on iPhone.
    @Environment(\.verticalSizeClass) private var heightClass
    /// With VoiceOver or Switch Control the controls stay visible: someone who
    /// cannot see them could not find them again after they fade out, since the
    /// surface underneath has no button to bring them back.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverAn
    @Environment(\.accessibilitySwitchControlEnabled) private var toggleAn

    // Current title; changes when switching to the next episode.
    @State private var item: Item
    @State private var plan: PlaybackPlan

    @State private var surface: VLCPlayerView?
    /// Counts only while the badge is on, see `TechBadge`.
    @AppStorage("technikschild") private var techBadge = false
    @State private var playValues: PlayValues?
    /// Counts how often CoreAnimation actually calls us; runs only while the badge is on.
    @State private var screenTick = ScreenTick()
    /// Fill the screen instead of showing the whole picture. Persists across episodes;
    /// whoever removes the bars once usually wants that afterwards too.
    @AppStorage("bildfuellend") private var fillFrame = false
    /// Keeps a single drag gesture from toggling several times.
    @State private var zoomAlreadySwitched = false

    @State private var restoring = false
    /// Currently playing in the small window.
    @State private var smallWindow = false
    @State private var firstImagePresent = false
    /// Start failed (VLC error or timeout without a picture). The start scrim
    /// then shows "Das startet nicht" with two ways out.
    @State private var startFailed = false
    /// Counts start attempts; keyed into the timeout so "try again" restarts it.
    @State private var startAttempt = 0
    /// The picture is currently being sent as a card to another device.
    @State private var handoverRuns = false
    /// Is a rotation applied on open? Must be known beforehand: if the orientation
    /// is already right, no transition fires at all.
    @State private var rotationWaits = false
    @State private var rotationReady = false
    /// When the rotation was requested, only to measure its duration on device.
    /// The simulator reports 300 ms animation time and 349 ms until `completion`;
    /// this logs whether a phone does the same.
    @State private var rotationRequested: Date?
    @State private var sinceStart = Date()
    /// Once per title: apply the track preselection.
    @State private var tracksSet = false
    /// The server has been told this title started.
    /// Reset on episode change, see `PlaybackTick.newTitle`.
    @State private var startReported = false
    /// Incremented on every title change. The loop then resets its state via
    /// `PlaybackTick.newTitle`; doing it by hand would also work, but then the
    /// rule would live in two places again.
    @State private var titleSwitch = 0
    /// Start position of an episode from the episode list, until the loop has picked up the switch.
    @State private var startPostSwitch: Double?
    @State private var hint: String?

    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var running = true
    @State private var atPush = false
    @State private var controlsVisible = true
    /// Does the control layer still accept taps? Stays set while fading out until
    /// the fade is done, see `controlsGripBarCatchUp`.
    @State private var controlsGripBar = true
    @State private var lastTap: Date?
    /// Is a seek chain running (double tap and every further quick tap on the same side)?
    @State private var inSeekChain = false
    @State private var lastPage = 0

    /// Visible means: wanted, picture is up, no menu in front.
    ///
    /// Not on tvOS: `AVPlayerViewController` provides the controls there, and two
    /// stacked control layers would hit each other.
    private var controlsPresent: Bool {
        scrimPresent && !layerOpen
    }

    /// One of the three layers: audio & subtitles, episodes, settings.
    private var layerOpen: Bool { openLayer != nil }

    /// Is something on screen that follows the position? Otherwise the full tick (`observe`) is enough.
    private var timeVisible: Bool {
        scrimPresent || layerOpen || offeringPresent || cardsSwitch != nil
            || techBadge || atPush || !firstImagePresent
    }

    /// **The offer button at the bottom right**: one rule whether or not the controls
    /// are open. Skip shows for the first six seconds of the segment, afterwards only
    /// with the controls (`OfferingLayer.buttonDuration`); the "next episode" card shows
    /// while the controls are closed (`OfferingLayer.display`), and with the controls
    /// open the normal button takes its place.
    private var offeringPresent: Bool {
        // Yields to the preview above the bar while scrubbing.
        guard offering.visible, imageFree, !layerOpen, !smallWindow, !atPush,
              airplayPlan == nil, !switches else { return false }
        return layer.display.visible || (controlsPresent && offering == .nextEpisode)
    }

    /// The scrim sits on the picture: with the controls open, and while the
    /// next-episode card is up so that it reads in the foreground.
    private var dimmed: Bool {
        scrimPresent || (cardPresent && cardsSwitch == nil)
    }

    /// The next-episode card is showing (or currently zooming).
    private var cardPresent: Bool {
        cardsSwitch != nil || (offeringPresent && countdownShare != nil)
    }

    /// The button at the bottom right, but not while the card is there.
    private var buttonPresent: Bool {
        offeringPresent && countdownShare == nil && cardsSwitch == nil
    }

    /// Springs of the draft, critically damped (``EpisodeCard``).
    private static func spring(_ omega: Double) -> Animation {
        if Theme.motionReduced { return Theme.fadeReduced }
        let f = EpisodeCard.spring(omega)
        return .interpolatingSpring(mass: 1, stiffness: f.stiffness, damping: f.damping)
    }

    private var countdownShare: Double? {
        if case let .card(share) = layer.display { return share }
        return nil
    }

    /// **The dimming stays under the playback menu.**
    ///
    /// It used to hang off `!zeigeEinstellungen`, so it was gone under the sheet and
    /// had to fade back in on close. During that window undimmed video showed,
    /// brighter than before *and* after.
    ///
    /// Visually this changes nothing while the sheet is open: at 0.97 opacity it covers
    /// everything below anyway. Header, footer and center controls still yield, since
    /// they would shine through the sheet (see below).
    private var scrimPresent: Bool {
        controlsVisible && imageFree && !smallWindow && airplayPlan == nil
    }

    /// **The picture is free once it is still and correctly oriented.**
    ///
    /// Since the player opens paused and jumps immediately, the first frame arrives at
    /// about +0.9 s. The rotation to landscape takes 300 ms and only starts with
    /// `onAppear`; before, the first second of the film's start masked it.
    ///
    /// `rotationReady` comes from `RotationListener`, i.e. the transition coordinator, the
    /// only signal that reports the **end** of the rotation. Geometry and
    /// `interfaceOrientation` jump to the final values after about thirty
    /// milliseconds and are no use for this (measured, see `RotationListener`).
    ///
    /// Without an expected rotation the condition is exactly the old one.
    private var imageFree: Bool {
        firstImagePresent && (!rotationWaits || rotationReady)
    }

    /// Observes whether audio was switched to an AirPlay device.
    @State private var remoteTarget = RemoteTarget()
    /// Set while the movie plays on the TV via `AVPlayer`.
    @State private var airplayPlan: PlaybackPlan?
    /// The position where VLC handed over.
    @State private var airplayOff: Double = 0
    @State private var jumpDisplay: (bearing: Int, seconds: Int)?
    /// Clears the seek indicator; per seek, so in a seek chain the first tap does not remove the indicator of the last.
    @State private var jumpDisplayTask: Task<Void, Never>?
    /// Fetches the plan for AirPlay. Cancellable: whoever switches back or closes the
    /// player before the server answers would otherwise still get switched to the TV.
    @State private var airplayTask: Task<Void, Never>?

    /// Count the triggers per direction, so the button rotates a bit further on every press instead of once.
    @State private var tickBack = 0
    @State private var tickPre = 0
    @State private var fadeOutMark = 0
    /// A seek where VLC has not arrived yet; until then the timeline shows the target.
    /// The rule lives in `PlaybackTick.Jump`.
    @State private var leap: PlaybackTick.Jump?
    /// The card's fill as a continuous motion (`FillClock`).
    @State private var fillClock = FillClock()
    @State private var lastPushed: Date?

    @State private var openLayer: PlayerLayer?
    /// The most recently opened layer; stays on close so the title also lies above
    /// the episodes during their fade-out.
    @State private var lastOpened: PlayerLayer?
    /// The next plan comes from a quality choice, for the hint.
    @State private var qualitySwitched = false
    /// No button for this in the player anymore; kept for the lock screen and Control
    /// Center, which want a rate reported.
    @State private var tempo: Float = 1.0
    /// Preview images while scrubbing (Jellyfin trickplay).
    @State private var trickplay = TrickplayImages()
    @State private var sleepMinutes: Int?
    @State private var sleepTask: Task<Void, Never>?
    /// Comes from the settings, no longer from the player.
    @AppStorage("querformatFest") private var landscapeFixed = true

    @State private var nextEpisode: Item?
    /// Intro, recap, outro; empty if the server knows nothing.
    ///
    /// With an empty list **nothing** changes from before: the remaining-time rule
    /// alone decides when "next episode" appears.
    // Spelled out as `JellyfinKit.` because `Abschnitt` is already a view in `BrowseViews.swift`.
    @State private var sections: [JellyfinKit.Segment] = []
    /// The file's chapters; they split the bar. Empty: one piece.
    @State private var chapter: [Chapter] = []
    /// "Skip intro" and "next episode" above the picture without the controls
    /// having to open. What applies when is in `OfferingLayer`. The next-episode
    /// card waits while the controls are open; it is dismissed with the X or a swipe
    /// (``EpisodeCardsView``).
    @State private var layer: OfferingLayer = {
        var e = OfferingLayer()
        e.cardWaitsControls = true
        return e
    }()
    /// Mirrors the latch of `episodesSwitch` for the view.
    @State private var switches = false
    /// Plan and file start of the next episode, fetched in the last minutes.
    @State private var preparation = EpisodePreparation()
    /// Since when the next episode is being loaded, for the switch time in the log.
    @State private var switchStart: Date?
    /// **The next-episode card** (``EpisodeCard``, variant C): held while it zooms
    /// into the picture, with the episode and countdown state from before, so nothing
    /// flashes when the switch removes the offer.
    @State private var cardsSwitch: CardsSwitch?
    @State private var cardsEpisode: Item?
    @State private var cardsClock: FillClock?
    @State private var cardsZoom: Double = 0
    @State private var cardImage: Double = 1
    /// The last visible offer: the button keeps its label while fading out instead of dropping out of the tree empty.
    @State private var shownOffering: ButtonOffering = .nobody

    /// Can be turned off in the measuring run (`Wechsellauf -ohnevorpuffer`) to compare the switch time with and without.
    private var prebufferAllowed: Bool {
        #if DEBUG
        return !SwitchRun.withoutPrebuffer
        #else
        return true
        #endif
    }
    @State private var episodesSwitch = EpisodeSwitch()
    /// Lock screen, Control Center, headphone buttons and calls.
    @State private var hub = PlaybackHub()

    /// Width of the window. In split screen only 320 remain, and a control layer
    /// built for 844 runs off the screen.
    @State private var windowWidthValue: CGFloat = 0

    /// **Watch together.** Set on open when the title is the one the group is
    /// watching. The group itself is held by ``SharedModel``.
    @State private var sharedAn = false
    @State private var bridge = SharedPlayer()
    private var gemeinsam: SharedModel { .shared }
    /// Is this player currently in a group? Then pause, resume and seek go as a
    /// request to the server, not to VLC.
    private var inGroup: Bool { sharedAn && gemeinsam.group != nil }

    /// From here on the controls move closer together.
    private var narrow: Bool { windowWidthValue > 0 && windowWidthValue < 500 }

    /// In a window, the iPadOS traffic lights sit over the top left corner, where
    /// the close button is.
    ///
    /// The player must account for this itself: it is a `fullScreenCover` and does not
    /// hang under `MainView`, so that view's safe-area inset never reaches it.
    private var inWindow: Bool {
        WindowButtons.inWindow(windowWidthValue: windowWidthValue)
    }

    init(model: AppModel, item: Item, plan: PlaybackPlan, startAt: Double) {
        self.model = model
        self.startAt = startAt
        // Do not start at zero: otherwise the slider briefly sits at the start and visibly jumps forward once the stream has its position.
        _position = State(initialValue: startAt)
        _item = State(initialValue: item)
        _plan = State(initialValue: plan)
    }

    /// Covers the time until VLC outputs the first frame and the stream is at its
    /// position.
    ///
    /// Deliberately black: a scene image underneath was restless, since it flashes
    /// briefly and is gone again immediately.
    private var startScrim: some View {
        ZStack(alignment: .top) {
            ZStack {
                Color.black
                if !startFailed { Loader() }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            // **A timeout instead of endless black.** If no picture arrives after 25 seconds
            // (a NAS that has to spin up takes longer than 10), the start has failed. Runs
            // only while the scrim is up; a new attempt restarts it.
            .task(id: startAttempt) {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled, !firstImagePresent, !startFailed,
                      airplayPlan == nil, !smallWindow else { return }
                AppLog.writeOut("[Player] Start gescheitert: 25 s ohne erstes Bild")
                startFailed = true
            }

            if startFailed {
                EmptyState(symbol: "exclamationmark.triangle",
                            headerLine: "Das startet nicht",
                            text: "Die Datei oder der Server liefert kein Bild. Prüf die Verbindung und versuch es noch einmal.",
                            primaryButton: ("Erneut versuchen", { startNewTry() }),
                            quietButton: ("Schließen", { close() }))
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            }

            // **Closing works before the picture is there.** The controls only appear with
            // the first frame; until then only the scrim was here, and whoever changed their
            // mind had to wait for the stream. Reported by a tester.
            //
            // Same button in the same place as in the controls' header: same margin, same
            // distance from the top, horizontally inside the safe area. When the controls
            // appear, theirs sits exactly above it.
            // **Only once the orientation is settled.** The rotation to landscape is still
            // running on open; before, the button sat at the top left in portrait, by the
            // clock, and then jumped into place. Now it fades in where it stays.
            if !rotationWaits || rotationReady {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        IconButton(symbol: "xmark", label: "Player schließen",
                                    mass: mass) { close() }
                    }
                    .padding(.horizontal, mass.page)
                    .padding(.top, mass.top)
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(edges: mass.topSkip)
                .transition(.opacity)
            }
        }
        // The same tempo at which every other view swaps its area. Before,
        // a hand-written easeOut 0.2: same duration, but a private number for a role that
        // already has a token.
        .animation(Theme.sectionSwitch, value: rotationReady)
        .transition(.opacity)
    }

    /// "Try again" in the start veil: same episode, same position,
    /// fresh setup.
    private func startNewTry() {
        AppLog.writeOut("[Player] Start erneut versucht")
        startFailed = false
        startAttempt += 1
        surface?.buffer = model.bufferLevel
        surface?.trackRequest = trackRequest(item, plan)
        surface?.play(url: plan.url, offSeconds: startPostSwitch ?? startAt,
                      container: plan.container,
                      subtitle: model.subtitleFiles(plan),
                      softwareDecoder: plan.softwareDecoder)
    }

    /// What shows in the large picture while the small window plays next to it.
    private var smallerHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "pip.fill")
                // Before: `.light`. That weight is gone; only Regular, Medium and Semibold
                // exist. Medium like the other symbols in the player. The size 30
                // stays: it is a symbol, not text.
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.fontVeryQuiet)
            Text("Läuft im kleinen Fenster")
                // Same step as before (15 Regular), now as a token.
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// Not an error but an intermediate state, so calm and without a button. It disappears by itself once the connection is up.
    private var connectionHint: some View {
        VStack(spacing: 10) {
            Loader(size: 26, strength: 2.5)
            Text("Verbindung unterbrochen")
                // Before: `.subheadline.weight(.medium)`. 15 Medium is on no ladder; a line that says something is 15 Semibold.
                .font(Theme.listTitle)
            Text("Läuft weiter, sobald das Netz zurück ist.")
                // Before: `.caption`; 12 Regular is called `small` here.
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)
        }
        // Reads `font`, not raw white (before: `.white`).
        .foregroundStyle(Theme.font)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    /// The player with fades, keys and cleanup. Pulled out of `body` because the chain would otherwise be too long for the type checker.
    private var reasonArea: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurfaceHost(url: plan.url, startAt: startAt, container: plan.container,
                             buffer: model.bufferLevel,
                             subtitle: model.subtitleFiles(plan),
                             softwareDecoder: plan.softwareDecoder,
                             tracks: trackRequest(item, plan)) {
                surface = $0
                $0.onRestoration = { restoring = $0 }
                $0.onPiPStateChanged = { smallWindow = $0 }
                // **The button follows VLC, not the click and not the tick.**
                //
                // On the tick it lagged by up to half a second. Set in the click it is too early:
                // the picture still needs its time, and a button that flips before the picture
                // looks like a player that does not respond. Measured on the Mac, three times:
                // click to VLC reporting "paused" 17-25 ms, until the film time really stands
                // 26-36 ms.
                //
                // On VLC's own report the button and the picture go still at the same moment.
                let reporter = model
                $0.runsReported = { [weak area = $0] an in
                    running = an
                    reporter.runStateReported(running: an, seconds: area?.positionSeconds ?? 0)
                }
                $0.jumpReported = { target in reporter.jumpReported(target: target) }
                $0.tracksReported = { tracks in reporter.tracksSelected(tracks) }
                $0.startErrorReported = { reason in
                    guard !firstImagePresent else { return }
                    AppLog.writeOut("[Player] Start gescheitert: \(reason)")
                    startFailed = true
                }
            }
            // After returning from picture-in-picture the surface still reported the size
            // of the small window. The stack followed it and the whole control layer stuck at
            // the top in a narrow strip.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            // The controls' animation sat on the whole stack and took the video surface
            // with it: it visibly grew from small to large on every fade-in.
            .transaction { $0.animation = nil }

            // While the small window plays, the player here is only a black surface, so
            // nothing should be hittable either. Otherwise you seek blindly in the background.
            tapAreas
                .allowsHitTesting(!smallWindow)
                // Invisible surfaces without a name: VoiceOver has the controls' buttons for
                // this, which stay up with VoiceOver. Play and pause also work with the
                // two-finger double tap (magic tap).
                .accessibilityHidden(true)

            // If the card zooms into the picture it covers the switch, so no loading screen on top.
            if !imageFree, cardsSwitch == nil { startScrim }

            // Invisible; only listens for the end of the rotation.
            RotationListener {
                if let since = rotationRequested {
                    let ms = Int(Date().timeIntervalSince(since) * 1000)
                    AppLog.writeOut("[Drehung] fertig nach \(ms) ms")
                }
                rotationReady = true
            }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            if smallWindow { smallerHint }
            if restoring { connectionHint }

            // Only once the picture is still, otherwise the controls lie over the loading
            // screen and it looks like two screens at once.
            // Not in addition to the playback menu: otherwise the player's header and footer
            // shine through and overlap its title bar.
            // Own layer because it answers its own question, see `scrimPresent`. Same curves as
            // the controls.
            scrim
                .opacity(dimmed ? 1 : 0)
                .animation(dimmed ? .snappy(duration: 0.18, extraBounce: 0)
                                       : .smooth(duration: 0.34),
                           value: dimmed)

            // **Above the scrim**: with the card up, it dims the picture as with open controls, and the card sits in front.
            cardsLayer

            // **The tech badge.** Information, not a control: it accepts nothing.
            // **Directly on the film**: above the scrim so it stays readable, but below
            // title, buttons and bar, hence also below the layers. **It slides with the
            // controls**: with them open it sits below the title bar, closed it moves to the
            // top edge where they were, so it is never in the way. Motion instead of a
            // fade, same curve as the controls; with reduced motion it jumps.
            if techBadge {
                TechBadge(plan: plan, values: playValues, area: surface,
                              screenHertz: screenTick.hertz)
                    .padding(.leading, mass.page)
                    .padding(.top, mass.top + mass.button + Theme.tileSpacing)
                    .offset(y: controlsPresent ? 0 : -(mass.button + Theme.tileSpacing))
                    .animation(Theme.motionReduced ? nil
                               : Self.curve(present: controlsPresent, layer: layerOpen),
                               value: controlsPresent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea(edges: mass.topSkip)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            Group {
                // Own layer instead of stacked between header and footer: the footer is taller
                // than the header, so the middle between them sat visibly above the picture
                // center.
                // While scrubbing only the bar counts; the center yields.
                centerControls
                    .opacity(atPush ? 0 : 1)
                    .allowsHitTesting(!atPush)
                    // **Center of the screen, not of the safe area.**
                    // In landscape the safe area is 21 pt taller at the bottom than at the top, so
                    // the buttons sat slightly above the picture center.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 0)
                    footer
                }
                // **At the bottom inside the safe area, at the top not.**
                //
                // The bar used to lie outside it, at the height of the home indicator, and was
                // confused with it when grabbed. Now it sits `mass.bottom` above. At the top,
                // landscape keeps nothing free anyway; horizontally the safe area matters, since
                // the notch sits there.
                .ignoresSafeArea(edges: mass.topSkip)
            }
            // Fade in, do not insert and remove.
            //
            // The controls used to sit in an `if`, so they were rebuilt and torn down on every
            // tap. Building up and down costs a layout pass, and the transition started
            // visibly hard; exactly what AVPlayerViewController avoids: there the controls
            // stay and only fade their opacity. Fade in fast, fade out leisurely: appearing
            // should answer the finger, disappearing may take its time.
            .opacity(controlsPresent ? 1 : 0)
            // **Hittable as long as visible.** Before, the controls were deaf from the first
            // frame of the fade-out: whoever still saw the button and hit it landed in the tap
            // area underneath.
            .allowsHitTesting(controlsGripBar)
            .task(id: controlsPresent) { await controlsGripBarCatchUp() }
            // **Springs so a second tap does not have to wait.** The asymmetry stays (fast
            // in, leisurely out), but a fixed duration cannot be redirected: whoever taps
            // twice in quick succession saw the fade start over.
            .animation(Self.curve(present: controlsPresent, layer: layerOpen), value: controlsPresent)

            // **The overlay, and the same button with the controls open.**
            // A tap on it executes; a tap beside it opens the controls as usual. Both sit at
            // exactly this one spot: before, with the controls open the button sat in the
            // title bar, ten points higher, and jumped when fading in. The footer only keeps
            // the space free for it. Skip shows by itself for six seconds, afterwards it comes
            // and goes with the controls (`OfferingLayer.buttonDuration`), always with the same
            // curves.
            //
            // Right-aligned directly above the bar, with the same measures as the footer, so
            // it never overlaps it whether the controls are open or not.
            // **Soft exit, not abrupt.** Removal from the tree ran hard despite a transition.
            // So the button stays in the tree as long as there is an offer and comes and goes
            // via opacity; the transition now applies only at the start and end of the
            // segment.
            // **Stays in the tree and goes via opacity and offset.** Removed from the tree it
            // vanished in one frame, on tapping as on episode switch. The label stays the last
            // one shown. The countdown to the next episode is carried by the card.
            if shownOffering.visible {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        OfferingButton(offering: shownOffering,
                                      action: offeringRun)
                            // VoiceOver: a two-finger scrub (Z) dismisses.
                            .accessibilityAction(.escape) { _ = layer.close() }
                    }
                }
                .padding(.horizontal, mass.page)
                .padding(.bottom, mass.bottom + mass.bar + mass.overBar)
                .ignoresSafeArea(edges: mass.topSkip)
                .offset(y: buttonPresent || Theme.motionReduced ? 0 : 6)
                .opacity(buttonPresent ? 1 : 0)
                .allowsHitTesting(buttonPresent)
                .accessibilityHidden(!buttonPresent)
                .animation(Theme.motionReduced ? Theme.fadeReduced
                           : buttonPresent ? .smooth(duration: 0.3) : .smooth(duration: 0.34),
                           value: buttonPresent)
            }

            if let jumpDisplay { jumpBackMessage(jumpDisplay) }

            // **What happens in the group, briefly at the top**, so nobody wonders why the film stopped.
            if inGroup, let event = gemeinsam.event {
                GroupsEvent(symbol: event.symbol, text: event.text)
                    .padding(.top, mass.top + mass.button + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: mass.topSkip)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .id(event.id)
                    .zIndex(4)
            }
            if inGroup, let error = gemeinsam.error {
                HintStrip(text: error) { gemeinsam.error = nil }
                    .zIndex(4)
            }
            if switches, cardsSwitch == nil { Loader() }

            // **The three layers.** Full screen above the video, the controls beneath yield
            // (`controlsPresent`), the hide timer rests.
            //
            // Mounted only while one is open: the track columns read `surface?.audioTracks` and
            // `?.subtitleTracks` directly from VLCKit, and mounted permanently that would
            // happen on every tick.
            if let openLayer {
                layersView(openLayer)
                    .transition(.opacity)
                    .zIndex(5)
            }

            // Above the layers only for the episodes, where it stays. Otherwise below
            // them, so it disappears with the meta line under the blur, not after it.
            stateTitle
                .zIndex(lastOpened == .episodes ? 6 : 3)

            // **Above everything, because it replaces everything.** While the TV is
            // connected the VLC surface below is just background; tapping and control happen
            // here.
            if let airplayPlan {
                AirPlayArea(
                    url: airplayPlan.url,
                    offSeconds: airplayOff,
                    state: { spot, length in
                        position = spot
                        if length > 0 { duration = length }
                        notifyProgress()
                    },
                    ended: {
                        if let nextEpisode { toNextEpisode(nextEpisode) }
                        else { close() }
                    },
                    error: { text in
                        // **Back to the device, do not stay black.** If the receiver does not take the
                        // stream, a black picture on the TV is the worst outcome: the film plays nowhere.
                        // So continue on the phone, with an announcement.
                        hint = String(localized: "Der Fernseher kann diesen Film nicht abspielen (\(text)). Er läuft auf dem iPhone weiter.")
                        airplayToggle(false)
                    }
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(Theme.reveal, value: techBadge)
        .animation(Theme.reveal, value: gemeinsam.event)
        // Two seconds is fast enough to watch a stutter, and slow enough that the numbers stay readable.
        .task(id: techBadge) {
            guard techBadge else { screenTick.halt(); return }
            // Count only while someone is looking: a forgotten counter on the main loop would itself be the load it is meant to measure.
            screenTick.start()
            defer { screenTick.halt() }
            while !Task.isCancelled {
                // The rate comes from the difference to the last time, see `PlayValues`.
                playValues = PlayValues(surface?.statistics, spot: surface?.positionSeconds ?? 0,
                                        running: surface?.isPlaying ?? false, before: playValues)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Going to the TV and back swaps the whole area, so the area-switch token. Before, a hand-written easeInOut 0.2.
        .animation(Theme.sectionSwitch, value: airplayPlan?.url)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Measured on the stack, not the video surface: after returning from picture-in-picture the surface still reports the small window's size.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
            windowWidthValue = new
        }
        .onAppear {
            model.remoteCommand = execute
            if gemeinsam.belongsGroup(item.id) {
                bridgeCatchUp()
                gemeinsam.plugIn(bridge)
                sharedAn = true
            }
            // **Check on open too, not only on change.** If the target is already on the TV
            // because music played there before, no notification arrives at all, and the film
            // would be audio without picture again.
            remoteTarget.switched = { airplayToggle($0) }
            remoteTarget.lookUp()
            if remoteTarget.airPlay { airplayToggle(true) }
        }
        .onDisappear {
            model.remoteCommand = nil
            // Closing means leaving.
            if sharedAn { gemeinsam.detach() }
            remoteTarget.quit()
        }
        .accessibilityAction(.magicTap) { togglePlaying() }
        // Tastatur am iPad — siehe `keysAbbreviation`.
        .background { keysAbbreviation }
    }

    var body: some View {
        reasonArea
        .task(id: fadeOutMark) {
            // Remove nothing while standing: whoever paused is not looking at the picture but wants to see the controls.
            guard controlsVisible, running, !voiceOverAn, !toggleAn else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !atPush, !layerOpen else { return }
            controlsVisible = false
        }
        // Before: easeInOut 0.15, which sits between two steps. The badge shows only 700 ms, hence the shorter toggle 0.10.
        .animation(Theme.toggle, value: jumpDisplay?.bearing)
        .animation(Self.layersCurve, value: openLayer)

        // Renew the handles too: otherwise `toggle` keeps calculating with the old
        // state.
        // Pause also stops the card's fill immediately, not only on the tick.
        .onChange(of: running) { _, _ in fadeOutMark += 1; hubAdopt(); fillSet() }
        // **After closing, the clock starts over.**
        //
        // The latch above (`!layerOpen`) rightly keeps the controls open while the panel
        // is up, but it sits *after* the sleep. The task then ends without removing
        // anything, and without a new mark no second one starts: the controls would have
        // stayed up permanently after closing.
        .onChange(of: layerOpen) { _, opened in if !opened { fadeOutMark += 1 } }
        // The overlay listens to the wanted controls, not the visible ones: on open
        // they are already "on" before the picture is there, and their first fade-out is
        // not a look at the controls that would be allowed to send "skip recap" away.
        .onChange(of: offering, initial: true) { _, new in
            if new.visible { shownOffering = new }
        }
        .onChange(of: cardPresent) { _, present in
            guard cardsSwitch == nil else { return }
            AppLog.writeOut(present ? "[Karte] erscheint bei \(Int(position)) s von \(Int(duration)) s"
                                 : "[Karte] geht (abgesagt oder Steuerung)")
        }
        .onChange(of: controlsVisible, initial: true) { _, opened in
            layer.controls(opened: opened)
            fillSet()
        }
        .onChange(of: tempo) { _, new in surface?.tempo = new }
        .onChange(of: sleepMinutes) { _, new in sleepTimeSet(new) }
        .onChange(of: landscapeFixed) { _, fixed in
            Orientierung.shared.playerOpened(landscapeFixed: fixed)
        }
        // **Pinching in and out switches the aspect.**
        //
        // Two states, as in Netflix and Apple's own video app: the whole picture with
        // bars, or fill with cropping. A third would only be a stretch, and nobody wants
        // that.
        //
        // **No label.** There used to be a faded-in word saying what applies. It came on
        // every gesture, sat in the picture and had to be tapped away; what happens is
        // visible anyway.
        //
        // **And no animation following the gesture.** An attempt to let the picture follow
        // the gesture via `scaleEffect` made it worse: the zoom no longer ran fully
        // through, and the accompanying `clipped()` sat outside `ignoresSafeArea` and
        // cropped the picture at the safe area instead of the screen edge. Reverted: a
        // hard, correct switch beats a soft one that is off.
        //
        // `simultaneousGesture` so that tapping and seeking underneath keep working. The
        // latch is needed because `onChanged` fires dozens of times during a gesture:
        // without it a single pinch would have flickered between both states.
        .simultaneousGesture(
            MagnifyGesture(minimumScaleDelta: 0.05)
                .onChanged { value in
                    guard !zoomAlreadySwitched, !smallWindow, !layerOpen else { return }
                    if value.magnification > 1.15, !fillFrame {
                        zoomAlreadySwitched = true
                        fillFrame = true
                        surface?.fillFrame(true)
                    } else if value.magnification < 0.85, fillFrame {
                        zoomAlreadySwitched = true
                        fillFrame = false
                        surface?.fillFrame(false)
                    }
                }
                .onEnded { _ in zoomAlreadySwitched = false }
        )
        // Set up the remembered state on open and on episode change.
        .onChange(of: surface == nil) { _, _ in surface?.fillFrame(fillFrame) }
        // **Playback continues in the background.** This is a decision, not an omission.
        //
        // There used to be a rule that paused on moving to the background, against the
        // case of a swiped-away episode silently running on and then showing as watched
        // (jellyfin/Swiftfin#871, regression #2175). It caused a real bug: iOS also sends
        // the app to the background when only Notification Center is pulled down, through
        // **exactly the same** sequence of notifications as a swipe to the home screen
        // (willResignActive -> scenePhase inactive -> didEnterBackground). No signal
        // separates the two cases. Every glance at a notification paused the film, and it
        // did not resume by itself.
        //
        // Other clients simply allow background playback, and the app declares
        // `UIBackgroundModes: audio` anyway; without it there would be no
        // picture-in-picture and no lock screen. So it keeps playing, and progress is
        // reported on the tick as usual.
        //
        // The lifecycle is still logged: that costs nothing in the shipped build
        // (`AppLog.write` is compiled out there) and found exactly this bug.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification)) { _ in
            AppLog.writeOut("[Lebenslage] didEnterBackground · Zustand \(StatusWord.now)"
                + " · PiP \(smallWindow) · laeuft \(running) → weiterlaufen lassen")
            // Report the position now: if the app gets frozen anyway, the server would otherwise hold a position up to ten seconds old.
            if startReported, !switches {
                model.backgroundReport(item: item, plan: plan, seconds: position, paused: !running)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            AppLog.writeOut("[Lebenslage] willEnterForeground · Zustand \(StatusWord.now)")
        }
        .task { await observe() }
        // Check once per title whether the server has preview images.
        .task(id: item.id) { await trickplay.load(model: model, item: item, plan: plan) }
        // **Per version, not per title**: a director's cut has different chapters. Until they arrive the bar shows none from other versions.
        .task(id: [item.id, plan.mediaSourceID]) {
            chapter = []   // also when the version changes without a new title
            let found = await model.chapter(for: item.id, source: plan.mediaSourceID)
            guard !Task.isCancelled else { return }
            chapter = found
        }
        // The next-episode image is ready for a possible handover; the sender's card needs it in the first frame (``Uebergabeabgang``).
        .task(id: item.id) { await HandoffExit.preload(item, model: model) }
        .task(id: item.id) {
            if item.type == "Episode" { await EpisodesLayer.preload(model: model, item: item) }
        }
        // Only then is it known whether a "continue" button may exist.
        .task { await lookUp(for: item) }
        .onChange(of: duration) { _, _ in hubReport() }
        .onAppear {
            model.playerOpen = true
            // Ask **before** requesting: afterwards the orientation is already landscape.
            // In its own frame UIKit rotates along while presenting, so the player appears
            // landscape right away and there is nothing to wait for.
            let inFrame = PlayerFrame.active != nil
            rotationWaits = !inFrame && Orientierung.rotationWaits(landscapeFixed: landscapeFixed)
            rotationRequested = Date()
            AppLog.writeOut("[Drehung] angeordnet · erwartet=\(rotationWaits)"
                + " · Sperre=\(landscapeFixed) · Rahmen=\(inFrame)")
            Orientierung.shared.playerOpened(landscapeFixed: landscapeFixed, demand: !inFrame)
        }
        // **Emergency exit.** If the transition never comes (rotation lock in Control
        // Center, rejected request, a case we do not know), the loading screen would hang
        // until someone leaves the player. The bug it hides is one second of crooked
        // picture; the bug it would create is a player that never opens.
        //
        // Deliberately **without** `guard rotationWaits`: `.task` and `.onAppear` have
        // no guaranteed order. If the task runs first it would still read `false`, the
        // exit would bail out immediately, and it would be missing in exactly the case it
        // exists for. Without an expected rotation `imageFree` ignores the result anyway.
        .task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, !rotationReady else { return }
            if rotationWaits {
                AppLog.writeOut("[Dreh] kein Uebergang binnen 1,5 s — Ladeschirm faellt trotzdem")
            }
            rotationReady = true
        }
        .onDisappear {
            fadeOutMark += 1
            sleepTask?.cancel()
            jumpDisplayTask?.cancel()
            airplayTask?.cancel()
            // If the small window is playing, `stop()` is exactly what picture-in-picture is
            // meant to prevent. The stream then stays up and is ended when the window closes.
            if !smallWindow {
                // Capture the position **before** stopping. It would still be right here, because
                // `position` is the view's state and not VLC's time, but that is an accident of
                // ordering, not a guarantee. After `stop()` VLC's time is zero, and swapping the
                // two lines would lose exactly what "continue watching" is about.
                let spot = position
                model.doneWatch(position: spot, duration: duration)
                surface?.stop()
                hub.handIn()
                // Over the switch: if one is running it aborts, and if the new episode's start is under way the stop goes afterwards.
                let ongoing = (item: item, plan: plan)
                episodesSwitch.close {
                    await model.reportStopped(item: ongoing.item, plan: ongoing.plan,
                                              seconds: spot)
                }
            }
            HandoffStage.shared.playerDistance(item.id)
            // In its own frame the transition has already rotated back.
            Orientierung.shared.playerClosed(demand: PlayerFrame.active == nil)
            model.playerOpen = false
        }
    }

    /// **One fade for layer and controls.** When a layer opens, the controls beneath
    /// fade out in the **same tempo** in which the blur fades in. Before, they kept
    /// going with their leisurely fade-out (0.34 s) while the layer stood after 0.2 s,
    /// and parts shimmered through the blur late.
    ///
    /// **A spring, not a fixed duration**, like the controls: whoever opens a layer and
    /// closes it right away redirects the running fade instead of seeing it restart.
    /// With reduced motion, the short crossfade from `Theme`.
    static var layersCurve: Animation {
        Theme.motionReduced ? Theme.fadeReduced : .snappy(duration: 0.2, extraBounce: 0)
    }

    /// Fade in springy and fast, out leisurely, unless a layer takes its place; then at the layer's tempo.
    static func curve(present: Bool, layer: Bool) -> Animation {
        if Theme.motionReduced { return Theme.fadeReduced }
        if present { return .snappy(duration: 0.18, extraBounce: 0) }
        return layer ? layersCurve : .smooth(duration: 0.34)
    }

    /// How long the fade-out from `kurve` runs.
    static func fadeOutDuration(layer: Bool) -> Duration {
        if Theme.motionReduced { return .milliseconds(140) }
        return layer ? .milliseconds(200) : .milliseconds(340)
    }

    /// Fading in makes it hittable immediately, fading out only after the fade. If
    /// the controls return before that, `task(id:)` cancels the wait.
    private func controlsGripBarCatchUp() async {
        guard !controlsPresent else { controlsGripBar = true; return }
        try? await Task.sleep(for: Self.fadeOutDuration(layer: layerOpen))
        guard !Task.isCancelled, !controlsPresent else { return }
        controlsGripBar = false
    }

    /// Carries the current state into the bridge to the group and gives it the tick;
    /// see ``Gemeinsamspieler`` for why an object and not a closure.
    private func bridgeCatchUp() {
        bridge.area = surface
        bridge.titleID = item.id
        bridge.isReady = (surface?.startReady ?? false) && imageFree && !switches
        bridge.jumpShow = { target in jumped(on: target) }
        bridge.switchTitle = { episode, _, since in toNextEpisode(episode, since: since) }
        gemeinsam.playerTick()
    }

    /// **Playback moves to another device** (``Uebergabeabgang``). The position goes
    /// to the server immediately (the other side waits for it), the controls go, the
    /// picture stops at 0.12 s and leaves as a card.
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
                                done: { area.stop(); close() })
    }

    /// On iPhone the own frame (`PlayerFrame`) closes; UIKit rotates back to portrait in the same transition.
    private func close() {
        AppLog.writeOut("[Player] Schließen · Wechsel \(episodesSwitch.phase) · Karte \(cardsSwitch != nil) · Rahmen \(PlayerFrame.active != nil)")
        if let frameRect = PlayerFrame.active {
            frameRect.close()
        } else {
            Orientierung.shared.playerClosed()
            dismiss()
        }
    }

    /// **Keyboard on iPad, as in the Mac player:** space pauses and plays, the arrows
    /// seek by the configured amount. With a layer open the keys belong to it; someone
    /// moving through the audio tracks should not pause the film. Own property because
    /// `body` would otherwise be too long for the type checker.
    private var keysAbbreviation: some View {
        Group {
            Button(running ? "Anhalten" : "Abspielen") { togglePlaying() }
                .keyboardShortcut(.space, modifiers: [])
            Button("\(model.backSeconds) Sekunden zurück") {
                scrub(Int32(-model.backSeconds))
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            Button("\(model.forwardSeconds) Sekunden vor") {
                scrub(Int32(model.forwardSeconds))
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .disabled(layerOpen)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Veil

    private var scrim: some View { PlayerScrim() }

    // MARK: - Tap areas

    private var tapAreas: some View {
        ZStack {
            HStack(spacing: 0) {
                area(bearing: -1)
                area(bearing: 1)
            }

            // Where the pause button sits, tapping should also pause when it is faded out.
            // Whoever taps the middle means the button, not "show me the controls".
            //
            // Deliberately below the controls: when they are visible, the real button catches
            // the tap. Narrow enough that the two seek buttons beside it stay free.
            Color.clear
                .frame(width: 108, height: 132)
                .contentShape(Rectangle())
                .onTapGesture {
                    togglePlaying()
                }
        }
        .ignoresSafeArea()
    }

    /// One tap toggles the controls, two seek.
    ///
    /// Not via `onTapGesture(count: 2)` plus `onTapGesture`: the single tap would have
    /// to wait until the double has failed (`require(toFail:)`), and that scant third
    /// of a second feels sluggish.
    ///
    /// **Two earlier versions were worse than this one.** First the first tap toggled
    /// immediately and the second undid it, so on every double tap the controls opened
    /// and closed once. Then the single tap waited `doubleTap` long: no more
    /// flicker, but the player felt sluggish since nothing happened for a quarter
    /// second after the touch.
    ///
    /// **Now the first tap toggles immediately and nothing is undone.** The second tap
    /// seeks and leaves the controls as the first set them. The UI is there at once and
    /// still nothing bobs: it opens **or** closes, never both in sequence.
    private func area(bearing: Int) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { onTap(bearing: bearing) }
    }

    private func onTap(bearing: Int) {
        let now = Date()
        let window = inSeekChain ? Self.chainTap : Self.doubleTap
        if let before = lastTap, lastPage == bearing,
           now.timeIntervalSince(before) < window {
            // **A chain, not a pair.** Before, `lastTap = nil` was set here, and every
            // third quick tap toggled the controls instead of continuing to seek. Now every
            // tap extends the chain.
            lastTap = now
            inSeekChain = true
            // The first tap has already toggled. That stays; what is shown once is not taken back.
            if controlsVisible { hideMove() }
            scrub(Int32(bearing < 0 ? -model.backSeconds : model.forwardSeconds))
            return
        }
        lastTap = now
        lastPage = bearing
        inSeekChain = false
        controlsToggle()
    }

    /// How long a tap waits for its second.
    private static let doubleTap: Double = 0.26
    /// How long a running seek chain waits for the next tap; longer than the double
    /// tap because when seeking you tap at your own pace while watching the seek
    /// indicator.
    private static let chainTap: Double = 0.5

    // MARK: - Header, center, footer

    /// Measures for iPhone and iPad, shared with the layers so their X sits exactly on the player's X.
    private var mass: PlayerMetric {
        PlayerMetric(pad: Theme.atPad, inWindow: inWindow,
                   portrait: !Theme.atPad && heightClass == .regular)
    }

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

    /// **Title top left, only symbols top right.**
    ///
    /// No picture-in-picture button anymore: the small window starts by itself on
    /// swiping up. No rate, no info; both lived in the old playback menu and go with
    /// it. While scrubbing only the title remains; the symbols yield to the preview.
    /// The buttons at the top right, also as an invisible placeholder in
    /// `stateTitle` so the title gets the same width there.
    private var iconRail: some View {
        HStack(spacing: mass.pad ? 6 : 2) {
            IconButton(symbol: "captions.bubble", label: "Audio & Untertitel",
                        mass: mass) { unfoldLayer(.tracks) }
            if hasEpisodes {
                IconButton(symbol: "rectangle.stack", label: "Folgen",
                            mass: mass) { unfoldLayer(.episodes) }
            }
            IconButton(symbol: "slider.horizontal.3", label: "Einstellungen",
                        mass: mass) { unfoldLayer(.settings) }
            IconButton(symbol: "xmark", label: "Player schließen",
                        mass: mass) { close() }
        }
    }

    /// **The title top left, one layer above everything.** With the episode layer
    /// open it stays exactly here; if it lived in the header it would fade out with the
    /// controls and back in within the layer, flickering.
    private var stateTitle: some View {
        let present = controlsPresent || openLayer == .episodes
        return HStack(alignment: .top, spacing: 12) {
            Text(verbatim: titleLine)
                // 20 Semibold, the row heading from the ladder. Before: 19 (iPhone) and 22 (iPad)
                // in Bold, a size on no ladder, and Bold appears exactly once, at the page title.
                // Rationale is at `Playermass`.
                .font(.system(size: mass.title, weight: .semibold))
                // Before: raw `.white`; `font` is read.
                .foregroundStyle(Theme.font)
                .lineLimit(1)
            Spacer(minLength: 0)
            iconRail
                .hidden()
                .accessibilityHidden(true)
        }
        .padding(.horizontal, mass.page)
        .padding(.top, mass.top)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: mass.topSkip)
        .allowsHitTesting(false)
        .opacity(present ? 1 : 0)
        .animation(Self.curve(present: present, layer: layerOpen), value: present)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // Placeholder only: what shows is the title from `stateTitle`, which stays while the episode layer is open.
                Text(verbatim: titleLine)
                    .font(.system(size: mass.title, weight: .semibold))
                    .lineLimit(1)
                    .opacity(0)
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    // **In a group, the group shows here**, where year and runtime
                    // otherwise sit. That is state, so accent.
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
            // Before: raw `.white`; `font` is read. The meta line below sets its own `schriftLeise`.
            .foregroundStyle(Theme.font)

            Spacer(minLength: 0)

            iconRail
            .opacity(atPush ? 0 : 1)
            .allowsHitTesting(!atPush)
        }
        .padding(.horizontal, mass.page)
        .padding(.top, mass.top)
        .overlay(alignment: .bottom) {
            // Below the header, centered: there it gets in the way of neither the bar nor the skip button.
            if let hint {
                Text(hint)
                    // Before: `.caption2` (11 Regular). 11 exists only as Semibold on the ladder; a sentence is a statement, so 12.
                    .font(Theme.small).foregroundStyle(Theme.font)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, mass.page)
                    .offset(y: 22)
                    .task {
                        try? await Task.sleep(for: .seconds(5))
                        self.hint = nil
                    }
            }
        }
    }

    private func unfoldLayer(_ target: PlayerLayer) {
        fadeOutMark += 1
        lastOpened = target
        openLayer = target
    }

    private func layerClose() {
        openLayer = nil
    }

    @ViewBuilder
    private func layersView(_ which: PlayerLayer) -> some View {
        switch which {
        case .tracks:
            TracksLayer(surface: surface, mass: mass, close: layerClose)
        case .settings:
            SettingLayer(surface: surface, mass: mass, sleepMinutes: $sleepMinutes,
                              quality: qualitySelection,
                              gemeinsam: inGroup ? gemeinsam : nil,
                              groupLeave: { close() },
                              close: layerClose)
        case .episodes:
            EpisodesLayer(model: model, item: item, title: titleLine, mass: mass,
                        close: layerClose) { episode in
                layerClose()
                // Tapping the running episode means: keep watching.
                guard episode.id != item.id else { return }
                // In a group nobody switches alone: the choice sets the queue, and everyone loads the episode.
                if inGroup { gemeinsam.bitTitle(episode.id); return }
                toNextEpisode(episode, since: episode.resumeFrom ?? 0)
            }
        }
    }

    /// Centered in the picture, not at the bottom edge, so the thumb is near in both orientations and the symbols do not sit in the subtitles.
    private var centerControls: some View {
        HStack(spacing: narrow ? 34 : 52) {
            button("gobackward.\(model.backSeconds)", large: true,
                  tick: tickBack,
                  label: "\(model.backSeconds) Sekunden zurück") {
                scrub(Int32(-model.backSeconds))
            }
            button(running ? "pause.fill" : "play.fill", huge: true,
                  snappy: true,
                  label: running ? "Anhalten" : "Abspielen") { togglePlaying() }
            // Forward further than backward: forward skips intro and ads, backward you look for a sentence.
            button("goforward.\(model.forwardSeconds)", large: true,
                  tick: tickPre,
                  label: "\(model.forwardSeconds) Sekunden vor") {
                scrub(Int32(model.forwardSeconds))
            }
        }
    }

    /// Only the bar, full width: elapsed time on the left, remaining on the right. The title now sits at the top.
    private var footer: some View {
        TimeRow(position: $position, duration: duration, atPush: atPush,
                  font: mass.time, pad: mass.pad, sliderTop: mass.sliderTop,
                  preview: { trickplay.image(at: $0, model: model) },
                  // **Both boundaries, not only the start.** Where the intro starts does not say where it ends, and that is what you want to see before you grab.
                  marks: sections.flatMap { [$0.from, $0.until] },
                  chapter: chapter) { schiebt in
            if schiebt {
                // **The scrubber is the component where the finger rests longest**, and the whole app
                // used to have exactly one haptic, none in the player. Touching and
                // releasing are the two moments when the hand expects an answer: light on
                // grabbing, medium on letting go, because the jump then really happens.
                // `Theme.jerk` follows `motionReduced` itself.
                Theme.jerk(.lightweight)
                atPush = true
                lastPushed = Date()
                fadeOutMark += 1
            } else {
                // Reset explicitly: otherwise atPush would stay set and the time display would never be updated again.
                atPush = false
                Theme.jerk(.medium)
                if inGroup { gemeinsam.bitJump(on: position) }
                else { surface?.seek(toSeconds: position) }
                jumped(on: position)
                hideMove()
            }
        }
        .frame(height: mass.bar)
        .padding(.horizontal, mass.page)
        .padding(.bottom, mass.bottom)
    }

    private func button(_ symbol: String, large: Bool = false, huge: Bool = false,
                       dimmedDown: Bool = false, tick: Int = 0, snappy: Bool = false,
                       label: LocalizedStringKey? = nil,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                // Without this SwiftUI crossfades the two symbols, which looked like a bug, not
                // intent.
                //
                // `.downUp` pushes both symbols past each other and visibly takes time. Too long
                // for pause: the button must flip at the same moment the sound stops, otherwise
                // the whole player feels sluggish. So a plain swap there.
                //
                // **With reduced motion it flips instead of transitioning.** The scale on the
                // button already asks for the setting; this effect did not, so exactly the motion
                // someone turned off kept running in the middle of the player.
                .contentTransition(Theme.motionReduced
                                   ? .identity
                                   : .symbolEffect(snappy ? .replace.offUp
                                                         : .replace.downUp))
                .font(.system(size: huge ? (narrow ? 36 : 48)
                                          : (large ? (narrow ? 24 : 30) : 17),
                              weight: .medium))
                // **Disabled means muted text, not translucent**. Before:
                // `.white.opacity(0.35)`. Over a bright scene the symbol was gone entirely, over a
                // dark one almost normal: the opacity depended on the picture instead of the
                // state.
                .foregroundStyle(dimmedDown ? Theme.fontVeryQuiet : Color.white)
                // Discrete SF Symbols effect: plays once and returns to rest by itself. A
                // hand-computed angle stayed put instead. A value that never changes never
                // triggers the effect, so the button stays still with reduced motion without the
                // branch swapping the view.
                .symbolEffect(.bounce, options: .speed(1.7),
                              value: Theme.motionReduced ? 0 : tick)
                .frame(width: border(huge), height: border(huge))
                .contentShape(Rectangle())
        }
        // **Every button gives feedback**. Back, pause and forward had none:
        // an image button in the default style shows nothing on press, and here the
        // surface is large and the finger far from the symbol.
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(label.map { Text($0) } ?? Text(verbatim: symbol))
        .accessibilityRemoveTraits(dimmedDown ? .isButton : [])
    }

    /// Edge length of the round buttons. One step smaller when narrow, otherwise back and forward touch in a 320 window.
    private func border(_ huge: Bool) -> CGFloat {
        if huge { return narrow ? 60 : 78 }
        return narrow ? 40 : 46
    }

    private func jumpBackMessage(_ display: (bearing: Int, seconds: Int)) -> some View {
        HStack(spacing: 0) {
            if display.bearing > 0 { Spacer() }
            JumpMark(bearing: display.bearing, seconds: display.seconds)
                // Without its own identity SwiftUI does not rebuild the view on two jumps in a row, so the rotation would not happen.
                .id(display.bearing < 0 ? -tickBack : tickPre)
            if display.bearing < 0 { Spacer() }
        }
        .padding(.horizontal, 44)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// Which button applies now: skip, advance or none.
    ///
    /// **It is the same button.** Design and place stay; only label, symbol and timing
    /// change. The rule behind it lives in the package so it is the same on all four
    /// platforms.
    private var offering: ButtonOffering {
        guard !switches else { return .nobody }
        return SectionLogic.offering(position: position, duration: duration,
                                       sections: sections,
                                       hasNextEpisode: nextEpisode != nil)
    }

    /// The press on it.
    private func offeringRun() {
        layer.pressed()
        switch offering {
        case .nobody:
            break
        case let .skip(to, _):
            // Medium, like releasing the scrubber: skipping a segment moves the film by minutes, not seconds.
            Theme.jerk(.medium)
            // Like a manual seek: set the position, jump, and briefly keep the display from being overwritten.
            if inGroup { gemeinsam.bitJump(on: to) }
            else { surface?.seek(toSeconds: to) }
            jumped(on: to)
            hideMove()
        case .nextEpisode:
            // Light: a tick that the press arrived; the switch itself is clearly visible.
            Theme.jerk(.lightweight)
            if let nextEpisode { toNextEpisode(nextEpisode) }
        }
    }

    // MARK: - Actions

    /// Commands from the Jellyfin dashboard.
    private func execute(_ command: RemoteCommand) {
        if inGroup {
            switch command {
            case .pause:  if running { gemeinsam.bitToggle(runningCurrently: true) }
            case .proceed: if !running { gemeinsam.bitToggle(runningCurrently: false) }
            case .toggle: gemeinsam.bitToggle(runningCurrently: running)
            case .stop: close()
            case let .jumpOn(seconds): gemeinsam.bitJump(on: seconds)
            case .forward: scrub(Int32(model.forwardSeconds))
            case .back: scrub(Int32(-model.backSeconds))
            case .next, .previous: break
            }
            controlsVisible = true
            hideMove()
            return
        }
        switch command {
        case .pause:
            surface?.pause()
            withAnimation(Theme.toggle) { running = false }
        case .proceed:
            resume()
            withAnimation(Theme.toggle) { running = true }
        case .toggle:
            if running { surface?.pause() } else { resume() }
            withAnimation(Theme.toggle) { running.toggle() }
        case .stop:
            // **Another device takes over** (hint came shortly before): the picture leaves as a card. Otherwise (dashboard, other app) as usual.
            if let target = model.handoffTargetTake(), let area = surface {
                handIn(an: target, area: area)
            } else {
                surface?.stop()
                close()
            }
        case let .jumpOn(seconds):
            surface?.seek(toSeconds: seconds)
            jumped(on: seconds)
        case .forward:
            scrub(Int32(model.forwardSeconds))
        case .back:
            scrub(Int32(-model.backSeconds))
        case .next:
            if let nextEpisode { toNextEpisode(nextEpisode) }
        case .previous:
            break
        }
        controlsVisible = true
        hideMove()
    }

    /// Pause and resume, from the center of the picture as from the button. Set the
    /// state and follow up on everything that hangs off it.
    ///
    /// `togglePlaying` inverts; that is right for the button in the picture but
    /// wrong for an external command that explicitly says "play" or "pause".
    private func runState(_ an: Bool) {
        // Same role as in `ausfuehren`, so the same token: toggle 0.10. Before: easeOut 0.12, two values for one toggle.
        withAnimation(Theme.toggle) { running = an }
        controlsVisible = true
        hub.stateCatchUp(position: position, running: an, tempo: tempo)
        hideMove()
        // Reported on VLC's callback (`runsReported`), not here.
    }

    /// Resume at the viewer's request: after a long pause a bit back
    /// (``Pausenruecksprung``). The display takes the target at the same moment so the
    /// bar does not first show the old position.
    private func resume() {
        guard let target = surface?.resume(jumpBack: !inGroup) else { return }
        jumped(on: target)
    }

    private func togglePlaying() {
        if inGroup {
            gemeinsam.bitToggle(runningCurrently: running)
            controlsVisible = true
            hideMove()
            return
        }
        // No more `running.toggle()`: the button waits for VLC's report. See `runsReported` above.
        if running { surface?.pause() } else { resume() }
        controlsVisible = true
        hub.stateCatchUp(position: position, running: running, tempo: tempo)
        hideMove()
        // This used to call `notifyProgress()` and read `running` before VLC's callback, so pause went out as "playing". Reporting now goes through `runsReported`.
    }

    private func scrub(_ seconds: Int32) {
        // Button **and** double tap run through here, so the feedback sits in one place.
        // Light, not medium: a ten-second seek is smaller than releasing the scrubber, and
        // the double tap is often triggered several times in a row.
        Theme.jerk(.lightweight)
        // Compute the target before the jump: from a still-open target, not from where VLC currently stands.
        let target = PlaybackTick.target(um: Double(seconds), state: displayState)
        if inGroup {
            // A request to the group; the jump happens when the command arrives.
            gemeinsam.bitJump(on: max(0, target))
        } else {
            surface?.jump(seconds: seconds)
        }
        jumped(on: target)
        if seconds < 0 { tickBack += 1 } else { tickPre += 1 }
        // **Tapped repeatedly, it counts up**: +10 s, +20 s, +30 s while the indicator of the previous jumps in the same direction is still up.
        let bearing = seconds < 0 ? -1 : 1
        let untilFrom = jumpDisplay.flatMap { $0.bearing == bearing ? $0.seconds : nil } ?? 0
        jumpDisplay = (bearing, untilFrom + Int(abs(seconds)))
        jumpDisplayTask?.cancel()
        jumpDisplayTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            jumpDisplay = nil
        }
        if controlsVisible { hideMove() }
        // Reported via `jumpReported`, with the target position instead of the old one.
    }

    /// What the timeline currently shows, as the state for the shared rules.
    private var displayState: PlaybackTick.Snapshot {
        var state = PlaybackTick.Snapshot(position: position, duration: duration)
        state.leap = leap
        return state
    }

    /// **Every seek, whichever way:** timeline and button stand on the target
    /// immediately, not only when VLC catches up. The tick hands over to VLC's time as
    /// soon as VLC is there.
    private func jumped(on target: Double) {
        var state = displayState
        PlaybackTick.jumped(&state, target: target)
        position = state.position
        leap = state.leap
        // A seek into the outro or to the end: the card's countdown starts over (seeked to the end, continues immediately).
        layer.jumped()
        if countdownShare != nil { fillClock = FillClock() }
        offeringCatchUp(elapsed: 0)
        #if DEBUG
        if JumpRun.an || OfflineRun.an { AppLog.writeOut("[Sprung] Anzeige \(String(format: "%.1f", position)) · Angebot \(offering)") }
        #endif
    }

    /// Adjust the overlay to the displayed position. With `elapsed: 0` directly
    /// after a seek, otherwise once per tick.
    ///
    /// - Returns: `true` if the countdown has now expired.
    @discardableResult
    private func offeringCatchUp(elapsed: Double) -> Bool {
        guard !switches else { return false }
        var new = layer
        let done = new.tick(offering: offering,
                                cardDue: SectionLogic.cardDue(position: position, duration: duration,
                                                                           sections: sections,
                                                                           hasNextEpisode: nextEpisode != nil,
                                                                           remainingWindow: EpisodeCard.remainingWindow),
                                running: running && imageFree && !atPush,
                                elapsed: elapsed,
                                countdown: SectionLogic.countdown(position: position, duration: duration,
                                                                     sections: sections,
                                                                     remainingWindow: EpisodeCard.remainingWindow),
                                // At the end of the file the countdown keeps running.
                                atEnd: EpisodeEnd.atEnd(position: position, duration: duration) && !atPush)
        // If the skip button fades out by itself (`buttonDuration`), it should go as softly
        // as it came: the tick runs without animation, so animate the visibility change
        // explicitly here.
        if new.display.visible != layer.display.visible {
            withAnimation(.smooth(duration: 0.34)) { layer = new }
        } else {
            layer = new
        }
        fillSet()
        return done
    }

    private func fillSet() {
        fillClock.set(share: countdownShare, running: running && imageFree && !atPush,
                             length: layer.countdownLength)
    }

    /// Switches to the next episode in the running player instead of jumping back to
    /// the overview.
    ///
    /// **The sequence lives in the package** (`EpisodeSwitch`): latch, stop and plan
    /// side by side, cancel on close, stop exactly once. It used to exist three times
    /// by hand, on tvOS and on the Mac, and drifted apart. What remains here is what
    /// only this view knows: which of its states belong to the episode.
    /// - Parameter ab: start position, from the episode list the resume point, when
    /// advancing always the start.
    /// Direct Play or cap: only when played from the server.
    ///
    /// **And not in a group.** The switch reloads the title and reports stop and start
    /// to the server, bypassing the group: it learns nothing and you continue alone at
    /// the old position. As with advancing to the next episode, the choice is therefore
    /// omitted in a group.
    private var qualitySelection: QualitySelection? {
        guard model.downloads.file(for: item.id) == nil, model.convertAllowed,
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
            AppLog.writeOut("[Qualität] \(model.alwaysDirectPlay ? "Direct Play" : "\(model.bitratesLimit) Mbit/s") — neu laden bei \(Int(position)) s")
            // Same path as on episode change: new plan, same position.
            layerClose()
            // A prepared plan for the next episode carries the old choice.
            preparation.forget()
            qualitySwitched = true
            toNextEpisode(item, since: position)
        }
    }

    private func toNextEpisode(_ episode: Item, since: Double = 0, fromCard: Bool = false) {
        guard !switches else { return }
        switches = true
        // **From the card: it zooms to the full picture** and covers the switch. Not in a
        // group, not under AirPlay, not for the same episode (quality choice).
        let zooms = fromCard && !inGroup && airplayPlan == nil && episode.id != item.id
        if zooms {
            cardsEpisode = episode
            cardsClock = fillClock
            cardsSwitch = CardsSwitch(episodeID: episode.id)
            AppLog.writeOut("[Karte] Start → \(episode.id)")
            withAnimation(Self.spring(EpisodeCard.zoomOmega)) { cardsZoom = 1 }
            if let beginning = cardsSwitch?.beginning { Task { await cardGuard(beginning) } }
        }
        let swapOff = zooms ? Date().addingTimeInterval(EpisodeCard.swap) : nil
        model.doneWatch(position: position, duration: duration)
        let alt = (item: item, plan: plan, spot: position)
        // Already fetched in the last minutes (``EpisodePreparation``)? Then the switch does not wait for the server again.
        let prepared = preparation.take(episode.id)
        // Log start and first frame; the switch time can be read from that, with and without preparation.
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
                    // Swap only when the card covers the picture, otherwise black would show around it.
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
                    hint = String(localized: "Nächste Folge konnte nicht geladen werden.")
                    // The old episode keeps running, but the server already knows it as finished. The loop reports it anew.
                    startReported = false
                }))
            AppLog.writeOut("[Wechsel] \(result) → \(episode.id)")

            // **The switch is done here, so the latch drops here.**
            //
            // While it was set, `offering` returned `.nobody`, above it lay
            // `if wechselt { Loader() }`, and the loop stayed silent. It must not sit above the
            // lookup below: if that comes late, the picture would stand with a running clock
            // and no buttons.
            switches = false
            guard result == .switched else {
                if cardsSwitch != nil { cardBack() }
                return
            }
            // From the card the controls stay closed; the picture takes over.
            if cardsSwitch == nil {
                controlsVisible = true
                hideMove()
            }
            await lookUp(for: episode)
        }
    }

    /// The new episode's first frame is up: the preview fades out, and the episode is already running underneath, at the earliest from the swap.
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

    /// The switch failed: the card returns to the corner and leaves.
    private func cardBack() {
        AppLog.writeOut("[Karte] Wechsel gescheitert, zurück")
        withAnimation(Self.spring(EpisodeCard.distanceOmega)) { cardsZoom = 0 }
        cardCleanUp()
    }

    /// **Without a first frame the card yields to the loading screen.** While it is
    /// zoomed there are neither controls nor loading screen, so no way out; if the
    /// picture does not come (``Folgenkarte/weicht``), the ordinary loading screen with
    /// close takes over. The switch keeps running underneath.
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

    /// The card at the bottom right: in the tree as long as a next episode exists, so entering and leaving are springs from the current state.
    @ViewBuilder
    private var cardsLayer: some View {
        if let episode = cardsEpisode ?? nextEpisode, !inGroup {
            EpisodeCardsView(
                episode: episode,
                imageAddress: model.imageURL(for: episode, maxHeight: 1080)
                    ?? model.landscapeImageURL(for: episode, width: 1920),
                pad: mass.pad, page: mass.page,
                present: cardPresent, zoom: cardsZoom,
                detailsPresent: cardPresent && cardsSwitch == nil,
                image: cardImage,
                fillContent: cardsClock ?? fillClock,
                rest: layer.countdownRest,
                onTap: {
                    Theme.jerk(.lightweight)
                    layer.pressed()
                    toNextEpisode(episode, fromCard: true)
                },
                cancel: {
                    // Watch the outro: countdown gone, no more advancing at the end of the file (`OfferingLayer.nextCancelled`).
                    Theme.jerk(.lightweight)
                    layer.close()
                    fillSet()
                })
            .allowsHitTesting(cardPresent && cardsSwitch == nil)
            .animation(cardPresent ? Self.spring(EpisodeCard.appearOmega)
                                .delay(cardsSwitch == nil ? EpisodeCard.appearLag : 0)
                               : Self.spring(EpisodeCard.distanceOmega),
                       value: cardPresent)
        }
    }

    /// Take over the new episode: everything that belonged to the old one goes back.
    ///
    /// **The one place where old becomes new.** Every switch (card, countdown, end of
    /// episode, episode list, lock screen) arrives here via `toNextEpisode` and
    /// `EpisodeSwitch`, with a finished plan. A transition between episodes hooks in
    /// here: before it the old picture still shows, with `play` the new one begins.
    /// The track choice for opening: same inputs as `wendeLanguagesAn`, only already
    /// before `play`, so VLC starts with the right track.
    private func trackRequest(_ title: Item, _ plan: PlaybackPlan) -> VLCPlayerView.TrackRequest {
        VLCPlayerView.TrackRequest(audio: model.audioLanguage, subtitle: model.subtitleLanguage,
                                 automatic: model.subtitleAutomatic, source: plan.source,
                                 title: TrackMemory.title(for: title))
    }

    private func episodeApply(_ episode: Item, _ newPlan: PlaybackPlan, since: Double = 0) {
        if let cardsSwitch {
            AppLog.writeOut("[Karte] Tausch nach \(Int(cardsSwitch.since * 1000)) ms")
        }
        // Delay: the same series keeps it, otherwise zero.
        surface?.delayForNewTitle(oldTitle: item.id, oldSeries: item.seriesId,
                                            newTitle: episode.id, addedSeries: episode.seriesId)
        item = episode
        plan = newPlan
        // A limit was chosen but the original plays: either the file already fits or the server does not transcode. Say so instead of staying silent.
        if qualitySwitched {
            qualitySwitched = false
            if !model.alwaysDirectPlay, newPlan.method == .directPlay {
                hint = String(localized: "Läuft in Originalqualität. Der Server wandelt nichts um.")
            }
        }
        // The shared rule resets position, tracks, start report and the first frame.
        // Without the loading screen the loop would still pick up the **old** episode's
        // time on the next tick: the bar would jump to the end and advancing would fire
        // again. `startReported: true` because the switch reports the start.
        var state = PlaybackTick.Snapshot(position: position, duration: duration, running: running,
                                         firstImagePresent: firstImagePresent,
                                         tracksSet: tracksSet,
                                         startReported: startReported)
        PlaybackTick.newTitle(&state, startReported: true)
        position = state.position
        leap = state.leap
        firstImagePresent = state.firstImagePresent
        tracksSet = state.tracksSet
        startReported = state.startReported
        // **Starting mid-episode is a seek.** The display shows the start position
        // immediately and holds it until VLC is there; otherwise it would take the old
        // episode's time or the switch lock would hold it at zero. The loop sets the same
        // after its restart.
        if since > 0 {
            position = since
            leap = PlaybackTick.Jump(target: since)
            startPostSwitch = since
        }
        startFailed = false
        startAttempt += 1
        titleSwitch += 1
        // A new episode starts its own clock. If the old one stayed, the emergency brake
        // and freshness window would expire immediately; on tvOS exactly that skipped an
        // episode.
        sinceStart = Date()
        // **Nothing points at the old episode anymore**: "next episode" would
        // otherwise hold the now-running episode until the lookup, and the intro button
        // jumped to the previous episode's positions.
        nextEpisode = nil
        sections = []
        chapter = []
        layer.newEpisode()
        hubAdopt()
        surface?.buffer = model.bufferLevel
        surface?.trackRequest = trackRequest(episode, newPlan)
        surface?.play(url: newPlan.url, offSeconds: since, container: newPlan.container,
                      subtitle: model.subtitleFiles(newPlan),
                      softwareDecoder: newPlan.softwareDecoder)
    }

    /// Next episode and segments for the running title, on open and after every
    /// switch. A result that arrives too late for its title is discarded by
    /// `EpisodeSwitch.lookUp`.
    private func lookUp(for title: Item) async {
        // **No next episode in a group.** Everyone would otherwise advance on their own and the group would drift apart.
        await episodesSwitch.lookUp(fetch: { await model.episodePost(title) },
                                         adopt: { nextEpisode = sharedAn ? nil : $0 })
        await episodesSwitch.lookUp(fetch: { await model.sections(for: title.id) },
                                         adopt: { sections = $0 })
        // **Stays last.** The hub carries the "next episode" command, and that needs `nextEpisode`.
        hubAdopt()
    }

    // MARK: - To the TV and back

    /// The target has changed, so the player changes with it.
    ///
    /// **Two players, one position.** VLC hands over to `AVPlayer` and back; what is
    /// passed on is `position`, the view's state. Not VLC's time: after stopping it is
    /// no longer reliable, and resuming has failed on exactly that before.
    ///
    /// **If it does not work, say so.** Audio then still plays on the TV, just without
    /// picture, because the receiver rejects the stream. Without a message that looks
    /// like a bug in Swiftly, and it is not one.
    private func airplayToggle(_ an: Bool) {
        if an {
            guard airplayPlan == nil else { return }
            guard let client = model.client, let source = plan.source else { return }
            airplayTask?.cancel()
            airplayTask = Task {
                do {
                    let result = try await client.airplayPlan(for: item.id, source: source)
                    guard !Task.isCancelled else { return }
                    switch result {
                    case .goesNot(let suitability):
                        hint = suitability.message
                        AppLog.writeOut("[AirPlay] abgelehnt — "
                            + suitability.obstacles.map(\.codec).joined(separator: ", "))
                    case .goes(let new):
                        // **Log the reasons.** Without them only "transcode" appeared there, which does
                        // not say what the server objects to; exactly the information missing at the first
                        // black picture.
                        let grounds = new.reasons.isEmpty
                            ? "keine" : new.reasons.map(\.codec).joined(separator: ",")
                        AppLog.writeOut("[AirPlay] uebernimmt ab \(Int(position)) s"
                            + " — \(new.method.wireName), Gruende: \(grounds)"
                            + " — \(new.url.absoluteString.prefix(160))")
                        airplayOff = position
                        surface?.pause()
                        // The lock screen hangs on VLC's handles, which now point nowhere. `AVPlayer` brings its own display.
                        hub.handIn()
                        airplayPlan = new
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    hint = error.localizedDescription
                }
            }
        } else {
            airplayTask?.cancel()
            airplayTask = nil
            guard airplayPlan != nil else { return }
            let spot = position
            AppLog.writeOut("[AirPlay] zurueck aufs Geraet bei \(Int(spot)) s")
            airplayPlan = nil
            surface?.seek(toSeconds: spot)
            surface?.resume()
            hubAdopt()
        }
    }

    private func sleepTimeSet(_ minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes else { return }
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            surface?.pause()
            running = false
            controlsVisible = true
            hint = String(localized: "Schlafzeit abgelaufen.")
        }
    }

    private func controlsToggle() {
        controlsVisible.toggle()
        if controlsVisible { hideMove() } else { fadeOutMark += 1 }
    }

    /// Restarts the hide timeout.
    ///
    /// Only count up a mark; the timeout itself hangs on `.task(id:)`. The earlier
    /// version held the task itself and got stuck several times, leaving the controls
    /// permanently on screen.
    private func hideMove() { fadeOutMark += 1 }

    private func observe() async {
        VLCPlayerView.log.info("Player geöffnet, Startposition \(Int(startAt)) s")
        hubAdopt()
        hideMove()

        // The rules live in `PlaybackTick`, shared with the other platforms. What
        // remains here is what only the iPhone does: hide the controls, update the lock
        // screen, catch the stuck slider.
        var state = PlaybackTick.Snapshot()
        var lastSwitch = titleSwitch
        var beats = 0
        var onlyTime = false

        while !Task.isCancelled {
            try? await Task.sleep(for: PlaybackTick.displayTick)
            guard let surface else { continue }
            if sharedAn { bridgeCatchUp() }

            // **In between, only the time**: on the half-second tick it started late after
            // playing and counted unevenly. Same locks as in the full tick.
            onlyTime.toggle()
            if onlyTime {
                guard !switches else { continue }
                // **Only when someone sees the time** (battery). `position` is `@State`; every
                // assignment rebuilds the whole player and creates new time rows in the invisible
                // controls. With the controls hidden nothing shows the half second, so it stays at
                // the full tick: half as many rebuilds, for the whole film. An open seek keeps
                // running on the half tick.
                guard timeVisible || leap != nil else { continue }
                state.position = position
                state.leap = leap
                state.firstImagePresent = firstImagePresent
                PlaybackTick.timeAdopt(&state,
                                               reported: restoring ? surface.goodPoint : surface.positionSeconds,
                                               atPush: atPush, sinceStart: sinceStart)
                position = state.position
                leap = state.leap
                continue
            }

            // Safety: if scrubbing gets stuck anyway, reset itself after three seconds without movement.
            if atPush, let recent = lastPushed,
               Date().timeIntervalSince(recent) > 3 {
                atPush = false
            }

            // Take over the view's state: it changes `position` while the finger is on the slider.
            state.position = position
            state.leap = leap
            state.duration = duration
            state.running = running
            state.firstImagePresent = firstImagePresent
            state.tracksSet = tracksSet
            state.startReported = startReported

            // A title change is announced: reset the state, via the shared rule.
            // `sinceMessage` lives only here and would otherwise have survived the switch; the
            // new episode's first report would have come immediately instead of after ten
            // seconds.
            if titleSwitch != lastSwitch {
                lastSwitch = titleSwitch
                // `true` because the switch reported the start itself.
                PlaybackTick.newTitle(&state, startReported: true)
                // From the episode list into the middle of an episode: see `episodeApply`.
                if let since = startPostSwitch {
                    startPostSwitch = nil
                    state.afterChange = false
                    state.position = since
                    state.leap = PlaybackTick.Jump(target: since)
                }
            }

            // **Arrived means arrived.** Whether VLC is at the target of a seek is decided by
            // `PlaybackTick` from `state.sprung`. A latch used to hold the display for two
            // seconds even when VLC had long been there.
            let job = PlaybackTick.compute(
                &state,
                measurement: .init(duration: surface.durationSeconds,
                               position: surface.positionSeconds,
                               goodPoint: surface.goodPoint,
                               showsImage: surface.showsImage,
                               seeksToStart: surface.seeksToStart,
                               running: surface.isPlaying,
                               // **Read the track list only while it is needed.** `PlaybackTick` asks
                               // `hasAudioTracks` alone until the tracks are set; afterwards the value is unused.
                               // It was read anyway, twice per second for the whole film. `player.audioTracks`
                               // rebuilds the list each time, under the running player's lock. Exactly the
                               // permanent grab the comment at `FrameTick.stillPostMeasure` a few lines up warns
                               // about; the `||` short-circuits it once it carries nothing.
                               hasAudioTracks: tracksSet || !surface.audioTracks.isEmpty),
                restoring: restoring,
                atPush: atPush,
                sinceStart: sinceStart)

            position = state.position
            leap = state.leap
            duration = state.duration
            running = state.running
            tracksSet = state.tracksSet
            startReported = state.startReported

            if job.loadingScreenGone {
                StartMeasurement.shared.mark("Ladeschirm weicht")
                if let beginning = switchStart {
                    switchStart = nil
                    AppLog.writeOut("[Wechsel] erstes Bild nach \(Int(Date().timeIntervalSince(beginning) * 1000)) ms")
                }
                if let k = cardsSwitch, k.imageSince == nil {
                    cardsSwitch?.imageSince = k.since
                    AppLog.writeOut("[Karte] erstes Bild nach \(Int(k.since * 1000)) ms")
                    Task { await cardHandOver() }
                }
                withAnimation(.easeOut(duration: 0.3)) { firstImagePresent = true } completion: {
                    StartMeasurement.shared.mark("Ladeschirm ausgeblendet")
                }
                // From a handover: the card now zooms onto the picture.
                HandoffStage.shared.imagePresent(item.id)
                hideMove()
            }
            if job.tracksApply {
                surface.wendeLanguagesAn(audio: model.audioLanguage,
                                        subtitle: model.subtitleLanguage,
                                        automatic: model.subtitleAutomatic,
                                        source: plan.source,
                                        title: TrackMemory.title(for: item))
            }
            if job.tracksApply { surface.channelsPostMeasure() }
            // Stay silent during the switch. Otherwise progress goes out for the **old**
            // title after its end was already reported, breaking the order the reporting order promises.
            if job.startReport, !switches {
                // The actual position, not the target: since the start is only reported once a
                // picture is up, the settling lies in between. For large files that is up to 25
                // seconds.
                model.reportStart(item: item, plan: plan, seconds: state.position)
            }
            if job.progressReport, !switches {
                notifyProgress()
                #if DEBUG
                print("[App] Position \(Int(position)) s · Dauer \(Int(duration)) s · läuft \(running) · schiebt \(atPush)")
                #endif
            }

            // **The overlay** (card countdown). It pauses while paused.
            let cardBefore = cardPresent
            if offeringCatchUp(elapsed: PlaybackTick.tickLength / .seconds(1)),
               let episode = nextEpisode {
                AppLog.writeOut("[Karte] Countdown abgelaufen")
                toNextEpisode(episode, fromCard: cardBefore)
            }
            #if DEBUG
            if JumpRun.an || OfflineRun.an { jumpTickWrite(vlc: surface.positionSeconds) }
            #endif

            // **Prepare the next episode** while this one is still playing; not in a group,
            // which advances by itself. Once per episode; when and over which network is up to
            // `Prebuffer`.
            if let episode = nextEpisode, !inGroup, !switches,
               Prebuffer.now(position: position, duration: duration,
                               creditsFrom: sections.first { $0.art == .credits }?.from,
                               networkFavorable: preparation.networkFavorable),
               prebufferAllowed {
                preparation.prepare(episode) { await model.plan(for: episode.id, still: true) }
            }

            // Advance by itself at the end, only with a card (outro segment from the
            // server), and not if it was cancelled. The "next episode automatically" switch no
            // longer matters here.
            // **If the card counts, advancing belongs to it** (seeked to the end, and
            // `position >= dauer - 1` switched immediately).
            if layer.nextAtEnd, let episode = nextEpisode, !switches,
               EpisodeEnd.advance(position: position, duration: duration,
                                         sinceOpen: Date().timeIntervalSince(sinceStart),
                                         cardCounts: layer.cardCounts) {
                AppLog.writeOut("[Wechsel] Dateiende ohne Karte")
                toNextEpisode(episode)
            }

            beats += 1
            // The lock screen needs the position only once per second.
            if beats % 2 == 0 {
                hub.stateCatchUp(position: position, running: running, tempo: tempo)
            }
        }
    }

    #if DEBUG
    /// One line per tick for the `Sprunglauf`.
    private func jumpTickWrite(vlc: Double) {
        AppLog.writeOut("[Sprungtakt] Anzeige \(String(format: "%.1f", position))"
            + " · VLC \(String(format: "%.1f", vlc)) · Angebot \(offering) · Ebene \(layer.display)")
    }
    #endif

    /// Tells the system what is playing and takes its commands.
    private func hubAdopt() {
        hub.adopt(.init(
            // **Command, do not ask.** These closures are registered once and hold the view
            // as it was at that moment, since SwiftUI views are values. `running` in them did
            // not say what is playing now but what played on open, which is always `true`. So
            // "pause" always paused, and "play" never did anything.
            //
            // It stayed invisible because **writing** works: `@State` stores its values
            // outside the struct. Only reading yields the old state. The tvOS side found it
            // where the hub is the only path; on the phone it applies only from the lock
            // screen, Control Center and the headphone button, and nobody had tried those
            // after pausing.
            play:   inGroup ? { gemeinsam.bitToggle(runningCurrently: false) }
                                  : { resume(); runState(true) },
            halt:    inGroup ? { gemeinsam.bitToggle(runningCurrently: true) }
                                  : { surface?.pause();  runState(false) },
            toggle:  { togglePlaying() },
            jumpOn: inGroup ? { target in gemeinsam.bitJump(on: target); jumped(on: target) }
                                  : { target in surface?.seek(toSeconds: target); jumped(on: target) },
            forward:         { scrub(Int32(model.forwardSeconds)) },
            back:     { scrub(Int32(-model.backSeconds)) },
            next:    inGroup ? nil : nextEpisode.map { episode in { toNextEpisode(episode) } }))
        hubReport()
    }

    private func hubReport() {
        hub.report(item: item, position: position, duration: duration, tempo: tempo,
                        running: running,
                        jumpDistance: (model.backSeconds, model.forwardSeconds),
                        imageUrl: model.lockImageURL(for: item))
    }


    /// Only enqueues; the queue in the model sends.
    private func notifyProgress() {
        model.reportProgress(item: item, plan: plan, seconds: position, paused: !running)
    }

    private func time(_ seconds: Double) -> String { PlayTime.text(seconds) }

}

/// Feedback on double tap: the same rotation as on the buttons, so button and double tap do not look like two different things.
private struct JumpMark: View {
    let bearing: Int
    let seconds: Int
    @State private var rotated = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: bearing < 0 ? "gobackward" : "goforward")
                .font(.system(size: 32, weight: .medium))
                // See the button above: with reduced motion the value stays and the effect does not play.
                .symbolEffect(.bounce, options: .speed(1.7),
                              value: Theme.motionReduced ? false : rotated)
            // Before: `.footnote.weight(.medium)`, the same step (13 Medium) but as a system
            // size that scales with the system font; the player stays fixed.
            // With a sign because it counts up: +10 s, +20 s, +30 s.
            Group {
                if bearing < 0 { Text("−\(seconds) s") } else { Text("+\(seconds) s") }
            }
            .font(Theme.tile)
            .monospacedDigit()
        }
        .foregroundStyle(Theme.font)
        .frame(width: 108, height: 108)
        .background(.black.opacity(0.45), in: Circle())
        .onAppear { rotated = true }
    }
}

struct VideoSurfaceHost: UIViewRepresentable {
    let url: URL
    let startAt: Double
    let container: String?
    /// Passed in instead of fetched here: this view does not know the model, and should not.
    let buffer: BufferLevel
    /// External subtitles, likewise before `play`.
    var subtitle: [SubtitleFile] = []
    /// Open with the software decoder right away, ``PlaybackPlan/softwareDekoder``.
    var softwareDecoder = false
    /// The desired tracks, also before `play`.
    var tracks: VLCPlayerView.TrackRequest?
    let onCreate: (VLCPlayerView) -> Void

    func makeUIView(context: Context) -> VLCPlayerView {
        let view = VLCPlayerView()
        // Set before the start, not after: the options hang on the media, which is created in `play`.
        view.buffer = buffer
        view.trackRequest = tracks
        view.play(url: url, offSeconds: startAt, container: container, subtitle: subtitle,
                  softwareDecoder: softwareDecoder)
        DispatchQueue.main.async { onCreate(view) }
        return view
    }

    func updateUIView(_ view: VLCPlayerView, context: Context) {}

    /// Without this the watchdog timer of the torn-down view runs forever; visible in
    /// the device log as a tick with 'spielt false'. `stop()` in onDisappear is not
    /// reliable: it hits the view that `surface` points to, not necessarily every one
    /// SwiftUI created.
    static func dismantleUIView(_ view: VLCPlayerView, coordinator: ()) {
        MainActor.assumeIsolated { view.stop() }
    }
}


/// **Dimming plus gradient at top and bottom, without a single input.**
///
/// Without the scrim white symbols are unreadable over bright scenes.
///
/// As a computed property it sat in `PlayerScreen`'s `body` and was recomputed on
/// **every** tick, twice per second, with three gradients, while VLC delivers
/// frames. As its own type **without stored values** SwiftUI compares the inputs,
/// finds none changed, and skips `body`.
private struct PlayerScrim: View {
    /// How far the bands reach. At the top it covers status bar, title, meta line and the button row; at the bottom the skip pill, the time row and the safe area below.
    private static let heightTop: CGFloat = 200
    private static let heightBottom: CGFloat = 260

    var body: some View {
        // **Pure black, not `Theme.reason`.** Over HDR video #0B0B0D is tone-mapped up as
        // an SDR color and lifts dark scenes: the controls made the picture brighter
        // instead of darker. As on tvOS.
        // **The surface leads the size, the bands lie on top.**
        //
        // There used to be a `ZStack` with a `VStack` whose two fixed bands added up to a
        // **460 point minimum height**. Before, the scrim was a bare `Color`, which has no
        // size of its own and fits any frame, including the small window player. With the
        // minimum height it stuck out there, and everything on it with it. Reported as
        // "the player is broken, the elements stick out of the player".
        //
        // As an `overlay` on the surface the bands do not count toward the size, so the
        // surface stays freely stretchable, and `clipped()` keeps them in their frame if
        // that is ever smaller.
        Color.black.opacity(0.45)
            .overlay(alignment: .top) { bandTop }
            .overlay(alignment: .bottom) { bandBottom }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// Top: held until the button row ends, then eased out. A gradient that fades
    /// right at the top edge is weakest exactly where the title sits: 0.55 over the
    /// surface adds up to 0.752, so the title gets 9.68:1 and the meta line in
    /// `schriftLeise` 4.66:1.
    private var bandTop: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                               .init(color: .black.opacity(0.55), location: 0.45),
                               .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: Self.heightTop)
    }

    /// Bottom reversed and densest at the edge, where the time row sits. 0.62 over
    /// the surface adds up to 0.791: 11.27:1 instead of the 5.70:1 the flat version
    /// reached. The edge became **more readable**, not just the middle brighter.
    private var bandBottom: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0),
                               .init(color: .black.opacity(0.42), location: 0.55),
                               .init(color: .black.opacity(0.62), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: Self.heightBottom)
    }
}

/// **Time display, slider and remaining time: the only part the tick touches.**
///
/// `PlaybackTick.tickLength` is 500 ms, and every tick writes `position`. If this
/// lived in `PlayerScreen`'s `body`, every tick would pull the whole tree through:
/// header, center controls, tap areas, gestures. As its own type the time is
/// limited to these three rows.
private struct TimeRow: View {
    @Binding var position: Double
    let duration: Double
    let atPush: Bool
    let font: CGFloat
    let pad: Bool
    /// Hit area of the slider above the row (`Playermass.sliderTop`).
    let sliderTop: CGFloat
    /// The trickplay image for the position, or `nil`.
    let preview: (Double) -> CGImage?
    /// Segment boundaries in seconds: notches on the slider.
    let marks: [Double]
    /// The chapters: pieces on the slider, their name above the handle.
    let chapter: [Chapter]
    /// `true` on touch, `false` on release.
    let schiebt: (Bool) -> Void
    /// How wide the box above the handle really is; with a chapter name but without a preview image it depends on the name.
    @State private var boxWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 14) {
            // The slider already speaks both times ("12 minutes of 45 minutes"); as digits
            // with a colon VoiceOver read them a second time, and worse.
            Text(PlayTime.text(position))
                .accessibilityHidden(true)
            TimeSlider(value: $position, until: max(duration, 1), marks: marks, chapter: chapter,
                       hitTop: sliderTop, onPush: schiebt)
                .overlay(alignment: .topLeading) {
                    if atPush { previewBox }
                }
            remainingTime
        }
        .font(.system(size: font).monospacedDigit())
        // **`schriftLeise` cannot be saved here.** At 13 point the row sits on the player
        // scrim over the running picture: over a white scene `schriftLeise` gave 1.34:1,
        // threshold 4.5. Under the gradient band at the foot (0.791 combined) `font`
        // reaches 11.27:1. Elapsed and remaining time are not minor; they are the reason
        // you look here.
        .foregroundStyle(Theme.font)
    }

    /// **Remaining time or end: a tap toggles** (1.0.5, to try out). "-12:34" or
    /// "Ends at 22:41"; the choice persists. No separate button, no second row: same
    /// place, same font.
    @AppStorage("restzeitAlsEnde") private var asEnd = false

    private var remainingTime: some View {
        let rest = max(duration - position, 0)
        return Button {
            asEnd.toggle()
        } label: {
            Group {
                if asEnd {
                    Text("Endet um \(Date().addingTimeInterval(rest).formatted(date: .omitted, time: .shortened))")
                } else {
                    Text(verbatim: "−" + PlayTime.text(rest))
                }
            }
            .lineLimit(1)
            .contentShape(Rectangle().inset(by: -10))
        }
        .buttonStyle(.plain)
        // For VoiceOver a toggle with state; the slider already reads the time itself.
        .accessibilityLabel(asEnd ? Text("Endet um \(Date().addingTimeInterval(rest).formatted(date: .omitted, time: .shortened))")
                                    : Text("Restzeit"))
        .accessibilityHint(Text("Wechselt zwischen Restzeit und Ende"))
    }

    /// **Above the handle: preview image, below it the time.** Without trickplay on
    /// the server only the time, no empty box.
    ///
    /// **With chapters its name comes before the time**, in the same capsule: one line,
    /// not two, so the box does not get taller and the bottom edge stays where it was
    /// set. A long name is truncated, not the time.
    private var previewBox: some View {
        GeometryReader { g in
            let image = preview(position)
            let width: CGFloat = pad ? 200 : 160
            let height = width * 9 / 16
            let share = duration > 0 ? min(max(position / duration, 0), 1) : 0
            let name = ChapterBar.chapter(at: position, in: chapter)?.name ?? ""
            // At the edge the box stays fully on the bar.
            let half = image != nil ? width / 2 : max(name.isEmpty ? 40 : boxWidth / 2, 40)
            let x = min(max(g.size.width * share, half), max(g.size.width - half, half))
            VStack(spacing: 6) {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                        // Borders are `Theme.rand`. Before: white 35%, a second number for the same role.
                        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                            .strokeBorder(Theme.margin, lineWidth: 1))
                }
                HStack(spacing: 6) {
                    if !name.isEmpty {
                        Text(verbatim: name)
                            .font(.system(size: font))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(PlayTime.text(position))
                        // Only the page title carries Bold, so Semibold here. The size stays `mass.zeit`, which scales with the window size.
                        .font(.system(size: font, weight: .semibold).monospacedDigit())
                        .layoutPriority(1)
                }
                .foregroundStyle(Theme.font)
                // **Its own surface because no scrim lies here.** The time sat bare over the
                // trickplay still: over a white image 1.09:1, threshold 4.5. On `Theme.reason` at
                // 0.82 (same opacity as the tech badge) it is 10.93:1, over any still.
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.reason.opacity(0.82)))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            // At most as wide as the preview image, otherwise a long chapter name would push the capsule past the edge of the bar.
            .frame(maxWidth: width)
            .fixedSize(horizontal: false, vertical: true)
            // Bottom edge just above the hit area; the bar itself sits in its middle.
            // `font + 6`: the capsule around the time has 3 points of air top and bottom.
            // Without the 6 the box would slip down by 3 points; the bottom edge should stay
            // where it was set.
            .position(x: x, y: -((image == nil ? 0 : height + 6) + font + 6) / 2 - 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// **"Skip intro" / "Next episode": the same button.**
///
/// Own type because `offering` is computed from `position` and `dauer` and so is
/// recomputed on every tick.
///
/// **That does not make it skipped.** `ButtonOffering` is `Equatable`, but the
/// closure `action` is not, and SwiftUI compares the view field by field. A
/// function field cannot be compared, so it redraws. The gain here is that the work
/// stays confined to this button instead of living in the player's `body`; anyone
/// who really wants to save it would have to replace `action` with something
/// comparable. The same holds for `TimeRow`, which is meant to redraw every tick.
///
/// **The only one that really is skipped is `Playerschleier`**: it has no stored
/// values at all.
private struct OfferingButton: View {
    /// Text on the white pill: the player's background, #0B0B0D.
    private static let dark = Theme.reason
    let offering: ButtonOffering
    /// Countdown to the next episode as a fill from the left, computed from the clock and updated on every frame, not on the tick.
    var fillContent: FillClock? = nil
    /// Seconds until the switch, for VoiceOver.
    var rest: Int = 0
    let action: () -> Void

    var body: some View {
        if offering.visible {
            Button(action: action) {
                // No server data is involved, but the label is built as a `String` in the
                // package, hence `Text(verbatim:)` instead of `Label(_:)`, otherwise it would be
                // looked up a second time.
                // **White pill with the skip symbol** (triangle and bar), for both offers, as in
                // the draft.
                HStack(spacing: 8) {
                    Image(systemName: "forward.end.fill")
                    Text(verbatim: offering.label)
                }
                // Before: 15 Bold. Bold appears exactly once, at the page title. The step below is 15 Semibold.
                .font(Theme.listTitle)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background {
                    ZStack(alignment: .leading) {
                        // The one filled surface in the picture is the main button, and its color is `font`. Before: raw `.white`.
                        RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous).fill(Theme.font)
                        if let fillContent {
                            // **Continuous instead of on the tick**: updated on the half-second tick it
                            // stuttered at the start and near the end. **Dark on white**, not in accent
                            // color, which in the player belongs to the scrubber handle while seeking.
                            TimelineView(.animation) { time in
                                GeometryReader { g in
                                    Rectangle()
                                        .fill(Self.dark.opacity(0.16))
                                        .frame(width: g.size.width * fillContent.share(now: time.date))
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                }
            }
            .buttonStyle(Theme.PressButton())
            .foregroundStyle(Self.dark)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: offering.label))
            .accessibilityValue(fillContent.map {
                _ in Text("Startet in \(rest) Sekunden")
            } ?? Text(verbatim: ""))
        }
    }
}
