import AppKit
import JellyfinKit
import StoreKit
import SwiftUI

// **"Support Swiftly" on the Mac.** Derived from `Sources/Shared/SupportViews.swift`
// (iPhone leads); what is asked and when lives in the package and `SupportModel`.
// Deviations are only for pointer, keyboard and window size: a fixed-size sheet,
// Esc on "Maybe later", hover on the buttons, the Dock icon instead of alternate icons.
//
// The App Review rules hold here as well: nothing is locked, "Maybe later" is as
// visible as the purchase (same height and width, directly below), nothing is
// preselected, and support is always reachable from Settings.

// MARK: - Buttons

/// Primary (white) and secondary (filled area) with the same height and width, so the
/// two choices weigh the same. Hover and press follow the other Mac buttons.
private struct SupportButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, primary: primary)
    }

    /// A view of its own, because hover is view state and a style is not a view.
    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let primary: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovers = false

        var body: some View {
            configuration.label
                .font(Theme.listTitle)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.primaryButtonHeight)
                .foregroundStyle(primary ? (enabled ? Theme.onAccent : Theme.fontVeryQuiet) : Theme.font)
                .background(fill, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed && !Theme.motionReduced ? 0.97 : 1)
                .onHover { hovers = $0 && enabled }
                .animation(Theme.timeFloat, value: hovers)
        }

        private var fill: Color {
            if primary {
                guard enabled else { return Theme.area }
                return hovers ? Theme.primaryButtonHovers : Theme.font
            }
            return hovers ? Theme.pressedArea : Theme.area
        }
    }
}

// MARK: - Entry points

/// **The heart in the home header.** White like the other bar buttons: it is a
/// destination, not a state.
struct MacSupportHeart: View {
    @State private var hovers = false

    var body: some View {
        // Supporters have said thank you already; the heart goes away for them.
        if !SupportModel.shared.isSupporter { button }
    }

    private var button: some View {
        Button {
            SupportModel.shared.open()
        } label: {
            Image(systemName: "heart.fill")
                .font(.system(size: 17))
                .foregroundStyle(hovers ? Theme.font : Theme.fontQuiet)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityLabel(Text(SupportCopy.supportSwiftly.localized))
    }
}

/// Heart and "Supporter" next to the version, supporters only. The heart carries the
/// accent: being a supporter is a state.
struct MacSupporterMark: View {
    var body: some View {
        if SupportModel.shared.isSupporter {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(SupportCopy.supporterBadge.localized)
                    .foregroundStyle(Theme.fontQuiet)
            }
            .font(Theme.small)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The small heart on the avatar, bottom right. The ring in the card color separates
/// it from the picture.
struct MacSupporterAvatarBadge: ViewModifier {
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

/// **The settings group "Swiftly"**: always here from the first launch on, it is the
/// entry App Review is pointed to. The icon picker sits right under the row.
struct MacSupportSettingsGroup: View {
    var body: some View {
        let support = SupportModel.shared
        SettingGroup(title: "Swiftly") {
            ValuesRow(symbol: "heart.fill",
                      title: Text(SupportCopy.supportSwiftly.localized),
                      under: Text(SupportCopy.sayThanks.localized),
                      value: support.isSupporter ? SupportCopy.thankYou.localized : nil,
                      action: { support.open() })
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            MacAppIconPicker()
                .padding(16)
            #if DEBUG
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            ValuesRow(symbol: "eye", title: Text(verbatim: "Preview (debug)"))
            ValuesRow(symbol: "rectangle.bottomhalf.inset.filled", title: Text(verbatim: "Show the card now"),
                      action: { support.debugShowCard() })
            ValuesRow(symbol: "party.popper", title: Text(verbatim: "Show the thank-you sheet now"),
                      action: { support.debugShowThanks() })
            ValuesRow(symbol: "heart.fill", title: Text(verbatim: "Mark as supporter"),
                      action: { support.debugMarkSupporter() })
            ValuesRow(symbol: "creditcard", title: Text(verbatim: "Simulate purchases (no App Store)"),
                      value: support.simulatePurchases ? "On" : "Off",
                      action: { support.simulatePurchases.toggle() })
            ValuesRow(symbol: "icloud.slash", title: Text(verbatim: "Prices unavailable in the sheet"),
                      value: support.forcePricesUnavailable ? "On" : "Off",
                      action: { support.forcePricesUnavailable.toggle() })
            ValuesRow(symbol: "calendar", title: Text(verbatim: "Halloween season now"),
                      value: LookClock.seasonOverride ? "On" : "Off",
                      action: {
                          LookClock.seasonOverride.toggle()
                          if LookClock.seasonOverride {
                              NotificationCenter.default.post(name: .lookBatNow, object: nil)
                          }
                      })
            ValuesRow(symbol: "gift", title: Text(verbatim: "Show the gift pop-up now"),
                      action: { GiftFlow.shared.stage = .offer(.halloween) })
            ValuesRow(symbol: "sparkles", title: Text(verbatim: "Show What's New now"),
                      action: {
                          if let entry = WhatsNewEntry.bundled(for: "1.0.8") { GiftFlow.shared.stage = .whatsNew(entry) }
                      })
            ValuesRow(symbol: "arrow.counterclockwise", title: Text(verbatim: "Reset support state"),
                      action: {
                          support.debugReset()
                          SupportFlow.shared.reset()
                      })
            #endif
        }
    }
}

// MARK: - Card

/// **The quiet card at the end of the home page.** "Not now" hides it for 30 days;
/// the second "Not now" ends it for good, so the card needs no menu.
struct MacSupportCard: View {
    var body: some View {
        let support = SupportModel.shared
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if support.watchedHours >= SupportCopy.cardMinimumHours {
                        Text(String(format: SupportCopy.cardWatchedHours.localized, support.watchedHours))
                            .font(Theme.listTitle)
                            .foregroundStyle(Theme.font)
                    }
                    Text(SupportCopy.cardAsk.localized)
                        .font(Theme.body)
                        .foregroundStyle(Theme.fontQuiet)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button(SupportCopy.cardSupport.localized) { support.open() }
                    .buttonStyle(SupportButtonStyle(primary: true))
                Button(SupportCopy.notNow.localized) {
                    withAnimation(Theme.reveal) { support.snoozeCard() }
                }
                .buttonStyle(SupportButtonStyle(primary: false))
            }
            .padding(.top, 16)
        }
        .padding(18)
        .background(Theme.groupsArea,
                    in: RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
        // A form, not a bar across a wide window.
        .frame(maxWidth: Theme.formWidth + 60, alignment: .leading)
        .padding(.horizontal, Theme.edgeSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
}

// MARK: - Presenting

extension View {
    /// **The one place the support sheet hangs**, at the root: every entry point only
    /// sets `SupportModel.presented`. Also decides when to ask: a minute after launch,
    /// after the player closes, when the app returns to the front. Never with the
    /// player open, never in the same moment as the rating prompt or the Discord hint.
    func macSupportPresentation(model: AppModel) -> some View {
        modifier(MacSupportPresentation(model: model))
    }
}

private struct MacSupportPresentation: ViewModifier {
    let model: AppModel
    /// The rating prompt and the Discord hint come 1.5 s after the player closes;
    /// this keeps the sheet out of that moment.
    @State private var playerClosedAt = Date.distantPast

    func body(content: Content) -> some View {
        @Bindable var support = SupportModel.shared
        content
            .sheet(isPresented: $support.presented, onDismiss: {
                support.closed()
                SupportFlow.shared.sheetClosed()
            }) {
                // The same sheet as on iPhone, in a 480 pt window sheet.
                SupportGrowSheet(model: model)
                    .frame(width: 480, height: 660)
            }
            .task {
                try? await Task.sleep(for: .seconds(SupportPrompt.quietAfterLaunch + 1))
                ask(sheet: true)
            }
            .onChange(of: model.playerOpen) { _, open in
                guard !open else { return }
                playerClosedAt = .now
                // The card may appear behind the closing player; the sheet waits.
                ask(sheet: false)
            }
            // Not scenePhase: on the Mac it does not follow the app being frontmost.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                ask(sheet: true)
            }
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

// MARK: - App icon

/// An icon from the bundle (`nil` = the standard one).
private struct MacIconImage: View {
    let icon: SupporterIcon?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image = SupporterIcon.image(icon) {
                Image(nsImage: image).resizable()
            } else {
                Theme.area
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// **The icon picker: the Dock icon of the running app.** Supporters choose; everyone
/// else sees the same icons as a preview with the way to support right below. Back to
/// the original with "Standard", always.
struct MacAppIconPicker: View {
    @State private var failed = false

    private var support: SupportModel { .shared }
    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !support.isSupporter {
                Text(SupportCopy.storeThankYouGifts.localized)
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                tile(nil)
                ForEach(SupporterIcon.allCases) { tile($0) }
            }
            if failed {
                Text("Das Icon ließ sich nicht wechseln.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontQuiet)
                    .padding(.top, 16)
            }
            if !support.isSupporter {
                Button {
                    support.open()
                } label: {
                    Label(SupportCopy.supportSwiftly.localized, systemImage: "heart.fill")
                }
                .buttonStyle(SupportButtonStyle(primary: true))
                .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                MacIconImage(icon: icon, size: 64, corner: 14)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2)
                            .padding(-4)
                    }
                Text(icon?.name ?? String(localized: "Standard"))
                    .font(Theme.small)
                    .foregroundStyle(selected ? Theme.font : Theme.fontQuiet)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        // A preview for everyone else: visible, not selectable; only the way back is open.
        .disabled(!support.canChoose(icon))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}


/// **The bat layer on the Mac home page**: the shared `BatLayer`, fed with what the Mac
/// knows (window in front, Reduce Motion, Low Power Mode).
struct MacBatLayer: View {
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = NSApp?.isActive ?? true
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        BatLayer(playing: playing, foreground: active, reduceMotion: reduceMotion, lowPower: lowPower)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }
}
