import JellyfinKit
import SwiftUI

/// **Add a second Jellyfin server.**
///
/// Address, then name and password, as on first sign-in, except that the running
/// session notices nothing. Only when the sign-in there succeeds is the server
/// added to the bundle and the app switches to it. Cancelling leaves things
/// exactly as they were.
///
/// **Quick Connect sits alongside on equal footing.** It was missing at first and
/// a tester found it at once: someone already signed in on the TV does not want to
/// type the password again.
///
/// Credentials are entered here and sent only to the server; only the session it
/// issues is kept.
struct ServerOnboardingView: View {
    let model: AppModel
    /// A server already in the bundle: then this is about another account there, and
    /// the address is already filled in.
    var preset: URL?
    let back: () -> Void

    @State private var address = ""
    @State private var server: (name: String, version: String)?
    @State private var examine = false
    @State private var user = ""
    @State private var passphrase = ""
    /// "Erweitert" (Advanced): custom headers for a service in front of the server.
    @State private var headers: [HeaderRow] = []
    /// Switched to the code flow. The flow only starts then; otherwise every visit to
    /// this page would request a code from the server that nobody needs.
    ///
    /// **In the window, not as a sheet on top.** On iPhone Quick Connect opens its own
    /// full screen: there is no room to keep a field and a six-digit code legible side
    /// by side. Here there is room, and a sheet over a half-filled form would hide the
    /// very thing the code refers to: which server one is signing in to. Same decision
    /// as for "Weiteres Konto" (add account), one screen on.
    @State private var perCode = false
    @State private var state = QuickConnectModel()
    @FocusState private var inputField: Field?

    private enum Field { case address, user, passphrase }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubpageHeader(title: preset == nil ? "Server hinzufügen" : "Weiteres Konto",
                            back: cancel)

            Text(explanation)
                .font(Theme.body)
                .lineSpacing(3)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            if let server {
                found(server).padding(.top, 22)
                if perCode { codePart } else { formSheet }
            } else {
                // With an address entered there is nothing to type; the field appears only when
                // the server does not respond.
                if preset == nil || model.errorMessage != nil { addressPart }
                else { hunts }
            }

            Spacer(minLength: 0)
        }
        // Narrow like a form, but left-aligned like every subpage.
        .frame(maxWidth: Theme.formWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.edgeSpacing)
        .padding(.top, Theme.contentTop)
        .onAppear {
            // **Clean up before starting.** An aborted attempt otherwise leaves its server and
            // its error message behind.
            model.serverOnboardingCancel()
            state.newServer = true
            if let preset {
                address = preset.absoluteString
                check()
            } else {
                inputField = .address
            }
        }
        // The code is fetched only when someone switches to it.
        .task(id: perCode) { if perCode { await state.newStart(model) } }
        .onDisappear { state.halt() }
        .onChange(of: state.released) { _, new in
            guard let new else { return }
            Task { _ = await model.signInWithQuickConnectAtNewServer(new) }
        }
    }

    private var explanation: LocalizedStringKey {
        preset == nil
        ? "Ein zweiter Jellyfin mit eigenen Konten. Beide bleiben angemeldet; auf der Profilseite wechselst du zwischen ihnen."
        : "Ein weiteres Konto auf diesem Server. Beide bleiben angemeldet; auf der Profilseite wechselst du zwischen ihnen."
    }

    // MARK: Address

    @ViewBuilder
    private var addressPart: some View {
        InputRow(text: $address, symbol: "server.rack",
                     placeholder: String(localized: "jellyfin.beispiel.de"),
                     completion: check)
            .padding(.top, 26)
            .focused($inputField, equals: .address)

        MacAdvanced(rows: $headers)
            .padding(.top, 10)

        errorRow

        PrimaryButton(label: examine ? "Moment…" : "Weiter", symbol: "arrow.right",
                   pick: check)
            .padding(.top, 22)
            .disabled(address.isEmpty || examine)
            .opacity(address.isEmpty ? 0.4 : 1)
    }

    /// While the entered address is being checked, the shape of the result stands here
    /// instead of a spinner.
    private var hunts: some View {
        LoadField(corner: Theme.cornerField)
            .frame(width: 280, height: 20)
            .padding(.top, 26)
    }

    /// Where the account goes. Display, not a field.
    private func found(_ server: (name: String, version: String)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.small)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(verbatim: "\(server.name) · Jellyfin \(server.version)")
                .font(Theme.secondLine)
                .foregroundStyle(Theme.fontVeryQuiet)
        }
    }

    // MARK: Name and password

    @ViewBuilder
    private var formSheet: some View {
        InputRow(text: $user, symbol: "person",
                     placeholder: String(localized: "Benutzername")) { inputField = .passphrase }
            .padding(.top, 26)
            .focused($inputField, equals: .user)

        InputRow(text: $passphrase, symbol: "lock", secret: true,
                     placeholder: String(localized: "Passwort"), completion: signIn)
            .padding(.top, 10)
            .focused($inputField, equals: .passphrase)

        errorRow

        PrimaryButton(label: model.isWorking ? "Moment…" : "Anmelden",
                   symbol: "arrow.right", pick: signIn)
            .padding(.top, 22)
            .disabled(user.isEmpty || model.isWorking)
            .opacity(user.isEmpty ? 0.4 : 1)

        separatorWithOr.padding(.top, 18)

        OutlineButton(label: "Mit Quick Connect anmelden",
                    symbol: "rectangle.and.text.magnifyingglass") { perCode = true }
            .padding(.top, 18)
    }

    // MARK: Quick Connect

    @ViewBuilder
    private var codePart: some View {
        if let preGait = state.preGait {
            Text("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du an diesem Server schon angemeldet bist.")
                .font(Theme.secondLine)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 26)

            Text(verbatim: preGait.code)
                // 28 bold is the highest step of the scale; 40 was above it.
                .font(Theme.titleLarge.monospacedDigit())
                .tracking(6)
                .foregroundStyle(Theme.font)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Theme.area,
                            in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                // A click copies the code to the clipboard; it is usually pasted right next to it
                // in a browser window.
                .copyable(preGait.code)
                .padding(.top, 14)

            Text("Läuft ab in \(state.secondsLeft / 60):\(String(format: "%02d", state.secondsLeft % 60))")
                .font(Theme.secondLine)
                .foregroundStyle(Theme.fontVeryQuiet)
                .padding(.top, 14)
        } else if let error = state.error {
            Text(verbatim: error)
                .font(Theme.secondLine)
                .foregroundStyle(Theme.warning)
                .padding(.top, 26)
        } else {
            // The code is coming; until then its shape is shown.
            LoadField(corner: Theme.cornerField)
                .frame(width: 240, height: 64)
                .padding(.top, 26)
        }

        errorRow

        OutlineButton(label: "Lieber Name und Passwort", symbol: "person") {
            state.halt()
            perCode = false
        }
        .padding(.top, 22)
    }

    // MARK: Small parts

    @ViewBuilder
    private var errorRow: some View {
        if let error = model.errorMessage {
            Text(verbatim: error)
                .font(Theme.secondLine)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    private var separatorWithOr: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Text("oder")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    // MARK: Flow

    private func check() {
        guard !address.isEmpty, !examine else { return }
        examine = true
        let checked = address
        Task {
            let answer = await model.serverCheck(address, headers: headers.headers)
            // A different address is in the field by now: the response belongs to the old one
            // and is discarded.
            guard address == checked else {
                model.errorMessage = nil
                examine = false
                return
            }
            withAnimation(Theme.leap) { server = answer }
            examine = false
            if answer != nil { inputField = .user }
        }
    }

    private func signIn() {
        guard !user.isEmpty else { return }
        Task {
            if await model.signInAtNewServer(user: user, password: passphrase) {
                passphrase = ""
                // **No `back()` here.** Signing in switches to the new server, and `MainView`
                // then clears the stack down to the profile page, so this page is long gone. A
                // back on top would take the profile page with it and end in an empty stack.
            }
        }
    }

    private func cancel() {
        state.halt()
        model.serverOnboardingCancel()
        back()
    }
}
