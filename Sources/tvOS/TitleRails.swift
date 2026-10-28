import JellyfinKit
import SwiftUI

// MARK: - The row section

/// Header and strip of a row, with the layout's spacing.
/// **A function, not a `View` struct**, and that is not taste. tvOS keeps a
/// row title clear on focus only if it is a `Section` header (WWDC24, "Migrate
/// your TVML app to SwiftUI"). With the `Section` inside the `body` of its own
/// struct, the stack above sees only that struct and the section property is
/// lost. A function returning `some View` passes the section through
/// unchanged.
/// Spacing, in one place:
///
///     above title      railsHeaderPadding   24
///     title to tiles   titleSpacing     36  (16 + railsPadding)
///     row to row       railsSpacing    72  (28 + 20 + 24)
///
/// Home, movie and series pages use the same function. Copying it lets the
/// pages drift apart, as already happened with `loadMore()`.
func railsSection<Header: View, ContentBody: View>(
    @ViewBuilder header: () -> Header,
    @ViewBuilder content: () -> ContentBody
) -> some View {
    Section {
        content()
            .padding(.bottom, Theme.railsSpacing - Theme.railsPadding - Theme.railsHeaderPadding)
    } header: {
        header()
            .padding(.horizontal, Theme.edgePage)
            .padding(.top, Theme.railsHeaderPadding)
            .padding(.bottom, Theme.titleSpacing - Theme.railsPadding)
    }
}

extension View {
    /// **A horizontal row fades out in the left margin instead of being cut.**
    /// See the mask in `strip`; the season row on the series page uses the same edge.
    nonisolated func leadingEdgeFade() -> some View {
        mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .white],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: Theme.edgePage)
                Color.white
            }
        }
    }
}

/// The horizontal surface under a row header.
/// `scrollClipDisabled` is a requirement, not polish: the focused tile grows
/// by 1.08 beyond its layout size and the surface would clip it at its edge.
/// `railsPadding` absorbs the same growth vertically **inside** the row, which
/// is the only reason the vertical surface above may clip without cutting a
/// tile.
/// **`height` makes the row independent of focus.** Without it SwiftUI
/// measures the row by its content, which grows once a tile is focused
/// (`focusMagnifier` 1.08). The row was measured at different heights depending on
/// focus, and its gap to the row header changed on entering and leaving. It
/// looked like a difference **between seasons** but was one between focused
/// and not. A fixed height on the container did not help: the horizontal
/// strip is greedy there and centers its content. It belongs on the surface
/// itself. `railsPadding` still absorbs the growth so the larger tile fits
/// inside this height instead of being clipped.
func strip<ContentBody: View>(state: Binding<String?>? = nil,
                            height: CGFloat? = nil,
                            runOut: CGFloat? = nil,
                            @ViewBuilder _ content: () -> ContentBody) -> some View {
    let area = ScrollView(.horizontal) {
        // Horizontally the lazy stack stays: nobody sets focus from outside here,
        // so no assignment can go to a tile not yet created. The home page differs
        // and uses an `HStack` for exactly that reason.
        LazyHStack(alignment: .top, spacing: Theme.tileSpacing, content: content)
            // Only so `scrollPosition` can say which tile is at the front. No
            // `scrollTargetBehavior` on purpose: nothing should snap.
            .scrollTargetLayout()
    }
    .frame(height: height)
    // **The focus margin sits outside, not in the content.**
    // As `padding` on the `LazyHStack` it was **inside** the scroll surface,
    // where it takes effect only once the surface really measures its content,
    // which happens when focus enters. On opening it was missing and the tiles
    // sat 20 pt too high; on first focus it appeared and everything shifted.
    // Measured from two screenshots: the row title stays at 683 in both, the
    // tiles at 742 and 762. The difference is exactly `railsPadding`, so it was
    // never scrolling or section behavior, though both looked likely.
    // Outside, it is part of the layout and always applies. The grown tile is
    // still not clipped, thanks to `scrollClipDisabled`.
    .padding(.vertical, Theme.railsPadding)
    // **Fade out at the left edge, do not cut.**
    // When the row is scrolled forward, the previous tile sits in the side margin
    // and would be cut off hard, label included. Painting over does not work: the
    // background is tinted, and a #0B0B0D surface would show as a patch. So a
    // mask as wide as the margin. It costs nothing when not scrolled: the first
    // tile starts at `edgePage`, exactly where the mask is fully opaque.
    .leadingEdgeFade()
    .scrollClipDisabled()
    .scrollIndicators(.hidden)
    // **The side margin is a content margin, not padding.**
    // As `padding` on the stack it was *inside* the scroll surface, and
    // `scrollPosition(anchor: .leading)` below aligns the target tile to the
    // **surface** edge, not the margin: the 80 pt scrolled out too and the
    // episode row stuck to the screen edge. Visible only where a binding is
    // passed; the home page without `state` always looked right.
    // `contentMargins` belongs to the surface, not the content, and is counted
    // when scrolling to a target.
    .contentMargins(.leading, Theme.edgePage, for: .scrollContent)
    // **Enough room on the right for the last tile to sit at the front**
    // (`runOut`). Without it the surface ended as soon as the last tile hit the
    // right edge: in a season of ten episodes E8 could not be scrolled to the
    // first position, and `scrollPosition` stopped short.
    .contentMargins(.trailing, runOut ?? Theme.edgePage, for: .scrollContent)
    // Without this tvOS searches vertically for a tile in the same column, and
    // rows of different length let focus fall two rows deep. As a section the
    // row counts as a whole.
    .focusSection()

    // **Pre-scrolled where there is a start that is not the first.**
    // The episode row should stand where playback continues, not at E1. Focus
    // falls on the frontmost tile on entry anyway, same rule as on the home
    // page, so the scroll position decides which episode is offered.
    // **`scrollPosition`, not `ScrollViewReader`.** The reader hands its proxy to
    // an escaping closure that is not `Sendable`, which does not compile under
    // Swift 6. It would also force picking the right moment to scroll yourself:
    // `scrollTo` on a tile the lazy stack has not created does nothing. The
    // binding instead carries the request until it can be honored.
    // Only where a binding is passed: the other strips should leave scrolling to
    // the focus engine.
    return Group {
        if let state {
            area.scrollPosition(id: state, anchor: .leading)
        } else {
            area
        }
    }
}

// MARK: - The strips

/// The cast.
/// **The tile must be focusable though it leads nowhere.** On the iPhone the
/// cast is a strip to swipe, with no target on tap. Taken over one to one it
/// becomes a dead-end section on TV: `focusSection` registers a region with
/// nothing in it, tvOS routes the down press there, finds no target and drops
/// it, so focus vanishes and neither forward nor back works. Also, a
/// horizontal list moves here only through focus. An empty callback is
/// therefore not a workaround but the point: the tile is a stop to move on
/// from.
struct CastStrip: View {
    let model: AppModel
    let folks: [Person]
    /// Where the person is known from; shown on the person page above the role.
    var origin: String? = nil

    var body: some View {
        strip {
            ForEach(folks) { person in
                // A button with an empty action used to sit here. It looked like a way
                // forward and was none: built but not wired up.
                NavigationLink(value: PersonRoute(person: person, origin: origin)) {
                    CastTile(image: model.personImage(person, maxHeight: 440),
                                     name: person.name, role: person.role)
                }
                .buttonStyle(TileStyle())
            }
        }
    }
}

/// A row of titles, for "Ähnliches" and "Extras".
struct TitleStrip: View {
    let model: AppModel
    let items: [Item]
    /// Extras do not open a page, they play at once.
    var start: ((Item) -> Void)?

    var body: some View {
        strip {
            ForEach(items) { item in
                if let start {
                    Button { start(item) } label: {
                        TileContent(image: model.landscapeImageURL(for: item, width: 900)
                                           ?? model.imageURL(for: item, maxHeight: 600),
                                     title: item.name, landscape: true,
                                     symbolText: item.tileCharacter)
                    }
                    .buttonStyle(TileStyle())
                } else {
                    NavigationLink(value: item) {
                        TileContent(image: model.imageURL(for: item, maxHeight: 600,
                                                          portrait: true),
                                     title: item.name,
                                     progress: item.userData?.playedPercentage
                                         .map { $0 / 100 },
                                     withUnderRow: false,
                                     mark: DisplayRules.tileMark(
                                        art: item.type,
                                        seasons: item.childCount,
                                        watched: item.userData?.played,
                                        openEpisodes: item.userData?.unplayedItemCount),
                                     symbolText: item.tileCharacter)
                    }
                    .buttonStyle(TileStyle())
                    .tileMenu(item, model: model)
                }
            }
        }
    }
}

/// The episodes of a season as a horizontal strip.
/// This used to be a vertical list with a thumbnail on the left
/// (`EpisodesRow`), taken from the iPhone. The layout makes it a row like any
/// other: the same landscape tile as "Weiterschauen" on the home page, so
/// there is no third tile shape. The same row appears in the player's episode
/// layer (`EpisodesLayer`).
struct EpisodesStrip: View {
    let model: AppModel
    let episodes: [Item]
    let start: (Item) -> Void
    /// Reports which episode is under focus and receives the initial focus.
    @FocusState.Binding var atEpisode: String?
    /// **Long press: the tile menu, as on every other episode**
    /// (``TileMenu``): watched/unwatched, Gemeinsam schauen. In the player
    /// without Play and Gemeinsam; see `TileMenu.inPlayer`.
    var inPlayer = false
    /// After a change to the watch state, so check mark and bar catch up.
    var afterwards: (() async -> Void)? = nil

    /// Which tile is at the front. On appearing, the episode where playback
    /// continues; afterwards the scroll surface tracks the value itself.
    /// **Not as an initial value, but set right after** (see `approach()`). As
    /// an initial value, "set means applied" did not hold on Apple TV: the
    /// binding carried the episode and `defaultFocus` found it, but the row stood
    /// at E1. Probably `scrollPosition` reads the initial value before the lazy
    /// stack has measured anything and discards it; a **change** of the binding
    /// scrolls. It went unnoticed before because the initial focus sat on the
    /// episode and the focus engine brought it into view.
    @State private var ahead: String?
    /// Whether the user has been in the row yet. Until then the episode where
    /// playback continues stays at the front, even if the state arrives later.
    /// Afterwards the scroll position belongs to the user.
    @State private var alreadyShown = false
    /// The episode where playback continues, as the page currently knows it.
    /// **It can still change after appearing.** On the second visit the series
    /// page builds the strip at once from the `SeriesCache`, including the
    /// cached state. That is stale once the user has watched on; the fresh state
    /// only comes with `load()`. `ahead` took only the initial value, and
    /// `.equatable()` did not let the change through: the row stayed at E1 (or
    /// the old episode) while the button above already named the new one. Where
    /// cache and server agree, or on the first visit, it went unnoticed.
    let nextWith: String?

    init(model: AppModel, episodes: [Item], nextWith: String?,
         atEpisode: FocusState<String?>.Binding,
         inPlayer: Bool = false,
         afterwards: (() async -> Void)? = nil,
         start: @escaping (Item) -> Void) {
        self.model = model
        self.episodes = episodes
        self.inPlayer = inPlayer
        self.afterwards = afterwards
        self.start = start
        self._atEpisode = atEpisode
        self.nextWith = nextWith
    }

    var body: some View {
        // **No fixed height.** Tried once with 80 pt for the two label lines, but
        // measured it is about 122. The frame was too small for its content and the
        // horizontal strip centers inside it, so it got worse, not better.
        strip(state: $ahead,
                 // The last episode may sit at the front; see `runOut`.
                 runOut: Theme.screenWidth - Theme.edgePage - Theme.landscapeWidth) {
            ForEach(episodes) { episode in
                Button { start(episode) } label: {
                    // `landscapeImageURL` builds the address from `seriesId ?? id`; for an episode
                    // `seriesId` is set, so every episode would get the same series backdrop.
                    // `imageURL` resolves the episode's own thumbnail through
                    // `imageTags["Primary"]`.
                    TileContent(image: model.imageURL(for: episode, maxHeight: 360)
                                       ?? model.landscapeImageURL(for: episode, width: 640),
                                 title: headerLine(episode),
                                 subline: durationRow(episode),
                                 landscape: true,
                                 // A full bar **and** a check mark would give the same information twice.
                                 progress: episode.isWatched ? nil : episode.watchedShare,
                                 mark: episode.isWatched ? .watched : nil,
                                 watched: episode.isWatched,
                                 symbolText: episode.tileCharacter)
                }
                .buttonStyle(TileStyle())
                .focused($atEpisode, equals: episode.id)
                .tileMenu(episode, model: model, landscape: true,
                             inPlayer: inPlayer, afterwards: afterwards)
            }
        }
        // **No catching up inside the strip.** On opening, the season's list comes
        // twice: at once from the `SeriesCache`, then fresh from the server in
        // the animated transaction of `load()`. The same episodes, but with a new
        // watch state, different remaining time, sometimes a different image, and
        // each change ran animated through the strip. Labels of differing width
        // pushed neighbors back and forth in the lazy stack and the front position
        // was re-scrolled: the jitter on opening, which appeared only when cache and
        // server differed, so rarely. The strip still fades in, but from outside
        // (the transitions on the series page and the player). Inside it stands
        // still; the tiles' focus curves hang on their own value and still apply.
        .transaction { $0.animation = nil }
        // **Down from the header lands on the front episode**, which on opening is
        // the one where playback continues. tvOS otherwise searches geometrically and
        // took the tile under the main button, usually E1. `.userInitiated` because
        // exactly the down press is meant. If the user scrolled, `ahead` is the tile
        // now at the front, so focus does not jump back to an invisible spot.
        .defaultFocus($atEpisode, ahead ?? nextWith, priority: .userInitiated)
        // **On appearing and on every later front state**, as long as the user has
        // not been in the row. The strip fades in from outside; the move to the front
        // falls in its first moment and is unanimated (`.transaction` above), so
        // nothing visibly slides.
        .task(id: nextWith) { await approach() }
        .onChange(of: atEpisode) { _, now in
            if now != nil { alreadyShown = true }
        }
    }

    /// Scrolls the episode where playback continues to the first position.
    private func approach() async {
        guard !alreadyShown, let target = nextWith else { return }
        // Wait one pass: then the scroll surface exists, and the binding change
        // scrolls instead of being discarded like an initial value.
        await Task.yield()
        // Superseded (a newer state arrived): its run scrolls, not this one.
        guard !Task.isCancelled, !alreadyShown, ahead != target else { return }
        ahead = target
    }

    private func headerLine(_ episode: Item) -> String {
        // Localized: German "F" for Folge, English "E" for episode. It used to be a
        // fixed "F", also in English.
        guard let number = episode.indexNumber else { return episode.name }
        return String(localized: "F\(number)") + " · " + episode.name
    }

    /// "52 Min", and where something is started, the remainder behind it.
    private func durationRow(_ episode: Item) -> String? {
        var parts: [String] = []
        // The rule from the package, not a separate check next to it.
        if DisplayRules.runtimeShow(seconds: episode.runtimeSeconds),
           let seconds = episode.runtimeSeconds {
            parts.append(String(localized: "\(Int(seconds / 60)) Min"))
        }
        // "Watched" shows as a check mark in the image, not as a word.
        if let rest = episode.remainingTimeText { parts.append(rest) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// **The strip redraws only when its episodes change.**
/// Same pattern as `EpisodesLayer` in the player: `start` and `nachher` are
/// new blocks on every pass of the page, SwiftUI cannot compare them and
/// recomputed the whole strip with its tile menus, on the series page for
/// every state set on opening: focus, plan, watchlist, watched, fade-in. See
/// the comment on `EpisodesLayer`'s `Equatable` in `PlayerLayers.swift`.
/// What the strip shows is compared. `start` and `nachher` read their state
/// at call time, so an older block does the same as a new one. `nextWith`
/// counts: the fresh state must come through.
extension EpisodesStrip: @MainActor Equatable {
    static func == (left: EpisodesStrip, right: EpisodesStrip) -> Bool {
        left.episodes == right.episodes && left.inPlayer == right.inPlayer
            && left.nextWith == right.nextWith
            && left.model === right.model
    }
}

// MARK: - Part of the collection

/// **The "Teil der Sammlung" row on the movie page**: the other titles of
/// the collection, in order. Same rule as on the iPhone (`Sammlungsreihe` in
/// `CollectionDetailPage.swift`): membership comes from the ``CollectionDirectory``,
/// only the posters are fetched fresh; at most two rows; no collection, no
/// row.
/// **The way to the collection page is a capsule next to the heading.** On
/// the iPhone the heading itself is the button; on TV a heading is no focus
/// target, and a path focus cannot reach is none. The capsule carries the
/// collection's name, the same detail the iPhone shows below.
/// **Loading happens on the movie page, not here**, as on the iPhone. The row
/// used to fetch its titles itself and arrived after everything else; now
/// the movie page waits for it like for extras and similar and fades
/// everything in together.
struct CollectionRail: View {
    let model: AppModel
    let title: Item
    let rails: [AppModel.CollectionRailsData]

    private var art: String? { LibraryGenre.art(toType: title.type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rails, id: \.collection.id) { rail in
                railsSection {
                    HStack(alignment: .center, spacing: 24) {
                        RailTitle(text: "Teil der Sammlung")
                        NavigationLink(value: CollectionRoute(collection: rail.collection.item, art: art)) {
                            Text(verbatim: rail.collection.item.name)
                        }
                        .buttonStyle(CapsuleStyle(arrow: "chevron.right"))
                    }
                    .focusSection()
                } content: {
                    TitleStrip(model: model, items: rail.title)
                }
            }
        }
    }
}
