import JellyfinKit
import StoreKit
import SwiftUI

// **"Help Swiftly grow": the support sheet of the supporter prototype** (design v6 "Mix",
// board 3), and its thank-you page (board 6).
//
// Debug builds only; release builds keep `SupportSheet`. The rules from App Review shape
// it the same way: nothing is preselected, "Not now" sits right under the purchase with
// the same width and height, and the subscription terms stand on the sheet itself.
// The purchase is `SupportModel.buy`; prices come from the App Store.

struct SupportGrowSheet: View {
    let model: AppModel

    @Environment(\.dismiss) private var close
    @Environment(\.openURL) private var openURL
    @Environment(\.purchase) private var purchase
    /// Nothing is preselected: choosing is the person's first step.
    @State private var chosen: SupportChoice?

    private var support: SupportModel { .shared }
    private var flow: SupportFlow { .shared }
    private var pricesShown: Bool { support.pricesReady }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            // Background B: the one tone of the look, a little lower on the offer, above the
            // screen on the thank-you page.
            LookGlowLayer(glow: .soft, anchoredToScreen: false)

            if support.showsThanks {
                SupportGrowThanks(name: model.session?.userName,
                                  look: flow.keptWithPurchase ?? LookStore.shared.palette.look,
                                  keptLook: flow.keptWithPurchase,
                                  home: { flow.goHome() },
                                  done: { close() })
                    .transition(.opacity)
            } else {
                offer
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) { closeButton }
        .animation(Theme.reveal, value: support.showsThanks)
        .presentationDetents([.large])
        // A running purchase finishes on the sheet, not behind it.
        .interactiveDismissDisabled(support.purchasing != nil)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.reason)
        .presentationCornerRadius(Theme.cornerSheet)
        .onAppear { support.sheetAppeared() }
        .task { await support.loadProducts() }
    }

    private var closeButton: some View {
        Button { close() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.font)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.4), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .disabled(support.purchasing != nil)
        .padding(.trailing, 8)
        .padding(.top, 4)
        .accessibilityLabel(Text("Schließen"))
    }

    // MARK: Offer

    private var offer: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LooksHero { flow.openLooks() }
                        .padding(.top, 36)
                        .disabled(support.purchasing != nil)

                    VStack(alignment: .leading, spacing: 8) {
                        // The sprout at the size of the text beside it, not of the heading.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Hilf Swiftly zu wachsen")
                                .growing(28, .bold)
                                .tracking(-0.56)
                                .foregroundStyle(Theme.font)
                                .accessibilityAddTraits(.isHeader)
                            Text(verbatim: "🌱")
                                .growing(17)
                                .accessibilityHidden(true)
                        }
                        Text("Dein Beitrag hält Swiftly am Laufen.")
                            .growing(17)
                            .foregroundStyle(Theme.font.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Open Source, keine Werbung, alles zum Schauen bleibt kostenlos.")
                            .growing(13)
                            .foregroundStyle(Theme.fontVeryQuiet)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 22)
                    .padding(.horizontal, 20)

                    if support.pricesUnavailable {
                        PricesUnavailableCard { retry() }
                            .padding(.top, 18)
                            .padding(.horizontal, 16)
                            .transition(.opacity)
                    }

                    plans
                        .padding(.top, 18)
                        .padding(.horizontal, 16)
                    tips
                        .padding(.top, 12)
                        .padding(.horizontal, 16)
                }
                .padding(.bottom, 12)
                .animation(Theme.reveal, value: pricesShown)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)

            footer
        }
    }

    /// The two plans side by side. A radio group: one choice at most, none at the start.
    private var plans: some View {
        // Both tiles as tall as the taller one, whatever the text wraps to.
        HStack(alignment: .top, spacing: 12) {
            PlanTile(choice: .monthly, badge: Text("Beliebt"), badgeLoud: true,
                     title: Text("Monatlich"), detail: Text("im Monat · jederzeit kündbar"),
                     chosen: $chosen, pricesShown: pricesShown)
            PlanTile(choice: .lifetime, badge: Text("Guter Deal"), badgeLoud: false,
                     title: Text("Für immer"), detail: Text("einmal zahlen · wie 10 Monate"),
                     chosen: $chosen, pricesShown: pricesShown)
        }
        .fixedSize(horizontal: false, vertical: true)
        .disabled(support.purchasing != nil || !pricesShown)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Arten zu unterstützen"))
    }

    private var tips: some View {
        HStack(spacing: 6) {
            Text("Einfach Danke ☕")
                .growing(12)
                .foregroundStyle(Theme.fontVeryQuiet)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 4)
            ForEach(SupportTip.ordered, id: \.self) { tip in
                TipChip(choice: .tip(tip), chosen: $chosen, pricesShown: pricesShown)
            }
        }
        .disabled(support.purchasing != nil || !pricesShown)
    }

    /// **The purchase and the terms right below.** Closing is the X and the pull-down.
    private var footer: some View {
        VStack(spacing: 8) {
            if let notice = support.notice {
                Text(notice.text)
                    .growing(12)
                    .foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
            Button {
                guard let chosen else { return }
                buy(chosen)
            } label: {
                buyLabel
            }
            .buttonStyle(PrimaryButtonStyle(lockedArea: Theme.raised))
            .disabled(chosen == nil || support.purchasing != nil || !pricesShown)
            .accessibilityAddTraits(support.purchasing != nil ? .updatesFrequently : [])

            // No "Not now" here: the sheet closes with the X at the top or by pulling it
            // down, and a second button under the purchase only made the footer heavier.

            VStack(spacing: 0) {
                Text("Das Monatsabo verlängert sich, bis du in den Einstellungen deines Apple Accounts kündigst. Für immer ist eine einmalige Zahlung. Trinkgelder sind nur ein Dankeschön.")
                    .growing(11)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    legalLink(Text("Nutzungsbedingungen")) { openURL(SupportLinks.termsURL) }
                    Text(verbatim: "·").foregroundStyle(Theme.fontVeryQuiet).accessibilityHidden(true)
                    legalLink(Text("Datenschutz")) { openURL(SupportLinks.privacyURL) }
                    Text(verbatim: "·").foregroundStyle(Theme.fontVeryQuiet).accessibilityHidden(true)
                    legalLink(Text("Wiederherstellen")) { restore() }
                }
                .growing(11, .medium)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .animation(Theme.reveal, value: support.notice)
        .animation(Theme.reveal, value: chosen)
    }

    private func legalLink(_ title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title
                .underline(color: Theme.font.opacity(0.25))
                .foregroundStyle(Theme.fontQuiet)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressText())
    }

    @ViewBuilder private var buyLabel: some View {
        if support.purchasing != nil {
            HStack(spacing: 6) {
                Text("Warte auf den App Store")
                WaitingDots()
            }
        } else {
            switch chosen {
            case .none:
                Text("Wähl eine Option")
            case .monthly:
                Text("Für \(support.price(.monthly) ?? "") im Monat unterstützen")
            case .lifetime:
                Text(String(format: SupportCopy.supportWithPrice.localized, support.price(.lifetime) ?? ""))
            case let .tip(tip):
                Text("Mit \(support.price(.tip(tip)) ?? "") Danke sagen")
            }
        }
    }

    // MARK: Actions

    private func buy(_ choice: SupportChoice) {
        guard support.purchasing == nil else { return }
        Theme.jerk(.medium)
        Task { await support.buy(choice, with: { try await purchase($0) }) }
    }

    private func restore() {
        Task { await support.restore() }
    }

    /// "Ask the App Store again".
    private func retry() {
        #if DEBUG
        support.forcePricesUnavailable = false
        #endif
        Task { await support.loadProducts(retry: true) }
    }
}

// MARK: - Tiles

/// **One plan: label, price, terms, a badge on the edge.** The choice is state, hence the
/// accent, as a ring and a check that pops in.
private struct PlanTile: View {
    let choice: SupportChoice
    let badge: Text
    /// White badge for the popular plan, a quiet one for the other.
    let badgeLoud: Bool
    let title: Text
    let detail: Text
    @Binding var chosen: SupportChoice?
    let pricesShown: Bool

    private var isChosen: Bool { chosen == choice }

    var body: some View {
        Button {
            Theme.jerk(.lightweight)
            withAnimation(Theme.motionReduced ? Theme.reveal : .spring(response: 0.38, dampingFraction: 0.62)) {
                chosen = choice
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .growing(13)
                    .foregroundStyle(Theme.fontQuiet)
                    .padding(.top, 6)
                if pricesShown {
                    Text(verbatim: SupportModel.shared.price(choice) ?? "")
                        .growing(22, .bold)
                        .monospacedDigit()
                        .tracking(-0.22)
                        .foregroundStyle(Theme.font)
                        .padding(.top, 4)
                        .transition(.opacity)
                    detail
                        .growing(12)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else {
                    SkeletonBar(width: 64, height: 22).padding(.top, 10)
                    SkeletonBar(width: 48, height: 10).padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112 - 28, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: isChosen ? 2 : 0)
            }
            .overlay(alignment: .topTrailing) { indicator.padding(12) }
            .overlay(alignment: .topLeading) {
                badge
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(badgeLoud ? Color(white: 0.04) : Theme.font)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(badgeLoud ? Theme.font : Theme.pressedArea, in: Capsule())
                    .offset(x: 14, y: -9)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    /// An empty ring, or the accent check. The check pops: small, a little too big, home.
    @ViewBuilder private var indicator: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.font.opacity(0.25), lineWidth: 1.5)
                .opacity(isChosen ? 0 : 1)
            if isChosen {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 20, height: 20)
                    .background(Theme.accent, in: Circle())
                    .transition(Theme.motionReduced ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// One tip as a chip. Chosen means the accent ring, like the plans.
private struct TipChip: View {
    let choice: SupportChoice
    @Binding var chosen: SupportChoice?
    let pricesShown: Bool

    var body: some View {
        let isChosen = chosen == choice
        Button {
            Theme.jerk(.lightweight)
            withAnimation(Theme.motionReduced ? Theme.reveal : .spring(response: 0.38, dampingFraction: 0.62)) {
                chosen = choice
            }
        } label: {
            ZStack {
                if pricesShown {
                    Text(verbatim: SupportModel.shared.price(choice) ?? "")
                        .growing(13, .semibold)
                        .monospacedDigit()
                        .foregroundStyle(isChosen ? Theme.font : Theme.font.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    SkeletonBar(width: 34, height: 10)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Theme.area, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.accent, lineWidth: isChosen ? 2 : 0) }
            .contentShape(Capsule())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(Text("Einfach Danke ☕") + Text(verbatim: ", \(SupportModel.shared.price(choice) ?? "")"))
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}

/// A placeholder in the shape of the text it stands for, breathing slowly.
private struct SkeletonBar: View {
    let width: CGFloat
    let height: CGFloat
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.font.opacity(0.08))
            .frame(width: width, height: height)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard !Theme.motionReduced else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

/// "Waiting for the App Store" ends in three dots that light up one after the other.
private struct WaitingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: Theme.motionReduced)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (time / 1.2 - Double(index) * 0.2 / 1.2).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .frame(width: 5, height: 5)
                        .opacity(Theme.motionReduced ? 0.6 : 0.2 + 0.8 * (1 - abs(phase * 2 - 1)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// **The App Store did not answer.** What happened, that nothing is lost, and one way to
/// try again.
private struct PricesUnavailableCard: View {
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 18))
                .foregroundStyle(Theme.font)
                .frame(width: 40, height: 40)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Preise sind gerade nicht verfügbar")
                    .growing(15, .semibold)
                    .foregroundStyle(Theme.font)
                Text("Der App Store hat nicht geantwortet. Das passiert ohne Internet oder wenn Käufe in der Bildschirmzeit aus sind. Nichts geht verloren, und Swiftly läuft wie immer.")
                    .growing(13)
                    .foregroundStyle(Theme.fontQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: retry) {
                    Label("App Store erneut fragen", systemImage: "arrow.clockwise")
                        .growing(14, .semibold)
                        .foregroundStyle(Theme.font)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.groupsArea, in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Hero

/// **Three small phones, each in a look, and the way to try one.** Every one of them is
/// something the looks preview can really set: the original with its glow on, Neon Night,
/// Neon Night with the coral accent.
struct LooksHero: View {
    let tryLooks: () -> Void

    private static let phones: [(selection: LookSelection, x: CGFloat, y: CGFloat, turn: Double, delay: Double)] = [
        (LookSelection(lookID: Look.original.id, glow: .soft), -104, 34, -8, 0),
        (LookSelection(lookID: Look.neonNight.id, accentID: LookAccent.coral.id), 104, 34, 8, 0.8),
        (LookSelection(lookID: Look.neonNight.id), 0, 16, 0, 0.4),
    ]

    var body: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                ForEach(Self.phones.indices, id: \.self) { index in
                    let phone = Self.phones[index]
                    LookMiniPhone(palette: phone.selection.palette, delay: phone.delay)
                        .rotationEffect(.degrees(phone.turn))
                        .offset(x: phone.x, y: phone.y)
                        .zIndex(index == 2 ? 2 : 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // **The phones end softly** above the pill instead of running under it.
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 0.62),
                                       .init(color: .clear, location: 0.9)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.top, -40)
            }
            Button(action: tryLooks) {
                HStack(spacing: 6) {
                    Text("Look ausprobieren")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .accessibilityHidden(true)
                }
                .growing(13, .semibold)
                .foregroundStyle(Theme.font)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .glassPill()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressButton())
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, -7)
            .zIndex(3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 252)
    }
}

/// **A phone of 104 × 208 showing the home page in a look.** Drawn, not a screenshot:
/// wordmark, heart, a row, the bar, all in the look's own colors.
struct LookMiniPhone: View {
    let palette: LookPalette
    var delay: Double = 0
    @State private var up = false

    var body: some View {
        let accent = palette.accent.mainColor
        ZStack(alignment: .topLeading) {
            Theme.reason
            EllipticalGradient(colors: [accent.opacity(0.34), accent.opacity(0)],
                               center: .top, startRadiusFraction: 0, endRadiusFraction: 0.75)
                .frame(height: 64)
            Wordmark(height: 11.6, logo: palette.logoStyle)
                .offset(x: 9, y: 16)
            Image(systemName: "heart.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.font)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 9)
                .offset(y: 16)
            Text("Weiterschauen")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .offset(x: 9, y: 34)
            poster(width: 86, height: 48, corner: 5, progress: 0.44, accent: accent)
                .offset(x: 9, y: 47)
            poster(width: 40, height: 60, corner: 4).offset(x: 9, y: 104)
            poster(width: 40, height: 60, corner: 4).offset(x: 55, y: 104)
            tabBar(accent: accent)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: 104, height: 208)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.font.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 20, y: 18)
        .offset(y: up ? -6 : 0)
        .onAppear {
            guard !Theme.motionReduced else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true).delay(delay)) { up = true }
        }
        .accessibilityHidden(true)
    }

    private func poster(width: CGFloat, height: CGFloat, corner: CGFloat,
                        progress: Double? = nil, accent: Color = .clear) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(colors: [Theme.raised, Theme.area], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottomLeading) {
                if let progress {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.font.opacity(0.3))
                        Rectangle().fill(accent).frame(width: width * progress)
                    }
                    .frame(height: 2.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .frame(width: width, height: height)
    }

    private func tabBar(accent: Color) -> some View {
        HStack {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(index == 0 ? accent : Color(white: 0.333))
                    .frame(width: 8, height: 8)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 24)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

extension View {
    /// The design's pill: a dark, slightly lighter capsule with a thin light edge. **No
    /// material:** a live blur over the whole home page cost frames in the looks preview.
    func glassPill() -> some View {
        background(Color(white: 0.16).opacity(0.92), in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.font.opacity(0.14), lineWidth: 1) }
    }
}

// MARK: - Thank you

/// **After the purchase: warmth, then the app.** The look's icon breathes, hearts rise
/// behind the words; the look is already on.
struct SupportGrowThanks: View {
    let name: String?
    /// Whose icon is shown: the look switched on with the purchase, or the active one.
    let look: Look
    /// Set when the purchase came from "Keep" in the looks preview.
    let keptLook: Look?
    let home: () -> Void
    let done: () -> Void

    @State private var hug = false

    var body: some View {
        ZStack(alignment: .top) {
            RisingHearts()
            VStack(spacing: 0) {
                Image(look.tileName)
                    .resizable()
                    .frame(width: 104, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 23.4, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 14)
                    .offset(y: hug ? -4 : 0)
                    .accessibilityLabel(Text(look.name))
                Text(title)
                    .growing(30, .bold)
                    .tracking(-0.6)
                    .foregroundStyle(Theme.font)
                    .multilineTextAlignment(.center)
                    .padding(.top, 26)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .growing(15)
                    .foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Looks kannst du jederzeit im Profil wechseln.")
                    .growing(13)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 26)
            // 150 from the top of the screen in the design; the sheet itself starts about 50
            // lower.
            .padding(.top, 100)
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 8) {
                Button { home() } label: { Text("Zeig mir meine Startseite") }
                    .buttonStyle(PrimaryButtonStyle())
                Button(SupportCopy.done.localized, action: done)
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear {
            Theme.jerk(.medium)
            guard !Theme.motionReduced else { return }
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) { hug = true }
        }
    }

    private var title: String {
        if let name, !name.isEmpty {
            String(localized: "Danke, \(name) 🫶")
        } else {
            String(localized: "Danke 🫶")
        }
    }

    private var message: String {
        if let keptLook {
            String(localized: "Du hast Swiftly gerade beim Weitermachen geholfen. \(keptLook.name) ist an, dein Icon und Logo auch. Schau dich um.")
        } else {
            String(localized: "Du hast Swiftly gerade beim Weitermachen geholfen. Looks und Icons gehören jetzt dir. Schau dich um.")
        }
    }
}

/// **Four white hearts that rise and fade, one after the other, over and over.** The
/// design's `rise`: 4.6 s, ease-out, up 170 pt, from 60 to 100 percent size. Still when
/// motion is reduced.
private struct RisingHearts: View {
    private static let hearts: [(x: CGFloat, size: CGFloat, delay: Double)] = [
        (92, 22, 0), (272, 26, 1.2), (150, 16, 2.4), (236, 18, 3.3),
    ]
    @State private var start = Date.now

    var body: some View {
        if !Theme.motionReduced {
            GeometryReader { geometry in
                let scale = geometry.size.width / 390
                TimelineView(.animation) { context in
                    let elapsed = context.date.timeIntervalSince(start)
                    ZStack(alignment: .topLeading) {
                        ForEach(Self.hearts.indices, id: \.self) { index in
                            let heart = Self.hearts[index]
                            let local = elapsed - heart.delay
                            let phase = local < 0 ? 0 : (local / 4.6).truncatingRemainder(dividingBy: 1)
                            let eased = 1 - pow(1 - phase, 3)
                            let opacity = local < 0 ? 0
                                : phase < 0.2 ? phase / 0.2 * 0.9 : 0.9 * (1 - (phase - 0.2) / 0.8)
                            Image(systemName: "heart.fill")
                                .font(.system(size: heart.size))
                                .foregroundStyle(Theme.font)
                                .scaleEffect(0.6 + 0.4 * eased)
                                .opacity(opacity)
                                .offset(x: heart.x * scale, y: 270 + 20 - 170 * eased)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
