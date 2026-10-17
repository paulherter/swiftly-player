import JellyfinKit
import SwiftUI

/// Connect Seerr: address, name, password.
///
/// **The name is already filled in.** It is the same account on both sides;
/// Seerr asks Jellyfin itself whether name and password are right. So only what
/// we do not have is typed: the password. And it is not stored: only the session
/// Seerr issues in response is saved.
struct SeerrSettingsView: View {
    let model: AppModel
    let seerr: SeerrModel

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    /// "Advanced": custom headers for a service in front of Seerr.
    @State private var headers: [HeaderRow] = []

    var body: some View {
        ZStack(alignment: .top) {
            // The same background as every other page. It was briefly a separate one
            // (`gruppengrund`) because pure black under a card was the whole jump at once;
            // since the background is #101010 the jump is a fifth of that and needs no
            // exception.
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 0) {
                // Title next to the arrow, not below it; see `SettingsView`.
                SubpageHeader(title: String(localized: "Seerr")) { back() }
                ScrollView { content }.scrollIndicators(.hidden)
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task {
            if user.isEmpty { user = model.session?.userName ?? "" }
            await seerr.lookUp()
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

    private var connectedPart: some View {
        SettingGroup(title: "Verbunden") {
            ValueRow(symbol: "link", title: Text(verbatim: seerr.address ?? ""),
                      value: seerr.carries ? String(localized: "Aktiv")
                                         : String(localized: "Sitzung abgelaufen"))
            SheetLine()
            // **Not "Sign out" but "Disconnect".** On Seerr's side everything stays as it
            // is; only this one access here is affected.
            ValueRow(symbol: "xmark.circle", title: Text("Verbindung trennen"),
                      action: { seerr.disconnect(); address = ""; password = "" })
        }
        .padding(.top, 26)
    }

    // MARK: Formular

    private var formSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // The address is the only detail that is really new.
                InputField(text: $address, symbol: "link",
                            placeholder: "seerr.example.de", keyboard: .address)
                // **Prefilled, but editable.** It is usually the same account on both sides,
                // which is why the name is already there. Usually is not always: whoever signs in
                // to Seerr under a different name must be able to overwrite it.
                InputField(text: $user, symbol: "person",
                            placeholder: "Benutzername")
                InputField(text: $password, symbol: "lock",
                            placeholder: "Passwort", secret: true)
                AdvancedSection(rows: $headers)
            }
            .padding(.horizontal, Theme.margin(wide: wide))

            if let error = seerr.error {
                Text(verbatim: error)
                    .growing(12)
                    // The login failed, it is not waiting: `error`. Server sign-in does the same.
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 14)
            }

            // No disabled button: while nothing is entered there is nothing to do, and a
            // gray button claims the opposite.
            if !address.isEmpty, !user.isEmpty, !password.isEmpty, !seerr.reportAn {
                // **The same button as everywhere, not the third copy.** It stood here at 15
                // instead of 16 pt, padding 13 instead of height 48 and corner 10 instead of 6,
                // the same kind of deviation as on the request button, one page over.
                Button("Verbinden") { Task { await linkUp() } }
                    .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, 20)
            } else if seerr.reportAn {
                Text("Verbinde…")
                    .growing(15).foregroundStyle(Theme.fontQuiet)
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

    private func linkUp() async {
        await seerr.linkUp(address: address, user: user, password: password,
                              headers: headers.headers)
        if seerr.connected { password = "" }
    }
}
