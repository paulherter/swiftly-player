import JellyfinKit
import SwiftUI
import VLCKit

/// Player dimensions on iPhone and iPad, **in one place**, so a layer's X
/// sits exactly where the player's X sat, and the episode list's title
/// exactly where the title sat in the picture.
struct PlayerMetric {
    let pad: Bool
    let inWindow: Bool
    /// iPhone in portrait (orientation lock off): the safe area applies at the
    /// top, otherwise the header would lie under the Dynamic Island.
    var portrait = false

    /// Ignore the safe area at the top only in landscape; there it is empty
    /// anyway, in portrait it holds the island.
    var topSkip: Edge.Set { portrait ? [] : .top }

    /// Margin left and right, inside the safe area. The same as in
    /// `EpisodesRow` (`Theme.rand(wide:)`), so the title and thumbnails of the
    /// episode list line up.
    var page: CGFloat { Theme.margin(wide: pad) }
    /// Spacing at the top; in a window, the iPadOS traffic lights sit above.
    var top: CGFloat { (pad ? 24 : 16) + (inWindow ? WindowButtons.height : 0) }
    /// Above the bottom safe area. On iPhone **directly on it**: the bar sits
    /// just above the home indicator, and since the hit area never reaches
    /// into the safe area, a swipe from the very bottom does not catch the
    /// scrubber. At 12 the bar sat too high and looked floating; at -10 it
    /// reached into the home zone.
    var bottom: CGFloat { pad ? 22 : 0 }
    /// Hit area of the icon buttons.
    let button: CGFloat = 44
    var symbol: CGFloat { pad ? 21 : 19 }
    /// **The app's scale, not an own one.**
    ///
    /// This used to have four values that do not exist in `Theme`: title 19 on
    /// iPhone and 22 on iPad, info 14 and 15, time 13 and 14. The player was
    /// the only place in the app with a second type scale, and 19 and 14 are
    /// in neither.
    ///
    /// Now: title = row heading (20), info and time = info (12/13). And **one**
    /// value per role instead of two: the scale applies on iPad 1:1 as on
    /// iPhone (one column for iPhone, iPad and Mac). The dimensions
    /// above (margin, hit area, symbol size) still split, since they depend on
    /// the device, not the type.
    let title: CGFloat = 20
    let meta: CGFloat = 12
    /// Runtime left and right of the bar. 13, like the tile title: the
    /// smallest step still safely legible over a picture.
    let time: CGFloat = 13
    /// Spacing of the skip pill above the bar.
    let overBar: CGFloat = 20
    /// Height of the time row: the scrubber's hit area.
    let bar: CGFloat = 44
    /// By this much the scrubber's hit area extends **upward** beyond the
    /// time row, never downward.
    let sliderTop: CGFloat = 16
    /// Indent of the rows on the layers: column title, choice row and delay
    /// thus share one text edge.
    static let inset: CGFloat = 10
}

/// The three layers above the picture.
enum PlayerLayer: Equatable {
    case tracks, episodes, settings
}

/// One of the round icon buttons at the top right, in the player and on
/// the layers.
struct IconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let mass: PlayerMetric
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: mass.symbol, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: mass.button, height: mass.button)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(Text(label))
    }
}

/// **Background of every layer:** pure black at 0.72. Accepts every tap so
/// nothing underneath seeks.
private struct LayersReason: View {
    var body: some View {
        // **Blur and black on top, both.**
        //
        // The blur was gone for a day, with two reasons. One was wrong: "pure
        // black applies in the player" refers to the **scrim over the running
        // picture**, where a material lifts HDR. A layer does not play, it stands,
        // and behind it you should see that the film is still there. The other
        // was right: below 0.72 black nothing of the blur was visible, it only
        // cost compute.
        //
        // So both, in suitable proportions: the material carries, and the
        // darkening on top is back to 0.45, enough for the column titles to stand
        // out, little enough for the blur to show.
        ZStack {
            // **Beyond the edge.** A blur ending at the screen edge pulls in emptiness
            // there: the corners flashed bright when fading in. Drawn larger, the
            // edge lies outside the screen.
            Blur(strength: 1)
                .padding(-60)
            Color.black.opacity(0.45)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

/// Header of a layer: on the left what the layer shows, on the right the X,
/// with the same dimensions as the player's header.
private struct LayersHeader<Left: View>: View {
    let mass: PlayerMetric
    let close: () -> Void
    @ViewBuilder let left: Left

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            left
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", label: "Schließen", mass: mass, action: close)
        }
        .padding(.horizontal, mass.page)
        .padding(.top, mass.top)
    }
}

// MARK: - Columns

/// A column with a fixed heading; only the rows below scroll.
private struct SelectionColumn<ContentBody: View>: View {
    let title: LocalizedStringKey
    let mass: PlayerMetric
    @ViewBuilder let content: ContentBody

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                // Exactly the grade of the player title, which computes with the window
                // size. The same numbers used to be typed by hand here (22/19); a role with
                // two sources eventually drifts apart.
                // Semibold, not bold: 20 is the row heading, and bold appears exactly once,
                // at the page title.
                .font(.system(size: mass.title, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                // Used to be raw `.white`; `font` is what is read.
                .foregroundStyle(Theme.font)
                .padding(.horizontal, PlayerMetric.inset)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { content }
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: mass.pad ? Theme.trackColumnWidthPad : Theme.trackColumnWidth,
               alignment: .leading)
    }
}

/// Checkmark and name. Selected: `Theme.font` and semibold, otherwise
/// `Theme.schriftLeise`. This used to be "62 % white"; over a picture an
/// opacity is not a text color, it gets lighter and darker with the scene.
private struct LayersRow: View {
    let text: String
    let selected: Bool
    let mass: PlayerMetric
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: mass.pad ? 15 : 14, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                // Track names come from the file: verbatim, do not look up.
                Text(verbatim: text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // **One grade, one weight.**
            //
            // This had `pad ? 17 : 15` and `selected ? .semibold : .regular`. The first
            // part was a second scale: 15 is the list row, on iPad as on iPhone
            //. The second was worse: the column is narrow and the row
            // carries `lineLimit(1)`, so **a long track name truncated more on
            // selection than before**. Selected is now expressed by tone.
            .font(Theme.listTitle)
            .foregroundStyle(selected ? Theme.font : Theme.fontQuiet)
            // The checkmark glides from row to row instead of jumping.
            .animation(Theme.toggle, value: selected)
            .padding(.horizontal, PlayerMetric.inset)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A name in the "Together" column: information, not a button.
private struct ParticipantRow: View {
    let name: String
    let mass: PlayerMetric

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: mass.pad ? 15 : 14))
                .foregroundStyle(Theme.fontVeryQuiet)
                .frame(width: 18)
            // A username from the server, verbatim.
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(Theme.listTitle)
        .foregroundStyle(Theme.fontQuiet)
        .padding(.horizontal, PlayerMetric.inset)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Columns side by side, centered, under the header. Each scrolls on its
/// own; at the bottom the content ends above the safe area.
private struct ColumnsRail<ContentBody: View>: View {
    let mass: PlayerMetric
    @ViewBuilder let content: ContentBody

    var body: some View {
        // In portrait the width is tight: closer together, otherwise three
        // columns do not fit side by side.
        HStack(alignment: .top, spacing: mass.pad ? 56 : (mass.portrait ? 16 : 40)) { content }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, mass.page)
            // Below the X row so no heading runs past it.
            .padding(.top, mass.top + mass.button + 6)
    }
}

/// **Delay: last row of the Audio and Subtitles columns.**
///
/// No button of its own in the bar: whoever shifts a track has just chosen
/// the track, and that is where the row is. - and + shift by 50 ms; held,
/// they repeat and speed up (`Delay.Haltezaehler`); the circular
/// arrow symbol resets to zero. For VoiceOver the row is one element that
/// is swiped up and down.
struct DelayRow: View {
    let value: Delay
    let mass: PlayerMetric
    let setDown: (Delay) -> Void
    @State private var hold = Delay.HoldCounter()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Verzögerung")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .padding(.horizontal, PlayerMetric.inset)
            HStack(spacing: 0) {
                keyButton("minus", bearing: -1, locked: value.atStart)
                Text(verbatim: value.text())
                    .font(Theme.listTitle.monospacedDigit())
                    .foregroundStyle(value.isNull ? Theme.fontQuiet : Theme.font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                keyButton("plus", bearing: 1, locked: value.atEnd)
                Button { setDown(.null) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: mass.symbol - 3, weight: .medium))
                        .foregroundStyle(Theme.fontQuiet)
                        .frame(width: mass.button, height: mass.button)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                // Space stays reserved so - value + does not jump sideways on reset.
                .opacity(value.isNull ? 0 : 1)
                .disabled(value.isNull)
                .animation(Theme.toggle, value: value.isNull)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Verzögerung"))
        .accessibilityValue(Text(verbatim: value.text()))
        .accessibilityAdjustableAction { bearing in
            switch bearing {
            case .increment: setDown(value.shifted(1))
            case .decrement: setDown(value.shifted(-1))
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Zurücksetzen")) { setDown(.null) }
    }

    private func keyButton(_ symbol: String, bearing: Int, locked: Bool) -> some View {
        Button {
            setDown(value.shifted(bearing, steps: hold.press()))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: mass.symbol - 2, weight: .semibold))
                .foregroundStyle(locked ? Theme.fontVeryQuiet : Theme.font)
                .frame(width: mass.button, height: mass.button)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        // The system repeats while held; the counter makes it faster.
        .buttonRepeatBehavior(.enabled)
        .disabled(locked)
    }
}

// MARK: - Audio & subtitles

struct TracksLayer: View {
    let surface: VLCPlayerView?
    let mass: PlayerMetric
    let close: () -> Void

    /// The own choice, independent of VLC.
    ///
    /// VLC does not apply a track choice immediately: reading `isSelected`
    /// right after still gives the old state. The display thus lagged one
    /// click behind, and on switching from "Off" to a track **both** briefly
    /// carried a checkmark. What was tapped, however, we know ourselves. The
    /// layer is rebuilt on every opening, after which VLC's state applies
    /// again.
    @State private var audioSelection: String?
    @State private var subtitleSelection: String??
    /// As with track choice: what was set, we know ourselves; the surface is
    /// not an observed quantity.
    @State private var audioLag: Delay?
    @State private var subtitleLag: Delay?

    var body: some View {
        ZStack(alignment: .top) {
            LayersReason()
            ColumnsRail(mass: mass) {
                SelectionColumn(title: "Audio", mass: mass) {
                    ForEach(surface?.audioTracks ?? [], id: \.trackId) { track in
                        LayersRow(text: track.prettyName, selected: audioNow == track.trackId,
                                  mass: mass) {
                            audioSelection = track.trackId
                            surface?.selectAudioTrack(track)
                        }
                    }
                    DelayRow(value: audioLag ?? surface?.audioDelay ?? .null,
                                       mass: mass) { new in
                        audioLag = new
                        surface?.audioDelay = new
                    }
                    .padding(.top, Theme.tileSpacing)
                }
                SelectionColumn(title: "Untertitel", mass: mass) {
                    LayersRow(text: String(localized: "Aus"), selected: subtitleNow == nil,
                              mass: mass) {
                        subtitleSelection = .some(nil)
                        surface?.selectSubtitle(nil)
                    }
                    let names = surface?.subtitleNames() ?? [:]
                    ForEach(surface?.subtitleTracks ?? [], id: \.trackId) { track in
                        LayersRow(text: names[track.trackId] ?? track.trackName,
                                  selected: subtitleNow == track.trackId, mass: mass) {
                            subtitleSelection = .some(track.trackId)
                            surface?.selectSubtitle(track)
                        }
                    }
                    DelayRow(value: subtitleLag ?? surface?.subtitleDelay ?? .null,
                                       mass: mass) { new in
                        subtitleLag = new
                        surface?.subtitleDelay = new
                    }
                    .padding(.top, Theme.tileSpacing)
                }
            }
            LayersHeader(mass: mass, close: close) { EmptyView() }
        }
        // Top like the player's header: across to the edge in landscape, under
        // the island in portrait (`Playermass.topSkip`).
        .ignoresSafeArea(edges: mass.topSkip)
        .accessibilityAction(.escape, close)
    }

    /// By `trackId`, not the name: two tracks named "German" both carried the
    /// checkmark otherwise.
    private var subtitleNow: String? {
        if let subtitleSelection { return subtitleSelection }
        return surface?.selectedSubtitle?.trackId
    }

    private var audioNow: String? {
        audioSelection ?? surface?.selectedAudioTrack?.trackId
    }
}

// MARK: - Settings

struct SettingLayer: View {
    let surface: VLCPlayerView?
    let mass: PlayerMetric
    @Binding var sleepMinutes: Int?
    /// Only when playing from the server; a downloaded file has no choice.
    let quality: QualitySelection?
    /// Only in a group: who is in it, and the way out.
    var gemeinsam: SharedModel? = nil
    var groupLeave: () -> Void = {}
    let close: () -> Void

    @AppStorage("technikschild") private var techBadge = false
    @AppStorage("bildfuellend") private var fillFrame = false

    var body: some View {
        ZStack(alignment: .top) {
            LayersReason()
            ColumnsRail(mass: mass) {
                // **Together first** (design A, step 5): who is in it, and the exit below.
                // The names do nothing.
                if let gemeinsam, let group = gemeinsam.group {
                    SelectionColumn(title: "Gemeinsam · \(group.name)", mass: mass) {
                        ForEach(Array(group.participant.enumerated()), id: \.offset) { pair in
                            ParticipantRow(name: pair.element, mass: mass)
                        }
                        Button(action: groupLeave) {
                            HStack(spacing: 8) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 18)
                                Text("Gruppe verlassen")
                            }
                            .font(Theme.listTitle)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, PlayerMetric.inset)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(Theme.PressRow())
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                    }
                }
                // **Two picture formats, not three.** The player knows the whole picture
                // and fill-screen (also via two-finger gesture); a stretched picture does
                // not exist.
                SelectionColumn(title: "Bild", mass: mass) {
                    LayersRow(text: String(localized: "Original"), selected: !fillFrame, mass: mass) {
                        fillFrame = false
                        surface?.fillFrame(false)
                    }
                    LayersRow(text: String(localized: "Füllen"), selected: fillFrame, mass: mass) {
                        fillFrame = true
                        surface?.fillFrame(true)
                    }
                }
                SelectionColumn(title: "Schlafzeit", mass: mass) {
                    LayersRow(text: String(localized: "Aus"), selected: sleepMinutes == nil, mass: mass) {
                        sleepMinutes = nil
                    }
                    ForEach(SleepTimes.values, id: \.self) { minutes in
                        LayersRow(text: String(localized: "\(minutes) Min."),
                                  selected: sleepMinutes == minutes, mass: mass) {
                            sleepMinutes = minutes
                        }
                    }
                }
                SelectionColumn(title: "Technikschild", mass: mass) {
                    LayersRow(text: String(localized: "Aus"), selected: !techBadge, mass: mass) {
                        techBadge = false
                    }
                    LayersRow(text: String(localized: "An"), selected: techBadge, mass: mass) {
                        techBadge = true
                    }
                }
                // **Quality: Direct Play or a cap.** A cap means the server may convert;
                // Direct Play is then off. It applies like the setting in the app and
                // reloads the film at the same position.
                if let quality {
                    SelectionColumn(title: "Qualität", mass: mass) {
                        LayersRow(text: String(localized: "Direct Play"),
                                    selected: quality.directPlay, mass: mass) {
                            quality.select(nil)
                        }
                        ForEach(Bitrate.levels) { rung in
                            LayersRow(text: Bitrate.text(rung.value),
                                        selected: !quality.directPlay && quality.limit == rung.value,
                                        mass: mass) {
                                quality.select(rung.value)
                            }
                        }
                    }
                }
            }
            LayersHeader(mass: mass, close: close) { EmptyView() }
        }
        // Top like the player's header: across to the edge in landscape, under
        // the island in portrait (`Playermass.topSkip`).
        .ignoresSafeArea(edges: mass.topSkip)
        .accessibilityAction(.escape, close)
    }
}

// MARK: - Episodes

/// The series' episodes: the same rows as on the series page.
///
/// The title sits exactly where it sat in the player; in place of the meta
/// line is the series page's season picker.
struct EpisodesLayer: View {
    let model: AppModel
    /// The current episode.
    let item: Item
    let title: String
    let mass: PlayerMetric
    let close: () -> Void
    let start: (Item) -> Void

    @State private var seasons: [Item] = []
    @State private var selectedSeason: Item?
    @State private var episodes: [Item] = []
    @State private var seasonListOpen = false

    /// **The list is already there on opening.** What the store has (the
    /// player preloads it at start with `preload`) is in the states before
    /// the first frame; otherwise the episodes would pop in only after the
    /// fade-in.
    init(model: AppModel, item: Item, title: String, mass: PlayerMetric,
         close: @escaping () -> Void, start: @escaping (Item) -> Void) {
        self.model = model
        self.item = item
        self.title = title
        self.mass = mass
        self.close = close
        self.start = start
        guard let series = item.seriesId,
              let remembered = SeriesCache.shared.state(series, with: model),
              !remembered.seasons.isEmpty else { return }
        let season = SeasonSelectionRule.choose(from: remembered.seasons, state: item)
        _seasons = State(initialValue: remembered.seasons)
        _selectedSeason = State(initialValue: season)
        _episodes = State(initialValue: season.flatMap { remembered.episodes[$0.id] } ?? [])
    }

    /// Seasons and the running season's episodes into the store, called as
    /// soon as the player shows an episode.
    static func preload(model: AppModel, item: Item) async {
        guard let seriesKeyID = item.seriesId, let series = Item.preCommonSeries(toward: item) else { return }
        // **A failed fetch does not go into the store.** `seasons` and `episodes`
        // return `nil` when the server stayed silent. Before, an empty list went
        // into the `SeriesCache` and the next view took it for the truth: a
        // cached network error.
        guard let seasons = await model.seasons(series), !seasons.isEmpty else { return }
        SeriesCache.shared.remember(seriesKeyID) { $0.seasons = seasons }
        guard let season = SeasonSelectionRule.choose(from: seasons, state: item) else { return }
        guard let episodes = await model.episodes(series: seriesKeyID, season: season.id) else { return }
        SeriesCache.shared.remember(seriesKeyID) { $0.episodes[season.id] = episodes }
    }

    var body: some View {
        ZStack(alignment: .top) {
            LayersReason()
            VStack(alignment: .leading, spacing: 0) {
                LayersHeader(mass: mass, close: close) {
                    VStack(alignment: .leading, spacing: 3) {
                        // Placeholder: the title itself is in the player (`stateTitle`) and
                        // does not fade along.
                        Text(verbatim: title)
                            .font(.system(size: mass.title, weight: .semibold))
                            .lineLimit(1)
                            .hidden()
                        if !seasons.isEmpty {
                            ExpandList(label: selectedSeason?.name
                                              ?? String(localized: "Staffel"),
                                          entries: seasons,
                                          text: { $0.name },
                                          isSelected: { $0.id == selectedSeason?.id },
                                          select: { season in
                                              selectedSeason = season
                                              Task { await episodesLoad(seasonSwitched: true) }
                                          },
                                          opened: $seasonListOpen,
                                          font: .system(size: mass.meta + 1, weight: .semibold),
                                          height: 28,
                                          // No surface in the player: it sits there in place of the meta line, and
                                          // that carries none.
                                          asField: false)
                        }
                    }
                }
                // The expanded season list lies over the episodes.
                .zIndex(1)

                ScrollViewReader { reader in
                    ScrollView {
                        // Lazy: a season with many episodes would otherwise build every row with
                        // its still on opening.
                        LazyVStack(spacing: 0) {
                            ForEach(episodes) { episode in
                                Button { start(episode) } label: {
                                    // The running episode carries a larger picture, no surface: it ran across
                                    // the full width here and made the Dynamic Island visible. Reasoning at
                                    // `EpisodesRow.ongoing`.
                                    EpisodesRow(model: model, episode: episode,
                                                ongoing: episode.id == item.id)
                                }
                                // A row presses like a row: surface instead of scale. Before it was
                                // `PressButton`, which pulled the whole still to 0.97, and in a list that
                                // looks like slipping. `SwipeRow` on the series page does the same.
                                .buttonStyle(Theme.PressRow())
                                // Long press: the tile menu, in the player with watch state only
                                // (`TileMenu.inPlayer`).
                                .tileMenu(episode, model: model, landscape: true, inPlayer: true,
                                             afterwards: { await episodesLoad() })
                                .accessibilityAddTraits(episode.id == item.id ? .isSelected : [])
                                .id(episode.id)
                                .transition(.opacity)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.hidden)
                    // **The running episode in view** once the list is there. On opening it
                    // sits there right away; if the list arrives later (server, season
                    // change), it glides there, and with reduced motion it jumps.
                    .onChange(of: episodes.map(\.id), initial: true) { alt, ids in
                        guard ids.contains(item.id) else { return }
                        if alt == ids || alt.isEmpty || Theme.motionReduced {
                            reader.scrollTo(item.id, anchor: .center)
                        } else {
                            withAnimation(.smooth(duration: 0.35)) {
                                reader.scrollTo(item.id, anchor: .center)
                            }
                        }
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
                        if seasonListOpen { seasonListOpen = false }
                    })
                }
                .padding(.top, 10)
            }
        }
        .ignoresSafeArea(edges: mass.topSkip)
        .environment(\.wide, mass.pad)
        .accessibilityAction(.escape, close)
        .task { await load() }
    }

    /// First what the series page's store already has, then fresh from the
    /// server.
    private func load() async {
        guard let series = Item.preCommonSeries(toward: item) else { return }
        if let remembered = SeriesCache.shared.state(series.id, with: model), !remembered.seasons.isEmpty {
            seasons = remembered.seasons
            selectedSeason = SeasonSelectionRule.choose(from: remembered.seasons, state: item)
            if let id = selectedSeason?.id, let list = remembered.episodes[id] { episodes = list }
        }
        // `nil` means disturbed: what the store had stays.
        guard let freshValue = await model.seasons(series), !freshValue.isEmpty else { return }
        seasons = freshValue
        if selectedSeason == nil || !freshValue.contains(where: { $0.id == selectedSeason?.id }) {
            selectedSeason = SeasonSelectionRule.choose(from: freshValue, state: item)
        }
        await episodesLoad()
    }

    /// Cross-fade only on season change; on opening the list is there at once.
    private func episodesLoad(seasonSwitched: Bool = false) async {
        guard let series = item.seriesId else { return }
        let season = selectedSeason?.id
        // Failed means the list stays as it was. Setting it empty would claim
        // the season has no episodes.
        guard let loaded = await model.episodes(series: series, season: season) else { return }
        // Whoever has chosen another season in the meantime gets its episodes.
        guard season == selectedSeason?.id else { return }
        if seasonSwitched {
            // The new season fades in instead of appearing abruptly. Arriving content
            // fades in over 0.28. Before it was easeOut 0.25: the same
            // intent, a number of its own.
            withAnimation(Theme.reveal) { episodes = loaded }
        } else {
            episodes = loaded
        }
        if let season { SeriesCache.shared.remember(series) { $0.episodes[season] = loaded } }
    }
}

/// The quality choice in the player: Direct Play or a cap in Mbit/s.
/// `select(nil)` means Direct Play.
struct QualitySelection {
    let directPlay: Bool
    let limit: Int
    let select: (Int?) -> Void
}
