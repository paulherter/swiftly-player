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

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()
            LookGlowLayer(glow: .soft, anchoredToScreen: false)
            if support.showsThanks {
                thanks
            } else {
                offer
            }
        }
        .tint(Theme.accent)
        .task { await support.loadProducts() }
        .onExitCommand { if !busy { close() } }
    }

    // MARK: Offer

    private var offer: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text("Hilf Swiftly zu wachsen")
                        .font(Theme.titleLarge)
                        .foregroundStyle(Theme.font)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: "🌱").font(Theme.titleLarge)
                }
                Text("Dein Beitrag hält Swiftly am Laufen.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .padding(.top, 10)
                Text("Open Source, keine Werbung, alles zum Schauen bleibt kostenlos.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .padding(.top, 4)

                Button {
                    close()
                    GiftFlow.shared.openLooks()
                } label: {
                    HStack(spacing: 12) {
                        Text("Look ausprobieren")
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                }
                .buttonStyle(ThemedButtonStyle())
                .disabled(busy)
                .padding(.top, 36)

                if support.pricesUnavailable {
                    unavailable.padding(.top, 36)
                } else {
                    plans.padding(.top, 36)
                    tips.padding(.top, 28)
                }

                if let notice = support.notice {
                    Text(notice.text)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                        .multilineTextAlignment(.center)
                        .padding(.top, 24)
                }

                Button { if let chosen { buy(chosen) } } label: { Text(buyTitle) }
                    .buttonStyle(ThemedButtonStyle())
                    .disabled(chosen == nil || busy || !pricesShown)
                    .padding(.top, 28)

                Text("Das Monatsabo verlängert sich, bis du in den Einstellungen deines Apple Accounts kündigst. Für immer ist eine einmalige Zahlung. Trinkgelder sind nur ein Dankeschön.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
                    .padding(.top, 24)

                Button { restore() } label: { Text("Wiederherstellen") }
                    .buttonStyle(ThemedButtonStyle())
                    .disabled(busy)
                    .padding(.top, 20)
            }
            .padding(.horizontal, Theme.edgePage)
            .padding(.vertical, Theme.edgeTop)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .defaultFocus($focus, .monthly)
    }

    private var plans: some View {
        HStack(spacing: 28) {
            planTile(.monthly, badge: "Beliebt", title: "Monatlich", detail: "im Monat · jederzeit kündbar")
            planTile(.lifetime, badge: "Guter Deal", title: "Für immer", detail: "einmal zahlen · wie 10 Monate")
        }
        .focusSection()
        .disabled(busy || !pricesShown)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Arten zu unterstützen"))
    }

    private func planTile(_ choice: SupportChoice, badge: LocalizedStringKey,
                          title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        let isChosen = chosen == choice
        return Button { chosen = choice } label: {
            VStack(spacing: 8) {
                Text(badge)
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontQuiet)
                Text(title)
                    .font(Theme.button)
                    .foregroundStyle(Theme.font)
                Text(verbatim: pricesShown ? price(choice) : "···")
                    .font(Theme.categoryLarge)
                    .foregroundStyle(Theme.font)
                Text(detail)
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontQuiet)
            }
            .padding(24)
            .frame(width: 440)
            .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 4)
                    .opacity(isChosen ? 1 : 0)
            }
        }
        .buttonStyle(TileStyle())
        .focused($focus, equals: choice)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    private var tips: some View {
        VStack(spacing: 14) {
            Text("Einfach Danke ☕")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
            HStack(spacing: 20) {
                ForEach(SupportTip.ordered, id: \.self) { tip in
                    let choice = SupportChoice.tip(tip)
                    let isChosen = chosen == choice
                    Button { chosen = choice } label: {
                        Text(verbatim: pricesShown ? price(choice) : "···")
                            .font(Theme.button)
                            .foregroundStyle(Theme.font)
                            .frame(width: 200, height: 84)
                            .background(Theme.area, in: Capsule())
                            .overlay { Capsule().strokeBorder(Theme.accent, lineWidth: 4).opacity(isChosen ? 1 : 0) }
                    }
                    .buttonStyle(TileStyle())
                    .focused($focus, equals: choice)
                    .accessibilityLabel(Text("Einfach Danke ☕") + Text(verbatim: ", \(price(choice))"))
                    .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
                }
            }
            .focusSection()
        }
        .disabled(busy || !pricesShown)
    }

    private var unavailable: some View {
        VStack(spacing: 14) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 44))
                .foregroundStyle(Theme.fontQuiet)
                .accessibilityHidden(true)
            Text("Preise sind gerade nicht verfügbar")
                .font(Theme.button)
                .foregroundStyle(Theme.font)
            Text("Der App Store hat nicht geantwortet. Das passiert ohne Internet oder wenn Käufe in der Bildschirmzeit aus sind. Nichts geht verloren, und Swiftly läuft wie immer.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1000)
            Button(action: retry) {
                Label("App Store erneut fragen", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ThemedButtonStyle())
        }
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

/// The status line on the profile for a supporter: what kind of support, since when.
struct TVSupportStatusRow: View {
    var body: some View {
        let support = SupportModel.shared
        HStack(spacing: 24) {
            Image(systemName: "heart.fill")
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
        .font(.system(size: 30, weight: .medium))
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
