import JellyfinKit
import SwiftUI

/// Connect Trakt, Mac version.
///
/// Same flow as on iPhone (`Shared/TraktSettingsView`): fetch a code, enter it
/// at Trakt, the page notices on its own. "Open Trakt" opens the browser with the
/// code already in the address.
///
/// Same layout as `SeerrSettingsView` on the Mac: header, explanation, then
/// "Connected" or the way there.
struct TraktSettingsView: View {
    let trakt: TraktAccount
    let back: () -> Void

    @Environment(\.openURL) private var open

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: "Trakt", back: back)

                Text("Swiftly meldet an Trakt, was du schaust. Ab 80 Prozent steht der Titel dort als gesehen.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                if trakt.connected { connected } else { login }

                Text("Hat dein Server das Trakt-Plugin, brauchst du das hier nicht. Sonst landet alles doppelt bei Trakt.")
                    .font(Theme.secondLine)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            .frame(maxWidth: Theme.formWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .pagesScroll()
        .onDisappear { trakt.cancel() }
    }

    private var connected: some View {
        SettingGroup(title: "Verbunden") {
            ValuesRow(symbol: "person",
                       title: Text(verbatim: trakt.user ?? "Trakt"),
                       value: String(localized: "Aktiv"))
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            // **"Disconnect", not "Sign out"**, as with Seerr.
            ValuesRow(symbol: "xmark.circle", title: Text("Verbindung trennen"),
                       action: { trakt.disconnect() })
        }
        .padding(.top, 26)
    }

    @ViewBuilder
    private var login: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch trakt.login {
            case .no:
                PrimaryButton(label: "Mit Trakt verbinden", symbol: "link") { trakt.linkUp() }
            case .fetchesCode:
                Text("Hole Code…")
                    .font(Theme.body).foregroundStyle(Theme.fontQuiet)
            case let .code(code, until):
                codePart(code, until: until)
            case let .error(text):
                Text(verbatim: text)
                    .font(Theme.secondLine)
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton(label: "Neuer Code", symbol: "arrow.clockwise") { trakt.linkUp() }
                    .padding(.top, 20)
            }
        }
        .padding(.top, 26)
    }

    private func codePart(_ code: TraktDevicesCode, until: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Geh auf \(code.addressShort) und gib diesen Code ein.")
                .font(Theme.body)
                .foregroundStyle(Theme.font)
                .fixedSize(horizontal: false, vertical: true)

            // Same shape as on iPhone: one field area, the code in the largest size,
            // selectable for copying.
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
                    .font(Theme.secondLine)
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
            .padding(.top, 10)

            PrimaryButton(label: "Trakt öffnen", symbol: "safari") { open(code.directAddress) }
                .padding(.top, 20)
        }
    }
}
