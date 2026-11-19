import JellyfinKit
import SwiftlyCore
import SwiftUI

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
    case tracks, episodes, settings, chapters
}

/// One of the round icon buttons at the top right, in the player and on
/// the layers.
struct IconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let mass: PlayerMetric
    /// A menu of this button is open: the button wears a light surface (white 12 %), faded in over 120 ms.
    var open = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(icon: symbol, size: mass.symbol)
                .font(.app(size: mass.symbol, weight: Theme.overlayWeight))
                .foregroundStyle(.white)
                .frame(width: mass.button, height: mass.button)
                .background(Circle().fill(Color.white.opacity(open ? 0.12 : 0)))
                .animation(.easeOut(duration: 0.12), value: open)
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
struct LayersHeader<Left: View>: View {
    let mass: PlayerMetric
    let close: () -> Void
    @ViewBuilder let left: Left

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            left
            Spacer(minLength: 0)
            // The same glass circle at the same spot as the player bar's X (design: 745 / 8), so the X does not move
            // when the panel opens.
            PlayerCloseButton(mass: mass, label: "Schließen", action: close)
                .offset(y: -8)
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
    /// Only the track columns are wide: their labels carry language, title and codec. The short
    /// choices (picture, sleep timer, badge, quality) keep the narrow column, or three of them no
    /// longer fit side by side on a landscape iPhone.
    var wide = false
    @ViewBuilder let content: ContentBody

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                // Exactly the grade of the player title, which computes with the window
                // size. The same numbers used to be typed by hand here (22/19); a role with
                // two sources eventually drifts apart.
                // Semibold, not bold: 20 is the row heading, and bold appears exactly once,
                // at the page title.
                .font(.app(size: mass.title, weight: .semibold))
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
        .frame(maxWidth: wide ? (mass.pad ? Theme.trackColumnWidthPad : Theme.trackColumnWidth)
                              : (mass.pad ? 260 : 210),
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
                Image(icon: "checkmark", size: mass.pad ? 15 : 14)
                    .font(.app(size: mass.pad ? 15 : 14, weight: .semibold))
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
            Image(icon: "person.fill", size: mass.pad ? 15 : 14)
                .font(.app(size: mass.pad ? 15 : 14))
                .foregroundStyle(Theme.font)
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
                    Image(icon: "arrow.counterclockwise", size: mass.symbol)
                        .font(.app(size: mass.symbol, weight: Theme.overlayWeight))
                        .foregroundStyle(Theme.font)
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
            Image(icon: symbol, size: mass.symbol)
                .font(.app(size: mass.symbol, weight: Theme.overlayWeight))
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

// MARK: - Speed and subtitle offset (rows from the core)

/// The "Geschwindigkeit" column: the speeds, their labels and the marked one come from the core's menu
/// (`PlayerVm.menu`); a press sends the speed back. Nothing is listed or formatted here.
private struct SpeedColumn: View {
    let surface: VLCPlayerView?
    let mass: PlayerMetric
    @State private var refresh = 0

    var body: some View {
        let _ = refresh
        if let menu = surface?.playerMenu() {
            SelectionColumn(title: LocalizedStringKey(menu.speedTitle), mass: mass) {
                ForEach(menu.speeds, id: \.value) { row in
                    LayersRow(text: row.label == "Normal" ? String(localized: "Normal") : row.label,
                              selected: row.selected, mass: mass) {
                        surface?.tempo = row.value
                        refresh += 1
                    }
                }
            }
        }
    }
}

/// The "Untertitel-Versatz" rows: current value, four step buttons and the reset, all from the core's menu.
private struct SubtitleOffsetRows: View {
    let surface: VLCPlayerView?
    let mass: PlayerMetric
    @State private var refresh = 0

    var body: some View {
        let _ = refresh
        if let menu = surface?.playerMenu() {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(LocalizedStringKey(menu.offsetTitle))
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                    Spacer()
                    Text(verbatim: menu.offsetText)
                        .font(Theme.listTitle.monospacedDigit())
                        .foregroundStyle(menu.canReset ? Theme.font : Theme.fontQuiet)
                }
                .padding(.horizontal, PlayerMetric.inset)
                HStack(spacing: 0) {
                    ForEach(menu.offsetSteps, id: \.stepMs) { step in
                        Button {
                            surface?.offsetStep(step.stepMs)
                            refresh += 1
                        } label: {
                            Text(verbatim: step.label)
                                .font(Theme.listTitle.monospacedDigit())
                                .foregroundStyle(Theme.font)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, minHeight: mass.button)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(Theme.PressButton())
                    }
                }
                Button {
                    surface?.offsetReset()
                    refresh += 1
                } label: {
                    Text(LocalizedStringKey(menu.resetLabel))
                        .font(Theme.listTitle)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, PlayerMetric.inset)
                        .frame(maxWidth: .infinity, minHeight: mass.button, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .opacity(menu.canReset ? 1 : 0.35)
                .disabled(!menu.canReset)
            }
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: - Audio & subtitles

/// What the tracks layer needs for the subtitle search. `nil` (Plex, no session) hides the entry.
struct SubtitleSearchLink {
    /// A search of the running title (the core's `SubtitleSearchVm`).
    let make: () -> SwiftlyCore.SubtitleSearchVm?
    /// The server has the new track (its stream index, `nil` when the server did not show it yet): the player reloads the
    /// title at the position with that track switched on.
    let added: (Int?) -> Void
}

struct TracksLayer: View {
    let surface: VLCPlayerView?
    let mass: PlayerMetric
    var search: SubtitleSearchLink?
    /// Opened from the menu's magnifier: starts in the search.
    var startsInSearch = false
    let close: () -> Void

    @State private var searchVm: SwiftlyCore.SubtitleSearchVm?

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

    var body: some View {
        ZStack(alignment: .top) {
            LayersReason()
            if let searchVm {
                SubtitleSearchPanel(vm: searchVm, mass: mass, added: { search?.added($0) })
                LayersHeader(mass: mass, close: { startsInSearch ? close() : (self.searchVm = nil) }) { EmptyView() }
            } else {
            ColumnsRail(mass: mass) {
                SelectionColumn(title: "Audio", mass: mass, wide: true) {
                    ForEach(surface?.audioTracks ?? [], id: \.trackId) { track in
                        LayersRow(text: surface?.audioLabel(track) ?? track.prettyName, selected: audioNow == track.trackId,
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
                SelectionColumn(title: "Untertitel", mass: mass, wide: true) {
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
                    if let search {
                        LayersRow(text: String(localized: "Untertitel suchen …"), selected: false, mass: mass) {
                            searchVm = search.make()
                        }
                    }
                    SubtitleOffsetRows(surface: surface, mass: mass)
                        .padding(.top, Theme.tileSpacing)
                }
            }
            LayersHeader(mass: mass, close: close) { EmptyView() }
            }
        }
        #if DEBUG
        .task { if LiveRun.opensSubtitleSearch, searchVm == nil { searchVm = search?.make() } }
        #endif
        .task { if startsInSearch, searchVm == nil { searchVm = search?.make() } }
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

// MARK: - Subtitle search

/// The core's subtitle search drawn as it is: language chips, then the rows of the state. Nothing is decided here.
private struct SubtitleSearchPanel: View {
    let vm: SwiftlyCore.SubtitleSearchVm
    let mass: PlayerMetric
    let added: (Int?) -> Void
    @State private var part: SwiftlyCore.SubtitleSearchPart
    @State private var reported = false

    init(vm: SwiftlyCore.SubtitleSearchVm, mass: PlayerMetric, added: @escaping (Int?) -> Void) {
        self.vm = vm
        self.mass = mass
        self.added = added
        _part = State(initialValue: vm.part())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: part.title)
                .font(.app(size: mass.title, weight: .semibold))
                .foregroundStyle(Theme.font)
                .padding(.horizontal, PlayerMetric.inset)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                ForEach(part.languages, id: \.value) { language in
                    Button { vm.send(intent: .search(language: language.value)) } label: {
                        Text(verbatim: language.label)
                            .font(Theme.listTitle)
                            .foregroundStyle(language.selected ? Theme.font : Theme.fontQuiet)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(language.selected ? Color.white.opacity(0.18) : .clear, in: Capsule())
                    }
                    .buttonStyle(Theme.PressButton())
                    .accessibilityAddTraits(language.selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, PlayerMetric.inset)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch part.phase {
                    case .idle, .loading:
                        ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 24)
                    case .results, .downloading:
                        ForEach(part.rows, id: \.id) { row in
                            Button { vm.send(intent: .download(id: row.id)) } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: row.title).font(Theme.listTitle).foregroundStyle(Theme.font).lineLimit(1)
                                        Text(verbatim: row.sourceLine).font(Theme.small).foregroundStyle(Theme.fontQuiet).lineLimit(1)
                                        if !row.metaLine.isEmpty {
                                            Text(verbatim: row.metaLine).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if row.busy { ProgressView().tint(.white) }
                                }
                                .padding(.horizontal, PlayerMetric.inset).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(Theme.PressRow())
                            .disabled(part.phase == .downloading)
                        }
                    case .empty, .noProvider, .failed, .done:
                        Text(verbatim: part.message ?? "")
                            .font(Theme.listTitle).foregroundStyle(Theme.fontQuiet)
                            .padding(.horizontal, PlayerMetric.inset).padding(.top, 16)
                    }
                }
            }
        }
        .padding(.top, mass.top + mass.button)
        .padding(.horizontal, mass.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #if DEBUG
        // The live run presses the first row on its own cue: the core has nothing new to say after the results, so the
        // pick cannot wait for a change of the part.
        .onReceive(NotificationCenter.default.publisher(for: LiveRun.pickSearchRow)) { _ in
            if part.phase == .results, let first = part.rows.first { vm.send(intent: .download(id: first.id)) }
        }
        #endif
        .task {
            vm.send(intent: .search(language: nil))
            part = vm.part()
            var seen = part.version
            while !Task.isCancelled {
                _ = try? await vm.changed(seen: seen)
                part = vm.part()
                seen = part.version
                #if DEBUG
                LiveRun.searchSnapshot = (String(describing: part.phase), part.rows.map(\.title), part.message ?? "")
                #endif
                if part.phase == .done, !reported { reported = true; added(part.selectedTrack.map(Int.init)) }
            }
        }
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
    /// "Problem melden" (Seerr), only when the account may report; the player opens the report sheet.
    var report: (() -> Void)? = nil
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
                        ForEach(Array(gemeinsam.participants.enumerated()), id: \.offset) { pair in
                            ParticipantRow(name: pair.element, mass: mass)
                        }
                        Button(action: groupLeave) {
                            HStack(spacing: 8) {
                                Image(icon: "rectangle.portrait.and.arrow.right", size: 14)
                                    .font(.app(size: 14, weight: .semibold))
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
                SpeedColumn(surface: surface, mass: mass)
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
                // **A problem with this film or episode** goes to the people who run the server. The place
                // (season, episode, the position now) is filled in by the player.
                if let report {
                    SelectionColumn(title: "Problem", mass: mass) {
                        LayersRow(text: String(localized: "Problem melden"), selected: false, mass: mass, action: report)
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

    let picker: SeasonPicker
    /// The core's season button (its value is the open season); `nil` without the core: the old list shows.
    var seasonButton: PlayerMenuValueRow?
    @Binding var anchors: PlayerMenuAnchors
    var openSeasons: () -> Void = {}
    /// The panel's tabs (design: Folgen | Kapitel; a film has only Kapitel) and the chapter strip's data.
    var tabs: [PlayerMenuPanelTab] = [.episodes]
    var chapters: PlayerChapters?
    var chapterPreview: (Double, PlayerPreview?) -> CGImage? = { _, _ in nil }
    var jumpToChapter: (Int) -> Void = { _ in }
    /// Design option C: the panel as a 372 x 321 box under the Folgen button (like the other menus) instead of the full layer.
    var boxed = false
    @Environment(\.menuMaxHeight) private var menuMaxHeight
    @State private var tab: PlayerMenuPanelTab
    @Namespace private var tabLine
    private var seasons: [Item] { get { picker.seasons } nonmutating set { picker.seasons = newValue } }
    private var selectedSeason: Item? { get { picker.selected } nonmutating set { picker.selected = newValue } }
    @State private var episodes: [Item] = []
    @State private var seasonListOpen = false

    /// **The list is already there on opening.** What the store has (the
    /// player preloads it at start with `preload`) is in the states before
    /// the first frame; otherwise the episodes would pop in only after the
    /// fade-in.
    init(model: AppModel, item: Item, title: String, mass: PlayerMetric, picker: SeasonPicker,
         seasonButton: PlayerMenuValueRow?, anchors: Binding<PlayerMenuAnchors>, openSeasons: @escaping () -> Void,
         tabs: [PlayerMenuPanelTab] = [.episodes], startTab: PlayerMenuPanelTab = .episodes, chapters: PlayerChapters? = nil,
         chapterPreview: @escaping (Double, PlayerPreview?) -> CGImage? = { _, _ in nil },
         jumpToChapter: @escaping (Int) -> Void = { _ in }, boxed: Bool = false,
         close: @escaping () -> Void, start: @escaping (Item) -> Void) {
        self.boxed = boxed
        self.tabs = tabs
        self.chapters = chapters
        self.chapterPreview = chapterPreview
        self.jumpToChapter = jumpToChapter
        _tab = State(initialValue: tabs.contains(startTab) ? startTab : (tabs.first ?? .episodes))
        self.picker = picker
        self.seasonButton = seasonButton
        _anchors = anchors
        self.openSeasons = openSeasons
        self.model = model
        self.item = item
        self.title = title
        self.mass = mass
        self.close = close
        self.start = start
        guard let series = item.seriesId,
              let remembered = SeriesCache.shared.state(series, with: model),
              !remembered.seasons.isEmpty else { return }
        // The init runs on every re-evaluation of the parent: a season the viewer already chose must stay.
        picker.adopt(seasons: remembered.seasons, rule: SeasonSelectionRule.choose(from: remembered.seasons, state: item))
        _episodes = State(initialValue: picker.selected.flatMap { remembered.episodes[$0.id] } ?? [])
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

    private var fullContent: some View {
        ZStack(alignment: .top) {
            LayersReason()
            VStack(alignment: .leading, spacing: 0) {
                LayersHeader(mass: mass, close: close) {
                    // Design (Player-Menüs, runde 2): title, then one row with the tabs and, on the Folgen tab, the season button.
                    VStack(alignment: .leading, spacing: 10) {
                        // Placeholder: the title itself is in the player (`stateTitle`) and
                        // does not fade along.
                        Text(verbatim: title)
                            .font(.app(size: mass.title, weight: .semibold))
                            .lineLimit(1)
                            .hidden()
                        HStack(alignment: .center, spacing: 16) {
                            panelTabs
                        }
                        if tab == .episodes, seasonButton == nil, !seasons.isEmpty {
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
                                          font: .app(size: mass.meta + 1, weight: .semibold),
                                          height: 28,
                                          // No surface in the player: it sits there in place of the meta line, and
                                          // that carries none.
                                          asField: false)
                        }
                    }
                }
                // The expanded season list lies over the episodes.
                .zIndex(1)

                // The same strip as on Apple TV: landscape tiles side by side, the running
                // episode marked and brought to the middle once the row is there.
                ZStack(alignment: .topLeading) {
                if tab == .chapters {
                    chapterStrip.transition(.opacity)
                } else {
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .bottom, spacing: 12) {
                            ForEach(episodes) { episode in
                                Button { start(episode) } label: {
                                    EpisodeStripTile(model: model, episode: episode,
                                                     ongoing: episode.id == item.id, pad: mass.pad)
                                }
                                .buttonStyle(Theme.PressButton())
                                // Long press: the tile menu, in the player with watch state only
                                // (`TileMenu.inPlayer`).
                                .tileMenu(episode, model: model, landscape: true, inPlayer: true,
                                             afterwards: { await episodesLoad() })
                                .accessibilityAddTraits(episode.id == item.id ? .isSelected : [])
                                .id(episode.id)
                                .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, mass.page)
                    }
                    .scrollIndicators(.hidden)
                    .fixedSize(horizontal: false, vertical: true)
                    // **The running episode in view** once the row is there. On opening it
                    // sits there right away; if the row arrives later (server, season
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
                .transition(.opacity)
                }
                }
                .animation(Theme.motionReduced ? Theme.fadeReduced : .easeOut(duration: 0.15), value: tab)
                // Design: the running tile's top sits 36 below the tab row.
                .padding(.top, 36)

                Spacer(minLength: 0)
            }
            // Tap on the empty ground only closes the season list. The layer closes via the
            // X and the episodes button, like every other player layer.
            .background {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { if seasonListOpen { seasonListOpen = false } }
            }
        }
    }

    var body: some View {
        Group { if boxed { boxContent } else { fullContent } }
        .ignoresSafeArea(edges: boxed ? [] : mass.topSkip)
        .environment(\.wide, mass.pad)
        .accessibilityAction(.escape, close)
        .task { await load() }
        #if DEBUG
        // Scenario hook: a tap on the first tile of the strip (what a finger does), logged.
        .onReceive(NotificationCenter.default.publisher(for: LiveRun.openLayer)) { note in
            guard note.object as? String == "tapfirst", let first = episodes.first else { return }
            LiveRun.event(["kind": "strip-tap", "episode": first.id, "season": selectedSeason?.id ?? "", "count": episodes.count])
            start(first)
        }
        #endif
        // A choice from the season box.
        .onChange(of: picker.chosen) { _, id in
            guard picker.takeChoice(id) != nil else { return }
            Task { await episodesLoad(seasonSwitched: true) }
        }
    }

    // MARK: Box (design option C)

    private var boxContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelTabs
                .padding(.leading, 10)
                .frame(height: 46, alignment: .bottomLeading)
                .padding(.bottom, 4)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if tab == .chapters {
                            ForEach(chapters?.rows ?? [], id: \.index) { row in
                                boxRow(id: Int(row.index), now: row.current,
                                       title: row.title(numberTitle: chapters?.numberTitle ?? "Kapitel %lld"),
                                       line: row.current ? "\(String(localized: "Läuft")) · \(row.startText)" : row.startText,
                                       action: { jumpToChapter(Int(row.index)); close() }) {
                                    Group {
                                        if let image = chapterPreview(row.start, row.preview) {
                                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                                        } else { Theme.area }
                                    }
                                    .frame(width: 100, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        } else {
                            ForEach(episodes) { episode in
                                boxRow(id: episode.id, now: episode.id == item.id, title: episode.stripHeaderLine,
                                       line: episode.stripDurationLine, action: { start(episode) }) {
                                    Picture(url: model.imageURL(for: episode, maxHeight: 360)
                                                   ?? model.landscapeImageURL(for: episode, width: 640),
                                            width: 100, height: 56, corner: 8,
                                            progress: episode.isWatched ? nil : episode.watchedShare) { Theme.area }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
                .onChange(of: episodes.map(\.id), initial: true) { _, ids in
                    if tab == .episodes, ids.contains(item.id) { reader.scrollTo(item.id, anchor: .center) }
                }
                .onAppear {
                    if tab == .chapters, let now = chapters?.rows.first(where: \.current) { reader.scrollTo(Int(now.index), anchor: .center) }
                }
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .animation(Theme.motionReduced ? Theme.fadeReduced : .easeOut(duration: 0.15), value: tab)
        }
        // The surface, edge and shadow are the menu box's (`MenuBox`): this is only what lies inside it.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: min(MenuMetric.folgenHeight, menuMaxHeight))
    }

    private func boxRow<Still: View, ID: Hashable>(id: ID, now: Bool, title: String, line: String?, action: @escaping () -> Void,
                                                   @ViewBuilder still: () -> Still) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                still().frame(width: 100, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.app(size: 13, weight: .semibold)).foregroundStyle(Theme.font)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if let line, !line.isEmpty {
                        Text(verbatim: line).font(.app(size: 12)).foregroundStyle(now ? Theme.accent : Theme.fontVeryQuiet).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(now ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityAddTraits(now ? .isSelected : [])
        .id(id)
    }

    /// Tabs "Folgen | Kapitel": 15 semibold, the open one white with a 2 pt line under it that glides to the other tab
    /// (smooth 0.25), the other grey; 20 between the tabs, 5 between label and line.
    private var panelTabs: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(tabs, id: \.self) { t in
                let on = t == tab
                Button {
                    // The first tab IS the season button: it opens the season list; from another tab it first comes back.
                    if t == .episodes, seasonButton != nil, !seasons.isEmpty, on { openSeasons(); return }
                    guard !on else { return }
                    withAnimation(Theme.motionReduced ? Theme.fadeReduced : .smooth(duration: 0.25)) { tab = t }
                } label: {
                    HStack(spacing: 5) {
                        if t == .episodes, let seasonButton {
                            // "Staffel N ⌄" (the open season) in place of the word "Folgen", like the detail page's season picker.
                            Text(verbatim: seasonButton.value.text)
                                .contentTransition(.opacity)
                            Image(icon: "chevron.down", size: 11).font(.app(size: 11, weight: .semibold))
                        } else {
                            Text(t == .episodes ? LocalizedStringKey("Folgen") : LocalizedStringKey("Kapitel"))
                        }
                    }
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(on ? Theme.font : Theme.fontVeryQuiet)
                    .padding(.bottom, 7)
                    .overlay(alignment: .bottom) {
                        if on { Theme.font.frame(height: 2).matchedGeometryEffect(id: "tabline", in: tabLine) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .background { if t == .episodes { Color.clear.menuAnchor(.seasons, into: $anchors) } }
                .animation(Theme.toggle, value: t == .episodes ? seasonButton?.value.text : nil)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityValue(Text(verbatim: t == .episodes ? (seasonButton?.value.text ?? "") : ""))
            }
        }
    }

    /// The chapter tiles in the same strip as the episodes: the running chapter larger, bottoms aligned.
    private var chapterStrip: some View {
        let rows = chapters?.rows ?? []
        return ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .bottom, spacing: 12) {
                    ForEach(rows, id: \.index) { row in
                        Button { jumpToChapter(Int(row.index)); close() } label: {
                            StripTile(width: mass.pad ? Theme.railsLandscapeWidth(wide: true) : 200,
                                      height: mass.pad ? Theme.railsLandscapeHeight(wide: true) : 112, ongoing: row.current,
                                      header: row.title(numberTitle: chapters?.numberTitle ?? "Kapitel %lld"),
                                      line: row.current ? "\(String(localized: "Läuft")) · \(row.startText)" : row.startText) { w, h in
                                Group {
                                    if let image = chapterPreview(row.start, row.preview) {
                                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                                    } else { Theme.area }
                                }
                                .frame(width: w, height: h)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                        .buttonStyle(Theme.PressButton())
                        .accessibilityAddTraits(row.current ? .isSelected : [])
                        .id(row.index)
                    }
                }
                .padding(.horizontal, mass.page)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { if let now = rows.first(where: \.current) { reader.scrollTo(now.index, anchor: .center) } }
        }
    }

    /// First what the series page's store already has, then fresh from the
    /// server.
    private func load() async {
        guard let series = Item.preCommonSeries(toward: item) else { return }
        if let remembered = SeriesCache.shared.state(series.id, with: model), !remembered.seasons.isEmpty {
            seasons = remembered.seasons
            // A season the viewer already chose stays; the rule only picks the first time.
            selectedSeason = remembered.seasons.first(where: { $0.id == selectedSeason?.id })
                ?? SeasonSelectionRule.choose(from: remembered.seasons, state: item)
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
        guard season == selectedSeason?.id else {
            AppLog.writeOut("[Staffel] episodes of \(season ?? "-") dropped, open is \(selectedSeason?.id ?? "-")")
            return
        }
        AppLog.writeOut("[Staffel] episodes of \(season ?? "-") loaded: \(loaded.count)")
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

/// One episode in the player's strip: landscape still with progress bar and watched mark,
/// number and title, runtime. Texts from `Item.stripHeaderLine`/`stripDurationLine`, shared
/// with the Apple TV strip (`EpisodesStrip`). The running episode is larger (1.2x) than the others, without an outline.
private struct EpisodeStripTile: View {
    let model: AppModel
    let episode: Item
    let ongoing: Bool
    let pad: Bool

    var body: some View {
        StripTile(width: pad ? Theme.railsLandscapeWidth(wide: true) : 200,
                  height: pad ? Theme.railsLandscapeHeight(wide: true) : 112, ongoing: ongoing,
                  header: episode.stripHeaderLine, line: episode.stripDurationLine,
                  watched: episode.isWatched) { w, h in
            Picture(url: model.imageURL(for: episode, maxHeight: 360)
                           ?? model.landscapeImageURL(for: episode, width: 640),
                    width: w, height: h, corner: 10,
                    // A full bar and a check mark would say the same twice.
                    progress: episode.isWatched ? nil : episode.watchedShare) {
                Theme.area.overlay {
                    Image(icon: episode.tileCharacter, size: 22)
                        .font(.app(size: 22))
                        .foregroundStyle(Theme.font)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: episode.stripHeaderLine))
        .accessibilityValue(Text(verbatim: [episode.stripDurationLine, episode.tileState]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")))
    }
}

/// **One tile of the panel's strip** (design: still 200 x 112, radius 10; the running one 230 x 129, so 1.15 larger; 8 below
/// it the header 13 semibold and the line 12 regular, 2 apart; the text is the same size on every tile and the stills sit
/// on one bottom edge).
private struct StripTile<Still: View>: View {
    let width: CGFloat
    let height: CGFloat
    let ongoing: Bool
    let header: String
    var line: String?
    var watched = false
    @ViewBuilder let still: (CGFloat, CGFloat) -> Still

    private let grow: CGFloat = 1.15

    var body: some View {
        let w = width * (ongoing ? grow : 1), h = height * (ongoing ? grow : 1)
        VStack(alignment: .leading, spacing: 8) {
            still(w, h)
                .overlay(alignment: .topTrailing) { if watched { TileBadge(mark: .watched) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: header).font(.app(size: 13, weight: .semibold)).foregroundStyle(Theme.font)
                    .lineLimit(1).frame(height: 16, alignment: .leading)
                if let line {
                    Text(verbatim: line).font(.app(size: 12)).foregroundStyle(Theme.fontVeryQuiet)
                        .lineLimit(1).frame(height: 15, alignment: .leading)
                }
            }
            .frame(width: w, alignment: .leading)
        }
        .frame(width: w, alignment: .leading)
        .animation(Theme.motionReduced ? Theme.fadeReduced : .smooth(duration: 0.25), value: ongoing)
    }
}

/// The quality choice in the player: Direct Play or a cap in Mbit/s.
/// `select(nil)` means Direct Play.
struct QualitySelection {
    let directPlay: Bool
    let limit: Int
    let select: (Int?) -> Void
}

/// The chapter list: the core's rows (name or "Kapitel n", start, preview tile, running one marked); a tap sends the jump.
struct ChaptersLayer: View {
    let surface: VLCPlayerView?
    let mass: PlayerMetric
    /// The trickplay image for a start and the core's tile; `nil` without trickplay.
    let preview: (Double, PlayerPreview?) -> CGImage?
    let close: () -> Void

    var body: some View {
        let part = surface?.coreChapters
        ZStack(alignment: .top) {
            LayersReason()
            ColumnsRail(mass: mass) {
                SelectionColumn(title: LocalizedStringKey(part?.title ?? "Kapitel"), mass: mass, wide: true) {
                    ForEach(part?.rows ?? [], id: \.index) { row in
                        ChapterListRow(row: row, numberTitle: part?.numberTitle ?? "Kapitel %lld", mass: mass,
                                       image: preview(row.start, row.preview)) {
                            surface?.coreJump(toChapter: Int(row.index))
                            close()
                        }
                    }
                }
            }
            LayersHeader(mass: mass, close: close) { EmptyView() }
        }
        .ignoresSafeArea(edges: mass.topSkip)
        .accessibilityAction(.escape, close)
    }
}

/// The button around the shared row (`ChapterRowContent`): white on the layer's dark ground.
private struct ChapterListRow: View {
    let row: PlayerChapterRow
    let numberTitle: String
    let mass: PlayerMetric
    let image: CGImage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChapterRowContent(row: row, numberTitle: numberTitle, image: image, look: .phone(pad: mass.pad))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityAddTraits(row.current ? .isSelected : [])
    }
}
