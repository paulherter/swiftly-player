import JellyfinKit
import SwiftUI

/// **Sign in with Plex on the TV: a code instead of a browser.**
///
/// The iPhone opens Plex's page in a window (`PlexSignInView`); the TV has no browser, so
/// the page holds the code in large fields and says where to type it (plex.tv/link), with a
/// QR code of the same page for the phone in hand, and the time left. The app polls
/// plex.tv until the code is confirmed, then goes on as the iPhone does: who is watching
/// (Plex Home, with a PIN on the remote's keyboard where protected), then which server.
///
/// Draws `PlexSignInModel` and nothing else; every network step is a closure. The Menu
/// button is one step back (`model.goBack()`), the arrow the iPhone shows at the top.
struct TVPlexSignInView: View {
    let model: PlexSignInModel

    /// Where the code is typed; the same page the QR code opens.
    private static let linkAddress = "plex.tv/link"

    @State private var pin = ""
    @FocusState private var pinFocused: Bool

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: TVSpec.pickerCardGap) {
                    ServerKindMark(kind: .plex, size: TVSpec.pickerCardMark)
                    Text(verbatim: model.pageTitle)
                        .font(Theme.titleLarge)
                        .foregroundStyle(Theme.font)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                content
            }
            .frame(width: TVSpec.messageWidth, alignment: .leading)
            .animation(Theme.reveal, value: model.step)
        }
        .onExitCommand(perform: model.goBack)
        .onChange(of: model.step) { _, step in
            if case .pin = step { pin = ""; pinFocused = true }
        }
        .onChange(of: model.pinWrong) { _, wrong in if wrong { pin = "" } }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .start, .opening:
            intro
        case let .waiting(prompt):
            waiting(prompt)
        case let .loading(shape):
            placeholder(shape)
        case let .profiles(profiles):
            profileChoice(profiles)
        case let .pin(profile):
            pinEntry(profile)
        case let .servers(servers):
            if servers.isEmpty { noServer } else { serverList(servers) }
        case let .failed(problem):
            failure(problem)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Die Anmeldung läuft auf der Seite von Plex. Dein Passwort bekommt Swiftly Player nie zu sehen.")
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.top, TVSpec.onboardingSubtitleTop)
            Text("Gleich bekommst du einen Code. Den gibst du am Handy oder Computer auf plex.tv/link ein.")
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.top, TVSpec.onboardingSubtitleTop)

            HStack(spacing: TVSpec.onboardingButtonSpacing) {
                let opening = model.step == .opening
                Button(opening ? "Wird geöffnet…" : "Mit Plex anmelden") { model.actions.start() }
                    .buttonStyle(ThemedButtonStyle())
                    .disabled(opening)
                Button("Zurück", action: model.goBack)
                    .buttonStyle(ThemedButtonStyle())
            }
            .padding(.top, TVSpec.onboardingBlockTop)
        }
    }

    private func waiting(_ prompt: PlexPinPrompt) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: TVSpec.plexWaitingGap) {
                if let image = CodeSheet.code(prompt.url) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: TVSpec.plexQrSize, height: TVSpec.plexQrSize)
                        // The white border belongs to the code; see `CodeSheet`.
                        .padding(TVSpec.plexQrInset)
                        .background(Color.white,
                                    in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: TVSpec.onboardingHintSpacing) {
                    Text("Geh auf \(Self.linkAddress) und gib diesen Code ein.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.font)
                    if let code = prompt.code {
                        CodeFields(code: code)
                    }
                    Group {
                        if let left = prompt.secondsLeft {
                            Text("Warte auf Plex · noch \(left / 60):\(String(format: "%02d", left % 60))")
                        } else {
                            Text("Warte auf Plex")
                        }
                    }
                    .font(Theme.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.fontVeryQuiet)
                }
            }
            .padding(.top, TVSpec.onboardingBlockTop)

            HStack(spacing: TVSpec.onboardingButtonSpacing) {
                Button("Neuen Code holen") { model.actions.start() }
                    .buttonStyle(ThemedButtonStyle())
                Button("Zurück", action: model.goBack)
                    .buttonStyle(ThemedButtonStyle())
            }
            .padding(.top, TVSpec.plexActionsTop)
        }
    }

    @ViewBuilder
    private func placeholder(_ shape: PlexSignInModel.Placeholder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch shape {
            case .profiles:
                heading("Wer schaut?")
                HStack(spacing: TVSpec.signInAccountSpacing) {
                    ForEach(0 ..< 3, id: \.self) { _ in
                        LoadField(corner: TVSpec.signInAccountSize / 2)
                            .frame(width: TVSpec.signInAccountSize, height: TVSpec.signInAccountSize)
                    }
                }
            case .servers:
                heading("Deine Server")
                VStack(spacing: TVSpec.plexServerSpacing) {
                    ForEach(0 ..< 2, id: \.self) { _ in
                        LoadField(corner: Theme.corner).frame(height: Theme.rowsHeight)
                    }
                }
            }
        }
        .padding(.top, TVSpec.onboardingBlockTop)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Lädt"))
    }

    // MARK: - Profiles

    private func profileChoice(_ profiles: [PlexProfileChoice]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Wer schaut?")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: TVSpec.signInAccountSpacing) {
                    ForEach(profiles) { profile in
                        VStack(spacing: TVSpec.signInAccountNameTop) {
                            Button { model.actions.pickProfile(profile) } label: {
                                ProfileCharacter(name: profile.name, image: profile.image,
                                                 size: TVSpec.signInAccountSize)
                                    .overlay(alignment: .topTrailing) {
                                        if profile.protected { lockMark }
                                    }
                            }
                            .buttonStyle(ProfilePickerStyle())
                            .accessibilityValue(profile.protected ? Text("Mit PIN") : Text(verbatim: ""))
                            Text(verbatim: profile.name)
                                .font(Theme.small)
                                .foregroundStyle(Theme.fontQuiet)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: TVSpec.signInAccountSize + TVSpec.signInAccountSpacing)
                        }
                    }
                }
                .padding(.horizontal, TVSpec.pickerRingGap + TVSpec.pickerRingWidth)
                .padding(.vertical, TVSpec.pickerRingGap + TVSpec.pickerRingWidth)
            }
            .scrollClipDisabled()
            .focusSection()

            Text("Jedes Profil hat seinen eigenen Fortschritt.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .padding(.top, TVSpec.signInAccountsTop)
        }
        .padding(.top, TVSpec.onboardingBlockTop)
        .onAppear { model.lastProfiles = profiles }
    }

    /// On the portrait's upper right edge, as a mark on a picture: a small field, not a
    /// circle (round is only what is a picture).
    private var lockMark: some View {
        Image(icon: "lock.fill")
            .font(.app(size: TVSpec.plexLockIcon, weight: .semibold))
            .foregroundStyle(Theme.fontQuiet)
            .frame(width: TVSpec.plexLockBadge, height: TVSpec.plexLockBadge)
            .background(Theme.raised,
                        in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .accessibilityHidden(true)
    }

    // MARK: - PIN

    private func pinEntry(_ profile: PlexProfileChoice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: TVSpec.pickerCardGap) {
                ProfileCharacter(name: profile.name, image: profile.image, size: TVSpec.plexPinAvatar)
                Text(verbatim: profile.name)
                    .font(Theme.rail)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
            }
            Text("Dieses Profil hat eine PIN. Gib sie hier ein.")
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.top, TVSpec.onboardingSubtitleTop)

            // Four boxes; the field behind them takes the digits from the remote's keyboard.
            // Shown as dots: someone on the sofa next to you need not read the PIN. The boxes
            // turn white while the field has focus, as `InputField`.
            HStack(spacing: TVSpec.plexPinSpacing) {
                ForEach(0 ..< 4, id: \.self) { index in
                    Text(verbatim: index < pin.count ? "\u{2022}" : "")
                        .font(Theme.titleLarge)
                        .foregroundStyle(pinFocused ? Theme.reason : Theme.font)
                        .frame(width: TVSpec.plexPinWidth, height: TVSpec.plexPinHeight)
                        .background(pinFocused ? Color.white : Theme.raised,
                                    in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                }
            }
            .overlay {
                SecureField("", text: $pin)
                    .textContentType(.password)
                    .focused($pinFocused)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .opacity(TVSpec.hiddenFieldOpacity)
                    .disabled(model.pinChecking)
                    .accessibilityLabel(Text("PIN"))
            }
            .animation(Theme.focusAnimation, value: pinFocused)
            .padding(.top, TVSpec.plexPinTop)
            .onChange(of: pin) { _, new in
                let digits = String(new.filter(\.isNumber).prefix(4))
                if digits != new { pin = digits; return }
                if !digits.isEmpty { model.pinWrong = false }
                if digits.count == 4 { model.actions.submitPin(profile, digits) }
            }

            Group {
                if model.pinChecking {
                    Text("Wird geprüft…").foregroundStyle(Theme.fontQuiet)
                } else if model.pinWrong {
                    Text("Die PIN passt nicht. Versuchs noch mal.").foregroundStyle(Theme.error)
                }
            }
            .font(Theme.small)
            .frame(height: Theme.rowsHeight, alignment: .leading)
        }
        .padding(.top, TVSpec.onboardingBlockTop)
        .onAppear { pinFocused = true }
    }

    // MARK: - Servers

    private func serverList(_ servers: [PlexServerChoice]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Deine Server")
            ScrollView {
                VStack(spacing: TVSpec.plexServerSpacing) {
                    ForEach(servers) { server in serverRow(server) }
                }
            }
            .scrollClipDisabled()
            .frame(maxHeight: TVSpec.plexServerListHeight)
            .focusSection()

            if let profile = model.profile {
                Text("Als \(profile.name)")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .padding(.top, TVSpec.onboardingCodeTop)
            }
            Button("Anderes Plex-Konto", action: model.actions.otherAccount)
                .buttonStyle(ThemedButtonStyle())
                .disabled(model.connecting != nil)
                .padding(.top, TVSpec.onboardingCodeTop)
        }
        .padding(.top, TVSpec.onboardingBlockTop)
    }

    private func serverRow(_ server: PlexServerChoice) -> some View {
        let busy = model.connecting == server.id
        let failed = model.unreachable.contains(server.id)
        return Button { model.actions.pickServer(server) } label: {
            HStack(spacing: TVSpec.plexServerGap) {
                Image(icon: "externaldrive")
                    .font(.app(size: TVSpec.valueIcon))
                    .foregroundStyle(Theme.fontQuiet)
                    .frame(width: TVSpec.plexServerIconBox)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: server.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    serverLine(server, busy: busy, failed: failed)
                        .font(Theme.small)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // Running now: a spinner where the arrow stands, so the press visibly did something.
                if busy {
                    ProgressView().accessibilityHidden(true)
                } else {
                    Image(icon: "chevron.right")
                        .font(.app(size: TVSpec.valueIcon, weight: .semibold))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(RowsStyle())
        .disabled(model.connecting != nil && !busy)
    }

    /// What the row says under the name. In order of urgency: running now, did not
    /// answer, then the plain facts (whose, where).
    private func serverLine(_ server: PlexServerChoice, busy: Bool, failed: Bool) -> some View {
        Group {
            if busy {
                Text("Verbinden…").foregroundStyle(Theme.font)
            } else if failed {
                Text("Antwortet gerade nicht. Tipp für einen neuen Versuch.")
                    .foregroundStyle(Theme.error)
            } else {
                let owner = server.sharedBy.map { String(localized: "Von \($0) freigegeben") }
                    ?? String(localized: "Dein Server")
                let place = !server.online ? String(localized: "laut Plex offline")
                    : server.local ? String(localized: "im WLAN") : String(localized: "über das Internet")
                Text(verbatim: "\(owner) · \(place)").foregroundStyle(Theme.fontQuiet)
            }
        }
    }

    private var noServer: some View {
        notice(symbol: "externaldrive.badge.questionmark",
               title: "Kein Server auf diesem Konto",
               text: "Richte Plex Media Server ein oder lass dir einen freigeben. Danach hier noch mal suchen.",
               primary: (title: "Noch mal suchen", perform: model.actions.reloadServers),
               secondary: (title: "Anderes Plex-Konto", perform: model.actions.otherAccount))
    }

    // MARK: - Problems

    @ViewBuilder
    private func failure(_ problem: PlexSignInProblem) -> some View {
        switch problem {
        case .plexUnreachable:
            notice(symbol: "wifi.exclamationmark",
                   title: "plex.tv antwortet nicht",
                   text: "Ohne plex.tv klappt die Anmeldung nicht. Hängt vielleicht das WLAN?",
                   primary: (title: "Erneut versuchen", perform: model.actions.start),
                   secondary: (title: "Zurück", perform: model.goBack))
        case .expired:
            notice(symbol: "clock.badge.xmark",
                   title: "Die Anmeldung ist abgelaufen",
                   text: "Der Code war zu lange offen. Hol dir einfach einen neuen.",
                   primary: (title: "Neuen Code holen", perform: model.actions.start),
                   secondary: (title: "Zurück", perform: model.goBack))
        case let .other(message):
            notice(symbol: "exclamationmark.triangle",
                   title: "Anmeldung hat nicht geklappt",
                   text: LocalizedStringKey(message),
                   primary: (title: "Erneut versuchen", perform: model.actions.start),
                   secondary: (title: "Zurück", perform: model.goBack))
        }
    }

    /// The empty state of the other pages, left-aligned in the column and with two ways on.
    private func notice(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey,
                        primary: (title: LocalizedStringKey, perform: () -> Void),
                        secondary: (title: LocalizedStringKey, perform: () -> Void)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(icon: symbol)
                .font(.app(size: TVSpec.plexNoticeIcon))
                .foregroundStyle(Theme.fontVeryQuiet)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.rail)
                .foregroundStyle(Theme.font)
                .padding(.top, TVSpec.onboardingSubtitleTop)
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.top, TVSpec.onboardingSubtitleTop)
            HStack(spacing: TVSpec.onboardingButtonSpacing) {
                Button(primary.title, action: primary.perform)
                    .buttonStyle(ThemedButtonStyle())
                Button(secondary.title, action: secondary.perform)
                    .buttonStyle(ThemedButtonStyle())
            }
            .padding(.top, TVSpec.onboardingBlockTop)
        }
        .padding(.top, TVSpec.onboardingBlockTop)
    }

    private func heading(_ text: LocalizedStringKey) -> some View {
        GroupsTitle(text: text)
            .padding(.leading, -TVSpec.rowInset)
            .accessibilityAddTraits(.isHeader)
    }
}
