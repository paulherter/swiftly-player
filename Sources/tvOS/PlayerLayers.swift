import JellyfinKit
import SwiftUI
import struct SwiftlyCore.PlayerChapterRow
import struct SwiftlyCore.PlayerPreview
import enum SwiftlyCore.PlayerMenuPanelTab

/// Player dimensions on the TV, in one place so the title of the episode layer
/// sits exactly where it sat on the picture. Rounded to the TV type steps; the
/// margins are the app-wide title-safe ones (`Theme.edgePage`, `Theme.edgeTop`).
enum PlayerMetric {
    /// Uses the app's type ladder, not its own. The title over the picture is the
    /// page title (56 bold), the info line is a detail (24), and the runtime sits on
    /// the tile title (26), the smallest step still readable from three metres.
    static let title = Theme.titleLarge
    static let meta = Theme.small
    static let time: CGFloat = 26
    /// Target time under the preview image while scrubbing.
    static let previewTime: CGFloat = 30
    /// Bar background, as in the design and the iPhone `Zeitregler`.
    static let barReason = Color.white.opacity(0.25)
    /// Buffered stretch of the bar (design: white at 40 %).
    static let barBuffered = Color.white.opacity(0.4)
    /// Between title and meta line or season pill.
    static let titleSpacing: CGFloat = 10
    /// Line boxes of the head: 56 x 1.1 and 24 x 1.3 as in the design CSS, so title and meta line sit on the same y.
    static let titleLine: CGFloat = 61.6
    static let metaLine: CGFloat = 31.2
    /// Title tracking (design: -1.2 px).
    static let titleTracking: CGFloat = -1.2
    /// The icon buttons at top right: 88 x 88, glyph 44, gap 8.
    static let button: CGFloat = 88
    static let symbol: CGFloat = 44
    static let buttonSpacing: CGFloat = 8
    /// Gap of the skip pill above the bar.
    static let overBar: CGFloat = 28
    /// Height of the time row (one 26 pt line).
    static let bar: CGFloat = 32
    /// Distance of the time row from the bottom edge.
    static let bottom: CGFloat = 90
    /// Column heading (36 / 700) and the gap below it.
    static let heading: CGFloat = 36
    static let headingGap: CGFloat = 16
    static let rowHeight: CGFloat = 72
    /// Space between the last row and the "Verzögerung" block.
    static let delayTop: CGFloat = 28
    /// Columns of the audio & subtitles and settings layers.
    static let column: CGFloat = 500
    static let columnSpacing: CGFloat = 114
    static let columnsTop: CGFloat = 212
    /// Row inset on the layers, so column title, choice row and delay share one text edge.
    static let inset: CGFloat = 20
    /// Width between the margins (80 pt) at 1920 pt.
    static let safeWidth: CGFloat = 1760

    /// Column width for `count` columns side by side. Up to three keep the design
    /// size; four or five (quality, group) move closer instead of running off screen.
    static func columnsWidth(count: Int) -> CGFloat {
        guard count > 3 else { return column }
        return min(column, (safeWidth - CGFloat(count - 1) * tighter) / CGFloat(count))
    }
    static func columnGap(count: Int) -> CGFloat { count > 3 ? tighter : columnSpacing }
    private static let tighter: CGFloat = 48

    /// Width of the icon row; the resting title keeps that space free.
    static func iconRail(count: Int) -> CGFloat {
        CGFloat(count) * button + CGFloat(max(count - 1, 0)) * buttonSpacing
    }
}

/// The layers over the picture.
enum PlayerLayer: Equatable {
    case episodes, chapters
}

/// Shoot path for screenshots without a working stream. DEBUG only; in release every flag is `false`.
///
///     -zeige player -ohneBild [-ebene]
///
/// `-ohneBild` shows the control layer as if playing (see `PlayerScreen`); `-ebene` opens the Ton & Untertitel menu.
enum PlayerShoot {
    #if DEBUG
    static let withoutImage = ProcessInfo.processInfo.arguments.contains("-ohneBild")
    static let layer = withoutImage && ProcessInfo.processInfo.arguments.contains("-ebene")
    #else
    static let withoutImage = false
    static let layer = false
    #endif
    static let position: Double = 1781
    static let duration: Double = 2880
    /// Buffered up to here (seconds): about nine percent of the film ahead of the position.
    static let buffered: Double = 2045
    /// Share of the "Nächste Folge" underline.
    static let countdown: Double = 0.7

}

/// Base of every layer: dark blur plus rgba(16,16,16,.6), as in the design.
private struct LayersReason: View {
    var body: some View {
        ZStack {
            // Forced dark scheme: the thin material would otherwise follow the system's light appearance on TV.
            Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
            Theme.reason.opacity(0.6)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Columns

/// A column with a fixed heading; only the rows below scroll, each by focus.
/// Fifty subtitles run under the heading instead of covering it.
private struct SelectionColumn<ContentBody: View>: View {
    @Environment(\.columnsWidth) private var width
    let title: LocalizedStringKey
    /// Off inside the episodes panel, where the "Kapitel" tab already names the list.
    var showsTitle = true
    @ViewBuilder let content: ContentBody
    /// Room around the rows so a magnified, lifted focus row is not clipped by the scroll view.
    private let bleed: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                Text(title)
                    // 36 / 700 / -0.6 at the heading step of the layers (design `.t-group` at 36).
                    .font(.app(size: PlayerMetric.heading, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                    .frame(height: PlayerMetric.heading * 1.15)
                    .padding(.bottom, PlayerMetric.headingGap)
                    .accessibilityAddTraits(.isHeader)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, bleed)
                    .padding(.bottom, Theme.edgeTop + 60)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -bleed)
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        // Left and right switch the column instead of jumping across rows.
        .focusSection()
    }
}

/// White surface, dark text, x1.03 and lift when focused (design `.r.focus` in the layers).
private struct LayersRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .fill(focus ? Color.white : .clear)
                        .lift(focus)
                }
                .scaleEffect(configuration.isPressed ? 0.98 : (focus ? TVSpec.focusMagnifierWide : 1))
                .animation(Theme.focusAnimation, value: focus)
        }
    }
}

private struct ColumnsWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = PlayerMetric.column
}
private extension EnvironmentValues {
    var columnsWidth: CGFloat {
        get { self[ColumnsWidthKey.self] }
        set { self[ColumnsWidthKey.self] = newValue }
    }
}

/// Columns side by side from the left margin (80 pt) at 212 pt from the top. They end at the bottom edge; overflow scrolls inside its column.
private struct ColumnsRail<ContentBody: View>: View {
    var count = 2
    /// A column wider than the design's 500 pt, for rows with a picture (the chapter list).
    var width: CGFloat?
    var top = PlayerMetric.columnsTop
    @ViewBuilder let content: ContentBody

    var body: some View {
        HStack(alignment: .top, spacing: PlayerMetric.columnGap(count: count)) { content }
            .environment(\.columnsWidth, width ?? PlayerMetric.columnsWidth(count: count))
            .padding(.leading, Theme.edgePage)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, top)
    }
}

// MARK: - Chapters

/// **The chapter list**, as on iPhone: the core's rows (name or "Kapitel n", start, preview tile, the running one marked)
/// through the shared row (`ChapterRowContent`); a press sends the jump (`coreJump`) and closes the layer. Focus starts on
/// the running chapter, and moving it scrolls the column.
struct ChaptersLayer: View {
    let area: VLCPlayerView?
    /// The trickplay image for a start and the core's tile; `nil` without trickplay.
    let preview: (Double, PlayerPreview?) -> CGImage?
    let close: () -> Void
    /// Inside the episodes panel (the "Kapitel" tab): no scrim of its own, no heading, the list starts right under the tabs.
    var embedded = false

    @FocusState private var focus: UInt32?

    var body: some View {
        let part = area?.coreChapters
        ZStack(alignment: .top) {
            if !embedded { LayersReason() }
            ColumnsRail(count: 1, width: 900, top: embedded ? 0 : PlayerMetric.columnsTop) {
                SelectionColumn(title: LocalizedStringKey(part?.title ?? "Kapitel"), showsTitle: !embedded) {
                    ForEach(part?.rows ?? [], id: \.index) { row in
                        Button {
                            area?.coreJump(toChapter: Int(row.index))
                            close()
                        } label: {
                            ChapterRowText(row: row, numberTitle: part?.numberTitle ?? "Kapitel %lld",
                                           image: preview(row.start, row.preview))
                        }
                        .buttonStyle(LayersRowStyle())
                        .accessibilityAddTraits(row.current ? .isSelected : [])
                        .focused($focus, equals: row.index)
                    }
                }
            }
        }
        .focusSection()
        .task { await LayersFocus.put { focus = focus ?? area?.coreChapters?.rows.first(where: \.current)?.index ?? 0 } }
    }

    /// Separate view so it can read the button's focus: dark text on the focused white row, as on every layer row.
    private struct ChapterRowText: View {
        let row: PlayerChapterRow
        let numberTitle: String
        let image: CGImage?
        @Environment(\.isFocused) private var focus

        var body: some View {
            ChapterRowContent(row: row, numberTitle: numberTitle, image: image, look: .tv)
                .foregroundStyle(focus ? Theme.reason : (row.current ? Theme.font : Theme.fontQuiet))
                .padding(.horizontal, PlayerMetric.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Quality

/// Quality choice in the player: Direct Play or a cap in Mbit/s. `select(nil)` means Direct Play.
struct QualitySelection {
    let directPlay: Bool
    let limit: Int
    let select: (Int?) -> Void
}

/// Focus does not enter a layer on its own: the first assignment falls into the
/// pass in which the layer is inserted, and SwiftUI drops it. So set it at once
/// and again one tick later.
enum LayersFocus {
    @MainActor
    static func put(_ setDown: () -> Void) async {
        setDown()
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        setDown()
    }
}

// MARK: - Episodes

/// The layer must not redraw on every player tick. The player recomputes its
/// `body` every 0.5 s, and `start` is a new closure each time that SwiftUI
/// cannot compare, so the whole layer with the episode strip was recomputed.
/// With the tile menu, tvOS rebuilt the open context menu every tick, entries
/// flickered between focused and not, and the Back button no longer reached the
/// player. Same cause as the season picker, one level up.
/// Equality compares what the layer shows: the running episode and the title
/// line. `start` reads its state when called, so an older closure does the same.
extension EpisodesLayer: @MainActor Equatable {
    static func == (left: EpisodesLayer, right: EpisodesLayer) -> Bool {
        left.item.id == right.item.id && left.title == right.title
            && left.model === right.model && left.seasonText == right.seasonText && left.frozen == right.frozen
            && left.hasChapters == right.hasChapters && left.chosenSeason == right.chosenSeason
    }
}

/// The episodes of the series: the same tile strip as on the series page. The
/// title stands where it stood in the player (`stateTitle`, only a
/// placeholder here); the season pill replaces the meta line, tiles below.
struct EpisodesLayer: View {
    let model: AppModel
    /// The running episode.
    let item: Item
    let title: String
    /// The seasons and the open one, shared with the player's menus: a choice from the core's season box lands in `chosen`.
    let picker: SeasonPicker
    /// The core's season button text ("Staffel 2"); `nil` until the core has it.
    let seasonText: String?
    /// The season box is open (the player draws it): the strip rests and focus returns to the pill afterwards.
    let frozen: Bool
    let openSeasons: () -> Void
    /// The series has chapters: the panel gets a "Kapitel" tab next to the season button (the core's `menus.episodes.tabs`).
    let hasChapters: Bool
    /// A choice from the core's season box, passed by value from the screen so the layer's equality sees it (the layer is
    /// `.equatable()`; reading the observable picker inside it did not switch the season). Consumed through `picker.chosen = nil`.
    let chosenSeason: String?
    /// The Kapitel tab's list (the player's surface, its trickplay tiles, the close of the panel).
    let area: VLCPlayerView?
    let chapterPreview: (Double, PlayerPreview?) -> CGImage?
    let close: () -> Void
    let start: (Item) -> Void

    private var seasons: [Item] { get { picker.seasons } nonmutating set { picker.seasons = newValue } }
    private var selectedSeason: Item? { get { picker.selected } nonmutating set { picker.selected = newValue } }
    @State private var episodes: [Item] = []
    /// The server was silent and there is nothing to show.
    @State private var disrupted = false
    @FocusState private var atEpisode: String?
    @FocusState private var atSeasonPill: Bool
    @FocusState private var atChapterTab: Bool
    @State private var tab: PlayerMenuPanelTab = .episodes

    /// The row is already there on open. What the cache has (the player preloads it
    /// via `preload`) is in the state before the first frame; otherwise the tiles
    /// would pop in after fade-in and focus would not find the running episode.
    init(model: AppModel, item: Item, title: String, picker: SeasonPicker, seasonText: String?, frozen: Bool,
         openSeasons: @escaping () -> Void, hasChapters: Bool, chosenSeason: String?, area: VLCPlayerView?,
         chapterPreview: @escaping (Double, PlayerPreview?) -> CGImage?, close: @escaping () -> Void,
         startTab: PlayerMenuPanelTab = .episodes, start: @escaping (Item) -> Void) {
        _tab = State(initialValue: startTab)
        self.model = model
        self.item = item
        self.title = title
        self.picker = picker
        self.seasonText = seasonText
        self.frozen = frozen
        self.openSeasons = openSeasons
        self.hasChapters = hasChapters
        self.chosenSeason = chosenSeason
        self.area = area
        self.chapterPreview = chapterPreview
        self.close = close
        self.start = start
        guard let series = item.seriesId,
              let remembered = SeriesCache.shared.state(series, with: model),
              !remembered.seasons.isEmpty else { return }
        let season = SeasonSelectionRule.choose(from: remembered.seasons, state: item)
        picker.adopt(seasons: remembered.seasons, rule: season)
        _episodes = State(initialValue: season.flatMap { remembered.episodes[$0.id] } ?? [])
    }

    /// Seasons and the episodes of the running season into the cache, called once the player shows an episode.
    static func preload(model: AppModel, item: Item) async {
        guard let seriesKeyID = item.seriesId, let series = Item.preCommonSeries(toward: item) else { return }
        // A failed fetch does not go into the cache. `seasons` and `episodes` return `nil` when the server was silent; otherwise an empty list would sit in `SeriesCache` and the next view would trust it (a cached network error).
        guard let seasons = await model.seasons(series), !seasons.isEmpty else { return }
        SeriesCache.shared.remember(seriesKeyID) { $0.seasons = seasons }
        guard let season = SeasonSelectionRule.choose(from: seasons, state: item) else { return }
        guard let episodes = await model.episodes(series: seriesKeyID, season: season.id) else { return }
        SeriesCache.shared.remember(seriesKeyID) { $0.episodes[season.id] = episodes }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LayersReason()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: PlayerMetric.titleSpacing) {
                    // Placeholder: the title itself is in the player and does not fade with this.
                    Text(verbatim: title)
                        .font(PlayerMetric.title)
                        .tracking(PlayerMetric.titleTracking)
                        .lineLimit(1)
                        .frame(height: PlayerMetric.titleLine)
                        .hidden()
                        .accessibilityHidden(true)
                    // Design: "Staffel N ⌄" and, for a series with chapters, the "Kapitel" tab beside it. The season button opens
                    // the core's season box under it; from the Kapitel tab it first comes back to the episodes.
                    HStack(spacing: 16) {
                        if !seasons.isEmpty {
                            SeasonPill(name: seasonText ?? selectedSeason?.name ?? String(localized: "Staffel"),
                                       opened: Binding(get: { frozen }, set: { if $0 { seasonPressed() } }))
                                .focused($atSeasonPill)
                        }
                        if hasChapters {
                            Button { show(.chapters) } label: { Text("Kapitel") }
                                .buttonStyle(ChipStyle(an: tab == .chapters))
                                .focused($atChapterTab)
                        }
                    }
                }
                .padding(.horizontal, Theme.edgePage)
                .padding(.top, Theme.edgeTop)

                // Old and new row overlap on a season change and cross-fade, as on the series page.
                ZStack(alignment: .topLeading) {
                    if tab == .chapters {
                        ChaptersLayer(area: area, preview: chapterPreview, close: close, embedded: true)
                            .transition(.opacity)
                    }
                    if tab == .episodes, episodes.isEmpty, disrupted {
                        DisturbState(model: model, retry: { Task { await load() } })
                            .frame(maxWidth: .infinity)
                    }
                    if tab == .episodes, !episodes.isEmpty {
                        EpisodesStrip(model: model, episodes: episodes,
                                       nextWith: episodes.contains { $0.id == item.id } ? item.id : nil,
                                       atEpisode: $atEpisode, inPlayer: true,
                                       afterwards: { await episodesLoad() }) { episode in
                            start(episode)
                        }
                        .id(episodes.first?.id ?? "leer")
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // Clear gap to the season pill, otherwise the row stuck to it.
                .padding(.top, 44)

                Spacer(minLength: 0)
            }
            // While the season box is open the rest is not a focus target.
            .disabled(frozen)
        }
        .focusSection()
        // Focus starts on the running episode.
        .defaultFocus($atEpisode, item.id, priority: .userInitiated)
        .onChange(of: frozen) { _, opened in if !opened { atSeasonPill = true } }
        // A choice from the core's season box.
        .onChange(of: chosenSeason) { _, id in
            guard picker.takeChoice(id) != nil else { return }
            Task { await episodesLoad(seasonSwitched: true) }
        }
        .task {
            await LayersFocus.put { if atEpisode == nil, !atSeasonPill { atEpisode = startEpisode } }
            await load()
        }
    }

    private func seasonPressed() {
        if tab == .chapters { show(.episodes) } else { openSeasons() }
    }

    private func show(_ new: PlayerMenuPanelTab) {
        guard tab != new else { return }
        withAnimation(Theme.motion(.easeOut(duration: 0.25))) { tab = new }
    }

    /// The running episode, else the first of the row.
    private var startEpisode: String? {
        episodes.contains { $0.id == item.id } ? item.id : episodes.first?.id
    }

    /// First what the cache has (already set in `init`), then fresh from the server.
    private func load() async {
        guard let series = Item.preCommonSeries(toward: item) else { return }
        // `nil` means disturbed: keep what the cache had.
        guard let freshValue = await model.seasons(series) else {
            disrupted = true
            return
        }
        guard !freshValue.isEmpty else { return }
        disrupted = false
        seasons = freshValue
        if selectedSeason == nil || !freshValue.contains(where: { $0.id == selectedSeason?.id }) {
            selectedSeason = SeasonSelectionRule.choose(from: freshValue, state: item)
        }
        let emptyOpened = episodes.isEmpty
        await episodesLoad()
        // If the row only arrives now, focus still belongs to the running episode.
        if emptyOpened, atEpisode == nil, !atSeasonPill, !frozen {
            await LayersFocus.put { atEpisode = startEpisode }
        }
    }

    /// Cross-fades only on a season change; on open the row is there at once.
    private func episodesLoad(seasonSwitched: Bool = false) async {
        guard let series = item.seriesId else { return }
        let season = selectedSeason?.id
        // Failed means the list stays as it was; emptying it would claim the season has no episodes.
        guard let loaded = await model.episodes(series: series, season: season) else {
            disrupted = true
            return
        }
        disrupted = false
        // Whoever picked another season in the meantime gets its episodes.
        guard season == selectedSeason?.id else {
            AppLog.writeOut("[Staffel] episodes of \(season ?? "-") dropped, open is \(selectedSeason?.id ?? "-")")
            return
        }
        AppLog.writeOut("[Staffel] episodes of \(season ?? "-") loaded: \(loaded.count)")
        if seasonSwitched {
            withAnimation(Theme.motion(.easeOut(duration: 0.25))) { episodes = loaded }
        } else {
            // The same first episode means the same strip `id`: it is not rebuilt and keeps focus.
            episodes = loaded
        }
        if let season { SeriesCache.shared.remember(series) { $0.episodes[season] = loaded } }
    }
}
