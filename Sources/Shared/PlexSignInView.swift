import AuthenticationServices
import JellyfinKit
import SwiftUI

/// **Sign in with Plex: one button, a browser window, then the choice.**
///
/// Plex has no address to type and no password for us: the sign-in happens on Plex's
/// own page, opened inside the app (an `ASWebAuthenticationSession` held by
/// ``PlexBrowser``, so the app can close the window itself). The app only holds a code
/// and waits until plex.tv says it was confirmed. That is the one thing this page must make clear before the
/// button, so it says it in a sentence and in three steps.
///
/// After that, in this order: who is watching (Plex Home, only if there are several
/// profiles, with PIN if protected), then which server. Profile first, because in
/// Plex the profile decides which servers there are.
///
/// Draws `PlexSignInModel` and nothing else; every network step is a closure.
struct PlexSignInView: View {
    let model: PlexSignInModel

    @Environment(\.wide) private var wide
    /// The page last opened. A new code (`waiting` with another URL) opens the window
    /// again by itself; the same one only through the button.
    @State private var opened: URL?
    /// The sign-in window. The page was confirmed at plex.tv, but the window does not
    /// notice (the page never forwards, see `PlexRun`): the app closes it itself.
    @State private var browser = PlexBrowser()
    @State private var pin = ""
    @FocusState private var pinFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, Theme.edgePageWide)
                .padding(.bottom, 40)
                .frame(maxWidth: Theme.formWidth)
                .frame(maxWidth: .infinity)
                .animation(Motion.change, value: model.step)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SubpageHeader(title: title) { back() }
        }
        .safeAreaInset(edge: .bottom) { footer }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .onChange(of: model.step) { _, step in
            if case let .waiting(prompt) = step {
                if prompt.url != opened { openBrowser(prompt) }
            } else {
                // The token was seen (or the flow ended): the window has done its job.
                browser.close()
            }
            if case .pin = step { pin = ""; pinFocused = true }
        }
        .onChange(of: model.pinWrong) { _, wrong in if wrong { pin = "" } }
        .onDisappear { browser.close() }
    }

    private var title: String { model.pageTitle }

    private func back() { model.goBack() }

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
            ServerKindMark(kind: .plex, size: 44)
                .padding(.top, 8)
            Text("Die Anmeldung läuft auf der Seite von Plex. Dein Passwort bekommt Swiftly Player nie zu sehen.")
                .growing(15)
                .lineSpacing(3)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)
            guide
        }
    }

    /// The three steps, built like the guide on the Quick Connect page.
    private var guide: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Text("So gehts")
                .growing(15, .semibold)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            step(1, "Die Seite von Plex geht hier in der App auf")
            step(2, "Dort anmelden, dann schließt sie sich von selbst")
            step(3, "Server aussuchen, fertig")
        }
        .padding(.top, 34)
    }

    private func step(_ figure: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(figure)")
                .growing(12)
                .monospacedDigit()
                .foregroundStyle(Theme.fontVeryQuiet)
                .frame(width: 20, alignment: .leading)
                .accessibilityHidden(true)
            Text(text)
                .growing(15)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    private func waiting(_ prompt: PlexPinPrompt) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ServerKindMark(kind: .plex, size: 44)
                .breathing(true)
                .padding(.top, 8)
            Text("Melde dich auf der Seite von Plex an. Danach gehts hier von selbst weiter.")
                .growing(15)
                .lineSpacing(3)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)

            if let code = prompt.code {
                // The way without the window: on a computer at plex.tv/link. The TV will
                // only have this way, so the code is part of the model, not of iOS.
                Text("Kein Fenster zu sehen? Auf plex.tv/link geht es auch, mit diesem Code.")
                    .growing(12)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 34)
                CodeBoxes(characters: Array(code))
                    .padding(.top, 12)
                    .copyable(code)
            }

            HStack(spacing: 9) {
                Circle().fill(Theme.accent).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Group {
                    if let left = prompt.secondsLeft {
                        Text("Warte auf Plex · noch \(left / 60):\(String(format: "%02d", left % 60))")
                    } else {
                        Text("Warte auf Plex")
                    }
                }
                .growing(12)
                .monospacedDigit()
                .foregroundStyle(Theme.fontQuiet)
            }
            .padding(.top, 24)
        }
    }

    @ViewBuilder
    private func placeholder(_ shape: PlexSignInModel.Placeholder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch shape {
            case .profiles:
                heading("Wer schaut?")
                HStack(spacing: 24) {
                    ForEach(0 ..< 3, id: \.self) { _ in
                        VStack(spacing: 8) {
                            LoadField(corner: 30).frame(width: 60, height: 60)
                            LoadField(corner: 3).frame(width: 48, height: 10)
                        }
                    }
                }
                .padding(.leading, 12)
            case .servers:
                heading("Deine Server")
                VStack(spacing: 10) {
                    ForEach(0 ..< 2, id: \.self) { _ in
                        LoadField(corner: Theme.cornerCard).frame(height: 64)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Lädt"))
    }

    private func profileChoice(_ profiles: [PlexProfileChoice]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Wer schaut?")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12, alignment: .top)],
                      alignment: .leading, spacing: 18) {
                ForEach(profiles) { profile in
                    Button { model.actions.pickProfile(profile) } label: {
                        AccountCharacter(name: profile.name, image: profile.image, selected: false)
                            .overlay(alignment: .topTrailing) {
                                if profile.protected { lockMark }
                            }
                            .accessibilityValue(profile.protected ? Text("Mit PIN") : Text(verbatim: ""))
                    }
                    .buttonStyle(Theme.PressButton())
                }
            }
            Footer("Jedes Profil hat seinen eigenen Fortschritt.")
                .padding(.top, 22)
        }
        .onAppear { model.lastProfiles = profiles }
    }

    /// On the portrait's upper right edge, as a mark on a picture: a small field, not a
    /// circle (round is only what is a picture).
    private var lockMark: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.fontQuiet)
            .frame(width: 22, height: 22)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .padding(.trailing, 6)
            .accessibilityHidden(true)
    }

    private func pinEntry(_ profile: PlexProfileChoice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ProfileCharacter(name: profile.name, image: profile.image, size: 44, selected: false)
                Text(verbatim: profile.name)
                    .growing(17, .semibold)
                    .foregroundStyle(Theme.font)
                    .lineLimit(2)
            }
            .padding(.top, 8)
            Text("Dieses Profil hat eine PIN. Gib sie hier ein.")
                .growing(15)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)

            // Four boxes; the field behind them takes the digits. Shown as dots: someone
            // on the sofa next to you need not read the PIN.
            CodeBoxes(characters: (0 ..< 4).map { $0 < pin.count ? "•" : " " },
                      active: pinFocused ? pin.count : nil)
                .padding(.top, 18)
                .overlay {
                    TextField("", text: $pin)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .textContentType(.password)
                        .focused($pinFocused)
                        .opacity(0.011)
                        .accessibilityLabel(Text("PIN"))
                        .disabled(model.pinChecking)
                }
                .contentShape(Rectangle())
                .onTapGesture { pinFocused = true }
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
            .growing(12)
            .padding(.top, 14)
        }
        .onAppear { pinFocused = true }
    }

    private func serverList(_ servers: [PlexServerChoice]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Deine Server")
            CardView {
                ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { SeparatorLine().padding(.leading, 34) }
                    serverRow(server)
                }
            }
            // `CardView` brings the page margin; this column already has its own.
            .padding(.horizontal, -Theme.margin(wide: wide))
            if let profile = model.profile {
                Footer(Text("Als \(profile.name)"))
                    .padding(.top, 12)
                    .padding(.leading, 2)
            }
        }
    }

    private func serverRow(_ server: PlexServerChoice) -> some View {
        let busy = model.connecting == server.id
        let failed = model.unreachable.contains(server.id)
        return Button { model.actions.pickServer(server) } label: {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.fontQuiet)
                    .frame(width: 20)
                    .breathing(busy)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: server.name)
                        .growing(15, .semibold)
                        .foregroundStyle(Theme.font)
                        .lineLimit(2)
                    serverLine(server, busy: busy, failed: failed)
                        .growing(12)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // Running now: a spinner where the arrow stands, so the tap visibly did something.
                if busy {
                    ProgressView().controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(Theme.PressRow())
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
                Text(verbatim: "\(owner) · \(place)").foregroundStyle(Theme.fontVeryQuiet)
            }
        }
    }

    private var noServer: some View {
        EmptyState(symbol: "externaldrive.badge.questionmark",
                   headerLine: "Kein Server auf diesem Konto",
                   text: "Richte Plex Media Server ein oder lass dir einen freigeben. Danach hier noch mal suchen.",
                   primaryButton: (title: "Noch mal suchen", perform: model.actions.reloadServers),
                   quietButton: (title: "Anderes Plex-Konto", perform: model.actions.otherAccount))
            .padding(.top, 48)
    }

    @ViewBuilder
    private func failure(_ problem: PlexSignInProblem) -> some View {
        Group {
            switch problem {
            case .plexUnreachable:
                EmptyState(symbol: "wifi.exclamationmark",
                           headerLine: "plex.tv antwortet nicht",
                           text: "Ohne plex.tv klappt die Anmeldung nicht. Hängt vielleicht das WLAN?",
                           primaryButton: (title: "Erneut versuchen", perform: model.actions.start))
            case .expired:
                EmptyState(symbol: "clock.badge.xmark",
                           headerLine: "Die Anmeldung ist abgelaufen",
                           text: "Der Code war zu lange offen. Hol dir einfach einen neuen.",
                           primaryButton: (title: "Neuen Code holen", perform: model.actions.start))
            case let .other(message):
                EmptyState(symbol: "exclamationmark.triangle",
                           headerLine: "Anmeldung hat nicht geklappt",
                           text: LocalizedStringKey(message),
                           primaryButton: (title: "Erneut versuchen", perform: model.actions.start))
            }
        }
        .padding(.top, 48)
    }

    /// A group heading aligned with the column, not indented by `GroupsTitle`'s own
    /// row margin: the same correction `SettingGroup` makes.
    private func heading(_ text: LocalizedStringKey) -> some View {
        GroupsTitle(text: text)
            .padding(.horizontal, -Theme.edgeSpacing)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Bottom

    @ViewBuilder
    private var footer: some View {
        Group {
            switch model.step {
            case .start, .opening:
                let opening = model.step == .opening
                Button(opening ? "Wird geöffnet…" : "Mit Plex anmelden") { model.actions.start() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(opening)
            case let .waiting(prompt):
                Button("Seite noch mal öffnen") { openBrowser(prompt) }
                    .buttonStyle(SecondaryButtonStyle())
            case .servers(let servers) where !servers.isEmpty:
                Button("Anderes Plex-Konto", action: model.actions.otherAccount)
                    .buttonStyle(Theme.PressRow())
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .frame(minHeight: 44)
                    .disabled(model.connecting != nil)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, Theme.edgePageWide)
        .frame(maxWidth: Theme.formWidth)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }

    private func openBrowser(_ prompt: PlexPinPrompt) {
        opened = prompt.url
        // `.shared`: whoever is already signed in at plex.tv in Safari only confirms.
        // The system asks once whether the app may use plex.tv; that question is
        // Apple's, and it is the honest one.
        browser.open(prompt.url, callbackScheme: prompt.callbackScheme) { _ in
            // Closed by hand, or the window could not open. Either way the code is still
            // valid and the page stays: the button opens it again. Look once right now.
            model.actions.browserClosed(false)
        }
    }
}

// MARK: - Previews

@MainActor
private func plexPreview(_ step: PlexSignInModel.Step, _ setup: (PlexSignInModel) -> Void = { _ in }) -> some View {
    let model = PlexSignInModel(step: step)
    model.account = "kinoabend"
    setup(model)
    return NavigationStack { PlexSignInView(model: model) }
}

private let previewPrompt = PlexPinPrompt(url: URL(string: "https://app.plex.tv/auth")!,
                                          code: "7KQ2", secondsLeft: 274)

#Preview("Start") { plexPreview(.start) }
#Preview("Wird geöffnet") { plexPreview(.opening) }
#Preview("Warten") { plexPreview(.waiting(previewPrompt)) }
#Preview("Lädt Server") { plexPreview(.loading(.servers)) }
#Preview("Profile") {
    plexPreview(.profiles([
        PlexProfileChoice(id: "1", name: "Paula", protected: true),
        PlexProfileChoice(id: "2", name: "Kinder", protected: false),
        PlexProfileChoice(id: "3", name: "Großeltern im Gästezimmer", protected: false),
    ]))
}
#Preview("PIN falsch") {
    plexPreview(.pin(PlexProfileChoice(id: "1", name: "Paula", protected: true))) { $0.pinWrong = true }
}
#Preview("Server") {
    plexPreview(.servers([
        PlexServerChoice(id: "a", name: "Wohnzimmer-NAS", local: true),
        PlexServerChoice(id: "b", name: "Server von Jonas mit einem sehr langen Namen, der umbricht",
                         sharedBy: "Jonas", local: false),
        PlexServerChoice(id: "c", name: "Altes Notebook", local: false, online: false),
    ])) {
        $0.unreachable = ["c"]
        $0.connecting = "a"
    }
}
#Preview("Kein Server") { plexPreview(.servers([])) }
#Preview("plex.tv weg") { plexPreview(.failed(.plexUnreachable)) }
#Preview("Abgelaufen") { plexPreview(.failed(.expired)) }
