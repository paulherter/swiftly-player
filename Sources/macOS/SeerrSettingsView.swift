import JellyfinKit
import SwiftUI
import SwiftlyCore

/// Connect Seerr: address, name, password. Mac version.
///
/// **The name is prefilled.** Both sides use the same account; Seerr asks Jellyfin
/// itself whether name and password match. So only what we lack is typed: the
/// password. It is not stored; only the session Seerr issues in response is saved.
///
/// **An add-on, not a foundation.** Anyone who connects nothing sees nothing of it
/// apart from one row in Settings: no empty section, no greyed button, no hint of
/// missing out.
struct SeerrSettingsView: View {
    let model: AppModel
    let seerr: SeerrModel
    let back: () -> Void

    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var headers: [HeaderRow] = []
    @State private var method: SwiftlyCore.SignInMethod?
    /// The core's sign-in screen (not connected / signing in / failed with words / connected), one per page visit.
    @State private var flow: SeerrSetupFlow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: "Seerr", back: back)

                Text("Jellyseerr oder Overseerr. Dann zeigt die Suche auch Titel, die noch nicht auf deinem Server sind, und du kannst sie anfragen.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                if seerr.connected { connected } else { formSheet }
            }
            // Left-aligned like Settings and Playback, which lead here; otherwise the arrow
            // would jump to the window centre on opening.
            .frame(maxWidth: Theme.formWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .pagesScroll()
        .task {
            if user.isEmpty { user = model.session?.userName ?? "" }
            await seerr.lookUp()
        }
        // Not connected: the core's screen decides what shows. Connected, or after a disconnect, a fresh one.
        .task(id: seerr.connected) {
            guard !seerr.connected else { flow = nil; return }
            if method == nil, model.session?.kind == .plex { method = .plex }
            let fresh = SeerrSetupFlow(seerr: seerr)
            flow = fresh
            await fresh.open()
        }
    }

    private var sessionText: String {
        switch seerr.sessionState {
        case .valid: String(localized: "Aktiv")
        case .invalid: String(localized: "Sitzung abgelaufen")
        case .unreachable: String(localized: "Seerr nicht erreichbar")
        }
    }

    private var connected: some View {
        SettingGroup(title: "Verbunden") {
            ValuesRow(symbol: "link",
                       title: Text(verbatim: seerr.address ?? ""),
                       value: sessionText)
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            // **"Disconnect", not "Sign out".** Nothing changes at Seerr itself; only this
            // one access is removed here.
            ValuesRow(symbol: "xmark.circle", title: Text("Verbindung trennen"),
                       action: { seerr.disconnect(); address = ""; password = "" })
        }
        .padding(.top, 26)
    }

    @ViewBuilder
    private var formSheet: some View {
        if let flow, flow.opened, !flow.working {
            switch flow.info.entry {
            case .notSetUp:
                Text(verbatim: flow.info.notSetUp ?? "")
                    .font(Theme.body).foregroundStyle(Theme.fontQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 26)
            case .askAddress, .knownAddress:
                signInForm(flow)
            }
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(verbatim: flow?.info.busy ?? "").font(Theme.body).foregroundStyle(Theme.fontQuiet)
            }
            .padding(.top, 26)
        }
    }

    private func signInForm(_ flow: SeerrSetupFlow) -> some View {
        let rows = flow.methods
        let chosen = rows.first { $0.method == method } ?? rows.first
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // The address: asked once per server of the administrator only. Everyone else sees it as a line.
                if flow.info.entry == .askAddress {
                    InputRow(text: $address, symbol: "link", placeholder: "seerr.example.de")
                    MacAdvanced(rows: $headers)
                } else if let known = flow.info.address {
                    HStack {
                        Text(verbatim: known)
                            .font(Theme.body).foregroundStyle(Theme.fontQuiet)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        if flow.info.canEditAddress {
                            Button("Adresse ändern") { flow.editAddress() }
                                .buttonStyle(Theme.PressButton())
                                .font(Theme.body).foregroundStyle(Theme.font)
                        }
                    }
                }
                if rows.count > 1 {
                    SettingGroup(title: "Anmelden") {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { SheetLine().padding(.leading, Theme.separatorInsetCard) }
                            ValuesRow(symbol: "person.crop.circle", title: Text(verbatim: row.title),
                                      action: {
                                method = row.method
                                // The Jellyfin name is the media server's; an e-mail is typed.
                                user = row.method == .jellyfin ? (model.session?.userName ?? "") : ""
                            }, checkmark: row.method == chosen?.method)
                        }
                    }
                }
                if let chosen {
                    if let label = chosen.userLabel {
                        InputRow(text: $user, symbol: "person", placeholder: label)
                    }
                    if chosen.needsPassword {
                        InputRow(text: $password, symbol: "lock", secret: true,
                                 placeholder: String(localized: "Passwort"),
                                 completion: { Task { await signIn(chosen, flow) } })
                    }
                }
            }

            if let error = flow.info.error {
                Text(verbatim: error)
                    .font(Theme.secondLine)
                    // The sign-in failed, it is not waiting: `error`, as on every server sign-in.
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }

            // No disabled button: while nothing is entered there is nothing to do, and a
            // greyed button suggests otherwise.
            if let chosen, ready(chosen, flow) {
                PrimaryButton(label: flow.working ? "Verbinde…" : "Anmelden", symbol: "link") {
                    guard !flow.working else { return }
                    Task { await signIn(chosen, flow) }
                }
                .padding(.top, 20)
            }

            Text("Swiftly speichert dein Passwort nicht, nur die Anmeldung bei Seerr.")
                .font(Theme.secondLine)
                .foregroundStyle(Theme.fontVeryQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .padding(.top, 26)
    }

    private func ready(_ row: SwiftlyCore.SetupMethodRow, _ flow: SeerrSetupFlow) -> Bool {
        if flow.info.entry == .askAddress, address.isEmpty { return false }
        if row.userLabel != nil, user.isEmpty { return false }
        if row.needsPassword, password.isEmpty { return false }
        return true
    }

    private func signIn(_ row: SwiftlyCore.SetupMethodRow, _ flow: SeerrSetupFlow) async {
        await flow.signIn(row.method, address: address, headers: headers, name: user, password: password)
        if seerr.connected { password = "" }
    }
}
