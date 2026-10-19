import JellyfinKit
import StoreKit
import SwiftUI

// **"Support Swiftly" on Apple TV.** Derived from `Sources/Shared/SupportViews.swift`
// (iPhone leads). The rules from App Review carry over unchanged: nothing is locked,
// "Maybe later" is as visible as a tip, the entry in Settings is always there, and
// there is no other way to pay than the App Store.
//
// What differs is distance and input. Focus is not a choice on a remote, so a press
// on a tip buys right away (the system dialog is the confirmation), and the sheet
// is a full page. The sheet is never pushed on the TV: only the card asks.

// MARK: - Settings entries

/// **The first row of the "Swiftly" area**: the heart, the line, "Thank you" for
/// supporters. Built here because `ActionRow` has no icon or second line.
struct TVSupportEntryRow: View {
    let action: () -> Void

    var body: some View {
        let support = SupportModel.shared
        Button(action: action) {
            HStack(spacing: 24) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(support.isSupporter ? Theme.accent : Theme.font)
                    .frame(width: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SupportCopy.supportSwiftly.localized)
                    Text(SupportCopy.sayThanksFreeForAll.localized)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(1)
                }
                Spacer(minLength: 40)
                if support.isSupporter {
                    Text(SupportCopy.thankYou.localized)
                        .foregroundStyle(Theme.fontQuiet)
                }
            }
        }
        .buttonStyle(RowsStyle())
    }
}

/// The row that opens the icon picker; the value is the icon in use.
struct TVAppIconRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                Text(SupportCopy.appIcon.localized)
                Spacer(minLength: 40)
                Text(SupportModel.shared.appIcon?.name ?? String(localized: "Standard"))
                    .foregroundStyle(Theme.fontQuiet)
                Image(systemName: "chevron.right")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(RowsStyle())
    }
}

/// **App version, with the supporter mark** (accent heart) for supporters.
struct TVVersionRow: View {
    var body: some View {
        HStack(spacing: 24) {
            Text("Swiftly").font(.system(size: 30, weight: .medium))
            Spacer(minLength: 40)
            if SupportModel.shared.isSupporter {
                Image(systemName: "heart.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(SupportCopy.supporterBadge.localized)
                    .font(Theme.button)
                    .foregroundStyle(Theme.fontQuiet)
            }
            Text(Version.row).font(Theme.button).foregroundStyle(Theme.fontQuiet)
        }
        .foregroundStyle(Theme.font)
        .padding(.horizontal, 26)
        .frame(height: Theme.rowsHeight)
        .accessibilityElement(children: .combine)
    }
}

/// **The small heart on the profile picture**, bottom right, supporters only. A ring
/// in the background color separates it from the picture.
struct TVSupporterAvatarBadge: ViewModifier {
    let size: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if SupportModel.shared.isSupporter {
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.2, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(size * 0.06)
                    .background(Theme.reason, in: Circle())
                    .offset(x: size * 0.04, y: size * 0.04)
                    .accessibilityLabel(Text(SupportCopy.supporterBadge.localized))
            }
        }
    }
}

// MARK: - Card

/// **The quiet card at the end of the home page.** No pop-up. Three plain buttons:
/// the TV has no context menu habit, so "Don't show again" sits beside the others.
struct TVSupportCard: View {
    var body: some View {
        let support = SupportModel.shared
        VStack(alignment: .leading, spacing: 0) {
            Text(String(format: SupportCopy.cardWatchedHours.localized, support.watchedHours))
                .font(Theme.rail)
                .foregroundStyle(Theme.font)
            Text(SupportCopy.cardAsk.localized)
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.top, 8)
            HStack(spacing: 24) {
                Button(SupportCopy.cardSupport.localized) { support.open() }
                    .buttonStyle(ThemedButtonStyle())
                Button(SupportCopy.notNow.localized) {
                    withAnimation(Theme.reveal) { support.snoozeCard() }
                }
                .buttonStyle(ThemedButtonStyle())
                Button(SupportCopy.dontShowAgain.localized) {
                    withAnimation(Theme.reveal) { support.dismissCard() }
                }
                .buttonStyle(ThemedButtonStyle())
            }
            .padding(.top, 32)
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.groupsArea,
                    in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        .focusSection()
    }
}

// MARK: - Presenting

extension View {
    /// **The one place the support page hangs on `presented`**, at the root. Settings
    /// uses its own local flag, so two covers never share one binding. Also decides
    /// when to ask: a minute after launch, after the player closes, on return. On the
    /// TV only the card ever appears, never the page by itself.
    func tvSupportPresentation(model: AppModel) -> some View {
        modifier(TVSupportPresentation(model: model))
    }
}

private struct TVSupportPresentation: ViewModifier {
    let model: AppModel
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        @Bindable var support = SupportModel.shared
        content
            .fullScreenCover(isPresented: $support.presented) {
                TVSupportView { support.presented = false }
            }
            .task {
                try? await Task.sleep(for: .seconds(SupportPrompt.quietAfterLaunch + 1))
                ask()
            }
            .onChange(of: model.playerOpen) { _, open in
                if !open { ask() }
            }
            .onChange(of: phase) { _, new in
                if new == .active { ask() }
            }
    }

    private func ask() {
        guard model.phase == .ready else { return }
        SupportModel.shared.evaluate(isPlaying: model.playerOpen, sheetAllowed: false)
    }
}

// MARK: - Page

/// **"Support Swiftly": three tips, then the thank-you page, then the icons.** One
/// full-screen page; Back closes it (from the icons first back to the page before).
struct TVSupportView: View {
    enum Start: Identifiable { case support, icons; var id: Self { self } }

    var start: Start = .support
    let close: () -> Void

    @Environment(\.purchase) private var purchase
    @State private var showsIcons = false
    @State private var failed = false
    @FocusState private var focus: Target?

    private enum Target: Hashable {
        case tip(SupportTip), later, restore, retry, choose, done, icon(Int), support
    }

    private var support: SupportModel { .shared }

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()
            Group {
                if showsIcons {
                    icons
                } else if support.showsThanks {
                    thanks
                } else {
                    offer
                }
            }
            .padding(.horizontal, Theme.edgePage)
            .padding(.vertical, Theme.edgeTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.opacity)
        }
        .ignoresSafeArea(edges: .horizontal)
        .animation(Theme.reveal, value: showsIcons)
        .animation(Theme.reveal, value: support.showsThanks)
        .onAppear { showsIcons = start == .icons }
        .task { await support.loadProducts() }
        .onExitCommand {
            if showsIcons, start == .support {
                showsIcons = false
            } else {
                finish()
            }
        }
    }

    /// Closing keeps nothing half-done for the next time.
    private func finish() {
        support.closed()
        close()
    }

    // MARK: Offer

    private var offer: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(SupportCopy.supportSwiftly.localized)
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.font)
                Text(SupportCopy.sheetIntro.localized)
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1200)
                    .padding(.top, 16)

                // Nothing is preselected: a press on a tip is the purchase itself.
                HStack(spacing: 32) {
                    ForEach(SupportTip.ordered, id: \.self) { tip in
                        tipButton(tip)
                    }
                }
                .focusSection()
                .padding(.top, 48)

                if let notice = support.notice {
                    Text(notice.text)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                        .multilineTextAlignment(.center)
                        .padding(.top, 24)
                        .transition(.opacity)
                }

                // "Maybe later" has the same weight as the purchase (5.6).
                HStack(spacing: 24) {
                    Button(SupportCopy.maybeLater.localized, action: finish)
                        .buttonStyle(ThemedButtonStyle())
                        .focused($focus, equals: .later)
                    Button {
                        Task { await support.restore() }
                    } label: {
                        if support.restoring {
                            ProgressView()
                        } else {
                            Text(SupportCopy.restorePurchases.localized)
                        }
                    }
                    .buttonStyle(ThemedButtonStyle())
                    .focused($focus, equals: .restore)
                    if support.productsState == .unavailable {
                        Button("Erneut versuchen") { Task { await support.loadProducts() } }
                            .buttonStyle(ThemedButtonStyle())
                            .focused($focus, equals: .retry)
                    }
                }
                .focusSection()
                .padding(.top, 32)

                Text(SupportCopy.freeForEveryone.localized)
                    .font(Theme.button)
                    .foregroundStyle(Theme.font)
                    .padding(.top, 40)
                Text(SupportCopy.storeThankYouGifts.localized)
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1200)
                    .padding(.top, 6)
                Text(SupportCopy.oneTimePurchaseAppStore.localized)
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1200)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .defaultFocus($focus, .tip(SupportTip.ordered.first ?? .coffee))
        .animation(Theme.reveal, value: support.notice)
    }

    private func tipButton(_ tip: SupportTip) -> some View {
        let price = support.products[tip]?.displayPrice
        let running = support.purchasing == tip
        return Button {
            guard support.purchasing == nil, support.products[tip] != nil else { return }
            Task { await support.buy(tip) { try await purchase($0) } }
        } label: {
            VStack(spacing: 10) {
                Text(verbatim: tip.emoji)
                    .font(.system(size: 64))
                    .accessibilityHidden(true)
                Text(tip.title.localized)
                    .font(Theme.button)
                    .foregroundStyle(Theme.font)
                if running || (support.productsState == .loading && price == nil) {
                    ProgressView().frame(height: 36)
                } else {
                    Text(verbatim: price ?? "–")
                        .font(Theme.body)
                        .foregroundStyle(Theme.fontQuiet)
                        .frame(height: 36)
                }
            }
            .frame(width: 340, height: 240)
        }
        .buttonStyle(TVTipStyle())
        .focused($focus, equals: .tip(tip))
    }

    // MARK: Thanks

    private var thanks: some View {
        VStack(spacing: 0) {
            Image(systemName: "heart.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(SupportCopy.thanksTitle.localized)
                .font(Theme.titleLarge)
                .foregroundStyle(Theme.font)
                .padding(.top, 20)
            Text(SupportCopy.thanksBody.localized)
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1200)
                .padding(.top, 12)

            VStack(spacing: 0) {
                gift(preview: AnyView(iconStrip), title: SupportCopy.giftIconsTitle,
                     detail: SupportCopy.giftIconsDetail)
                Rectangle().fill(Theme.line).frame(height: 1)
                gift(preview: AnyView(heartBadge), title: SupportCopy.giftHeartTitle,
                     detail: SupportCopy.giftHeartDetail)
            }
            .frame(maxWidth: 1100)
            .background(Theme.groupsArea,
                        in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
            .padding(.top, 40)

            HStack(spacing: 24) {
                Button(SupportCopy.chooseAppIcon.localized) { showsIcons = true }
                    .buttonStyle(ThemedButtonStyle())
                    .focused($focus, equals: .choose)
                Button(SupportCopy.done.localized, action: finish)
                    .buttonStyle(ThemedButtonStyle())
                    .focused($focus, equals: .done)
            }
            .focusSection()
            .padding(.top, 40)
        }
        .defaultFocus($focus, .choose)
    }

    private func gift(preview: AnyView, title: SupportCopy, detail: SupportCopy) -> some View {
        HStack(spacing: 28) {
            preview.frame(width: 190, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.localized).font(Theme.button).foregroundStyle(Theme.font)
                Text(detail.localized).font(Theme.small).foregroundStyle(Theme.fontQuiet)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .accessibilityElement(children: .combine)
    }

    private var iconStrip: some View {
        HStack(spacing: -24) {
            ForEach([SupporterIcon.heart, .gold, .aurora]) { icon in
                Image(icon.previewAsset)
                    .resizable()
                    .aspectRatio(400.0 / 240.0, contentMode: .fit)
                    .frame(width: 96)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                            .strokeBorder(Theme.groupsArea, lineWidth: 3)
                    }
            }
        }
        .accessibilityHidden(true)
    }

    private var heartBadge: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 44))
            .foregroundStyle(Theme.accent)
            .accessibilityHidden(true)
    }

    // MARK: Icons

    /// **The icon picker.** Supporters choose; everyone else browses the same icons
    /// (the tiles stay focusable so the names can be read, a press does nothing) with
    /// the way to support right below.
    private var icons: some View {
        let supporter = support.isSupporter
        return VStack(spacing: 0) {
            Text(SupportCopy.appIcon.localized)
                .font(Theme.titleLarge)
                .foregroundStyle(Theme.font)
            if !supporter {
                Text(SupportCopy.storeThankYouGifts.localized)
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1200)
                    .padding(.top, 16)
            }
            HStack(alignment: .top, spacing: 28) {
                tile(nil, index: 0)
                ForEach(Array(SupporterIcon.allCases.enumerated()), id: \.element) { i, icon in
                    tile(icon, index: i + 1)
                }
            }
            .focusSection()
            .padding(.top, 56)

            if failed {
                Text("Das Icon ließ sich nicht wechseln.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontQuiet)
                    .padding(.top, 24)
            }
            if !supporter {
                Button {
                    // Same page, other content: the page before is the offer.
                    showsIcons = false
                } label: {
                    Label(SupportCopy.supportSwiftly.localized, systemImage: "heart.fill")
                }
                .buttonStyle(ThemedButtonStyle())
                .focused($focus, equals: .support)
                .focusSection()
                .padding(.top, 48)
            }
        }
        .defaultFocus($focus, .icon(0))
    }

    private func tile(_ icon: SupporterIcon?, index: Int) -> some View {
        let selected = support.isChosen(icon)
        let name = icon?.name ?? String(localized: "Standard")
        return Button {
            // Everyone else browses a preview; only the way back to the original is open.
            guard support.canChoose(icon) else { return }
            Task {
                await support.choose(icon)
                failed = support.appIcon != icon
            }
        } label: {
            VStack(spacing: 14) {
                Image(icon?.previewAsset ?? SupporterIcon.standardPreviewAsset)
                    .resizable()
                    .aspectRatio(400.0 / 240.0, contentMode: .fit)
                    .frame(width: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cornerTile + 6, style: .continuous)
                            .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 4)
                            .padding(-8)
                    }
                Text(name)
                    .font(Theme.small)
                    .foregroundStyle(selected ? Theme.font : Theme.fontQuiet)
                    .lineLimit(1)
            }
        }
        .buttonStyle(TileStyle())
        .focused($focus, equals: .icon(index))
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One tip card: the calm focus surface and the base tile movement, no white.
private struct TVTipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .background(focus ? Theme.raised : Theme.groupsArea,
                            in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
                .scaleEffect(focus ? Theme.focusMagnifier : 1)
                .animation(Theme.focusAnimation, value: focus)
        }
    }
}
