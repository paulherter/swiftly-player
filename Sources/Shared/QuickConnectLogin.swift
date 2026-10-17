import JellyfinKit
import SwiftUI

/// Sign in without typing a password.
///
/// The counterpart of the Quick Connect page in the profile: there this device
/// authorizes someone else's code, here it gets authorized itself. The code is
/// all that matters, so it is large and split into single fields to avoid
/// miscounting when typing it.
struct QuickConnectLogin: View {
    let model: AppModel
    /// On the server currently being added. `done` then reports that the
    /// sign-in there succeeded.
    var newServer = false
    var done: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    /// The flow lives in `QuickConnectModel`, shared with the tvOS version.
    @State private var state = QuickConnectModel()

    /// **The only page of this version that did not read it.**
    /// A fixed inner padding of 28 and full width: on iPad the explanatory text
    /// was over 1036 points wide, about 140 characters per line.
    @Environment(\.wide) private var wide

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Title next to the arrow, like the other menus.
                    SubpageHeader(title: String(localized: "Quick Connect")) { dismiss() }
                        .padding(.horizontal, -Theme.margin(wide: wide))

                    Text("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineSpacing(3)
                        .padding(.top, 10)

                    if let preGait = state.preGait {
                        // A tap copies the code to the clipboard; it is usually pasted right
                        // next to it.
                        codeFields(preGait.code)
                            .copyable(preGait.code)
                        waitRow
                    } else if let error = state.error {
                        Text(error)
                            .font(Theme.body)
                            // `error`, not `warning`: the code could not be created. `warning` means
                            // "something is waiting for someone", and nothing is waiting anymore.
                            .foregroundStyle(Theme.error)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        // The code arrives shortly; until then its shape is shown.
                        LoadField(corner: Theme.cornerField)
                            .frame(height: 60)
                            .frame(maxWidth: 260)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }

                    guide
                }
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.bottom, 40)
                // Same measure as sign-in and server.
                .frame(maxWidth: Theme.formWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(.top, 8, for: .scrollContent)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Neuen Code holen") { Task { await newStart() } }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.horizontal, Theme.margin(wide: wide))
                .frame(maxWidth: Theme.formWidth)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .task {
            state.newServer = newServer
            await newStart()
        }
        .onDisappear { state.halt() }
        .onChange(of: state.released) { _, new in
            guard let new else { return }
            dismiss()
            Task {
                if newServer {
                    if await model.signInWithQuickConnectAtNewServer(new) { done() }
                } else {
                    await model.signInWithQuickConnect(new)
                }
            }
        }
    }

    /// Single fields instead of one string: nobody reads six digits in a row off
    /// a screen without errors.
    private func codeFields(_ code: String) -> some View {
        let symbolText = Array(code)
        return HStack(spacing: 8) {
            ForEach(Array(symbolText.enumerated()), id: \.offset) { pair in
                if pair.offset == symbolText.count / 2 {
                    Color.clear.frame(width: 6)
                }
                Text(String(pair.element))
                    // The size comes from the type ladder, the weight does not: 28 is the page
                    // title step, and bold appears exactly once, on the title. The code is the
                    // main thing on the page but not a title.
                    .font(Theme.titleLarge)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(Theme.font)
                    .frame(width: 46, height: 60)
                    .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 34)
    }

    /// Without the remaining time nobody knows whether anything is still
    /// happening.
    private var waitRow: some View {
        HStack(spacing: 9) {
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
            Text("Warte auf Freigabe · noch \(state.secondsLeft / 60):\(String(format: "%02d", state.secondsLeft % 60))")
                // 12 regular from the ladder; 13 regular is not on it.
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 0) {
            SeparatorLine()
            GroupsTitle(text: "So gehts")
            step(1, "Jellyfin im Browser öffnen und anmelden")
            step(2, "Oben rechts aufs Profil, dann Quick Connect")
            step(3, "Code eingeben, dann geht es hier von selbst weiter")
        }
        .padding(.top, 38)
    }

    private func step(_ figure: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(figure)")
                // 12 regular from the ladder, like the step line next to it.
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .frame(width: 20, alignment: .leading)
            Text(text)
                // 12 regular from the ladder.
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)
                .lineSpacing(2)
        }
        .padding(.top, 10)
    }

    // MARK: - Flow

    /// Close first, then sign in: signing in swaps out the whole view, and a
    /// cover lying over a swapped view flashes.
    private func newStart() async {
        await state.newStart(model)
    }
}
