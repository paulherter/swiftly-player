import JellyfinKit
import SwiftUI

/// Entry point: enter server, sign in, then the app. Same flow and state holder as
/// on iPhone, with an interface for three metres and the same launch curtain: the
/// mark rises as on iPhone, only larger.
struct RootView: View {
    @State private var model = AppModel.only
    /// The curtain covers everything until the animation is done.
    @State private var started = false
    /// The one-time Discord hint, after the fifth title.
    @State private var discordHint = false

    var body: some View {
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
        }
        .overlay {
            if !started {
                StartCurtain {
                    withAnimation(Theme.motion(.easeOut(duration: 0.45))) { started = true }
                }
            }
        }
        .animation(.default, value: model.phase)
        // Once at the root, not on every tile. A setting decides which tile shows its progress bar, and call sites that pass `progress:` should not need to know. It is read where the bar is made; see `EnvironmentValues.progressOnTiles`.
        .environment(\.progressOnTiles, model.progressOnTiles)
        .environment(\.watchlistShown, model.watchlistShown)
        // No light theme: the design is built for dark, which is the rule on tvOS anyway.
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        // Only once the player is closed. tvOS has no rating prompt; the Discord hint comes once, as a code to scan. Back dismisses it for good.
        .onChange(of: model.discordHintDue && !model.playerOpen) { _, now in
            guard now else { return }
            model.discordHintDue = false
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !model.playerOpen else { model.discordHintDue = true; return }
                discordHint = true
                GiftFlow.shared.noteBigAsk()
            }
        }
        .fullScreenCover(isPresented: $discordHint) {
            CodeSheet(target: .discord) { discordHint = false }
        }
        .tvSupportPresentation(model: model)
        .tvGiftPresentation(model: model)
    }
}

// MARK: - Input field

/// A custom field, literally.
/// On tvOS a `TextField` cannot be tinted: the system draws a white capsule with glow
/// and shadow, and neither `.textFieldStyle(.plain)` nor `.focusEffectDisabled()` removes it.
/// So the real field sits invisibly on top: it takes focus, brings up the system keyboard
/// and holds the text, while only what we draw is visible. It must not go fully to zero
/// opacity, or SwiftUI drops it from the focus chain.
/// `keyboardType` does not exist here (iOS and Catalyst only), so the kind of input is
/// given via `textContentType`.
struct InputField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var safe = false
    var content: UITextContentType?
    /// Focus set from outside. Search needs it: the keyboard should open as soon as the area is open, without first focusing the field.
    var outer: FocusState<Bool>.Binding?
    var completion: () -> Void = {}

    @FocusState private var inner: Bool

    private var bound: FocusState<Bool>.Binding { outer ?? $inner }
    private var focus: Bool { bound.wrappedValue }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(focus ? Color.white : Theme.raised)


            label
                .font(Theme.body)
                .lineLimit(1)
                .padding(.horizontal, 30)

            // Invisible text, visible view. The real field sits behind the styled label. At 2 % opacity
            // its white system-size text still shimmered through; making only the text transparent
            // and keeping the layer opaque showed the background tvOS gives the field as a pill.
            // So both: the layer nearly invisible and the text transparent. It stays focusable, and
            // the visible text comes from `label`.
            inputField
                .foregroundStyle(.clear)
                .tint(.clear)
                .opacity(0.02)
                .padding(.horizontal, 30)
        }
        .frame(height: Theme.buttonHeight)
        .animation(Theme.focusAnimation, value: focus)
    }

    @ViewBuilder
    private var label: some View {
        if text.isEmpty {
            Text(placeholder)
                .foregroundStyle(focus ? Theme.reason.opacity(0.45) : Theme.fontVeryQuiet)
        } else {
            Text(safe ? String(repeating: "\u{2022}", count: text.count) : text)
                .foregroundStyle(focus ? Theme.reason : Theme.font)
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if safe {
            SecureField("", text: $text, onCommit: completion)
                .textContentType(content)
                .focused(bound)
        } else {
            TextField("", text: $text, onCommit: completion)
                .textContentType(content)
                .autocorrectionDisabled()
                .focused(bound)
        }
    }
}

// MARK: - Server

/// First step: where the server is. As on iPhone only the wordmark, no emblem beside it (two marks stacked are one too many), and one sentence instead of heading plus label plus placeholder.
struct ServerView: View {
    let model: AppModel
    @State private var address = ""
    /// "Advanced": custom headers for a service in front of the server.
    @State private var headers: [HeaderRow] = []

    var body: some View {
        VStack(spacing: 0) {
            Wordmark(height: 72)

            Text("Wo steht dein Jellyfin-Server?")
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.top, 56)

            InputField(placeholder: "tv.beispiel.de", text: $address,
                        content: .URL, completion: linkUp)
                .frame(width: 760)
                .padding(.top, 28)

            Text("https:// kannst du weglassen.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .frame(width: 760, alignment: .leading)
                .padding(.top, 12)

            TVAdvanced(rows: $headers)
                .frame(width: 760, alignment: .leading)
                .padding(.top, 24)

            Button(model.phase == .connecting ? "Verbinden…" : "Verbinden",
                   action: linkUp)
                .buttonStyle(ThemedButtonStyle())
                .disabled(address.isEmpty || model.phase == .connecting)
                .padding(.top, 36)

            // No ring replacing the button. It keeps its place and says so in the label; otherwise the page jumps and where you pressed is lost.
            if let error = model.errorMessage, model.phase != .connecting {
                Text(error)
                    .font(Theme.body)
                    // `error`, not `warning`; see `Colors.swift`.
                    .foregroundStyle(Theme.error)
                    .multilineTextAlignment(.center)
                    .frame(width: 900)
                    .padding(.top, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Changing the address during the check cancels it.
        .onChange(of: address) { _, new in model.addressChanged(new) }
    }

    /// Button and the keyboard's send key meet here; a second send during the check is discarded by the model.
    private func linkUp() {
        guard !address.isEmpty else { return }
        model.connectStart(address, headers: headers.headers)
    }
}

// MARK: - Sign-in

/// Second step: user and password.
struct SignInView: View {
    let model: AppModel
    let serverName: String
    let version: String?

    @State private var user = ""
    @State private var passphrase = ""
    @State private var quickConnect = false

    var body: some View {
        VStack(spacing: 0) {
            Wordmark(height: 60)

            Text(serverName)
                .font(Theme.rail)
                .foregroundStyle(Theme.font)
                .padding(.top, 44)

            if let version {
                Text("Jellyfin \(version)")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .padding(.top, 6)
            }

            VStack(spacing: 20) {
                InputField(placeholder: "Benutzername", text: $user,
                            content: .username)
                InputField(placeholder: "Kennwort", text: $passphrase,
                            safe: true, content: .password,
                            completion: signIn)
            }
            .frame(width: 760)
            .padding(.top, 44)

            Button(model.isWorking ? "Anmelden…" : "Anmelden", action: signIn)
                .buttonStyle(ThemedButtonStyle())
                .disabled(user.isEmpty || model.isWorking)
                .padding(.top, 36)

            if let error = model.errorMessage, !model.isWorking {
                Text(error)
                    .font(Theme.body)
                    // `error`, not `warning`; see `Colors.swift`.
                    .foregroundStyle(Theme.error)
                    .multilineTextAlignment(.center)
                    .frame(width: 900)
                    .padding(.top, 32)
            }

            HStack(spacing: 24) {
                // On TV the better way than the password field above, so it sits beside it as an equal, not in a submenu as on iPhone.
                Button("Quick Connect") { quickConnect = true }
                    .buttonStyle(ThemedButtonStyle())
                Button("Anderer Server") { model.signOut() }
                    .buttonStyle(ThemedButtonStyle())
            }
            .padding(.top, 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if quickConnect {
                QuickConnectView(model: model) { quickConnect = false }
                    .transition(.opacity)
            }
        }
        .animation(Theme.motion(.easeInOut(duration: 0.2)), value: quickConnect)
    }

    private func signIn() {
        guard !user.isEmpty else { return }
        Task { await model.login(username: user, password: passphrase) }
    }
}
