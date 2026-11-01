import JellyfinKit
import SwiftUI

/// **Sign in with Emby: the Jellyfin way, two steps on one page.**
///
/// Emby is signed in to the way Jellyfin is: an address, then name and password, with
/// the accounts the server shows as pictures. So the page is built from the same parts
/// as `ConnectView` and `LoginView` and differs only in what it says; anyone who knows
/// the one finds their way in the other.
///
/// Without Quick Connect: Emby has no such thing. Without the "Zuletzt verbunden" row:
/// the picker is the way back to a known server.
///
/// One page instead of two pushes: the header stays, only the column changes, so the
/// arrow at the top always goes one step back, not out of the flow by surprise.
struct EmbySignInView: View {
    @Bindable var model: EmbySignInModel

    @State private var headers: [HeaderRow] = []
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch model.step {
                    case .address:
                        addressStep
                    case let .signIn(serverName, version):
                        signInStep(serverName: serverName, version: version)
                    }
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
            SubpageHeader(title: String(localized: "Mit Emby anmelden")) { back() }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        // Changing the address after an error takes the error away: it was about the old one.
        .onChange(of: model.address) { _, _ in model.problem = nil }
        .onChange(of: model.users) { _, users in
            // One account: nothing to choose, the name is filled in. As on the Jellyfin page.
            if let users, users.count == 1, user.isEmpty { user = users[0].name }
        }
    }

    private func back() {
        if case .signIn = model.step { password = "" }
        model.goBack()
    }

    // MARK: - Address

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            ServerKindMark(kind: .emby, size: 44)
                .padding(.top, 8)
            Text("Wo steht dein Emby-Server?")
                .growing(15)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.top, 20)

            InputField(text: $model.address, symbol: "globe",
                       placeholder: "emby.beispiel.de", keyboard: .address,
                       completion: check)
                .padding(.top, 14)
                .disabled(model.checking)

            Text("https:// kannst du weglassen.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .padding(.top, 9)
                .padding(.leading, 2)

            AdvancedSection(rows: $headers)
                .padding(.top, 6)

            let empty = model.address.trimmingCharacters(in: .whitespaces).isEmpty
            Button(model.checking ? "Verbinden…" : "Verbinden", action: check)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 22)
                .disabled(empty || model.checking)
                .opacity(empty ? 0.4 : 1)

            if let problem = model.problem { problemView(problem) }
        }
    }

    @ViewBuilder
    private func problemView(_ problem: EmbySignInProblem) -> some View {
        switch problem {
        case let .unreachable(address):
            // The same hint as everywhere a server does not answer: one sentence for
            // one situation, whichever kind of server it is.
            DisturbHint(retry: check, spacingTop: 32, address: address)
        case let .notEmby(kindFound):
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if let kindFound {
                        Text("Unter der Adresse läuft \(kindFound), kein Emby.")
                    } else {
                        Text("Unter der Adresse antwortet etwas, aber kein Emby.")
                    }
                }
                .growing(12)
                .foregroundStyle(Theme.error)
                .fixedSize(horizontal: false, vertical: true)
                // Jellyfin and Emby share their roots and answer alike: whoever typed the
                // address of a Jellyfin server here only picked the wrong card.
                if let useJellyfin = model.actions.useJellyfin, kindFound == ServerKind.jellyfin.displayName {
                    Button("Mit Jellyfin weiter") { useJellyfin(model.address) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.top, 14)
        case let .other(message):
            Text(verbatim: message)
                .growing(12)
                .foregroundStyle(Theme.error)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
    }

    private func check() {
        let address = model.address.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty, !model.checking else { return }
        model.actions.check(address, headers.headers)
    }

    // MARK: - Sign in

    private func signInStep(serverName: String, version: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The header of the Jellyfin page, with the other name: the accent dot is the
            // state (it answered), the name the place.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text("Verbunden · Emby \(version)")
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
                Text(verbatim: serverName)
                    .font(Theme.title)
                    .foregroundStyle(Theme.font)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)

            accounts

            VStack(spacing: 10) {
                InputField(text: $user, symbol: "person", placeholder: "Benutzername")
                InputField(text: $password, symbol: "lock", placeholder: "Passwort",
                           secret: true, completion: signIn)
                Button(model.signingIn ? "Anmelden…" : "Anmelden", action: signIn)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 10)
                    .disabled(user.isEmpty || model.signingIn)
                    .opacity(user.isEmpty ? 0.4 : 1)
                if let error = model.signInError {
                    Text(verbatim: error)
                        .font(Theme.small)
                        .foregroundStyle(Theme.error)
                        .multilineTextAlignment(.center)
                }
            }
            .disabled(model.signingIn)
            .padding(.top, 28)
        }
        .onChange(of: user) { _, _ in model.signInError = nil }
    }

    /// The accounts the server shows. While they come: circles in their shape, so the
    /// fields below do not jump down when they arrive. None: nothing, the fields alone.
    @ViewBuilder
    private var accounts: some View {
        if model.users == nil {
            VStack(alignment: .leading, spacing: 0) {
                heading
                HStack(spacing: 16) {
                    ForEach(0 ..< 3, id: \.self) { _ in
                        VStack(spacing: 8) {
                            LoadField(corner: 30).frame(width: 60, height: 60)
                            LoadField(corner: 3).frame(width: 48, height: 10)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .padding(.top, 22)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Lädt"))
        } else if let users = model.users, !users.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                heading
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(users) { person in
                            Button { user = person.name } label: {
                                AccountCharacter(name: person.name, image: person.image,
                                                 selected: user == person.name)
                            }
                            .buttonStyle(Theme.PressRow())
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, 22)
        }
    }

    private var heading: some View {
        GroupsTitle(text: "Wer schaut?")
            .padding(.horizontal, -Theme.edgeSpacing)
            .accessibilityAddTraits(.isHeader)
    }

    private func signIn() {
        guard !user.isEmpty, !model.signingIn else { return }
        model.actions.signIn(user, password)
    }
}

// MARK: - Previews

@MainActor
private func embyPreview(_ setup: (EmbySignInModel) -> Void) -> some View {
    let model = EmbySignInModel()
    setup(model)
    return NavigationStack { EmbySignInView(model: model) }
}

#Preview("Adresse") { embyPreview { _ in } }
#Preview("Prüft") { embyPreview { $0.address = "emby.beispiel.de"; $0.checking = true } }
#Preview("Antwortet nicht") {
    embyPreview { $0.address = "emby.beispiel.de"; $0.problem = .unreachable(address: "emby.beispiel.de") }
}
#Preview("Ist Jellyfin") {
    embyPreview {
        $0.address = "tv.beispiel.de"
        $0.problem = .notEmby(kindFound: "Jellyfin")
        $0.actions.useJellyfin = { _ in }
    }
}
#Preview("Konten laden") {
    embyPreview { $0.step = .signIn(serverName: "Keller", version: "4.9.1") }
}
#Preview("Konten") {
    embyPreview {
        $0.step = .signIn(serverName: "Mediathek im Keller mit einem langen Namen", version: "4.9.1")
        $0.users = [EmbyUserChoice(id: "1", name: "Mara"), EmbyUserChoice(id: "2", name: "Theo"),
                    EmbyUserChoice(id: "3", name: "Gäste")]
        $0.signInError = "Name oder Passwort stimmt nicht."
    }
}
