import JellyfinKit
import SwiftUI

/// The page of a title the own server does not have yet.
///
/// **The same page as usual, just a different action.** Swapped are the big button
/// (*Continue* becomes *Request*) and the tabs: there are no episodes to show, but
/// cast and suggestions.
///
/// **The structure is the series page's, line by line.** That is not convenience
/// but the lesson of three rounds. Rebuilding the page misses the spacing: the
/// header sat lower, the image stuck while scrolling, and a gradient showed at the
/// top that never existed there. Each of these three deviations was a component
/// that already existed and went unused: `Heldbild` measures itself in the "blatt"
/// space, `DetailHeader` brings its own, much weaker gradient, and
/// `.ignoresSafeArea(edges: .top)` is why the image reaches the top at all.
///
/// What deviates here does so on purpose and has a comment.
struct SeerrDetailView: View {
    let model: AppModel
    let hit: SeerrHit

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide

    /// How far scrolled; the header fades in after that. As there.
    /// How tall the season list is in total, measured so the sheet does not get taller
    /// than its content.
    @State private var listsHeight: CGFloat = 0
    @State private var offset: CGFloat = 0

    @State private var state: SeerrState
    @State private var running = false
    @State private var error: String?
    @State private var requested = false
    @State private var detail: SeerrDetail?
    /// **The difference the page did not know before.** With a silent Jellyseerr
    /// `detail` stayed `nil`, and description, seasons, cast and similar vanished
    /// without a word; the page looked like a title there is nothing to say about.
    @State private var detailDisturbed = false
    /// Which seasons are ticked. Empty means **all**, as on first open when nobody has selected anything.
    @State private var selected: Set<Int> = []
    @State private var sheetOpen = false
    /// **Has the user pressed once already?** For a movie the request is otherwise a
    /// finger's width away. For a series the season sheet asks anyway, which is the
    /// second step there.
    @State private var confirmed = false
    /// Which of the four confirmations is showing. Drawn on tap, not on render.
    @State private var version = 0

    init(model: AppModel, hit: SeerrHit) {
        self.model = model
        self.hit = hit
        _state = State(initialValue: hit.state)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.reason.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // **Wide, the same header as a real detail page.**
                    //
                    // Landscape used to show the narrow layout here: a strip across the full width,
                    // title below, button below. On a 1000 point wide window that is the mail slot
                    // `HeroHeader` was built against, and the page stood next to movie and series like
                    // from another app. On the Mac that is exactly the difference: poster and text
                    // side by side, the description as its own block below.
                    //
                    // No progress: what does not exist here yet, nobody has half seen.
                    if wide {
                        HeroHeader(image: hit.backdrop(),
                                 poster: hit.poster(),
                                 title: hit.title,
                                 secondaryLine: secondaryLine) {
                            VStack(alignment: .leading, spacing: 14) {
                                proofRow
                                primaryButton
                            }
                        }
                        description
                            .frame(maxWidth: Theme.readWidth, alignment: .leading)
                            .padding(.horizontal, Theme.edgePageWide)
                            .padding(.top, 18)
                            .padding(.bottom, 22)
                    } else {
                    hero

                    VStack(alignment: .leading, spacing: 14) {
                        proofRow
                        primaryButton
                        description
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 14)
                    }

                    // **Two rows, no tabs.** Exactly as on the movie page: a row of cast, below it a
                    // row of similar titles. As tabs with a grid this was a wall of twenty heads.
                    // Horizontally a row shows five and hints at the rest; whoever wants more
                    // scrolls.
                    cast
                    similarRail
                    if detailDisturbed {
                        // This holds Seerr's address, not the own server's: the own one is running, or you would not be on this page.
                        DisturbHint(model: model, retry: { Task { await detailLoad() } },
                                     address: model.seerr.address)
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            // The space in which `Heldbild` measures its stretch. Without it the image stayed put while scrolling instead of moving along.
            .coordinateSpace(.named("blatt"))
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
                offset = new
            }
            // Without this the safe area's black strip shows above the image.
            .ignoresSafeArea(edges: .top)

            // **Our own sheet, not the system's.** A `.sheet` brings its own language
            // (rounded corners at the top, grabber, navigation bar) and stood next to "More"
            // and the playlists like from another app.
            if let error {
                HintStrip(text: error) { self.error = nil }
                    .zIndex(21)
            }

            DetailHeader(title: hit.title, offset: offset) { back() }
        }
        // Which seasons: a sheet from below, attached to the side and not in the stack, since a sheet is a modifier.
        .sheet(opened: $sheetOpen) { seasonSheet }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        // **The question does not stand forever.** Whoever taps the button once and
        // keeps reading should not find, minutes later, a button that requests on the very
        // next tap.
        .task(id: confirmed) {
            guard confirmed else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            // **After an error it stays.** Whoever confirmed and gets an error message has
            // already given their answer; the next tap is the retry, not the question again.
            // Likewise do not take it back while the request is running.
            guard !running, error == nil else { return }
            confirmed = false
        }
        // **Nothing preselected.** Nobody downloads all of them normally: whoever wants
        // everything ticks everything; whoever wants one should not have to deselect
        // eight first.
        .task { await detailLoad() }
    }

    private func detailLoad() async {
        let fetched = await model.seerr.detail(hit)
        detailDisturbed = fetched == nil
        if let fetched {
            detail = fetched
            // The server knows better than the search hit from before.
            if let new = fetched.state { state = new }
        }
    }

    // MARK: Parts

    /// Word for word as `SeriesDetailView.hero`, only with TMDB's landscape image instead of the own server's.
    private var hero: some View {
        HeroImage(url: hit.backdrop())
            .overlay(alignment: .bottom) { HeroRunOut() }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: hit.title)
                        .font(Theme.title)
                        .tracking(Theme.lockTitle)
                        .foregroundStyle(Theme.font)
                    Text(verbatim: secondaryLine)
                        // Year, runtime, genre are one statement: 12, as under every other hero image. Before: 13 Regular, a step that does not exist.
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(1)
                }
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.bottom, 16)
            }
    }

    /// Year, seasons or runtime, genres: the same order as there.
    private var secondaryLine: String {
        var parts: [String] = []
        if let year = hit.year { parts.append("\(year)") }
        if hit.isSeries {
            let n = detail?.seasons.count ?? 0
            if n > 0 { parts.append(n == 1 ? String(localized: "1 Staffel")
                                           : String(localized: "\(n) Staffeln")) }
        } else if let m = detail?.runtime, m > 0 {
            parts.append(String(localized: "\(m) Min."))
        }
        let genres = detail?.genres ?? []
        if !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        if parts.isEmpty {
            parts.append(hit.isSeries ? String(localized: "Serie")
                                          : String(localized: "Film"))
        }
        return parts.joined(separator: " · ")
    }

    /// **Really the same row as there.** It stood here a second time, rebuilt with the
    /// same numbers (symbol 11 heavy, word 13 medium, spacing 6 and 14). Now the page
    /// only passes in symbol, word and color; the measures live in one place.
    ///
    /// **Zero is not a rating.** For an unrated title TMDB delivers a zero, which would
    /// become "★ 0.0", a false statement. So it drops out here and not only there.
    private var proofRow: some View {
        ProofRow(rating: (detail?.rating).flatMap { $0 > 0 ? $0 : nil },
                   own: (symbol: state.symbol, word: state.word, color: state.color))
    }

    /// **A status is not a button.**
    ///
    /// What waits or loads cannot be requested again; a statement stands there instead
    /// of a gray button.
    ///
    /// The surrounding stack is that of `SeriesDetailView.primaryButton`: the same
    /// `VStack(spacing: 9)`, so the row below sits at the same height as "25 minutes
    /// left" there.
    @ViewBuilder
    private var primaryButton: some View {
        VStack(alignment: .leading, spacing: 9) {
            if requested {
                inquiry(String(localized: "Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."))
            } else if state.requestable {
                Button(action: pressed) {
                    HStack(spacing: 8) {
                        // No ring: the text says "Wird angefragt…".
                        Image(systemName: confirmed ? "checkmark" : "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .opacity(running ? 0.5 : 1)
                        Text(buttonText)
                    }
                }
                // **The same button as "Continue", no ifs and buts.** It was once in accent, but
                // the status above already carries it, and the same color twice on a page turns a
                // signal for state into a base color. What distinguishes it is the word on it.
                //
                // Height, corner and font size live in the style and not here; a rebuilt button
                // sat visibly lower and rounder.
                .buttonStyle(PrimaryButtonStyle(stretches: !wide))
                .disabled(running)
                // The change of label should be visible, otherwise nobody reads that something changed.
                .animation(Theme.leap, value: confirmed)
            } else {
                inquiry(state.hint)
            }
        }
    }

    /// **The second step says what to do.**
    ///
    /// It used to say "Really request?" (feedback: "you don't understand that you have
    /// to press again"). A button with a question on it is a question without an
    /// answer: you do not know whether pressing confirms or cancels. Every version
    /// therefore starts with "Nochmal": the instruction first, the punchline behind.
    ///
    /// Four versions, and the dice are rolled **once**, on tap: otherwise the text
    /// would change under the finger whenever the view redraws. The same one never
    /// comes twice in a row.
    ///
    /// No emoji: the symbol stays the checkmark and the mood is in the word. Once
    /// Seerr can undo, the confirmation drops entirely: the request then happens
    /// immediately and offers "Undo". The model lacks the withdraw
    /// call for that; until it exists, a tap without confirmation would not be
    /// reversible.
    private static let confirmations: [LocalizedStringResource] = [
        "Nochmal, dann läuft’s", "Nochmal — ab die Post",
        "Nochmal, dann frag ich", "Nochmal, her damit"
    ]

    private var buttonText: String {
        if running { return String(localized: "Wird angefragt…") }
        guard confirmed else { return String(localized: "Anfragen") }
        return String(localized: Self.confirmations[version])
    }

    /// **Two steps, and the second is the actual order.**
    ///
    /// For a series the season sheet takes the second step: it states again what is
    /// requested, and the button in it triggers. A movie has nothing to select, so here
    /// the button asks itself instead of opening a sheet that holds only a question.
    private func pressed() {
        if hit.isSeries {
            sheetOpen = true
            return
        }
        guard confirmed else {
            // Roll once, and not the same as last time.
            let other = (0 ..< Self.confirmations.count).filter { $0 != version }
            version = other.randomElement() ?? 0
            confirmed = true
            return
        }
        Task { await askFor() }
    }

    @ViewBuilder
    private var description: some View {
        if let text = detail?.description {
            CollapsibleText(text: text)
        }
    }

    /// Word for word as `ItemDetailView.cast`, only with TMDB's heads instead of
    /// the own server's, including the limit at twelve.
    ///
    /// No arrow beside it: a page with the full cast does not exist here, and an arrow
    /// would promise one.
    @ViewBuilder
    private var cast: some View {
        let folks = detail?.cast ?? []
        if !folks.isEmpty {
            Segment(title: "Besetzung") {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(folks.prefix(12)) { person in
                        CastTile(image: person.image(), name: person.name,
                                         role: person.role)
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
            }
        }
    }

    /// The same row as there, with `SeerrTile` instead of `PosterTile`, because the
    /// suggestions are not on the server either and belong pale.
    ///
    /// The fixed measure lives here and not in the tile: in the search grid it gets its
    /// width from the column, in a row it has none.
    @ViewBuilder
    private var similarRail: some View {
        let other = detail?.similarOne ?? []
        if !other.isEmpty {
            Segment(title: "Ähnliche Titel") {
                HStack(alignment: .top, spacing: Theme.tileSpacing) {
                    ForEach(other) { t in
                        NavigationLink(value: t) {
                            SeerrTile(hit: t).frame(width: Theme.tileWidth)
                        }
                        .buttonStyle(Theme.PressButton())
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
            }
        }
    }

    // MARK: Status in words

    // Symbol, word, color and hint live in `SeerrMark.swift`, the same table the tile reads. It used to exist here a second time, with other symbols and other colors.

    private func inquiry(_ text: String) -> some View {
        Text(verbatim: text)
            // **Growing with the text, not fixed**. Applies to the
            // statement, the season rows and the button in the sheet; their heights are
            // therefore minimum heights. Fixed stay the page title above the hero image and
            // its subline: the bar there carries an image.
            .growing(15)
            .foregroundStyle(Theme.fontQuiet)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 13).padding(.horizontal, 14)
            // Surface measure, not field measure: the box is a surface, not an input field. It was 10 because that was the number nearby.
            .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
    }

    // MARK: Seasons

    /// The seasons to tick.
    ///
    /// **What is already there cannot be ticked** and says beside it that it is there.
    /// A checkbox you may press that does nothing is worse than none.
    @ViewBuilder
    private var seasonList: some View {
        ForEach(detail?.seasons ?? []) { st in
            Button {
                guard st.state.requestable else { return }
                if selected.contains(st.number) { selected.remove(st.number) }
                else { selected.insert(st.number) }
            } label: {
                HStack(spacing: 10) {
                    Text("Staffel \(st.number)")
                        .growing(15)
                        .foregroundStyle(st.state.requestable ? Theme.font
                                                            : Theme.fontVeryQuiet)
                    if st.episodes > 0 {
                        Text("· \(st.episodes) Folgen")
                            .growing(12).foregroundStyle(Theme.fontVeryQuiet)
                    }
                    Spacer(minLength: 8)
                    if st.state.requestable {
                        Image(systemName: selected.contains(st.number)
                                ? "checkmark.square.fill" : "square")
                            .font(.system(size: 17))
                            .foregroundStyle(selected.contains(st.number)
                                ? Theme.accent : Theme.fontVeryQuiet)
                    } else {
                        Text(st.state == .present ? "vorhanden" : "unterwegs")
                            .growing(12).foregroundStyle(Theme.fontVeryQuiet)
                    }
                }
                .padding(.horizontal, Theme.edgeSpacing)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressRow())
            // The cross in the box is the accent, and the accent is color: read aloud a ticked season sounded like any other. `.isSelected` conveys the state.
            .accessibilityAddTraits(selected.contains(st.number) ? .isSelected : [])
        }
    }

    /// What is in the sheet. Body, motion and grabber come from ``Blattmodifikator``.
    @ViewBuilder
    private var seasonSheet: some View {
        SheetCategory(text: Text("Welche Staffeln?"))

        ScrollView {
            VStack(spacing: 0) { seasonList }
                // Measured, not assumed.
                .onGeometryChange(for: CGFloat.self) { $0.size.height }
                    action: { listsHeight = $0 }
        }
        // **As tall as the seasons, at most 320.**
        //
        // There used to be `.frame(maxHeight: 320)`, and that is not enough: a
        // `ScrollView` is vertically greedy and takes the 320 even when three seasons need
        // only 150. What remained was a hollow of a good two centimeters under the last
        // row, doing nothing. Feedback: "there are about 2 cm free, as if something were
        // there that is not."
        //
        // The same calculation as in `SelectionSheet`, where it is already explained.
        .frame(height: min(listsHeight, 320))
        .scrollIndicators(.hidden)

        // Full width, because the button below is too.
        SheetLine()

        Button {
            sheetOpen = false
            Task { await askFor() }
        } label: {
            Text(selected.isEmpty ? "Staffel wählen"
                                  : "\(selected.count) anfragen")
                .growing(15, .semibold)
                .foregroundStyle(selected.isEmpty ? Theme.fontVeryQuiet : Theme.accent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 54)
        }
        .buttonStyle(Theme.PressRow())
        .disabled(selected.isEmpty)
    }

    private func askFor() async {
        error = nil
        running = true
        defer { running = false }
        do {
            // Empty means all; Seerr understands the word `all`, and whoever ticked nothing
            // does not want nothing.
            // **Never empty.** `nil` means "all seasons" to Seerr, and that is the case nobody
            // should trigger by accident: whoever only looks at which ones exist would
            // otherwise request the whole series.
            //
            // **Only for series.** A movie has no seasons, `selected` is always empty there;
            // the guard silently threw it out, and pressing "Request" did nothing at all.
            let seasons: [Int]?
            if hit.isSeries {
                guard !selected.isEmpty else { return }
                seasons = Array(selected).sorted()
            } else {
                seasons = nil
            }
            try await model.seerr.askFor(hit, seasons: seasons)
            // **Read the state, do not assume.** If Seerr approves the request immediately, the title is "loading" or there, not "waiting".
            selected = []
            await detailLoad()
            if state.requestable { state = .waitsSharing }
            requested = state == .waitsSharing
        } catch {
            self.error = readableError(error)
        }
    }
}
