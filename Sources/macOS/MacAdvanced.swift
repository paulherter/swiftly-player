import JellyfinKit
import SwiftUI

/// **"Advanced" on the Mac**: custom headers for a service in front of the server
/// (issue #4). Template is `Shared/AdvancedSection.swift`; same rows (`Kopfzeile`)
/// with the Mac's `Eingabezeile`. Collapsed and empty by default so nothing changes
/// for anyone else. The value is hidden like a password.
struct MacAdvanced: View {
    @Binding var rows: [HeaderRow]
    var expanded = false

    @State private var opened = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !expanded {
                Button {
                    withAnimation(Theme.reveal) { opened.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Erweitert")
                        Image(systemName: "chevron.right")
                            .font(Theme.badge)
                            .rotationEffect(.degrees(opened ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .font(Theme.secondLine)
                    .foregroundStyle(Theme.fontQuiet)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
            }
            if opened || expanded { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if !rows.isEmpty { opened = true } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Für einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse.")
                .font(Theme.secondLine)
                .foregroundStyle(Theme.fontVeryQuiet)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        InputRow(text: $row.name, symbol: "tag",
                                     placeholder: String(localized: "Header-Name"))
                        InputRow(text: $row.value, symbol: "key", secret: true,
                                     placeholder: String(localized: "Wert"))
                        Button {
                            rows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(Theme.body)
                                .foregroundStyle(Theme.fontVeryQuiet)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(Theme.PressButton())
                        .help(Text("Entfernen"))
                        .accessibilityLabel(Text("Entfernen"))
                    }
                    if row.locked {
                        Text("Den setzt Swiftly selbst.")
                            .font(Theme.secondLine)
                            .foregroundStyle(Theme.warning)
                    }
                }
            }

            Button {
                rows.append(HeaderRow())
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                    Text("Header hinzufügen")
                }
                .font(Theme.secondLine)
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressButton())
        }
    }
}

/// Custom headers of the active server, in Settings under the "Server" group.
/// **No page of its own on the Mac:** the window has the room, and a subpage for
/// two fields would be an extra step.
struct MacOwnHeaders: View {
    let model: AppModel

    @State private var rows: [HeaderRow] = []
    @State private var secured: [OwnHeader] = []

    private var server: URL? { model.session?.serverURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacAdvanced(rows: $rows)
            if rows.headers != secured {
                PrimaryButton(label: "Sichern", symbol: "checkmark") {
                    guard let server else { return }
                    model.ownHeadersSafe(rows.headers, for: server)
                    secured = model.ownHeaders(for: server)
                }
                .padding(.top, 14)
            }
        }
        .padding(.top, 14)
        .onAppear {
            secured = model.ownHeaders(for: server)
            rows = HeaderRow.from(secured)
        }
    }
}
