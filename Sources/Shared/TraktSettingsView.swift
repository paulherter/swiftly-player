import JellyfinKit
import SwiftUI

/// Connect Trakt: get a code, enter it at Trakt, done.
///
/// **No password, no browser in the app.** For devices Trakt provides the device
/// code: a code is shown here, entered at trakt.tv/activate, and the page notices by
/// itself. On the phone, "Open Trakt" opens the address with the code already in it.
///
/// The same structure as `SeerrSettingsView`: explanation on top, below it
/// either "Connected" or the way there.
struct TraktSettingsView: View {
    let trakt: TraktAccount

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @Environment(\.openURL) private var open

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 0) {
                SubpageHeader(title: String(localized: "Trakt")) { back() }
                ScrollView { content }.scrollIndicators(.hidden)
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        // Whoever leaves the page cancels the polling; otherwise the app would keep asking in the background for ten minutes.
        .onDisappear { trakt.cancel() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Swiftly meldet an Trakt, was du schaust. Ab 80 Prozent steht der Titel dort als gesehen.")
                .growing(15)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, 10)

            if trakt.connected { connectedPart } else { loginPart }

            // **The hint applies to both states.** Whoever is already connected and has the plugin should read here why everything appears twice at Trakt.
            Text("Hat dein Server das Trakt-Plugin, brauchst du das hier nicht. Sonst landet alles doppelt bei Trakt.")
                .growing(12)
                .foregroundStyle(Theme.fontVeryQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, 14)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: Theme.formWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: wide ? .center : .leading)
    }

    // MARK: Connected

    private var connectedPart: some View {
        SettingGroup(title: "Verbunden") {
            ValueRow(symbol: "person",
                      title: Text(verbatim: trakt.user ?? "Trakt"),
                      value: String(localized: "Aktiv"))
            SheetLine()
            // **"Disconnect", not "Sign out"**, as with Seerr. At Trakt the history stays as it is.
            ValueRow(symbol: "xmark.circle", title: Text("Verbindung trennen"),
                      action: { trakt.disconnect() })
        }
        .padding(.top, 26)
    }

    // MARK: Sign in

    @ViewBuilder
    private var loginPart: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch trakt.login {
            case .no:
                Button("Mit Trakt verbinden") { trakt.linkUp() }
                    .buttonStyle(PrimaryButtonStyle())
            case .fetchesCode:
                Text("Hole Code…")
                    .growing(15).foregroundStyle(Theme.fontQuiet)
            case let .code(code, until):
                codePart(code, until: until)
            case let .error(text):
                Text(verbatim: text)
                    .growing(12)
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Neuer Code") { trakt.linkUp() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 20)
            }
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.top, 26)
    }

    private func codePart(_ code: TraktDevicesCode, until: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Geh auf \(code.addressShort) und gib diesen Code ein.")
                .growing(15)
                .foregroundStyle(Theme.font)
                .fixedSize(horizontal: false, vertical: true)

            // The same shape as the code field at Quick Connect: there a code is typed, here it is read off; the same thing.
            Text(verbatim: code.userCode)
                .font(Theme.titleLarge.monospacedDigit())
                .foregroundStyle(Theme.font)
                .textSelection(.enabled)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                .accessibilityLabel(Text("Code"))
                .accessibilityValue(Text(verbatim: code.userCode.map(String.init).joined(separator: " ")))
                .padding(.top, 16)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let rest = max(0, Int(until.timeIntervalSince(context.date)))
                Text("Läuft ab in \(rest / 60):\(String(format: "%02d", rest % 60))")
                    .growing(12)
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
            .padding(.top, 10)

            // With the code in the address: on the phone you are on anyway, nothing has to be typed.
            Button("Trakt öffnen") { open(code.directAddress) }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 20)
        }
    }
}
