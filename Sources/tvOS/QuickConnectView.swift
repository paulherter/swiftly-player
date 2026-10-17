import JellyfinKit
import SwiftUI

/// Sign in without typing a password. On iPhone this is a convenience; on TV it is the better way: typing a password with the remote means swiping letter by letter through a grid. The code is large and in separate fields so it can be read across the room. The flow (fetch code, poll every two seconds, valid five minutes) is in `QuickConnectModel`, shared with iPhone.
struct QuickConnectView: View {
    let model: AppModel
    let close: () -> Void

    @State private var state = QuickConnectModel()

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()

            VStack(spacing: 0) {
                Text("Quick Connect")
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.font)

                Text("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center)
                    .frame(width: 1100)
                    .padding(.top, 16)

                if let preGait = state.preGait {
                    CodeFields(code: preGait.code)
                        .padding(.top, 56)
                    waitRow
                        .padding(.top, 28)
                } else if let error = state.error {
                    Text(error)
                        .font(Theme.body)
                        // `error`, not `warning`: something went wrong, it is not waiting. Same split as on iPhone.
                        .foregroundStyle(Theme.error)
                        .multilineTextAlignment(.center)
                        .frame(width: 1100)
                        .padding(.top, 56)
                } else {
                    // The code arrives shortly; until then its shape stands.
                    LoadField(corner: Theme.corner)
                        .frame(width: 560, height: 120)
                        .padding(.top, 72)
                }

                guide.padding(.top, 56)

                HStack(spacing: 24) {
                    Button("Neuer Code") { Task { await state.newStart(model) } }
                        .buttonStyle(ThemedButtonStyle())
                    Button("Zurück", action: close)
                        .buttonStyle(ThemedButtonStyle())
                }
                .padding(.top, 52)
            }
        }
        .task { await state.newStart(model) }
        .onDisappear { state.halt() }
        .onExitCommand(perform: close)
        .onChange(of: state.released) { _, new in
            guard let new else { return }
            Task {
                await model.signInWithQuickConnect(new)
                // The sheet closes itself. On first sign-in it vanished incidentally because `RootView` swaps the whole screen at `phase == .ready`. Over an already signed-in app that does not happen: the code was approved, the account added, and the page stayed anyway.
                if model.errorMessage == nil { close() }
            }
        }
    }

    private var waitRow: some View {
        HStack(spacing: 14) {
            // No ring: the row beside it already counts down.
            Text("Läuft ab in \(state.secondsLeft / 60):\(String(format: "%02d", state.secondsLeft % 60))")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
        }
    }

    /// Wording taken from the iPhone version so the same instructions do not read differently in two places.
    private var guide: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupsTitle(text: "So gehts")
            step(1, "Jellyfin im Browser öffnen und anmelden")
            step(2, "Oben rechts aufs Profil, dann Quick Connect")
            step(3, "Code eingeben, dann geht es hier von selbst weiter")
        }
        .frame(width: 900, alignment: .leading)
    }

    private func step(_ figure: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Text("\(figure)")
                .foregroundStyle(Theme.fontVeryQuiet)
                .frame(width: 32, alignment: .leading)
            Text(text)
                .foregroundStyle(Theme.fontQuiet)
        }
        .font(Theme.tile)
    }
}
