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
                Image(icon: "heart.fill")
                    .font(.app(size: 30, weight: .semibold))
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

/// **App version, with the supporter mark** (accent heart) for supporters.
struct TVVersionRow: View {
    var body: some View {
        HStack(spacing: 24) {
            Text("Swiftly").font(.app(size: 30, weight: .medium))
            Spacer(minLength: 40)
            if SupportModel.shared.isSupporter {
                Image(icon: "heart.fill")
                    .font(.app(size: 24))
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
                Image(icon: "heart.fill")
                    .font(.app(size: size * 0.2, weight: .semibold))
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
        // While the gift page is up, the support page goes over that one (see `TVGiftView`).
        let shown = Binding(get: { support.presented && GiftFlow.shared.stage == nil },
                            set: { if !$0 { support.presented = false } })
        content
            .fullScreenCover(isPresented: shown, onDismiss: {
                support.closed()
                SupportFlow.shared.sheetClosed()
            }) {
                TVSupportPage(model: model)
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
