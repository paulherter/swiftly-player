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
    /// Counts the heartbeats; each change plays two beats.
    @State private var beats = 0
    /// The heart beats once per launch, a second after the home page first appears.
    @MainActor private static var hasBeaten = false

    var body: some View {
        // Supporters have said thank you already; the heart goes away for them.
        if !SupportModel.shared.isSupporter { button }
    }

    private var button: some View {
        Button {
            SupportModel.shared.open()
        } label: {
            symbol
                .font(.system(size: 20))
                .foregroundStyle(Theme.font)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(Text(SupportCopy.supportSwiftly.localized))
    }

    @ViewBuilder private var symbol: some View {
        // White and filled, as drawn. Two soft beats after launch say it is
        // there, then it keeps still.
        Image(systemName: "heart.fill")
            .keyframeAnimator(initialValue: 1.0, trigger: beats) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                // The design's `beat`: 2.6 s, up at 12 and 36 percent, still for the rest; twice.
                KeyframeTrack {
                    CubicKeyframe(1.18, duration: 0.31)
                    CubicKeyframe(1.0, duration: 0.31)
                    CubicKeyframe(1.12, duration: 0.31)
                    CubicKeyframe(1.0, duration: 0.31)
                    LinearKeyframe(1.0, duration: 1.36)
                    CubicKeyframe(1.18, duration: 0.31)
                    CubicKeyframe(1.0, duration: 0.31)
                    CubicKeyframe(1.12, duration: 0.31)
                    CubicKeyframe(1.0, duration: 0.31)
                }
            }
            .task {
                guard !Self.hasBeaten, !Theme.motionReduced else { return }
                Self.hasBeaten = true
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else {
                    Self.hasBeaten = false
                    return
                }
                beats += 1
            }
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
            #if DEBUG
            SupportDebugRows()
            #endif
        }
    }
}

// MARK: - Card

/// **The quiet card at the end of the home page.** No pop-up: whoever scrolls to the
/// end finds it, whoever does not, never sees it. "Not now" hides it for 30 days; the
/// second "Not now" ends it for good (`SupportPromptHistory.snoozeCard`), so the card needs
/// no menu and carries two buttons.
struct SupportCard: View {
    @Environment(\.wide) private var wide

    var body: some View {
        let support = SupportModel.shared
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    // The number only from a size worth saying: "0 hours" is no reason to give.
                    if support.watchedHours >= SupportCopy.cardMinimumHours {
                        Text(String(format: SupportCopy.cardWatchedHours.localized, support.watchedHours))
                            .growing(15, .semibold)
                            .foregroundStyle(Theme.font)
                    }
                    Text(SupportCopy.cardAsk.localized)
                        .growing(15)
                        .foregroundStyle(Theme.fontQuiet)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
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
            // flush-ok: the support sheet is full height (`.presentationDetents([.large])`).
            .sheet(isPresented: rootSheet, onDismiss: {
                support.closed()
                SupportFlow.shared.sheetClosed()
            }) {
                SupportGrowSheet(model: model)
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

    /// The support sheet from the root: over the page, and over the looks panel when a
    /// "Keep" opens it.
    private var rootSheet: Binding<Bool> {
        let support = SupportModel.shared
        return Binding(get: { support.presented }, set: { support.presented = $0 })
    }

    private func ask(sheet: Bool) {
        guard model.phase == .ready else { return }
        // One big ask per session: after the gift or What's New the sheet waits.
        let gift = GiftFlow.shared
        SupportModel.shared.evaluate(
            isPlaying: model.playerOpen,
            sheetAllowed: sheet && !model.ratingDue && !model.discordHintDue && !gift.bigAskShown
                && gift.stage == nil && Date.now.timeIntervalSince(playerClosedAt) > 10)
        if SupportModel.shared.presented { gift.noteBigAsk() }
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
        ValueRow(symbol: "creditcard", title: Text(verbatim: "Simulate purchases (no App Store)"),
                 value: support.simulatePurchases ? "On" : "Off",
                 action: { support.simulatePurchases.toggle() })
        ValueRow(symbol: "icloud.slash", title: Text(verbatim: "Prices unavailable in the sheet"),
                 value: support.forcePricesUnavailable ? "On" : "Off",
                 action: { support.forcePricesUnavailable.toggle() })
        // Halloween before its window: the clock of the looks stands on 26 Oct, and the gift
        // pop-up and What's New can be called up by hand.
        ValueRow(symbol: "calendar", title: Text(verbatim: "Halloween season now"),
                 value: LookClock.seasonOverride ? "On" : "Off",
                 action: {
                     LookClock.seasonOverride.toggle()
                     // Switched on: a bat flies at once, to see the effect without waiting.
                     if LookClock.seasonOverride {
                         NotificationCenter.default.post(name: .lookBatNow, object: nil)
                     }
                 })
        ValueRow(symbol: "gift", title: Text(verbatim: "Show the gift pop-up now"),
                 action: { GiftFlow.shared.stage = .offer(.halloween) })
        ValueRow(symbol: "sparkles", title: Text(verbatim: "Show What's New now"),
                 action: {
                     if let entry = WhatsNewEntry.bundled(for: "1.0.8") { GiftFlow.shared.stage = .whatsNew(entry) }
                 })
        ValueRow(symbol: "arrow.counterclockwise", title: Text(verbatim: "Reset support state"),
                 action: {
                     support.debugReset()
                     SupportFlow.shared.reset()
                 })
    }
}
#endif
