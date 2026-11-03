import JellyfinKit
import SwiftUI

/// Search. No `.searchable`: on the Mac it brings its own bar, corners and
/// material. Same field as the sign-in screen, just wider.
struct SearchView: View {
    let model: AppModel
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    #if DEBUG
    @State private var term = WindowOffPull.searchTerm ?? ""
    #else
    @State private var term = ""
    #endif
    @State private var headerState = HeaderState()
    /// An account switch is in progress: content holds still, then appears staggered.
    @State private var change = false
    @State private var hit: [Item] = []
    /// What Seerr knows and the own server does not; empty if nothing is connected.
    @State private var seerrHit: [SeerrHit] = []
    @State private var searched = false
    /// The last search term; the empty-state text names this term, not whatever is
    /// currently in the field.
    @State private var searchedHandle = ""
    /// **`nil` means failed, `[]` means nothing found.** `model.search` returns the two
    /// separately; `a ?? []` here turned a network error into "nothing found".
    @State private var disrupted = false
    /// A request is running: show the grid placeholder instead of a spinner.
    @State private var loads = false
    @FocusState private var inField: Bool

    /// **Recent searches.** Stored on the device, not on the server: the list is a
    /// convenience, not part of the account.
    ///
    /// Recorded on submit, not while typing: typing "Ga", "Gam", "Game" is one search,
    /// not three. The rule lives in `SearchHistory`; TV and iPhone show the same list.
    @AppStorage(SearchHistory.key) private var lastRaw = ""

    private var last: [String] { SearchHistory.list(lastRaw) }

    /// **What there is to search.** Shown only while the field is empty and there is
    /// no history, otherwise a hint would sit above the thing it explains.
    ///
    /// Centered under the field, not in the window: the field is left-aligned at its
    /// own width, and a hint centered in the whole area would float away from what it
    /// refers to.
    private var emptyHint: some View {
        // **Use the shared component, not a second variant.** This used to be a glyph at
        // size 30 `.light`, a weight that is not on the scale, with no circle and its own
        // layout. The same file uses the component two lines further down.
        EmptyState(symbol: "magnifyingglass",
                    headerLine: "Filme, Serien und Folgen durchsuchen")
        .frame(maxWidth: Theme.formWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 70)
    }

    /// "Zuletzt gesucht": the iPhone list. Plain rows under the heading, no card: the
    /// card made a convenience look like a settings group.
    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                category("Zuletzt gesucht")
                Spacer(minLength: 8)
                Button { lastRaw = "" } label: {
                    Text("Löschen")
                        .growing(13, .medium)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
            }
            .padding(.top, 26)

            ForEach(Array(last.enumerated()), id: \.offset) { spot, word in
                Button { term = word } label: {
                    HStack(spacing: 12) {
                        Image(icon: "clock.arrow.circlepath")
                            .font(Theme.body)
                            .foregroundStyle(Theme.font)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text(verbatim: word)
                            .growing(15, .semibold)
                            .foregroundStyle(Theme.font)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressRow())
                if spot < last.count - 1 {
                    SheetLine().padding(.leading, 32)
                }
            }
        }
        .frame(maxWidth: Theme.readWidth, alignment: .leading)
    }

    /// The heading of every search block, the iPhone's level: section size, white.
    private func category(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Theme.section)
            .tracking(Theme.lockSection)
            .foregroundStyle(Theme.font)
    }

    /// **Hits grouped by kind, as on iPhone**: Serien, Filme, Folgen, Weiteres. One
    /// mixed grid made the reader check each tile for what it is.
    @ViewBuilder
    private func group(_ label: LocalizedStringKey, _ entries: [Item]) -> some View {
        if !entries.isEmpty {
            // Group title 22/700, margin 30 0 12 (design).
            Text(label)
                .font(Theme.section)
                .tracking(-0.2)
                .foregroundStyle(Theme.font)
                .padding(.top, 30)
                .padding(.bottom, 12)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(entries, id: \.id) { entryRecord in
                    Button { navigator.openIt(.title(entryRecord), in: section) } label: {
                        SearchPoster(model: model, entry: entryRecord)
                    }
                    .buttonStyle(Theme.PressButton())
                    .tileMenu(entryRecord, model: model)
                }
            }
        }
    }

    /// Retry: same term, new attempt. Otherwise the user would have to append a
    /// character and delete it again.
    private func stillInTimes() {
        let word = term
        term = ""
        Task { @MainActor in term = word }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 120, maximum: 120), spacing: 16, alignment: .topLeading)]
    }

    /// The Seerr tiles keep the shared tile size.
    private var seerrColumns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.tileWidth, maximum: Theme.tileWidth),
                  spacing: Theme.tileSpacing, alignment: .topLeading)]
    }

    /// The field: 520 x 40, radius 12, surface fill; focus = 3 pt accent ring at 35 % plus a
    /// 1 pt accent edge.
    private var field: some View {
        HStack(spacing: 10) {
            Image(icon: "magnifyingglass", size: 16)
                .font(.app(size: 16))
                .foregroundStyle(Theme.fontVeryQuiet)
                .accessibilityHidden(true)
            TextField("", text: $term,
                      prompt: Text("Titel, Serie, Person").foregroundColor(Theme.fontVeryQuiet))
                .textFieldStyle(.plain)
                .font(.app(size: 15))
                .foregroundStyle(Theme.font)
                .focused($inField)
                .onSubmit { lastRaw = SearchHistory.remember(term, in: lastRaw) }
            if !term.isEmpty {
                Button { term = ""; inField = true } label: {
                    Image(icon: "xmark.circle.fill", size: 16)
                        .font(.app(size: 16))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Löschen"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .frame(maxWidth: 520)
        .background(Theme.area, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background {
            if inField {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.accent.opacity(0.35), lineWidth: 6)
            }
        }
        .overlay {
            if inField {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1)
            }
        }
        .animation(Theme.timeFloat, value: inField)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MacPageTitle(text: "Suche", bottom: 16)

                field

                // With nothing in the field: where the user left off. A click searches it again.
                if term.isEmpty {
                    if last.isEmpty { emptyHint } else { recent }
                }

                if loads, hit.isEmpty, seerrHit.isEmpty {
                    // **No spinner.** The grid is already shown in its final shape and is cross-faded
                    // as soon as the results arrive, as on iPhone and TV.
                    GridPlaceholder(columns: 6, rails: 2)
                        .padding(.top, 24)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                } else if !hit.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        group("Serien", hit.filter { $0.type == "Series" })
                        group("Filme", hit.filter { $0.type == "Movie" })
                        group("Folgen", hit.filter { $0.type == "Episode" })
                        group("Weiteres", hit.filter {
                            !["Series", "Movie", "Episode"].contains($0.type ?? "")
                        })
                    }
                } else if searched, disrupted, !term.isEmpty, seerrHit.isEmpty {
                    // Same text as in the library, including the server address: one cause, one
                    // diagnosis.
                    EmptyState(
                        symbol: "externaldrive.badge.xmark",
                        headerLine: "Server ist abgetaucht",
                        text: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                        primaryButton: ("Erneut versuchen", { stillInTimes() }))
                        .padding(.top, 120)
                } else if searched, !term.isEmpty, seerrHit.isEmpty {
                    // **Both empty, not just the library.** With `hit.isEmpty` here, this branch
                    // would win as soon as the own server has nothing, and the Seerr block below would
                    // never be reached, which is exactly the case the integration exists for.
                    // Wording and symbol match iPhone: the search says what it found nothing for, and
                    // the second sentence softens it.
                    EmptyState(symbol: "magnifyingglass",
                                headerLine: "Nichts gefunden zu \u{201E}\(searchedHandle)\u{201C}",
                                text: "Auf deinem Server steht dazu nichts. Manchmal ist es nur ein Buchstabe.")
                        .padding(.top, 120)
                }

                if !seerrHit.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        // The iPhone wording: it says which way the request goes.
                        category("Über Seerr anfragen")
                        Spacer(minLength: 8)
                        CountMark(count: seerrHit.count)
                    }
                    .padding(.top, hit.isEmpty ? 30 : 40)

                    LazyVGrid(columns: seerrColumns, alignment: .leading, spacing: 20) {
                        ForEach(seerrHit) { t in
                            Button { navigator.openIt(.seerrTitle(t), in: section) } label: {
                                SeerrTile(hit: t)
                            }
                            .buttonStyle(Theme.PressButton())
                        }
                    }
                    .padding(.top, 18)
                }
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        // The look's glow, the same on every main page; goes up with the content.
        .lookGlow()
        .scrollIndicators(.never)
        // ‹ › and, once scrolled, the page name, as on every main page.
        .overlay(alignment: .top) {
            StateBar(title: "Suche", state: headerState)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        .accountSwitchFade(model: model, ready: true, change: $change)
        // Term and results belong to the previous account.
        .onChange(of: model.accountSwitch) { _, _ in
            term = ""; hit = []; seerrHit = []
            searched = false; disrupted = false; loads = false
        }
        // **The milky bar at the top edge.** macOS 26 adds it over every scroll view by
        // itself; it is not in our code. Over the image it was barely visible, on a plain
        // background to the left it showed as a bar. Anything the framework adds unasked
        // has to be switched off just like anything we add ourselves.
        .pagesScroll()
        .onAppear { inField = true }
        .task(id: "\(term)|\(model.listenRefresh)") {
            // **The rule comes from the package, not from here.** This used to be
            // `term.count > 1`: same result but without trimming, so a space plus one letter
            // triggered a request on the Mac but not on iPhone, and the threshold would have
            // been changed in one place only.
            guard DisplayRules.searchTermFits(term) else {
                hit = []; seerrHit = []; searched = false
                disrupted = false; loads = false; return
            }
            // Debounce instead of querying on every keystroke.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            loads = true
            // **Own server first, Seerr after.** Seerr is an extra; whatever the own server
            // has appears immediately. The term is sent trimmed.
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
            async let foreignOnes = model.seerr.searching(clean)
            let a = await model.search(clean)
            // A cancelled run writes nothing, otherwise "server unreachable" or an empty area
            // would flash up for a moment.
            guard !Task.isCancelled else { return }
            // Drop duplicate ids before they go into a `ForEach`.
            disrupted = a == nil
            hit = ListRules.withoutDouble(a ?? [])
            searchedHandle = clean
            if !hit.isEmpty { searched = true }
            let b = await foreignOnes
            guard !Task.isCancelled else { return }
            // Anything already on the server belongs in the upper block.
            seerrHit = b.filter { !$0.state.alreadyPresent }
            searched = true
            loads = false
        }
        .onReceive(NotificationCenter.default.publisher(for: CommandPost.name)) { post in
            if CommandPost.receive(post) == .search { inField = true }
        }
    }
}

/// A search hit: poster 120 x 180 radius 10, title 14/600, year 12 in the quiet tone.
private struct SearchPoster: View {
    let model: AppModel
    let entry: Item
    @State private var hovers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ImageArea(image: model.imageURL(for: entry, portrait: true),
                      width: 120, height: 180,
                      progress: entry.userData?.playedPercentage.map { $0 / 100 },
                      symbolText: entry.tileCharacter)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let mark = DisplayRules.tileMark(
                        art: entry.type,
                        seasons: entry.childCount,
                        watched: entry.userData?.played,
                        openEpisodes: entry.userData?.unplayedItemCount) {
                        TileBadge(mark: mark)
                    }
                }
                .scaleEffect(hovers ? 1.04 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.name)
                    .font(.app(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                if !entry.hitInfo.isEmpty {
                    Text(verbatim: entry.hitInfo)
                        .font(.app(size: 12))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 120, alignment: .leading)
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityElement(children: .combine)
    }
}
