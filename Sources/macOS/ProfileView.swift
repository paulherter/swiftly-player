import AppKit
import JellyfinKit
import SwiftUI


/// Profile page, as in the approved Mac design: title, then two columns of 470 pt.
/// Left: account card, look card, support card, Wiedergabe / Darstellung / Allgemein.
/// Right: server group (add, Quick Connect, sign out), then the links.
struct ProfileView: View {
    let model: AppModel
    let back: () -> Void
    @State private var headerState = HeaderState()
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section
    @Environment(\.openURL) private var open

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MacPageTitle(text: "Profil", bottom: 18)
                    // If the page opens in the middle of an account switch, the switch
                    // finishes immediately (see `AccountSwitchTransition.complete`).
                    .onAppear { AccountSwitchTransition.shared.complete() }

                HStack(alignment: .top, spacing: 24) {
                    leftColumn.frame(minWidth: 0, maxWidth: 470, alignment: .topLeading)
                    rightColumn.frame(minWidth: 0, maxWidth: 470, alignment: .topLeading)
                }
                .frame(maxWidth: 964, alignment: .leading)

                // Not typed in: this is the line a tester copies into a bug report.
                HStack(spacing: 10) {
                    Text(verbatim: Version.row)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                    MacSupporterMark()
                }
                .padding(.top, 26)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        // The look's glow, the same on every main page; goes up with the content.
        .lookGlow()
        .scrollIndicators(.never)
        // ‹ › and, once scrolled, the page name.
        .overlay(alignment: .top) {
            StateBar(title: "Profil", state: headerState, back: back)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        // macOS 26 puts a milky bar over every scroll view by itself; switched off here.
        .pagesScroll()
        // The pop-up on the first visit.
        .supportProfileIntro()
    }

    // MARK: Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            AccountCard(model: model,
                       insertOn: { server in
                           // By the known kind of that server: its sign-in without the picker.
                           navigator.openIt(.serverAdd(ServerRoute(
                               preset: server, kind: model.accounts(on: server).first?.kind)),
                                            in: section)
                       },
                       insert: {
                           // Another account on the connected server, by its kind: Jellyfin
                           // and Emby sign in on the page with the user list, Plex through
                           // plex.tv.
                           if model.session?.kind == .plex {
                               navigator.openIt(.serverAdd(ServerRoute(
                                   preset: model.session?.serverURL, kind: .plex)), in: section)
                           } else {
                               navigator.openIt(.accountAdd, in: section)
                           }
                       })

            // The look card replaces the old "Wähl deinen Look" banner.
            LookLineCard {
                if lookEntry == .current {
                    GiftFlow.shared.openLooksOnHome()
                } else {
                    SupportFlow.shared.openLooks()
                }
            }
            .padding(.top, 18)

            Group {
                if SupportModel.shared.isSupporter {
                    SupportStatusCard()
                } else {
                    SupportLineCard()
                }
            }
            .padding(.top, 16)
            .animation(Theme.reveal, value: SupportModel.shared.isSupporter)

            // The categories live here, as on iPhone and iPad.
            RowsGroup {
                Button { navigator.openIt(.playback, in: section) } label: {
                    ValuesRow(symbol: "play.circle", title: Text("Wiedergabe"),
                               under: Text("Qualität, Sprache, Player"),
                               arrow: true, hoverable: true)
                }
                .buttonStyle(Theme.PressRow())
                GroupLine()
                Button { navigator.openIt(.presentation, in: section) } label: {
                    ValuesRow(symbol: "textformat.size", title: Text("Darstellung"),
                               under: Text("Startseite, Reihen, Genres"),
                               arrow: true, hoverable: true)
                }
                .buttonStyle(Theme.PressRow())
                GroupLine()
                Button { navigator.openIt(.settings, in: section) } label: {
                    ValuesRow(symbol: "gearshape", title: Text("Allgemein"),
                               under: Text("Downloads, Server, Sync"),
                               arrow: true, hoverable: true)
                }
                .buttonStyle(Theme.PressRow())
            }
            .padding(.top, 18)
        }
    }

    // MARK: Right column

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowsGroup {
                // Leads to the sign-in flow: address, then sign in, optionally with Quick Connect.
                Button { navigator.openIt(.serverAdd(ServerRoute()), in: section) } label: {
                    ValuesRow(symbol: "externaldrive.connected.to.line.below",
                               title: Text("Server hinzufügen"),
                               under: Text("Jellyfin, Emby oder Plex, auch gemischt"),
                               arrow: true, hoverable: true)
                }
                .buttonStyle(Theme.PressRow())
                // Quick Connect is Jellyfin's; the other kinds have no counterpart.
                if model.can(.quickConnect) {
                    GroupLine()
                    Button { navigator.openIt(.quickConnect, in: section) } label: {
                        ValuesRow(symbol: "rectangle.and.text.magnifyingglass",
                                   title: Text("Quick Connect"),
                                   under: Text("Code vom Fernseher eingeben"),
                                   accent: true, arrow: true, hoverable: true)
                    }
                    .buttonStyle(Theme.PressRow())
                }
                GroupLine()
                // Affects only the active account: with others present the app switches to the
                // next one; only the last leads back to sign-in (done in the state holder).
                ValuesRow(symbol: "rectangle.portrait.and.arrow.right",
                           title: Text("Abmelden")) { model.signOut() }
            }

            RowsGroup {
                ValuesRow(symbol: "star", title: Text("Swiftly bewerten"), external: true,
                           action: { open(Community.appStoreRating) })
                GroupLine()
                ValuesRow(symbol: "bubble.left.and.bubble.right", title: Text("Discord beitreten"),
                           external: true, action: { open(Community.discord) })
                GroupLine()
                ValuesRow(symbol: "ladybug", title: Text("Fehler melden"),
                           external: true, action: { open(Version.errorReport) })
                GroupLine()
                // Next to "Fehler melden": whoever reports a bug attaches this.
                ValuesRow(symbol: "doc.text", title: Text("Protokoll teilen"),
                           action: { logShare() })
                GroupLine()
                ValuesRow(symbol: "text.book.closed", title: Text("Open-Source-Lizenzen"),
                           arrow: true,
                           action: { navigator.openIt(.licenses, in: section) })
            }
            .padding(.top, 18)
        }
    }

    /// What the top of the page shows about looks.
    private var lookEntry: LookProfileEntry {
        LookProfileEntry.at(supporterFeatures: true,
                                   isSupporter: SupportModel.shared.isSupporter,
                                   ownsLook: LookStore.shared.ownsLook)
    }

    /// **The Mac share menu, at the click position.** There is no sheet from below on the
    /// Mac; the menu attaches to the pointer, so to the row.
    private func logShare() {
        guard let file = LogFile.write(),
              let window = NSApp.keyWindow, let area = window.contentView else { return }
        let point = area.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: [file.url])
            .show(relativeTo: NSRect(origin: point, size: .zero), of: area, preferredEdge: .minY)
    }
}

/// The look card: palette, the current look's name, a caret.
///
/// **Built like "Swiftly unterstützen" below it.** It used to show three preview
/// swatches in front of the name; next to the plain support row they read as three
/// odd boxes, not as looks. Two rows of one kind belong in one form.
private struct LookLineCard: View {
    let action: () -> Void

    var body: some View {
        let current = LookStore.shared.palette.look
        Button(action: action) {
            HStack(spacing: 12) {
                Image(icon: "paintpalette", size: 22)
                    .font(.app(size: 22))
                    .foregroundStyle(Theme.font)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: current.name)
                        .font(.app(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.font)
                    Text("Dein aktueller Look")
                        .font(.app(size: 13))
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
                Spacer(minLength: 0)
                Image(icon: "chevron.right")
                    .font(.app(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.fontQuiet)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.groupsArea, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Dein Look: \(current.name)"))
    }
}

/// "Swiftly unterstützen": heart, two lines, caret.
private struct SupportLineCard: View {
    var body: some View {
        Button { SupportModel.shared.open() } label: {
            HStack(spacing: 12) {
                Image(icon: "heart", size: 22)
                    .font(.app(size: 22))
                    .foregroundStyle(Theme.font)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SupportCopy.supportSwiftly.localized)
                        .font(.app(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.font)
                    Text(SupportCopy.sayThanks.localized)
                        .font(.app(size: 13))
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
                Spacer(minLength: 0)
                Image(icon: "chevron.right")
                    .font(.app(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.fontQuiet)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.groupsArea, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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

            Text(explanation)
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
            Image(icon: "server.rack")
                .font(Theme.small)
                .accessibilityHidden(true)
            Text(verbatim: serverDescription)
                .font(Theme.secondLine)
        }
        .foregroundStyle(Theme.fontVeryQuiet)
    }

    private var explanation: LocalizedStringKey {
        (model.session?.kind ?? ServerKind.jellyfin) == .jellyfin
        ? "Ein zweites Jellyfin-Konto auf demselben Server. Beide bleiben angemeldet; oben auf der Profilseite wechselst du zwischen ihnen."
        : "Ein weiteres Konto auf diesem Server. Beide bleiben angemeldet; auf der Profilseite wechselst du zwischen ihnen."
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

        // Emby has no Quick Connect: the form alone.
        if model.can(.quickConnect) {
            separatorWithOr.padding(.top, 18)

            OutlineButton(label: "Mit Quick Connect anmelden",
                       symbol: "rectangle.and.text.magnifyingglass") { perCode = true }
                .padding(.top, 18)
        }
    }

    // MARK: Quick Connect

    @ViewBuilder
    private var codePart: some View {
        QuickConnectCode(state: state, hint: "Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist.")

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
                Image(icon: symbol).font(Theme.body)
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

/// **The account card** (design: avatar 56, name, "server · version", then "Konto hinzufügen").
///
/// Clicking another account in the card switches the user on the same server. One card per
/// server, the connected one first; stacked rather than paged, as a window has the room.
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
    /// chosen one from there. A plain class, so scrolling does not rebuild on every image.
    @State private var circles = CircleStore()
    private final class CircleStore {
        var frameRect: [String: CGRect] = [:]
    }

    /// A switch is running: everything except the chosen image steps back.
    private var switches: Bool { AccountSwitchTransition.shared.transition != nil }

    /// Switching, with motion: see `AccountSwitchTransition` and `AccountSwitchStage`.
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
        VStack(alignment: .leading, spacing: 0) {
            headerLine(front, active: active, server: server)
            ForEach(other, id: \.accountKey) { account in
                otherRow(account).padding(.top, 12)
            }
            addRow(active: active, server: server).padding(.top, 20)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.groupsArea, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // The connected server carries the accent border; with only one server there is
        // nothing to distinguish, so the border is omitted.
        .overlay {
            if active, model.server.count > 1 {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.5)
            }
        }
    }

    @ViewBuilder
    private func headerLine(_ account: Session?, active: Bool, server: URL?) -> some View {
        let key = account?.accountKey ?? ""
        let flying = AccountSwitchTransition.shared.transition?.account == key
        let line = active
            ? [model.serverName ?? server?.host(), model.serverVersion]
                .compactMap { $0 }.joined(separator: " · ")
            : (server?.host() ?? "")
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
                    .font(.app(size: 17, weight: .bold))
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                Text(verbatim: line)
                    .font(.app(size: 13))
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .lineLimit(1)
                if !active {
                    Text("Klicken zum Wechseln")
                        .font(.app(size: 13))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .lineLimit(1)
                }
            }
            // Name and server of the old account step back too.
            .opacity(switches ? 0 : 1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .animation(AccountSwitchTransition.lift, value: switches)
        if !active, let account {
            Button { switchTo(toward: account) } label: { content }
                .buttonStyle(Theme.PressButton())
        } else {
            content
        }
    }

    /// Another account on the same server: a click switches to it.
    private func otherRow(_ account: Session) -> some View {
        let flying = AccountSwitchTransition.shared.transition?.account == account.accountKey
        return Button { switchTo(toward: account) } label: {
            HStack(spacing: 14) {
                ProfileCharacter(name: account.userName,
                              image: model.userImageURL(for: account),
                              size: 40)
                    .modifier(remember(account.accountKey))
                    // The chosen one lifts off, the others shrink away.
                    .opacity(switches ? 0 : 1)
                    .scaleEffect(switches && !flying && !Theme.motionReduced ? 0.8 : 1)
                    .animation(flying ? nil : AccountSwitchTransition.lift, value: switches)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: account.userName)
                        .font(Theme.listTitle)
                        .foregroundStyle(Theme.font)
                        .lineLimit(1)
                    Text("Klicken zum Wechseln")
                        .font(.app(size: 13))
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
                .opacity(switches ? 0 : 1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(Text("Zu \(account.userName) wechseln"))
    }

    /// "Konto hinzufügen" on every card: creates an account on *this* server. On the
    /// connected one it is the usual sign-in; on another it is the same as adding a server,
    /// only with the address filled in.
    private func addRow(active: Bool, server: URL?) -> some View {
        Button {
            if active { insert() } else if let server { insertOn(server) }
        } label: {
            HStack(spacing: 16) {
                Image(icon: "plus", size: 20)
                    .font(.app(size: 20))
                    .foregroundStyle(Theme.font)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                Text("Konto hinzufügen")
                    .font(.app(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.font)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .opacity(switches ? 0 : 1)
        .animation(AccountSwitchTransition.lift, value: switches)
    }
}
