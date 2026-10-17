import JellyfinKit
import SwiftUI

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
    /// "Advanced": custom headers for a service in front of Seerr.
    @State private var headers: [HeaderRow] = []

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
    }

    private var connected: some View {
        SettingGroup(title: "Verbunden") {
            ValuesRow(symbol: "link",
                       title: Text(verbatim: seerr.address ?? ""),
                       value: seerr.carries ? String(localized: "Aktiv")
                                          : String(localized: "Sitzung abgelaufen"))
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            // **"Disconnect", not "Sign out".** Nothing changes at Seerr itself; only this
            // one access is removed here.
            ValuesRow(symbol: "xmark.circle", title: Text("Verbindung trennen"),
                       action: { seerr.disconnect(); address = ""; password = "" })
        }
        .padding(.top, 26)
    }

    private var formSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // The address is the only genuinely new input.
                InputRow(text: $address, symbol: "link",
                             placeholder: "seerr.example.de")
                // **Prefilled but editable.** Usually both sides are the same account, but not
                // always.
                InputRow(text: $user, symbol: "person",
                             placeholder: String(localized: "Benutzername"))
                InputRow(text: $password, symbol: "lock", secret: true,
                             placeholder: String(localized: "Passwort"),
                             completion: { Task { await linkUp() } })
                MacAdvanced(rows: $headers)
            }

            if let error = seerr.error {
                Text(verbatim: error)
                    .font(Theme.secondLine)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }

            // No disabled button: while nothing is entered there is nothing to do, and a
            // greyed button suggests otherwise.
            if !address.isEmpty, !user.isEmpty, !password.isEmpty {
                PrimaryButton(label: seerr.reportAn ? "Verbinde…" : "Verbinden",
                           symbol: "link") {
                    guard !seerr.reportAn else { return }
                    Task { await linkUp() }
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

    private func linkUp() async {
        await seerr.linkUp(address: address, user: user, password: password,
                              headers: headers.headers)
        if seerr.connected { password = "" }
    }
}
