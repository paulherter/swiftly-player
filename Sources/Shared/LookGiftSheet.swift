import JellyfinKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

// **The Halloween gift, and the looks sheet everyone can use** (design "Halloween look",
// version 2, boards G1 to G3).
//
// One system sheet goes through the steps: the offer ("A look for you"), picking it up (the
// icon springs to the middle, the app turns orange under it), and the looks sheet with the
// original and the gift. The same looks sheet opens from the profile and from Settings →
// Appearance. Also "What's new" after an update lives in this sheet, so there is only ever
// one sheet from below.
//
// **One looks panel for everything** (profile "Change", "Try a look", Settings): the real
// home page under it, a row with every look. Looks this person may not wear (supporter
// looks) show greyed; a tap previews them, nothing is stored, and only a debug build offers
// the purchase.
//
// Included in the iPhone/iPad, Mac and Apple TV targets (on TV: the flow and the tile only).

/// **Where the gift sheet stands, for the whole app**, and the one rule that keeps big
/// asks apart: at most one per session (the gift, What's New, the support sheet, the rating
/// prompt, the Discord hint).
@MainActor
@Observable
final class GiftFlow {
    static let shared = GiftFlow()

    enum Stage: Equatable {
        case whatsNew(WhatsNewEntry)
        case offer(Look)
        /// "Grab it" was pressed: the short animation before the looks sheet.
        case claiming(Look)
        /// The looks sheet; `fromGift`: the icon lands in its row.
        case choosing(fromGift: Bool)
    }

    /// The sheet is open on this step; `nil`: closed.
    var stage: Stage?
    /// The looks panel is up, over the real home page: nothing on the page reacts to a tap.
    var looksOpen: Bool {
        if case .choosing = stage { return true }
        return false
    }
    /// One big ask showed this session.
    private(set) var bigAskShown = false
    /// Since when the loaded home page is on screen; `nil` while it is not.
    private(set) var homeSince: Date?
    /// Counts "go to the home page, and close whatever lies above it"; `MainView` steps
    /// there on every change. The profile slides away to the right as it does on "back".
    private(set) var homeRequests = 0

    private init() {}

    var presented: Bool {
        get { stage != nil }
        set { if !newValue { close() } }
    }

    // MARK: Asks

    /// Another big ask showed (support sheet, rating, Discord hint): the gift waits.
    func noteBigAsk() { bigAskShown = true }

    /// The home page has its rows, or went away.
    func homeVisible(_ visible: Bool) {
        if visible {
            if homeSince == nil { homeSince = .now }
        } else {
            homeSince = nil
        }
    }

    /// **Called a moment after the home page came up.** Shows What's New after an update,
    /// else the gift once in its window. Nothing during playback, nothing on top of another
    /// sheet, nothing when the session already asked.
    func evaluate(model: AppModel) {
        guard stage == nil, !bigAskShown, let homeSince, model.phase == .ready,
              !model.playerOpen, !model.ratingDue, !model.discordHintDue,
              !SupportModel.shared.presented else { return }
        let store = LookStore.shared

        // What's New first: it carries the gift itself when there is one.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let entry = WhatsNewEntry.bundled(for: version)
        let defaults = UserDefaults.standard
        switch WhatsNew.decide(lastSeen: defaults.string(forKey: WhatsNew.lastSeenKey),
                               usedBefore: SupportModel.shared.usedBeforeThisLaunch,
                               current: version, hasEntry: entry != nil) {
        case .show:
            defaults.set(version, forKey: WhatsNew.lastSeenKey)
            if let entry {
                if let gift = entry.giftLook, giftDue(gift, store: store) { markOffered(gift) }
                show(.whatsNew(entry))
                return
            }
        case .markSeen:
            defaults.set(version, forKey: WhatsNew.lastSeenKey)
        case .nothing:
            break
        }

        let context = LookGift.Context(
            now: LookClock.now, homeReady: true, playing: model.playerOpen, askedThisSession: bigAskShown,
            secondsOnHome: Date.now.timeIntervalSince(homeSince), owned: store.owned, offered: offered)
        guard let gift = LookGift.due(context) else { return }
        markOffered(gift)
        show(.offer(gift))
    }

    /// Whether a sheet with this gift may still offer it (in the window, not owned).
    func giftDue(_ look: Look, store: LookStore = .shared) -> Bool {
        !store.owned.contains(look.id) && (look.availability?.isActive(at: LookClock.now) ?? false)
    }

    private var offered: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: LookStorageKey.giftOffered) ?? [])
    }

    private func markOffered(_ look: Look) {
        guard let id = LookGift.offerID(look, at: LookClock.now) else { return }
        var all = offered
        all.insert(id)
        UserDefaults.standard.set(all.sorted(), forKey: LookStorageKey.giftOffered)
    }

    private func show(_ stage: Stage) {
        bigAskShown = true
        self.stage = stage
    }

    // MARK: Actions

    /// The looks sheet over the page that is showing (from What's New, from the home page).
    func openLooks() {
        stage = .choosing(fromGift: false)
    }

    /// **The looks sheet from a page deeper in the app** (profile, settings): that page
    /// slides away to the right, the home page shows, and the sheet comes up over it, so
    /// closing the sheet leaves the person on the home page. One movement after the
    /// other, never two at once (`Motion.pageBeforeSheet`).
    func goHome() { homeRequests += 1 }

    func openLooksOnHome(trying look: Look? = nil) {
        goHome()
        Task {
            try? await Task.sleep(for: .seconds(Theme.motionReduced ? 0 : Motion.pageBeforeSheet))
            openLooks()
            // A look that may not be worn: the panel opens with it as a preview.
            if let look {
                let store = LookStore.shared
                let next = store.saved.switching(to: look)
                guard !store.mayWear(next) else { return }
                withAnimation(Motion.change) {
                    store.beginPreview()
                    store.tryOn(next)
                }
            }
        }
    }

    /// "Grab it": picked up for good the moment it is pressed; the app turns to the look
    /// while the icon springs to the middle, then the looks sheet comes.
    func grab(_ look: Look) {
        // A second tap while the icon is on its way must not claim again.
        if case .claiming = stage { return }
        #if os(iOS)
        Theme.jerk(.lightweight)
        #endif
        let reduced = Theme.motionReduced
        withAnimation(Motion.change) {
            _ = LookStore.shared.claim(look)
            stage = reduced ? .choosing(fromGift: true) : .claiming(look)
        }
        // The icon follows when the looks sheet closes: the system's notice about a new
        // icon would land in the middle of the animation.
        guard !reduced else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard stage == .claiming(look) else { return }
            withAnimation(Motion.land) {
                stage = .choosing(fromGift: true)
            }
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
        }
    }

    /// "Use" in the looks sheet.
    func use(_ selection: LookSelection) {
        let store = LookStore.shared
        if selection != store.saved {
            withAnimation(Motion.change) { _ = store.choose(selection) }
        }
        close()
    }

    func close() {
        // Pulled down or X on the looks sheet: the icon follows what is worn, as on "Use".
        // A look only previewed (not allowed) goes back first.
        switch stage {
        case .choosing, .claiming:
            if LookStore.shared.isPreviewing {
                withAnimation(Motion.change) { LookStore.shared.endPreview() }
            }
            let icon = LookStore.shared.palette.iconName
            Task { await LookIcon.apply(icon) }
        default:
            break
        }
        stage = nil
    }

    #if DEBUG
    /// **Launch arguments for looking at the steps without tapping** (debug builds):
    /// `-lookReset` starts from before the gift; `-lookDemo whatsnew|offer|looks` opens
    /// that step a moment after launch. With `-lookDate` (see `LookClock`) for the season.
    static func debugLaunch() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-lookReset") {
            LookStore.shared.reset()
            shared.reset()
        }
        guard let index = arguments.firstIndex(of: "-lookDemo"), index + 1 < arguments.count else { return }
        let step = arguments[index + 1]
        Task {
            try? await Task.sleep(for: .seconds(4))
            switch step {
            case "whatsnew":
                if let entry = WhatsNewEntry.bundled(for: "1.0.8") { shared.show(.whatsNew(entry)) }
            case "offer":
                shared.show(.offer(.halloween))
            case "looks":
                shared.openLooks()
            default:
                break
            }
        }
    }

    /// Back to before the gift (Settings → Swiftly → Preview → Reset).
    func reset() {
        stage = nil
        bigAskShown = false
        UserDefaults.standard.removeObject(forKey: LookStorageKey.giftOffered)
        UserDefaults.standard.removeObject(forKey: WhatsNew.lastSeenKey)
    }
    #endif
}

// Everything from here to `LookTile` is views for iPhone, iPad and Mac; Apple TV has its own
// (`Sources/tvOS/TVLooks.swift`) and only takes the flow above and the tile.
#if !os(tvOS)
// MARK: - Presentation

extension View {
    /// **The gift sheet and when it comes**, once at the root of the app.
    func giftPresentation(model: AppModel) -> some View {
        modifier(GiftPresentation(model: model))
    }
}

private struct GiftPresentation: ViewModifier {
    let model: AppModel
    @Bindable private var flow = GiftFlow.shared

    /// Something on screen that the gift must not land on.
    private var blocked: Bool {
        model.playerOpen || SupportModel.shared.presented
    }

    func body(content: Content) -> some View {
        content
            .environment(\.looksPreviewing, flow.looksOpen)
            .modifier(GiftSheetPresenter(flow: flow))
            // A moment after the home page came up, and again when nothing showed then
            // because the player or another sheet was open.
            .task(id: flow.homeSince) {
                guard flow.homeSince != nil else { return }
                try? await Task.sleep(for: .seconds(LookGift.quietAfterHome))
                flow.evaluate(model: model)
            }
            // Again when what kept it back is gone: the player, or a sheet opened by a tap
            // (a sheet opened by the rules counts as this session's ask and keeps it back).
            .onChange(of: blocked) { _, blocked in
                guard !blocked, flow.homeSince != nil else { return }
                Task {
                    try? await Task.sleep(for: .seconds(LookGift.quietAfterHome))
                    flow.evaluate(model: model)
                }
            }
            .task {
                // The look icons are decoded now, not when the panel opens.
                #if os(iOS)
                LookTileCache.prewarm()
                #endif
                #if DEBUG
                GiftFlow.debugLaunch()
                #endif
                // The Dock icon is not kept by the system, and a gift's icon whose look is no
                // longer worn goes back.
                await LookIcon.restore()
            }
    }
}

// MARK: - The sheet

/// **Where the sheet hangs.** On iPhone and iPad it is the app's own flush sheet
/// (`.sheet(opened:)`): Apple's sheet with a partial height floats on iOS 26 and leaves a
/// strip of the page under it. On the Mac the system sheet is flush already. The looks
/// panel has no scrim: the home page under it stays in its colors.
private struct GiftSheetPresenter: ViewModifier {
    let flow: GiftFlow
    @State private var lastTone = Color.clear
    @State private var lastTint: Color?

    /// The light at the top of the card: the look being offered, else the look worn now.
    private var tone: Color {
        let offered: Look? = switch flow.stage {
        case let .offer(look): look
        case let .whatsNew(entry): entry.giftLook
        default: nil
        }
        return (offered?.glowColor ?? LookStore.shared.palette.glowColor).color
    }

    /// The faint second tone of the same light, from the look's mark gradient.
    private var tint: Color? {
        let offered: Look? = switch flow.stage {
        case let .offer(look): look
        case let .whatsNew(entry): entry.giftLook
        default: nil
        }
        return (offered?.glowTint ?? (offered == nil ? LookStore.shared.palette.glowTint : nil))?.color
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .sheet(opened: Binding(get: { flow.presented },
                                   set: { if !$0 { flow.close() } }),
                   dimmed: !flow.looksOpen,
                   light: flow.stage == nil ? lastTone : tone,
                   lightTint: flow.stage == nil ? lastTint : tint) {
                GiftSheet()
            }
            .onChange(of: tone, initial: true) { _, new in
                if flow.stage != nil { lastTone = new }
            }
            .onChange(of: tint, initial: true) { _, new in
                if flow.stage != nil { lastTint = new }
            }
        #else
        // flush-ok: macOS sheets do not float.
        content.sheet(isPresented: Binding(get: { flow.presented },
                                           set: { if !$0 { flow.close() } })) {
            GiftSheet()
        }
        #endif
    }
}

/// The one sheet, through its steps. **It is as tall as its content**: nothing is cut off,
/// whatever the text size; a change of step slides the sheet to the new height.
private struct GiftSheet: View {
    @Namespace private var icon
    @Environment(\.dynamicTypeSize) private var typeSize
    private var flow: GiftFlow { .shared }
    /// The last step that was on screen: while the sheet slides out, `stage` is already
    /// `nil` and the content must not go blank under the closing card.
    @State private var lastStage: GiftFlow.Stage?
    /// How tall the offer is, so the pick-up animation keeps that height.
    @State private var offerHeight: CGFloat = 400

    private var stage: GiftFlow.Stage? { flow.stage ?? lastStage }

    var body: some View {
        #if os(iOS)
        Group {
            // At the accessibility text sizes the sheet is tall and scrolls.
            if typeSize.isAccessibilitySize {
                ScrollView { steps.padding(.bottom, 24) }
                    .scrollBounceBehavior(.basedOnSize)
                    .containerRelativeFrame(.vertical) { height, _ in height * 0.8 }
            } else {
                steps
                    .frame(maxWidth: .infinity, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: flow.stage) { _, new in if let new { lastStage = new } }
        .onAppear { if let current = flow.stage { lastStage = current } }
        #else
        steps
            .frame(width: 480, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .background(alignment: .top) { SheetLight() }
            .presentationBackground(Theme.area)
        #endif
    }

    private var steps: some View {
        // **No `.animation(nil, …)` and no `.transaction` here.** The content travels with the
        // card because `SheetModifier` inserts it while the card is still below the screen
        // (`settled`), not inside the slide-up animation.
        content
    }

    private var content: some View {
        Group {
            switch stage {
            case let .whatsNew(entry):
                WhatsNewSheet(entry: entry, giftAvailable: entry.giftLook.map { flow.giftDue($0) } ?? false,
                              icon: icon)
            case let .offer(look):
                GiftOffer(look: look, icon: icon)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { offerHeight = $0 }
            case let .claiming(look):
                GiftClaiming(look: look, icon: icon)
                    .frame(height: offerHeight)
            case let .choosing(fromGift):
                LooksPanel(fromGift: fromGift, icon: icon)
            case nil:
                Color.clear.frame(height: 300)
            }
        }
    }
}

#if os(macOS)
/// **The light at the top of the Mac sheet**, in the tone of the look worn now: one
/// gradient, gone at about a quarter of the height. (On iPhone and iPad the sheet draws it
/// itself, over the whole card: `SheetModifier.light`.)
private struct SheetLight: View {
    var body: some View {
        let offered: Look? = switch GiftFlow.shared.stage {
        case let .offer(look): look
        case let .whatsNew(entry): entry.giftLook
        default: nil
        }
        let tone = (offered?.glowColor ?? LookStore.shared.palette.glowColor).color
        let tint = (offered?.glowTint ?? (offered == nil ? LookStore.shared.palette.glowTint : nil))?.color
        CardLight(tone: tone, tint: tint)
            .frame(maxWidth: .infinity)
    }
}
#endif

// MARK: G1: the offer

private struct GiftOffer: View {
    let look: Look
    let icon: Namespace.ID
    private var flow: GiftFlow { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LookTile(look: look, size: 76)
                .matchedGeometryEffect(id: "gift", in: icon)
                .padding(.top, 36)
            Text("Ein Look für dich 🎃")
                .giftFont(24, .semibold)
                .foregroundStyle(Theme.font)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 20)
            Text("Danke, dass du Swiftly benutzt. \(look.name) ist ein Geschenk an alle.")
                .giftFont(15)
                .foregroundStyle(Theme.fontQuiet)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Text("Bleibt für immer in deiner Sammlung.")
                .giftFont(13)
                .foregroundStyle(Theme.fontVeryQuiet)
                .padding(.top, 6)
            Color.clear.frame(height: 20)
            VStack(spacing: 10) {
                Button { flow.grab(look) } label: { Text("Hol ihn dir") }
                    .buttonStyle(GiftButton(primary: true))
                Button { flow.close() } label: { Text("Nicht jetzt") }
                    .buttonStyle(GiftButton(primary: false))
            }
        }
        .padding(.horizontal, Theme.sheetInset)
        .padding(.bottom, 16)
        .overlay(alignment: .topTrailing) { CloseButton { flow.close() } }
    }
}

// MARK: G2: picking it up

/// **0.9 s: the icon springs to the middle, a thin ring runs out, a bat crosses the light.**
/// The app under the sheet turns to the look at the same time (`LookStore`, 0.45 s).
private struct GiftClaiming: View {
    let look: Look
    let icon: Namespace.ID
    @State private var ring = false
    @State private var batStart = Date.now

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.accent.opacity(ring ? 0 : 0.8), lineWidth: 1.5)
                .frame(width: 120, height: 120)
                .scaleEffect(ring ? 1.9 : 0.8)
                .accessibilityHidden(true)
            LookTile(look: look, size: 114)
                .matchedGeometryEffect(id: "gift", in: icon)
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                Canvas { context, size in
                    let progress = timeline.date.timeIntervalSince(batStart) / 0.85
                    guard progress >= 0, progress <= 1 else { return }
                    BatShape.draw(in: &context,
                                  at: CGPoint(x: -20 + (size.width + 40) * progress,
                                              y: 50 + sin(progress * .pi * 2) * 8),
                                  span: 22, beat: cos(timeline.date.timeIntervalSince(batStart) / 0.32 * .pi * 2),
                                  facingRight: true)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // A tap during the animation goes straight to the end.
        .onTapGesture {
            withAnimation(Motion.land) {
                GiftFlow.shared.stage = .choosing(fromGift: true)
            }
        }
        .onAppear {
            batStart = .now
            withAnimation(Theme.motionReduced ? Theme.fadeReduced : .easeOut(duration: 0.6)) { ring = true }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("\(look.name) gehört dir."))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: G3: the looks panel

/// **"Choose your look": every look in one row, then "Use".** The one view behind "Change"
/// in the profile, "Try a look", and Settings. A look this person may wear is chosen at once;
/// any other one (a supporter look) is only previewed: the page under the panel takes its
/// colors, nothing is stored, and the button says why. Only a debug build offers the
/// purchase. As tall as its content.
struct LooksPanel: View {
    var fromGift: Bool
    let icon: Namespace.ID

    private var store: LookStore { .shared }

    var body: some View {
        let selection = store.selection
        let look = selection.look
        let wearable = store.mayWear(selection)
        VStack(alignment: .leading, spacing: 0) {
            Text("Wähl deinen Look")
                .giftFont(17, .semibold)
                .foregroundStyle(Theme.font)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 26)
                .padding(.trailing, 40)

            // **A strip of its own that scrolls sideways**: every look has a column of the
            // same fixed width. The row used to share the panel's width evenly, and its
            // names were `fixedSize`: with nine looks the row asked for more than the screen
            // and pushed the whole panel wider, cut off left and right. The strip takes the
            // panel's width and never more; it runs to the sheet's edges, its first look
            // starts on the page margin, and the chosen look is in view when it opens.
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(store.pickerLooks()) { item in
                            LookChoice(look: item, chosen: look == item, locked: !allowed(item),
                                       icon: fromGift && item.isGift ? icon : nil) { pick(item, selection) }
                                .id(item.id)
                        }
                    }
                    // Room for the ring and the lock, which reach past the tile.
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, Theme.sheetInset, for: .scrollContent)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, -Theme.sheetInset)
                .onAppear { reader.scrollTo(look.id, anchor: .center) }
            }
            .padding(.top, 12)
            .accessibilityElement(children: .contain)

            settings(selection, look: look, wearable: wearable)

            button(wearable: wearable)
                .padding(.top, 16)
                .padding(.bottom, 16)
        }
        // **One side margin for the whole panel**: heading, settings group and button end on
        // the same line left and right.
        .padding(.horizontal, Theme.sheetInset)
        .tint(Theme.accent)
        .overlay(alignment: .topTrailing) { CloseButton { GiftFlow.shared.close() } }
    }

    /// Whether this person may wear the look as it comes (the original, a gift).
    private func allowed(_ look: Look) -> Bool {
        store.mayWear(LookSelection(lookID: look.id)) || (look.isGift && !store.owned.contains(look.id))
    }

    private func pick(_ item: Look, _ selection: LookSelection) {
        guard selection.look != item else { return }
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
        // A gift not picked up yet ("Not now" before): picking it here picks it up, with
        // its moment.
        if item.isGift, !store.owned.contains(item.id) {
            GiftFlow.shared.grab(item)
            return
        }
        apply(selection.switching(to: item))
    }

    /// **Live**: the app under the sheet changes with the same 0.25 s cross-fade as
    /// everywhere. What may be worn is stored (the icon follows on "Use" or on closing, so
    /// the system's icon notice comes once); anything else is a preview.
    private func apply(_ next: LookSelection) {
        withAnimation(Motion.change) {
            if store.mayWear(next) {
                store.endPreview()
                _ = store.choose(next)
            } else {
                if !store.isPreviewing { store.beginPreview() }
                store.tryOn(next)
            }
        }
    }

    /// **The settings under the row of looks: always the same rows, the same height.**
    /// Everyone can set the glow on the home page and whether the app icon follows the look;
    /// the accent color is the supporters' (a greyed line until the support update).
    /// A look that may not be worn yet (a preview) shows the rows greyed.
    @ViewBuilder
    private func settings(_ selection: LookSelection, look: Look, wearable: Bool) -> some View {
        let season = look.availability.flatMap { $0.isActive(at: LookClock.now) ? $0 : nil }
        VStack(spacing: 0) {
            if season != nil {
                toggleRow(Text("Fledermäuse und Spinnennetz"),
                          isOn: Binding(get: { store.effectsOn }, set: { store.effectsOn = $0 }))
                divider
            }
            toolRow(Text("Startseiten-Schein")) {
                glowChoice(selection, look: look)
            }
            divider
            toggleRow(Text("App-Icon zum Look"), enabled: look.iconName != nil,
                      isOn: Binding(get: { look.iconName != nil && selection.usesLookIcon != false },
                                    set: { on in
                                        var next = selection
                                        next.usesLookIcon = on ? nil : false
                                        apply(next)
                                    }))
            divider
            accentRow(selection, look: look)
        }
        .disabled(!wearable)
        .opacity(wearable ? 1 : 0.5)
        .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        .padding(.top, 14)
    }

    @ViewBuilder
    private func glowChoice(_ selection: LookSelection, look: Look) -> some View {
        let change: (LookGlow) -> Void = { glow in
            var next = selection
            next.glow = glow == look.defaultGlow ? nil : glow
            apply(next)
        }
        #if os(iOS)
        Segments(options: LookGlow.allCases, value: selection.palette.glow, title: \.name, choose: change)
        #else
        Picker(selection: Binding(get: { selection.palette.glow }, set: change)) {
            ForEach(LookGlow.allCases, id: \.self) { Text($0.name).tag($0) }
        } label: { EmptyView() }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)
        #endif
    }

    /// **The accent color is a supporter's tool:** the dots for a supporter, "Become a
    /// supporter" (opens the support sheet) for everyone else.
    @ViewBuilder
    private func accentRow(_ selection: LookSelection, look: Look) -> some View {
        if SupportModel.shared.isSupporter {
            toolRow(Text("Akzentfarbe")) {
                AccentDots(chosen: selection.palette.accent) { accent in
                    var next = selection
                    next.accentID = accent == look.accent ? nil : accent.id
                    apply(next)
                }
            }
        } else {
            toolRow(Text("Akzentfarbe")) {
                Button { SupportModel.shared.open() } label: {
                    Text("Unterstützer werden")
                        .giftFont(13, .semibold)
                        .foregroundStyle(Theme.font)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Theme.area, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
            }
        }
    }

    @ViewBuilder
    private func button(wearable: Bool) -> some View {
        if wearable {
            Button { GiftFlow.shared.use(store.saved) } label: { Text("Verwenden") }
                .buttonStyle(GiftButton(primary: true))
        } else {
            Button { SupportFlow.shared.keep() } label: { Text("Unterstützer werden") }
                .buttonStyle(GiftButton(primary: true))
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 16)
    }

    /// Every settings row is this tall, so the block reads as one list.
    private static let rowHeight: CGFloat = 52

    private func toggleRow(_ title: Text, enabled: Bool = true, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            title
                .giftFont(15, .semibold)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .padding(.horizontal, 16)
        .frame(minHeight: Self.rowHeight)
    }

    private func toolRow<Trailing: View>(_ title: Text, enabled: Bool = true,
                                         @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            title
                .giftFont(15, .semibold)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Self.rowHeight)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
    }

    /// "2 Nov": the last day of the window this year.
    static func end(of season: LookSeason, now: Date = LookClock.now) -> String {
        let calendar = Calendar.current
        var year = calendar.component(.year, from: now)
        if season.crossesNewYear, calendar.component(.month, from: now) >= season.from.month { year += 1 }
        let date = calendar.date(from: DateComponents(year: year, month: season.to.month, day: season.to.day)) ?? now
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// **One look in the row: its icon, its name.** The chosen one gets a white ring; a look
/// that is not allowed is greyed with a small lock.
private struct LookChoice: View {
    let look: Look
    let chosen: Bool
    let locked: Bool
    let icon: Namespace.ID?
    let action: () -> Void
    /// One width for every column, growing with the text size so names never touch.
    @ScaledMetric(relativeTo: .caption) private var column: CGFloat = 68

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                tile
                    .overlay {
                        // The ring: 2 pt of the sheet's color, then 2 pt of white.
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .strokeBorder(Theme.font, lineWidth: 2)
                            .padding(-4)
                            .opacity(chosen ? 1 : 0)
                    }
                    .opacity(locked ? 0.45 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if locked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.font)
                                .frame(width: 20, height: 20)
                                .background(Theme.raised, in: Circle())
                                .offset(x: 4, y: 4)
                                .accessibilityHidden(true)
                        }
                    }
                Text(look.name)
                    .giftFont(12, chosen ? .semibold : .regular)
                    .foregroundStyle(chosen ? Theme.font : Theme.fontQuiet)
                    .opacity(locked ? 0.6 : 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 2)
            }
            .frame(width: min(column, 140))
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(Text(look.name))
        .accessibilityValue(locked ? Text("Nur für Unterstützer") : Text(verbatim: ""))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var tile: some View {
        if let icon {
            LookTile(look: look, size: 56).matchedGeometryEffect(id: "gift", in: icon)
        } else {
            LookTile(look: look, size: 56)
        }
    }
}

// MARK: - Parts

#if os(iOS)
/// **The look icons, decoded ahead of time** (at launch), so the panel has them when it opens
/// and nothing is read or decoded while the sheet slides up.
@MainActor
enum LookTileCache {
    private static var images: [String: UIImage] = [:]

    static func image(_ name: String) -> UIImage? { images[name] }

    static func prewarm() {
        guard images.isEmpty else { return }
        let names = Look.all.map(\.tileName)
        Task.detached(priority: .utility) {
            var made: [String: UIImage] = [:]
            for name in names {
                if let image = UIImage(named: name) { made[name] = image.preparingForDisplay() ?? image }
            }
            await MainActor.run { images = made }
        }
    }
}
#endif

#endif

/// The look's icon as a tile, rounded like an app icon.
struct LookTile: View {
    let look: Look
    let size: CGFloat

    var body: some View {
        picture
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private var picture: Image {
        #if os(iOS)
        if let ready = LookTileCache.image(look.tileName) { return Image(uiImage: ready) }
        #endif
        return Image(look.tileName)
    }
}

#if !os(tvOS)
/// The X in the top corner, 44 pt to hit.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.fontQuiet)
                .frame(width: 30, height: 30)
                .background(Theme.raised, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .padding(.trailing, 10)
        .padding(.top, 14)
        .accessibilityLabel(Text("Schließen"))
    }
}

/// **The two buttons of these sheets, the same height:** white for the main action, the
/// raised surface for "Not now". Height 50, corner 10. Not the app's `PrimaryButtonStyle`,
/// which the Mac target does not have.
struct GiftButton: ButtonStyle {
    var primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(primary ? Color.black : Theme.font)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(primary ? Color.white.opacity(configuration.isPressed ? 0.75 : 1)
                                : (configuration.isPressed ? Theme.raised.opacity(0.7) : Theme.raised),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed && !Theme.motionReduced ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

extension View {
    /// The app's text sizes, growing with the system setting on iPhone and iPad.
    @ViewBuilder
    func giftFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        #if os(iOS)
        growing(size, weight)
        #else
        font(.system(size: size, weight: weight))
        #endif
    }
}

// MARK: - The profile's look line

/// **"Your look: Halloween · Change"**, a quiet card at the top of the profile for anyone
/// who has a look to choose. During the season a web hangs in its corner.
struct CurrentLookCard: View {
    let playing: Bool
    let action: () -> Void

    var body: some View {
        let look = LookStore.shared.palette.look
        let details = LookEffects.details(on: .profile, .current(playing: playing))
        Button(action: action) {
            HStack(spacing: 14) {
                LookTile(look: look, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dein Look")
                        .giftFont(13)
                        .foregroundStyle(Theme.fontQuiet)
                    Text(look.name)
                        .giftFont(17, .semibold)
                        .foregroundStyle(Theme.font)
                }
                Spacer(minLength: 0)
                Text("Ändern")
                    .giftFont(15, .semibold)
                    .foregroundStyle(Theme.accent)
                    .padding(.trailing, details ? 44 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 76)
            .background(Theme.groupsArea, in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
            .seasonWeb(cornerRadius: Theme.cornerArea, shown: details)
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Dein Look: \(look.name)"))
    }
}

#endif

extension EnvironmentValues {
    /// The home page is shown under the looks panel: it scrolls, but nothing on it can be
    /// tapped.
    @Entry var looksPreviewing = false
}

extension LookGlow {
    var name: String {
        switch self {
        case .off: String(localized: "Aus")
        case .soft: String(localized: "Sanft")
        case .bright: String(localized: "Kräftig")
        }
    }
}
