import JellyfinKit
import SwiftUI
import SwiftlyCore

/// Connect Seerr: the TV flow.
///
/// The name is already there. It is the same account on both sides; Seerr asks Jellyfin
/// itself whether name and password are right. Only what we don't have is typed, and with a
/// remote every character is expensive, so as few as possible.
///
/// A page of its own above everything, not a row in settings: three fields and an on-screen
/// keyboard need space a list row doesn't have.
struct SeerrConnectView: View {
    let model: AppModel
    let seerr: SeerrModel
    let close: () -> Void

    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    /// "Advanced": custom headers for a service in front of Seerr.
    @State private var headers: [HeaderRow] = []
    @State private var method: SwiftlyCore.SignInMethod?
    /// The core's sign-in screen (not connected / signing in / failed with words / connected), one per page visit.
    @State private var flow: SeerrSetupFlow?

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("Seerr")
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.font)

                Text("Jellyseerr oder Overseerr. Dann zeigt die Suche auch Titel, die noch nicht auf deinem Server sind, und du kannst sie anfragen.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .frame(width: 900, alignment: .leading)
                    .padding(.top, 16)

                if seerr.connected { connected } else { formSheet }

                HStack(spacing: 24) {
                    Button("Fertig") { close() }
                        .buttonStyle(ThemedButtonStyle())
                }
                .padding(.top, 44)
            }
            .frame(width: 900, alignment: .leading)
        }
        .task {
            if user.isEmpty { user = model.session?.userName ?? "" }
            await seerr.lookUp()
        }
        // Not connected: the core's screen decides what shows. Connected (also by the server's synced session), or after a
        // disconnect, a fresh one.
        .task(id: seerr.connected) {
            guard !seerr.connected else { flow = nil; return }
            if method == nil, model.session?.kind == .plex { method = .plex }
            let fresh = SeerrSetupFlow(seerr: seerr)
            flow = fresh
            await fresh.open()
        }
    }

    @ViewBuilder
    private var connected: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: seerr.address ?? "")
                .font(Theme.body).foregroundStyle(Theme.font)
            // A value, not a state color. The template shows it as an ordinary row value
            // (`Shared/SeerrSettingsView`); here it used the accent or `warning`. An expired
            // session is not waiting and not an error, it is information, and the word says it.
            Text(seerr.sessionState == .valid ? "Sitzung aktiv"
                 : seerr.sessionState == .invalid ? "Sitzung abgelaufen" : "Seerr nicht erreichbar")
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)
            // "Disconnect", not "Sign out": nothing changes on Seerr itself, only this one access.
            Button("Verbindung trennen") {
                seerr.disconnect(); address = ""; password = ""
            }
            .buttonStyle(ThemedButtonStyle())
        }
        .padding(.top, 44)
    }

    @ViewBuilder
    private var formSheet: some View {
        if let flow, flow.opened, !flow.working {
            switch flow.info.entry {
            case .notSetUp:
                Text(verbatim: flow.info.notSetUp ?? "")
                    .font(Theme.body).foregroundStyle(Theme.fontQuiet)
                    .frame(width: 900, alignment: .leading)
                    .padding(.top, 44)
            case .askAddress, .knownAddress:
                signInForm(flow)
            }
        } else {
            // The core's own loading line; no spinner on the TV, the page keeps its shape.
            Text(verbatim: flow?.info.busy ?? "")
                .font(Theme.body).foregroundStyle(Theme.fontQuiet)
                .padding(.top, 44)
        }
    }

    private func signInForm(_ flow: SeerrSetupFlow) -> some View {
        let rows = flow.methods
        let chosen = rows.first { $0.method == method } ?? rows.first
        return VStack(alignment: .leading, spacing: 20) {
            // The address: asked once per server of the administrator only. Everyone else sees it as a line.
            if flow.info.entry == .askAddress {
                InputField(placeholder: "seerr.example.de", text: $address, content: .URL)
                TVAdvanced(rows: $headers)
            } else if let known = flow.info.address {
                HStack(spacing: 24) {
                    Text(verbatim: known).font(Theme.body).foregroundStyle(Theme.fontQuiet).lineLimit(1)
                    if flow.info.canEditAddress {
                        Button("Adresse ändern") { flow.editAddress() }
                            .buttonStyle(ThemedButtonStyle())
                    }
                }
            }
            if rows.count > 1 {
                HStack(spacing: 16) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        Button {
                            method = row.method
                            // The Jellyfin name is the media server's; an e-mail is typed.
                            user = row.method == .jellyfin ? (model.session?.userName ?? "") : ""
                        } label: {
                            Text(verbatim: row.title).font(Theme.body)
                                .padding(.horizontal, 26).padding(.vertical, 10)
                        }
                        .buttonStyle(HubTabStyle(selected: row.method == chosen?.method))
                    }
                }
                .focusSection()
            }
            if let chosen {
                if let label = chosen.userLabel {
                    InputField(placeholder: LocalizedStringKey(label), text: $user,
                               content: chosen.method == .jellyfin ? .username : .emailAddress)
                }
                if chosen.needsPassword {
                    InputField(placeholder: "Passwort", text: $password, safe: true, content: .password,
                               completion: { Task { await signIn(chosen, flow) } })
                }
            }

            if let error = flow.info.error {
                Text(verbatim: error)
                    // Failed is not "waiting". The sign-in went wrong, so `error`.
                    .font(Theme.small).foregroundStyle(Theme.error)
            }

            // No disabled button: while nothing is entered there is nothing to do, and a grey button claims the opposite.
            if let chosen, ready(chosen, flow) {
                Button(flow.working ? "Verbinde…" : "Anmelden") {
                    guard !flow.working else { return }
                    Task { await signIn(chosen, flow) }
                }
                .buttonStyle(ThemedButtonStyle())
            }

            Text("Swiftly speichert dein Passwort nicht, nur die Anmeldung bei Seerr.")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
        }
        .frame(width: 900, alignment: .leading)
        .padding(.top, 44)
    }

    private func ready(_ row: SwiftlyCore.SetupMethodRow, _ flow: SeerrSetupFlow) -> Bool {
        if flow.info.entry == .askAddress, address.isEmpty { return false }
        if row.userLabel != nil, user.isEmpty { return false }
        if row.needsPassword, password.isEmpty { return false }
        return true
    }

    private func signIn(_ row: SwiftlyCore.SetupMethodRow, _ flow: SeerrSetupFlow) async {
        await flow.signIn(row.method, address: address, headers: headers, name: user, password: password)
        if seerr.connected { password = "" }
    }
}

/// The page of a title the user's own server doesn't have yet.
///
/// The same page as usual, just a different action: the big button asks. Every word, state and the request
/// sheet come from the core through `SeerrTitleFlow` (shared with iPhone and Mac); this draws them for the remote.
struct SeerrDetailView: View {
    let model: AppModel
    let hit: JellyfinKit.SeerrHit

    @State private var flow: SeerrTitleFlow?
    /// Focus must move into the panel on opening; tvOS doesn't do it while the trigger stays.
    @FocusState private var firstRow: Int64?
    /// The request row: focus lands here if no season is available.
    @FocusState private var atJob: Bool
    /// Start focus belongs on the button, and returns there when the panel closes.
    @FocusState private var atButton: Bool
    /// The request being decided (its buttons are off until the page has read again).
    @State private var adminBusy: Int64?

    private var info: SwiftlyCore.SeerrTitleInfo? { flow?.info }
    private var sheet: SwiftlyCore.SeerrSheetInfo? { flow?.sheet }
    private var seasonsOpen: Bool { flow?.sheetOpen ?? false }

    init(model: AppModel, hit: JellyfinKit.SeerrHit) {
        self.model = model
        self.hit = hit
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                waitingSeasons

                // The episodes of a series, in the page's own flow right under the header (`SeerrEpisodes`).
                if let flow, flow.episodeSeasonRow != nil {
                    SeerrEpisodes(flow: flow, margin: Theme.edgePage)
                        .padding(.top, Theme.railsHeaderPadding)
                        .padding(.bottom, Theme.railsSpacing - Theme.railsPadding - Theme.railsHeaderPadding)
                }

                if let similar = flow?.similar, !similar.isEmpty {
                    railsSection {
                        RailTitle(text: "Ähnliche Titel")
                    } content: {
                        strip {
                            ForEach(similar.prefix(20)) { card in
                                NavigationLink(value: card.route) { SeerrTile(card: card, width: Theme.posterWidth) }
                                    .buttonStyle(TileStyle())
                            }
                        }
                    }
                }
                if let cast = info?.cast, !cast.isEmpty {
                    railsSection {
                        RailTitle(text: "Besetzung")
                    } content: {
                        strip {
                            ForEach(Array(cast.prefix(12).enumerated()), id: \.offset) { _, person in
                                NavigationLink(value: PersonRoute(seerrCast: person, origin: info?.title)) {
                                    CastTile(image: person.image.flatMap { URL(string: $0) },
                                             name: person.name, role: person.role)
                                }
                                .buttonStyle(TileStyle())
                            }
                        }
                    }
                }
                if flow == nil || info?.load == .offline || info?.load == .failed {
                    // Seerr's address, not the user's own server's: that one runs, or we wouldn't be on this page.
                    DisturbState(model: model, address: model.seerr.address,
                                 retry: { Task { await load() } })
                        .frame(height: Theme.posterHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Theme.completionPadding)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .imageReason(url: info?.backdrop.flatMap { URL(string: $0) } ?? hit.backdrop(width: 1280))
        // While the panel is open the rest is not a focus target, like the More sheet of the detail page.
        .defaultFocus($atButton, true, priority: .userInitiated)
        .onChange(of: seasonsOpen) { _, opened in if !opened { atButton = true } }
        .disabled(seasonsOpen)
        // Below the request button, at its edge; see `PanelAnchor`.
        .panel(under: seasonsOpen ? "staffeln" : nil) {
            requestPanel.transition(.opacity)
        }
        .animation(Theme.focusAnimation, value: seasonsOpen)
        .task { await load() }
    }

    private func load() async {
        guard model.seerr.connected else { return }
        let made = flow ?? SeerrTitleFlow(hub: model.seerr.hub, art: hit.art, tmdb: Int64(hit.id))
        flow = made
        await made.start()
    }

    private var title: String {
        guard let name = info?.title, !name.isEmpty else { return hit.title }
        return name
    }

    /// The same header as on a real detail page: backdrop right, shadow over it, text block left.
    private var header: some View {
        ZStack(alignment: .topLeading) {
            Backdrop(url: info?.backdrop.flatMap { URL(string: $0) } ?? hit.backdrop(width: 1280))
                .frame(maxWidth: .infinity, alignment: .trailing)
            HeaderShadow()
            block
                .padding(.leading, Theme.edgePage)
                .padding(.top, 140 + Theme.headerOffsetDetail)
        }
        .frame(height: Theme.heroHeightDetail, alignment: .topLeading)
        .focusSection()
    }

    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title)
                .font(Theme.titleLarge)
                .tracking(Theme.lockTitle)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(height: 68, alignment: .leading)

            HStack(spacing: 24) {
                Text(verbatim: secondaryLine)
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .lineLimit(1)
                // Status and rating in the same shell, like on the iPhone.
                ProofRow(directPlayFlag: false,
                         rating: info?.rating.flatMap { $0 > 0 ? $0 : nil },
                         own: info?.badge.map { ($0.symbol, $0.line, $0.kind.tint) })
            }
            .frame(height: 34)
            .padding(.top, 14)

            Text(verbatim: info?.overview ?? "")
                .font(Theme.body)
                .lineSpacing(Theme.descriptionPadding)
                .foregroundStyle(Theme.fontVeryQuiet)
                .lineLimit(3)
                .padding(.top, 22)
                .frame(width: 1000, height: Theme.descriptionHeight(3), alignment: .topLeading)

            action.padding(.top, 36)
        }
        .frame(width: 1000, alignment: .topLeading)
    }

    private var secondaryLine: String {
        if let line = info?.secondaryLine, !line.isEmpty { return line }
        return hit.isSeries ? String(localized: "Serie") : String(localized: "Film")
    }

    /// A status is not a button. What is waiting or loading can't be requested again; there is information instead.
    @ViewBuilder
    private var action: some View {
        if let info, info.primary.kind == .request || info.primary.kind == .locked {
            VStack(alignment: .leading, spacing: 20) {
                Button(info.primary.text) { flow?.open(season: nil) }
                    .buttonStyle(ThemedButtonStyle())
                    .disabled(!info.primary.enabled)
                    .focused($atButton)
                    .panelTrigger("staffeln")
                if let quota = flow?.quota {
                    Text(verbatim: quota)
                        .font(Theme.small)
                        .foregroundStyle(info.primary.kind == .locked ? Theme.warning : Theme.fontVeryQuiet)
                }
            }
        } else if let info, info.primary.kind != .hidden {
            inquiry(info.primary.text)
        }
    }

    /// **The action panel (620 wide)**: the core's sheet. Tapping a season row ticks it and does not close the
    /// panel; the last row is the order. The administrator's 4K / quality / folder stay out on the TV.
    private var requestPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Four rows high, the rest scrolls and focus brings the area along; the request row stays visible.
            if let rows = sheet?.rows, !rows.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            Button {
                                guard row.selectable else { return }
                                flow?.toggle(row.number)
                            } label: { seasonRow(row) }
                            .buttonStyle(RowsStyle())
                            .accessibilityAddTraits(row.selected ? [.isButton, .isSelected] : .isButton)
                            .focused($firstRow, equals: row.number)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: CGFloat(max(min(rows.count, 4), 1)) * Theme.rowsHeight)
                Rectangle().fill(Theme.margin).frame(height: 1)
            }

            if let error = sheet?.error {
                Text(verbatim: error).font(Theme.small).foregroundStyle(Theme.error)
                    .padding(.horizontal, 24).padding(.vertical, 12)
            }

            // Never send empty: while nothing is ticked the row says so and does nothing.
            let enabled = sheet?.primary.enabled ?? false
            Button {
                guard enabled else { return }
                Task { await flow?.confirm() }
            } label: {
                HStack(spacing: 22) {
                    Image(icon: "plus").frame(width: 38)
                    Text(verbatim: sheet?.primary.text ?? "")
                    Spacer(minLength: 0)
                }
                .foregroundStyle(enabled ? Theme.font : Theme.fontVeryQuiet)
            }
            .buttonStyle(RowsStyle())
            .focused($atJob)
        }
        .frame(width: 620)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        .focusSection()
        .task {
            if let first = sheet?.rows.first(where: \.selectable) { firstRow = first.number } else { atJob = true }
        }
        .onExitCommand { flow?.close() }
    }

    /// **Seasons with a request waiting, for an account that may decide** (the iPhone's "Freigeben" / "Ablehnen" under a
    /// season row): the season and its state in the core's words, two focusable buttons. The rule and the call are
    /// shared (`SeasonAdmin`); a decision reads the page again, so the season shows its new state.
    @ViewBuilder
    private var waitingSeasons: some View {
        let rows = (info?.seasons ?? []).compactMap { row in
            SeasonAdmin.waitingRequest(row, model: model).map { (row, $0) }
        }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                RailTitle(text: "Staffeln")
                ForEach(rows, id: \.0.number) { row, request in
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: row.title).font(Theme.body).foregroundStyle(Theme.font)
                            Text(verbatim: row.badge.line.isEmpty ? row.badge.word : row.badge.line)
                                .font(Theme.small).foregroundStyle(row.badge.kind.tint)
                        }
                        .frame(width: 420, alignment: .leading)
                        Button("Ablehnen") { decide(request, approve: false) }
                            .buttonStyle(ThemedButtonStyle(height: 64))
                        Button("Freigeben") { decide(request, approve: true) }
                            .buttonStyle(ThemedButtonStyle(height: 64))
                    }
                    .disabled(adminBusy == request)
                    .opacity(adminBusy == request ? 0.5 : 1)
                }
            }
            .padding(.horizontal, Theme.edgePage)
            .padding(.top, Theme.railsHeaderPadding)
            .focusSection()
        }
    }

    private func decide(_ request: Int64, approve: Bool) {
        adminBusy = request
        Task {
            await SeasonAdmin.decide(request, approve: approve, model: model, flow: flow)
            adminBusy = nil
        }
    }

    private func seasonRow(_ row: SwiftlyCore.SeerrSeasonRowInfo) -> some View {
        HStack(spacing: 22) {
            Image(icon: row.selectable ? (row.selected ? "checkmark.square.fill" : "square") : "checkmark.circle")
                .frame(width: 38)
                .foregroundStyle(row.selected ? Theme.accent : Theme.fontQuiet)
                .accessibilityHidden(true)
            Text(verbatim: row.title)
            Spacer(minLength: 0)
            if let episodes = row.episodes {
                Text(verbatim: episodes).foregroundStyle(Theme.fontQuiet)
            } else if !row.selectable {
                Text(verbatim: row.badge.word.isEmpty ? row.badge.line : row.badge.word).foregroundStyle(Theme.fontQuiet)
            }
        }
        .foregroundStyle(row.selected ? Theme.accent : (row.selectable ? Theme.font : Theme.fontQuiet))
    }

    private func inquiry(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Theme.body)
            .foregroundStyle(Theme.fontQuiet)
            .frame(width: 900, alignment: .leading)
            .padding(.vertical, 20).padding(.horizontal, 24)
            .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

/// A focus target without action: grows in focus like a tile but doesn't give way on press, since nothing happens.
private struct WatchTile<ContentBody: View>: View {
    @ViewBuilder let content: ContentBody
    @FocusState private var focus: Bool

    var body: some View {
        content
            .scaleEffect(focus ? Theme.focusMagnifier : 1)
            .animation(Theme.focusAnimation, value: focus)
            .focusable()
            .focused($focus)
    }
}

// MARK: - Home block

/// **What Seerr adds to the Home rows on the TV**, in two sections that sit in the Home row order like any other row:
/// "Anfrage ist da" (the arrival stack, `DesktopArrivalSection`: select opens it, a focusable X removes a card) and
/// "Meine Anfragen" (a rail of Seerr tiles). The core decides every word and whether anything shows (`SeerrHomeInfo`);
/// the Home page loads this together with its rows, so the block is there when the page appears. The administrator's
/// line, the lists and the queue stay out on the TV.
struct TVSeerrHomeBlock: View {
    enum Part { case arrival, requests }

    let part: Part
    let model: AppModel
    let flow: SeerrHomeFlow
    /// True while focus is on a control of the arrival stack (the Start page makes room for the open stack).
    var focusWithin: Binding<Bool> = .constant(false)
    /// Set by the Start page to put focus on the front card when the stack is the first row.
    var claimFocus: Binding<Bool> = .constant(false)

    @State private var arrived: Item?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let info = flow.block(model) {
                switch part {
                case .arrival where !info.arrivals.isEmpty:
                    DesktopArrivalSection(arrivals: info.arrivals, expanded: info.arrivalsExpanded,
                                          pending: info.state == .pending,
                                          play: { id in Task { arrived = await model.item(id: id) } },
                                          openTitle: { id in Task { arrived = await model.item(id: id) } },
                                          close: { flow.dismissArrival($0) },
                                          setExpanded: { flow.setArrivalsExpanded($0) },
                                          focusWithin: focusWithin, claimFocus: claimFocus)
                        .padding(.bottom, Theme.railsSpacing)
                        .transition(.opacity)
                case .requests where !info.rail.isEmpty:
                    railsSection {
                        RailTitle(name: info.railTitle)
                    } content: {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: Theme.gridColumn) {
                                ForEach(info.rail) { card in
                                    NavigationLink(value: card.route) { SeerrTile(card: card, width: Theme.posterWidth) }
                                        .buttonStyle(TileStyle())
                                }
                            }
                            .padding(.horizontal, Theme.edgePage)
                        }
                        .scrollClipDisabled()
                    }
                    // Pending: blank content of the last start's shape keeps the room; nothing shows or takes focus.
                    .modifier(SeerrReserved(pending: info.state == .pending))
                default:
                    EmptyView()
                }
            }
        }
        .navigationDestination(item: $arrived) { item in
            DetailView(model: model, item: item)
        }
    }
}
