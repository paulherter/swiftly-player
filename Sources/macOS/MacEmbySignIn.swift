import JellyfinKit
import SwiftUI

/// **Sign in with Emby on the Mac: the Jellyfin way, two steps on one page.**
///
/// The Mac's counterpart of `EmbySignInView` on the iPhone, drawn from the same
/// `EmbySignInModel` with the same words. What differs is the input: the address field
/// has the focus when the page opens, Return in it checks the address, Return in the
/// password field signs in, Escape goes one step back (`MacFlowPage`), and the accounts
/// the server shows light up under the pointer.
///
/// Without Quick Connect: Emby has none.
struct MacEmbySignIn: View {
    @Bindable var model: EmbySignInModel
    var centered = false

    @State private var headers: [HeaderRow] = []
    @State private var user = ""
    @State private var password = ""
    @FocusState private var field: Field?

    private enum Field { case address, user, password }

    var body: some View {
        MacFlowPage(title: String(localized: "Mit Emby anmelden"), back: back, centered: centered) {
            switch model.step {
            case .address:
                addressStep
            case let .signIn(serverName, version):
                signInStep(serverName: serverName, version: version)
            }
        }
        .animation(Theme.reveal, value: model.step)
        .onAppear { field = .address }
        // Changing the address after an error takes the error away: it was about the old one.
        .onChange(of: model.address) { _, _ in model.problem = nil }
        .onChange(of: model.users) { _, users in
            // One account: nothing to choose, the name is filled in. As on the Jellyfin page.
            if let users, users.count == 1, user.isEmpty { user = users[0].name }
        }
        .onChange(of: model.step) { _, step in
            switch step {
            case .address: field = .address
            case .signIn: field = user.isEmpty ? .user : .password
            }
        }
    }

    private func back() {
        if case .signIn = model.step { password = "" }
        model.goBack()
    }

    // MARK: Address

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            ServerKindMark(kind: .emby, size: 44)
                .padding(.top, 22)
            Text("Wo steht dein Emby-Server?")
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.top, 18)

            InputRow(text: $model.address, symbol: "globe",
                     placeholder: "emby.beispiel.de", completion: check)
                .padding(.top, 14)
                .focused($field, equals: .address)
                .disabled(model.checking)

            Text("https:// kannst du weglassen.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .padding(.top, 9)
                .padding(.leading, 2)

            MacAdvanced(rows: $headers)
                .padding(.top, 8)

            let empty = model.address.trimmingCharacters(in: .whitespaces).isEmpty
            PrimaryButton(label: model.checking ? "Verbinden…" : "Verbinden",
                          symbol: "arrow.right", pick: check)
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
            // The same hint as everywhere a server does not answer.
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
                .font(Theme.secondLine)
                .foregroundStyle(Theme.error)
                .fixedSize(horizontal: false, vertical: true)
                // Jellyfin and Emby share their roots and answer alike: whoever typed the
                // address of a Jellyfin server here only picked the wrong card.
                if let useJellyfin = model.actions.useJellyfin,
                   kindFound == ServerKind.jellyfin.displayName {
                    OutlineButton(label: "Mit Jellyfin weiter", symbol: "arrow.right") {
                        useJellyfin(model.address)
                    }
                }
            }
            .padding(.top, 14)
        case let .other(message):
            Text(verbatim: message)
                .font(Theme.secondLine)
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

    // MARK: Sign in

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
                    .font(Theme.subpageTitle).tracking(Theme.lockSubpage)
                    .foregroundStyle(Theme.font)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 22)

            accounts

            VStack(spacing: 10) {
                InputRow(text: $user, symbol: "person",
                         placeholder: String(localized: "Benutzername")) { field = .password }
                    .focused($field, equals: .user)
                InputRow(text: $password, symbol: "lock", secret: true,
                         placeholder: String(localized: "Passwort"), completion: signIn)
                    .focused($field, equals: .password)
                PrimaryButton(label: model.signingIn ? "Anmelden…" : "Anmelden",
                              symbol: "arrow.right", pick: signIn)
                    .padding(.top, 10)
                    .disabled(user.isEmpty || model.signingIn)
                    .opacity(user.isEmpty ? 0.4 : 1)
                if let error = model.signInError {
                    Text(verbatim: error)
                        .font(Theme.secondLine)
                        .foregroundStyle(Theme.error)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(model.signingIn)
            .padding(.top, 26)
        }
        .onChange(of: user) { _, _ in model.signInError = nil }
    }

    /// The accounts the server shows. While they come: circles in their shape, so the
    /// fields below do not jump down when they arrive. None: nothing, the fields alone.
    @ViewBuilder
    private var accounts: some View {
        if model.users == nil {
            VStack(alignment: .leading, spacing: 12) {
                GroupsTitle(text: "Wer schaut?")
                HStack(spacing: 16) {
                    ForEach(0 ..< 3, id: \.self) { _ in
                        VStack(spacing: 8) {
                            LoadField(corner: 30).frame(width: 60, height: 60)
                            LoadField(corner: 3).frame(width: 48, height: 10)
                        }
                    }
                }
            }
            .padding(.top, 22)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Lädt"))
        } else if let users = model.users, !users.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                GroupsTitle(text: "Wer schaut?")
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(users) { person in
                            let pick = { user = person.name; field = .password }
                            Button(action: pick) {
                                AccountCharacter(name: person.name, image: person.image,
                                                 selected: user == person.name)
                                    .padding(6)
                            }
                            .buttonStyle(Theme.PressButton())
                            .choiceSurface(corner: Theme.cornerCard, activate: pick)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, 22)
        }
    }

    private func signIn() {
        guard !user.isEmpty, !model.signingIn else { return }
        model.actions.signIn(user, password)
    }
}
