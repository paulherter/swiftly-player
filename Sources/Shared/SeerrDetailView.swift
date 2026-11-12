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

    /// The page's state machine (state, words, button, season sheet, second tap) lives in the core.
    @State private var flow: SeerrCore.Flow?

    private var page: SeerrCore.Page? { flow?.page }
    /// The server knows better than the search hit from before; the core keeps the newer one.
    private var state: SeerrState { page.map { SeerrCore.state($0.hit.state) } ?? hit.state }

    init(model: AppModel, hit: SeerrHit) {
        self.model = model
        self.hit = hit
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.reason.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero

                    VStack(alignment: .leading, spacing: 14) {
                        proofRow
                        primaryButton
                        description
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 14)

                    // **Two rows, no tabs.** Exactly as on the movie page: a row of cast, below it a
                    // row of similar titles. As tabs with a grid this was a wall of twenty heads.
                    // Horizontally a row shows five and hints at the rest; whoever wants more
                    // scrolls.
                    cast
                    similarRail
                    if flow == nil || page?.disturbed == true {
                        // This holds Seerr's address, not the own server's: the own one is running, or you would not be on this page.
                        DisturbHint(model: model, retry: { Task { await load() } },
                                     address: model.seerr.address)
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            // The space in which `Heldbild` measures its stretch. Without it the image stayed put while scrolling instead of moving along.
            .coordinateSpace(.named("blatt"))
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
                let clamped = min(max(new, 0), Theme.heroHeightValue - 110)
                if clamped != offset { offset = clamped }
            }
            // Without this the safe area's black strip shows above the image.
            .ignoresSafeArea(edges: .top)

            // **Our own sheet, not the system's.** A `.sheet` brings its own language
            // (rounded corners at the top, grabber, navigation bar) and stood next to "More"
            // and the playlists like from another app.
            if let error = page?.error {
                HintStrip(text: error) { flow?.dismissError() }
                    .zIndex(21)
            }

            DetailHeader(title: hit.title, offset: offset) { back() }
        }
        // Which seasons: a sheet from below, attached to the side and not in the stack, since a sheet is a modifier.
        .sheet(opened: Binding(get: { page?.sheetOpen ?? false },
                               set: { if !$0 { flow?.closeSheet() } })) { seasonSheet }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        // The core opens the page and, for a series, the season list; nothing is preselected.
        .task { await load() }
    }

    private func load() async {
        guard let client = model.seerr.coreClient else { return }
        let made = flow ?? SeerrCore.Flow(model: client)
        flow = made
        await made.open(SeerrCore.coreHit(hit))
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

    /// Year, seasons or runtime, genres: the same order as there; the core words it.
    private var secondaryLine: String {
        page?.secondaryLine ?? (hit.isSeries ? String(localized: "Serie") : String(localized: "Film"))
    }

    /// **Really the same row as there.** It stood here a second time, rebuilt with the
    /// same numbers (symbol 11 heavy, word 13 medium, spacing 6 and 14). Now the page
    /// only passes in symbol, word and color; the measures live in one place.
    ///
    /// **Zero is not a rating.** For an unrated title TMDB delivers a zero, which would
    /// become "★ 0.0", a false statement. So it drops out here and not only there.
    private var proofRow: some View {
        ProofRow(rating: page?.rating.flatMap { $0 > 0 ? $0 : nil },
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
            if let page, page.canRequest {
                Button { Task { await flow?.press() } } label: {
                    HStack(spacing: 8) {
                        // No ring: the text says "Wird angefragt…".
                        Image(icon: page.buttonChecked ? "checkmark" : "plus", size: 15)
                            .font(.app(size: 15, weight: .semibold))
                            .opacity(page.running ? 0.5 : 1)
                        Text(page.buttonText)
                    }
                }
                // **The same button as "Continue", no ifs and buts.** What distinguishes it is the word on it.
                // Height, corner and font size live in the style and not here.
                .buttonStyle(PrimaryButtonStyle(stretches: true))
                .disabled(page.running)
                // The change of label should be visible, otherwise nobody reads that something changed.
                .animation(Theme.leap, value: page.buttonChecked)
            } else {
                inquiry(page?.note ?? state.hint)
            }
        }
    }

    @ViewBuilder
    private var description: some View {
        if let text = page?.description {
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
        let folks = page?.cast ?? []
        if !folks.isEmpty {
            Segment(title: "Besetzung") {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(folks.prefix(12).enumerated()), id: \.offset) { _, c in
                        let person = SeerrCore.person(c)
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
        let other = (page?.similar ?? []).map { SeerrCore.hit($0.hit) }
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
    /// A checkbox you may press that does nothing is worse than none. The rows come from the core.
    @ViewBuilder
    private var seasonList: some View {
        ForEach(page?.seasons ?? [], id: \.number) { st in
            Button {
                guard st.requestable else { return }
                flow?.toggleSeason(Int(st.number))
            } label: {
                HStack(spacing: 10) {
                    Text(verbatim: st.title)
                        .growing(15)
                        .foregroundStyle(st.requestable ? Theme.font : Theme.fontVeryQuiet)
                    if let episodes = st.episodes {
                        Text(verbatim: "· \(episodes)")
                            .growing(12).foregroundStyle(Theme.fontVeryQuiet)
                    }
                    Spacer(minLength: 8)
                    if st.requestable {
                        Image(icon: st.selected ? "checkmark.square.fill" : "square", size: 17)
                            .font(.app(size: 17))
                            .foregroundStyle(st.selected ? Theme.accent : Theme.fontVeryQuiet)
                    } else if let note = st.note {
                        Text(verbatim: note)
                            .growing(12).foregroundStyle(Theme.fontVeryQuiet)
                    }
                }
                .padding(.horizontal, Theme.edgeSpacing)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressRow())
            // The cross in the box is the accent, and the accent is color: `.isSelected` conveys the state.
            .accessibilityAddTraits(st.selected ? .isSelected : [])
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

        let enabled = page?.sheetButtonEnabled ?? false
        Button {
            Task { await flow?.confirmSeasons() }
        } label: {
            Text(verbatim: page?.sheetButton ?? "")
                .growing(15, .semibold)
                .foregroundStyle(enabled ? Theme.accent : Theme.fontVeryQuiet)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 54)
        }
        .buttonStyle(Theme.PressRow())
        .disabled(!enabled)
    }
}
