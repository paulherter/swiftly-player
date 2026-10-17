import JellyfinKit
import SwiftUI

/// **"Advanced" on the TV**: custom headers for a service in front of the server (issue
/// #4). The template is `Shared/AdvancedSection.swift`; this has the same rows
/// (``Kopfzeile``) with the TV's fields and buttons. Collapsed and empty by default so
/// nothing changes for anyone else. The value is hidden like a password.
struct TVAdvanced: View {
    @Binding var rows: [HeaderRow]
    var expanded = false

    @State private var opened = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !expanded {
                Button {
                    withAnimation(Theme.reveal) { opened.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        Text("Erweitert")
                        Image(systemName: opened ? "chevron.down" : "chevron.right")
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(ThemedButtonStyle())
            }
            if opened || expanded { content }
        }
        .onAppear { if !rows.isEmpty { opened = true } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Für einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 20) {
                        InputField(placeholder: "Header-Name", text: $row.name)
                        InputField(placeholder: "Wert", text: $row.value, safe: true)
                        Button {
                            rows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(ThemedButtonStyle(onlySymbol: true))
                        .accessibilityLabel(Text("Entfernen"))
                    }
                    if row.locked {
                        Text("Den setzt Swiftly selbst.")
                            .font(Theme.small)
                            .foregroundStyle(Theme.warning)
                    }
                }
            }

            Button {
                rows.append(HeaderRow())
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                    Text("Header hinzufügen")
                }
            }
            .buttonStyle(ThemedButtonStyle())
        }
    }
}

/// Edit the active server's custom headers, from Profile > Server.
struct TVOwnHeadersPage: View {
    let model: AppModel
    let close: () -> Void

    @State private var rows: [HeaderRow] = []
    @State private var secured: [OwnHeader] = []

    private var server: URL? { model.session?.serverURL }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.reason.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Eigene Header")
                        .font(Theme.titleLarge)
                        .foregroundStyle(Theme.font)
                    TVAdvanced(rows: $rows, expanded: true)
                        .padding(.top, 44)
                    HStack(spacing: 20) {
                        if rows.headers != secured {
                            Button("Sichern") {
                                guard let server else { return }
                                model.ownHeadersSafe(rows.headers, for: server)
                                secured = model.ownHeaders(for: server)
                                close()
                            }
                            .buttonStyle(ThemedButtonStyle())
                        }
                        Button(rows.headers != secured ? "Abbrechen" : "Fertig", action: close)
                            .buttonStyle(ThemedButtonStyle())
                    }
                    .padding(.top, 44)
                }
                .frame(width: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
            }
        }
        .onAppear {
            secured = model.ownHeaders(for: server)
            rows = HeaderRow.from(secured)
        }
    }
}
