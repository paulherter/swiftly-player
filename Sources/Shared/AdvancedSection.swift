import JellyfinKit
import SwiftUI

/// **"Advanced": custom headers for a service in front of the server.**
///
/// Cloudflare Access, Authelia, Authentik, Pangolin: whoever secures
/// Jellyfin or Seerr this way lets the app through only with certain
/// headers (issue #4). Everyone else never needs this, so it is
/// **collapsed and empty**, and for whoever does not open it nothing
/// changes.
///
/// The values are credentials and are treated like a password: entered
/// obscured (`secret`), stored in the keychain, never logged.
///
/// On iPhone and iPad. Mac and TV have their own version with their own
/// fields (`MacAdvanced`, `TVAdvanced`), the same row below:
/// ``Kopfzeile``.
struct AdvancedSection: View {
    @Binding var rows: [HeaderRow]
    /// On its own page in settings there is nothing to expand.
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
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(opened ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontQuiet)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .accessibilityHint(opened ? Text("Zuklappen") : Text("Aufklappen"))
            }

            if opened || expanded { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Whoever has already entered headers should see them.
        .onAppear { if !rows.isEmpty { opened = true } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Für einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        InputField(text: $row.name, symbol: "tag",
                                    placeholder: "Header-Name")
                        Button {
                            withAnimation(Theme.reveal) { rows.removeAll { $0.id == row.id } }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.fontVeryQuiet)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(Theme.PressButton())
                        .accessibilityLabel(Text("Entfernen"))
                    }
                    InputField(text: $row.value, symbol: "key", placeholder: "Wert",
                                secret: true)
                        .padding(.trailing, 52)
                    if row.locked {
                        Text("Den setzt Swiftly selbst.")
                            .font(Theme.small)
                            .foregroundStyle(Theme.warning)
                    }
                }
                .padding(.top, 4)
            }

            Button {
                withAnimation(Theme.reveal) { rows.append(HeaderRow()) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                    Text("Header hinzufügen")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.top, 4)
        }
    }
}

/// **The custom headers of the server the app is currently attached to.**
///
/// Editing after sign-in: from Settings, Server. Saving applies
/// immediately to every further request, including images and downloads.
struct OwnHeadersPage: View {
    let model: AppModel

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var rows: [HeaderRow] = []
    @State private var secured: [OwnHeader] = []

    private var server: URL? { model.session?.serverURL }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 0) {
                SubpageHeader(title: String(localized: "Eigene Header")) { back() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        AdvancedSection(rows: $rows, expanded: true)
                            .padding(.top, 10)
                        if rows.headers != secured {
                            Button("Sichern") {
                                guard let server else { return }
                                model.ownHeadersSafe(rows.headers, for: server)
                                secured = model.ownHeaders(for: server)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .padding(.top, 22)
                        }
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.bottom, 40)
                    .frame(maxWidth: Theme.formWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: wide ? .center : .leading)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .onAppear {
            secured = model.ownHeaders(for: server)
            rows = HeaderRow.from(secured)
        }
    }
}
