import JellyfinKit
import StoreKit
import SwiftUI

/// The same three states as on iPhone and TV, from the same `AppModel`. Only the
/// views behind them are specific to the Mac.
///
/// **With launch curtain.** `StartAnimation.swift` has an AppKit variant, so the
/// mark animates in the same way on all four platforms.
struct RootView: View {
    @State private var model = AppModel.only
    @State private var curtainShown = true
    /// Apple's review prompt; `Community.kickoff` decides when.
    @Environment(\.requestReview) private var rate
    @State private var discordHint = false

    var body: some View {
        #if DEBUG
        // The halving: a bare scroll surface instead of the app when the environment
        // asks for it. See `BareSame`.
        if BareSame.demanded {
            BareSame()
        } else {
            shell
        }
        #else
        shell
        #endif
    }

    private var shell: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()
            switch model.phase {
            case .disconnected, .connecting:
                ServerView(model: model)
            case let .needsLogin(serverName, version):
                SignInView(model: model, serverName: serverName, version: version)
            case .ready:
                MainView(model: model)
            }

            if curtainShown {
                StartCurtain { withAnimation(.easeOut(duration: 0.35)) { curtainShown = false } }
            }
        }
        .background(WindowLine())
        #if DEBUG
        // Logs the frame cadence, development builds only, see `FrameTick`. A view with
        // no size that draws nothing.
        .background(ImageTickMeasure().frame(width: 0, height: 0))
        #endif
        .animation(Theme.timePage, value: model.phase)
        .macSupportPresentation(model: model)
        // The Halloween gift and "What's new": one sheet, as on iPhone (`GiftFlow`).
        .giftPresentation(model: model)
        // **Once at the root, not on every tile.** A setting decides which tile shows its
        // progress bar, and call sites that pass `progress:` along should not need to
        // know. It is read where the bar is created. See
        // `EnvironmentValues.progressOnTiles`.
        .environment(\.progressOnTiles, model.progressOnTiles)
        // **Only once the player is closed, with a short pause**, as on iPhone. An
        // episode change counts as the player being open.
        .onChange(of: model.ratingDue && !model.playerOpen) { _, now in
            guard now else { return }
            model.ratingDue = false
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !model.playerOpen else { model.ratingDue = true; return }
                // One big ask per session: after the gift or What's New, not this time.
                guard !GiftFlow.shared.bigAskShown else { return }
                GiftFlow.shared.noteBigAsk()
                rate()
            }
        }
        .onChange(of: model.discordHintDue && !model.playerOpen) { _, now in
            guard now else { return }
            model.discordHintDue = false
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !model.playerOpen else { model.discordHintDue = true; return }
                guard !GiftFlow.shared.bigAskShown else { return }
                GiftFlow.shared.noteBigAsk()
                withAnimation(Theme.leap) { discordHint = true }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if discordHint {
                DiscordHint { withAnimation(Theme.leap) { discordHint = false } }
                    .padding(Theme.edgeSpacing)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}

/// **Once per installation: a Discord invite.**
///
/// Shown after the fifth finished title (`Community.kickoff`), when the player
/// is closed. A card at the bottom right instead of a window: it covers nothing,
/// and the close button dismisses it for good.
struct DiscordHint: View {
    let close: () -> Void
    @Environment(\.openURL) private var open

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Swiftly hat einen Discord")
                    .font(Theme.listTitle)
                    .foregroundStyle(Theme.font)
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(Theme.small.weight(.semibold))
                        .foregroundStyle(Theme.fontQuiet)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .accessibilityLabel(Text("Schließen"))
            }
            Text("Da kannst du Fragen stellen und Fehler melden. Neue Builds stehen da auch zuerst.")
                .font(Theme.secondLine)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(label: "Discord beitreten", symbol: "bubble.left.and.bubble.right") {
                open(Community.discord)
                close()
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        // No shadow anywhere.
        .background {
            let form = RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous)
            form.fill(Theme.raised).overlay { form.strokeBorder(Theme.margin, lineWidth: 1) }
        }
    }
}

// MARK: - Enter server

/// Where the server is. One sentence, one field, one button, as on iPhone but
/// centred in the window instead of at the top of the screen.
struct ServerView: View {
    let model: AppModel
    @State private var address = ""
    /// "Advanced": custom headers for a service in front of the server.
    @State private var headers: [HeaderRow] = []
    @FocusState private var inField: Bool

    var body: some View {
        VStack(spacing: 0) {
            Wordmark(height: 44)

            Text("Wo steht dein Jellyfin-Server?")
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.top, 40)

            InputRow(text: $address, symbol: "globe",
                         placeholder: "tv.beispiel.de", completion: linkUp)
                .frame(width: Theme.formWidth)
                .padding(.top, 24)
                .focused($inField)

            MacAdvanced(rows: $headers)
                .frame(width: Theme.formWidth)
                .padding(.top, 10)

            if let error = model.errorMessage {
                Text(error)
                    .font(Theme.secondLine)
                    .foregroundStyle(Theme.warning)
                    .multilineTextAlignment(.center)
                    .frame(width: Theme.formWidth)
                    .padding(.top, 12)
            }

            // The label says that a check is running, as on iPhone.
            PrimaryButton(label: model.phase == .connecting ? "Verbinden…" : "Verbinden",
                       symbol: "arrow.right", pick: linkUp)
                .padding(.top, 24)
                .disabled(address.isEmpty || model.isWorking || model.phase == .connecting)
                .opacity(address.isEmpty ? 0.4 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { inField = true }
        // Changing the address during the check cancels it.
        .onChange(of: address) { _, new in model.addressChanged(new) }
    }

    /// The button and the keyboard's submit key meet here; a second submit during the
    /// check discards the model.
    private func linkUp() {
        guard !address.isEmpty else { return }
        model.connectStart(address, headers: headers.headers)
    }
}

// MARK: - Sign in

struct SignInView: View {
    let model: AppModel
    let serverName: String
    let version: String

    @State private var user = ""
    @State private var passphrase = ""
    @FocusState private var inputField: Field?

    private enum Field { case user, passphrase }

    var body: some View {
        VStack(spacing: 0) {
            Wordmark(height: 44)

            Text(serverName)
                .font(Theme.subpageTitle).tracking(Theme.lockSubpage)
                .foregroundStyle(Theme.font)
                .padding(.top, 34)
            Text(verbatim: "Jellyfin \(version)")
                .font(Theme.secondLine)
                .foregroundStyle(Theme.fontVeryQuiet)
                .padding(.top, 4)

            InputRow(text: $user, symbol: "person",
                         placeholder: String(localized: "Benutzername")) { inputField = .passphrase }
                .frame(width: Theme.formWidth)
                .padding(.top, 28)
                .focused($inputField, equals: .user)

            InputRow(text: $passphrase, symbol: "lock", secret: true,
                         placeholder: String(localized: "Passwort"), completion: signIn)
                .frame(width: Theme.formWidth)
                .padding(.top, 10)
                .focused($inputField, equals: .passphrase)

            if let error = model.errorMessage {
                Text(error)
                    .font(Theme.secondLine)
                    .foregroundStyle(Theme.warning)
                    .multilineTextAlignment(.center)
                    .frame(width: Theme.formWidth)
                    .padding(.top, 12)
            }

            PrimaryButton(label: "Anmelden", symbol: "arrow.right",
                       pick: signIn)
                .padding(.top, 24)
                .disabled(user.isEmpty || model.isWorking)
                .opacity(user.isEmpty ? 0.4 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { inputField = .user }
    }

    private func signIn() {
        guard !user.isEmpty else { return }
        Task { await model.login(username: user, password: passphrase) }
    }
}

// MARK: - Input field

/// A custom field instead of `TextField` with the system frame, which brings a
/// light surface and its own corner on the Mac. The border is a hairline at white
/// 12 %, corner radius 10, the same values as on iPhone.
struct InputRow: View {
    @Binding var text: String
    let symbol: String
    var secret = false
    let placeholder: String
    var completion: () -> Void = {}

    @FocusState private var inside: Bool

    var body: some View {
        HStack(spacing: 9) {
            // Character 17 in a 20-wide column.
            Image(systemName: symbol)
                .font(Theme.categoryLarge.weight(.regular))
                .foregroundStyle(Theme.fontVeryQuiet)
                .frame(width: 20)
                .accessibilityHidden(true)

            Group {
                if secret {
                    SecureField("", text: $text, prompt: slot)
                } else {
                    TextField("", text: $text, prompt: slot)
                }
            }
            .textFieldStyle(.plain)
            .font(Theme.body)
            .foregroundStyle(Theme.font)
            .focused($inside)
            .onSubmit(completion)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.area,
                    in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
        // **No focus ring.** An accent border at 50 % opacity made focus depend on colour
        // alone. Instead the stroke width shows where you are typing: 2 instead of 1,
        // same colour.
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous)
            .strokeBorder(Theme.margin, lineWidth: inside ? 2 : 1))
        .animation(Theme.timeFloat, value: inside)
    }

    private var slot: Text {
        Text(verbatim: placeholder).foregroundColor(Theme.fontVeryQuiet)
    }
}
