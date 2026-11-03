import JellyfinKit
import SwiftUI

/// **Sign in with Plex on the Mac: one button, a browser window, then the choice.**
///
/// The Mac's counterpart of `PlexSignInView`, drawn from the same `PlexSignInModel` with
/// the same words and the same order: the page of plex.tv in a sheet of the window
/// (`PlexBrowser`, the `ASWebAuthenticationSession` that the app can close itself), the
/// code for plex.tv/link beside it, then who is watching (only with several profiles,
/// with PIN if protected), then which server.
///
/// What differs is the input. Return on the first page opens the window, the profiles and
/// servers can be walked with Tab and chosen with Return, the PIN is typed straight in,
/// Escape goes one step back (`MacFlowPage`), and everything that can be chosen lights up
/// under the pointer and in focus (`choiceSurface`). The buttons stand in the column
/// instead of at the bottom edge: a window has room, and the pointer is already there.
struct MacPlexSignIn: View {
    let model: PlexSignInModel
    var centered = false

    /// The page last opened. A new code (`waiting` with another URL) opens the window
    /// again by itself; the same one only through the button.
    @State private var opened: URL?
    /// The sign-in window. The page was confirmed at plex.tv, but the window does not
    /// notice (the page never forwards): the app closes it itself.
    @State private var browser = PlexBrowser()
    @State private var pin = ""
    @FocusState private var pinFocused: Bool

    var body: some View {
        MacFlowPage(title: model.pageTitle, back: { model.goBack() }, centered: centered) {
            content
        }
        .animation(Theme.reveal, value: model.step)
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

    // MARK: Steps

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
        let opening = model.step == .opening
        return VStack(alignment: .leading, spacing: 0) {
            ServerKindMark(kind: .plex, size: 44)
                .padding(.top, 22)
            Text("Die Anmeldung läuft auf der Seite von Plex. Dein Passwort bekommt Swiftly Player nie zu sehen.")
                .font(Theme.body)
                .lineSpacing(3)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)

            PrimaryButton(label: opening ? "Wird geöffnet…" : "Mit Plex anmelden",
                          symbol: "arrow.right") { model.actions.start() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 24)
                .disabled(opening)

            guide
        }
    }

    /// The three steps, built like the guide on the Quick Connect page.
    private var guide: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Text("So gehts")
                .font(Theme.listTitle)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            step(1, "Die Seite von Plex geht hier in der App auf")
            step(2, "Dort anmelden, dann schließt sie sich von selbst")
            step(3, "Server aussuchen, fertig")
        }
        .padding(.top, 30)
    }

    private func step(_ figure: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(figure)")
                .font(Theme.small)
                .monospacedDigit()
                .foregroundStyle(Theme.fontVeryQuiet)
                .frame(width: 20, alignment: .leading)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    private func waiting(_ prompt: PlexPinPrompt) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ServerKindMark(kind: .plex, size: 44)
                .breathing(true)
                .padding(.top, 22)
            Text("Melde dich auf der Seite von Plex an. Danach gehts hier von selbst weiter.")
                .font(Theme.body)
                .lineSpacing(3)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)

            if let code = prompt.code {
                // The way without the window: on a computer at plex.tv/link.
                Text("Kein Fenster zu sehen? Auf plex.tv/link geht es auch, mit diesem Code.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 30)
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
                .font(Theme.small)
                .monospacedDigit()
                .foregroundStyle(Theme.fontQuiet)
            }
            .padding(.top, 22)

            OutlineButton(label: "Seite noch mal öffnen", symbol: "arrow.up.forward.app") {
                openBrowser(prompt)
            }
            .keyboardShortcut(.defaultAction)
            .padding(.top, 22)
        }
    }

    @ViewBuilder
    private func placeholder(_ shape: PlexSignInModel.Placeholder) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch shape {
            case .profiles:
                GroupsTitle(text: "Wer schaut?")
                HStack(spacing: 24) {
                    ForEach(0 ..< 3, id: \.self) { _ in
                        VStack(spacing: 8) {
                            LoadField(corner: 30).frame(width: 60, height: 60)
                            LoadField(corner: 3).frame(width: 48, height: 10)
                        }
                    }
                }
            case .servers:
                GroupsTitle(text: "Deine Server")
                VStack(spacing: 10) {
                    ForEach(0 ..< 2, id: \.self) { _ in
                        LoadField(corner: Theme.cornerCard).frame(height: 64)
                    }
                }
            }
        }
        .padding(.top, 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Lädt"))
    }

    private func profileChoice(_ profiles: [PlexProfileChoice]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupsTitle(text: "Wer schaut?")
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8, alignment: .top)],
                      alignment: .leading, spacing: 8) {
                ForEach(profiles) { profile in
                    let pick = { model.actions.pickProfile(profile) }
                    Button(action: pick) {
                        AccountCharacter(name: profile.name, image: profile.image, selected: false)
                            .overlay(alignment: .topTrailing) {
                                if profile.protected { lockMark }
                            }
                            .accessibilityValue(profile.protected ? Text("Mit PIN") : Text(verbatim: ""))
                            .padding(6)
                    }
                    .buttonStyle(Theme.PressButton())
                    .choiceSurface(corner: Theme.cornerCard, activate: pick)
                }
            }
            Text("Jedes Profil hat seinen eigenen Fortschritt.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .padding(.top, 10)
        }
        .padding(.top, 22)
        .onAppear { model.lastProfiles = profiles }
    }

    /// On the portrait's upper right edge, as a mark on a picture: a small field, not a
    /// circle (round is only what is a picture).
    private var lockMark: some View {
        Image(icon: "lock.fill")
            .font(.app(size: 10, weight: .semibold))
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
                    .font(Theme.listTitle)
                    .foregroundStyle(Theme.font)
                    .lineLimit(2)
            }
            .padding(.top, 22)
            Text("Dieses Profil hat eine PIN. Gib sie hier ein.")
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)

            // Four boxes; the field behind them takes the digits. Shown as dots: someone
            // next to you need not read the PIN.
            CodeBoxes(characters: (0 ..< 4).map { $0 < pin.count ? "•" : " " },
                      active: pinFocused ? pin.count : nil)
                .padding(.top, 16)
                .overlay {
                    TextField("", text: $pin)
                        .textFieldStyle(.plain)
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
            .font(Theme.small)
            .padding(.top, 14)
        }
        .onAppear { pinFocused = true }
    }

    private func serverList(_ servers: [PlexServerChoice]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupsTitle(text: "Deine Server")
                .accessibilityAddTraits(.isHeader)
            CardView {
                ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { SeparatorLine().padding(.leading, 48) }
                    serverRow(server)
                }
            }
            if let profile = model.profile {
                Text("Als \(profile.name)")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .padding(.leading, 2)
            }
            Button("Anderes Plex-Konto", action: model.actions.otherAccount)
                .buttonStyle(Theme.PressButton())
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .frame(minHeight: 32)
                .disabled(model.connecting != nil)
                .padding(.top, 6)
        }
        .padding(.top, 22)
    }

    private func serverRow(_ server: PlexServerChoice) -> some View {
        let busy = model.connecting == server.id
        let failed = model.unreachable.contains(server.id)
        let pick = { model.actions.pickServer(server) }
        let waiting = model.connecting != nil && !busy
        return Button(action: pick) {
            HStack(spacing: 14) {
                Image(icon: "externaldrive")
                    .font(.app(size: 17))
                    .foregroundStyle(Theme.fontQuiet)
                    .frame(width: 20)
                    .breathing(busy)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: server.name)
                        .font(Theme.listTitle)
                        .foregroundStyle(Theme.font)
                        .lineLimit(2)
                    serverLine(server, busy: busy, failed: failed)
                        .font(Theme.small)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // Running now: a spinner where the arrow stands, so the click visibly did something.
                if busy {
                    ProgressView().controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(icon: "chevron.right")
                        .font(.app(size: 13, weight: .semibold))
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
        .buttonStyle(Theme.PressButton())
        .choiceSurface(corner: Theme.cornerCard, activate: pick)
        .disabled(waiting)
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
            .frame(minHeight: 320)
            .padding(.top, 30)
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
        .frame(minHeight: 320)
        .padding(.top, 30)
    }

    private func openBrowser(_ prompt: PlexPinPrompt) {
        opened = prompt.url
        // `.shared`: whoever is already signed in at plex.tv in Safari only confirms.
        browser.open(prompt.url, callbackScheme: prompt.callbackScheme) { _ in
            // Closed by hand, or the window could not open. Either way the code is still
            // valid and the page stays: the button opens it again. Look once right now.
            model.actions.browserClosed(false)
        }
    }
}
