import JellyfinKit
import SwiftUI

// **The looks, the Halloween gift and "What's new" on Apple TV.** The flow is the shared one
// (`GiftFlow` in `Sources/Shared/LookGiftSheet.swift`: when the gift is due, what "Grab it"
// stores, what a preview keeps); only the views are drawn here, for distance and a remote.
//
// - One full-screen page for every step, no sheet from below. Back closes it, from the
//   pick-up animation it skips to the looks.
// - The looks panel is a page of its own: the iPhone shows the real home page under the
//   panel, a full-screen page cannot, so a strip of mock tiles takes the look's colors live.
// - Not here, because Apple TV does not have them: the app icon that follows a look (no
//   alternate icons), the bats and the web over the home page (`BatLayer` is not in this
//   target), and the lock-screen style tile cache.
//
// Which looks may be worn, the purchase and the accent color follow iOS: a release build
// offers the original and the gift, only a debug build offers the supporter side.

// MARK: - Presentation

extension View {
    /// **The gift page and when it comes**, once at the root of the app (next to
    /// `tvSupportPresentation`). The timing is the iPhone's: a moment after the home page is
    /// up, again when the player or the support page that kept it back is gone.
    func tvGiftPresentation(model: AppModel) -> some View {
        modifier(TVGiftPresentation(model: model))
    }
}

private struct TVGiftPresentation: ViewModifier {
    let model: AppModel
    @Bindable private var flow = GiftFlow.shared

    private var blocked: Bool { model.playerOpen || SupportModel.shared.presented }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: Binding(get: { flow.presented },
                                                  set: { if !$0 { flow.close() } })) {
                TVGiftView(model: model)
            }
            .task(id: flow.homeSince) {
                guard flow.homeSince != nil else { return }
                try? await Task.sleep(for: .seconds(LookGift.quietAfterHome))
                flow.evaluate(model: model)
            }
            .onChange(of: blocked) { _, blocked in
                guard !blocked, flow.homeSince != nil else { return }
                Task {
                    try? await Task.sleep(for: .seconds(LookGift.quietAfterHome))
                    flow.evaluate(model: model)
                }
            }
            .task {
                #if DEBUG
                GiftFlow.debugLaunch()
                #endif
                await LookIcon.restore()
            }
    }
}

/// The support page: "Help Swiftly grow".
struct TVSupportPage: View {
    let model: AppModel

    var body: some View {
        TVSupportGrowView(model: model) { SupportModel.shared.presented = false }
    }
}

// MARK: - The page

/// The one page through its steps. It keeps the last step on screen while it closes.
private struct TVGiftView: View {
    let model: AppModel
    @Bindable private var support = SupportModel.shared
    @State private var lastStage: GiftFlow.Stage?
    private var flow: GiftFlow { .shared }
    private var stage: GiftFlow.Stage? { flow.stage ?? lastStage }

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()
            LookGlowLayer(glow: .soft, anchoredToScreen: false).ignoresSafeArea()
            switch stage {
            case let .whatsNew(entry):
                TVWhatsNew(entry: entry, giftAvailable: entry.giftLook.map { flow.giftDue($0) } ?? false)
            case let .offer(look):
                TVGiftOffer(look: look)
            case let .claiming(look):
                TVGiftClaiming(look: look)
            case let .choosing(fromGift):
                TVLooksPage(fromGift: fromGift)
            case nil:
                Color.clear
            }
        }
        .ignoresSafeArea(edges: .horizontal)
        .tint(Theme.accent)
        .onChange(of: flow.stage) { _, new in if let new { lastStage = new } }
        .onAppear { if let current = flow.stage { lastStage = current } }
        .onExitCommand {
            // From the pick-up animation straight to the looks; everywhere else it closes.
            if case .claiming = flow.stage {
                withAnimation(Motion.land) { flow.stage = .choosing(fromGift: true) }
            } else {
                flow.close()
            }
        }
        // "Become a supporter" in the looks page: the support page goes over this one.
        .fullScreenCover(isPresented: $support.presented, onDismiss: {
            support.closed()
            SupportFlow.shared.sheetClosed()
        }) {
            TVSupportPage(model: model)
        }
    }
}

// MARK: - Offer and pick-up

private struct TVGiftOffer: View {
    let look: Look
    @FocusState private var focus: Bool
    private var flow: GiftFlow { .shared }

    var body: some View {
        VStack(spacing: 0) {
            LookTile(look: look, size: 200)
            Text("Ein Look für dich 🎃")
                .font(Theme.titleLarge)
                .foregroundStyle(Theme.font)
                .padding(.top, 40)
                .accessibilityAddTraits(.isHeader)
            Text("Danke, dass du Swiftly benutzt. \(look.name) ist ein Geschenk an alle.")
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1100)
                .padding(.top, 14)
            Text("Bleibt für immer in deiner Sammlung.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .padding(.top, 10)
            HStack(spacing: 24) {
                Button { flow.grab(look) } label: { Text("Hol ihn dir") }
                    .buttonStyle(ThemedButtonStyle())
                    .focused($focus)
                Button { flow.close() } label: { Text("Nicht jetzt") }
                    .buttonStyle(ThemedButtonStyle())
            }
            .focusSection()
            .padding(.top, 56)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focus, true)
    }
}

/// **0.9 s: the icon grows, a thin ring runs out.** The app already turned to the look
/// (`LookStore`); the flow moves on to the looks by itself.
private struct TVGiftClaiming: View {
    let look: Look
    @State private var ring = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.accent.opacity(ring ? 0 : 0.8), lineWidth: 3)
                .frame(width: 260, height: 260)
                .scaleEffect(ring ? 1.9 : 0.8)
                .accessibilityHidden(true)
            LookTile(look: look, size: 240)
                .scaleEffect(ring ? 1 : 0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(Theme.motionReduced ? Theme.fadeReduced : .easeOut(duration: 0.6)) { ring = true }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("\(look.name) gehört dir."))
    }
}

// MARK: - What's new

/// **"What's new": once after an update, from the version's JSON.** The same plain page as
/// on the iPhone: version line, title, a few entries, the gift when there is one.
private struct TVWhatsNew: View {
    let entry: WhatsNewEntry
    let giftAvailable: Bool
    @FocusState private var focus: Bool

    private var language: String { Bundle.main.preferredLocalizations.first ?? "en" }
    private var gift: Look? { giftAvailable ? entry.giftLook : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Neu in Version \(entry.version)")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
            Text(verbatim: entry.title.localized(language))
                .font(Theme.titleLarge)
                .foregroundStyle(Theme.font)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 26) {
                ForEach(entry.items.indices, id: \.self) { index in
                    row(entry.items[index])
                }
            }
            .padding(.top, 40)

            if let gift {
                HStack(spacing: 24) {
                    LookTile(look: gift, size: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: gift.name)
                            .font(Theme.button)
                            .foregroundStyle(Theme.font)
                        Text("Geschenk, bleibt für immer in deiner Sammlung")
                            .font(Theme.small)
                            .foregroundStyle(Theme.fontQuiet)
                    }
                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(maxWidth: 1100)
                .background(Theme.groupsArea,
                            in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
                .padding(.top, 36)
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: 24) {
                Button(action: primary) { Text(primaryTitle) }
                    .buttonStyle(ThemedButtonStyle())
                    .focused($focus)
                if gift != nil {
                    Button { GiftFlow.shared.close() } label: { Text("Nicht jetzt") }
                        .buttonStyle(ThemedButtonStyle())
                }
            }
            .focusSection()
            .padding(.top, 48)
        }
        .padding(.horizontal, Theme.edgePage)
        .padding(.vertical, Theme.edgeTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .defaultFocus($focus, true)
    }

    private func row(_ item: WhatsNewEntry.Item) -> some View {
        HStack(alignment: .center, spacing: 24) {
            Image(systemName: item.symbol)
                .font(.system(size: 34))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Theme.fontQuiet)
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.title.localized(language))
                    .font(Theme.button)
                    .foregroundStyle(Theme.font)
                if let detail = item.detail {
                    Text(verbatim: detail.localized(language))
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var primaryTitle: LocalizedStringKey {
        switch gift == nil && entry.primary.label == "grab" ? "continue" : entry.primary.label {
        case "grab": "Hol ihn dir"
        case "try": "Ausprobieren"
        case "tryLook": "Look ausprobieren"
        default: "Verstanden"
        }
    }

    private func primary() {
        let action = entry.primary.action
        if action.hasPrefix("applyLook:"), let gift {
            GiftFlow.shared.grab(gift)
        } else if action == "open:looks" {
            GiftFlow.shared.openLooks()
        } else {
            GiftFlow.shared.close()
        }
    }
}

// MARK: - The looks page

/// **"Choose your look": every look in one row, then "Use".** Pressing a look the person may
/// wear chooses it at once; any other one (a supporter look) is only previewed: the page
/// takes its colors, nothing is stored, and the button says why.
private struct TVLooksPage: View {
    let fromGift: Bool
    @FocusState private var focus: Target?

    private enum Target: Hashable {
        case look(String), glow, accent(String), accentRow, use
    }

    private var store: LookStore { .shared }

    /// For VoiceOver; the dots carry no text.
    static func accentName(_ accent: LookAccent) -> String {
        switch accent.id {
        case LookAccent.violet.id: String(localized: "Violett")
        case LookAccent.coral.id: String(localized: "Koralle")
        case LookAccent.gold.id: String(localized: "Gold")
        case LookAccent.emerald.id: String(localized: "Smaragd")
        default: String(localized: "Türkis")
        }
    }

    var body: some View {
        let selection = store.selection
        let look = selection.look
        let wearable = store.mayWear(selection)
        ScrollView {
            VStack(spacing: 0) {
                Text("Wähl deinen Look")
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.font)
                    .accessibilityAddTraits(.isHeader)

                mock
                    .padding(.top, 28)

                HStack(alignment: .top, spacing: 24) {
                    ForEach(store.pickerLooks()) { item in
                        choice(item, chosen: look == item, selection: selection)
                    }
                }
                .focusSection()
                .padding(.top, 36)

                settings(selection, look: look, wearable: wearable)
                    .padding(.top, 28)

                button(wearable: wearable)
                    .focusSection()
                    .padding(.top, 32)
            }
            .padding(.horizontal, Theme.edgePage)
            .padding(.vertical, Theme.edgeTop)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .defaultFocus($focus, .look(look.id))
    }

    // MARK: Mock home

    /// **The real home page is not under this page, so a stand-in is:** poster tiles with a
    /// progress bar, the "keep watching" pill. It takes the colors of what is being tried.
    private var mock: some View {
        HStack(spacing: 20) {
            ForEach(0..<4, id: \.self) { index in
                // A poster stand-in that shows the look: the picture area takes the accent, the
                // lines below are the title. Plain grey tiles on the grey card read as empty.
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: Theme.cornerTile - 6, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.accent.opacity(0.15)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 70)
                        .overlay(alignment: .bottomLeading) {
                            if index < 2 {
                                Capsule()
                                    .fill(Theme.accent)
                                    .frame(width: index == 0 ? 110 : 60, height: 6)
                                    .padding(10)
                            }
                        }
                    Capsule().fill(Theme.font.opacity(0.7)).frame(width: 120, height: 8)
                    Capsule().fill(Theme.fontQuiet.opacity(0.6)).frame(width: 76, height: 6)
                }
                .padding(12)
                .frame(width: 200, height: 136, alignment: .topLeading)
                .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
            }
            Text("Weiterschauen")
                .font(Theme.small)
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 26)
                .frame(height: 56)
                .background(Theme.accent, in: Capsule())
        }
        .padding(24)
        .background(Theme.groupsArea.opacity(0.7),
                    in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        .accessibilityHidden(true)
    }

    // MARK: Looks

    private func allowed(_ look: Look) -> Bool {
        store.mayWear(LookSelection(lookID: look.id)) || (look.isGift && !store.owned.contains(look.id))
    }

    private func choice(_ item: Look, chosen: Bool, selection: LookSelection) -> some View {
        let locked = !allowed(item)
        return Button { pick(item, selection) } label: {
            VStack(spacing: 14) {
                LookTile(look: item, size: 136)
                    .overlay {
                        RoundedRectangle(cornerRadius: 136 * 0.225 + 8, style: .continuous)
                            .strokeBorder(Theme.font, lineWidth: 4)
                            .padding(-8)
                            .opacity(chosen ? 1 : 0)
                    }
                    .opacity(locked ? 0.45 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if locked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Theme.font)
                                .frame(width: 40, height: 40)
                                .background(Theme.raised, in: Circle())
                                .offset(x: 8, y: 8)
                                .accessibilityHidden(true)
                        }
                    }
                Text(item.name)
                    .font(Theme.small)
                    .foregroundStyle(chosen ? Theme.font : Theme.fontQuiet)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 164)
        }
        .buttonStyle(TileStyle())
        .focused($focus, equals: .look(item.id))
        .accessibilityLabel(Text(item.name))
        .accessibilityValue(locked ? Text("Nur für Unterstützer") : Text(verbatim: ""))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    private func pick(_ item: Look, _ selection: LookSelection) {
        guard selection.look != item else { return }
        // A gift not picked up yet ("Not now" before): choosing it here picks it up.
        if item.isGift, !store.owned.contains(item.id) {
            GiftFlow.shared.grab(item)
            return
        }
        apply(selection.switching(to: item))
    }

    /// **Live**: the colors change with the same cross-fade as everywhere. What may be worn
    /// is stored; anything else is a preview.
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

    // MARK: Settings

    /// Always the same rows, so the page does not jump between looks. A look that may not
    /// be worn yet shows them dimmed.
    private func settings(_ selection: LookSelection, look: Look, wearable: Bool) -> some View {
        VStack(spacing: 0) {
            Button {
                var next = selection
                let all = LookGlow.allCases
                let index = all.firstIndex(of: selection.palette.glow) ?? 0
                let glow = all[(index + 1) % all.count]
                next.glow = glow == look.defaultGlow ? nil : glow
                apply(next)
            } label: {
                HStack(spacing: 24) {
                    Text("Startseiten-Schein")
                    Spacer(minLength: 40)
                    Text(selection.palette.glow.name).foregroundStyle(Theme.fontQuiet)
                }
            }
            .buttonStyle(RowsStyle())
            .focused($focus, equals: .glow)
            // Only what changes the look is locked for a look that may not be worn yet; the
            // way to the support page below stays reachable.
            .disabled(!wearable)
            .opacity(wearable ? 1 : 0.5)
            Rectangle().fill(Theme.line).frame(height: 1)
            accentRow(selection, look: look, wearable: wearable)
        }
        .padding(10)
        .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
        .frame(maxWidth: 1300)
        .focusSection()
    }

    /// **The accent color is a supporter's tool**: the choice for a supporter, the way to the
    /// support page for everyone else.
    @ViewBuilder
    private func accentRow(_ selection: LookSelection, look: Look, wearable: Bool) -> some View {
        if SupportModel.shared.isSupporter {
            HStack(spacing: 24) {
                Text("Akzentfarbe")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.font)
                Spacer(minLength: 40)
                HStack(spacing: 18) {
                    ForEach(LookAccent.all) { accent in
                        let chosen = selection.palette.accent == accent
                        Button {
                            var next = selection
                            next.accentID = accent == look.accent ? nil : accent.id
                            apply(next)
                        } label: {
                            Circle()
                                .fill(accent.mainColor)
                                .frame(width: 44, height: 44)
                                .padding(6)
                                .overlay { Circle().strokeBorder(Theme.font, lineWidth: 3).opacity(chosen ? 1 : 0) }
                        }
                        .buttonStyle(TileStyle())
                        .focused($focus, equals: .accent(accent.id))
                        .accessibilityLabel(Text(TVLooksPage.accentName(accent)))
                        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .focusSection()
            }
            .padding(.horizontal, 26)
            .frame(height: Theme.rowsHeight + 20)
            .disabled(!wearable)
            .opacity(wearable ? 1 : 0.5)
        } else {
            Button { SupportModel.shared.open() } label: {
                HStack(spacing: 24) {
                    Text("Akzentfarbe")
                    Spacer(minLength: 40)
                    Text("Unterstützer werden").foregroundStyle(Theme.fontQuiet)
                }
            }
            .buttonStyle(RowsStyle())
            .focused($focus, equals: .accentRow)
        }
    }

    @ViewBuilder
    private func button(wearable: Bool) -> some View {
        if wearable {
            Button { GiftFlow.shared.use(store.saved) } label: { Text("Verwenden") }
                .buttonStyle(ThemedButtonStyle())
                .focused($focus, equals: .use)
        } else {
            Button { SupportFlow.shared.keep() } label: { Text("Unterstützer werden") }
                .buttonStyle(ThemedButtonStyle())
                .focused($focus, equals: .use)
        }
    }
}

// MARK: - The profile's entries

/// **What the profile shows about looks, by state** (`LookProfileEntry`): a line with the
/// look worn and "Change" for everyone who has one to choose, the teaser for the supporter
/// looks only in the debug prototype, nothing for everyone else.
@MainActor
enum TVLookEntry {
    static var current: LookProfileEntry {
        LookProfileEntry.at(supporterFeatures: true,
                                   isSupporter: SupportModel.shared.isSupporter,
                                   ownsLook: LookStore.shared.ownsLook)
    }

    /// The plain "Looks" row where the profile shows nothing and a gift can be picked up.
    static var showsPlainRow: Bool {
        LookProfileEntry.showsLooksRow(entry: current,
                                       giftAvailable: LookStore.shared.freeLooks().count > 1)
    }

    /// Whether the page has a looks row at all.
    static var shown: Bool { current != .none || showsPlainRow }
}

/// **"Dein Look" with "Change"**, or the teaser, as a row on the settings card.
struct TVLookEntryRow: View {
    var body: some View {
        let entry = TVLookEntry.current
        let saved = LookStore.shared.saved.look
        Button { GiftFlow.shared.openLooks() } label: {
            HStack(spacing: 24) {
                switch entry {
                case .current:
                    LookTile(look: saved, size: 52)
                    Text(saved.name)
                    Spacer(minLength: 40)
                    Text("Ändern").foregroundStyle(Theme.accent)
                case .teaser:
                    LookTile(look: saved, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wähl deinen Look")
                        Text("Looks und Icons für alle, die Swiftly am Laufen halten.")
                            .font(Theme.small)
                            .foregroundStyle(Theme.fontQuiet)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 40)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .accessibilityHidden(true)
                case .none:
                    LookTile(look: saved, size: 52)
                    Text("Looks")
                    Spacer(minLength: 40)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(RowsStyle())
        .accessibilityLabel(entry == .current ? Text("Dein Look: \(saved.name)") : Text("Looks"))
    }
}
