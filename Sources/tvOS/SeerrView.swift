import JellyfinKit
import SwiftUI

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
        VStack(alignment: .leading, spacing: 20) {
            InputField(placeholder: "seerr.example.de", text: $address, content: .URL)
            InputField(placeholder: "Benutzername", text: $user, content: .username)
            InputField(placeholder: "Passwort", text: $password,
                        safe: true, content: .password)
            TVAdvanced(rows: $headers)

            if let error = seerr.error {
                Text(verbatim: error)
                    // Failed is not "waiting". The sign-in went wrong, so `error`; the reasoning is at the
                    // token in `Colors.swift`. Server intake and Quick Connect already do it right.
                    .font(Theme.small).foregroundStyle(Theme.error)
            }

            // No disabled button: while nothing is entered there is nothing to do, and a grey button claims the opposite.
            if !address.isEmpty, !user.isEmpty, !password.isEmpty {
                Button(seerr.reportAn ? "Verbinde…" : "Verbinden") {
                    guard !seerr.reportAn else { return }
                    Task {
                        await seerr.linkUp(address: address, user: user,
                                              password: password, headers: headers.headers)
                        if seerr.connected { password = "" }
                    }
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
}

/// A title the user's own server doesn't have yet: the TV tile.
///
/// Pale, and that is the whole message. Moving over the grid, one should see without
/// reading that there is nothing to play here.
struct SeerrTile: View {
    let hit: SeerrHit

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picture(url: hit.poster(width: 500),
                 width: Theme.posterWidth, height: Theme.posterHeight,
                 symbolText: hit.isSeries ? "tv" : "film")
                .opacity(0.45)
                .overlay(alignment: .bottomLeading) { mark.padding(10) }

            Text(verbatim: hit.title)
                .font(Theme.tile)
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
                .padding(.top, 14)

            Text(verbatim: subtitle)
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .frame(width: Theme.posterWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(hit.title), \(hit.state.announcement)"))
    }

    private var subtitle: String {
        let art = hit.isSeries ? String(localized: "Serie") : String(localized: "Film")
        return hit.year.map { "\($0) · \(art)" } ?? art
    }

    @ViewBuilder
    private var mark: some View {
        if hit.state != .present {
            // The measures of `Shared/SeerrTile.swift`, doubled. There: icon 10 semibold, text
            // `Theme.badge`, spacing 3, padding 5/7 by 3. Here it was 15 bold and 17 semibold, neither iPhone nor TV steps.
            HStack(spacing: 6) {
                Image(icon: hit.state.symbol)
                    .font(.app(size: 20, weight: .semibold))
                if let word = hit.state.shortWord {
                    Text(verbatim: word).font(Theme.badge)
                }
            }
            .foregroundStyle(Theme.reason)
            .padding(.horizontal, hit.state.shortWord == nil ? 10 : 14)
            .padding(.vertical, 6)
            .background(hit.state.color, in: Capsule())
        }
    }
}

/// The page of a title the user's own server doesn't have yet.
///
/// The same page as usual, just a different action: the big button changes from Play to Request.
struct SeerrDetailView: View {
    let model: AppModel
    let hit: SeerrHit

    /// State, words, button, season panel and the second tap live in the core (`SeerrScreen`).
    @State private var flow: SeerrCore.Flow?
    /// Focus must move into the panel on opening; tvOS doesn't do it while the trigger stays.
    @FocusState private var firstRow: Int?
    /// The request row: focus lands here if no season is available. Otherwise the panel opened and nothing in it held focus.
    @FocusState private var atJob: Bool
    /// Start focus belongs on the button, and returns there when the panel closes: a panel is
    /// not a change of place but something that opens above the button. Same reasoning as the
    /// More button of the detail page.
    @FocusState private var atButton: Bool

    private var page: SeerrCore.Page? { flow?.page }
    /// The server knows better than the search hit from before; the core keeps the newer one.
    private var state: SeerrState { page.map { SeerrCore.state($0.hit.state) } ?? hit.state }
    private var seasonsOpen: Bool { page?.sheetOpen ?? false }

    init(model: AppModel, hit: SeerrHit) {
        self.model = model
        self.hit = hit
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                // Rows like on every other page, not one block. The cast used to be a bare `ScrollView`
                // of tiles: with no button there is nothing to focus, so the remote could not get down
                // at all, and the margin came from the outer block, which no longer exists. `railsSection`
                // carries margin, title and spacing, the same function as the home, movie and series pages.
                if !similarOne.isEmpty {
                    railsSection {
                        RailTitle(text: "Ähnliche Titel")
                    } content: {
                        seerrStrip
                    }
                }
                if !cast.isEmpty {
                    railsSection {
                        RailTitle(text: "Besetzung")
                    } content: {
                        castStrip
                    }
                }
                if flow == nil || page?.disturbed == true {
                    // Jellyseerr's address, not the user's own server's: that one runs, or we wouldn't be on this page.
                    DisturbState(model: model, address: model.seerr.address,
                                 retry: { Task { await load() } })
                        .frame(height: Theme.posterHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Theme.completionPadding)
        }
        .scrollIndicators(.hidden)
        // The side margin is granted once, not twice. It was missing here, so this page alone sat
        // twice as far in: tvOS keeps 80 pt free itself and `Theme.edgePage` adds 80 again. The
        // same line with its reasoning is in `DetailView`.
        .ignoresSafeArea()
        .imageReason(url: hit.backdrop(width: 1280))
        // While the panel is open the rest is not a focus target, like the More sheet of the
        // detail page. `focusSection` only orders focus; without the lock a press to the left
        // jumps out of the panel and leaves it open.
        .defaultFocus($atButton, true, priority: .userInitiated)
        .onChange(of: seasonsOpen) { _, opened in if !opened { atButton = true } }
        .disabled(seasonsOpen)
        // Below the request button, at its edge; see `PanelAnchor`.
        .panel(under: seasonsOpen ? "staffeln" : nil) {
            seasonPanel.transition(.opacity)
        }
        .animation(Theme.focusAnimation, value: seasonsOpen)
        .task { await load() }
    }

    private func load() async {
        guard let client = model.seerr.coreClient else { return }
        let made = flow ?? SeerrCore.Flow(model: client)
        flow = made
        await made.open(SeerrCore.coreHit(hit))
    }

    /// The same header as on a real detail page.
    ///
    /// There used to be a title line without an image: the page carried only the tinted
    /// backdrop and the TMDB landscape image was never seen. Structure, measures and order are
    /// those of `DetailHeader`: backdrop right, header shadow over it, text block left at 140 + offset.
    private var header: some View {
        ZStack(alignment: .topLeading) {
            Backdrop(url: hit.backdrop(width: 1280))
                .frame(maxWidth: .infinity, alignment: .trailing)

            HeaderShadow()

            block
                .padding(.leading, Theme.edgePage)
                .padding(.top, 140 + Theme.headerOffsetDetail)
        }
        .frame(height: Theme.heroHeightDetail, alignment: .topLeading)
        .focusSection()
    }

    /// Title, facts, description, button: the order of `HeaderInfo`, with the same grades and
    /// heights. The status sits in the facts line instead of its own below, so the button stays
    /// at the height it has on every other page and the panel below hits its spot.
    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: hit.title)
                // Page title from the ladder; there is no 60 there.
                .font(Theme.titleLarge)
                .tracking(Theme.lockTitle)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(height: 68, alignment: .leading)

            HStack(spacing: 24) {
                Text(verbatim: secondaryLine)
                    // One fact: 12 on the iPhone, double here.
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .lineLimit(1)
                proofRow
            }
            .frame(height: 34)
            .padding(.top, 14)

            Text(verbatim: page?.description ?? "")
                .font(Theme.body)
                .lineSpacing(Theme.descriptionPadding)
                .foregroundStyle(Theme.fontVeryQuiet)
                .lineLimit(3)
                .padding(.top, 22)
                .frame(width: 1000, height: Theme.descriptionHeight(3),
                       alignment: .topLeading)

            action.padding(.top, 36)
        }
        .frame(width: 1000, alignment: .topLeading)
    }

    private var secondaryLine: String {
        page?.secondaryLine ?? (hit.isSeries ? String(localized: "Serie") : String(localized: "Film"))
    }

    /// Status and rating in the same shell, like on the iPhone, where both go through the same `ProofRow`.
    private var proofRow: some View {
        ProofRow(directPlayFlag: false,
                   rating: page?.rating.flatMap { $0 > 0 ? $0 : nil },
                   own: (state.symbol, state.word, state.color))
    }

    /// A status is not a button. What is waiting or loading can't be requested again; there is information instead.
    @ViewBuilder
    private var action: some View {
        if let page, page.canRequest {
            VStack(alignment: .leading, spacing: 20) {
                Button(buttonText(page)) { pressed(page) }
                    .buttonStyle(ThemedButtonStyle())
                    .focused($atButton)
                    .panelTrigger("staffeln")
                if let error = page.error {
                    // A failed request is an error, not a warning.
                    Text(verbatim: error).font(Theme.small).foregroundStyle(Theme.error)
                }
            }
        } else {
            inquiry(page?.note ?? state.hint)
        }
    }

    /// The second step says what to do: the wording (four variants, rolled once on press, never the same
    /// twice) comes from the core, the same on every platform.
    private func buttonText(_ page: SeerrCore.Page) -> String {
        if page.running { return String(localized: "Wird angefragt…") }
        if hit.isSeries { return String(localized: "Staffeln wählen") }
        return page.buttonText
    }

    /// Two steps, and the second is the actual order. With a remote a click happens especially fast.
    /// For a series the panel takes over the second step: the choice is made there and the last
    /// row triggers. The core decides what the press does.
    private func pressed(_ page: SeerrCore.Page) {
        guard !page.running else { return }
        Task { await flow?.press() }
    }

    /// The season choice is a panel, not a block in the flow.
    ///
    /// It was a plain list below the button with `.plain` buttons: tvOS painted its own white
    /// focus pill over them, the rows didn't sit in our grid, and the Menu button didn't close
    /// it because nobody listened.
    ///
    /// Structure, width, rounding, shadow and focus handling are those of `Handlungstafel`, the
    /// same panel that opens under the More button on the detail page. What differs is multiple
    /// selection: tapping a row does not close it, and the last row is the order.
    private var seasonPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Seven seasons don't fit on the screen. The panel starts at 542; seven rows of 84 plus the
            // request row are 673 and end behind the lower edge. With no area to scroll, everything from
            // the fifth on was unreachable, including the row that requests.
            //
            // Four rows high, the rest scrolls and focus brings the area along. The request row sits
            // outside it and is always visible.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(page?.seasons ?? [], id: \.number) { st in
                        Button {
                            guard st.requestable else { return }
                            flow?.toggleSeason(Int(st.number))
                        } label: {
                            seasonRow(st)
                        }
                        .buttonStyle(RowsStyle())
                        // Selected is the accent color of the whole row, as `seasonRow` says, and VoiceOver
                        // doesn't see color. Without the trait the selected season sounds like any other, and a
                        // multiple choice you can't hear isn't one.
                        .accessibilityAddTraits(st.selected
                                                ? [.isButton, .isSelected] : .isButton)
                        .focused($firstRow, equals: Int(st.number))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: panelHeight)

            Rectangle().fill(Theme.margin).frame(height: 1)

            // Never send empty. Without seasons the request means "all" to Seerr, a case nobody should
            // trigger by accident. While nothing is selected the row says so too.
            let enabled = page?.sheetButtonEnabled ?? false
            Button {
                guard enabled else { return }
                Task { await flow?.confirmSeasons() }
            } label: {
                HStack(spacing: 22) {
                    Image(icon: "plus").frame(width: 38)
                    Text(verbatim: page?.sheetButton ?? "")
                    Spacer(minLength: 0)
                }
                .foregroundStyle(enabled ? Theme.font : Theme.fontVeryQuiet)
            }
            .buttonStyle(RowsStyle())
            .focused($atJob)
        }
        .frame(width: 620)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        // No border, no shadow; see `TVBausteine`.
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        .focusSection()
        .task {
            if let first = firstSelectable { firstRow = first } else { atJob = true }
        }
        .onExitCommand { flow?.closeSheet() }
    }

    /// The row itself as its own building block so the compiler can check it in finite time;
    /// as one expression in the `label` it gave up.
    private func seasonRow(_ st: SeerrCore.SeasonRow) -> some View {
        let an = st.selected
        let free = st.requestable
        return HStack(spacing: 22) {
            Image(icon: symbolText(for: st))
                .frame(width: 38)
                .foregroundStyle(an ? Theme.accent : Theme.fontQuiet)
                // The icon is only an image; "selected" is carried by the button's trait, "already there" stands as a suffix on the row.
                .accessibilityHidden(true)
            Text(verbatim: st.title)
            Spacer(minLength: 0)
            if let episodes = st.episodes {
                Text(verbatim: episodes)
                    .foregroundStyle(Theme.fontQuiet)
            }
        }
        // What is already there is not an offer; what is selected takes the accent color of the whole row.
        // `fontQuiet` and not very quiet: on the raised surface the very quiet text is 3.12:1.
        .foregroundStyle(an ? Theme.accent : (free ? Theme.font : Theme.fontQuiet))
        // The box icon is hidden, so the status must stand as a word or the only information vanishes.
        .accessibilityHint(free ? Text("") : Text(verbatim: st.note ?? ""))
    }

    /// At most four rows, below that it scrolls. With fewer seasons the panel is exactly as tall as it has rows.
    private var panelHeight: CGFloat {
        let count = min(page?.seasons.count ?? 0, 4)
        return CGFloat(max(count, 1)) * Theme.rowsHeight
    }

    /// Box, checkmark, or the circle for what is already there.
    private func symbolText(for st: SeerrCore.SeasonRow) -> String {
        guard st.requestable else { return "checkmark.circle" }
        return st.selected ? "checkmark.square.fill" : "square"
    }

    /// Where focus lands when the panel opens: the first season that can be had at all.
    private var firstSelectable: Int? {
        (page?.seasons ?? []).first { $0.requestable }.map { Int($0.number) }
    }

    private var cast: [SeerrPerson] { (page?.cast ?? []).prefix(12).map(SeerrCore.person) }
    private var similarOne: [SeerrHit] { (page?.similar ?? []).prefix(20).map { SeerrCore.hit($0.hit) } }

    /// Every tile is a focus target, but not a button.
    ///
    /// On the TV focus moves the page; what isn't a focus target can't be reached. A header
    /// without focus made the whole row unreachable. A button without a target was the other
    /// extreme: it gave way on press and did nothing. There is no person page for TMDB heads,
    /// the same limit as on the iPhone, where they only stand there.
    private var castStrip: some View {
        strip {
            ForEach(Array(cast.enumerated()), id: \.offset) { _, person in
                WatchTile {
                    CastTile(image: person.image(width: 300),
                                     name: person.name, role: person.role)
                }
            }
        }
    }

    /// "Similar titles": missing here although Seerr delivers them and iPhone, iPad and Mac show
    /// them. Each leads to its own request page.
    private var seerrStrip: some View {
        strip {
            ForEach(similarOne) { t in
                NavigationLink(value: t) { SeerrTile(hit: t) }
                    .buttonStyle(TileStyle())
            }
        }
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
