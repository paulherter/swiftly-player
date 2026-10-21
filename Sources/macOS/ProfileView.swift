import AppKit
import JellyfinKit
import SwiftUI

/// Profile, Quick Connect, playback, settings, sign out.
///
/// Layout and order are taken verbatim from the iPhone version: a centered
/// image block, then three groups separated only by whitespace. No cards.
///
/// The page is kept narrow in the window; stretched to full width, icon and
/// value would end up half a meter apart.
struct ProfileView: View {
    let model: AppModel
    let back: () -> Void
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section
    @Environment(\.openURL) private var open

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // **A page title like every other subpage.** It used to be only the arrow,
                // on the grounds that the image block was the title. As a card, though, it is
                // an object on the page, not a header.
                //
                // **Aligned with the cards, not in front of them.** The header was pulled
                // left by one page margin and collided with the sidebar; on every other
                // subpage the arrow sits above the content edge.
                SubpageHeader(title: "Profil", back: back)
                    .padding(.bottom, 10)
                    // **If the page opens in the middle of an account switch**, the switch
                    // finishes immediately: new account active, profile image in place. See
                    // `AccountSwitchTransition.complete`.
                    .onAppear { AccountSwitchTransition.shared.complete() }

                // **Looks at the top, by state** (`LookProfileEntry`), as on iPhone: who has a
                // look to choose sees a quiet card with it; the teaser for the supporter looks;
                // everyone else sees nothing here.
                if lookEntry != .none || supporterStatusShown {
                    VStack(spacing: 16) {
                        switch lookEntry {
                        case .current:
                            CurrentLookCard(playing: model.playerOpen) { GiftFlow.shared.openLooksOnHome() }
                        case .teaser:
                            SupportLooksCard()
                        case .none:
                            EmptyView()
                        }
                        SupportStatusCard()
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                    .animation(Theme.reveal, value: SupportModel.shared.isSupporter)
                    .animation(Theme.reveal, value: lookEntry)
                }

                AccountCard(model: model,
                           insertOn: { server in
                               navigator.openIt(.serverAdd(server), in: section)
                           },
                           insert: {
                               navigator.openIt(.accountAdd, in: section)
                           })

                Color.clear.frame(height: 20)

                RowsGroup {
                    Button { navigator.openIt(.quickConnect, in: section) } label: {
                        ValuesRow(symbol: "rectangle.and.text.magnifyingglass",
                                   title: Text("Quick Connect"),
                                   under: Text("Code vom Fernseher eingeben"),
                                   accent: true, arrow: true, hoverable: true)
                    }
                    .buttonStyle(Theme.PressRow())
                }

                Color.clear.frame(height: 18)

                // **The categories live here, as on iPhone and iPad.**
                //
                // They briefly moved to Settings, on the grounds that Command-comma promises
                // everything there. The argument is right but the price was too high: the
                // profile became a single row, and anyone looking for "Darstellung" had to
                // know it is two levels deeper than on every other device. Command-comma
                // still opens Settings; what is there concerns the device.
                RowsGroup {
                    Button { navigator.openIt(.playback, in: section) } label: {
                        ValuesRow(symbol: "play.fill", title: Text("Wiedergabe"),
                                   under: Text("Sprache, Untertitel, Tempo"),
                                   arrow: true, hoverable: true)
                    }
                    .buttonStyle(Theme.PressRow())
                    SheetLine().padding(.leading, Theme.separatorInsetCard)
                    Button { navigator.openIt(.presentation, in: section) } label: {
                        ValuesRow(symbol: "square.grid.2x2", title: Text("Darstellung"),
                                   under: Text("Startseite, Reihen, Genres"),
                                   arrow: true, hoverable: true)
                    }
                    .buttonStyle(Theme.PressRow())
                    SheetLine().padding(.leading, Theme.separatorInsetCard)
                    // A plain way to the looks while a gift can be picked up and nothing above
                    // leads there.
                    if LookProfileEntry.showsLooksRow(entry: lookEntry,
                                                      giftAvailable: LookStore.shared.freeLooks().count > 1) {
                        Button { GiftFlow.shared.openLooksOnHome() } label: {
                            ValuesRow(symbol: "paintpalette", title: Text("Looks"),
                                       under: Text("Original und Halloween"),
                                       arrow: true, hoverable: true)
                        }
                        .buttonStyle(Theme.PressRow())
                        SheetLine().padding(.leading, Theme.separatorInsetCard)
                    }
                    Button { navigator.openIt(.settings, in: section) } label: {
                        ValuesRow(symbol: "gearshape", title: Text("Einstellungen"),
                                   arrow: true, hoverable: true)
                    }
                    .buttonStyle(Theme.PressRow())
                }

                Color.clear.frame(height: 18)

                RowsGroup {
                    // **Now with content below.** This used to be a note that multiple servers
                    // would come later, while the account bundle held exactly one. It now holds
                    // several, and the row leads to the sign-in flow: address, then sign in,
                    // optionally with Quick Connect.
                    //
                    // "Weiteres Konto hinzufuegen" is gone: the plus in the account card does
                    // the same, and does it where the accounts are.
                    Button { navigator.openIt(.serverAdd(nil), in: section) } label: {
                        ValuesRow(symbol: "externaldrive.connected.to.line.below",
                                   title: Text("Server hinzufügen"),
                                   under: Text("Ein zweiter Jellyfin, eigene Konten"),
                                   arrow: true, hoverable: true)
                    }
                    .buttonStyle(Theme.PressRow())
                    SheetLine().padding(.leading, Theme.separatorInsetCard)
                    // **Affects only the active account.** If others exist, the app switches to
                    // the next one; only the last one leads back to the sign-in screen. This is
                    // implemented in the state holder, not here.
                    ValuesRow(symbol: "rectangle.portrait.and.arrow.right",
                               title: Text("Abmelden")) { model.signOut() }
                }

                Color.clear.frame(height: 18)

                // **Rate, Discord, report a bug: at the very bottom.** They used to be in
                // Settings, where they were rarely seen.
                RowsGroup {
                    ValuesRow(symbol: "star", title: Text("Swiftly bewerten"),
                               under: Text("Im App Store"),
                               action: { open(Community.appStoreRating) })
                    SheetLine().padding(.leading, Theme.separatorInsetCard)
                    ValuesRow(symbol: "bubble.left.and.bubble.right", title: Text("Discord beitreten"),
                               under: Text("Fragen stellen und sagen, was fehlt"),
                               action: { open(Community.discord) })
                    SheetLine().padding(.leading, Theme.separatorInsetCard)
                    ValuesRow(symbol: "ladybug", title: Text("Fehler melden"),
                               under: Text("Auf GitHub, deine App-Version ist schon eingetragen"),
                               action: { open(Version.errorReport) })
                    SheetLine().padding(.leading, Theme.separatorInsetCard)
                    // Next to "Fehler melden" because it belongs with it: whoever reports a bug
                    // in Discord attaches this.
                    ValuesRow(symbol: "doc.text", title: Text("Protokoll teilen"),
                               under: Text("Die letzte Stunde, ohne Zugangsdaten"),
                               action: { logShare() })
                    SheetLine().padding(.leading, Theme.separatorInsetCard)
                    // Last, because it sets nothing: it shows what is in the app and where the
                    // VLCKit source code is.
                    ValuesRow(symbol: "text.book.closed", title: Text("Open-Source-Lizenzen"),
                               under: Text("Was in Swiftly steckt, und der Quelltext von VLCKit"),
                               arrow: true,
                               action: { navigator.openIt(.licenses, in: section) })
                }

                // **Not typed in.** This used to say "Swiftly 1.0", which has been wrong
                // since the first release, and this is exactly the line a tester copies into
                // a bug report.
                HStack(spacing: 10) {
                    Text(verbatim: Version.row)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                    MacSupporterMark()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 26)
            }
            // **Left-aligned, not centered in the window, as on iPad.** The page used to
            // hang as a narrow column between the sidebar and the right edge, touching
            // no existing edge. The width stays limited; the leftover space is now on
            // the right instead of on both sides.
            //
            // **Form width, not reading width.** 700 was too much: a row of an icon, a
            // word and a chevron, stretched over 700 points and 46 tall, is a stripe
            // with text at the edge. Reading width is the measure for **running text**;
            // a list of rows is a form, and `formWidth` exists for that. This keeps
            // the rows in the same proportion as on iPhone, and the accounts in the card
            // above read as a group rather than a row trailing off to the right.
            .frame(maxWidth: Theme.formWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        // The look's glow, the same on every main page; goes up with the content.
        .lookGlow()
        .scrollIndicators(.never)
        // **The milky bar at the top edge.** macOS 26 puts it over every scroll view
        // by itself. It was never in our code, which is why it was easy to look in
        // the wrong place. Over the image it blended in; on a plain background on the
        // left it showed up as a bar.
        //
        // What the framework adds unasked has to be switched off just like what you
        // write yourself.
        .pagesScroll()
        // The pop-up on the first visit.
        .supportProfileIntro()
    }

    /// What the top of the page shows about looks.
    private var lookEntry: LookProfileEntry {
        LookProfileEntry.at(supporterFeatures: true,
                                   isSupporter: SupportModel.shared.isSupporter,
                                   ownsLook: LookStore.shared.ownsLook)
    }

    private var supporterStatusShown: Bool {
        SupportModel.shared.isSupporter
    }

    /// **The Mac share menu, at the click position.** The counterpart of the
    /// share sheet on iPhone. There is no sheet from below on the Mac; the menu
    /// attaches to the pointer, so to the row.
    private func logShare() {
        guard let file = LogFile.write(),
              let window = NSApp.keyWindow, let area = window.contentView else { return }
        let point = area.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: [file.url])
            .show(relativeTo: NSRect(origin: point, size: .zero), of: area, preferredEdge: .minY)
    }
}

/// **`imageBlock`, `Kontenstreifen` and `AccountCircle` used to be here**: a
/// centered image block with a strip of scrolling circles. They called each
/// other, but nobody called them: since the switch to cards the body shows
/// `Kontokarte`. A hundred and ten lines nobody saw but that were read with
/// every change.

// MARK: - Quick Connect

/// Authorize a code that is shown on another device.
struct QuickConnectView: View {
    let model: AppModel
    let back: () -> Void

    @State private var code = ""
    @State private var running = false
    @State private var message: String?
    @State private var succeeded = false
    @FocusState private var inField: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubpageHeader(title: "Quick Connect", back: back)

            Text("Auf dem anderen Gerät steht ein sechsstelliger Code. Gib ihn hier ein, dann meldet es sich mit deinem Konto an.")
                .font(Theme.body)
                .lineSpacing(3)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            TextField("", text: $code,
                      prompt: Text(verbatim: "000000").foregroundColor(Theme.fontVeryQuiet))
                .textFieldStyle(.plain)
                // The code is the page title: 28 bold is the top level of the type scale;
                // 34 and 40 used to be above it.
                .font(Theme.titleLarge.monospacedDigit())
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.font)
                .focused($inField)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(Theme.area,
                            in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                .padding(.top, 26)
                .onSubmit(share)

            if let message {
                Text(verbatim: message)
                    .font(Theme.body)
                    .foregroundStyle(succeeded ? Theme.accent : Theme.error)
                    .padding(.top, 12)
            }

            PrimaryButton(label: running ? "Moment…" : "Freigeben",
                       symbol: "checkmark", pick: share)
                .disabled(running || code.count < 4)
                .opacity(code.count < 4 ? 0.4 : 1)
                .padding(.top, 22)

            Spacer(minLength: 0)
        }
        // Narrow like a form, but at the left edge like every subpage. Centered, the
        // arrow stood in the middle of the window, at no edge.
        .frame(maxWidth: Theme.formWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.edgeSpacing)
        .padding(.top, Theme.contentTop)
        // No waiting for a keyboard animation as on iPhone; nothing slides in the
        // window.
        .onAppear { inField = true }
    }

    private func share() {
        guard code.count >= 4, !running else { return }
        running = true
        message = nil
        Task {
            defer { running = false }
            do {
                try await model.quickConnectShare(code: code)
                succeeded = true
                message = String(localized: "Freigegeben. Das andere Gerät ist gleich angemeldet.")
                try? await Task.sleep(for: .seconds(2))
                back()
            } catch {
                succeeded = false
                message = model.readable(error)
            }
        }
    }
}

// MARK: - Additional account

/// Add a second account **on the same server**.
///
/// **No server field.** An account bundle belongs to exactly one server; the
/// address is fixed and only displayed. To change server, sign out.
///
/// **Name and password are the normal way here**, Quick Connect sits next to
/// it. On TV it is the other way around: a password on a remote is a burden,
/// whereas here a keyboard is in front of you.
struct AccountAddView: View {
    let model: AppModel
    let back: () -> Void

    @State private var user = ""
    @State private var passphrase = ""
    /// Switched to the code path. The process starts only then; otherwise every
    /// visit to this page would fetch a code from the server that nobody needs.
    @State private var perCode = false
    @State private var state = QuickConnectModel()
    @FocusState private var inputField: Field?

    private enum Field { case user, passphrase }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubpageHeader(title: "Weiteres Konto", back: back)

            Text("Ein zweites Jellyfin-Konto auf demselben Server. Beide bleiben angemeldet; oben auf der Profilseite wechselst du zwischen ihnen.")
                .font(Theme.body)
                .lineSpacing(3)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            serverRow.padding(.top, 22)

            if perCode { codePart } else { formSheet }

            Spacer(minLength: 0)
        }
        // Narrow like a form, but at the left edge like every subpage. Centered, the
        // arrow stood in the middle of the window, at no edge.
        .frame(maxWidth: Theme.formWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.edgeSpacing)
        .padding(.top, Theme.contentTop)
        .onAppear { inputField = .user }
        // The code is fetched only when someone switches to it.
        .task(id: perCode) { if perCode { await state.newStart(model) } }
        .onDisappear { state.halt() }
        .onChange(of: state.released) { _, new in
            guard let new else { return }
            Task {
                await model.signInWithQuickConnect(new)
                closeIfExpanded()
            }
        }
    }

    /// Where the account goes. A display, not a field.
    private var serverRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(Theme.small)
                .accessibilityHidden(true)
            Text(verbatim: serverDescription)
                .font(Theme.secondLine)
        }
        .foregroundStyle(Theme.fontVeryQuiet)
    }

    private var serverDescription: String {
        [model.serverName, model.serverAddress]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    // MARK: Name and password

    @ViewBuilder
    private var formSheet: some View {
        InputRow(text: $user, symbol: "person",
                     placeholder: String(localized: "Benutzername")) { inputField = .passphrase }
            .padding(.top, 26)
            .focused($inputField, equals: .user)

        InputRow(text: $passphrase, symbol: "lock", secret: true,
                     placeholder: String(localized: "Passwort"), completion: insert)
            .padding(.top, 10)
            .focused($inputField, equals: .passphrase)

        errorRow

        PrimaryButton(label: "Hinzufügen", symbol: "arrow.right",
                   pick: insert)
            .padding(.top, 22)
            .disabled(user.isEmpty || model.isWorking)
            .opacity(user.isEmpty ? 0.4 : 1)

        separatorWithOr.padding(.top, 18)

        OutlineButton(label: "Mit Quick Connect anmelden",
                   symbol: "rectangle.and.text.magnifyingglass") { perCode = true }
            .padding(.top, 18)
    }

    // MARK: Quick Connect

    @ViewBuilder
    private var codePart: some View {
        if let preGait = state.preGait {
            Text("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist.")
                .font(Theme.secondLine)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 26)

            Text(verbatim: preGait.code)
                .font(Theme.titleLarge.monospacedDigit())
                .tracking(6)
                .foregroundStyle(Theme.font)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Theme.area,
                            in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                // A click puts the code on the clipboard; it is usually pasted right away
                // into a browser window next to it.
                .copyable(preGait.code)
                .padding(.top, 14)

            HStack(spacing: 10) {
                Text("Läuft ab in \(state.secondsLeft / 60):\(String(format: "%02d", state.secondsLeft % 60))")
                    .font(Theme.secondLine)
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
            .padding(.top, 14)
        } else if let error = state.error {
            Text(verbatim: error)
                .font(Theme.secondLine)
                .foregroundStyle(Theme.warning)
                .padding(.top, 26)
        } else {
            // The code arrives shortly; until then its shape is shown.
            LoadField(corner: Theme.cornerField)
                .frame(width: 240, height: 64)
                .padding(.top, 26)
        }

        errorRow

        OutlineButton(label: "Lieber Name und Passwort", symbol: "person") {
            state.halt()
            perCode = false
        }
        .padding(.top, 22)
    }

    // MARK: Small parts

    @ViewBuilder
    private var errorRow: some View {
        if let error = model.errorMessage {
            Text(verbatim: error)
                .font(Theme.secondLine)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    private var separatorWithOr: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Text("oder")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private func insert() {
        guard !user.isEmpty, !model.isWorking else { return }
        Task {
            await model.login(username: user, password: passphrase)
            closeIfExpanded()
        }
    }

    /// **The page closes itself, but only if it worked.**
    ///
    /// On first sign-in the screen disappears on its own: `RootView` swaps the
    /// whole content at `phase == .ready`. On an already signed-in app that does
    /// not happen; the account is added and the page would stay as if nothing
    /// happened. The check on `errorMessage` is needed, otherwise closing
    /// swallows the error message.
    private func closeIfExpanded() {
        if model.errorMessage == nil { back() }
    }
}

/// The second way on a page: outline instead of fill, accent instead of
/// black. Outlined button, the second way next to the main button.
///
/// **No longer private:** the server onboarding puts the same button under its
/// form, and two copies would be duplicated code.
struct OutlineButton: View {
    let label: LocalizedStringKey
    let symbol: String
    let pick: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(Theme.body)
                    .accessibilityHidden(true)
                Text(label).font(Theme.body.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.primaryButtonHeight)
            .foregroundStyle(Theme.accent)
            // **A fill, not a drawn border.** The fill says "you can press here"; a
            // border would say the same a second time. The text carries the accent: this
            // is the second way to the same goal, not a replacement for the main button.
            .background(hovers ? Theme.pressedArea : Theme.area,
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
    }
}

/// **The account card, taken verbatim from iPhone and iPad.**
///
/// Two axes, two gestures, saying two different things: **clicking** an
/// account in the row switches the user on the same server; **paging** the
/// card switches the server. A second account is a housemate (same library,
/// different progress). A second server is a different place.
///
/// **The accounts, sorted by server.**
///
/// **Stacked, not swipeable.** On iPhone each server has a card in a paged
/// band with dots below, because the page is narrow there and two stacked
/// cards would be two screen heights. A window has room downward, and
/// swiping is a finger gesture, so here the servers are simply stacked, the
/// connected one first. The deviation is justified by input method and window size, not taste.
private struct AccountCard: View {
    let model: AppModel
    /// An account on a **different** server than the connected one.
    var insertOn: (URL) -> Void = { _ in }
    /// An account on **this** server: the usual sign-in.
    let insert: () -> Void

    /// The connected server first, the others in their order.
    private var server: [URL] {
        model.server.sorted { a, b in isActive(a) && !isActive(b) }
    }

    var body: some View {
        VStack(spacing: 14) {
            if server.isEmpty {
                card(model.session?.serverURL)
            } else {
                ForEach(server, id: \.absoluteString) { url in card(url) }
            }
        }
    }

    private func isActive(_ server: URL?) -> Bool {
        server?.absoluteString.lowercased() == model.session?.serverURL.absoluteString.lowercased()
    }

    /// Where the profile images live, globally: the account switch lifts the
    /// chosen one from there. A plain class, so scrolling does not rebuild on
    /// every image, as on iPhone.
    @State private var circles = CircleStore()
    private final class CircleStore {
        var frameRect: [String: CGRect] = [:]
    }

    /// A switch is running: everything except the chosen image steps back.
    private var switches: Bool { AccountSwitchTransition.shared.transition != nil }

    /// **Switching, with motion** (design D, as on iPhone). See
    /// `AccountSwitchTransition` and, on the Mac, `AccountSwitchStage`: the page moves
    /// out, the image flies in an arc into the sidebar, the ring pops, the home
    /// rows arrive staggered.
    private func switchTo(toward account: Session) {
        let from = circles.frameRect[account.accountKey] ?? .zero
        let address = model.userImageURL(for: account)
        let withoutImage = address.map { ImageCache.shared.image($0) == nil } ?? true
        AccountSwitchTransition.shared.start(
            account: account.accountKey,
            image: ProfileCharacter(name: account.userName, image: address,
                                size: max(from.width, 1) * 1.06, withoutImage: withoutImage),
            from: from, area: Theme.area, address: address) {
            model.switchAccount(toward: account.accountKey)
        }
    }

    private func remember(_ key: String) -> some ViewModifier {
        FrameReporter { circles.frameRect[key] = $0 }
    }

    @ViewBuilder
    private func card(_ server: URL?) -> some View {
        let all = server.map { model.accounts(on: $0) } ?? model.accounts
        let active = isActive(server)
        // On the connected server the signed-in user comes first; on another server
        // the first account there. A click switches to it.
        let front = active ? model.session : all.first
        let other = all.filter { $0.accountKey != front?.accountKey }
        CardView {
            headerLine(front, active: active, server: server)
            SheetLine()
            rail(other, active: active, server: server)
        }
        // The connected server carries the accent border; the others are ordinary
        // cards. With only one server there is nothing to distinguish, so the border
        // is omitted.
        .overlay {
            if active, model.server.count > 1 {
                RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.5)
            }
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
                .modifier(MacSupporterAvatarBadge(size: 56, shown: active))
                .modifier(remember(key))
                // The signed-in image makes room for the new one; a lifting one is on its
                // way and no longer shown here.
                .opacity(switches ? 0 : 1)
                .scaleEffect(switches && !flying && !Theme.motionReduced ? 0.8 : 1)
                .animation(flying ? nil : AccountSwitchTransition.lift, value: switches)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: account?.userName ?? String(localized: "Angemeldet"))
                    // 19 is on no scale; 20 semibold is the row heading level, and its
                    // tracking is tied to it.
                    .font(Theme.rail)
                    .tracking(Theme.lockRail)
                    .foregroundStyle(Theme.font)
                // Name and version are known only from the connected server; for the others
                // the address is shown.
                Text(verbatim: active ? (model.serverName ?? server?.host() ?? "")
                                     : (server?.host() ?? ""))
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .lineLimit(1)
                // **The line is always present, even without a version.** The version only
                // arrives with the server's response, so late after a cold start or a server
                // switch. If the line were drawn only then, the text block would grow and
                // name and address would jump up (same bug as on Android).
                if active {
                    Text(verbatim: "Jellyfin \(model.serverVersion ?? "")")
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .lineLimit(1)
                        .opacity(model.serverVersion == nil ? 0 : 1)
                        .accessibilityHidden(model.serverVersion == nil)
                } else {
                    Text("Klicken zum Wechseln")
                        .font(Theme.small)
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
                .buttonStyle(Theme.PressButton())
        } else {
            content
        }
    }

    /// The other accounts on this server, followed by the plus.
    private func rail(_ other: [Session], active: Bool, server: URL?) -> some View {
        // **Verbatim the iPhone's row**, with its two subtleties: it scrolls
        // horizontally when a server has many accounts, and it keeps its height even
        // when empty. Otherwise the card of a server with a single account is lower
        // than the others, which on the Mac looked as if the row had slipped.
        ScrollView(.horizontal) {
        HStack(spacing: 14) {
            Color.clear.frame(width: 0, height: 40)
            ForEach(other, id: \.accountKey) { account in
                let flying = AccountSwitchTransition.shared.transition?.account == account.accountKey
                Button { switchTo(toward: account) } label: {
                    ProfileCharacter(name: account.userName,
                                  image: model.userImageURL(for: account),
                                  size: 40)
                        .modifier(remember(account.accountKey))
                        // The chosen one lifts off, the others shrink away; the chosen one is gone
                        // immediately, otherwise it would briefly appear twice.
                        .opacity(switches ? 0 : 1)
                        .scaleEffect(switches && !flying && !Theme.motionReduced ? 0.8 : 1)
                        .animation(flying ? nil : AccountSwitchTransition.lift, value: switches)
                }
                .buttonStyle(Theme.PressButton())
                // `.help` sets the tooltip under the pointer, not the label: the profile
                // icon alone tells VoiceOver nothing.
                .accessibilityLabel(Text("Zu \(account.userName) wechseln"))
                .help(Text(verbatim: account.userName))
            }

            // **The plus is on every card** and creates an account on *this* server. On
            // the connected one it is the usual sign-in; on another it is the same as
            // adding a server, only with the address filled in. It used to be only on the
            // connected server's card, so creating an account elsewhere meant switching
            // there first.
            Button {
                if active { insert() } else if let server { insertOn(server) }
            } label: {
                // **A field on `area`, not a dashed circle.** The dashed circle was the
                // only dashed line in the app and the only circle on a card. A button without
                // a label is square.
                Image(systemName: "plus")
                    .font(Theme.listTitle)
                    .foregroundStyle(Theme.fontQuiet)
                    .frame(width: Theme.buttonField, height: Theme.buttonField)
                    .background(Theme.area,
                                in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressButton())
            // `.help` sets the tooltip under the pointer, not the label: VoiceOver read
            // only "button" here.
            .accessibilityLabel(Text("Weiteres Konto hinzufügen"))
            .help(Text("Weiteres Konto hinzufügen"))
            .opacity(switches ? 0 : 1)
            .animation(AccountSwitchTransition.lift, value: switches)
        }
        .padding(16)
        }
        .scrollIndicators(.hidden)
    }
}
