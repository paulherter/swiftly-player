import JellyfinKit
import StoreKit
import SwiftUI

// **"Help Swiftly grow" on Apple TV** (the counterpart of
// `Sources/Shared/SupportGrowSheet.swift`). The same steps as on the iPhone: the offer with
// two plans and three tips, nothing preselected, the App Store purchase, the thank-you page.
// Drawn for the remote: one column, large buttons, Back closes (not while "waiting for the
// App Store"). Purchases run through `SupportModel` (StoreKit 2).
//
// The legal links of the iPhone sheet are not here: Apple TV has no browser. The terms are
// part of the text, and "Restore" stays.

struct TVSupportGrowView: View {
    let model: AppModel
    let close: () -> Void

    @State private var chosen: SupportChoice?
    @Environment(\.purchase) private var purchase
    @FocusState private var focus: SupportChoice?

    private var support: SupportModel { .shared }
    private var flow: SupportFlow { .shared }
    private var busy: Bool { support.purchasing != nil }
    private var pricesShown: Bool { support.pricesReady }

    /// The page is drawn from the very top of the screen: the cover's own safe area (the 60 pt
    /// of overscan on top) would otherwise show as a band in the cover's backing color. The
    /// content brings its own edges (`Theme.edgeTop`).
    var body: some View {
        ZStack {
            Theme.reason
            LookGlowLayer(glow: .soft, anchoredToScreen: false)
            if support.showsThanks {
                thanks
            } else {
                offer
            }
        }
        .ignoresSafeArea()
        .tint(Theme.accent)
        .task { await support.loadProducts() }
        .onExitCommand { if !busy { close() } }
    }

    /// The column of the iPhone sheet, at the size of the TV picture (about 2.6 times).
    private let column: CGFloat = 1040

    // MARK: Offer

    /// Like the iPhone: the content scrolls, the purchase and the terms stay below it.
    private var offer: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TVLooksHero {
                        close()
                        GiftFlow.shared.openLooks()
                    }
                    .disabled(busy)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Hilf Swiftly zu wachsen")
                                .font(.app(size: 56, weight: .bold))
                                .tracking(-1.1)
                                .foregroundStyle(Theme.font)
                                .accessibilityAddTraits(.isHeader)
                            Text(verbatim: "🌱")
                                .font(.app(size: 34))
                                .accessibilityHidden(true)
                        }
                        Text("Dein Beitrag hält Swiftly am Laufen.")
                            .font(.app(size: 32))
                            .foregroundStyle(Theme.font.opacity(0.9))
                        Text("Open Source, keine Werbung, alles zum Schauen bleibt kostenlos.")
                            .font(.app(size: 26))
                            .foregroundStyle(Theme.fontVeryQuiet)
                    }
                    .padding(.top, 24)
                    .padding(.horizontal, 20)

                    if support.pricesUnavailable {
                        unavailable.padding(.top, 28)
                    } else {
                        plans.padding(.top, 26)
                        tips.padding(.top, 16)
                    }
                }
                .frame(width: column)
                .padding(.top, Theme.edgeTop - 24)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .defaultFocus($focus, .monthly)

            footer
        }
    }

    private var plans: some View {
        HStack(alignment: .top, spacing: 28) {
            planTile(.monthly, badge: "Beliebt", loud: true, title: "Monatlich",
                     detail: "im Monat · jederzeit kündbar")
            planTile(.lifetime, badge: "Guter Deal", loud: false, title: "Für immer",
                     detail: "einmal zahlen · wie 10 Monate")
        }
        .fixedSize(horizontal: false, vertical: true)
        .focusSection()
        .disabled(busy || !pricesShown)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Arten zu unterstützen"))
    }

    private func planTile(_ choice: SupportChoice, badge: LocalizedStringKey, loud: Bool,
                          title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        let isChosen = chosen == choice
        return Button { chosen = choice } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.app(size: 28))
                    .foregroundStyle(Theme.fontQuiet)
                    .padding(.top, 14)
                Text(verbatim: pricesShown ? price(choice) : "···")
                    .font(.app(size: 52, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.font)
                    .padding(.top, 6)
                Text(detail)
                    .font(.app(size: 24))
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
            .frame(maxWidth: .infinity, minHeight: 112, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)
            .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: isChosen ? 4 : 0)
            }
            .overlay(alignment: .topTrailing) { indicator(isChosen).padding(26) }
            .overlay(alignment: .topLeading) {
                Text(badge)
                    .font(.app(size: 20, weight: .bold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(loud ? Color(white: 0.04) : Theme.font)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(loud ? Theme.font : Theme.pressedArea, in: Capsule())
                    .offset(x: 28, y: -18)
            }
        }
        .buttonStyle(TileStyle())
        .focused($focus, equals: choice)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    /// An empty ring, or the accent check.
    @ViewBuilder private func indicator(_ isChosen: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.font.opacity(0.25), lineWidth: 3)
                .opacity(isChosen ? 0 : 1)
            if isChosen {
                Image(icon: "checkmark", size: 20)
                    .font(.app(size: 20, weight: .heavy))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: Circle())
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }

    /// The label and the three tips in one row, as on the iPhone.
    private var tips: some View {
        HStack(spacing: 14) {
            Text("Einfach Danke ☕")
                .font(.app(size: 24))
                .foregroundStyle(Theme.fontVeryQuiet)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 6)
            ForEach(SupportTip.ordered, id: \.self) { tip in
                let choice = SupportChoice.tip(tip)
                let isChosen = chosen == choice
                Button { chosen = choice } label: {
                    Text(verbatim: pricesShown ? price(choice) : "···")
                        .font(.app(size: 28, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.font)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .background(Theme.area, in: Capsule())
                        .overlay { Capsule().strokeBorder(Theme.accent, lineWidth: isChosen ? 4 : 0) }
                }
                .buttonStyle(TileStyle())
                .focused($focus, equals: choice)
                .accessibilityLabel(Text("Einfach Danke ☕") + Text(verbatim: ", \(price(choice))"))
                .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .focusSection()
        .disabled(busy || !pricesShown)
    }

    /// The purchase and the terms right below it (the iPhone's footer).
    private var footer: some View {
        VStack(spacing: 14) {
            if let notice = support.notice {
                Text(notice.text)
                    .font(.app(size: 24))
                    .foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center)
            }
            Button { if let chosen { buy(chosen) } } label: { Text(buyTitle) }
                .buttonStyle(TVBuyStyle())
                .disabled(chosen == nil || busy || !pricesShown)
                .frame(width: column)

            Text("Das Monatsabo verlängert sich, bis du in den Einstellungen deines Apple Accounts kündigst. Für immer ist eine einmalige Zahlung. Trinkgelder sind nur ein Dankeschön.")
                .font(.app(size: 22))
                .foregroundStyle(Theme.fontVeryQuiet)
                .multilineTextAlignment(.center)
                .frame(width: column)
                .padding(.top, 4)

            Button { restore() } label: {
                Text("Wiederherstellen")
                    .underline(color: Theme.font.opacity(0.25))
            }
            .buttonStyle(TVLinkStyle())
            .disabled(busy)
        }
        .focusSection()
        .padding(.horizontal, Theme.edgePage)
        .padding(.top, 10)
        .padding(.bottom, Theme.edgeTop - 24)
        .frame(maxWidth: .infinity)
    }

    private var unavailable: some View {
        HStack(alignment: .top, spacing: 24) {
            Image(icon: "icloud.slash", size: 36)
                .font(.app(size: 36))
                .foregroundStyle(Theme.font)
                .frame(width: 80, height: 80)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Preise sind gerade nicht verfügbar")
                    .font(.app(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.font)
                Text("Der App Store hat nicht geantwortet. Das passiert ohne Internet oder wenn Käufe in der Bildschirmzeit aus sind. Nichts geht verloren, und Swiftly läuft wie immer.")
                    .font(.app(size: 26))
                    .foregroundStyle(Theme.fontQuiet)
                Button(action: retry) {
                    Label("App Store erneut fragen", icon: "arrow.clockwise")
                }
                .buttonStyle(ThemedButtonStyle())
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(30)
        .background(Theme.groupsArea, in: RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
        .focusSection()
    }

    private var buyTitle: LocalizedStringKey {
        if busy {
            "Warte auf den App Store"
        } else if !pricesShown {
            "Warte auf den App Store"
        } else if let chosen {
            switch chosen {
            case .monthly: "Für \(price(.monthly)) im Monat unterstützen"
            case .lifetime: LocalizedStringKey(String(format: SupportCopy.supportWithPrice.localized,
                                                      price(.lifetime)))
            case .tip: "Mit \(price(chosen)) Danke sagen"
            }
        } else {
            "Wähl eine Option"
        }
    }

    // MARK: Thanks

    private var thanks: some View {
        let kept = flow.keptWithPurchase
        let look = kept ?? LookStore.shared.palette.look
        let name = model.session?.userName
        return VStack(spacing: 0) {
            LookTile(look: look, size: 180)
            Text(thanksTitle(name))
                .font(Theme.titleLarge)
                .foregroundStyle(Theme.font)
                .padding(.top, 36)
                .accessibilityAddTraits(.isHeader)
            Text(thanksMessage(kept))
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1100)
                .padding(.top, 12)
            Text("Looks kannst du jederzeit im Profil wechseln.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .padding(.top, 14)
            HStack(spacing: 24) {
                Button { flow.goHome() } label: { Text("Zeig mir meine Startseite") }
                    .buttonStyle(ThemedButtonStyle())
                Button { close() } label: { Text(SupportCopy.done.localized) }
                    .buttonStyle(ThemedButtonStyle())
            }
            .focusSection()
            .padding(.top, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func thanksTitle(_ name: String?) -> String {
        if let name, !name.isEmpty {
            String(localized: "Danke, \(name) 🫶")
        } else {
            String(localized: "Danke 🫶")
        }
    }

    private func thanksMessage(_ kept: Look?) -> String {
        if let kept {
            String(localized: "Du hast Swiftly gerade beim Weitermachen geholfen. \(kept.name) ist an, dein Icon und Logo auch. Schau dich um.")
        } else {
            String(localized: "Du hast Swiftly gerade beim Weitermachen geholfen. Looks und Icons gehören jetzt dir. Schau dich um.")
        }
    }

    // MARK: Actions

    private func price(_ choice: SupportChoice) -> String {
        support.price(choice) ?? "···"
    }

    private func buy(_ choice: SupportChoice) {
        guard !busy else { return }
        Task { await support.buy(choice, with: { try await purchase($0) }) }
    }

    private func restore() {
        Task { await support.restore() }
    }

    private func retry() {
        #if DEBUG
        support.forcePricesUnavailable = false
        #endif
        Task { await support.loadProducts(retry: true) }
    }
}

/// The big white purchase button of the iPhone: white, muted when it cannot be used; the
/// remote's focus lifts it.
private struct TVBuyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focus
        @Environment(\.isEnabled) private var released

        var body: some View {
            configuration.label
                .font(Theme.button)
                .lineLimit(1)
                .foregroundStyle(released ? Color(white: 0.04) : Theme.fontVeryQuiet)
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .background(released ? Color.white : Theme.area,
                            in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .lift(focus)
                .scaleEffect(configuration.isPressed ? 0.98 : (focus ? Theme.focusMagnifier : 1))
                .animation(Theme.focusAnimation, value: focus)
        }
    }
}

/// A quiet text link in the footer ("Restore"); focus puts a soft surface behind it.
private struct TVLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .font(.app(size: 26, weight: .medium))
                .foregroundStyle(focus ? Theme.reason : Theme.fontQuiet)
                .padding(.horizontal, 28)
                .frame(height: 60)
                .background(focus ? Color.white : Color.clear, in: Capsule())
                .scaleEffect(focus ? Theme.focusMagnifier : 1)
                .animation(Theme.focusAnimation, value: focus)
        }
    }
}

/// The pill under the phones: dark with a thin edge, white when focused.
private struct TVPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .font(.app(size: 28, weight: .semibold))
                .foregroundStyle(focus ? Theme.reason : Theme.font)
                .padding(.horizontal, 34)
                .frame(height: 72)
                .background(focus ? Color.white : Color(white: 0.16).opacity(0.92), in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.font.opacity(focus ? 0 : 0.14), lineWidth: 2) }
                .lift(focus)
                .scaleEffect(configuration.isPressed ? 0.97 : (focus ? Theme.focusMagnifier : 1))
                .animation(Theme.focusAnimation, value: focus)
        }
    }
}

/// **Three looks on a TV, and the way to try one** (the iPhone's `LooksHero`, made for the
/// TV). Each small 16:9 screen is the Start page drawn in that look: head, hero, a row of
/// tiles.
///
/// Before, these were the iPhone's three tilted phones, drawn bigger. On the TV they were
/// unreadable and said "this is about a phone" (round 3 on the device). The pill sits in its
/// own row below: laid over the pictures, the white focused pill touched the title (round 2).
private struct TVLooksHero: View {
    let tryLooks: () -> Void

    private static let looks: [LookSelection] = [
        LookSelection(lookID: Look.original.id, glow: .soft),
        LookSelection(lookID: Look.neonNight.id),
        LookSelection(lookID: Look.neonNight.id, accentID: LookAccent.coral.id),
    ]

    var body: some View {
        VStack(spacing: 20) {
            // Drawn at 256 x 144 and shown at 208 x 117, so the whole offer fits one screen.
            HStack(spacing: 24) {
                ForEach(Self.looks.indices, id: \.self) { index in
                    TVMiniScreen(palette: Self.looks[index].palette)
                        .scaleEffect(208 / 256)
                        .frame(width: 208, height: 117)
                }
            }
            .accessibilityHidden(true)
            Button(action: tryLooks) {
                HStack(spacing: 12) {
                    Text("Look ausprobieren")
                    Image(icon: "chevron.right", size: 22)
                        .font(.app(size: 22, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(TVPillStyle())
        }
        .frame(maxWidth: .infinity)
    }
}

/// A TV picture of 256 x 144 showing the Start page in a look (drawn, at 2/15 of 1920 x 1080).
private struct TVMiniScreen: View {
    let palette: LookPalette

    var body: some View {
        let accent = palette.accent.mainColor
        ZStack(alignment: .topLeading) {
            Theme.reason
            // The hero glow, where the Start page has it: right of the title, upper half.
            EllipticalGradient(colors: [accent.opacity(0.32), accent.opacity(0)],
                               center: UnitPoint(x: 0.62, y: 0.3),
                               startRadiusFraction: 0, endRadiusFraction: 0.6)
            // Head: wordmark, four tabs (the first one current), heart and avatar.
            HStack(spacing: 7) {
                Wordmark(height: 7, logo: palette.logoStyle)
                    .padding(.trailing, 3)
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index == 0 ? Theme.font : Theme.font.opacity(0.35))
                        .frame(width: index == 0 ? 14 : 16, height: 2.5)
                }
                Spacer(minLength: 0)
                Circle().fill(accent).frame(width: 7, height: 7)
            }
            .padding(.horizontal, 11)
            .offset(y: 10)
            // Hero: title, meta line, text.
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(Theme.font).frame(width: 52, height: 6)
                Capsule().fill(Theme.font.opacity(0.45)).frame(width: 36, height: 2.5)
                Capsule().fill(Theme.font.opacity(0.3)).frame(width: 90, height: 2.5)
                    .padding(.top, 2)
            }
            .offset(x: 11, y: 32)
            // Weiterschauen: label and four tiles, the first one focused, with progress.
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(Theme.font.opacity(0.8)).frame(width: 30, height: 3)
                HStack(spacing: 5) {
                    ForEach(0..<4, id: \.self) { index in
                        tile(focused: index == 0, accent: accent)
                    }
                }
            }
            .offset(x: 11, y: 78)
        }
        .frame(width: 256, height: 144)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.font.opacity(0.12), lineWidth: 1)
        }
    }

    private func tile(focused: Bool, accent: Color) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(LinearGradient(colors: [Theme.raised, Theme.area], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottomLeading) {
                if focused {
                    Rectangle().fill(accent).frame(width: 22, height: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Theme.font.opacity(0.7), lineWidth: 1)
                }
            }
            .frame(width: 54, height: 31)
    }
}

/// The status line on the profile for a supporter: what kind of support, since when.
struct TVSupportStatusRow: View {
    var body: some View {
        let support = SupportModel.shared
        HStack(spacing: 24) {
            Image(icon: "heart.fill")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(support.plan))
                if let since = support.supporterSince {
                    Text(since, format: .dateTime.day().month(.wide).year())
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.app(size: 30, weight: .medium))
        .foregroundStyle(Theme.font)
        .padding(.horizontal, 26)
        .frame(height: Theme.rowsHeight + 10)
        .accessibilityElement(children: .combine)
    }

    private func title(_ plan: SupportPlan?) -> LocalizedStringKey {
        switch plan {
        case .monthly: "Monatlich"
        case .lifetime: "Für immer"
        default: "Einfach Danke ☕"
        }
    }
}
