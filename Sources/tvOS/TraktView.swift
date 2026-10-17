import JellyfinKit
import SwiftUI

/// Connect Trakt, the TV version. The device code is at home here: typing a password with the remote is a burden, and Trakt provides exactly this path for TVs. The code is large in fields as in Quick Connect, with the address to type beside it and a QR code that carries both to a phone. It is its own page over everything, like `SeerrConnectView`, and fetches the code itself on open since whoever is here wants to connect.
struct TraktConnectView: View {
    let trakt: TraktAccount
    let close: () -> Void

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()

            VStack(spacing: 0) {
                Text(verbatim: "Trakt")
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.font)

                Text("Swiftly meldet an Trakt, was du schaust. Ab 80 Prozent steht der Titel dort als gesehen.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center)
                    .frame(width: 1100)
                    .padding(.top, 16)

                if trakt.connected { connected } else { login }

                Text("Hat dein Server das Trakt-Plugin, brauchst du das hier nicht. Sonst landet alles doppelt bei Trakt.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .multilineTextAlignment(.center)
                    .frame(width: 1100)
                    .padding(.top, 40)
            }
        }
        .task { if !trakt.connected, trakt.login == .no { trakt.linkUp() } }
        .onDisappear { trakt.cancel() }
        .onExitCommand(perform: close)
    }

    // MARK: Connected

    private var connected: some View {
        VStack(spacing: 18) {
            Text(verbatim: trakt.user ?? "Trakt")
                .font(Theme.body).foregroundStyle(Theme.font)
            Text("Aktiv")
                .font(Theme.small).foregroundStyle(Theme.fontQuiet)
            HStack(spacing: 24) {
                // "Disconnect", not "sign out", as with Seerr.
                Button("Verbindung trennen") { trakt.disconnect() }
                    .buttonStyle(ThemedButtonStyle())
                Button("Fertig", action: close)
                    .buttonStyle(ThemedButtonStyle())
            }
            .padding(.top, 26)
        }
        .padding(.top, 56)
    }

    // MARK: Sign-in

    @ViewBuilder
    private var login: some View {
        switch trakt.login {
        case let .code(code, until):
            codePart(code, until: until)
        case let .error(text):
            Text(verbatim: text)
                .font(Theme.body)
                .foregroundStyle(Theme.error)
                .multilineTextAlignment(.center)
                .frame(width: 1100)
                .padding(.top, 56)
            buttons
        case .no, .fetchesCode:
            // The code arrives shortly; until then its shape stands.
            LoadField(corner: Theme.corner)
                .frame(width: 560, height: 120)
                .padding(.top, 72)
            buttons
        }
    }

    private func codePart(_ code: TraktDevicesCode, until: Date) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 56) {
                if let image = CodeSheet.code(code.directAddress) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 240, height: 240)
                        // The white border belongs to the code; see `CodeSheet`.
                        .padding(18)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 20) {
                    Text("Geh auf \(code.addressShort) und gib diesen Code ein.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.font)
                    CodeFields(code: code.userCode)
                        // Eight characters instead of six: one step smaller so the fields fit beside the QR code.
                        .scaleEffect(0.8, anchor: .leading)
                        .frame(height: 128, alignment: .leading)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let rest = max(0, Int(until.timeIntervalSince(context.date)))
                        Text("Läuft ab in \(rest / 60):\(String(format: "%02d", rest % 60))")
                            .font(Theme.small)
                            .foregroundStyle(Theme.fontVeryQuiet)
                    }
                }
            }
            .padding(.top, 56)
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: 24) {
            Button("Neuer Code") { trakt.linkUp() }
                .buttonStyle(ThemedButtonStyle())
            Button("Zurück", action: close)
                .buttonStyle(ThemedButtonStyle())
        }
        .padding(.top, 52)
    }
}
