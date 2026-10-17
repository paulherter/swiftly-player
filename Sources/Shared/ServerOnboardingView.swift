import JellyfinKit
import SwiftUI

/// **Add a second Jellyfin server.**
///
/// Address, then name and password - like the first sign-in, except the running
/// session notices nothing. Only once sign-in there succeeds is the server added
/// to the set and the app switches to it. Cancelling leaves things exactly as
/// they were.
///
/// Same components as `LoginView`: input field, primary button, the header with
/// "Connected - Jellyfin ...". Credentials are entered here and sent only to
/// the server; only the session it issues is stored.
struct ServerOnboardingView: View {
    let model: AppModel
    /// A server already in the set - then it is about another account there,
    /// and the address is already filled in.
    var preset: URL? = nil
    /// **What happens at the end - or nothing, then the page goes back.**
    ///
    /// It used to be presented as a sheet and needed someone to close the sheet.
    /// As a pushed page it closes itself; the callback remains for callers that
    /// also clean up something else.
    var done: (() -> Void)? = nil

    @Environment(\.dismiss) private var close

    private func finish() {
        if let done { done() } else { close() }
    }

    @State private var address = ""
    @State private var server: (name: String, version: String)?
    @State private var examine = false
    @State private var user = ""
    @State private var password = ""
    @State private var quickConnect = false
    /// "Advanced": custom headers for a service in front of the server.
    @State private var headers: [HeaderRow] = []

    /// What sits next to the back button - it changes with the state.
    private var pagesTitle: String {
        if let server { return server.name }
        return preset == nil ? String(localized: "Server hinzufügen")
                                     : String(localized: "Konto hinzufügen")
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    // With an address entered there is nothing to type - the field only
                    // appears if the server does not answer.
                    if server != nil { loginPart }
                    else if preset == nil || model.errorMessage != nil { addressPart }
                    if let error = model.errorMessage {
                        Text(error)
                            .growing(12)
                            // The server did not answer - that failed, it is not
                            // pending. `error`.
                            .foregroundStyle(Theme.error)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
                .frame(maxWidth: Theme.formWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            // **The back button is the cancel.** There used to be its own "Cancel" row
            // at the bottom - needed while the view came as a sheet and could only be
            // closed that way. As a pushed page it has the same back button on top as
            // any other, and two ways back are one too many.
            .safeAreaInset(edge: .top, spacing: 0) {
                SubpageHeader(title: pagesTitle) {
                    model.serverOnboardingCancel()
                    finish()
                } right: { EmptyView() }
            }
        }
        #if os(iOS)
        // Without this, Apple's bar with its own back arrow sits above - then there
        // are two, and one is made of glass. That was visible here because the view
        // started as a sheet and never needed the bar.
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .onAppear {
            model.serverOnboardingCancel()
            if let preset {
                address = preset.absoluteString
                check()
            }
        }
        .fullScreenCover(isPresented: $quickConnect) {
            QuickConnectLogin(model: model, newServer: true) { finish() }
        }
    }

    /// **No own large title anymore.**
    ///
    /// It used to show the page name in 28 bold, 48 pt below the status bar -
    /// the build of a root page. As a pushed subpage the bar at the top carries it
    /// next to the back button, like any other subpage. What remains is what the
    /// title cannot say: the connection state and the explanation.
    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let server {
                HStack(spacing: 8) {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    Text("Verbunden · Jellyfin \(server.version)")
                        // The value from the type scale, 12 regular. Previously a literal number.
                        .growing(12)
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
            } else if let preset {
                Text(verbatim: preset.host() ?? preset.absoluteString)
                    .growing(15)
                    .foregroundStyle(Theme.fontQuiet)
            } else {
                Text("Die Adresse eines weiteren Jellyfin-Servers. Du bleibst bei beiden angemeldet und wechselst auf der Profilseite zwischen ihnen.")
                    .growing(15)
                    .lineSpacing(3)
                    .foregroundStyle(Theme.fontQuiet)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var addressPart: some View {
        VStack(spacing: 10) {
            InputField(text: $address, symbol: "externaldrive.connected.to.line.below",
                        placeholder: "tv.example.de", completion: check)
            AdvancedSection(rows: $headers)
            Button(examine ? "Verbinden…" : "Verbinden", action: check)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 10)
                .disabled(examine || address.isEmpty)
                .opacity(address.isEmpty ? 0.4 : 1)
        }
        .padding(.top, 28)
    }

    private var loginPart: some View {
        VStack(spacing: 10) {
            InputField(text: $user, symbol: "person", placeholder: "Benutzername")
            InputField(text: $password, symbol: "lock", placeholder: "Passwort",
                        secret: true, completion: signIn)
            Button(model.isWorking ? "Anmelden…" : "Anmelden", action: signIn)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 10)
                .disabled(model.isWorking || user.isEmpty)
                .opacity(user.isEmpty ? 0.4 : 1)

            // As in the first sign-in: Quick Connect as a second path - no password
            // on the phone, approved on a device already signed in to the new server.
            HStack(spacing: 12) {
                Rectangle().fill(Theme.line).frame(height: 1)
                Text("oder")
                    // The value from the type scale, 12 regular. Previously a literal number.
                    .growing(12)
                    .foregroundStyle(Theme.fontVeryQuiet)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            .padding(.top, 16)
            Button {
                quickConnect = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "tv")
                    Text("Mit Quick Connect anmelden")
                }
            }
            .buttonStyle(SecondaryButtonStyle(accent: true))
            .padding(.top, 10)
        }
        .padding(.top, 28)
    }

    private func check() {
        guard !address.isEmpty, !examine else { return }
        examine = true
        let checked = address
        Task {
            let answer = await model.serverCheck(address, headers: headers.headers)
            // A different address is in the field meanwhile: the response belongs to
            // the old one and is discarded.
            guard address == checked else {
                model.errorMessage = nil
                examine = false
                return
            }
            // The sign-in part appears because the server answered - exactly the case
            // `Theme.einblenden` exists for. Previously its own `.easeInOut(0,2)`.
            withAnimation(Theme.reveal) { server = answer }
            examine = false
        }
    }

    private func signIn() {
        guard !user.isEmpty else { return }
        Task {
            if await model.signInAtNewServer(user: user, password: password) {
                password = ""
                finish()
            }
        }
    }
}
