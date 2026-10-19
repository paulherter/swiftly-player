import JellyfinKit
import StoreKit
import SwiftUI

// **"Support Swiftly" on iPhone and iPad.** The lead version: Mac and Apple TV
// derive their views from this one (`MacSupport.swift`, `TVSupport.swift`).
//
// What is asked and when is decided in the package (`SupportPrompt`) and held by
// `SupportModel`; here is only how it looks. The rules from App Review shape every
// part of it:
//
// - **Nothing is locked.** The tip is a thank-you; the extras are an icon and a heart.
// - **"Maybe later" is as visible as the purchase** (5.6): same height, same width,
//   directly below. Nothing is preselected, the sheet closes without buying.
// - **Always reachable** (2.1): Settings → Support Swiftly, from the first launch on.
//   Card and sheet only come after days of use.
// - **No link anywhere else.** Store builds carry no other way to pay.

// MARK: - Entry points

/// **The heart in the header.** White like the bookmark next to it: it is a
/// destination, not a state, and the accent belongs to state.
struct SupportHeart: View {
    var body: some View {
        Button {
            SupportModel.shared.open()
        } label: {
            Image(systemName: "heart.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.font)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(Text(SupportCopy.supportSwiftly.localized))
    }
}

/// **Heart and "Supporter" next to the version**, only for supporters. The heart
/// carries the accent: being a supporter is a state.
struct SupporterMark: View {
    var body: some View {
        if SupportModel.shared.isSupporter {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(SupportCopy.supporterBadge.localized)
                    .foregroundStyle(Theme.fontQuiet)
            }
            .growing(12)
        }
    }
}

/// **The small heart on the profile picture**, bottom right, only for supporters.
/// The ring of the background color separates it from the picture.
struct SupporterAvatarBadge: ViewModifier {
    let size: CGFloat
    /// Only on the account signed in here; the status belongs to this device.
    var shown = true

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if shown, SupportModel.shared.isSupporter {
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.2, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(size * 0.06)
                    .background(Theme.groupsArea, in: Circle())
                    .offset(x: size * 0.04, y: size * 0.04)
                    .accessibilityLabel(Text(SupportCopy.supporterBadge.localized))
            }
        }
    }
}

/// **The settings group "Swiftly".** Support is always here, from the first launch
/// on: it is the entry App Review is pointed to.
struct SupportSettingsGroup: View {
    var body: some View {
        let support = SupportModel.shared
        SettingGroup(title: "Swiftly") {
            ValueRow(symbol: "heart.fill",
                     title: Text(SupportCopy.supportSwiftly.localized),
                     under: Text(SupportCopy.sayThanks.localized),
                     value: support.isSupporter ? SupportCopy.thankYou.localized : nil,
                     action: { support.open() })
            SheetLine()
            NavigationLink {
                AppIconPicker()
            } label: {
                ValueRow(symbol: "app",
                         title: Text(SupportCopy.appIcon.localized),
                         value: support.appIcon?.name ?? String(localized: "Standard"))
            }
            .buttonStyle(Theme.PressRow())
            #if DEBUG
            SupportDebugRows()
            #endif
        }
    }
}

// MARK: - Card

/// **The quiet card at the end of the home page.** No pop-up: whoever scrolls to the
/// end finds it, whoever does not, never sees it. "Not now" hides it for 30 days;
/// "Don't show again" sits in the menu, so the card does not carry three buttons.
struct SupportCard: View {
    @Environment(\.wide) private var wide

    var body: some View {
        let support = SupportModel.shared
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: SupportCopy.cardWatchedHours.localized, support.watchedHours))
                        .growing(15, .semibold)
                        .foregroundStyle(Theme.font)
                    Text(SupportCopy.cardAsk.localized)
                        .growing(15)
                        .foregroundStyle(Theme.fontQuiet)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Menu {
                    Button(SupportCopy.dontShowAgain.localized) {
                        withAnimation(Theme.reveal) { support.dismissCard() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.top, -12)
                .padding(.trailing, -12)
                .accessibilityLabel(Text(SupportCopy.dontShowAgain.localized))
            }
            HStack(spacing: 10) {
                Button(SupportCopy.cardSupport.localized) { support.open() }
                    .buttonStyle(PrimaryButtonStyle())
                Button(SupportCopy.notNow.localized) {
                    withAnimation(Theme.reveal) { support.snoozeCard() }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 16)
        }
        .padding(18)
        .background(Theme.groupsArea,
                    in: RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
        .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
        .padding(.horizontal, Theme.margin(wide: wide))
        .transition(.opacity)
    }
}

// MARK: - Presenting

extension View {
    /// **The one place the support sheet hangs**, at the root: every entry point
    /// (heart, settings row, card, the occasional ask) only sets
    /// `SupportModel.presented`.
    ///
    /// Also decides when to ask: a minute after launch, after the player closes,
    /// when the app returns to the front. Never with the player open, and never in
    /// the same moment as the rating prompt or the Discord hint.
    func supportPresentation(model: AppModel) -> some View {
        modifier(SupportPresentation(model: model))
    }
}

private struct SupportPresentation: ViewModifier {
    let model: AppModel
    @Environment(\.scenePhase) private var phase
    /// The rating prompt and the Discord hint come 1.5 s after the player closes and
    /// reset their flags before that; this keeps the sheet out of that moment.
    @State private var playerClosedAt = Date.distantPast

    func body(content: Content) -> some View {
        @Bindable var support = SupportModel.shared
        content
            .sheet(isPresented: $support.presented, onDismiss: { support.closed() }) {
                SupportSheet()
            }
            .task {
                try? await Task.sleep(for: .seconds(SupportPrompt.quietAfterLaunch + 1))
                ask(sheet: true)
            }
            .onChange(of: model.playerOpen) { _, open in
                guard !open else { return }
                playerClosedAt = .now
                // The card may appear behind the closing player; the sheet waits for
                // the next launch or return, the rating prompt has this moment.
                ask(sheet: false)
            }
            .onChange(of: phase) { _, new in
                if new == .active { ask(sheet: true) }
            }
    }

    private func ask(sheet: Bool) {
        guard model.phase == .ready else { return }
        SupportModel.shared.evaluate(
            isPlaying: model.playerOpen,
            sheetAllowed: sheet && !model.ratingDue && !model.discordHintDue
                && Date.now.timeIntervalSince(playerClosedAt) > 10)
    }
}

// MARK: - Sheet

/// **"Support Swiftly": three tips, then the thank-you page.**
struct SupportSheet: View {
    @Environment(\.dismiss) private var close
    @Environment(\.purchase) private var purchase
    /// Nothing is preselected: choosing is the person's first step.
    @State private var chosen: SupportTip?

    private var support: SupportModel { .shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if support.showsThanks {
                        SupportThanks { close() }
                            .transition(.opacity)
                    } else {
                        offer
                    }
                }
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.bottom, 24)
                .frame(maxWidth: Theme.formWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Theme.reason.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !support.showsThanks { footer }
            }
            .toolbar(.hidden, for: .navigationBar)
            .animation(Theme.reveal, value: support.showsThanks)
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.reason)
        .presentationCornerRadius(Theme.cornerSheet)
        .onAppear { support.sheetAppeared() }
        .task { await support.loadProducts() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(support.showsThanks ? SupportCopy.thankYou.localized
                                     : SupportCopy.supportSwiftly.localized)
                .font(Theme.subpageTitle)
                .tracking(Theme.lockSubpage)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.fontQuiet)
                    .frame(width: 32, height: 32)
                    .background(Theme.area, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressButton())
            .accessibilityLabel(Text("Schließen"))
        }
        .padding(.leading, Theme.edgeSpacing)
        .padding(.trailing, 8)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Theme.reason)
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(SupportCopy.sheetIntro.localized)
                .growing(15)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)

            VStack(spacing: 10) {
                ForEach(SupportTip.ordered, id: \.self) { tip in
                    TipRow(tip: tip, price: support.products[tip]?.displayPrice,
                           loading: support.productsState == .loading,
                           chosen: chosen == tip,
                           running: support.purchasing == tip) {
                        chosen = tip
                    }
                    .disabled(support.purchasing != nil)
                }
            }

            if support.productsState == .unavailable {
                Button("Erneut versuchen") {
                    Task { await support.loadProducts() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 12)
            }

            Text(SupportCopy.freeForEveryone.localized)
                .growing(15, .semibold)
                .foregroundStyle(Theme.font)
                .padding(.top, 22)
            Text(SupportCopy.storeThankYouGifts.localized)
                .growing(15)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(.top, 6)
    }

    /// **Buy and "Maybe later" with the same weight**: same height, full width,
    /// one above the other.
    private var footer: some View {
        VStack(spacing: 10) {
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
                Task { await support.buy(chosen) { try await purchase($0) } }
            } label: {
                if support.purchasing != nil {
                    ProgressView().tint(Theme.onAccent)
                } else {
                    Text(buyTitle)
                }
            }
            .buttonStyle(PrimaryButtonStyle(lockedArea: Theme.raised))
            .disabled(chosen == nil || support.products[chosen ?? .coffee] == nil
                      || support.purchasing != nil)

            Button(SupportCopy.maybeLater.localized) { close() }
                .buttonStyle(SecondaryButtonStyle())

            Text(SupportCopy.oneTimePurchaseAppStore.localized)
                .growing(12)
                .foregroundStyle(Theme.fontVeryQuiet)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

            Button {
                Task { await support.restore() }
            } label: {
                if support.restoring {
                    ProgressView().tint(Theme.fontQuiet)
                } else {
                    Text(SupportCopy.restorePurchases.localized)
                }
            }
            .growing(12, .medium)
            .foregroundStyle(Theme.fontQuiet)
            .frame(minHeight: 44)
            .buttonStyle(Theme.PressButton())
            .disabled(support.restoring)
        }
        .padding(.horizontal, Theme.edgeSpacing)
        .padding(.top, 12)
        .frame(maxWidth: Theme.formWidth)
        .frame(maxWidth: .infinity)
        .background(Theme.reason)
        .animation(Theme.reveal, value: support.notice)
    }

    private var buyTitle: String {
        guard let chosen, let price = support.products[chosen]?.displayPrice else {
            return SupportCopy.cardSupport.localized
        }
        return String(format: SupportCopy.supportWithPrice.localized, price)
    }
}

/// One tip: emoji, name, the store's price. The emoji appear only here.
private struct TipRow: View {
    let tip: SupportTip
    let price: String?
    let loading: Bool
    let chosen: Bool
    let running: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(verbatim: tip.emoji)
                    .font(.system(size: 24))
                    .accessibilityHidden(true)
                Text(tip.title.localized)
                    .growing(15, .semibold)
                    .foregroundStyle(Theme.font)
                Spacer(minLength: 8)
                if running || (loading && price == nil) {
                    ProgressView().tint(Theme.fontQuiet)
                } else if let price {
                    Text(verbatim: price)
                        .growing(15)
                        .foregroundStyle(Theme.fontQuiet)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 60)
            .background(Theme.groupsArea,
                        in: RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
            .overlay {
                // The choice is state, hence the accent, as a ring and not a fill.
                RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous)
                    .strokeBorder(chosen ? Theme.accent : Theme.line, lineWidth: chosen ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Thank you

/// **After the purchase: what is new.** A preview of the extras, and the way to
/// the icons right away.
struct SupportThanks: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "heart.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
                .padding(.top, 12)
            Text(SupportCopy.thanksTitle.localized)
                .font(Theme.title)
                .foregroundStyle(Theme.font)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            Text(SupportCopy.thanksBody.localized)
                .growing(15)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            VStack(spacing: 0) {
                gift(preview: AnyView(iconStrip), title: SupportCopy.giftIconsTitle,
                     detail: SupportCopy.giftIconsDetail)
                SheetLine()
                gift(preview: AnyView(heartBadge), title: SupportCopy.giftHeartTitle,
                     detail: SupportCopy.giftHeartDetail)
            }
            .background(Theme.groupsArea,
                        in: RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
            .padding(.top, 24)

            NavigationLink {
                AppIconPicker()
            } label: {
                Text(SupportCopy.chooseAppIcon.localized)
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 24)
            Button(SupportCopy.done.localized, action: done)
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 10)
        }
    }

    private func gift(preview: AnyView, title: SupportCopy, detail: SupportCopy) -> some View {
        HStack(spacing: 14) {
            preview.frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.localized)
                    .growing(15, .semibold)
                    .foregroundStyle(Theme.font)
                Text(detail.localized)
                    .growing(12)
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private var iconStrip: some View {
        HStack(spacing: -10) {
            ForEach([SupporterIcon.heart, .gold, .aurora]) { icon in
                Image(icon.previewAsset)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.groupsArea, lineWidth: 2)
                    }
            }
        }
        .accessibilityHidden(true)
    }

    private var heartBadge: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 22))
            .foregroundStyle(Theme.accent)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }
}

// MARK: - App icon

/// **The icon picker.** Supporters choose; everyone else sees the same icons as a
/// preview, with the way to support right below. Back to the original with
/// "Standard", always.
struct AppIconPicker: View {
    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var failed = false

    private var support: SupportModel { .shared }
    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 14, alignment: .top)]

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 0) {
                SubpageHeader(title: SupportCopy.appIcon.localized) { back() } right: { EmptyView() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !support.isSupporter {
                            Text(SupportCopy.storeThankYouGifts.localized)
                                .growing(15)
                                .foregroundStyle(Theme.fontQuiet)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 16)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            tile(nil)
                            ForEach(SupporterIcon.allCases) { tile($0) }
                        }
                        if failed {
                            Text("Das Icon ließ sich nicht wechseln.")
                                .growing(12)
                                .foregroundStyle(Theme.fontQuiet)
                                .padding(.top, 16)
                        }
                        if !support.isSupporter {
                            Button {
                                support.open()
                            } label: {
                                Label(SupportCopy.supportSwiftly.localized, systemImage: "heart.fill")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .padding(.top, 24)
                        }
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.bottom, 40)
                    .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
    }

    private func tile(_ icon: SupporterIcon?) -> some View {
        let selected = support.isChosen(icon)
        return Button {
            Task {
                await support.choose(icon)
                failed = support.appIcon != icon
            }
        } label: {
            VStack(spacing: 8) {
                Image(icon?.previewAsset ?? SupporterIcon.standardPreviewAsset)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2)
                            .padding(-4)
                    }
                Text(icon?.name ?? String(localized: "Standard"))
                    .growing(12)
                    .foregroundStyle(selected ? Theme.font : Theme.fontQuiet)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        // A preview for everyone else: visible, not selectable; only the way back is open.
        .disabled(!support.canChoose(icon))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

#if DEBUG
/// Preview block for debug builds: the new surfaces without days of use.
struct SupportDebugRows: View {
    var body: some View {
        let support = SupportModel.shared
        SheetLine()
        ValueRow(symbol: "eye", title: Text(verbatim: "Preview (debug)"))
        ValueRow(symbol: "rectangle.bottomhalf.inset.filled", title: Text(verbatim: "Show the card now"),
                 action: { support.debugShowCard() })
        ValueRow(symbol: "party.popper", title: Text(verbatim: "Show the thank-you sheet now"),
                 action: { support.debugShowThanks() })
        ValueRow(symbol: "heart.fill", title: Text(verbatim: "Mark as supporter"),
                 action: { support.debugMarkSupporter() })
        ValueRow(symbol: "arrow.counterclockwise", title: Text(verbatim: "Reset support state"),
                 action: { support.debugReset() })
    }
}
#endif
