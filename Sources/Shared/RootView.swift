import JellyfinKit
import StoreKit
import SwiftUI

struct RootView: View {
    @State private var model = AppModel.only
    /// The curtain covers everything until the animation is done.
    @State private var started = false
    #if os(iOS)
    /// Apple's own rating prompt. When it appears is decided by
    /// `RatingQuestion` in the package; Apple shows it at most three times a
    /// year.
    @Environment(\.requestReview) private var rate
    #endif
    /// The one-time hint to the Discord, after the fifth title.
    @State private var discordSheet = false

    /// Read only here. Views query `\.wide` so the rule lives in one place
    /// and not in every view.
    @Environment(\.horizontalSizeClass) private var widthClass

    private var wide: Bool { widthClass == .regular && Theme.atPad }

    /// Measured window width. The size class alone says nothing about whether
    /// a button row fits side by side.
    @State private var windowWidthValue: CGFloat = 0


    /// The app shares the screen: iPadOS' traffic lights then lie on our top
    /// left corner. See `WindowButtons`.
    private var inWindow: Bool {
        WindowButtons.inWindow(windowWidthValue: windowWidthValue)
    }

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()
            switch model.phase {
            case .disconnected, .connecting:
                ConnectView(model: model)
            case let .needsLogin(serverName, version):
                LoginView(model: model, serverName: serverName, version: version)
            case .ready:
                MainView(model: model)
            }
        }
        // **Once at the root, not on every tile.** A setting decides which tile
        // shows its progress bar, and the 33 call sites passing `progress:`
        // through should not have to know about it. It is read where the bar is
        // created. See `EnvironmentValues.progressOnTiles`.
        .environment(\.progressOnTiles, model.progressOnTiles)
        #if os(iOS)
        // **Only after the player, and with a beat of delay.** The prompt comes
        // when someone has just finished watching something, not in the middle
        // of playback and not at launch.
        //
        // **Only once the player is closed.** Switching to the next episode
        // counts the title while the player stays open; before, the prompt then
        // appeared 1.5 s later over the running episode.
        .onChange(of: model.ratingDue && !model.playerOpen) { _, now in
            guard now else { return }
            model.ratingDue = false
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !model.playerOpen else { model.ratingDue = true; return }
                rate()
            }
        }
        #endif
        .onChange(of: model.discordHintDue && !model.playerOpen) { _, now in
            guard now else { return }
            model.discordHintDue = false
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !model.playerOpen else { model.discordHintDue = true; return }
                discordSheet = true
            }
        }
        .overlay { DiscordHint(opened: $discordSheet) }
        .overlay {
            #if os(iOS)
            if !started {
                StartCurtain {
                    // 0.28 from `Theme.einblenden` instead of its own 0.45: the curtain lifts
                    // like any other content that is there, one duration, not two.
                    withAnimation(Theme.reveal) { started = true }
                }
            }
            #endif
        }
        // Connect, sign in, main view is a change of area, not a system default.
        // `.default` was the last motion in the app without a token; now the
        // same curve as every tab switch.
        .animation(Theme.sectionSwitch, value: model.phase)
        // Cap for the type size.
        //
        // The design is built on fixed point dimensions: tiles 112 x 168, bar 54,
        // buttons 44. The top steps of the system setting (up to "AX5") triple
        // the type, which breaks each of these heights. Everything up to
        // `accessibility1` is supported; above that only a rework of every fixed
        // height would help, which is a project of its own.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // There is no light theme: the design is built for dark.
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
            windowWidthValue = new
        }
        .environment(\.wide, wide)
        .environment(\.broad, wide && windowWidthValue >= Theme.landscapeHeaderOffWidth)
        .environment(\.windowButtons, inWindow)
    }
}

// MARK: - Enter server

/// First step: where the server is.
///
/// Deliberately only the wordmark, no logo beside it: two marks stacked
/// are one too many. And no heading plus label plus placeholder: saying
/// the same thing three times was the earlier mistake, one sentence is
/// enough.
struct ConnectView: View {
    let model: AppModel
    @State private var address = ""
    /// "Advanced": custom headers for a service in front of the server.
    @State private var headers: [HeaderRow] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Wordmark(height: 40)
                    .padding(.top, 172)

                Text("Wo steht dein Jellyfin-Server?")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .padding(.top, 44)

                InputField(text: $address, symbol: "globe",
                            placeholder: "tv.beispiel.de", keyboard: .address,
                            completion: linkUp)
                    .padding(.top, 18)

                Text("https:// kannst du weglassen.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 9)
                    .padding(.leading, 2)

                AdvancedSection(rows: $headers)
                    .padding(.top, 6)

                // **The button stays and says what is running.** Here it swapped for a
                // spinner: the page jumped and where you had pressed was gone.
                do {
                    Button(model.phase == .connecting ? "Verbinden…" : "Verbinden",
                           action: linkUp)
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, 22)
                        .disabled(address.isEmpty || model.phase == .connecting)
                        .opacity(address.isEmpty ? 0.4 : 1)
                }

                if let error = model.errorMessage {
                    // The error appears under the field that caused it, not at the end of the
                    // page.
                    // **`error`, not `warning`.** A rejected sign-in went wrong; it is not
                    // waiting for someone, and both carried the same color.
                    Text(error)
                        .font(Theme.small)
                        .foregroundStyle(Theme.error)
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                }

                if let last = model.lastServer, last.address != address {
                    recent(last)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            // Otherwise the field stretches across the whole iPad width.
            .frame(maxWidth: Theme.formWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { if address.isEmpty { address = model.lastServer?.address ?? "" } }
        // Changing the address during the check cancels it.
        .onChange(of: address) { _, new in model.addressChanged(new) }
    }

    /// The second time nobody types the address again.
    private func recent(_ last: ServerReminder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupsTitle(text: "Zuletzt verbunden")
            SeparatorLine()
            Button {
                address = last.address
                linkUp()
            } label: {
                HStack(spacing: 12) {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(last.name)
                            // List row from the scale; before it was a literal 15.
                            .font(Theme.listTitle)
                            .foregroundStyle(Theme.font)
                        Text("\(last.address) · Jellyfin \(last.version)")
                            // The scale's info grade, 12 Regular. Before it was a literal 12 at the
                            // call site.
                            .font(Theme.small)
                            .foregroundStyle(Theme.fontVeryQuiet)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        // 13 semibold: the chevron on the right of a row, as in `ValueRow` and
                        // `ProfileRow`. 12 was the second number for the same symbol.
                        .font(.system(size: 13, weight: .semibold))
                        // White at 28 percent is 2.50:1; for a control symbol the limit is 3:1.
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressRow())
            SeparatorLine()
        }
        .padding(.top, 36)
    }

    /// The button and the keyboard's Send key meet here; a second send during
    /// the check discards the model.
    private func linkUp() {
        guard !address.isEmpty else { return }
        model.connectStart(address, headers: headers.headers)
    }
}

// MARK: - Sign in

/// Second step: who is watching.
///
/// Jellyfin hands out the public users without sign-in. Offering them as
/// images, instead of making people type a name the server already knows,
/// is the real difference from before.
struct LoginView: View {
    let model: AppModel
    let serverName: String
    let version: String
    /// Opened as a sheet from the profile: the same server, one more account.
    /// There is then no way to another server, and the sheet must be able to
    /// close itself.
    var moreAccount = false
    /// No longer needed when adding: the page goes back by itself. Remains for
    /// sign-in at the root, which has no back.
    var done: () -> Void = {}

    @Environment(\.dismiss) private var close

    @State private var user = ""
    @State private var password = ""
    @State private var knownOnes: [PublicUser] = []
    @State private var images: [String: URL] = [:]
    @State private var quickConnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !knownOnes.isEmpty { choice }
                fields
                quickConnectDistance
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: Theme.formWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        // **When adding, the bar carries the way back at the top.**
        //
        // There was "Cancel" at the bottom, needed while the view came as a
        // sheet. As a pushed page it has the same way back at the top as every
        // subpage, and two ways back are one too many. At the root the row stays:
        // there is no back, only the way to another server.
        .safeAreaInset(edge: .top, spacing: 0) {
            if moreAccount {
                SubpageHeader(title: String(localized: "Konto hinzufügen")) {
                    close()
                } right: { EmptyView() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !moreAccount {
                Button("Anderer Server") { model.signOut() }
                    .buttonStyle(Theme.PressRow())
                    // 12 Regular from the scale; 13 Regular is not in it.
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .padding(.bottom, 22)
            }
        }
        #if os(iOS)
        // Only when adding: at the root there is no bar to get in the way, and
        // `SwipeBack` would have nothing to swipe back to.
        .toolbar(moreAccount ? .hidden : .automatic, for: .navigationBar)
        #endif
        // **Whoever shows the sheet also closes it.** After adding it would
        // otherwise stay and it looked as if nothing happened.
        //
        // `accountSwitch` rises exactly when someone was already signed in, i.e.
        // when adding and not on first sign-in. And **only without an error
        // message**: otherwise closing swallows it.
        .onChange(of: model.accountSwitch) { _, _ in
            guard moreAccount, model.errorMessage == nil else { return }
            close()
        }
        .task {
            knownOnes = await model.publicUser()
            images = await model.imageAddresses(knownOnes)
            // With exactly one account there is nothing to choose. Making people type
            // the name anyway, and leaving the sign-in button gray until then, is a
            // hurdle without purpose.
            if knownOnes.count == 1, user.isEmpty {
                user = knownOnes[0].name
            }
        }
        .fullScreenCover(isPresented: $quickConnect) {
            QuickConnectLogin(model: model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text("Verbunden · Jellyfin \(version)")
                    // The scale's info grade, 12 Regular. Before it was a literal.
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
            Text(serverName)
                .font(Theme.title)
                .foregroundStyle(Theme.font)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 48)
    }

    private var choice: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupsTitle(text: "Wer schaut?")
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(knownOnes) { person in
                        Button { user = person.name } label: {
                            AccountCharacter(name: person.name,
                                         image: images[person.id],
                                         selected: user == person.name)
                        }
                        .buttonStyle(Theme.PressRow())
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, 22)
    }

    private var fields: some View {
        VStack(spacing: 10) {
            InputField(text: $user, symbol: "person",
                        placeholder: "Benutzername")
            InputField(text: $password, symbol: "lock",
                        placeholder: "Passwort", secret: true,
                        completion: signIn)

            // The same reason as above: the button stays.
            do {
                Button(model.isWorking ? "Anmelden…" : "Anmelden", action: signIn)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 10)
                    .disabled(model.isWorking)
                    .disabled(user.isEmpty)
                    .opacity(user.isEmpty ? 0.4 : 1)
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(Theme.small)
                    .foregroundStyle(Theme.error)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 28)
    }

    /// Equal rank, not hidden: a password with special characters is hard to
    /// type on a glass screen.
    private var quickConnectDistance: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                Rectangle().fill(Theme.line).frame(height: 1)
                Text("oder")
                    // The scale's info grade, 12 Regular. Before it was a literal.
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            Button {
                quickConnect = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "tv")
                        .accessibilityHidden(true)
                    Text("Mit Quick Connect anmelden")
                }
            }
            .buttonStyle(SecondaryButtonStyle(accent: true))
        }
        .padding(.top, 26)
    }

    private func signIn() {
        guard !user.isEmpty else { return }
        Task { await model.login(username: user, password: password) }
    }
}

/// Round symbol for an account on the sign-in page.
struct AccountCharacter: View {
    let name: String
    let image: URL?
    let selected: Bool

    var body: some View {
        VStack(spacing: 8) {
            // **The building block, not a copy of it.**
            //
            // The symbol was built a second time by hand here: `erhoeht` as the
            // background instead of the gradient, a white 2 pt ring instead of
            // `highlighted`, 20 semibold as the letter instead of `size * 0.38`,
            // and the image via `Picture` instead of the image store, i.e. without the
            // synchronous lookup that prevents the letter from flashing. The same
            // thing in two builds means two profile rings in one app. That the ring
            // is white here and not accent is correct and is now `selected` in the
            // block.
            ProfileCharacter(name: name, image: image, size: 60, selected: selected)
            Text(name)
                // Title under a symbol: 13 from the scale, before a literal. One weight,
                // not two: `semibold` is wider than `medium`, and with two lines and
                // `minimumScaleFactor` the width decides the line break, so the name
                // wrapped differently when selected. Tone and ring express the choice.
                .font(Theme.tile)
                .foregroundStyle(selected ? Theme.font : Theme.fontQuiet)
                // Two lines and a bit more width: an eleven-character name was truncated
                // to ten characters at 66 pt and one line, and a truncated name on a
                // sign-in screen looks like an error.
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
        }
        .frame(width: 84)
        // **The choice is not expressed only through tone and ring.** Both are
        // color, and color alone reaches nobody who has the page read aloud:
        // VoiceOver said the same for every account. `.isSelected` is the trait
        // the system knows for this.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Bibliotheken

