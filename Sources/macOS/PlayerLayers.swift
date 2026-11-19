import JellyfinKit
import SwiftUI
import enum SwiftlyCore.PlayerMenuPanelTab
import struct SwiftlyCore.PlayerChapterRow
import struct SwiftlyCore.PlayerChapters
import struct SwiftlyCore.PlayerPreview

/// Player dimensions on the Mac, in one place, so that the close button of a layer
/// sits exactly where the player's close button sat.
///
/// The counterpart of `Playermass` on iOS (`Sources/iOS/PlayerLayers.swift`), but
/// with fixed values instead of `pad`/`inWindow`: a window has no diagonal and no
/// notch the margin would need to align with, so it is the same everywhere.
struct PlayerMetric {
    /// Right margin of the icon row and of the bar; the skip pill and the next-episode
    /// card share it (design: 28).
    let page: CGFloat = 28
    /// Left edge of the title block: the normal player margin. The title no longer makes room
    /// for the traffic lights beside it; it sits in the row below them.
    let titleLeft: CGFloat = 28
    /// Top inset of the icon row (design: 14); in windowed mode the traffic lights share this row.
    let top: CGFloat = 14
    /// The window is in full screen: no traffic lights, the title block moves up to the icon row.
    var fullScreen = false
    /// Top inset of the title block: below the traffic lights in a window, level with the icon
    /// row in full screen.
    /// **The same place in a window and in full screen**. macOS shows only
    /// a snapshot during its full-screen animation, so anything that moves with the mode
    /// appears to jump when the animation ends. Nothing moves now: in full screen the
    /// traffic-light row simply stays free.
    var titleTop: CGFloat { top + 30 }
    /// Line height of the 22 pt title; the icon row is centered on this first line.
    let titleLine: CGFloat = 27
    /// Top inset of the icon row (and of every header row): the 44 pt buttons are vertically
    /// centered on the title's first line, in a window and in full screen alike.
    var iconTop: CGFloat { titleTop - (button - titleLine) / 2 }
    /// Gap between the row top and the title text inside a header row.
    var titleInset: CGFloat { titleTop - iconTop }
    /// Height of the title block (22 pt title, 3 gap, one 13 pt meta line).
    let titleBlock: CGFloat = 46
    let bottom: CGFloat = 20
    /// Hit area of the icon buttons (design: 44 with a 22 pt glyph).
    let button: CGFloat = 44
    let symbol: CGFloat = 22
    /// Design: title 22/700, subtitle 13, time 13.
    let title: CGFloat = 22
    let meta: CGFloat = 13
    let time: CGFloat = 13
    /// Distance of the skip pill above the bar (bar 44 + 12 = pill bottom at 76).
    let overBar: CGFloat = 12
    /// Hit area of the seek bar; the track itself is 4 pt.
    let bar: CGFloat = 44
    /// Indent of the rows on the layers, so column title, selection row and delay
    /// share one text edge.
    static let inset: CGFloat = 10
}

/// The layers above the video, the same offer as on iOS.
enum PlayerLayer: Equatable {
    case tracks, settings
}

/// One of the plain icon buttons at the top right, in the player as on the layers.
///
/// Unlike iOS it shows a faint fill on hover and, when `key` is given, a tooltip in
/// the design's style ("Ton und Untertitel  T" on #303030) instead of the system one.
struct IconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let mass: PlayerMetric
    /// The keyboard shortcut shown in the tooltip, or `nil` for the system tooltip.
    var key: String?
    /// Draws a diagonal slash over the glyph (muted speaker), in the glyph's stroke.
    var slashed = false
    /// A part of the glass bar (design: halves 40 x 36, circles 36 x 36, symbol 18, hover white 6 %): `half` or `circle`.
    var bar: Bar?
    /// A menu hangs from it: white 18 %.
    var open = false
    /// The tooltip may show (off while the volume pill hangs under the speaker).
    var tip = true
    let action: () -> Void

    enum Bar { case half, circle }

    private var size: CGSize {
        switch bar {
        case .half?: CGSize(width: 40, height: 36)
        case .circle?: CGSize(width: 36, height: 36)
        case nil: CGSize(width: mass.button, height: mass.button)
        }
    }

    private var fill: Color {
        if bar == nil { return hovers ? Theme.hoverArea : .clear }
        return open ? Theme.ringProgress : (hovers ? Color.white.opacity(0.06) : .clear)
    }

    @State private var hovers = false
    @State private var tipShown = false

    var body: some View {
        Button(action: action) {
            Image(icon: symbol)
                .font(.app(size: bar == nil ? mass.symbol : 18, weight: .medium))
                .foregroundStyle(.white)
                .overlay {
                    if slashed {
                        Path { p in
                            p.move(to: CGPoint(x: 4, y: 3)); p.addLine(to: CGPoint(x: 18, y: 19))
                        }
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
                        .frame(width: 22, height: 22)
                    }
                }
                .frame(width: size.width, height: size.height)
                .background(fill, in: RoundedRectangle(cornerRadius: bar == nil ? Theme.cornerField : 18, style: .continuous))
                .animation(.easeOut(duration: 0.12), value: open)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .help(key == nil ? Text(label) : Text(verbatim: ""))
        .accessibilityLabel(Text(label))
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .overlay(alignment: .topTrailing) {
            if let key, tipShown, tip, !open {
                HStack(spacing: 8) {
                    Text(label)
                    if !key.isEmpty { Text(verbatim: key).foregroundStyle(Self.keyColor) }
                }
                .font(.app(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 9, y: 6)
                .offset(x: 4, y: size.height + (bar == nil ? 2 : 6))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
            }
        }
        .zIndex(tipShown ? 1 : 0)
        .task(id: hovers) {
            guard key != nil else { return }
            guard hovers else { tipShown = false; return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            tipShown = true
        }
    }

    /// The shortcut in the tooltip, #989898 in the design.
    private static let keyColor = Color(white: 0.596)
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
            left.padding(.top, mass.titleInset)
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", label: "Schließen", mass: mass, action: close)
        }
        .padding(.leading, mass.titleLeft)
        .padding(.trailing, mass.page)
        .padding(.top, mass.iconTop)
    }
}

// MARK: - Columns

/// A column with a fixed heading; only the rows below scroll, so with 50 or more
/// subtitles the other column stays still.
private struct SelectionColumn<ContentBody: View>: View {
    let title: LocalizedStringKey
    /// Short choices take `layerColumnWidth`; the track columns pass `trackColumnWidth`.
    var width: CGFloat = Theme.layerColumnWidth
    /// Off inside the episodes panel, where the "Kapitel" tab already names the list (as on tvOS and iPhone).
    var showsTitle = true
    @ViewBuilder let content: ContentBody

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column heading = sheet heading: 17 semibold with its tracking. 18 bold is in no
            // scale, and bold is used exactly once, for the page title.
            if showsTitle {
                Text(title)
                    .font(Theme.categoryLarge)
                    .tracking(Theme.lockCategory)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                    .padding(.horizontal, PlayerMetric.inset)
                    .padding(.bottom, 9)
                    .accessibilityAddTraits(.isHeader)
            }
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
                Image(icon: "checkmark")
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
            .padding(.top, mass.iconTop + mass.button + 6)
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
            Image(icon: symbol)
                .font(.app(size: mass.symbol - 3, weight: .semibold))
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
            Image(icon: "person.fill")
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

// MARK: - Speed and subtitle offset (rows from the core)

/// The "Geschwindigkeit" column: speeds, labels and the marked one come from the core's menu
/// (`PlayerVm.menu`); a press sends the speed back. Nothing is listed or formatted here.
private struct SpeedColumn: View {
    let area: VLCPlayerView?
    @State private var refresh = 0

    var body: some View {
        let _ = refresh
        if let menu = area?.playerMenu() {
            SelectionColumn(title: LocalizedStringKey(menu.speedTitle)) {
                ForEach(menu.speeds, id: \.value) { row in
                    LayersRow(text: row.label == "Normal" ? String(localized: "Normal") : row.label,
                              selected: row.selected) {
                        area?.tempo = row.value
                        refresh += 1
                    }
                }
            }
        }
    }
}

/// The "Untertitel-Versatz" rows: value, four steps and reset, all from the core's menu.
private struct SubtitleOffsetRows: View {
    let area: VLCPlayerView?
    @State private var refresh = 0

    var body: some View {
        let _ = refresh
        if let menu = area?.playerMenu() {
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
                            area?.offsetStep(step.stepMs)
                            refresh += 1
                        } label: {
                            Text(verbatim: step.label)
                                .font(Theme.listTitle.monospacedDigit())
                                .foregroundStyle(Theme.font)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    area?.offsetReset()
                    refresh += 1
                } label: {
                    Text(LocalizedStringKey(menu.resetLabel))
                        .font(Theme.listTitle)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, PlayerMetric.inset)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(menu.canReset ? 1 : 0.35)
                .disabled(!menu.canReset)
            }
            .accessibilityElement(children: .contain)
        }
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
                    SubtitleOffsetRows(area: area)
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
                        ForEach(Array(gemeinsam.participants.enumerated()), id: \.offset) { pair in
                            ParticipantRow(name: pair.element)
                        }
                        Button(action: groupLeave) {
                            HStack(spacing: 9) {
                                Image(icon: "rectangle.portrait.and.arrow.right")
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
                SpeedColumn(area: area)
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
