import JellyfinKit
import SwiftUI

/// **Sign in with Emby: the Jellyfin way, two steps on one page**, the remote's version of
/// the iPhone's `EmbySignInView`.
///
/// An address, then name and password, with the accounts the server shows as large
/// circles ("Wer schaut?"). No Quick Connect: Emby has none. The logic is the shared
/// `EmbySignInModel`; this file only draws it.
///
/// The Menu button is one step back: from the sign-in to the address, from the address out
/// of the flow (`model.goBack()`), the same arrow the iPhone shows at the top.
struct TVEmbySignInView: View {
    @Bindable var model: EmbySignInModel

    @State private var headers: [HeaderRow] = []
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                switch model.step {
                case .address:
                    addressStep
                case let .signIn(serverName, version):
                    signInStep(serverName: serverName, version: version)
                }
            }
            .frame(width: TVSpec.messageWidth, alignment: .leading)
            .animation(Theme.reveal, value: model.step)
        }
        .onExitCommand(perform: back)
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
            HStack(spacing: TVSpec.pickerCardGap) {
                ServerKindMark(kind: .emby, size: TVSpec.pickerCardMark)
                Text("Mit Emby anmelden")
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.font)
            }
            Text("Wo steht dein Emby-Server?")
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.top, TVSpec.onboardingSubtitleTop)

            VStack(alignment: .leading, spacing: TVSpec.onboardingHintSpacing) {
                InputField(placeholder: "emby.beispiel.de", text: $model.address,
                           content: .URL, completion: check)
                    .frame(width: TVSpec.formWidth)
                    .disabled(model.checking)

                Text("https:// kannst du weglassen.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)

                TVAdvanced(rows: $headers)

                HStack(spacing: TVSpec.onboardingButtonSpacing) {
                    Button(model.checking ? "Verbinden…" : "Verbinden", action: check)
                        .buttonStyle(ThemedButtonStyle())
                        .disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty
                                  || model.checking)
                    Button("Zurück", action: back)
                        .buttonStyle(ThemedButtonStyle())
                }
            }
            .padding(.top, TVSpec.onboardingBlockTop)

            if let problem = model.problem { problemView(problem) }
        }
    }

    @ViewBuilder
    private func problemView(_ problem: EmbySignInProblem) -> some View {
        VStack(alignment: .leading, spacing: TVSpec.onboardingButtonSpacing) {
            switch problem {
            case let .unreachable(address):
                // The same sentence as everywhere a server does not answer, whichever kind it is.
                Text("\(address) antwortet nicht. Läuft er noch, oder hängt das WLAN?")
                    .font(Theme.body)
                    .foregroundStyle(Theme.error)
            case let .notEmby(kindFound):
                Group {
                    if let kindFound {
                        Text("Unter der Adresse läuft \(kindFound), kein Emby.")
                    } else {
                        Text("Unter der Adresse antwortet etwas, aber kein Emby.")
                    }
                }
                .font(Theme.body)
                .foregroundStyle(Theme.error)
                // Jellyfin and Emby share their roots and answer alike: whoever typed the
                // address of a Jellyfin server here only picked the wrong card.
                if let useJellyfin = model.actions.useJellyfin,
                   kindFound == ServerKind.jellyfin.displayName {
                    Button("Mit Jellyfin weiter") { useJellyfin(model.address) }
                        .buttonStyle(ThemedButtonStyle())
                }
            case let .other(message):
                Text(verbatim: message)
                    .font(Theme.body)
                    .foregroundStyle(Theme.error)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, TVSpec.onboardingErrorTop)
    }

    private func check() {
        let address = model.address.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty, !model.checking else { return }
        model.actions.check(address, headers.headers)
    }

    // MARK: - Sign in

    private func signInStep(serverName: String, version: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // No accent. Server name and version are information, not a choice.
            Text("Verbunden · Emby \(version)")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
            Text(verbatim: serverName)
                .font(Theme.rail)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, TVSpec.loginVersionTop)

            accounts

            VStack(alignment: .leading, spacing: TVSpec.loginFieldSpacing) {
                InputField(placeholder: "Benutzername", text: $user, content: .username)
                InputField(placeholder: "Passwort", text: $password,
                           safe: true, content: .password, completion: signIn)
            }
            .frame(width: TVSpec.formWidth)
            .padding(.top, TVSpec.signInFieldsTop)
            .disabled(model.signingIn)

            HStack(spacing: TVSpec.onboardingButtonSpacing) {
                Button(model.signingIn ? "Anmelden…" : "Anmelden", action: signIn)
                    .buttonStyle(ThemedButtonStyle())
                    .disabled(user.isEmpty || model.signingIn)
                Button("Zurück", action: back)
                    .buttonStyle(ThemedButtonStyle())
            }
            .padding(.top, TVSpec.loginButtonTop)

            if let error = model.signInError {
                Text(verbatim: error)
                    .font(Theme.small)
                    .foregroundStyle(Theme.error)
                    .padding(.top, TVSpec.onboardingErrorTop)
            }
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
                HStack(spacing: TVSpec.signInAccountSpacing) {
                    ForEach(0 ..< 3, id: \.self) { _ in
                        LoadField(corner: TVSpec.signInAccountSize / 2)
                            .frame(width: TVSpec.signInAccountSize, height: TVSpec.signInAccountSize)
                    }
                }
            }
            .padding(.top, TVSpec.signInAccountsTop)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Lädt"))
        } else if let users = model.users, !users.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                heading
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: TVSpec.signInAccountSpacing) {
                        ForEach(users) { person in
                            column(person)
                        }
                    }
                    .padding(.horizontal, TVSpec.pickerRingGap + TVSpec.pickerRingWidth)
                    .padding(.vertical, TVSpec.pickerRingGap + TVSpec.pickerRingWidth)
                }
                .scrollClipDisabled()
                .focusSection()
            }
            .padding(.top, TVSpec.signInAccountsTop)
        }
    }

    private func column(_ person: EmbyUserChoice) -> some View {
        let chosen = user == person.name
        return VStack(spacing: TVSpec.signInAccountNameTop) {
            Button { user = person.name } label: {
                ProfileCharacter(name: person.name, image: person.image,
                                 size: TVSpec.signInAccountSize, selected: chosen)
            }
            .buttonStyle(ProfilePickerStyle())
            Text(verbatim: person.name)
                .font(Theme.small)
                .foregroundStyle(chosen ? Theme.font : Theme.fontQuiet)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: TVSpec.signInAccountSize + TVSpec.signInAccountSpacing)
        }
    }

    private var heading: some View {
        GroupsTitle(text: "Wer schaut?")
            .padding(.leading, -TVSpec.rowInset)
            .accessibilityAddTraits(.isHeader)
    }

    private func signIn() {
        guard !user.isEmpty, !model.signingIn else { return }
        model.actions.signIn(user, password)
    }
}
