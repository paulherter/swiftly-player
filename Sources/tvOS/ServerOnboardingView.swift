import JellyfinKit
import SwiftUI

/// Add a second Jellyfin server. Enter the address, then sign in, with Quick Connect first: on Mac name and password come first, here it is reversed, since typing a password with the remote means swiping letter by letter through a grid. The running session notices nothing; only when sign-in there succeeds does the server join the set and the app switch to it. Cancelling leaves things exactly as they were.
struct ServerOnboardingView: View {
    let model: AppModel
    let close: () -> Void
    /// A server the page already knows (a second account on it): checked on appear.
    var preset: URL? = nil
    /// The kind was chosen on the picker before: the title says what is being signed in.
    var kindPicked = false
    /// One step back to the picker. Without it the page closes.
    var back: (() -> Void)? = nil

    @State private var address = ""
    @State private var server: (name: String, version: String)?
    @State private var examine = false
    @State private var user = ""
    @State private var password = ""
    /// "Advanced": custom headers for a service in front of the server.
    @State private var headers: [HeaderRow] = []
    /// The code path starts only once the server is set; otherwise every visit would fetch a code from a server that does not exist yet.
    @State private var perCode = true
    @State private var state = QuickConnectModel()

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text(kindPicked && preset == nil ? LocalizedStringKey("Mit Jellyfin anmelden")
                     : LocalizedStringKey("Server hinzufügen"))
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.font)

                Text("Ein zweiter Jellyfin mit eigenen Konten. Beide bleiben angemeldet; im Profil wechselst du zwischen ihnen.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .frame(width: TVSpec.messageWidth, alignment: .leading)
                    .padding(.top, TVSpec.onboardingSubtitleTop)

                if let server { login(server) } else { addressPart }

                if let error = model.errorMessage {
                    Text(verbatim: error)
                        .font(Theme.small)
                        .foregroundStyle(Theme.error)
                        .padding(.top, TVSpec.onboardingErrorTop)
                }

                Button(back == nil ? LocalizedStringKey("Abbrechen") : LocalizedStringKey("Zurück"),
                       action: leave)
                .buttonStyle(ThemedButtonStyle())
                .padding(.top, TVSpec.onboardingCancelTop)
            }
            .frame(width: TVSpec.messageWidth, alignment: .leading)
        }
        .onExitCommand(perform: leave)
        .onAppear {
            // Clean up first: an aborted attempt otherwise leaves its server and error message behind.
            model.serverOnboardingCancel()
            state.newServer = true
            if let preset, address.isEmpty {
                address = preset.absoluteString
                check()
            }
        }
        .onDisappear { state.halt() }
        // The code is fetched once a server is set, and only then.
        .task(id: "\(server?.name ?? "")|\(perCode)") {
            guard server != nil, perCode else { return }
            await state.newStart(model)
        }
        .onChange(of: state.released) { _, new in
            guard let new else { return }
            // No closing from here: sign-in switches to the new server, and the page above closes with the switch anyway.
            Task { _ = await model.signInWithQuickConnectAtNewServer(new) }
        }
    }

    // MARK: Address

    private var addressPart: some View {
        VStack(alignment: .leading, spacing: TVSpec.onboardingHintSpacing) {
            InputField(placeholder: "tv.beispiel.de", text: $address,
                        content: .URL, completion: check)
                .frame(width: TVSpec.formWidth)

            Text("https:// kannst du weglassen.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)

            TVAdvanced(rows: $headers)

            Button(examine ? "Moment…" : "Weiter", action: check)
                .buttonStyle(ThemedButtonStyle())
                .disabled(address.isEmpty || examine)
        }
        .padding(.top, TVSpec.onboardingBlockTop)
    }

    // MARK: Sign-in

    @ViewBuilder
    private func login(_ server: (name: String, version: String)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // No accent. Server name and version are information, not a choice; the accent carries progress, selection and the Direct Play proof.
            Text(verbatim: "\(server.name) · Jellyfin \(server.version)")
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)

            if perCode { codePart } else { formSheet }
        }
        .padding(.top, TVSpec.onboardingBlockTop)
    }

    @ViewBuilder
    private var codePart: some View {
        Text("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du an diesem Server schon angemeldet bist.")
            .font(Theme.body)
            .foregroundStyle(Theme.fontQuiet)
            .frame(width: TVSpec.messageWidth, alignment: .leading)
            .padding(.top, TVSpec.onboardingCodeTop)

        if let preGait = state.preGait {
            // Same fields as on the Quick Connect page; see `CodeFields`. The code used to be one line at 80 pt.
            CodeFields(code: preGait.code)
                .padding(.top, 24)
            Text("Läuft ab in \(state.secondsLeft / 60):\(String(format: "%02d", state.secondsLeft % 60))")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .padding(.top, 12)
        } else if let error = state.error {
            Text(verbatim: error)
                .font(Theme.body)
                .foregroundStyle(Theme.error)
                .padding(.top, 24)
        }

        Button("Lieber Name und Passwort") {
            state.halt()
            perCode = false
        }
        .buttonStyle(ThemedButtonStyle())
        .padding(.top, TVSpec.onboardingAlternativeTop)
    }

    @ViewBuilder
    private var formSheet: some View {
        VStack(alignment: .leading, spacing: TVSpec.onboardingHintSpacing) {
            InputField(placeholder: "Benutzername", text: $user, content: .username)
            InputField(placeholder: "Passwort", text: $password,
                        safe: true, content: .password, completion: signIn)

            HStack(spacing: TVSpec.onboardingButtonSpacing) {
                Button(model.isWorking ? "Moment…" : "Anmelden", action: signIn)
                    .buttonStyle(ThemedButtonStyle())
                    .disabled(user.isEmpty || model.isWorking)
                Button("Lieber Quick Connect") { perCode = true }
                    .buttonStyle(ThemedButtonStyle())
            }
        }
        .frame(width: TVSpec.formWidth, alignment: .leading)
        .padding(.top, TVSpec.onboardingFormTop)
    }

    // MARK: Flow

    /// The button and the Menu button: one step back, or out when the page has no picker before it.
    private func leave() {
        state.halt()
        model.serverOnboardingCancel()
        (back ?? close)()
    }

    private func check() {
        guard !address.isEmpty, !examine else { return }
        examine = true
        let checked = address
        Task {
            let answer = await model.serverCheck(address, headers: headers.headers)
            // Another address is in the field meanwhile: the answer belongs to the old one and is dropped.
            guard address == checked else {
                model.errorMessage = nil
                examine = false
                return
            }
            withAnimation(Theme.reveal) { server = answer }
            examine = false
        }
    }

    private func signIn() {
        guard !user.isEmpty else { return }
        Task {
            if await model.signInAtNewServer(user: user, password: password) {
                password = ""
            }
        }
    }
}
