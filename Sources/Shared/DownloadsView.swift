import JellyfinKit
import SwiftUI

// MARK: - The ring

/// One glyph, six positions - the same everywhere.
///
/// In the row on the right, on the detail page in a field, in the episode list
/// at the edge. **State and action in one shape**, like the tile badge.
///
/// The accent exceptionally carries a surface here, but only for *finished*:
/// that is the one position that no longer offers an action but makes a
/// statement. The accent rule forbids the accent button surfaces, not marks.
///
/// **And it does not spin.** The loading ring has disappeared from the rest of
/// the app, replaced by placeholders in the shape of the content. Here a ring
/// stays, but it fills and carries a real number - the difference between
/// "I don't know how long" and "six minutes left".
struct DownloadRing: View {
    /// `nil` means: this title is not on the device.
    let entries: DownloadItem?
    /// The estimated state between two reports - the same value as the number and
    /// bar beside it. Without it, the reported one.
    var shareNow: Double? = nil
    /// **28 in a row, 22 in a field** - not two measures for the same thing but the
    /// same rule: the glyph grows with the thing it sits in. The row is 65 high,
    /// the action row's field 48; 28 to 65 and 22 to 48 are the same ratio.
    var mass: CGFloat = 28
    let onTap: () -> Void

    var body: some View {
        // **The hit area belongs inside the button, not around it.**
        //
        // `frame` and `contentShape` were **behind** the `Button` - on the shell, not on
        // its label. A button takes its area from what it draws, and what is drawn
        // here is **lines**: `Circle().strokeBorder` only hits on the stroke, the arc
        // likewise. Between them was nothing.
        //
        // In the no-download state it went unnoticed - an arrow sits in the middle,
        // and that is a surface. While loading there is an eight-point square, and
        // everything beside it hit nothing: the ring could be started but not stopped.
        Button(action: onTap) {
            symbolText
                .frame(width: max(mass, 44), height: max(mass, 44))
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(Text(announcement))
    }

    @ViewBuilder private var symbolText: some View {
        ZStack {
            switch entries?.state {
            case nil:
                Circle().strokeBorder(Theme.fontQuiet, lineWidth: 1.5)
                image("arrow.down", 13, Theme.font)
            case .waits:
                Circle().strokeBorder(Theme.fontVeryQuiet,
                                      style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
                image("pause.fill", 11, Theme.fontVeryQuiet)
            case .loads:
                arc(share: shareNow ?? entries?.share ?? 0, color: Theme.accent)
                // The square is a pause, not a cancel - a cross would mean discard, and
                // nothing is discarded here.
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: mass * 0.32, height: mass * 0.32)
            case .halted:
                arc(share: entries?.share ?? 0, color: Theme.fontQuiet)
                image("play.fill", 11, Theme.font)
            case .done:
                // **An arrow, not a check mark.**
                //
                // The check mark belongs to the question "have I seen this" - and in the episode
                // list it sits two centimetres further left. Two check marks next to each other
                // meaning different things are no information but a puzzle.
                //
                // Filled means finished here, as everywhere: the same shape as loading, just
                // full instead of hollow. It reads as "the download is complete", not "done".
                Circle().fill(Theme.accent)
                image("arrow.down", 13, Theme.reason)
            case .error:
                // `error`, not `warning`: an aborted download went wrong. The glyph stays so
                // it does not hang on colour alone.
                Circle().strokeBorder(Theme.error, lineWidth: 2)
                image("exclamationmark", 13, Theme.error)
            }
        }
        .frame(width: mass, height: mass)
        .animation(Theme.reveal, value: entries?.state)
    }

    private func arc(share: Double, color: Color) -> some View {
        ZStack {
            // **The same track as in `ProgressBar`** - and for a day it was not.
            //
            // This used `reason` at 0.78, with a note "same tone as in the progress bar so
            // ring and bar say the same". That very bar became light (white 30%) and this
            // spot was left behind: two progress indicators of the same app on **the same
            // screen** - the ring in the row, the bar below - one dark and one light. The
            // note kept claiming equality.
            //
            // The reason for the light track is at `ProgressBar`: the track is the
            // length of the whole, not the missing remainder.
            Circle().strokeBorder(Color.white.opacity(0.30), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, share))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(1)
                // **The arc grows, it does not jump.**
                //
                // Without its own curve every report sets the arc hard to the new value. On a
                // fast connection that is many small jumps in a row, and with round ends it
                // looks as if the ring trembles. Linear over a short half second it runs calmly
                // - and stays honest, since it never falls back.
                .animation(Theme.progressTravel, value: share)
        }
    }

    private func image(_ name: String, _ size: CGFloat, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
    }

    private var announcement: LocalizedStringKey {
        switch entries?.state {
        case nil:          "Laden"
        case .waits:      "Wartet"
        case .loads:       "Lädt, anhalten"
        case .halted:  "Angehalten, fortsetzen"
        case .done:      "Geladen, entfernen"
        case .error:      "Fehlgeschlagen, erneut versuchen"
        }
    }
}

/// What a tap on the ring does - the same in all three places.
///
/// Lives here and not three times in the views: the page, the episode list and
/// the action row ask the same question, so there is one answer.
@MainActor
func ringTap(_ entries: DownloadItem?, _ management: DownloadManager,
                 create: () -> Void) {
    switch entries?.state {
    case nil:          create()
    case .loads:       management.halt(entries!.id)
    case .halted,
         .error,
         .waits:      management.resume(entries!.id)
    case .done:      break   // Removing goes through the sheet, not a tap.
    }
}

/// The fifth field of the action row.
///
/// Called **`DownloadField`** and not `Ladefeld`: the latter has meant the
/// placeholder in the shape of content since the design pass, and two components
/// with the same name in one app are the start of someone picking the wrong one.
///
/// **Its own component instead of an `Aktionsknopf` with an overlay.** At first
/// the ring was an `.overlay` over the button with its own background beneath so
/// the glyph vanished - and that background was a rectangle over a surface with
/// 10 pt corners. The four corners would have been painted over square, and only
/// on this one field of the row. A field that can show two things shows them in
/// the same tree instead of laying one over the other.
///
/// Metrics and surface are literally those of ``Aktionsknopf`` - it sits in the
/// same row, and you must not see it.
struct DownloadField: View {
    @Environment(\.onImageTint) private var onImage
    let entries: DownloadItem?
    var stretches = true
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Group {
                if let p = entries, p.state != .done {
                    DownloadRing(entries: p, mass: 22) {}
                        .allowsHitTesting(false)
                } else {
                    // The same distinction as at the ring: filled means loaded, and it stays an
                    // arrow. The check mark beside it in the same row means "seen".
                    // 19 medium is in no scale; 17 semibold is the level below and the one that exists.
                    Image(systemName: entries == nil ? "arrow.down" : "arrow.down.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(entries == nil ? Theme.font : Theme.accent)
                }
            }
            .frame(maxWidth: stretches ? .infinity : nil)
            // **48 and 48, like the neighbour.**
            //
            // It was 56 wide and 44 high, with a border, while `Aktionsknopf` right next to
            // it is 48 square without one. Three differences in a row in which all fields
            // should do the same. The note here even named the coupling - "until it catches
            // up you see the difference" - but the neighbour caught up long ago and this
            // field stayed.
            .frame(width: stretches ? nil : 48, height: 48)
            .background(Theme.buttonArea(onImage: onImage),
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(Text("Laden"))
        .accessibilityAddTraits(entries == nil ? .isButton : [.isButton, .isSelected])
    }
}

// MARK: - One row

/// **Rows, not tiles.**
///
/// A download must show four things at once: what, how far, how big and what
/// you can press. A 104 x 156 poster fits one of them.
struct DownloadRow: View {
    let model: AppModel
    let entries: DownloadItem
    /// Set when the row stands for a whole series.
    var group: (title: String, episodes: [DownloadItem])?
    var edit = false
    @Binding var selected: Bool
    /// What a tap on a finished row does. `nil` for a group - it navigates on
    /// instead of starting.
    var start: (() -> Void)?

    private var management: DownloadManager { model.downloads }
    /// The entry with the running state. **Read only here**, so a progress report
    /// redraws this one row and not the list.
    private var now: DownloadItem { management.current(entries) }
    /// Keeps the estimator across redraws; it is not observed, the timeline asks
    /// it per frame.
    @State private var estimator = EstimatorHolder()

    /// **While loading, the row keeps counting per frame.**
    ///
    /// The manager reports at most once a second; in between
    /// `ProgressEstimator` extrapolates at the pace of the last seconds, as App
    /// Store and Music do. Number, bar and ring read **the same** value - before,
    /// the number jumped in steps and bar and ring ran ahead or behind depending on
    /// animation. 30 frames a second suffice for a bar; more only costs battery.
    ///
    /// **Only estimated while bytes really arrive.** Paused, waiting, failed or
    /// offline, the number is set at once - where it stood, not on the last report,
    /// which may lie beyond.
    var body: some View {
        Group {
            if comesWas {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { tick in
                    row(loaded: estimator.s.value(um: tick.date))
                }
            } else if entries.state == .halted || entries.state == .loads {
                row(loaded: max(estimator.s.value(um: Date()), now.loaded))
            } else {
                row(loaded: now.loaded)
            }
        }
        .onChange(of: now.loaded, initial: true) { _, new in
            estimator.s.report(new, total: now.bytes, um: Date())
            if !comesWas { estimator.s.halt() }
        }
        .onChange(of: comesWas) { _, an in
            if !an { estimator.s.halt() }
        }
    }

    private var comesWas: Bool {
        group == nil && entries.state == .loads && !management.noNetwork
    }

    private func share(_ loaded: Int64) -> Double? {
        now.bytes > 0 ? Double(loaded) / Double(now.bytes) : now.share
    }

    private func row(loaded: Int64) -> some View {
        HStack(spacing: 12) {
            if edit {
                // 21 was a one-off between the levels; 20 semibold is the row heading and
                // thus the next real one.
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? Theme.accent : Theme.fontVeryQuiet)
                    // **The circle comes in from the left and pushes the row ahead of it.** With
                    // `.opacity` it stood at full width at once, and the row only moved by what
                    // the fade left over. With reduced motion it stays a fade.
                    .transition(Theme.motionReduced
                                ? .opacity
                                : .move(edge: .leading).combined(with: .opacity))
            }

            NetworkImage(url: imageAddressValue, symbolText: landscape ? "tv" : "film")
                // 116 x 65 instead of 104 x 59: the same still as in the series page's
                // episode list. Two measures for the same role were the bug.
                .frame(width: landscape ? 116 : 64, height: landscape ? 65 : 96)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
                // **Watched as in the episode list** - also offline: the state is in the
                // entry. Only on the individual row; a series row stands for many episodes.
                .watchedCheckmark(group == nil && entries.watched)

            VStack(alignment: .leading, spacing: 3) {
                // A row carries semibold, not medium - medium belongs to the title under a
                // poster. The token keeps both together so they do not drift apart again.
                Text(verbatim: group?.title ?? entries.title)
                    .growing(15, .semibold)
                    .lineLimit(1)
                // 12.5 was a half step between two whole ones; the line under a title is
                // 12 regular.
                Text(verbatim: subline(loaded))
                    // **Tabular.** "1.4 GB - 42 min." stands in a list one under another, and the
                    // brand rules name runtimes and sizes explicitly: equal-width digits, otherwise
                    // the decimal separators wander from row to row.
                    .growing(12).monospacedDigit()
                    .foregroundStyle(underColor)
                    .lineLimit(1)
                if let share = share(loaded), entries.state == .loads || entries.state == .halted {
                    ProgressBar(share: share, round: true)
                        .padding(.top, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if group != nil {
                // 14 is in no scale - a chevron is 13 semibold.
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.fontVeryQuiet)
            } else if !edit {
                DownloadRing(entries: now, shareNow: share(loaded)) {
                    ringTap(entries, management) {}
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .animation(Theme.sheetMotion, value: edit)
        // **The gesture may only exist in selection mode.**
        //
        // It was fixed here with an `if edit` in the body - and an
        // `onTapGesture` swallows the tap even when its body does nothing. The series
        // row sits in a `NavigationLink`, which therefore never received it: a tap on a
        // series simply did nothing. Seen on the device, not in the build.
        // **A tap plays.** That was missing entirely: the row only carried selection in
        // edit mode. Play and not the detail page - that needs the server, and whoever
        // is here may have none.
        .modifier(SelectionTap(an: edit || start != nil) {
            if edit { selected.toggle() } else { start?() }
        })
    }

    /// **Disk first, then the server.** Offline there is only the disk, and that is
    /// exactly when this page is needed.
    ///
    /// A group row carries the series poster, an episode row its own landscape image
    /// - otherwise the episode list would show the same image three times.
    private var imageAddressValue: URL? {
        let hasGroup = group != nil
        return management.image(for: entries, asGroup: hasGroup)
            ?? model.posterURL(itemID: hasGroup ? (entries.seriesIdentifier ?? entries.id) : entries.id)
    }

    /// Portrait for movies and series, landscape for a single episode - the same
    /// distinction as in the series page's episode list.
    private var landscape: Bool { group == nil && entries.art == .episode }

    private func subline(_ loaded: Int64) -> String {
        if let g = group {
            let bytes = g.episodes.reduce(Int64(0)) { $0 + $1.bytes }
            return String(localized: "\(g.episodes.count) Folgen") + " · "
                + DownloadRules.size(bytes)
                + (DownloadQuality.gemeinsam(g.episodes).map { " · " + $0.name } ?? "")
        }
        var parts: [String] = []
        // Translated: German "F" for Folge, English "E" for Episode - it was fixed
        // as "F" here, also in English.
        if let s = entries.season, let f = entries.episode {
            parts.append(String(localized: "S\(s) F\(f)"))
        } else if let ticks = entries.runtimeTicks, ticks > 0 {
            parts.append(runtime(Double(ticks) / 10_000_000))
        }
        switch entries.state {
        case .loads:
            // **Fixed unit, fixed positions.** `size` switched mid-load from "845 MB"
            // to "1 GB" and "1.01 GB" - decimal separator in, decimal separator out, and
            // the row changed width at every step. Worst for the first episode starting
            // under a gigabyte. The total size dictates the unit.
            let f = DownloadRules.progress(loaded: loaded, from: now.bytes)
            // When converted the end is estimated - then "~" precedes it.
            parts = [String(localized: "\(f.loaded) von \((entries.streamed ? "≈ " : "") + f.total)")]
        case .waits:
            parts.append(String(localized: "wartet"))
            if entries.converted { parts.append(entries.guete.name) }
        case .halted:
            parts.append(String(localized: "angehalten"))
            if entries.converted { parts.append(entries.guete.name) }
        case .error:
            parts = [entries.reason ?? String(localized: "Fehlgeschlagen")]
        case .done:
            parts.append(DownloadRules.size(now.bytes))
            // **The chosen quality stands where the container otherwise stands** -
            // "720p" explains the small number before it, "MKV" does not.
            if entries.converted {
                parts.append(entries.guete.name)
            } else if let c = entries.container {
                parts.append(c.uppercased())
            }
            // **H9.** The file stays and stays playable; the hint sits quietly beside it,
            // not as an error.
            if !entries.stillOnTheServer {
                parts.append(String(localized: "nicht mehr auf dem Server"))
            }
        }
        return parts.joined(separator: " · ")
    }

    private var underColor: Color {
        switch entries.state {
        case .loads:  Theme.accent
        case .error: Theme.error
        // At rest the sub-line is a specification, not a description: previously
        // `schriftLeise`, which made it nearly as loud as the title above.
        default:      Theme.fontVeryQuiet
        }
    }
}

/// A tap gesture that only exists when needed.
///
/// Without this detour the gesture would have to be attached permanently and
/// check in the body - and then it swallows the tap anyway, since SwiftUI does
/// not look into the body when dispatching.
private struct SelectionTap: ViewModifier {
    let an: Bool
    let perform: () -> Void

    func body(content: Content) -> some View {
        // **Always a button, just without action when none is needed.** There was an
        // `if an` around the button: if Edit switched a loading row from "without" to
        // "with", it was a different view to SwiftUI - it cross-faded and slid in late
        // while the rest glided. An inner button (the ring) still gets its tap itself.
        //
        // **No grey surface.** `PressRow` put grey behind the row; here you only tap
        // to select or play. The content dims briefly - that suffices as the answer.
        Button { if an { perform() } } label: { content }
            .buttonStyle(Dim(an: an))
            .accessibilityRemoveTraits(an ? [] : .isButton)
    }

}

private struct Dim: ButtonStyle {
    var an = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(an && configuration.isPressed ? 0.6 : 1)
            .animation(Theme.pressCurve(configuration.isPressed),
                       value: configuration.isPressed)
    }
}

/// A shell so the estimator survives redraws without each estimate triggering
/// a new one.
private final class EstimatorHolder {
    var s = ProgressEstimator()
}

// MARK: - The page

struct DownloadsView: View {
    let model: AppModel

    @Environment(\.wide) private var wide
    @Environment(\.sectionActive) private var sectionActive
    @Environment(\.tabStillTimes) private var anotherTime
    @State private var offset: CGFloat = 0
    @State private var edit = false
    @State private var selected: Set<String> = []
    @State private var deleteSheet = false
    @State private var openSeries: DownloadSeriesRoute?

    private var management: DownloadManager { model.downloads }

    private var ongoing: [DownloadItem] {
        management.entries.filter { $0.state != .done }
    }
    private var finished: [DownloadGroup] {
        DownloadRules.grouped(management.entries.filter { $0.state == .done })
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()

            ScrollView {
                // **Lazy, like every other list.** Every row carries an image from disk; with a
                // large offline library opening the page built them all at once instead of
                // when becoming visible.
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !ongoing.isEmpty {
                        // **The margin is subtracted back, not added.**
                        //
                        // `Gruppentitel` brings `edgeSpacing` itself, and the `VStack` below puts
                        // `rand(wide:)` around it once more: the heading sat visibly 18 pt further in
                        // than its own list. `Einstellungsgruppe` already does it this way, character
                        // for character.
                        GroupsTitle(text: management.noNetwork ? "Wartet auf Netz" : "Lädt gerade")
                            .padding(.horizontal, Theme.margin(wide: wide) - Theme.edgeSpacing)
                            .padding(.top, 4)
                        // **What is running can be removed too.**
                        //
                        // These rows got `selected: .constant(false)` and no `edit` - so they
                        // could not be ticked at all. Someone who started a download by accident had
                        // to wait until it finished to get rid of it. `remove` cancels the task
                        // anyway; only the path there was missing.
                        ForEach(ongoing) { p in
                            DownloadRow(model: model, entries: p,
                                          edit: edit,
                                          selected: binding(for: [p.id]))
                            // No separator line: the row carries an image, and that separates already.
                            // See the brand rules, "The row with image".
                        }
                    }

                    if !finished.isEmpty {
                        // **No heading above the downloaded items.** It used to say "On device" - on
                        // the downloads page everything is on the device, so the sentence said nothing.
                        // The spacing to "Loading now" above stays.
                        Color.clear.frame(height: ongoing.isEmpty ? 4 : 26)
                        ForEach(finished) { g in
                            rowFor(g)

                        }
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.bottom, 24)
                // **Full width, like every other page.**
                //
                // A limit of 900 pt stood here, reasoning that a row of image, title and ring
                // has nothing to say in the middle. True in itself - but separators and rings
                // then ended about three hundred points before the edge while title and bar in
                // the header above ran to the right. Two edges on one page, and the page looked
                // cut off.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .toTop(anotherTime: anotherTime, active: sectionActive)
            .contentMargins(.bottom, edit ? 84 : 24, for: .scrollContent)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y + $0.contentInsets.top
            } action: { _, new in offset = new }
            .animation(Theme.reveal, value: management.entries.count)
            // **Only the scroll area draws in on the switch.**
            // The look's glow, the same on every main page; goes up with the content.
            .lookGlow()
            .areaContent()
            // **And the header after it, not before.**
            //
            // Modifiers wrap from inside out: what comes before `areaContent` is inside
            // it and moves along. The header came before, so it pushed in when the
            // downloads page opened. On Movies and Series it has been behind since the
            // change, which is why it is fixed there.
            //
            // It sits as a safe-area inset instead of an overlay; the reasoning is in
            // `MainView`.
            .safeAreaInset(edge: .top, spacing: 0) { header }


            if management.entries.isEmpty {
                // **No "What can I download" button.** Netflix has one because not everything
                // is downloadable there. Here everything is - the button only led back to the
                // library. The sentence says **where** to start instead.
                EmptyState(symbol: "arrow.down.circle",
                            headerLine: "Noch nichts geladen",
                            text: "Lad was runter, bevor der Zug ins Funkloch fährt.")
                    // **Account for the nav bar**, as on the library page: the block sits in the
                    // middle of the whole window, and narrow the lower 54 points of it lie under
                    // the bar.
                    .padding(.bottom, wide ? 0 : Theme.stripHeight)
                    // The when to the how from `Leerzustand`.
                    .animation(Theme.reveal, value: management.entries.isEmpty)
                    // Draws in with the area change, like the scroll area below - without its own
                    // background, otherwise it would cover the header.
                    .sectionWithPull()
            }
        }
        .safeAreaInset(edge: .bottom) { if edit { deleteBar } }
        .navigationDestination(item: $openSeries) { route in
            DownloadSeriesView(model: model, route: route)
        }
        #if os(iOS)
        .playerCover(item: $play) { wish in
            PlayerScreen(model: model, item: wish.item,
                         plan: wish.plan, startAt: wish.startAt)
        }
        #endif
        .sectionBar()
        // **After the bar, not before.** Overlays lie in the order they are attached;
        // attached before, the area bar cut the sheet's lower edge off. The same order
        // is used in the other root views.
        .overlay(alignment: .topTrailing) {
            ActionSheet(opened: $deleteSheet, title: deleteTitle, actions: [
                TitleAction(symbol: "trash", text: "Entfernen", cautionary: true) {
                    management.remove(Array(selected))
                    selected = []
                    withAnimation(Theme.reveal) { edit = false }
                }
            ])
        }
    }

    @ViewBuilder
    private func rowFor(_ g: DownloadGroup) -> some View {
        switch g {
        case let .single(p):
            DownloadRow(model: model, entries: p, edit: edit,
                          selected: binding(for: [p.id]),
                          start: p.state == .done ? { playItem(p) } : nil)
        case let .series(id, title, episodes):
            // **One row in both modes, no swap.** There used to be a `NavigationLink`
            // outside and a second row in edit mode - two different views to SwiftUI, so
            // the series row cross-faded on switching instead of gliding. Now the same row;
            // the way to the series goes via `openSeries`.
            DownloadRow(model: model, entries: episodes[0],
                          group: (title, episodes), edit: edit,
                          selected: binding(for: episodes.map(\.id)),
                          start: { openSeries = DownloadSeriesRoute(seriesIdentifier: id, title: title) })
        }
    }

    /// A series is selected as a whole - half-selected groups would only exist to
    /// be explained away again.
    private func binding(for ids: [String]) -> Binding<Bool> {
        Binding(
            get: { !ids.isEmpty && ids.allSatisfy { selected.contains($0) } },
            set: { an in
                if an { selected.formUnion(ids) } else { selected.subtract(ids) }
            })
    }

    @State private var play: PlayRequest?

    /// **Without server.** `model.plan` takes the file from disk if there is one
    ///, and the entry builds the `Item` for it itself - on a plane there is no
    /// one who could supply one.
    private func playItem(_ p: DownloadItem) {
        Task {
            guard let plan = await model.plan(for: p.id) else { return }
            // At the remembered position - the same with and without network.
            play = PlayRequest(item: p.asItem, plan: plan,
                                      startAt: model.downloads.entries(for: p.id)?.resumeFrom ?? 0)
        }
    }

    private var deleteTitle: String { DeleteBar.title(selected, in: management) }

    // MARK: Header

    private var header: some View {
        BlurHeader(offset: offset) {
            VStack(alignment: .leading, spacing: 12) {
                // Centered, not top - see MainView: without the line under the title `.top`
                // is off.
                HStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Downloads").font(Theme.titleLarge).tracking(Theme.lockTitle)
                        // **No line under the title.**
                        //
                        // It used to show usage - title count, size, free space. The same information
                        // is at the storage bar further down, and a page title with a sub-line looks
                        // different from every other root page. Offline, the empty state or the status
                        // line on the row itself says so.
                    }
                    Spacer(minLength: 0)
                    // **Edit exists wide and narrow.**
                    //
                    // Narrow it sits in the glyph group at the top right - where the home page has
                    // the "continue watching here" offer, left of the Watchlist/Profile pair. Wide,
                    // that group does not exist, it lives in the sidebar; then it stands alone.
                    // Showing it only narrow would mean nothing can be removed on iPad.
                    if wide {
                        editButton
                    } else {
                        HeaderTargets(name: model.session?.userName ?? "?",
                                  image: model.userImageURL()) { editButton }
                    }
                }
                .foregroundStyle(Theme.font)

                if !management.entries.isEmpty { cacheBar }
            }
        }
    }

    @ViewBuilder
    private var editButton: some View {
        if !management.entries.isEmpty {
            EditButton(edit: $edit, selected: $selected)
        }
    }


    /// **Instead of an upper limit.** The no-limit rule: a limit you did not set yourself annoys
    /// exactly when you need it. A bar says the same without forbidding anything.
    private var cacheBar: some View {
        let our = Double(DownloadRules.allocation(management.entries).bytes)
        let free = Double(max(management.free, 0))
        let whole = max(our + free, 1)
        return GeometryReader { r in
            HStack(spacing: 0) {
                Theme.accent.frame(width: r.size.width * our / whole)
                // The free part was white 0.22 - a raw value and a second tone next to the
                // accent. `erhoeht` is the surface that exists for this, and it lies the right
                // way round: lighter than the background, quieter than the own share.
                Theme.raised.frame(width: r.size.width * free / whole)
                Color.clear
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    /// **Above the area bar, not below.**
    ///
    /// `sectionBar()` lays the bar over the page as an overlay; a `safeAreaInset`
    /// sits in the content and thus below it. Without the spacing only a white strip
    /// of the button stuck out above the bar - seen on the device, not noticeable in
    /// the build.
    ///
    /// The bar stays and is not hidden: someone cleaning up who wants to switch area
    /// should be able to without leaving selection mode first.
    private var deleteBar: some View {
        DeleteBar(title: deleteTitle, active: !selected.isEmpty) { deleteSheet = true }
    }
}

/// Pencil and cross at the top right - the same button on the download list
/// and on the page of a downloaded series.
struct EditButton: View {
    @Binding var edit: Bool
    @Binding var selected: Set<String>

    var body: some View {
        Button {
            // The same curve as the sheets: the rows glide.
            withAnimation(Theme.sheetMotion) {
                edit.toggle()
                if !edit { selected = [] }
            }
        } label: {
            // 18 medium was the third size for the same glyph on this page; 17 semibold
            // is the scale's level.
            Image(systemName: edit ? "xmark" : "pencil")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(edit ? Theme.accent : Theme.font)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        // In edit mode the button shows a cross and ends it - then it should be called
        // that.
        .accessibilityLabel(edit ? Text("Fertig") : Text("Bearbeiten"))
    }
}

/// **Above the area bar, not below** - see `DownloadsView`.
struct DeleteBar: View {
    @Environment(\.wide) private var wide
    let title: String
    let active: Bool
    let perform: () -> Void

    var body: some View {
        Button(action: perform) { Text(verbatim: title) }
            .buttonStyle(PrimaryButtonStyle(stretches: true))
            .disabled(!active)
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.bottom, wide ? 8 : Theme.stripHeight + 8)
            .background(Theme.reason.ignoresSafeArea())
    }

    /// „3 entfernen · 7,42 GB".
    static func title(_ selected: Set<String>, in management: DownloadManager) -> String {
        let bytes = management.entries.filter { selected.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.bytes }
        return String(localized: "\(selected.count) entfernen")
            + " · " + DownloadRules.size(bytes)
    }
}

// MARK: - The episodes of a downloaded series

struct DownloadSeriesRoute: Hashable {
    let seriesIdentifier: String
    let title: String
}

/// **The series on the device, as a detail page.**
///
/// This was a bare list under series name and "N episodes - X GB". Wanted:
/// what the rest of the app has: the large image on top, the name, a play
/// button, below the episodes by season. Built from the series page's
/// components (`Heldbild`, `HeroRunOut`, `PrimaryButtonStyle`, `DetailHeaderReader`)
/// - no own design.
///
/// **Everything from disk.** Whoever is here may have no network: the image is
/// the saved landscape image of the next episode, otherwise the series poster,
/// and only then a server URL. The button plays the file via `model.plan`, which
/// takes disk first.
struct DownloadSeriesView: View {
    let model: AppModel
    let route: DownloadSeriesRoute

    @Environment(\.dismiss) private var close
    @Environment(\.wide) private var wide
    /// See `SeriesDetailView.distance` - as an `@State` number every scroll step
    /// rebuilt the page.
    @State private var distance = ScrollDistance()
    @State private var play: PlayRequest?
    @State private var edit = false
    @State private var selected: Set<String> = []
    @State private var deleteSheet = false
    @Environment(\.displayScale) private var pixelMetric
    @State private var pagesWidth: CGFloat = 0
    /// The header image fetched later, once it is available.
    @State private var caughtUp: URL?

    private func playItem(_ p: DownloadItem) {
        Task {
            guard let plan = await model.plan(for: p.id) else { return }
            // At the remembered position - the same with and without network.
            play = PlayRequest(item: p.asItem, plan: plan,
                                      startAt: model.downloads.entries(for: p.id)?.resumeFrom ?? 0)
        }
    }

    private var episodes: [DownloadItem] {
        model.downloads.entries
            .filter { $0.seriesIdentifier == route.seriesIdentifier }
            // Episodes without a season number at the end: they form their own group and
            // would otherwise sort between season 0 and 1.
            .sorted { ($0.season ?? .max, $0.episode ?? .max) < ($1.season ?? .max, $1.episode ?? .max) }
    }

    /// By season, in the order of the seasons.
    private var seasons: [(number: Int?, episodes: [DownloadItem])] {
        var rail: [Int?] = []
        var je: [Int?: [DownloadItem]] = [:]
        for p in episodes {
            if je[p.season] == nil { rail.append(p.season) }
            je[p.season, default: []].append(p)
        }
        return rail.map { ($0, je[$0] ?? []) }
    }

    private var next: DownloadItem? { DownloadRules.nextEpisode(from: episodes) }

    /// **First the series' large header image** - it loads with the first download
    /// at screen resolution. Before, this showed the episode's landscape image (220
    /// high) or the poster (300 high), both measured for rows and visibly soft in
    /// the header.
    private var headerImage: URL? {
        guard let p = next ?? episodes.first else { return nil }
        if let large = caughtUp ?? model.downloads.headerImage(series: route.seriesIdentifier, account: p.account) {
            return large
        }
        return model.downloads.image(for: p)
            ?? model.downloads.image(for: p, asGroup: true)
            ?? model.posterURL(itemID: p.seriesIdentifier ?? p.id)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.reason.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // **Wide, the same header as on the series page** - `HeroHeader` with poster next
                    // to name and button. A 300 pt strip across the whole iPad width is no hero
                    // image anymore; the reasoning is there.
                    if wide {
                        HeroHeader(image: headerImage, poster: poster,
                                 title: route.title, secondaryLine: detail) {
                            primaryButton
                        }
                        Color.clear.frame(height: 22)
                    } else {
                    HeroImage(url: headerImage)
                        .overlay(alignment: .bottom) { HeroRunOut() }
                        .overlay(alignment: .bottomLeading) { titleBlock }

                    primaryButton
                        .padding(.horizontal, Theme.margin(wide: wide))
                        .padding(.top, 14)
                        .padding(.bottom, 22)
                    }

                    ForEach(seasons, id: \.number) { season in
                        if let n = season.number {
                            GroupsTitle(text: "Staffel \(n)")
                                .padding(.horizontal, Theme.margin(wide: wide) - Theme.edgeSpacing)
                                .padding(.top, 6)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(season.episodes) { p in episodeRow(p) }
                        }
                        .padding(.bottom, 16)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named("blatt"))
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
                distance.setDown(new)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pagesWidth = $0 }
            .ignoresSafeArea(edges: .top)

            DetailHeaderReader(title: route.title, distance: distance, back: { close() }) {
                EditButton(edit: $edit, selected: $selected)
            }
        }
        .task(id: pagesWidth > 0) { await headerImageCatchUp() }
        .safeAreaInset(edge: .bottom) {
            if edit {
                DeleteBar(title: DeleteBar.title(selected, in: model.downloads),
                             active: !selected.isEmpty) { deleteSheet = true }
            }
        }
        .overlay(alignment: .topTrailing) {
            ActionSheet(opened: $deleteSheet,
                           title: DeleteBar.title(selected, in: model.downloads),
                           actions: [
                TitleAction(symbol: "trash", text: "Entfernen", cautionary: true) {
                    remove(Array(selected))
                    selected = []
                    withAnimation(Theme.sheetMotion) { edit = false }
                }
            ])
        }
        // **Last episode gone, page gone.** A series page without episodes has nothing
        // left to show; back to the list.
        .onChange(of: episodes.isEmpty) { _, empty in if empty { close() } }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        .playerCover(item: $play) { wish in
            PlayerScreen(model: model, item: wish.item,
                         plan: wish.plan, startAt: wish.startAt)
        }
        #endif
    }

    /// **Three ways to remove, as usual in iOS.** The ring on each episode did not
    /// work as a delete path - it is none, it pauses and resumes. Now: swipe left,
    /// long press, or Edit at the top with selection circles and the button below,
    /// like in the list.
    ///
    /// The swipe row runs the full width so the red goes to the edge; the row itself
    /// carries the side margin. Tapping happens in the row (`start`, in edit mode
    /// the selection) - the swipe row itself does nothing on tap.
    private func episodeRow(_ p: DownloadItem) -> some View {
        SwipeRow(symbol: "trash", label: "Entfernen", color: Theme.error,
                   action: { remove([p.id]) }, onTap: {}) {
            DownloadRow(model: model, entries: p, edit: edit,
                          selected: Binding(
                            get: { selected.contains(p.id) },
                            set: { an in if an { selected.insert(p.id) } else { selected.remove(p.id) } }),
                          start: p.state == .done ? { playItem(p) } : nil)
                .padding(.horizontal, Theme.margin(wide: wide))
        }
        .contextMenu {
            Button(role: .destructive) { Theme.jerk(.medium); remove([p.id]) } label: {
                Label("Download entfernen", systemImage: "trash")
            }
        }
    }

    private func remove(_ ids: [String]) {
        withAnimation(Theme.reveal) { model.downloads.remove(ids) }
    }

    /// **Earlier downloads have no large header image** - with network it is
    /// fetched once here. Offline the request fails silently, and the image from
    /// disk stays.
    private func headerImageCatchUp() async {
        guard pagesWidth > 0, let p = episodes.first,
              model.downloads.headerImage(series: route.seriesIdentifier, account: p.account) == nil,
              let series = await model.item(id: route.seriesIdentifier) else { return }
        // Wide, the header is at least `heroHeightWide` high.
        let points = max(pagesWidth, (wide ? Theme.heroHeightWide : Theme.heroHeightValue) * 16 / 9)
        guard let address = model.headerImageURL(for: series,
                                              width: Int((points * pixelMetric).rounded(.up)))
        else { return }
        caughtUp = await model.downloads.headerImageCatchUp(series: route.seriesIdentifier,
                                                             account: p.account, from: address)
    }

    /// „12 Folgen · 18,4 GB".
    private var detail: String {
        String(localized: "\(episodes.count) Folgen") + " · "
            + DownloadRules.size(episodes.reduce(0) { $0 + $1.bytes })
    }

    /// The series poster from disk - for the wide header.
    private var poster: URL? {
        guard let p = episodes.first else { return nil }
        return model.downloads.image(for: p, asGroup: true)
            ?? model.posterURL(itemID: p.seriesIdentifier ?? p.id)
    }

    /// Name and details at the bottom of the image - like on the series page.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: route.title)
                .font(Theme.title)
                .tracking(Theme.lockTitle)
                .foregroundStyle(Theme.font)
            Text(verbatim: detail)
                .growing(12)
                .monospacedDigit()
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.bottom, 16)
    }

    /// **The next unwatched episode**, otherwise from the start - the rule is in
    /// `DownloadRules.nextEpisode`. Labeled as on the series page ("Play S2 the one-main-button rule").
    private var primaryButton: some View {
        Button {
            if let next { playItem(next) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill").font(.system(size: 15))
                    .accessibilityHidden(true)
                Text(verbatim: Item.seriesButton(episode: next?.asItem, loads: false))
            }
        }
        .buttonStyle(PrimaryButtonStyle(stretches: !wide))
        .disabled(next == nil)
    }
}
