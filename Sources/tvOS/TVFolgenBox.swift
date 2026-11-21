import JellyfinKit
import SwiftlyCore
import SwiftUI

// **The Folgen box on Apple TV** (`PlayerMenuKind.folgen`): the same dark box as the other player menus and as on iPhone and
// Mac, top right under the player's buttons, with a vertical list (still, "F2 · Name", runtime and progress). Its first row is
// the season button "Staffel N ⌄", which opens the core's season list as a second box (the player draws it); for a series with
// chapters a "Kapitel" tab sits beside it, and a film shows only its chapters.
//
// The surface, the motion and Back belong to the menu session (`TVFolgenLayer`, `PlayerScreen.closeMenu`); this file draws what
// lies inside, sized for ten feet (rows of 72 pt and more, white focus with dark text, as in `TVMenuBox`).

enum TVFolgenMetric {
    static let width: CGFloat = 860
    static let listMax: CGFloat = 700
    static let still = CGSize(width: 176, height: 99)
}

/// The layer must not redraw on every player tick (the player's `body` runs twice a second and `start` is a new closure each
/// time): equality compares what the box shows. `start` reads its state when called, so an older closure does the same.
extension TVFolgenBox: @MainActor Equatable {
    static func == (left: TVFolgenBox, right: TVFolgenBox) -> Bool {
        left.item.id == right.item.id && left.model === right.model && left.seasonText == right.seasonText
            && left.frozen == right.frozen && left.hasEpisodes == right.hasEpisodes && left.hasChapters == right.hasChapters
            && left.chosenSeason == right.chosenSeason
    }
}

struct TVFolgenBox: View {
    let model: AppModel
    /// The running title.
    let item: Item
    /// A series' episode (else the box shows only the film's chapters).
    let hasEpisodes: Bool
    /// The seasons and the open one, shared with the player's menus: a choice from the core's season box lands in `chosen`.
    let picker: SeasonPicker
    /// The core's season button text ("Staffel 2"); `nil` until the core has it.
    let seasonText: String?
    /// The season box is open (the player draws it): the list rests and focus returns to the season button afterwards.
    let frozen: Bool
    let openSeasons: () -> Void
    /// The series has chapters: a "Kapitel" tab beside the season button (the core's `menus.episodes.tabs`).
    let hasChapters: Bool
    /// A choice from the season box, passed by value so the box's equality sees it; consumed through `picker.chosen = nil`.
    let chosenSeason: String?
    let area: VLCPlayerView?
    let chapterPreview: (Double, PlayerPreview?) -> CGImage?
    let close: () -> Void
    let start: (Item) -> Void

    private var seasons: [Item] { get { picker.seasons } nonmutating set { picker.seasons = newValue } }
    private var selectedSeason: Item? { get { picker.selected } nonmutating set { picker.selected = newValue } }
    @State private var loader: EpisodesLoader
    private var episodes: [Item] { loader.episodes }
    /// The server was silent and there is nothing to show.
    private var disrupted: Bool { loader.disrupted }
    @State private var tab: PlayerMenuPanelTab
    @FocusState private var focus: String?
    @State private var listHeight: CGFloat = 0

    /// **The list is already there on opening.** What the store has (the player preloads it at start) is in the states before the
    /// first frame; otherwise the rows would pop in after the box and focus would not find the running episode.
    init(model: AppModel, item: Item, hasEpisodes: Bool, picker: SeasonPicker, seasonText: String?, frozen: Bool,
         openSeasons: @escaping () -> Void, hasChapters: Bool, chosenSeason: String?, area: VLCPlayerView?,
         chapterPreview: @escaping (Double, PlayerPreview?) -> CGImage?, close: @escaping () -> Void,
         startTab: PlayerMenuPanelTab, start: @escaping (Item) -> Void) {
        self.model = model; self.item = item; self.hasEpisodes = hasEpisodes; self.picker = picker
        self.seasonText = seasonText; self.frozen = frozen; self.openSeasons = openSeasons; self.hasChapters = hasChapters
        self.chosenSeason = chosenSeason; self.area = area; self.chapterPreview = chapterPreview; self.close = close
        self.start = start
        _tab = State(initialValue: hasEpisodes ? startTab : .chapters)
        _loader = State(initialValue: EpisodesLoader(model: model, item: item, picker: picker))
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .padding(TVMenuMetric.boxPad)
        .frame(width: TVFolgenMetric.width)
        .background(RoundedRectangle(cornerRadius: TVMenuMetric.radius, style: .continuous).fill(Theme.groupsArea))
        .focusSection()
        // While the season box is open the rest is not a focus target.
        .disabled(frozen)
        .onChange(of: frozen) { _, opened in if !opened { focus = "season" } }
        // A choice from the core's season box.
        .onChange(of: chosenSeason) { _, id in
            Task { await loader.switchSeason(to: id, animation: Theme.motion(.easeOut(duration: 0.25))) }
        }
        .task {
            await LayersFocus.put { if focus == nil { focus = startFocus } }
            if hasEpisodes { await load() }
        }
    }

    // MARK: Header: "Staffel N ⌄" and the Kapitel tab

    @ViewBuilder
    private var header: some View {
        if !hasEpisodes {
            title("Kapitel")
        } else {
            HStack(spacing: 8) {
                if seasonText != nil || !seasons.isEmpty {
                    tabButton(on: tab == .episodes, id: "season", action: seasonPressed) { ink in
                        tvText(seasonText ?? selectedSeason?.name ?? String(localized: "Staffel"), ink).layoutPriority(1)
                        Image(icon: "chevron.down", size: TVMenuMetric.detail)
                            .font(.app(size: TVMenuMetric.detail, weight: .semibold)).foregroundStyle(ink)
                    }
                } else {
                    title("Folgen")
                }
                if hasChapters {
                    tabButton(on: tab == .chapters, id: "chapters", action: { show(.chapters) }) { ink in
                        tvText(String(localized: "Kapitel"), ink)
                    }
                }
            }
            .focusSection()
        }
    }

    private func title(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.app(size: TVMenuMetric.label, weight: .semibold)).foregroundStyle(Theme.font)
            .padding(.horizontal, TVMenuMetric.pad)
            .frame(maxWidth: .infinity, minHeight: TVMenuMetric.row, alignment: .leading)
    }

    /// A tab is a row of the box: white with dark text on focus; the open one carries a line under its label.
    private func tabButton<Label: View>(on: Bool, id: String, action: @escaping () -> Void,
                                        @ViewBuilder label: @escaping (Color) -> Label) -> some View {
        TVMenuButton(action: action) { lit in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) { label(lit ? Theme.reason : (on ? Theme.font : Theme.fontVeryQuiet)) }
                Capsule().fill(lit ? Theme.reason : Theme.font).frame(height: 3).opacity(on ? 1 : 0)
            }
        }
        .focused($focus, equals: id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if tab == .chapters {
                        ForEach(area?.coreChapters?.rows ?? [], id: \.index) { chapterRow($0) }
                    } else if episodes.isEmpty, disrupted {
                        DisturbState(model: model, retry: { Task { await load() } })
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(episodes) { episodeRow($0) }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollClipDisabled()
            .frame(height: min(max(listHeight, 1), TVFolgenMetric.listMax))
            // Under the header the list fades out in a strip, so a scrolled row never runs over it.
            .modifier(FadeUnderHeaderIf(header: true))
            .onChange(of: episodes.map(\.id), initial: true) { _, ids in
                if tab == .episodes, ids.contains(item.id) { reader.scrollTo(item.id, anchor: .center) }
            }
            .onChange(of: tab) { _, new in
                if new == .chapters, let now = area?.coreChapters?.rows.first(where: \.current) { reader.scrollTo(now.index, anchor: .center) }
            }
        }
    }

    private func episodeRow(_ episode: Item) -> some View {
        let now = episode.id == item.id
        return TVMenuButton(action: { start(episode) }) { lit in
            HStack(spacing: 20) {
                Picture(url: model.imageURL(for: episode, maxHeight: 360) ?? model.landscapeImageURL(for: episode, width: 640),
                        width: TVFolgenMetric.still.width, height: TVFolgenMetric.still.height, corner: 12,
                        progress: episode.isWatched ? nil : episode.watchedShare) { Theme.area }
                VStack(alignment: .leading, spacing: 6) {
                    tvText(episode.stripHeaderLine, lit ? Theme.reason : Theme.font, size: 28, lines: 2)
                    if let line = episode.stripDurationLine, !line.isEmpty {
                        tvText(line, lit ? Theme.reason.opacity(0.7) : (now ? Theme.accent : Theme.fontVeryQuiet),
                               size: TVMenuMetric.detail, weight: .regular)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
        }
        .focused($focus, equals: episode.id)
        .accessibilityAddTraits(now ? .isSelected : [])
        .id(episode.id)
    }

    private func chapterRow(_ row: PlayerChapterRow) -> some View {
        TVMenuButton(action: { area?.coreJump(toChapter: Int(row.index)); close() }) { lit in
            ChapterRowContent(row: row, numberTitle: area?.coreChapters?.numberTitle ?? "Kapitel %lld",
                              image: chapterPreview(row.start, row.preview), look: .tv)
                .foregroundStyle(lit ? Theme.reason : (row.current ? Theme.font : Theme.fontQuiet))
        }
        .focused($focus, equals: "c\(row.index)")
        .accessibilityAddTraits(row.current ? .isSelected : [])
        .id(row.index)
    }

    // MARK: Focus and tabs

    /// The running episode, else the first row; for chapters the current one.
    private var startFocus: String? {
        if tab == .chapters {
            return (area?.coreChapters?.rows.first(where: \.current)?.index ?? area?.coreChapters?.rows.first?.index).map { "c\($0)" }
        }
        return episodes.contains { $0.id == item.id } ? item.id : (episodes.first?.id ?? "season")
    }

    private func seasonPressed() {
        if tab == .chapters { show(.episodes) } else { openSeasons() }
    }

    private func show(_ new: PlayerMenuPanelTab) {
        guard tab != new else { return }
        withAnimation(Theme.motion(.easeOut(duration: 0.25))) { tab = new }
        Task { await LayersFocus.put { focus = startFocus } }
    }

    // MARK: Loading

    /// The loading itself is `EpisodesLoader`'s; here only focus follows: if the list arrives after opening, it belongs to the
    /// running episode.
    private func load() async {
        let emptyOpened = episodes.isEmpty
        await loader.load()
        if emptyOpened, tab == .episodes, focus == nil || focus == "season", !frozen {
            await LayersFocus.put { focus = startFocus }
        }
    }
}
