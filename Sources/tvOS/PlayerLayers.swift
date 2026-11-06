import JellyfinKit
import SwiftUI

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

/// The three layers over the picture.
enum PlayerLayer: Equatable {
    case tracks, episodes, settings
}

/// Shoot path for screenshots without a working stream. DEBUG only; in release every flag is `false`.
///
///     -zeige player -ohneBild [-ebene]
///
/// `-ohneBild` shows the control layer as if playing (see `PlayerScreen`); `-ebene` opens the audio and subtitle layer with focus on the subtitle "Deutsch".
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

    /// Mock tracks for the layer when no player exists. `id` doubles as the focus id.
    struct Track: Identifiable {
        let id: String
        let text: String
    }
    static let audio = [Track(id: "a1", text: "Deutsch · AC3 5.1"), Track(id: "a2", text: "English · E-AC3 5.1"),
                        Track(id: "a3", text: "Audiodeskription")]
    static let subtitles = [Track(id: "s1", text: "Deutsch"), Track(id: "s2", text: "Deutsch (erzwungen)"),
                            Track(id: "s3", text: "English · SDH")]
    static let subtitleDelay = Delay(milliseconds: 500)
}

/// Glyph box of the icon buttons. The same view draws the real button and the decorative copy over a layer.
struct IconGlyph: View {
    let symbol: String
    /// Lit like focus: white surface, dark glyph, magnified, lifted.
    let lit: Bool

    var body: some View {
        Image(icon: symbol, size: PlayerMetric.symbol)
            .font(.app(size: PlayerMetric.symbol, weight: .medium))
            .foregroundStyle(lit ? Theme.reason : Theme.font)
            .frame(width: PlayerMetric.button, height: PlayerMetric.button)
            .background {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(lit ? Color.white : .clear)
                    .lift(lit)
            }
            .scaleEffect(lit ? Theme.focusMagnifierSmall : 1)
            .animation(Theme.focusAnimation, value: lit)
    }
}

/// One of the icon buttons at top right. At rest only the glyph, focused the
/// white fill of `ThemedButtonStyle`. `active` lights it like focus while its layer is open.
struct IconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.clear
        }
        .buttonStyle(IconButtonStyle(symbol: symbol, active: active))
        .accessibilityLabel(Text(label))
    }
}

/// No fill at rest: the glyph floats over the picture. Focus = white rounded square, x1.1, lifted (design `iconBtn`).
private struct IconButtonStyle: ButtonStyle {
    let symbol: String
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration, symbol: symbol, active: active)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        let symbol: String
        let active: Bool
        @Environment(\.isFocused) private var focus

        var body: some View {
            IconGlyph(symbol: symbol, lit: focus || active)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
        }
    }
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
    @ViewBuilder let content: ContentBody
    /// Room around the rows so a magnified, lifted focus row is not clipped by the scroll view.
    private let bleed: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                // 36 / 700 / -0.6 at the heading step of the layers (design `.t-group` at 36).
                .font(.app(size: PlayerMetric.heading, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .frame(height: PlayerMetric.heading * 1.15)
                .padding(.bottom, PlayerMetric.headingGap)
                .accessibilityAddTraits(.isHeader)
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

/// Check mark and name. Selected is white and semibold, otherwise #CCC medium; focus is a white row with dark semibold text.
private struct LayersRow: View {
    let text: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RowsText(text: text, selected: selected)
        }
        .buttonStyle(LayersRowStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Separate view so it can read the button's focus.
    private struct RowsText: View {
        let text: String
        let selected: Bool
        @Environment(\.isFocused) private var focus

        var body: some View {
            HStack(spacing: 20) {
                Image(icon: "checkmark", size: 30)
                    .font(.app(size: 30, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 32)
                    // The check mark is only an image; VoiceOver reads the selection from the button (`.isSelected`).
                    .accessibilityHidden(true)
                // Track names come from the file; use them verbatim.
                Marquee(text: text, running: focus)
            }
            .font(.app(size: 30, weight: selected || focus ? .semibold : .medium))
            .foregroundStyle(focus ? Theme.reason : (selected ? Theme.font : Theme.fontQuiet))
            .padding(.horizontal, PlayerMetric.inset)
            .frame(height: PlayerMetric.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// **A name that does not fit runs through once while focused**, like the system's
/// focused labels: a pause to start reading, the text slides to its end, holds, then
/// jumps back and starts over. Unfocused or fitting, it is a plain truncated line.
private struct Marquee: View {
    let text: String
    let running: Bool
    @State private var box: CGFloat = 0
    @State private var full: CGFloat = 0
    @State private var shift: CGFloat = 0

    private var overflow: CGFloat { max(0, full - box) }

    var body: some View {
        Text(verbatim: text)
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { full = $0 }
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if running && overflow > 0 && !Theme.motionReduced {
                    Text(verbatim: text)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: -shift)
                } else {
                    Text(verbatim: text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { box = $0 }
            .task(id: running && overflow > 0) { await run() }
    }

    private func run() async {
        shift = 0
        guard running, overflow > 0, !Theme.motionReduced else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.2))
            let travel = overflow
            // A steady reading pace, whatever the length.
            let time = Double(travel / 110)
            withAnimation(.linear(duration: time)) { shift = travel }
            try? await Task.sleep(for: .seconds(time + 1.5))
            guard !Task.isCancelled else { break }
            shift = 0
        }
        shift = 0
    }
}

/// A name in the "together" column: information, not a button.
private struct ParticipantRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 22) {
            Image(icon: "person.fill")
                .font(.app(size: 26))
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
        .frame(height: PlayerMetric.rowHeight)
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

/// Columns side by side from the left margin (80 pt) at 212 pt from the top. They end at the bottom edge; overflow scrolls inside its column.
private struct ColumnsRail<ContentBody: View>: View {
    var count = 2
    @ViewBuilder let content: ContentBody

    var body: some View {
        HStack(alignment: .top, spacing: PlayerMetric.columnGap(count: count)) { content }
            .environment(\.columnsWidth, PlayerMetric.columnsWidth(count: count))
            .padding(.leading, Theme.edgePage)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, PlayerMetric.columnsTop)
    }
}

/// Delay: last row of the audio and subtitle columns. Counterpart of `Verzoegerungszeile` on iOS (rationale there).
/// On TV it has three focus targets (-, +, reset) instead of one row catching
/// left/right, because left/right switch the column here. Holding repeats,
/// faster via `Delay.Haltezaehler`.
/// Design shows one decimal ("0,0 s", "+0,5 s"); the step logic stays 50 ms.
private func delayLabel(_ delay: Delay) -> String {
    let tenths = (Double(delay.milliseconds) / 100).rounded(.toNearestOrAwayFromZero)
    let sign = tenths > 0 ? "+" : (tenths < 0 ? "\u{2212}" : "")
    return "\(sign)\(String(format: "%.1f", abs(tenths) / 10).replacingOccurrences(of: ".", with: ",")) s"
}

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
            // Four items, equal gaps (design: space-between): minus, value, plus, reset. The hidden reset keeps its place.
            HStack(spacing: 0) {
                keyButton("minus", "-", locked: value.atStart) {
                    setDown(value.shifted(-1, steps: hold.press()))
                }
                .accessibilityLabel(Text("Früher"))
                Spacer(minLength: 0)
                Text(verbatim: delayLabel(value))
                    .font(Font.app(size: 26, weight: .medium).monospacedDigit())
                    .foregroundStyle(value.isNull ? Theme.fontQuiet : Theme.font)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                keyButton("plus", "+", locked: value.atEnd) {
                    setDown(value.shifted(1, steps: hold.press()))
                }
                .accessibilityLabel(Text("Später"))
                Spacer(minLength: 0)
                // The reset button disappears afterwards; focus goes to + instead of jumping elsewhere.
                keyButton("arrow.counterclockwise", "0", locked: false, redo: false) {
                    setDown(.null)
                    focus.wrappedValue = identifier + "+"
                }
                .accessibilityLabel(Text("Zurücksetzen"))
                .opacity(value.isNull ? 0 : 1)
                .disabled(value.isNull)
            }
            .accessibilityValue(Text(verbatim: delayLabel(value)))
        }
    }

    private func keyButton(_ symbol: String, _ suffix: String, locked: Bool, redo: Bool = true,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Color.clear
        }
        .buttonStyle(IconButtonStyle(symbol: symbol))
        .opacity(locked ? 0.4 : 1)
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

    /// Without a player the shoot path (`-ohneBild`) shows mock tracks; otherwise this is always `false`.
    private var mock: Bool { area == nil && PlayerShoot.withoutImage }

    var body: some View {
        ZStack(alignment: .top) {
            LayersReason()
            ColumnsRail {
                SelectionColumn(title: "Audio") {
                    if mock {
                        ForEach(PlayerShoot.audio) { track in
                            LayersRow(text: track.text, selected: audioNow == track.id) {
                                audioSelection = track.id
                            }
                            .focused($focus, equals: "t" + track.id)
                        }
                    } else {
                        ForEach(area?.audioTracks ?? [], id: \.trackId) { track in
                            LayersRow(text: area?.audioLabel(track) ?? track.prettyName, selected: audioNow == track.trackId) {
                                audioSelection = track.trackId
                                area?.selectAudioTrack(track)
                            }
                            .focused($focus, equals: "t" + track.trackId)
                        }
                    }
                    DelayRow(value: audioLag ?? area?.audioDelay ?? .null,
                                       identifier: "vt", focus: $focus) { new in
                        audioLag = new
                        area?.audioDelay = new
                    }
                    .padding(.top, PlayerMetric.delayTop)
                }
                SelectionColumn(title: "Untertitel") {
                    LayersRow(text: String(localized: "Aus"), selected: subtitleNow == nil) {
                        subtitleSelection = .some(nil)
                        area?.selectSubtitle(nil)
                    }
                    .focused($focus, equals: "u")
                    if mock {
                        ForEach(PlayerShoot.subtitles) { track in
                            LayersRow(text: track.text, selected: subtitleNow == track.id) {
                                subtitleSelection = .some(track.id)
                            }
                            .focused($focus, equals: "u" + track.id)
                        }
                    } else {
                        let names = area?.subtitleNames() ?? [:]
                        ForEach(area?.subtitleTracks ?? [], id: \.trackId) { track in
                            LayersRow(text: names[track.trackId] ?? track.trackName,
                                        selected: subtitleNow == track.trackId) {
                                subtitleSelection = .some(track.trackId)
                                area?.selectSubtitle(track)
                            }
                            .focused($focus, equals: "u" + track.trackId)
                        }
                    }
                    DelayRow(value: subtitleLag ?? area?.subtitleDelay ?? (mock ? PlayerShoot.subtitleDelay : .null),
                                       identifier: "vu", focus: $focus) { new in
                        subtitleLag = new
                        area?.subtitleDelay = new
                    }
                    .padding(.top, PlayerMetric.delayTop)
                }
            }
        }
        .focusSection()
        // Starts on the selected audio track; the shoot path `-ebene` starts on the subtitle "Deutsch".
        .task { await LayersFocus.put { focus = focus ?? startTarget } }
    }

    private var startTarget: String {
        if PlayerShoot.layer { return "us1" }
        if let audio = audioNow { return "t" + audio }
        return "u" + (subtitleNow ?? "")
    }

    /// By `trackId`, not name: two tracks called "Deutsch" would both show the check mark.
    private var subtitleNow: String? {
        if let subtitleSelection { return subtitleSelection }
        return mock ? nil : area?.selectedSubtitle?.trackId
    }

    private var audioNow: String? {
        audioSelection ?? (mock ? "a1" : area?.selectedAudioTrack?.trackId)
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
                                Image(icon: "rectangle.portrait.and.arrow.right")
                                    .font(.app(size: 28, weight: .semibold))
                                    .frame(width: 42)
                                Text("Gruppe verlassen")
                                Spacer(minLength: 0)
                            }
                            .font(Theme.listTitle)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, PlayerMetric.inset)
                            .frame(height: PlayerMetric.rowHeight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(LayersRowStyle())
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
                        .tracking(PlayerMetric.titleTracking)
                        .lineLimit(1)
                        .frame(height: PlayerMetric.titleLine)
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
