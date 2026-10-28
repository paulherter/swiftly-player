import JellyfinKit
import SwiftUI
import VLCKit

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
    static let barReason = Color.white.opacity(0.28)
    /// Between title and meta line or season pill.
    static let titleSpacing: CGFloat = 6
    /// The icon buttons at top right.
    static let button: CGFloat = 88
    static let symbol: CGFloat = 38
    static let buttonSpacing: CGFloat = 20
    /// Gap of the skip pill above the bar.
    static let overBar: CGFloat = 40
    /// Height of the time row.
    static let bar: CGFloat = 40
    /// Columns of the audio & subtitles and settings layers.
    static let column: CGFloat = 500
    static let columnSpacing: CGFloat = 114
    static let columnsTop: CGFloat = 152
    /// Row inset on the layers, so column title, choice row and delay share one text edge.
    static let inset: CGFloat = 26
    /// Width between the safe margins (90 pt) at 1920 pt.
    static let safeWidth: CGFloat = 1740

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

/// The three layers over the picture.
enum PlayerLayer: Equatable {
    case tracks, episodes, settings
}

/// One of the icon buttons at top right. At rest only the glyph, focused the
/// white fill of `ThemedButtonStyle`.
struct IconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: PlayerMetric.symbol, weight: .medium))
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel(Text(label))
    }
}

/// Like `ThemedButtonStyle(nurSymbol:)`, but without a fill at rest: the glyphs float over the picture.
private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .foregroundStyle(focus ? Theme.reason : Theme.font)
                .frame(width: PlayerMetric.button, height: PlayerMetric.button)
                .background(focus ? Color.white : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                // 88 x 88, the small step: 1.04 would have been three points, and the glyph floats over the picture.
                .scaleEffect(configuration.isPressed ? 0.97 : (focus ? Theme.focusMagnifierSmall : 1))
                .animation(Theme.focusAnimation, value: focus)
        }
    }
}

/// Base of every layer: blur with little extra dimming. The controls already
/// darkened the picture, so a second strong dim felt heavy. Uses the dark UIKit
/// style because `.ultraThinMaterial` follows the system's light appearance on
/// TV. Pure black on top, never `Theme.reason`, which lifts black to grey in HDR.
private struct LayersReason: View {
    var body: some View {
        ZStack {
            DarkBlur()
            Color.black.opacity(0.15)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct DarkBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    }

    func updateUIView(_ viewRef: UIVisualEffectView, context: Context) {}
}

// MARK: - Columns

/// A column with a fixed heading; only the rows below scroll, each by focus.
/// Fifty subtitles run under the heading instead of covering it.
private struct SelectionColumn<ContentBody: View>: View {
    @Environment(\.columnsWidth) private var width
    let title: LocalizedStringKey
    @ViewBuilder let content: ContentBody

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                // Sub-page title from the ladder: the size was right, the weight was not. Bold appears once, on the page title.
                .font(Theme.subpageTitle)
                .tracking(Theme.lockSubpage)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .padding(.horizontal, PlayerMetric.inset)
                .padding(.bottom, 22)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) { content }
                    .padding(.bottom, Theme.edgeTop)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        // Left and right switch the column instead of jumping across rows.
        .focusSection()
    }
}

/// Check mark and name. Selected is white and semibold, otherwise 62 % white; focus is the calm fill of `EpisodesStyle`.
private struct LayersRow: View {
    let text: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RowsText(text: text, selected: selected)
        }
        .buttonStyle(EpisodesStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Separate view so it can read the button's focus.
    private struct RowsText: View {
        let text: String
        let selected: Bool
        @Environment(\.isFocused) private var focus

        var body: some View {
            HStack(spacing: 22) {
                Image(systemName: "checkmark")
                    .font(Theme.listTitle)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 42)
                    // The check mark is only an image; VoiceOver reads the selection from the button (`.isSelected`).
                    .accessibilityHidden(true)
                // Track names come from the file; use them verbatim.
                Text(verbatim: text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 30, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected || focus ? Theme.font : Theme.fontQuiet)
            .padding(.horizontal, PlayerMetric.inset)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A name in the "together" column: information, not a button.
private struct ParticipantRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: "person.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.fontVeryQuiet)
                .frame(width: 42)
            // A server user name, verbatim.
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(Theme.body)
        .foregroundStyle(Theme.fontQuiet)
        .padding(.horizontal, PlayerMetric.inset)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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

/// Columns side by side, centred. They end at the bottom edge; overflow scrolls inside its column.
private struct ColumnsRail<ContentBody: View>: View {
    var count = 2
    @ViewBuilder let content: ContentBody

    var body: some View {
        HStack(alignment: .top, spacing: PlayerMetric.columnGap(count: count)) { content }
            .environment(\.columnsWidth, PlayerMetric.columnsWidth(count: count))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, PlayerMetric.columnsTop)
    }
}

/// Delay: last row of the audio and subtitle columns. Counterpart of `Verzoegerungszeile` on iOS (rationale there).
/// On TV it has three focus targets (-, +, reset) instead of one row catching
/// left/right, because left/right switch the column here. Holding repeats,
/// faster via `Delay.Haltezaehler`.
struct DelayRow: View {
    let value: Delay
    /// Focus id of the row, `"v" + column`; the keys append `-`, `+` and `0`.
    let identifier: String
    let focus: FocusState<String?>.Binding
    let setDown: (Delay) -> Void
    @State private var hold = Delay.HoldCounter()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Verzögerung")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .padding(.horizontal, PlayerMetric.inset)
            HStack(spacing: 0) {
                keyButton("minus", "-", locked: value.atStart) {
                    setDown(value.shifted(-1, steps: hold.press()))
                }
                .accessibilityLabel(Text("Früher"))
                Text(verbatim: value.text())
                    .font(Theme.listTitle.monospacedDigit())
                    .foregroundStyle(value.isNull ? Theme.fontQuiet : Theme.font)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                keyButton("plus", "+", locked: value.atEnd) {
                    setDown(value.shifted(1, steps: hold.press()))
                }
                .accessibilityLabel(Text("Später"))
                // The reset button disappears afterwards; focus goes to + instead of jumping elsewhere.
                keyButton("arrow.counterclockwise", "0", locked: false, redo: false) {
                    setDown(.null)
                    focus.wrappedValue = identifier + "+"
                }
                .accessibilityLabel(Text("Zurücksetzen"))
                .opacity(value.isNull ? 0 : 1)
                .disabled(value.isNull)
            }
            .accessibilityValue(Text(verbatim: value.text()))
        }
    }

    private func keyButton(_ symbol: String, _ suffix: String, locked: Bool, redo: Bool = true,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: PlayerMetric.symbol - 6, weight: .semibold))
                .opacity(locked ? 0.4 : 1)
        }
        .buttonStyle(IconButtonStyle())
        .buttonRepeatBehavior(redo ? .enabled : .disabled)
        // At the limit the key stays focusable; if focus vanished mid-hold it would jump to another column.
        .focused(focus, equals: identifier + suffix)
    }
}

// MARK: - Audio & subtitles

struct TracksLayer: View {
    let area: VLCPlayerView?

    /// The own selection, independent of VLC: VLC applies the choice one tick later,
    /// so the check marks would lag a click behind.
    @State private var audioSelection: String?
    @State private var subtitleSelection: String??
    @FocusState private var focus: String?
    @State private var audioLag: Delay?
    @State private var subtitleLag: Delay?

    var body: some View {
        ZStack(alignment: .top) {
            LayersReason()
            ColumnsRail {
                SelectionColumn(title: "Audio") {
                    ForEach(area?.audioTracks ?? [], id: \.trackId) { track in
                        LayersRow(text: track.prettyName, selected: audioNow == track.trackId) {
                            audioSelection = track.trackId
                            area?.selectAudioTrack(track)
                        }
                        .focused($focus, equals: "t" + track.trackId)
                    }
                    DelayRow(value: audioLag ?? area?.audioDelay ?? .null,
                                       identifier: "vt", focus: $focus) { new in
                        audioLag = new
                        area?.audioDelay = new
                    }
                    .padding(.top, Theme.railsPadding)
                }
                SelectionColumn(title: "Untertitel") {
                    LayersRow(text: String(localized: "Aus"), selected: subtitleNow == nil) {
                        subtitleSelection = .some(nil)
                        area?.selectSubtitle(nil)
                    }
                    .focused($focus, equals: "u")
                    let names = area?.subtitleNames() ?? [:]
                    ForEach(area?.subtitleTracks ?? [], id: \.trackId) { track in
                        LayersRow(text: names[track.trackId] ?? track.trackName,
                                    selected: subtitleNow == track.trackId) {
                            subtitleSelection = .some(track.trackId)
                            area?.selectSubtitle(track)
                        }
                        .focused($focus, equals: "u" + track.trackId)
                    }
                    DelayRow(value: subtitleLag ?? area?.subtitleDelay ?? .null,
                                       identifier: "vu", focus: $focus) { new in
                        subtitleLag = new
                        area?.subtitleDelay = new
                    }
                    .padding(.top, Theme.railsPadding)
                }
            }
        }
        .focusSection()
        // Starts on the selected audio track.
        .task { await LayersFocus.put { focus = focus ?? startTarget } }
    }

    private var startTarget: String {
        if let audio = audioNow { return "t" + audio }
        return "u" + (subtitleNow ?? "")
    }

    /// By `trackId`, not name: two tracks called "Deutsch" would both show the check mark.
    private var subtitleNow: String? {
        if let subtitleSelection { return subtitleSelection }
        return area?.selectedSubtitle?.trackId
    }

    private var audioNow: String? {
        audioSelection ?? area?.selectedAudioTrack?.trackId
    }
}

// MARK: - Settings

struct SettingLayer: View {
    let area: VLCPlayerView?
    @Binding var sleepMinutes: Int?
    /// Only when playing from the server; a downloaded file has no choice.
    let quality: QualitySelection?
    /// Only in a group: who is in it, and the way out.
    var gemeinsam: SharedModel? = nil
    var groupLeave: () -> Void = {}

    @AppStorage("technikschild") private var techBadge = false
    @AppStorage("bildfuellend") private var fillFrame = false
    @FocusState private var focus: String?

    var body: some View {
        ZStack(alignment: .top) {
            LayersReason()
            ColumnsRail(count: 3 + (gemeinsam?.group != nil ? 1 : 0) + (quality != nil ? 1 : 0)) {
                // Together comes first (design A, as on iPhone): who is in, then the exit. The names do nothing and are not focus targets, so focus skips them to "leave group".
                if let gemeinsam, let group = gemeinsam.group {
                    SelectionColumn(title: "Gemeinsam · \(group.name)") {
                        ForEach(Array(group.participant.enumerated()), id: \.offset) { pair in
                            ParticipantRow(name: pair.element)
                        }
                        Button(action: groupLeave) {
                            HStack(spacing: 22) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 28, weight: .semibold))
                                    .frame(width: 42)
                                Text("Gruppe verlassen")
                                Spacer(minLength: 0)
                            }
                            .font(Theme.listTitle)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, PlayerMetric.inset)
                            .padding(.vertical, 18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(EpisodesStyle())
                    }
                }
                // Two picture formats as on iPhone: the whole picture and fill. There is no stretched picture.
                SelectionColumn(title: "Bild") {
                    LayersRow(text: String(localized: "Original"), selected: !fillFrame) {
                        fillFrame = false
                        area?.fillFrame(false)
                    }
                    .focused($focus, equals: "b0")
                    LayersRow(text: String(localized: "Füllen"), selected: fillFrame) {
                        fillFrame = true
                        area?.fillFrame(true)
                    }
                    .focused($focus, equals: "b1")
                }
                SelectionColumn(title: "Schlafzeit") {
                    LayersRow(text: String(localized: "Aus"), selected: sleepMinutes == nil) {
                        sleepMinutes = nil
                    }
                    ForEach(SleepTimes.values, id: \.self) { minutes in
                        LayersRow(text: String(localized: "\(minutes) Min."),
                                    selected: sleepMinutes == minutes) {
                            sleepMinutes = minutes
                        }
                    }
                }
                SelectionColumn(title: "Technikschild") {
                    LayersRow(text: String(localized: "Aus"), selected: !techBadge) {
                        techBadge = false
                    }
                    LayersRow(text: String(localized: "An"), selected: techBadge) {
                        techBadge = true
                    }
                }
                // Quality: Direct Play or a cap. A cap lets the server transcode, so Direct Play is off. Works like the app setting and reloads the film at the same position.
                if let quality {
                    SelectionColumn(title: "Qualität") {
                        LayersRow(text: String(localized: "Direct Play"),
                                    selected: quality.directPlay) {
                            quality.select(nil)
                        }
                        ForEach(Bitrate.levels) { rung in
                            LayersRow(text: Bitrate.text(rung.value),
                                        selected: !quality.directPlay && quality.limit == rung.value) {
                                quality.select(rung.value)
                            }
                        }
                    }
                }
            }
        }
        .focusSection()
        .task { await LayersFocus.put { focus = focus ?? (fillFrame ? "b1" : "b0") } }
    }
}

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
/// player. Same cause as the season picker (`panelActions`), one level up.
/// Equality compares what the layer shows: the running episode and the title
/// line. `start` reads its state when called, so an older closure does the same.
extension EpisodesLayer: @MainActor Equatable {
    static func == (left: EpisodesLayer, right: EpisodesLayer) -> Bool {
        left.item.id == right.item.id && left.title == right.title
            && left.model === right.model
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
    let start: (Item) -> Void

    @State private var seasons: [Item] = []
    @State private var selectedSeason: Item?
    @State private var episodes: [Item] = []
    /// The server was silent and there is nothing to show.
    @State private var disrupted = false
    @State private var seasonSelectionOpen = false
    /// The entries of the open season picker, built once. Each `TitleAction`
    /// carries a new id; computed in `body` the list was rebuilt every player tick
    /// (0.5 s), rows were replaced, focus jumped between list and pill, and the
    /// pill flickered while the picker was open.
    @State private var panelActions: [TitleAction] = []
    @FocusState private var atEpisode: String?
    @FocusState private var atSeasonPill: Bool

    /// The row is already there on open. What the cache has (the player preloads it
    /// via `preload`) is in the state before the first frame; otherwise the tiles
    /// would pop in after fade-in and focus would not find the running episode.
    init(model: AppModel, item: Item, title: String, start: @escaping (Item) -> Void) {
        self.model = model
        self.item = item
        self.title = title
        self.start = start
        guard let series = item.seriesId,
              let remembered = SeriesCache.shared.state(series, with: model),
              !remembered.seasons.isEmpty else { return }
        let season = SeasonSelectionRule.choose(from: remembered.seasons, state: item)
        _seasons = State(initialValue: remembered.seasons)
        _selectedSeason = State(initialValue: season)
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
                        .tracking(Theme.lockTitle)
                        .lineLimit(1)
                        .hidden()
                        .accessibilityHidden(true)
                    if !seasons.isEmpty {
                        SeasonPill(name: selectedSeason?.name ?? String(localized: "Staffel"),
                                     opened: $seasonSelectionOpen)
                            .focused($atSeasonPill)
                            .panelTrigger("staffel")
                    }
                }
                .padding(.horizontal, Theme.edgePage)
                .padding(.top, Theme.edgeTop)

                // Old and new row overlap on a season change and cross-fade, as on the series page.
                ZStack(alignment: .topLeading) {
                    if episodes.isEmpty, disrupted {
                        DisturbState(model: model, retry: { Task { await load() } })
                            .frame(maxWidth: .infinity)
                    }
                    if !episodes.isEmpty {
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
            // While the season picker is open the rest is not a focus target (see `SeriesView`).
            .disabled(seasonSelectionOpen)
            .panel(under: seasonSelectionOpen && !panelActions.isEmpty ? "staffel" : nil) {
                ActionPanel(actions: panelActions, opened: $seasonSelectionOpen,
                            start: seasons.firstIndex { $0.id == selectedSeason?.id } ?? 0)
                    .transition(.opacity)
            }
            .animation(Theme.motion(.easeInOut(duration: 0.18)), value: seasonSelectionOpen)
        }
        .focusSection()
        // Focus starts on the running episode.
        .defaultFocus($atEpisode, item.id, priority: .userInitiated)
        .onChange(of: seasonSelectionOpen) { _, opened in
            if opened {
                panelActions = seasonActions
            } else {
                panelActions = []
                atSeasonPill = true
            }
        }
        .task {
            await LayersFocus.put { if atEpisode == nil, !atSeasonPill { atEpisode = startEpisode } }
            await load()
        }
    }

    /// The running episode, else the first of the row.
    private var startEpisode: String? {
        episodes.contains { $0.id == item.id } ? item.id : episodes.first?.id
    }

    /// Seasons as an action panel, not a `Menu`, as everywhere in the app.
    private var seasonActions: [TitleAction] {
        seasons.map { season in
            TitleAction(symbol: selectedSeason?.id == season.id
                                  ? "checkmark.circle.fill" : "circle",
                          text: "\(season.name)") {
                selectedSeason = season
                Task { await episodesLoad(seasonSwitched: true) }
            }
        }
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
        if emptyOpened, atEpisode == nil, !atSeasonPill, !seasonSelectionOpen {
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
        guard season == selectedSeason?.id else { return }
        if seasonSwitched {
            withAnimation(Theme.motion(.easeOut(duration: 0.25))) { episodes = loaded }
        } else {
            // The same first episode means the same strip `id`: it is not rebuilt and keeps focus.
            episodes = loaded
        }
        if let season { SeriesCache.shared.remember(series) { $0.episodes[season] = loaded } }
    }
}
