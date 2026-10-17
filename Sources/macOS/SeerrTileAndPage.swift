import JellyfinKit
import SwiftUI

/// A title the user's own server does not have yet: the Mac tile.
///
/// **Dimmed, and that is the whole message.** Someone scrolling quickly should see
/// without reading a word that there is nothing to play here. The heading above
/// only confirms it; it is not the explanation.
struct SeerrTile: View {
    let hit: SeerrHit
    @State private var hovers = false
    @State private var present = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                ImageArea(image: hit.poster(width: 342),
                            width: Theme.tileWidth, height: Theme.tileHeight,
                            symbolText: hit.isSeries ? "tv" : "film")
                    .opacity(0.45)
                mark.padding(8)
            }
            .scaleEffect(hovers ? 1.04 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: hit.title)
                    .font(Theme.tileTitleText)
                    .foregroundStyle(Theme.fontQuiet)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(Theme.secondLine)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .lineLimit(1)
            }
        }
        .frame(width: Theme.tileWidth, alignment: .leading)
        .opacity(present ? 1 : 0)
        .onAppear {
            guard !present else { return }
            withAnimation(Theme.reveal) { present = true }
        }
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(hit.title), \(hit.state.announcement)"))
    }

    private var subtitle: String {
        let art = hit.isSeries ? String(localized: "Serie") : String(localized: "Film")
        return hit.year.map { "\($0) · \(art)" } ?? art
    }

    /// **Only what adds something new.** "Kann angefragt werden" (can be requested)
    /// is already the heading above the block; a badge repeating it is noise.
    @ViewBuilder
    private var mark: some View {
        if hit.state != .present {
            HStack(spacing: 4) {
                Image(systemName: hit.state.symbol)
                    .font(Theme.badge)
                if let word = hit.state.shortWord {
                    Text(verbatim: word).font(Theme.badge)
                        .tracking(Theme.badgeLock)
                }
            }
            .foregroundStyle(Theme.reason)
            .padding(.horizontal, hit.state.shortWord == nil ? 6 : 8)
            .padding(.vertical, 3)
            .background(hit.state.color, in: Capsule())
        }
    }
}

/// The page of a title the user's own server does not have yet.
///
/// **The same page as usual, only a different action.** The big button changes
/// (*Play* becomes *Request*), and so do the rows: there are no episodes to show,
/// but there are cast and suggestions.
struct SeerrDetailView: View {
    let model: AppModel
    let hit: SeerrHit
    let back: () -> Void

    @State private var state: SeerrState
    @State private var detail: SeerrDetail?
    /// **Telling "no data" apart from "nothing to say".** With a silent Jellyseerr,
    /// `detail` stays `nil`, and description, seasons, cast and similar titles would
    /// vanish without a word, making the page look like a title with nothing to say
    /// about it.
    @State private var detailDisturbed = false
    @State private var running = false
    @State private var requested = false
    @State private var error: String?
    /// Which seasons are ticked. Empty means **all**.
    @State private var selected: Set<Int> = []
    @State private var seasonsOpen = false
    /// **Has the user already pressed it?** For a movie the request is otherwise one
    /// click away.
    @State private var confirmed = false
    /// How far the page is scrolled; the header bar fades in with it.
    @State private var headerState = HeaderState()
    /// The tone of the header image. It is needed so the page is not plain black
    /// where every other page carries the gradient.
    @State private var color = ImageColor()
    /// How tall the season list would actually be.
    @State private var listsHeight: CGFloat = 0

    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    init(model: AppModel, hit: SeerrHit, back: @escaping () -> Void) {
        self.model = model
        self.hit = hit
        self.back = back
        _state = State(initialValue: hit.state)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // **The same header as a real detail page.**
                //
                // `Backdrop` takes a plain URL, so TMDB's landscape image fits in directly. The
                // structure follows `DetailHero` in `DetailView` line by line.
                hero.zIndex(1)

                // **As on the real page:** 26 pt between the rows, the same margin, the same
                // heading style.
                VStack(alignment: .leading, spacing: 26) {
                    cast
                    similarOne
                    if detailDisturbed {
                        // Seerr's address, not the user's own server: that one is running, or the user
                        // would not be on this page.
                        DisturbHint(model: model,
                                     retry: { Task { await detailLoad() } },
                                     spacingTop: 0,
                                     address: model.seerr.address)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.top, 26)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.never)
        .pagesScroll()
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        // **The gradient from the image.**
        //
        // Every real detail page carries it: the tone continues a bit beyond the hero
        // image and fades into the base color. Without it the page is plain black.
        //
        // **The backdrop is also relevant here.** It is 1.62 times as tall as the header
        // zone and runs on with its soft fade over the cast row. With no background below,
        // it showed through and the heads became transparent towards the right.
        // `background(Theme.reason)` puts something behind it.
        .background(alignment: .top) {
            LinearGradient(colors: [color.audio, Theme.reason],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Theme.heroHeightValue + 260)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.reason)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        // **The same header bar as the real page.** It fades in when the large title
        // below it scrolls away, and the back arrow lives in it.
        // **The season list hangs on the page, not in the block.** The catcher layer lies
        // below it: a click beside it closes it, like the loading panel.
        .overlay(alignment: .topLeading) {
            if hit.isSeries, seasonsOpen {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(Theme.leap) { seasonsOpen = false }
                        }
                    seasonList
                        .padding(.leading, Theme.edgeSpacing)
                        // Below the button: the block starts at `titleHeight + 98`, and the button row
                        // inside it at 182.
                        .padding(.top, Theme.titleHeight + 98 + 182
                                       + Theme.primaryButtonHeight + 10)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            DetailHeader(title: hit.title, state: headerState, back: back)
        }
        .task { await color.load(hit.backdrop(width: 780)) }
        .task { await detailLoad() }
    }

    private func detailLoad() async {
        let fetched = await model.seerr.detail(hit)
        detailDisturbed = fetched == nil
        if let fetched { detail = fetched }
    }

    /// **The layout of `DetailHero` in `DetailView`, exactly.**
    ///
    /// Same positions, same width, same angles. Where it differs, the subject requires
    /// it: instead of "Direct Play" it shows the status, because nobody knows how a
    /// title that does not exist here would play.
    ///
    /// 0    Title         42
    /// 54   Details       20
    /// 92   Description   66 (three lines)
    /// 182  Button row    48
    /// 230  End
    private var hero: some View {
        ZStack(alignment: .topLeading) {
            // The landscape image belongs to the search result, not the detail: Seerr already
            // delivers it in the search. If it is missing, the area stays empty instead of
            // showing an enlarged poster.
            Backdrop(url: hit.backdrop(width: 1280),
                    height: Theme.heroHeightValue * 1.62)

            block
                .padding(.leading, Theme.edgeSpacing)
                .padding(.top, Theme.titleHeight + 98)
        }
        .frame(height: Theme.heroHeightValue, alignment: .topLeading)
    }

    private var block: some View {
        ZStack(alignment: .topLeading) {
            // **The title comes from TMDB and is not a key.**
            Text(verbatim: hit.title)
                .font(Theme.titleLarge)
                .tracking(Theme.lockTitle)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(width: 640, height: 42, alignment: .leading)
                .offset(y: 0)

            detailsRail
                .frame(width: 640, height: 20, alignment: .leading)
                .clipped()
                .offset(y: 54)

            Text(verbatim: detail?.description ?? "")
                .font(Theme.body)
                .lineSpacing(3)
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(width: 640, height: 66, alignment: .topLeading)
                .clipped()
                .offset(y: 92)

            action
                .frame(height: Theme.primaryButtonHeight, alignment: .leading)
                .offset(y: 182)
        }
        .frame(width: 640, height: 230, alignment: .topLeading)
    }

    /// Year, seasons or runtime, genres, rating: **one line**, not two. The real page
    /// puts everything side by side, followed by the evidence. Here the evidence is
    /// the status.
    private var detailsRail: some View {
        HStack(spacing: 14) {
            // Detail line: 12, as on the real detail page next door.
            Text(verbatim: secondaryLine)
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)
            if let rating = detail?.rating {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill").font(.system(size: 11))
                        .accessibilityHidden(true)
                    // `String(format:)` as next door: the real page shows "8.4", not "8,4". Two
                    // spellings of the same number on two pages would be inconsistent.
                    Text(verbatim: String(format: "%.1f", rating))
                        .font(Theme.tile)
                }
                .foregroundStyle(Theme.fontQuiet)
            }
            HStack(spacing: 6) {
                Image(systemName: state.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(state.word)
                    .font(Theme.tile)
            }
            .foregroundStyle(state.color)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

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

    /// **A status is not a button.** Something waiting or loading cannot be requested
    /// again; it shows a notice instead of a gray button.
    @ViewBuilder
    private var action: some View {
        if requested {
            inquiry(String(localized: "Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."))
        } else if state.requestable {
            // **The button only.** The season list used to sit next to it in a `VStack`, which
            // lives in a block with a **fixed** height (230, button row at 182). When the stack
            // grows, the button moves up instead of the list moving down. The list now hangs on
            // the page as a panel, like the loading panel.
            HStack(spacing: 12) {
                PrimaryButton(label: buttonText,
                           symbol: confirmed ? "checkmark" : "plus") { pressed() }
                    .frame(maxWidth: 320)
                if let error {
                    Text(verbatim: error)
                        .font(Theme.secondLine).foregroundStyle(Theme.warning)
                        .lineLimit(2)
                }
            }
        } else {
            inquiry(state.hint)
        }
    }

    private var buttonText: LocalizedStringKey {
        if running { return "Wird angefragt…" }
        if hit.isSeries {
            guard seasonsOpen else { return "Staffeln wählen" }
            // **The count is on the button.** Otherwise it would say "Anfragen" (Request)
            // and what is being requested could not be read off, since empty meant all.
            return selected.isEmpty ? "Staffeln wählen"
                                    : "\(selected.count) Staffeln anfragen"
        }
        return confirmed ? "Wirklich anfragen?" : "Anfragen"
    }

    /// **Two steps, and the second is the actual job.** For a series the season list
    /// takes over the second step; a movie has nothing to choose, so the button asks
    /// directly.
    private func pressed() {
        guard !running else { return }
        if hit.isSeries {
            // **With no selection nothing happens.** Empty used to mean "all", so someone who
            // only wanted to see which seasons exist requested the whole series.
            guard seasonsOpen else {
                withAnimation(Theme.leap) { seasonsOpen = true }
                return
            }
            guard !selected.isEmpty else { return }
            Task { await askFor() }
            return
        }
        guard confirmed else { confirmed = true; return }
        Task { await askFor() }
    }

    /// **What is already available cannot be ticked**, and a note beside it says so.
    private var seasonList: some View {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(detail?.seasons ?? []) { st in
                Button {
                    guard st.state.requestable else { return }
                    if selected.contains(st.number) { selected.remove(st.number) }
                    else { selected.insert(st.number) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: st.state.requestable
                              ? (selected.contains(st.number) ? "checkmark.square.fill" : "square")
                              : "checkmark.circle")
                            .font(Theme.listTitle)
                            // Multi-select checkmark: being ticked is the state of the thing itself, so it
                            // carries the accent color.
                            .foregroundStyle(selected.contains(st.number) ? Theme.accent
                                                                          : Theme.fontVeryQuiet)
                            // The checkbox is only an image; the row's selected trait carries the selection,
                            // and "already there" appears as a hint.
                            .accessibilityHidden(true)
                        Text("Staffel \(st.number)")
                            .font(Theme.body)
                            .foregroundStyle(st.state.requestable ? Theme.font
                                                                : Theme.fontVeryQuiet)
                        if st.episodes > 0 {
                            Text("· \(st.episodes) Folgen")
                                .font(Theme.secondLine).foregroundStyle(Theme.fontVeryQuiet)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .accessibilityAddTraits(selected.contains(st.number)
                                        ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint(st.state.requestable ? Text("") : Text(st.state.announcement))
            }
          }
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listsHeight = $0 }
        }
        .scrollIndicators(.never)
        // **It floats, so it casts a shadow**, like the loading panel and the action list.
        // It used to sit in the layout flow, where none was needed.
        //
        // **It is as tall as its list, at most 380.** A bare `maxHeight: 380` is not enough:
        // a `ScrollView` takes all the vertical space it can get, so with seven seasons the
        // panel would show a hand's width of empty space below.
        //
        // The content is measured, not estimated: a season row is 38 pt tall, but whether a
        // series has seven or twenty seasons only the server knows.
        .frame(maxWidth: 320, alignment: .leading)
        .frame(height: min(max(listsHeight, 38), 380))
        // No shadow, anywhere. Surface and the single edge separate the panel from the
        // background.
        .background {
            let form = RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous)
            form.fill(Theme.raised).overlay { form.strokeBorder(Theme.margin) }
        }
        .transition(.expand(from: .topLeading))
    }

    @ViewBuilder
    private var cast: some View {
        let folks = detail?.cast ?? []
        if !folks.isEmpty {
            // **Layout of `CastRail`, line by line.** The component itself takes
            // `[Person]` from the user's own server; here the heads come from TMDB. Everything
            // else is the same: 14 pt spacing, 16 semibold, the same paging row.
            VStack(alignment: .leading, spacing: 12) {
                RailTitle(text: "Besetzung")
                PagingRail(margin: 0, widthJePiece: 84 + 18, imageHeight: 84) {
                    ForEach(folks.prefix(12)) { person in
                        HeaderImage(name: person.name, role: person.role,
                                 image: person.image())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var similarOne: some View {
        let other = detail?.similarOne ?? []
        if !other.isEmpty {
            // Layout of `TitleRail`: the same heading, spacing and paging row. Only the tile
            // differs, because the title is not on the server yet.
            VStack(alignment: .leading, spacing: 12) {
                RailTitle(text: "Ähnliche Titel")
                PagingRail(margin: 0) {
                    ForEach(other) { t in
                        Button { navigator.openIt(.seerrTitle(t), in: section) } label: {
                            SeerrTile(hit: t)
                        }
                        .buttonStyle(Theme.PressButton())
                    }
                }
            }
        }
    }

    private func inquiry(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Theme.body)
            .foregroundStyle(Theme.fontQuiet)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Theme.formWidth, alignment: .leading)
            .padding(.vertical, 13).padding(.horizontal, 14)
            .background(Theme.area,
                        in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
    }

    private func askFor() async {
        error = nil
        running = true
        defer { running = false }
        do {
            // **Never empty.** `gedrueckt()` does not let it get this far; the guard appears a
            // second time here because `nil` means "all seasons" to Seerr, which is the case
            // nobody should trigger by accident.
            // **Series only.** A movie has no seasons, so `selected` is empty there and the
            // request was silently discarded.
            let seasons: [Int]?
            if hit.isSeries {
                guard !selected.isEmpty else { return }
                seasons = Array(selected).sorted()
            } else {
                seasons = nil
            }
            try await model.seerr.askFor(hit, seasons: seasons)
            requested = true
            state = .waitsSharing
        } catch {
            self.error = readableError(error)
        }
    }
}
