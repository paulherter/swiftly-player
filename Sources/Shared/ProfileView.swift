import JellyfinKit
import SwiftUI

/// Profile, Quick Connect, settings, sign out.
///
/// A page of its own instead of a dropdown menu. The menu was the only one of
/// its kind in the app and looked foreign; it also hung on a 34 pt target in the
/// corner although everything in it leads on anyway.
///
/// Layout combines three references: the centered image block of Netflix and
/// Disney+, flat rows with hairlines, and groups separated only by whitespace
/// as in Disney+ and Prime Video. Cards would be pure Netflix and look foreign
/// next to our flat surfaces.
struct ProfileView: View {

    let model: AppModel

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide

    @State private var accountRecord = false
    /// Sign out asks first: a stray tap would otherwise cost the login.
    @State private var signOutSheet = false
    /// **Server onboarding as a pushed page.**
    ///
    /// The destination lives here and not with the others in `MainView` because it
    /// carries an address and is triggered from two places on this page: once
    /// without (new server), once with (another account on a known server).
    @State private var serverTarget: ServerRoute?
    @State private var log: LogFile?
    /// Someone tapped "Add server"; see there. Another account on a server we are
    /// not currently connected to, from the plus on its card.

    @Environment(\.openURL) private var open

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()

            VStack(spacing: 0) {
                // **A page title like everywhere else, next to the arrow.**
                //
                // This used to have none, on the grounds that the image block was the title.
                // That held while it filled half the page and sat centered; as a card it is
                // an object on the page and no longer a header.
                SubpageHeader(title: String(localized: "Profil")) { back() }

            ScrollView {
                VStack(spacing: 0) {
                    AccountCard(model: model,
                               insertOn: { serverTarget = ServerRoute(preset: $0) }) {
                        accountRecord = true
                    }

                    // 18 as between all other cards on this page; the only gap here used to be 20.
                    Color.clear.frame(height: 18)

                    group {
                        // **The symbol carries the accent, the title does not.**
                        //
                        // It was once fully accent, then not at all, on the grounds that accent means
                        // state and not rank. That is right, but the conclusion went too far: a profile
                        // page without a single colored spot reads lifeless, and Quick Connect is the
                        // one path on this page that **does** something; everything else leads on or
                        // displays.
                        //
                        // The symbol carries the color, the title stays white: the row stands out
                        // without claiming a rank among siblings. Feedback: it makes the page look much
                        // less colorless.
                        ProfileRow(symbol: "rectangle.and.text.magnifyingglass",
                                    title: "Quick Connect",
                                    under: "Code vom Fernseher eingeben",
                                    characterAccent: true,
                                    last: true, target: QuickConnectRoute())
                    }

                    Color.clear.frame(height: 18)

                    group {
                        ProfileRow(symbol: "play.fill", title: "Wiedergabe",
                                    under: "Sprache, Untertitel, Tempo",
                                    target: PlaybackRoute())
                        ProfileRow(symbol: "square.grid.2x2", title: "Darstellung",
                                    under: "Startseite, Reihen, Genres",
                                    target: PresentationRoute())
                        ProfileRow(symbol: "gearshape", title: "Einstellungen",
                                    last: true, target: SettingsRoute())
                    }

                    Color.clear.frame(height: 18)


                    group {
                        // **Now with a backend.** This used to say the form was designed and the
                        // backend missing. That stopped being true and the sentence stayed, which
                        // makes someone porting this conclude nothing is wired up: the account bundle
                        // holds several servers, and this row leads to onboarding.
                        // **Pushed, not from below.** The same kind of destination as Quick Connect,
                        // Seerr and settings: a subpage you go back from. The reasoning is at
                        // `ServerRoute`.
                        ProfileRow(symbol: "externaldrive.connected.to.line.below",
                                    title: "Server hinzufügen",
                                    under: "Ein zweiter Jellyfin, eigene Konten") {
                            serverTarget = ServerRoute()
                        }
                        // **Affects only the active account.** If others exist, the app switches to
                        // the next; only the last one returns to sign-in. That logic is in the state
                        // holder, not here.
                        ProfileRow(symbol: "rectangle.portrait.and.arrow.right",
                                    title: "Abmelden", last: true) { signOutSheet = true }
                    }


                    Color.clear.frame(height: 18)

                    // **Rate, Discord, report a bug: at the very bottom.** In settings these were
                    // at the bottom and hardly seen.
                    group {
                        ProfileRow(symbol: "star", title: "Swiftly bewerten",
                                    under: "Im App Store") {
                            open(Community.appStoreRating)
                        }
                        ProfileRow(symbol: "bubble.left.and.bubble.right", title: "Discord beitreten",
                                    under: "Fragen stellen und sagen, was fehlt") {
                            open(Community.discord)
                        }
                        ProfileRow(symbol: "ladybug", title: "Fehler melden",
                                    under: "Auf GitHub, deine App-Version ist schon eingetragen") {
                            open(Version.errorReport)
                        }
                        // Next to "Report a bug" because it belongs: whoever reports a bug on Discord
                        // attaches this.
                        ProfileRow(symbol: "doc.text", title: "Protokoll teilen",
                                    under: "Die letzte Stunde, ohne Zugangsdaten") {
                            log = LogFile.write()
                        }
                        // Last, because it sets nothing: it shows what is in the app and where the
                        // VLCKit source is (LGPL).
                        ProfileRow(symbol: "text.book.closed", title: "Open-Source-Lizenzen",
                                    under: "Was in Swiftly steckt, und der Quelltext von VLCKit",
                                    last: true, target: LicensesRoute())
                    }


                    // Same component as in settings and under the row list. **These stay fixed on
                    // this page:** the account-strip tiles, the profile symbol and the Quick Connect
                    // code, which sit in a grid of point measures that larger type would break.
                    Footer(Text(verbatim: Version.row))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.margin(wide: wide))
                        .padding(.top, 26)
                }
                .padding(.bottom, 40)
                // Limited width: across the full iPad width the arrow would sit half a meter
                // from its label.
                //
                // **Leading-aligned, not centered.** Centered was right while the image block
                // stood in the middle; as a card it hangs on the left edge like everything else.
                // And the reference is the sidebar: what hangs from it starts at its edge,
                // otherwise the page sits next to its own navigation.
                .frame(maxWidth: wide ? Theme.readWidth : .infinity,
                       alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            }

        }
        #if os(iOS)
        // Without this Apple's bar with its own back arrow sits on top: then there are
        // two, one of them glass.
        .toolbar(.hidden, for: .navigationBar)
        // **If the page opens in the middle of an account switch** (experiment
        // `experiment-glas`), it finishes immediately: new account active, profile
        // picture in place. See `AccountSwitchTransition.complete`.
        .onAppear {
            AccountSwitchTransition.shared.complete()
            AccountSwitchTransition.note("profil offen: angemeldet \(model.session?.userName ?? "-")")
        }
        .background(SwipeBack())
        #endif
        .overlay(alignment: .topTrailing) {
            ActionSheet(opened: $signOutSheet,
                           title: String(localized: "Abmelden von \(model.session?.userName ?? "")"),
                           actions: [
                TitleAction(symbol: "rectangle.portrait.and.arrow.right",
                              text: "Abmelden", cautionary: true) { model.signOut() },
            ])
        }
        .sheet(item: $log) { file in
            ShareSheet(file: file.url)
                .presentationDetents([.medium, .large])
        }
        // **Pushed, like every other subpage.** The reasoning is at `ServerRoute`.
        .navigationDestination(item: $serverTarget) { target in
            ServerOnboardingView(model: model, preset: target.preset)
        }
        // The same sign-in as for the first account, only without the way to another
        // server, and also pushed instead of from below.
        .navigationDestination(isPresented: $accountRecord) {
            LoginView(model: model,
                      serverName: model.serverName ?? "",
                      version: model.serverVersion ?? "",
                      moreAccount: true)
        }
    }

    /// A group is a card; see ``CardView``.
    ///
    /// `@escaping` because `CardView` keeps the closure instead of evaluating it
    /// immediately.
    private func group<ContentBody: View>(
        @ViewBuilder _ content: @escaping () -> ContentBody) -> some View {
        CardView(content: content)
    }
}

/// Quick Connect: authorize a code shown on another device.
///
/// A page of its own with the same layout as the profile page: arrow top left,
/// content below. Before, it was a sheet in the middle of the screen that brought
/// its own shape.
struct QuickConnectView: View {
    @Environment(\.wide) private var wide
    let model: AppModel

    @Environment(\.dismiss) private var back
    @FocusState private var inField: Bool

    @State private var code = ""
    @State private var running = false
    @State private var message: String?
    @State private var succeeded = false

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Title next to the arrow, as on the four other menus; see `SubpageHeader`.
                SubpageHeader(title: String(localized: "Quick Connect")) { back() }
                    .padding(.horizontal, -Theme.margin(wide: wide))

                Text("Auf dem anderen Gerät steht ein sechsstelliger Code. Gib ihn hier ein, dann meldet es sich mit deinem Konto an.")
                    .growing(15)
                    .lineSpacing(3)
                    .foregroundStyle(Theme.fontQuiet)
                    .padding(.top, 10)

                // **The placeholder was unreadable.** White at 22 percent gives 2.02:1 on the
                // field surface (calculated, not estimated); for text the limit is 4.5.
                // `schriftSehrLeise` gives 5.1:1 there and is still clearly quieter than the
                // typed code above.
                //
                // **28, not 34.** 34 existed in no scale. 28 is the largest there is, and a
                // six-digit code is the main thing on this page, so it may carry it. No
                // tracking, because the digits should line up tabularly.
                TextField("", text: $code, prompt: Text("000000")
                    .foregroundColor(Theme.fontVeryQuiet))
                    .font(Theme.titleLarge.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .foregroundStyle(Theme.font)
                    .focused($inField)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    // A field is a surface you can touch and carries the same tone as any other:
                    // `area`. The one *filled* surface on this page stays the button below, which
                    // carries the accent, not this tone. `eckeFeld`, not `corner`: this is an input
                    // field, not a tile. 10 was a raw value for the same role that has 12.
                    .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                    .padding(.top, 26)

                if let message {
                    Text(message)
                        // 13 Medium: the same level as the text under a poster. 13 Regular existed in
                        // no scale.
                        .font(Theme.tile)
                        // Success carries the accent, failure `error`. `warning` used to stand for
                        // both failures, but it means "waiting", not "went wrong".
                        .foregroundStyle(succeeded ? Theme.accent : Theme.error)
                        .padding(.top, 12)
                }

                Button(running ? "Moment…" : "Freigeben") { share() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(running || code.count < 4)
                    .padding(.top, 22)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.top, 8)
            // Same width as sign-in and server: a six-digit code in a 1036 pt wide field
            // is absurd.
            .frame(maxWidth: Theme.formWidth)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task {
            // Only after the transition: grabbing focus immediately makes the rising
            // keyboard push the page mid-animation, causing one jolt.
            try? await Task.sleep(for: .milliseconds(420))
            inField = true
        }
    }

    private func share() {
        running = true
        message = nil
        Task {
            defer { running = false }
            do {
                try await model.quickConnectShare(code: code)
                succeeded = true
                message = String(localized: "Freigegeben. Das andere Gerät ist gleich angemeldet.")
                Theme.jerk(.medium)
                #if os(iOS)
                AccessibilityNotification.Announcement(message ?? "").post()
                #endif
                try? await Task.sleep(for: .seconds(2))
                back()
            } catch {
                succeeded = false
                // **`lesbar` and not `localizedDescription`.** Since
                // `JellyfinError.errorDescription` itself goes through `readableError`, both
                // show the same, but `lesbar` also covers errors that do not come from the
                // package.
                message = model.readable(error)
            }
        }
    }
}

// MARK: - Account strip

/// Several Jellyfin accounts on the same server, horizontally above the page.
///
/// **Large is what is in the middle; connected is what carries the ring and the
/// dot.** Keeping these apart is the core of the design. Size follows scrolling
/// and means nothing; it only says what you are looking at. Only tapping
/// switches, and only then do the accent ring and dot move. Merging both gives a
/// strip that seems to switch constantly while scrolling.
///
/// With **one** account nothing appears here: the single image block of the
/// profile page remains, unchanged.
private struct AccountsStrip: View {
    let model: AppModel

    /// Which account is currently centered. Initially the signed-in one, so the
    /// strip does not start somewhere random.
    @State private var centeredOn: String?
    /// Width of the strip, from which the inset follows that the outer tiles need to
    /// be able to scroll to the center at all.
    @State private var width: CGFloat = 0

    /// From four accounts the neighbors step back one level, otherwise too little
    /// fits.
    private var many: Bool { model.accounts.count >= 4 }
    private var smallMass: CGFloat { many ? 56 : 64 }
    /// **22, always.** The design uses `gap: 22px` in both artboards, with two
    /// accounts and with four. Only the circles shrink, not the gap; otherwise the
    /// inset also moves with two accounts and the design's number matches nowhere.
    private static let spacing: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            strip
            label
        }
        .padding(.top, 56)
        .padding(.bottom, 32)
        // After a switch the center moves to the new account, otherwise the ring would
        // sit on one and the large tile on another without anyone scrolling.
        .onChange(of: model.accountSwitch) { _, _ in
            withAnimation(Theme.sectionSwitch) { centeredOn = model.session?.userID }
        }
    }

    private var strip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Self.spacing) {
                ForEach(model.accounts, id: \.userID) { account in
                    tile(account).id(account.userID)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        // Without this inset the outer tiles never reach the center: the strip scrolls,
        // but the first and last account would never become large.
        .contentMargins(.horizontal, max((width - 84) / 2, 0), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centeredOn, anchor: .center)
        // **Width first, then the center.**
        //
        // The inset above depends on `width`; while that is zero there is none, and
        // snapping to the center goes nowhere. This used to be in `onAppear`, reliably
        // *before* the first measurement.
        //
        // With two accounts it goes unnoticed, since the strip fits side by side anyway.
        // From four it would open at the left stop instead of at the signed-in account,
        // so the very case the strip is built for starts with a lie: someone would be
        // large, just not the one you expect.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
            let firstMeasurement = width == 0
            width = new
            if firstMeasurement, new > 0, centeredOn == nil {
                centeredOn = model.session?.userID
            }
        }
    }

    private func tile(_ account: Session) -> some View {
        let connected = account.userID == model.session?.userID
        let centered = account.userID == centeredOn
        let mass = centered ? 84 : smallMass
        return Button {
            if !connected { Theme.jerk(.medium) }
            model.switchAccount(toward: account.userID)
        } label: {
            VStack(spacing: 0) {
                // Fixed height so the row does not jump while growing.
                ZStack {
                    ProfileCharacter(name: account.userName,
                                  image: model.userImageURL(for: account),
                                  size: mass,
                                  highlighted: connected)
                }
                .frame(height: 84)

                // The dot belongs to the ring, not to the size: both say "connected".
                Circle()
                    .fill(connected ? Theme.accent : Color.clear)
                    .frame(width: 5, height: 5)
                    .padding(.top, 8)
                    .frame(height: 13, alignment: .top)
            }
            // Connected stays bright, even far out. Only what is neither connected nor
            // viewed is dimmed.
            .opacity(connected || centered ? 1 : 0.55)
            .animation(Theme.reveal, value: centered)
        }
        .buttonStyle(Theme.PressButton())
        // Custom controls tell VoiceOver their state.
        .accessibilityLabel(connected ? Text("\(account.userName), angemeldet")
                                      : Text("Zu \(account.userName) wechseln"))
        .accessibilityAddTraits(connected ? [.isButton, .isSelected] : .isButton)
    }

    /// Name of what is in the center, not of what is connected. Otherwise the line
    /// would contradict what stands large above it.
    private var label: some View {
        let account = model.accounts.first { $0.userID == centeredOn } ?? model.session
        let signedIn = account?.userID == model.session?.userID
        return VStack(spacing: 3) {
            Text(account?.userName ?? "")
                .font(Theme.rail)
                .tracking(Theme.lockRail)
                .foregroundStyle(Theme.font)
            // **White instead of accent.** Both lines carried it, but "Tap to switch" is
            // not a state change, it is an announcement, so the accent carried rank. Now
            // the text color says what applies: selected is bright, everything else quiet.
            Text(signedIn ? "Angemeldet" : "Tippen, um zu wechseln")
                .growing(12)
                .foregroundStyle(signedIn ? Theme.font : Theme.fontVeryQuiet)
        }
        .padding(.top, 14)
        .animation(Theme.reveal, value: centeredOn)
    }
}

/// **The account card: two axes, two gestures, two different meanings.**
///
/// **Tapping** an account in the row switches the user on the same server;
/// **swiping** the card switches the server. A second account is a housemate:
/// same library, different progress. A second server is a different place.
///
/// **The second axis is designed but not built.** An account bundle in the package
/// belongs to exactly one server; the card is already built to carry several so
/// nobody designs it a second time later. While there is one, there are no dots
/// and nothing to swipe, so nothing hints at something that does not exist.
///
/// **Edge to edge like every other card, no peek.** A neighboring card peeking
/// in would invite swiping and be a peek without a neighbor with one server. The
/// dots say what else exists.
private struct AccountCard: View {
    let model: AppModel
    /// An account on a server other than the connected one.
    var insertOn: (URL) -> Void = { _ in }
    let insert: () -> Void

    @Environment(\.wide) private var wide
    /// Which server is currently visible; for paging, not for switching.
    @State private var page = ""
    /// Measured height of each card; the page surface takes the largest.
    @State private var heights: [String: CGFloat] = [:]
    /// Where the profile pictures are, globally (experiment `experiment-glas`): the
    /// account switch lifts the selected one from there. In a plain class so scrolling
    /// and paging do not rebuild with every image.
    @State private var circles = CircleStore()
    private final class CircleStore {
        var frameRect: [String: CGRect] = [:]
    }

    /// A switch is running: everything except the selected image steps back.
    private var switches: Bool { AccountSwitchTransition.shared.transition != nil }

    /// **Switch, with motion**; see ``AccountSwitchTransition``.
    private func switchTo(toward account: Session) {
        Theme.jerk(.medium)
        let from = circles.frameRect[account.accountKey] ?? .zero
        let address = model.userImageURL(for: account)
        // If no image is in memory the card shows the letter, and exactly that flies
        // along, as one unit with its circle.
        let withoutImage = address.map { ImageCache.shared.image($0) == nil } ?? true
        AccountSwitchTransition.shared.start(
            account: account.accountKey,
            // Drawn as large as it gets at most while in flight.
            image: ProfileCharacter(name: account.userName, image: address,
                                size: max(from.width, 1) * 1.06, withoutImage: withoutImage),
            from: from, area: Theme.area, address: address) {
            model.switchAccount(toward: account.accountKey)
        }
    }

    /// The frame of a profile picture, without rebuilding the view.
    private func remember(_ key: String) -> some ViewModifier {
        FrameReporter { circles.frameRect[key] = $0 }
    }

    /// **One card per server**. Within a server the row of accounts,
    /// between servers the cards: tap an account and swipe the card to reach another
    /// server. With one server, the normal case, it is a card without dots; nothing
    /// hints at something that does not exist.
    var body: some View {
        content
        #if DEBUG
            .task {
                guard AccountSwitchRun.an, !AccountSwitchRun.wasTapped else { return }
                AccountSwitchRun.wasTapped = true
                try? await Task.sleep(for: .milliseconds(1500))
                guard let s = model.session,
                      let target = model.accounts(on: s.serverURL)
                          .first(where: { $0.accountKey != s.accountKey }) else { return }
                AccountSwitchTransition.note("selbsttest: tipp auf \(target.userName)")
                switchTo(toward: target)
                // A second tap mid-switch must go nowhere.
                try? await Task.sleep(for: .milliseconds(200))
                AccountSwitchTransition.note("selbsttest: zweiter tipp")
                switchTo(toward: target)
            }
        #endif
    }

    @ViewBuilder private var content: some View {
        let server = model.server
        if server.count <= 1 {
            card(model.session?.serverURL)
        } else {
            VStack(spacing: 10) {
                TabView(selection: $page) {
                    ForEach(server, id: \.absoluteString) { url in
                        card(url)
                            .fixedSize(horizontal: false, vertical: true)
                            // **The largest, not the most recently measured.** Otherwise the lower card
                            // won and the taller one was cut off top and bottom.
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
                                if new > 0 { heights[url.absoluteString] = new }
                            }
                            .frame(maxHeight: .infinity, alignment: .top)
                            .tag(url.absoluteString)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: heights.values.max() ?? 170)
                points(server)
            }
            .onAppear { page = model.session?.serverURL.absoluteString ?? "" }
            .onChange(of: model.session?.serverURL) { _, new in
                if let new { withAnimation(Theme.sectionSwitch) { page = new.absoluteString } }
            }
        }
    }

    /// The dots below are the only thing that says swiping is possible here, and
    /// they appear only from the second server.
    private func points(_ server: [URL]) -> some View {
        HStack(spacing: 7) {
            ForEach(server, id: \.absoluteString) { url in
                Circle()
                    .fill(url.absoluteString == page ? Theme.font : Theme.fontVeryQuiet)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func isActive(_ server: URL?) -> Bool {
        server?.absoluteString.lowercased() == model.session?.serverURL.absoluteString.lowercased()
    }

    @ViewBuilder
    private func card(_ server: URL?) -> some View {
        let all = server.map { model.accounts(on: $0) } ?? model.accounts
        let active = isActive(server)
        // On the active server the signed-in account comes first; on another, the first
        // account there. A tap switches to it.
        let front = active ? model.session : all.first
        let other = all.filter { $0.accountKey != front?.accountKey }
        CardView {
            headerLine(front, active: active, server: server)
            // `.padding(.leading, 0)` stood here and did nothing: `SeparatorLine` brings its
            // own inset, and a zero before it does not remove it.
            SeparatorLine()
            rail(other, active: active, server: server)
        }
    }

    @ViewBuilder
    private func headerLine(_ account: Session?, active: Bool, server: URL?) -> some View {
        let key = account?.accountKey ?? ""
        let flying = AccountSwitchTransition.shared.transition?.account == key
        let content = HStack(spacing: 14) {
            ProfileCharacter(name: account?.userName ?? "?",
                          image: account.flatMap { model.userImageURL(for: $0) },
                          size: 56,
                          highlighted: active && model.server.count > 1)
                .modifier(FrameReporter { circles.frameRect[key] = $0 })
                // The signed-in image makes room for the new one; a lifting one is in flight
                // and no longer shown here.
                .opacity(switches ? 0 : 1)
                .scaleEffect(switches && !flying && !Theme.motionReduced ? 0.8 : 1)
                .animation(flying ? nil : AccountSwitchTransition.lift, value: switches)
            VStack(alignment: .leading, spacing: 2) {
                // **17, not 19.** There is no level between 15 and 20; 17 Semibold is the sheet
                // heading, and its tracking is -0.008 em, so -0.14 at 17 points.
                Text(verbatim: account?.userName ?? String(localized: "Angemeldet"))
                    .font(Theme.categoryLarge)
                    .tracking(Theme.lockCategory)
                    .foregroundStyle(Theme.font)
                // Name and version are only known from the server we are connected to; for the
                // others the address is shown. The server name is a detail: 12 in
                // `schriftSehrLeise`, as on the library page. 13 Regular does not exist.
                Text(verbatim: active ? (model.serverName ?? server?.host() ?? "")
                                     : (server?.host() ?? ""))
                    .growing(12)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .lineLimit(1)
                // **The line is always there, even without a version.** The version only comes
                // with the server's response, so late after a cold start or server switch. If
                // the line was only drawn then, the text block grew and name and address jumped
                // up (same bug as on Android).
                if active {
                    Text(verbatim: "Jellyfin \(model.serverVersion ?? "")")
                        .growing(12)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .lineLimit(1)
                        .opacity(model.serverVersion == nil ? 0 : 1)
                        .accessibilityHidden(model.serverVersion == nil)
                } else {
                    Text("Antippen zum Wechseln")
                        .growing(12)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .lineLimit(1)
                }
            }
            // Name and server of the old account step back too.
            .opacity(switches ? 0 : 1)
            Spacer(minLength: 0)
        }
        .padding(16)
        .contentShape(Rectangle())
        .animation(AccountSwitchTransition.lift, value: switches)
        if !active, let account {
            Button { switchTo(toward: account) } label: { content }
                .buttonStyle(Theme.PressRow())
        } else {
            content
        }
    }

    private func rail(_ other: [Session], active: Bool, server: URL?) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                // The row keeps its height even when empty, otherwise the card of a server with
                // only one account is shorter than the others.
                Color.clear.frame(width: 0, height: 40)
                ForEach(other, id: \.accountKey) { account in
                    let flying = AccountSwitchTransition.shared.transition?.account == account.accountKey
                    Button { switchTo(toward: account) } label: {
                        ProfileCharacter(name: account.userName,
                                      image: model.userImageURL(for: account),
                                      size: 40)
                            .modifier(remember(account.accountKey))
                            // The selected one lifts off (now floating at root level), the others shrink
                            // away.
                            .opacity(switches ? 0 : 1)
                            .scaleEffect(switches && !flying && !Theme.motionReduced ? 0.8 : 1)
                            // The selected one is gone immediately, otherwise it would briefly appear
                            // twice.
                            .animation(flying ? nil : AccountSwitchTransition.lift, value: switches)
                    }
                    .buttonStyle(Theme.PressButton())
                    .accessibilityLabel(Text(verbatim: account.userName))
                }
                // **The plus is on every card** and adds an account on *this* server. On the
                // connected one the usual sign-in with "Who is watching?", on another the same as
                // when adding a server, only with the address already filled in.
                do {
                    Button {
                        if active { insert() } else if let server { insertOn(server) }
                    } label: {
                        // **A field on `area`, not a dashed circle**, as on the Mac (a
                        // button without a label is square). From the token, not a custom number: the
                        // same level as a list row title.
                        Image(systemName: "plus")
                            .font(Theme.listTitle)
                            .foregroundStyle(Theme.fontQuiet)
                            // **The field stays 40, the target becomes 44**, Apple's minimum size for a
                            // hit area.
                            .frame(width: 40, height: 40)
                            .background(Theme.area,
                                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(Theme.PressButton())
                    .accessibilityLabel(Text("Weiteres Konto hinzufügen"))
                    .opacity(switches ? 0 : 1)
                    .animation(AccountSwitchTransition.lift, value: switches)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }
}

// `FrameReporter` lives in `AccountTransition.swift` since the Mac port.
