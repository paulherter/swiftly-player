import JellyfinKit
import SwiftUI

// MARK: - Rule

/// **When the profile picker opens, and how large it draws.**
///
/// Pure functions, no view: the decision is made once when the process starts
/// (`RootView.init`) and never again, so a return from the background, a switch
/// or a sign-in cannot bring it up.
enum ProfilePickerRule {
    /// The one setting. The picker's switch and the row in Profile › Konto read the
    /// same key; unset means on.
    static let key = "askProfileAtLaunch"

    #if DEBUG
    /// `-SwiftlyProfilauswahl`: open at launch even when switched off. Not compiled
    /// into release builds.
    static var forced: Bool { ProcessInfo.processInfo.arguments.contains("-SwiftlyProfilauswahl") }
    #endif

    /// Asks with a single account too: signing in silently must not be the default.
    static let minimum = 1

    static func opensAtLaunch(ready: Bool, accounts: Int) -> Bool {
        guard ready, accounts >= minimum else { return false }
        #if DEBUG
        if forced { return true }
        #endif
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// 2 to 5 profiles: 280 and a gap of 80 (5 x 280 + 4 x 80 = 1720 fits the 1760 usable).
    /// From 6: 220 and 64, six still fit without scrolling.
    static func size(count: Int) -> CGFloat { count <= 5 ? 280 : 220 }
    static func gap(count: Int) -> CGFloat { count <= 5 ? 80 : 64 }
}

/// A choice made in the picker must not move focus to the header's profile circle
/// afterwards (you came to watch, not to change settings). `MainView` reads and clears
/// this when the switch's `back` counter increments.
@MainActor
enum ProfilePickerHandoff {
    static var running = false
    static func consume() -> Bool {
        defer { running = false }
        return running
    }
}

// MARK: - Server names

/// `Session` has no server name. Whatever `/System/Info/Public` returned is cached per
/// server address, so the picker can name a profile's server without asking the network.
enum ServerNameCache {
    private static let key = "serverNamenCache"

    private static func id(_ url: URL) -> String { url.absoluteString.lowercased() }

    static func store(_ name: String, for url: URL) {
        let host = url.host() ?? url.absoluteString
        // The host is what `AppModel` shows until the real name arrives: not worth keeping.
        guard !name.isEmpty, name != host else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        guard all[id(url)] != name else { return }
        all[id(url)] = name
        UserDefaults.standard.set(all, forKey: key)
    }

    static func name(for url: URL) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id(url)]
    }
}

extension AppModel {
    /// The cached server name, else the host.
    func profileServerName(for session: Session) -> String {
        ServerNameCache.name(for: session.serverURL)
            ?? session.serverURL.host() ?? session.serverURL.absoluteString
    }
}

// MARK: - Picker

/// **"Wer schaut?"** at cold start. Sits above the blurred home page of the last
/// profile (`RootView`); a press starts the ordinary account switch.
struct ProfilePicker: View {
    let model: AppModel
    /// The launch curtain is gone: the entrance may begin.
    let entered: Bool
    /// The chosen account is no longer there.
    let vanished: () -> Void

    private enum Spot: Hashable {
        case profile(String)
        case askSwitch
    }

    @FocusState private var focus: Spot?
    @State private var lastAvatar: String
    @State private var shown = false
    @State private var circles = CircleStore()
    @AppStorage(ProfilePickerRule.key) private var asks = true

    private final class CircleStore {
        var frameRect: [String: CGRect] = [:]
    }

    init(model: AppModel, entered: Bool, vanished: @escaping () -> Void) {
        self.model = model
        self.entered = entered
        self.vanished = vanished
        _lastAvatar = State(initialValue: model.session?.accountKey ?? model.accounts.first?.accountKey ?? "")
    }

    private var waits: Bool { AccountSwitchTransition.shared.waits }

    private var size: CGFloat { ProfilePickerRule.size(count: model.accounts.count) }
    private var gap: CGFloat { ProfilePickerRule.gap(count: model.accounts.count) }

    /// Title, then the avatars left to right, then the switch row.
    private func entrance(_ index: Int) -> some ViewModifier {
        Entrance(shown: shown, index: index)
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .center, spacing: 64) {
                Text("Wer schaut?")
                    .font(Theme.titleLarge)
                    .tracking(Theme.lockTitle)
                    .foregroundStyle(Theme.font)
                    .accessibilityAddTraits(.isHeader)
                    .modifier(entrance(0))
                // Full width: the switch sits bottom-left, and with the avatars centered
                // nothing lay above it, so "up" from the switch found no target.
                profiles
                    .frame(maxWidth: .infinity)
                    .focusSection()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.edgePage)
            .padding(.top, Theme.contentTop)

            VStack {
                Spacer(minLength: 0)
                askLine
            }
            .padding(.leading, Theme.edgePage)
            .padding(.bottom, Theme.edgeTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .onAppear {
            focus = .profile(lastAvatar)
            if entered { shown = true }
        }
        .onChange(of: entered) { _, now in if now { shown = true } }
        .onChange(of: focus) { old, new in
            guard case let .profile(key)? = new else { return }
            // Coming up from the switch: back to the avatar we left, not to whichever lies
            // geometrically above.
            if old == .askSwitch, key != lastAvatar {
                focus = .profile(lastAvatar)
                return
            }
            lastAvatar = key
        }
    }

    // MARK: Avatars

    @ViewBuilder private var profiles: some View {
        if model.accounts.count > 5 {
            ScrollView(.horizontal, showsIndicators: false) {
                row.padding(.horizontal, Theme.edgePage)
            }
            .padding(.leading, -Theme.edgePage)
            .scrollClipDisabled()
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(model.accounts.enumerated()), id: \.element.accountKey) { index, account in
                column(account, index: index)
            }
        }
        .defaultFocus($focus, .profile(lastAvatar))
    }

    private func column(_ account: Session, index: Int) -> some View {
        let key = account.accountKey
        let focused = focus == .profile(key)
        let enabled = !waits
        let address = model.userImageURL(for: account)
        return VStack(spacing: 36) {
            Button {
                choose(account)
            } label: {
                ProfileCharacter(name: account.userName, image: address, size: size)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        circles.frameRect[key] = $0
                    }
            }
            .buttonStyle(ProfilePickerStyle())
            .focused($focus, equals: .profile(key))
            .disabled(!enabled)
            .accessibilityLabel(Text("\(account.userName), \(model.profileServerName(for: account))"))
            .accessibilityHint(Text("Mit diesem Profil weiter"))

            VStack(spacing: 6) {
                Text(account.userName)
                    .font(.system(size: 30, weight: focused ? .semibold : .medium))
                    .foregroundStyle(!enabled ? Theme.fontVeryQuiet : (focused ? Theme.font : Theme.fontQuiet))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: size + 40, height: 40)
                // Space is always reserved, only the opacity changes, so nothing jumps.
                Text(model.profileServerName(for: account))
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontQuiet)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size + 40, height: 30)
                    .opacity(focused && enabled ? 1 : 0)
                    .offset(y: focused && enabled ? 0 : 4)
                    .animation(focused ? Theme.reveal : Theme.focusAnimation, value: focused)
            }
            .animation(Theme.focusAnimation, value: focused)
            .accessibilityHidden(true)
        }
        .frame(width: size)
        .modifier(entrance(index + 1))
    }

    // MARK: Switch row

    private var askLine: some View {
        HStack(spacing: 32) {
            Button {
                asks.toggle()
            } label: {
                HStack(spacing: 24) {
                    Text("Immer fragen")
                    ToggleSwitch(an: asks)
                }
            }
            .buttonStyle(RowsStyle(quiet: true, compact: true))
            .focused($focus, equals: .askSwitch)
            .disabled(waits)
            .accessibilityRepresentation {
                Toggle(isOn: .constant(asks)) { Text("Immer fragen") }
            }

            Text("Dann gehts direkt ins letzte Profil. Wieder an unter Profil › Konto.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
                .opacity(asks ? 0 : 1)
                .offset(y: asks ? 4 : 0)
                .animation(asks ? Theme.focusAnimation : Theme.reveal, value: asks)
                .accessibilityHidden(asks)
        }
        .focusSection()
        .modifier(entrance(model.accounts.count + 1))
    }

    // MARK: Choose

    /// The existing account switch, started from here: the picture flies to the header
    /// circle, a still image of picker and blurred page fades out, `RootView` closes the
    /// picker under it (`AccountSwitchTransition.back`).
    private func choose(_ account: Session) {
        guard !waits else { return }
        let key = account.accountKey
        guard model.accounts.contains(where: { $0.accountKey == key }) else {
            vanished()
            return
        }
        let from = circles.frameRect[key] ?? .zero
        let address = model.userImageURL(for: account)
        let withoutImage = address.map { ImageCache.shared.image($0) == nil } ?? true
        let current = model.session?.accountKey
        ProfilePickerHandoff.running = true
        AccountSwitchTransition.shared.start(
            account: key,
            // The frame is unscaled; focus scales by 1.06 here, not 1.10 as in the strip.
            image: ProfileCharacter(name: account.userName, image: address,
                                    size: max(from.width, 1) * Theme.focusMagnifier,
                                    withoutImage: withoutImage),
            from: from, area: Theme.reason, address: address) {
            // The last profile again: nothing to switch.
            guard key != current else { return }
            model.switchAccount(toward: key)
        }
    }
}

/// Opacity 0 to 1 and scale 0.97 to 1 (as `EmptyState`), one item after the other.
private struct Entrance: ViewModifier {
    let shown: Bool
    let index: Int

    func body(content: Content) -> some View {
        let calm = Theme.motionReduced
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || calm ? 1 : 0.97)
            .animation(calm ? Theme.fadeReduced
                       : Motion.change.delay(Double(index) * AccountSwitchCurve.railsSeason),
                       value: shown)
    }
}

// MARK: - Settings row

/// The way back from "off": the same setting as the picker's switch, in Profile › Konto.
struct AskAtLaunchRow: View {
    @AppStorage(ProfilePickerRule.key) private var asks = true

    var body: some View {
        ToggleRow(title: "Beim Start fragen, wer schaut", an: asks) { asks.toggle() }
    }
}
