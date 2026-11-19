import JellyfinKit
import SwiftlyCore
import SwiftUI

/// Connect Seerr. The core's sign-in screen decides what shows (`SeerrSetupFlow`): the admin types the address once per
/// server, every other profile only signs in, with the way the server needs (Jellyfin account, Seerr e-mail, Plex).
///
/// **The name is already filled in** for the Jellyfin way: it is the same account on both sides, Seerr asks Jellyfin
/// itself whether name and password are right. The password is not stored for the e-mail way; of the Jellyfin way
/// only the Keychain copy for the automatic sign-in, and the session Seerr issues in response.
struct SeerrSettingsView: View {
    let model: AppModel
    let seerr: SeerrModel

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var address = ""
    /// The Jellyfin name or the Seerr e-mail, whichever way is chosen.
    @State private var user = ""
    @State private var method: SwiftlyCore.SignInMethod?
    /// The core's sign-in screen; made when the page opens without a connection and again after a disconnect.
    @State private var flow: SeerrSetupFlow?
    @State private var password = ""
    /// "Advanced": custom headers for a service in front of Seerr.
    @State private var headers: [HeaderRow] = []
    /// "Show arrival hints": the same device key the settings sync carries (`seerrArrivalHint`).
    @AppStorage(SeerrArrival.hintKey) private var arrivalHint = true

    var body: some View {
        ZStack(alignment: .top) {
            // The same background as every other page. It was briefly a separate one
            // (`gruppengrund`) because pure black under a card was the whole jump at once;
            // since the background is #101010 the jump is a fifth of that and needs no
            // exception.
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 0) {
                // Title next to the arrow, not below it; see `SettingsView`.
                ScrollView { content }.scrollIndicators(.hidden)
            }
            .fadingUnderSubpageHeader(title: String(localized: "Seerr")) { back() }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
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

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Jellyseerr oder Overseerr. Dann zeigt die Suche auch Titel, die noch nicht auf deinem Server sind, und du kannst sie anfragen.")
                // **Growing, not fixed**: body text and settings follow
                // the system font. The same level as `Theme.body`, only it scales.
                .growing(15)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, 10)

            if seerr.connected { connectedPart } else { formSheet }

            Spacer(minLength: 40)
        }
        // `formWidth`, not 520: the same role as sign-in and server onboarding, so
        // the same measure. 520 was the second answer to "how wide may a form get".
        .frame(maxWidth: Theme.formWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: wide ? .center : .leading)
    }

    // MARK: Connected

    private var sessionText: String {
        switch seerr.sessionState {
        case .valid: String(localized: "Aktiv")
        case .invalid: String(localized: "Sitzung abgelaufen")
        case .unreachable: String(localized: "Seerr nicht erreichbar")
        }
    }

    @ViewBuilder
    private var connectedPart: some View {
        SettingGroup(title: "Verbunden") {
            ValueRow(symbol: "link", title: Text(verbatim: seerr.address ?? ""),
                      value: sessionText)
            SheetLine()
            // **Not "Sign out" but "Disconnect".** On Seerr's side everything stays as it
            // is; only this one access here is affected.
            ValueRow(symbol: "xmark.circle", title: Text("Verbindung trennen"),
                      action: { seerr.disconnect(); address = ""; password = "" })
        }
        .padding(.top, 26)

        SettingGroup(title: "Home") {
            ChoiceRow(symbol: "bell.badge", title: Text("Ankunft-Hinweise anzeigen"),
                      under: Text("Auf Home steht, wenn ein angefragter Titel da ist."),
                      an: $arrivalHint)
        }
        .padding(.top, 26)
    }

    // MARK: Formular

    /// What the core's sign-in screen shows: loading, one sentence (not set up), or the form with the ways it offers.
    @ViewBuilder
    private var formSheet: some View {
        if let flow, flow.opened, !flow.working {
            switch flow.info.entry {
            case .notSetUp:
                Text(verbatim: flow.info.notSetUp ?? "")
                    .growing(15).foregroundStyle(Theme.fontQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 26)
            case .askAddress, .knownAddress:
                signInForm(flow)
            }
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(verbatim: flow?.info.busy ?? "")
                    .growing(15).foregroundStyle(Theme.fontQuiet)
            }
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.top, 26)
        }
    }

    private func signInForm(_ flow: SeerrSetupFlow) -> some View {
        let rows = flow.methods
        let chosen = rows.first { $0.method == method } ?? rows.first
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // The address: asked once per server of the admin only. Everyone else sees it as a line.
                if flow.info.entry == .askAddress {
                    InputField(text: $address, symbol: "link",
                                placeholder: "seerr.example.de", keyboard: .address)
                    AdvancedSection(rows: $headers)
                } else if let known = flow.info.address {
                    HStack {
                        Text(verbatim: known)
                            .growing(15).foregroundStyle(Theme.fontQuiet)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        if flow.info.canEditAddress {
                            Button("Adresse ändern") { flow.editAddress() }
                                .growing(15).foregroundStyle(Theme.font)
                        }
                    }
                }
                if rows.count > 1 {
                    SettingGroup(title: "Anmelden") {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { SheetLine() }
                            Button {
                                method = row.method
                                // The Jellyfin name is the media server's; an e-mail is typed.
                                user = row.method == .jellyfin ? (model.session?.userName ?? "") : ""
                            } label: {
                                HStack(spacing: 10) {
                                    Image(icon: "checkmark", size: 17)
                                        .opacity(row.method == chosen?.method ? 1 : 0)
                                        .frame(width: 20)
                                        .accessibilityHidden(true)
                                    Text(verbatim: row.title).growing(15).foregroundStyle(Theme.font)
                                    Spacer(minLength: 0)
                                }
                                // A row is a full-size touch target (44 pt), not the height of its text.
                                .padding(.horizontal, 16)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(row.method == chosen?.method ? .isSelected : [])
                        }
                    }
                }
                if let chosen {
                    if let label = chosen.userLabel {
                        InputField(text: $user, symbol: "person", placeholder: LocalizedStringKey(label))
                    }
                    if chosen.needsPassword {
                        InputField(text: $password, symbol: "lock", placeholder: "Passwort", secret: true)
                    }
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))

            if let error = flow.info.error {
                Text(verbatim: error)
                    .growing(12)
                    // The sign-in failed, it is not waiting: `error`. Server sign-in does the same.
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 14)
            }

            // No disabled button: while nothing is entered there is nothing to do, and a
            // gray button claims the opposite.
            if let chosen, ready(chosen, flow) {
                Button("Anmelden") { Task { await signIn(chosen, flow) } }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 20)
            }

            Text("Swiftly speichert dein Passwort nicht, nur die Anmeldung bei Seerr.")
                .growing(12)
                .foregroundStyle(Theme.fontVeryQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, 12)
        }
        .padding(.top, 26)
    }

    /// Everything the chosen way needs is typed (the address only where the core asks for it).
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
