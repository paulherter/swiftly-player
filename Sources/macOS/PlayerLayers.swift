import JellyfinKit
import SwiftUI
import VLCKit

/// Player dimensions on the Mac, in one place, so that the close button of a layer
/// sits exactly where the player's close button sat.
///
/// The counterpart of `Playermass` on iOS (`Sources/iOS/PlayerLayers.swift`), but
/// with fixed values instead of `pad`/`inWindow`: a window has no diagonal and no
/// notch the margin would need to align with, so it is the same everywhere.
struct PlayerMetric {
    /// Left and right margin.
    let page: CGFloat = 40
    /// Top inset. Reaches past the zone where the window controls sit
    /// (`Theme.signalZone`), so title and controls do not collide.
    let top: CGFloat = 28
    let bottom: CGFloat = 24
    /// Hit area of the icon buttons.
    let button: CGFloat = 38
    let symbol: CGFloat = 18
    /// The app's type scale, not a separate one.
    ///
    /// The player used to have title 22 and detail 14, making it the only place on the
    /// Mac with a second type scale, and 14 is in neither. Now the same numbers as on
    /// iPhone: title = row heading (20), detail = detail (12), time 13 like the tile
    /// title, the smallest step that is still safely legible over video.
    let title: CGFloat = 20
    let meta: CGFloat = 12
    let time: CGFloat = 13
    /// Distance of the skip pill above the bar.
    let overBar: CGFloat = 20
    /// Hit area of the seek bar.
    let bar: CGFloat = 32
    /// Indent of the rows on the layers, so column title, selection row and delay
    /// share one text edge.
    static let inset: CGFloat = 10
}

/// The three layers above the video, the same offer as on iOS.
enum PlayerLayer: Equatable {
    case tracks, episodes, settings
}

/// One of the round icon buttons at the top right, in the player as on the layers.
///
/// Unlike iOS it shows a faint circular fill on hover: a mouse needs the feedback,
/// while a finger hits what it sees anyway.
struct IconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let mass: PlayerMetric
    let action: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: mass.symbol, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: mass.button, height: mass.button)
                .background(hovers ? Theme.hoverArea : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.cornerField,
                                                 style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .help(label)
        .accessibilityLabel(Text(label))
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
    }
}

/// Base of every layer: blur plus a darkening of rgba(11,11,13,.72). It accepts
/// every click so nothing underneath seeks.
private struct LayersReason: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Theme.reason.opacity(0.72)
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

/// Header of a layer: on the left what the layer shows, on the right the close
/// button, with the same dimensions as the player's header so both close buttons
/// line up.
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

/// A column with a fixed heading; only the rows below scroll, so with 50 or more
/// subtitles the other column stays still.
private struct SelectionColumn<ContentBody: View>: View {
    let title: LocalizedStringKey
    /// Short choices take `layerColumnWidth`; the track columns pass `trackColumnWidth`.
    var width: CGFloat = Theme.layerColumnWidth
    @ViewBuilder let content: ContentBody

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column heading = sheet heading: 17 semibold with its tracking. 18 bold is in no
            // scale, and bold is used exactly once, for the page title.
            Text(title)
                .font(Theme.categoryLarge)
                .tracking(Theme.lockCategory)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .padding(.horizontal, PlayerMetric.inset)
                .padding(.bottom, 9)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { content }
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Checkmark and name. Selected is white and semibold, otherwise 62 % white, with a
/// faint fill on hover, which iOS does not need without a pointer.
private struct LayersRow: View {
    let text: String
    let selected: Bool
    let action: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark")
                    .font(Theme.listTitle)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 17)
                    // The checkmark is only an image; VoiceOver announces the selection through the
                    // row's trait.
                    .accessibilityHidden(true)
                // Track names come from the file; shown verbatim, not looked up.
                Text(verbatim: text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // The full name on hover, for the rare row that still does not fit.
            .help(Text(verbatim: text))
            // One weight. Selected means full color, not a second weight, which would change
            // the width.
            .font(Theme.body)
            .foregroundStyle(selected ? Theme.font : Theme.fontQuiet)
            .padding(.horizontal, PlayerMetric.inset)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovers ? Theme.hoverArea : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.cornerField,
                                             style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Columns side by side, centered, below the header. Each scrolls on its own.
private struct ColumnsRail<ContentBody: View>: View {
    let mass: PlayerMetric
    @ViewBuilder let content: ContentBody

    var body: some View {
        HStack(alignment: .top, spacing: 45) { content }
            .frame(maxWidth: .infinity)
            // Below the close button's row, so no heading runs past it.
            .padding(.top, mass.top + mass.button + 6)
    }
}

/// Delay: the last row of the audio and subtitle columns.
///
/// Counterpart of `Verzoegerungszeile` on iOS (rationale there), with a hover
/// surface for the pointer and the Mac player's dimensions. Subtitles (G/H) and
/// audio (J/K) can also be adjusted from the keyboard without opening the layer,
/// as in VLC (`PlayerScreen`).
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
                LagKey(symbol: "minus", mass: mass, locked: value.atStart) {
                    setDown(value.shifted(-1, steps: hold.press()))
                }
                Text(verbatim: value.text())
                    .font(Theme.body.monospacedDigit())
                    .foregroundStyle(value.isNull ? Theme.fontQuiet : Theme.font)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                LagKey(symbol: "plus", mass: mass, locked: value.atEnd) {
                    setDown(value.shifted(1, steps: hold.press()))
                }
                LagKey(symbol: "arrow.counterclockwise", mass: mass, locked: false,
                             redo: false) { setDown(.null) }
                    .help(Text("Zurücksetzen"))
                    // Reserved width, so − value + does not jump.
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
}

/// Minus, plus and reset of the delay row, with a hover surface like `IconButton`.
/// The system repeats while held.
private struct LagKey: View {
    let symbol: String
    let mass: PlayerMetric
    let locked: Bool
    var redo = true
    let action: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: mass.symbol - 3, weight: .semibold))
                .foregroundStyle(locked ? Theme.fontVeryQuiet : Theme.font)
                .frame(width: mass.button, height: mass.button)
                .background(hovers && !locked ? Theme.hoverArea : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .buttonRepeatBehavior(redo ? .enabled : .disabled)
        .disabled(locked)
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
    }
}

/// A name in the "Together" column: information, not a button. Same dimensions as
/// `LayersRow`, so the names line up with the rows next to it.
private struct ParticipantRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "person.fill")
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .frame(width: 17)
            // A user name from the server, shown verbatim.
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(Theme.body)
        .foregroundStyle(Theme.font)
        .padding(.horizontal, PlayerMetric.inset)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Audio and subtitles

struct TracksLayer: View {
    let area: VLCPlayerView?
    let mass: PlayerMetric
    let close: () -> Void

    /// The user's own selection, independent of VLC. VLC does not apply a track choice
    /// immediately, and without this intermediate state the wrong track, or none, would
    /// briefly carry the checkmark after a switch. See the iOS version.
    @State private var audioSelection: String?
    @State private var subtitleSelection: String??
    @State private var audioLag: Delay?
    @State private var subtitleLag: Delay?

    var body: some View {
        ZStack(alignment: .top) {
            LayersReason()
            ColumnsRail(mass: mass) {
                SelectionColumn(title: "Audio", width: Theme.trackColumnWidth) {
                    ForEach(area?.audioTracks ?? [], id: \.trackId) { track in
                        LayersRow(text: area?.audioLabel(track) ?? track.prettyName, selected: audioNow == track.trackId) {
                            audioSelection = track.trackId
                            area?.selectAudioTrack(track)
                        }
                    }
                    DelayRow(value: audioLag ?? area?.audioDelay ?? .null,
                                       mass: mass) { new in
                        audioLag = new
                        area?.audioDelay = new
                    }
                    .padding(.top, Theme.tileSpacing)
                }
                SelectionColumn(title: "Untertitel", width: Theme.trackColumnWidth) {
                    LayersRow(text: String(localized: "Aus"), selected: subtitleNow == nil) {
                        subtitleSelection = .some(nil)
                        area?.selectSubtitle(nil)
                    }
                    let names = area?.subtitleNames() ?? [:]
                    ForEach(area?.subtitleTracks ?? [], id: \.trackId) { track in
                        LayersRow(text: names[track.trackId] ?? track.trackName,
                                  selected: subtitleNow == track.trackId) {
                            subtitleSelection = .some(track.trackId)
                            area?.selectSubtitle(track)
                        }
                    }
                    DelayRow(value: subtitleLag ?? area?.subtitleDelay ?? .null,
                                       mass: mass) { new in
                        subtitleLag = new
                        area?.subtitleDelay = new
                    }
                    .padding(.top, Theme.tileSpacing)
                }
            }
            LayersHeader(mass: mass, close: close) { EmptyView() }
        }
        .accessibilityAction(.escape, close)
    }

    /// Matched by `trackId`, not by name: two tracks named "Deutsch" would both get the
    /// checkmark otherwise.
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
    let mass: PlayerMetric
    @Binding var sleepMinutes: Int?
    /// Only when playing from the server; a downloaded file offers no choice.
    let quality: QualitySelection?
    /// Only inside a group: who is present, and the way out.
    var gemeinsam: SharedModel? = nil
    var groupLeave: () -> Void = {}
    let close: () -> Void

    @AppStorage("technikschild") private var techBadge = false
    @AppStorage("bildfuellend") private var fillFrame = false
    @State private var leaveHovers = false

    var body: some View {
        ZStack(alignment: .top) {
            LayersReason()
            ColumnsRail(mass: mass) {
                // "Together" comes first: who is present, and below it the exit. The names do
                // nothing.
                if let gemeinsam, let group = gemeinsam.group {
                    SelectionColumn(title: "Gemeinsam · \(group.name)") {
                        ForEach(Array(group.participant.enumerated()), id: \.offset) { pair in
                            ParticipantRow(name: pair.element)
                        }
                        Button(action: groupLeave) {
                            HStack(spacing: 9) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(Theme.listTitle)
                                    .frame(width: 17)
                                Text("Gruppe verlassen")
                            }
                            .font(Theme.body)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(leaveHovers ? Theme.hoverArea : .clear,
                                        in: RoundedRectangle(cornerRadius: Theme.cornerField,
                                                             style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(Theme.PressRow())
                        .onHover { leaveHovers = $0 }
                        .animation(Theme.timeFloat, value: leaveHovers)
                    }
                }
                // Two picture formats, not three: the iOS rule verbatim. The player knows the
                // original picture and fill (also via pinch); a stretched picture does not exist.
                SelectionColumn(title: "Bild") {
                    LayersRow(text: String(localized: "Original"), selected: !fillFrame) {
                        fillFrame = false
                        area?.fillFrame(false)
                    }
                    LayersRow(text: String(localized: "Füllen"), selected: fillFrame) {
                        fillFrame = true
                        area?.fillFrame(true)
                    }
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
                // Quality: Direct Play or a cap. A cap means the server may transcode, so Direct
                // Play is off. Applies like the in-app setting and reloads the movie at the same
                // position.
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
            LayersHeader(mass: mass, close: close) { EmptyView() }
        }
        .accessibilityAction(.escape, close)
    }
}

/// The quality choice in the player: Direct Play or a cap in Mbit/s.
/// `select(nil)` means Direct Play.
struct QualitySelection {
    let directPlay: Bool
    let limit: Int
    let select: (Int?) -> Void
}

// MARK: - Episodes

/// The series' episodes, using the same rows as the Mac series page (`EpisodesRow`
/// in `SeriesView.swift`), not rebuilt.
///
/// The title sits exactly where it sat in the player (`stateTitle` in
/// `PlayerScreen.swift`); in place of the meta line is the series page's season
/// picker (`Staffelwahl`, also there).
///
/// Loading mirrors the iOS version (`EpisodesLayer` in `Sources/iOS/PlayerLayers.swift`):
/// first the series page's cache, then fresh from the server, cross-fade only on a
/// season switch. A separate type instead of a shared function, because both
/// versions depend on their own `@State` values and moving this into `JellyfinKit`
/// would go beyond the macOS-only scope.
struct EpisodesLayer: View {
    let model: AppModel
    /// The episode currently playing.
    let item: Item
    let title: String
    let mass: PlayerMetric
    let close: () -> Void
    let start: (Item) -> Void

    @State private var seasons: [Item] = []
    @State private var selectedSeason: Item?
    @State private var episodes: [Item] = []
    @State private var seasonListOpen = false

    var body: some View {
        ZStack(alignment: .top) {
            LayersReason()
            VStack(alignment: .leading, spacing: 0) {
                LayersHeader(mass: mass, close: close) {
                    VStack(alignment: .leading, spacing: 3) {
                        // Placeholder: the title itself is shown by the player (`stateTitle`) and does
                        // not fade with this.
                        Text(verbatim: title)
                            .font(.system(size: mass.title, weight: .bold))
                            .lineLimit(1)
                            .hidden()
                        if !seasons.isEmpty {
                            SeasonSelection(seasons: seasons, selected: $selectedSeason,
                                        opened: $seasonListOpen, limited: true)
                                .onChange(of: selectedSeason?.id) { _, _ in
                                    Task { await episodesLoad(seasonSwitched: true) }
                                }
                        }
                    }
                }
                // The expanded season list lies over the episodes.
                .zIndex(1)

                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(episodes) { episode in
                                // `action:` is spelled out, not a trailing closure. That was needed once because
                                // `EpisodesRow` carried `ringtipp` before it, and Swift's rule for trailing
                                // closures would have bound it there. The ring is gone, but the explicit label
                                // stays: it says what the closure does.
                                EpisodesRow(model: model, episode: episode,
                                            action: { selectedEpisode in start(selectedEpisode) })
                                // `selected` is exactly this value: white at eight percent, the fill of a playing
                                // row.
                                .background(episode.id == item.id ? Theme.selected : .clear)
                                // Right click: the tile menu, in the player only with the watched state
                                // (`TileMenu.inPlayer`).
                                .tileMenu(episode, model: model, inPlayer: true,
                                             afterwards: { await episodesLoad() })
                                .accessibilityAddTraits(episode.id == item.id ? .isSelected : [])
                                .id(episode.id)
                                .transition(.opacity)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .scrollIndicators(.hidden)
                    // Bring the playing episode into view once the list is ready.
                    .onChange(of: episodes.map(\.id), initial: true) { _, ids in
                        guard ids.contains(item.id) else { return }
                        reader.scrollTo(item.id, anchor: .center)
                    }
                }
                .padding(.top, 10)
            }
        }
        .accessibilityAction(.escape, close)
        .task { await load() }
    }

    /// First what the series page's cache already has, then fresh from the server.
    private func load() async {
        guard let series = Item.preCommonSeries(toward: item) else { return }
        if let remembered = SeriesCache.shared.state(series.id, with: model), !remembered.seasons.isEmpty {
            seasons = remembered.seasons
            selectedSeason = SeasonSelectionRule.choose(from: remembered.seasons, state: item)
            if let id = selectedSeason?.id, let list = remembered.episodes[id] { episodes = list }
        }
        // `nil` means a failure: what the cache had stays.
        guard let freshValue = await model.seasons(series), !freshValue.isEmpty else { return }
        seasons = freshValue
        if selectedSeason == nil || !freshValue.contains(where: { $0.id == selectedSeason?.id }) {
            selectedSeason = SeasonSelectionRule.choose(from: freshValue, state: item)
        }
        await episodesLoad()
    }

    /// Cross-fade only on a season switch; on open the list is shown immediately.
    private func episodesLoad(seasonSwitched: Bool = false) async {
        guard let series = item.seriesId else { return }
        let season = selectedSeason?.id
        // Failed means the list stays as it was. Clearing it would claim the season has no
        // episodes.
        guard let loaded = await model.episodes(series: series, season: season) else { return }
        // Whoever has switched to another season in the meantime gets that season's
        // episodes.
        guard season == selectedSeason?.id else { return }
        if seasonSwitched {
            withAnimation(Theme.reveal) { episodes = loaded }
        } else {
            episodes = loaded
        }
        if let season { SeriesCache.shared.remember(series) { $0.episodes[season] = loaded } }
    }
}
