import JellyfinKit
import SwiftUI

// **The Mac version of Downloads.**
//
// Same behavior as on iPhone, except for three things, all caused by input
// method and window size:
//
// 1. **The confirmation is a popover at the button, not a sheet from below.**
//    With a pointer, anything tied to a button appears next to it. Same rule
//    as `Handlungsliste`.
// 2. **The tab is a row in the sidebar**, since there is no bottom bar here.
// 3. **The ring is drawn larger**, like all icons in this version.
//
// The rules themselves (who loads next, whether there is enough space, what
// can be dropped) live in `DownloadRules` in the package, not here.

/// One icon, six states. Same meanings as the iPhone version.
struct DownloadRing: View {
    let entries: DownloadItem?
    /// Estimated progress between two reports, the same value as the number and
    /// bar next to it. Without it, the reported value is used.
    var shareNow: Double? = nil
    var mass: CGFloat = 26
    let onTap: () -> Void

    @State private var hovers = false

    var body: some View {
        // Same trap as on iPhone: `frame` and `contentShape` were applied **after**
        // the button, so they sized its wrapper. A button takes its hit area from what
        // it draws, and here that is thin lines. Only a small square in the middle
        // was clickable.
        Button(action: onTap) {
            symbolText
                .frame(width: mass + 10, height: mass + 10)
                .contentShape(Rectangle())
        }
            .buttonStyle(Theme.PressButton())
            .onHover { hovers = $0 }
            .animation(Theme.timeFloat, value: hovers)
            .help(help)
            .accessibilityLabel(Text(help))
    }

    @ViewBuilder private var symbolText: some View {
        ZStack {
            switch entries?.state {
            case nil:
                Circle().strokeBorder(Theme.fontQuiet, lineWidth: 1.5)
                image("arrow.down", 12, Theme.font)
            case .waits:
                Circle().strokeBorder(Theme.fontVeryQuiet,
                                      style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
                image("pause.fill", 10, Theme.fontVeryQuiet)
            case .loads:
                arc(share: shareNow ?? entries?.share ?? 0, color: Theme.accent)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: mass * 0.32, height: mass * 0.32)
            case .halted:
                arc(share: entries?.share ?? 0, color: Theme.fontQuiet)
                image("play.fill", 10, Theme.font)
            case .done:
                // **An arrow, not a checkmark.** The checkmark is reserved for "watched",
                // and in the episode list it sits right next to this icon.
                Circle().fill(Theme.accent)
                image("arrow.down", 12, Theme.reason)
            case .error:
                Circle().strokeBorder(Theme.warning, lineWidth: 2)
                image("exclamationmark", 12, Theme.warning)
            }
        }
        .frame(width: mass, height: mass)
        .opacity(hovers ? 1 : 0.9)
        .animation(Theme.reveal, value: entries?.state)
    }

    private func arc(share: Double, color: Color) -> some View {
        ZStack {
            // The track is light: white at 30%, the same tone as under a tile's
            // progress bar.
            Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, share))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(1)
        }
    }

    private func image(_ name: String, _ size: CGFloat, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
    }

    private var help: LocalizedStringKey {
        switch entries?.state {
        case nil:          "Laden"
        case .waits:      "Wartet"
        case .loads:       "Lädt, anhalten"
        case .halted:  "Angehalten, fortsetzen"
        case .done:      "Auf diesem Mac"
        case .error:      "Fehlgeschlagen, erneut versuchen"
        }
    }
}

/// What a click on the ring does. The same everywhere.
@MainActor
func ringClick(_ entries: DownloadItem?, _ management: DownloadManager,
                  create: () -> Void) {
    switch entries?.state {
    case nil:                            create()
    case .loads:                         management.halt(entries!.id)
    case .halted, .error, .waits:  management.resume(entries!.id)
    case .done:                        break
    }
}

// MARK: - The confirmation

/// Three states, same as on iPhone, shown as a popover at the button
/// instead of a sheet from below.
struct LoadPanel: View {
    let model: AppModel
    let entries: [DownloadItem]
    let title: String
    var images: [String: URL] = [:]
    @Binding var opened: Bool
    /// **Quality is chosen here**, for a movie that has no selection step
    /// before it. A series comes from `MacLadeauswahl` and brings its choice with
    /// it. Like `LoadSheet` on iPhone.
    var qualitySelect = false
    /// The audio tracks of a film, to choose one before loading. A series brings
    /// its choice from the selection.
    var audioStreams: [MediaStream] = []
    /// If the download fails right after starting. Same as on iPhone.
    var failed: (String) -> Void = { _ in }

    @State private var choice: DownloadQuality = .original
    /// `nil` until someone picks: then the audio language from the settings applies.
    @State private var audioChosen: DownloadAudioChoice?

    private var management: DownloadManager { model.downloads }
    private var version: [DownloadItem] {
        let base = qualitySelect ? entries.map { $0.inQuality(choice) } : entries
        guard audioSelect else { return base }
        return base.map { $0.withAudio(audio, streams: audioStreams) }
    }
    private var audioSelect: Bool {
        qualitySelect && model.downloadQualitySelectable
            && DownloadAudio.offered(streams: audioStreams)
    }
    private var audioOptions: [DownloadAudioOption] { DownloadAudio.trackOptions(streams: audioStreams) }
    private var audio: DownloadAudioChoice {
        audioChosen ?? DownloadAudio.preselected(options: audioOptions, streams: audioStreams,
                                                 preferredLanguage: model.audioLanguage)
    }
    private var bytes: Int64 { version.reduce(0) { $0 + $1.bytes } }
    /// Built by the server: the size is an estimate.
    private var converted: Bool { version.contains(where: \.streamed) }
    /// Converted, not only cut down to one audio track.
    private var recomputed: Bool { version.contains(where: \.converted) }
    private var offered: [DownloadQuality] {
        DownloadQuality.offered(
            selectable: model.downloadQualitySelectable,
            sourceBitrateOf: DownloadQuality.sourceBitrateOf(entries.map { ($0.bytes, $0.runtimeTicks) }))
    }
    /// Size as text, with "≈" if it is estimated.
    private var sizesText: String {
        (converted ? "≈ " : "") + DownloadRules.size(bytes)
    }
    private var inquiry: DownloadRules.SpaceInfo { management.inquiry(for: bytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: header)
                .font(Theme.listTitle)
                .foregroundStyle(Theme.font)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Rectangle().fill(Theme.margin).frame(height: 1)

            if !inquiry.suffices {
                detail("internaldrive", "Diese Datei", sizesText)
                // A smaller version is the obvious way out. If that is enough, the popover
                // switches to the normal case by itself.
                if qualitySelect, model.downloadQualitySelectable, offered.count > 1 {
                    qualityRow
                }
                if audioSelect { audioRow }
                detail("externaldrive", "Frei auf diesem Mac",
                       DownloadRules.size(management.free), cautionary: true)
                if inquiry.sufficesToCleanUp, !inquiry.dispensable.isEmpty {
                    detail("checkmark.circle", "Gesehene Titel",
                           DownloadRules.size(inquiry.dispensableBytes))
                    button("Gesehene entfernen und laden") {
                        management.remove(inquiry.dispensable.map(\.id))
                        start()
                    }
                } else {
                    hint("Auch nach dem Entfernen der gesehenen Titel reicht der Platz nicht.")
                }
                cancel
            } else if !DownloadRules.mayLoad(wLAN: management.wLAN,
                                               onlyOverWLAN: management.onlyOverWLAN) {
                detail("internaldrive", "Größe", sizesText)
                detail("wifi.slash", "Kein WLAN", String(localized: "Mobilfunk"), cautionary: true)
                button("In die Warteschlange") { start() }
                cancel
            } else {
                detail("internaldrive", "Größe", sizesText)
                if qualitySelect, model.downloadQualitySelectable, offered.count > 1 {
                    qualityRow
                } else if let g = guete {
                    detail("sparkles", "Qualität", g)
                }
                if audioSelect {
                    audioRow
                } else if let a = audioName {
                    detail("speaker.wave.2", "Ton", a)
                }
                detail("externaldrive", "Danach frei",
                       DownloadRules.size(inquiry.freeAfter))
                button("Laden") { start() }
                if recomputed {
                    hint("Der Server wandelt die Datei beim Laden um. Die Größe ist geschätzt, Untertitel kommen als eigene Dateien mit.")
                } else if converted {
                    hint("Der Server legt die Datei beim Laden mit nur einer Tonspur an. Die Größe ist geschätzt, Untertitel kommen als eigene Dateien mit.")
                } else {
                    hint("Swiftly lädt die Originaldatei, in derselben Qualität wie beim Streamen.")
                }
                cancel
            }
        }
        .frame(width: 320, alignment: .leading)
        // No shadow anywhere.
        .background {
            let form = RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous)
            form.fill(Theme.raised).overlay { form.strokeBorder(Theme.margin, lineWidth: 1) }
        }
    }

    /// The way out. **Always present**, even if the state already has a second
    /// button; otherwise "never mind" would depend on which of the three states
    /// applies.
    private var cancel: some View {
        Button { opened = false } label: {
            Text("Abbrechen")
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(Theme.PressButton())
        // **Escape, done this way.** On the Mac `onExitCommand` hangs off the
        // responder chain, and a popover is not part of it, so the key never
        // arrived. `cancelAction` binds it to this button, which is the usual
        // desktop way anyway.
        .keyboardShortcut(.cancelAction)
        .padding(.bottom, 12)
    }

    private var header: String {
        inquiry.suffices ? String(localized: "\(title) laden")
                        : String(localized: "Nicht genug Platz")
    }

    private func detail(_ symbol: String, _ was: LocalizedStringKey,
                        _ value: String, cautionary: Bool = false) -> some View {
        HStack(spacing: 10) {
            // A row in a popover: icon and text on the type scale, 20 wide icon column.
            // The scale has 13 only as a medium weight, so it is not used without a role.
            Image(systemName: symbol)
                .font(Theme.body)
                .foregroundStyle(cautionary ? Theme.warning : Theme.fontQuiet)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(was)
                .font(Theme.body)
                .foregroundStyle(cautionary ? Theme.warning : Theme.font)
            Spacer(minLength: 10)
            Text(verbatim: value)
                .font(Theme.body)
                .monospacedDigit()
                .foregroundStyle(Theme.fontQuiet)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// Quality level and container, as shown when there is no choice.
    private var guete: String? {
        var parts: [String] = []
        if let q = version.first?.guete, !q.isOriginal { parts.append(q.name + " · " + q.addition()) }
        if let c = version.first?.container { parts.append(c.uppercased()) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The quality with the choice on the right. Same badge as in the series
    /// selection.
    private var qualityRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("Qualität")
                .font(Theme.body)
                .foregroundStyle(Theme.font)
            Spacer(minLength: 10)
            MacQualityBadge(choice: $choice, offered: offered, selectable: true,
                                  size: { q in entries.reduce(0) {
                                      $0 + q.estimatedBytes(original: $1.bytes,
                                                              runtimeTicks: $1.runtimeTicks) } })
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    /// The audio with the choice on the right, built like the quality row.
    private var audioRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2")
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("Ton")
                .font(Theme.body)
                .foregroundStyle(Theme.font)
            Spacer(minLength: 10)
            MacAudioBadge(choice: Binding(get: { audio }, set: { audioChosen = $0 }),
                          options: audioOptions)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    /// What the audio row says when it is not a choice: a series brings the language
    /// along from its selection.
    private var audioName: String? {
        guard let key = version.first?.audioLanguage, version.first?.audioIndex != nil
        else { return nil }
        return TrackLabel.language(key) ?? key
    }

    private func button(_ text: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        PrimaryButton(label: text, symbol: "arrow.down", pick: perform)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 12)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Theme.small)
            .foregroundStyle(Theme.fontQuiet)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
    }

    private func start() {
        opened = false
        let new = version.map(\.id).filter { id in !management.entries.contains { $0.id == id } }
        management.trigger(version, images: images)
        let lager = management, report = failed
        Task {
            if let reason = await lager.immediateFailed(new) { report(reason) }
        }
    }
}

// MARK: - The page

struct DownloadsView: View {
    let model: AppModel

    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section
    @State private var edit = false
    @State private var selected: Set<String> = []

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
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if !ongoing.isEmpty {
                        category(management.noNetwork ? "Wartet auf Netz" : "Lädt gerade")
                        // Same gap as on iPhone: items that were still downloading could not be
                        // checked and so could not be removed.
                        ForEach(ongoing) { p in
                            MacDownloadRow(model: model, entries: p,
                                             edit: edit,
                                             selected: binding(for: [p.id]))
                            separator(after: p.id == ongoing.last?.id)
                        }
                    }

                    if !finished.isEmpty {
                        // **No heading above the downloaded items.** Everything on the downloads
                        // page is on this Mac, so a label like "On this Mac" said nothing. As on
                        // iPhone, the spacing to "Downloading now" stays.
                        Color.clear.frame(height: ongoing.isEmpty ? 4 : 26)
                        ForEach(finished) { g in
                            rowFor(g)
                            separator(after: g.id == finished.last?.id)
                        }
                    }
                }
                // **Reading width, not window width.** A row of image, title and a ring,
                // stretched over 1600 points, has nothing to say in the middle. Same limit
                // as elsewhere.
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if management.entries.isEmpty {
                // **No "What can I download" button.** Some apps have one because not
                // everything is downloadable there. Here everything is, so the button only
                // led back to the library.
                //
                // The wording is the iPhone's, verbatim. An empty state says plainly what is
                // going on, and the second sentence may have some personality. Two wordings
                // for the same situation would be a deviation.
                EmptyState(symbol: "arrow.down.circle",
                            headerLine: "Noch nichts geladen",
                            text: "Lad was runter, bevor der Zug ins Funkloch fährt.")
            }
        }
    }

    private func category(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Theme.rail)
            .foregroundStyle(Theme.font)
            .padding(.top, 26)
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private func separator(after last: Bool) -> some View {
        if !last { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    @ViewBuilder
    private func rowFor(_ g: DownloadGroup) -> some View {
        switch g {
        case let .single(p):
            MacDownloadRow(model: model, entries: p, edit: edit,
                             selected: binding(for: [p.id]))
        case let .series(id, title, episodes):
            // **A series opens its own page**, as on iPhone: large image, name, play
            // button, episodes by season below. Before, the row expanded in place into a
            // plain list under the name, without image or play button.
            MacDownloadRow(model: model, entries: episodes[0],
                             group: (title, episodes), edit: edit,
                             selected: binding(for: episodes.map(\.id)),
                             unfold: {
                                 navigator.openIt(.downloadSeries(id, title: title), in: section)
                             })
        }
    }

    private func binding(for ids: [String]) -> Binding<Bool> {
        Binding(get: { !ids.isEmpty && ids.allSatisfy { selected.contains($0) } },
                set: { an in
                    if an { selected.formUnion(ids) } else { selected.subtract(ids) }
                })
    }

    private var header: some View {
        // **Same header as every other root page.**
        //
        // It used to have two lines and started at `signalHeight` (40) instead of
        // `contentTop` (52), which made it visibly taller than "Movies", "Shows",
        // "Watchlist" and "Search".
        //
        // **No line under the title.** It showed usage (title count, size, free
        // space). The same information is on the storage bar further down, and a
        // title with a subtitle looks unlike every other root page. Offline, the
        // empty state says it. The line was already removed on iPhone.
        HStack(alignment: .center, spacing: 14) {
            Text("Downloads")
                .font(Theme.titleLarge)
                .tracking(Theme.lockTitle)
            Spacer(minLength: 0)
            if !management.entries.isEmpty {
                if edit, !selected.isEmpty {
                    ActionButton(mass: Theme.primaryButtonHeight, symbol: "trash", title: "Entfernen", active: false) {
                        management.remove(Array(selected))
                        selected = []
                        edit = false
                    }
                }
                EditButton(edit: $edit, selected: $selected)
            }
        }
        .padding(.top, Theme.contentTop)
    }

}

/// Pencil and cross at the top right. The same button on the download list
/// and on a downloaded series' page, as on iPhone.
struct EditButton: View {
    @Binding var edit: Bool
    @Binding var selected: Set<String>

    var body: some View {
        ActionButton(mass: Theme.primaryButtonHeight, symbol: edit ? "xmark" : "pencil",
                     title: edit ? "Fertig" : "Bearbeiten",
                     active: edit) {
            // The animation curve for popovers on the Mac: rows glide, the circle
            // pushes them from the left.
            withAnimation(Theme.leap) {
                edit.toggle()
                if !edit { selected = [] }
            }
        }
    }
}

/// One row. Named `MacDownloadRow` rather than `Downloadzeile` because no
/// two types with the same name may exist in the same target.
struct MacDownloadRow: View {
    let model: AppModel
    let entries: DownloadItem
    var group: (title: String, episodes: [DownloadItem])?
    var edit = false
    @Binding var selected: Bool
    /// Only for a group row: opens the series' page.
    var unfold: (() -> Void)?

    @State private var hovers = false
    @Environment(PlayControls.self) private var controls
    private var management: DownloadManager { model.downloads }
    /// The item with the live progress. **Read only here**, so a progress report
    /// redraws just this row and not the whole list.
    private var now: DownloadItem { management.current(entries) }
    /// Keeps the estimator across redraws. It is not observed; the timeline
    /// queries it for each frame.
    @State private var estimator = EstimatorHolder()

    /// **While downloading, the row keeps counting every frame**, as on iPhone.
    /// The download manager reports at most once per second; in between,
    /// `ProgressEstimator` extrapolates at the speed of the last few seconds.
    /// Number, bar and ring read the **same** value.
    ///
    /// **Estimation happens only while bytes are actually arriving.** When
    /// paused, waiting, failed or offline, the number is shown immediately,
    /// where it was.
    var body: some View {
        Group {
            if comesWas {
                TimelineView(.animation(minimumInterval: 1.0 / 10)) { tick in
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
        // **A button, not `onTapGesture`.**
        //
        // Playing, expanding and selecting all used to hang off a tap gesture, so
        // the whole download list was dead with VoiceOver or keyboard only. The
        // button covers everything except the column on the right: the download
        // ring is a button itself, and a button inside a button swallows the click.
        HStack(spacing: 16) {
            Button(action: activate) {
            HStack(spacing: 16) {
            if edit {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(Theme.categoryLarge.weight(.regular))
                    .foregroundStyle(selected ? Theme.accent : Theme.fontVeryQuiet)
                    .accessibilityHidden(true)
                    // **The circle comes in from the left and pushes the row ahead of it**, as
                    // on iPhone. With reduced motion it is a cross-fade.
                    .transition(Theme.motionReduced
                                ? .opacity
                                : .move(edge: .leading).combined(with: .opacity))
            }

            ImageArea(image: imageAddressValue,
                        width: landscape ? 142 : 76, height: landscape ? 80 : 114,
                        symbolText: landscape ? "tv" : "film")
                // Watched state shown as in the episode list, also offline.
                .watchedCheckmark(group == nil && entries.watched, border: 20, spacing: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: group?.title ?? entries.title)
                    .font(Theme.listTitle)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                Text(verbatim: subline(loaded))
                    .font(Theme.secondLine.monospacedDigit())
                    .foregroundStyle(underColor)
                    .lineLimit(1)
                if let share = share(loaded),
                   entries.state == .loads || entries.state == .halted {
                    // Not a shared component: `ProgressBar` is in
                    // `Sources/Shared/Style.swift` and belongs to the iPhone target. Copying
                    // three lines is cheaper than moving a file the Mac otherwise does not need.
                    GeometryReader { r in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.3))
                            Capsule().fill(Theme.accent)
                                .frame(width: r.size.width * min(max(share, 0), 1))
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 3)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            }
            // **No gray background**, as on iPhone: clicking here only selects or
            // plays. The content dims briefly.
            .buttonStyle(Dim())
            .accessibilityLabel(Text(verbatim: group?.title ?? entries.title))
            .accessibilityValue(Text(verbatim: subline(loaded)))
            .accessibilityAddTraits(edit && selected ? [.isButton, .isSelected]
                                                           : .isButton)

            if group == nil {
                DownloadRing(entries: now, shareNow: share(loaded)) {
                    ringClick(entries, management) {}
                }
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .frame(width: 36)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(hovers && edit ? Theme.area : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .animation(Theme.leap, value: edit)
    }

    /// **Plays directly instead of opening the detail page:** that needs the
    /// server, and someone here may not have one. `model.plan` takes the file
    /// from disk without asking, and the item builds the `Item` it needs itself.
    private func activate() {
        if edit { selected.toggle() }
        else if let unfold { unfold() }
        else if entries.state == .done { controls.launch(entries.asItem) }
    }

    private var landscape: Bool { group == nil && entries.art == .episode }

    private var imageAddressValue: URL? {
        management.image(for: entries, asGroup: group != nil)
            ?? model.posterURL(itemID: group != nil ? (entries.seriesIdentifier ?? entries.id) : entries.id)
    }

    private func subline(_ loaded: Int64) -> String {
        if let g = group {
            let bytes = g.episodes.reduce(Int64(0)) { $0 + $1.bytes }
            return String(localized: "\(g.episodes.count) Folgen") + " · "
                + DownloadRules.size(bytes)
                + (DownloadQuality.gemeinsam(g.episodes).map { " · " + $0.name } ?? "")
        }
        var parts: [String] = []
        // Localized: German "F" for Folge, English "E" for episode. It was
        // hard-coded as "F", including in English.
        if let s = entries.season, let f = entries.episode { parts.append(String(localized: "S\(s) F\(f)")) }
        else if let t = entries.runtimeTicks, t > 0 {
            parts.append(runtime(Double(t) / 10_000_000))
        }
        switch entries.state {
        case .loads:
            // **Fixed unit, fixed digits.** `size` switched mid-download from
            // "845 MB" to "1 GB" and "1,01 GB", so the row changed width at every
            // step. The total size now dictates the unit.
            let f = DownloadRules.progress(loaded: loaded, from: now.bytes)
            // If transcoded, the end result is an estimate, so "≈" goes in front.
            parts = [String(localized: "\(f.loaded) von \((entries.streamed ? "≈ " : "") + f.total)")]
        case .waits:
            parts.append(String(localized: "wartet"))
            if entries.converted { parts.append(entries.guete.name) }
        case .halted:
            parts.append(String(localized: "angehalten"))
            if entries.converted { parts.append(entries.guete.name) }
        case .error:      parts = [entries.reason ?? String(localized: "Fehlgeschlagen")]
        case .done:
            parts.append(DownloadRules.size(now.bytes))
            // The chosen level is shown where the container is otherwise shown.
            if entries.converted {
                parts.append(entries.guete.name)
            } else if let c = entries.container {
                parts.append(c.uppercased())
            }
            if !entries.stillOnTheServer {
                parts.append(String(localized: "nicht mehr auf dem Server"))
            }
        }
        return parts.joined(separator: " · ")
    }

    private var underColor: Color {
        switch entries.state {
        case .loads:  Theme.accent
        case .error: Theme.warning
        default:      Theme.fontQuiet
        }
    }
}

// MARK: - A downloaded series

/// **The series on this Mac, as a detail page.** Template: `DownloadSeriesView`
/// in `Sources/Shared/DownloadsView.swift`.
///
/// Large image on top, name with episode count and size, a play button, then
/// the episodes by season. Built from the detail page's components
/// (`Backdrop`, `DetailHeader`, `Hauptknopf`), with no design of its own.
///
/// **Everything from disk.** Someone here may be offline: the image is the
/// series' saved header image, else the next episode's landscape image or the
/// poster, and a server address only after that.
///
/// **Removal goes through an episode's context menu or through Edit**
/// (selection circles, then the trash button or the Delete key). iPhone adds
/// swiping, which does not exist with a pointer.
struct DownloadSeriesOverviewPage: View {
    let model: AppModel
    let seriesIdentifier: String
    let title: String
    let back: () -> Void

    @Environment(PlayControls.self) private var controls
    @Environment(\.displayScale) private var pixelMetric
    @State private var headerState = HeaderState()
    @State private var edit = false
    @State private var selected: Set<String> = []
    @State private var pagesWidth: CGFloat = 0
    /// The header image fetched later, once it is available.
    @State private var caughtUp: URL?

    private var management: DownloadManager { model.downloads }

    private var episodes: [DownloadItem] {
        management.entries
            .filter { $0.seriesIdentifier == seriesIdentifier }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }

    /// By season, in season order.
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

    private var headerImage: URL? {
        guard let p = next ?? episodes.first else { return nil }
        if let large = caughtUp ?? management.headerImage(series: seriesIdentifier, account: p.account) {
            return large
        }
        return management.image(for: p)
            ?? management.image(for: p, asGroup: true)
            ?? model.posterURL(itemID: p.seriesIdentifier ?? p.id)
    }

    /// How wide the header image must be in pixels: `Backdrop` uses 62% of the
    /// width and is `heroHeightValue * 1.62` tall. A 16:9 image needs at least the
    /// width that fills that height.
    static func headerPixel(pagesWidth: CGFloat, pixelMetric: CGFloat) -> Int {
        let points = max(pagesWidth * 0.62, Theme.heroHeightValue * 1.62 * 16 / 9)
        return Int((points * pixelMetric).rounded(.up))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Backdrop(url: headerImage, height: Theme.heroHeightValue * 1.62)
                    block
                        .padding(.leading, Theme.edgeSpacing)
                        .padding(.top, Theme.titleHeight + 98)
                }
                .frame(height: Theme.heroHeightValue, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(seasons, id: \.number) { season in
                        if let n = season.number {
                            GroupsTitle(text: "Staffel \(n)")
                                .padding(.top, 26)
                                .padding(.bottom, 10)
                        }
                        ForEach(season.episodes) { p in
                            episodeRow(p)
                            if p.id != season.episodes.last?.id {
                                Rectangle().fill(Theme.line).frame(height: 1)
                            }
                        }
                    }
                }
                // Reading width, same as the download list.
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.never)
        .pagesScroll()
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(Theme.reason)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pagesWidth = $0 }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        .overlay(alignment: .top) {
            DetailHeader(title: title, state: headerState, back: back)
        }
        .task(id: pagesWidth > 0) { await headerImageCatchUp() }
        // **Last episode gone, page gone.** A series page with no episodes has
        // nothing left to show, so go back to the list.
        .onChange(of: episodes.isEmpty) { _, empty in if empty { back() } }
    }

    /// Name and details, with the buttons below, where the detail page puts
    /// them.
    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title)
                .font(Theme.titleLarge)
                .tracking(Theme.lockTitle)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(width: 640, height: 42, alignment: .leading)
            Text(verbatim: String(localized: "\(episodes.count) Folgen") + " · "
                 + DownloadRules.size(episodes.reduce(0) { $0 + $1.bytes }))
                .font(Theme.small)
                .monospacedDigit()
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
                .padding(.top, 12)
            buttonRail
                .padding(.top, 22)
        }
    }

    /// **The next unwatched episode**, otherwise from the start. The rule is in
    /// `DownloadRules.nextEpisode`. Labeled as on the series page
    /// ("Abspielen S2 F6").
    private var buttonRail: some View {
        HStack(spacing: 12) {
            PrimaryButton(label: LocalizedStringKey(
                           Item.seriesButton(episode: next?.asItem, loads: false))) {
                if let next { controls.launch(next.asItem) }
            }
            .fixedSize()
            .frame(minWidth: Theme.primaryButtonWidth, alignment: .leading)
            .disabled(next == nil)
            EditButton(edit: $edit, selected: $selected)
            if edit, !selected.isEmpty {
                ActionButton(mass: Theme.primaryButtonHeight, symbol: "trash",
                             title: "Entfernen") {
                    removeSelected()
                }
                // **The Delete key does the same**, the usual desktop way to discard a
                // selection.
                .keyboardShortcut(.delete, modifiers: [])
                .transition(.opacity)
            }
        }
        .animation(Theme.leap, value: edit && !selected.isEmpty)
    }

    private func episodeRow(_ p: DownloadItem) -> some View {
        MacDownloadRow(model: model, entries: p, edit: edit,
                         selected: Binding(
                            get: { selected.contains(p.id) },
                            set: { an in if an { selected.insert(p.id) } else { selected.remove(p.id) } }))
            // The equivalent of "long press" on iPhone.
            .contextMenu {
                Button(role: .destructive) { remove([p.id]) } label: {
                    Label("Download entfernen", systemImage: "trash")
                }
            }
    }

    private func removeSelected() {
        remove(Array(selected))
        selected = []
        withAnimation(Theme.leap) { edit = false }
    }

    private func remove(_ ids: [String]) {
        withAnimation(Theme.reveal) { management.remove(ids) }
    }

    /// **Older downloads have no large header image.** With a network it is
    /// fetched once here. Offline the request fails silently and the image from
    /// disk stays.
    private func headerImageCatchUp() async {
        guard pagesWidth > 0, let p = episodes.first,
              management.headerImage(series: seriesIdentifier, account: p.account) == nil,
              let series = await model.item(id: seriesIdentifier),
              let address = model.headerImageURL(for: series, width: Self.headerPixel(
                  pagesWidth: pagesWidth, pixelMetric: pixelMetric))
        else { return }
        caughtUp = await management.headerImageCatchUp(series: seriesIdentifier, account: p.account, from: address)
    }
}

/// The pressed state of a download row: the content dims briefly instead of
/// putting a fill behind the row. The keyboard focus mark stays; without it a
/// keyboard-only user could not see where they are.
private struct Dim: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BodyShell(pressed: configuration.isPressed) { configuration.label }
    }

    private struct BodyShell<ContentBody: View>: View {
        let pressed: Bool
        @ViewBuilder let content: ContentBody
        @Environment(\.isFocused) private var focused

        var body: some View {
            content
                .opacity(pressed ? 0.6 : 1)
                .background(Theme.hoverArea.opacity(focused ? 1 : 0),
                            in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .animation(Theme.pressCurve(pressed), value: pressed)
                .animation(Theme.timeFloat, value: focused)
        }
    }
}

/// A wrapper so the estimator survives redraws without each estimate
/// triggering a new one.
private final class EstimatorHolder {
    var s = ProgressEstimator()
}

// MARK: - Choosing what to download

/// **The download selection: Mac version of `Sources/Shared/LoadSelection.swift`.**
///
/// It used to be a "Staffel laden" chip that took exactly one season, the
/// currently selected one. Two seasons meant two clicks, the whole series
/// seven.
///
/// A tree with three levels (**whole series, season, episode**), and each
/// level carries the same round box in three states: empty, partial, full.
/// Checking a season checks its episodes; unchecking an episode makes the
/// season partial.
///
/// **The switch does not select anything.** "Nur ungesehene" decides *what* a
/// check selects. Toggling it keeps the selection; it is recomputed.
///
/// **It appears as a popover in place, not as a sheet from below.** Nothing
/// slides in from below on the Mac; same decision as for the season picker,
/// the More list and the download popover. Everything else is the iPhone
/// version. The row heights 58 for the season and 52 for the indented episode
/// are **intentional** and not two answers to the same question: the episode
/// should sit flatter than the season it belongs to.
struct MacLoadSelection: View {
    let model: AppModel
    let series: Item
    let seasons: [Item]
    /// The episodes the series page already has, usually the selected season.
    let preloaded: [String: [Item]]
    @Binding var opened: Bool
    /// What the selection yields: the episodes to download, and in which
    /// quality.
    let proceed: ([Item], DownloadQuality, DownloadAudioChoice) -> Void

    @State private var episodes: [String: [Item]] = [:]
    /// `nil` until someone picks: then the audio language from the settings applies.
    @State private var audioChosen: DownloadAudioChoice?
    @State private var selected: Set<String> = []
    @State private var openSeason: String?
    @State private var onlyUnwatched = false
    @State private var loads = true
    /// Original, until someone clicks the badge and picks something else.
    @State private var quality: DownloadQuality = .original
    /// **The failure case is part of it.** If loading fails, the selection must
    /// not show up empty; nobody would know whether the series has no episodes or
    /// the server is not answering.
    @State private var disrupted = false

    private var allEpisodes: [Item] { seasons.compactMap { episodes[$0.id] }.flatMap { $0 } }

    var body: some View {
        VStack(spacing: 0) {
            // Sheet heading: 17 semibold, no line below.
            Text(verbatim: series.name)
                .font(Theme.categoryLarge)
                .tracking(Theme.lockCategory)
                .foregroundStyle(Theme.font)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if disrupted, allEpisodes.isEmpty {
                DisturbHint(model: model, retry: { Task { await loadAll() } },
                             spacingTop: 10)
                    .padding(.bottom, 16)
            } else {
                ScrollView {
                    VStack(spacing: 12) { seriesCard; seasonCard }
                        .padding(.bottom, 12)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height }
                            action: { heightSet($0) }
                }
                // **As tall as the cards, at most 360.** Without a cap the popover grows
                // past the window with fifteen seasons. The cap alone is not enough: a
                // `ScrollView` is greedy vertically and would take the 360 even with two
                // seasons, leaving a gap under the last card. Same calculation as on iPhone.
                .frame(height: min(max(contentHeight, 58), 360))
                .scrollIndicators(.hidden)

                footer
            }
        }
        .frame(width: 420, alignment: .leading)
        // No shadow anywhere.
        .background {
            let form = RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous)
            form.fill(Theme.raised).overlay { form.strokeBorder(Theme.margin, lineWidth: 1) }
        }
        .task(id: opened) { if opened { await loadAll() } }
    }

    @State private var contentHeight: CGFloat = 0

    /// **The popover grows with its content instead of jumping**, as on iPhone
    /// (`Ladeauswahl.heightSet`). The rows expanded along a curve, but the
    /// height above only updated after expanding and without a curve, so the
    /// popover snapped tall and the rows moved in afterwards. Now the height
    /// uses the same curve as the rows (`sprung`, the popover curve on the Mac).
    /// Only the first measurement is applied immediately; otherwise the popover
    /// would grow from zero when opening.
    private func heightSet(_ new: CGFloat) {
        guard contentHeight > 0, opened else { contentHeight = new; return }
        withAnimation(Theme.leap) { contentHeight = new }
    }

    /// **What a check takes.** Without the switch, everything; with it, only
    /// what is still open. What is already on disk is never taken.
    private func takeable(_ list: [Item]) -> [Item] {
        list.filter { episode in
            guard model.downloads.entries(for: episode.id) == nil else { return false }
            guard onlyUnwatched else { return true }
            return !(episode.userData?.played ?? false)
        }
    }

    private var selectedEpisodes: [Item] { allEpisodes.filter { selected.contains($0.id) } }
    /// Audio as languages, because the same language sits at a different index in
    /// every file. Only offered when the selected files hold more than one.
    private var audioOptions: [DownloadAudioOption] {
        DownloadAudio.languageOptions(selectedEpisodes.map { $0.mediaSources?.first?.mediaStreams ?? [] })
    }
    private var audioOffered: Bool {
        DownloadAudio.offered(selection: selectedEpisodes.map { $0.mediaSources?.first?.mediaStreams ?? [] })
    }
    private var audio: DownloadAudioChoice {
        let wished = audioChosen ?? .language(model.audioLanguage)
        return audioOffered && audioOptions.contains { $0.choice == wished } ? wished : .all
    }
    /// The footer calculates in the chosen quality, as on iPhone.
    private var bytes: Int64 { bytes(in: quality) }

    private func bytes(in q: DownloadQuality) -> Int64 {
        selectedEpisodes.reduce(0) {
            $0 + q.estimatedBytes(original: Int64($1.mediaSources?.first?.size ?? 0),
                                    runtimeTicks: $1.runTimeTicks)
        }
    }

    private var offered: [DownloadQuality] {
        let base = selectedEpisodes.isEmpty ? allEpisodes : selectedEpisodes
        return DownloadQuality.offered(
            selectable: model.downloadQualitySelectable,
            sourceBitrateOf: DownloadQuality.sourceBitrateOf(base.map {
                (Int64($0.mediaSources?.first?.size ?? 0), $0.runTimeTicks)
            }))
    }

    // MARK: The cards

    private var seriesCard: some View {
        VStack(spacing: 0) {
            row(box: stateAll, title: Text("Ganze Serie"),
                  right: seriesRight) {
                toggle(allEpisodes)
            }
            SheetLine()
            VStack(alignment: .leading, spacing: 3) {
                // A button, not a tap gesture: otherwise the switch is unreachable without
                // a mouse and VoiceOver does not read it.
                Button { onlyUnwatched.toggle() } label: {
                    HStack(spacing: 13) {
                        Text("Nur ungesehene")
                            .font(Theme.listTitle)
                            .foregroundStyle(Theme.font)
                        Spacer(minLength: 12)
                        ToggleSwitch(an: onlyUnwatched)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressRow())
                .accessibilityRepresentation { Toggle(isOn: $onlyUnwatched) { Text("Nur ungesehene") } }
                Text("Entscheidet, was ein Haken auswählt.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.area,
                    in: RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
        .padding(.horizontal, 16)
        // Toggling the switch changes not the selection but its base set, so it is
        // recomputed.
        .onChange(of: onlyUnwatched) { _, _ in newCompute() }
    }

    /// **"Ganze Serie" counts only what is still missing.** What is already on
    /// the Mac does not count.
    private var seriesRight: String {
        if loads { return String(localized: "wird gelesen …") }
        if stateAll == .present { return String(localized: "alles da") }
        if !allEpisodes.isEmpty, visible(allEpisodes).isEmpty {
            return String(localized: "alles gesehen")
        }
        return numberAndSize(takeable(allEpisodes).count, bytesFrom(allEpisodes))
    }

    private var seasonCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(seasons.enumerated()), id: \.element.id) { nr, season in
                let ownOnes = visible(episodes[season.id] ?? [])
                let box = state(ownOnes)
                row(box: box, title: Text(verbatim: season.name),
                      right: seasonRight(episodes[season.id], visible: ownOnes, box),
                      expanded: openSeason == season.id) {
                    toggle(ownOnes)
                } expand: {
                    withAnimation(Theme.leap) {
                        openSeason = openSeason == season.id ? nil : season.id
                    }
                }
                if openSeason == season.id {
                    // **Only indented, no second fill.** In dark mode depth goes upward;
                    // something darker inside a light card looks like a hole.
                    ForEach(ownOnes) { episode in
                        SheetLine()
                        let entries = model.downloads.entries(for: episode.id)
                        row(box: entries != nil ? .present
                                      : (selected.contains(episode.id) ? .full : .empty),
                              title: Text(verbatim: episode.name),
                              right: entries.map(loadState) ?? episodesRight(episode),
                              small: true, inset: 38,
                              quiet: watched(episode)) {
                            toggle([episode])
                        }
                    }
                }
                if nr < seasons.count - 1 { SheetLine() }
            }
        }
        .background(Theme.area,
                    in: RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
        .padding(.horizontal, 16)
        // The switch removes episodes from the list. They leave softly rather than
        // abruptly, and the popover shrinks along the same curve.
        .animation(Theme.leap, value: onlyUnwatched)
    }

    /// **What is in the list.** With "Nur ungesehene", watched episodes are not
    /// shown at all and count nowhere. Before, they stayed visible and were just
    /// no longer selectable. As on iPhone.
    private func visible(_ list: [Item]) -> [Item] {
        onlyUnwatched ? list.filter { !watched($0) } : list
    }

    private func watched(_ episode: Item) -> Bool { episode.userData?.played ?? false }

    /// **"Watched" is shown before choosing.** Without the switch, watched
    /// episodes stay selectable: a circle like any other, but a quiet title and
    /// "gesehen" on the right before the size. The circle distinguishes it from
    /// the quiet checkmark of downloaded episodes.
    private func episodesRight(_ episode: Item) -> String {
        watched(episode) ? String(localized: "gesehen") + " · " + size(episode)
                       : size(episode)
    }

    /// Right side of the season row: what a check there would still take.
    /// **"alles da" only if true**, so not while the season is still being read,
    /// and not when "Nur ungesehene" excludes everything.
    private func seasonRight(_ all: [Item]?, visible ownOnes: [Item],
                               _ box: CheckboxState) -> String {
        guard let all else {
            return loads ? String(localized: "wird gelesen …") : "—"
        }
        if all.isEmpty { return String(localized: "Keine Folgen") }
        if ownOnes.isEmpty { return String(localized: "alles gesehen") }
        if box == .present { return String(localized: "alles da") }
        let free = takeable(ownOnes)
        if free.isEmpty { return String(localized: "alles da") }
        return String(localized: "\(free.count) Folgen")
    }

    /// **A downloaded episode says it is there.** Before, it showed an empty
    /// circle that did nothing when clicked.
    private func loadState(_ entries: DownloadItem) -> String {
        switch entries.state {
        case .done: String(localized: "geladen")
        case .loads: String(localized: "lädt")
        default: String(localized: "wartet")
        }
    }

    /// **The footer calculates too.** Left: what is selected. Right: what stays
    /// free afterwards, not what is free now. The number that matters is the one
    /// after downloading.
    private var footer: some View {
        VStack(spacing: 10) {
            SheetLine()
            HStack(spacing: 10) {
                Text(verbatim: selected.isEmpty
                     ? String(localized: "Nichts gewählt")
                     : numberAndSize(selected.count, bytes))
                    .font(Theme.tile)
                    .monospacedDigit()
                    .foregroundStyle(Theme.font)
                Spacer(minLength: 8)
                spaceDetail
            }
            .padding(.horizontal, 16)
            // **The quality is shown, not hidden in small print.** Swiftly downloads the
            // original file; at 35 GB that explains the number above it and is not a
            // footnote. If the server may transcode, the badge is also the choice of a
            // smaller version.
            MacQualityBadge(choice: $quality, offered: offered,
                                  selectable: model.downloadQualitySelectable,
                                  size: { selected.isEmpty ? 0 : bytes(in: $0) })
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .onChange(of: offered) { _, new in
                    if !new.contains(quality) { quality = .original }
                }
            if audioOffered {
                MacAudioBadge(choice: Binding(get: { audio }, set: { audioChosen = $0 }),
                              options: audioOptions)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }

            PrimaryButton(label: selected.isEmpty ? "Laden"
                                                     : LocalizedStringKey("\(selectedNumber) laden"),
                       symbol: "arrow.down") {
                opened = false
                proceed(selectedEpisodes, quality, audio)
            }
            .disabled(selected.isEmpty)
            .padding(.horizontal, 16)
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    /// **Right side of the footer: free space afterwards, or what is missing.**
    /// With too little space it used to say "Danach 0 GB frei". Correctly
    /// calculated and still wrong, because it did not say that there is not
    /// enough. `DownloadRules.footSpace` decides whether it fits, with the same
    /// reserve as the hint shown afterwards. As on iPhone.
    @ViewBuilder
    private var spaceDetail: some View {
        switch DownloadRules.footSpace(for: bytes, free: model.downloads.free) {
        case .free(let rest):
            Text(verbatim: String(localized: "Danach \(DownloadRules.size(rest)) frei"))
                .font(Theme.small)
                .foregroundStyle(Theme.fontVeryQuiet)
                .monospacedDigit()
        case .few(let missing):
            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(verbatim: String(localized: "\(DownloadRules.size(missing)) zu wenig"))
                    .font(Theme.small)
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.warning)
        }
    }

    private var selectedNumber: String {
        let n = selected.count
        return n == 1 ? String(localized: "1 Folge") : String(localized: "\(n) Folgen")
    }

    private func numberAndSize(_ count: Int, _ bytes: Int64) -> String {
        let figure = count == 1 ? String(localized: "1 Folge")
                               : String(localized: "\(count) Folgen")
        return figure + " · " + DownloadRules.size(bytes)
    }

    // MARK: The box and the row

    /// Four states: the three of the selection, and **da** for what is already
    /// on the Mac and can no longer be chosen.
    private enum CheckboxState { case empty, part, full, present }

    private func state(_ all: [Item], presentCounts: Bool = true) -> CheckboxState {
        let list = visible(all)
        if presentCounts, !list.isEmpty,
           list.allSatisfy({ model.downloads.entries(for: $0.id) != nil }) {
            return .present
        }
        let free = takeable(list)
        guard !free.isEmpty else { return .empty }
        let an = free.filter { selected.contains($0.id) }.count
        return an == 0 ? .empty : (an == free.count ? .full : .part)
    }
    /// Until every season has been read, the series is not "da", even if the
    /// first one read happens to be fully downloaded.
    private var stateAll: CheckboxState { state(allEpisodes, presentCounts: !loads) }

    private func row(box: CheckboxState, title: Text, right: String,
                       small: Bool = false, inset: CGFloat = 16,
                       expanded: Bool? = nil,
                       quiet: Bool = false,
                       perform: @escaping () -> Void,
                       expand: (() -> Void)? = nil) -> some View {
        HStack(spacing: 13) {
            Button(action: perform) { boxImage(box) }
                .buttonStyle(Theme.PressButton())
                .disabled(box == .present)
                .accessibilityLabel(Text("Auswählen"))
                .accessibilityValue(boxValue(box))
                .accessibilityAddTraits(box == .full ? .isSelected : [])
            Button { (expand ?? perform)() } label: {
                HStack(spacing: 10) {
                    title
                        .font(small ? Theme.tile : Theme.listTitle)
                        .foregroundStyle(box == .present || quiet ? Theme.fontQuiet : Theme.font)
                        .lineLimit(1)
                    Spacer(minLength: 10)
                    Text(verbatim: right)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .monospacedDigit()
                    if let expanded {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.fontVeryQuiet)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressRow())
        }
        .padding(.leading, inset)
        .padding(.trailing, 16)
        // **The indented episode row uses the 52 of the other sheets; the season row
        // is one step above.** The 58 is the intended exception, not a second value
        // for the same role: the episode should sit flatter than the season it
        // belongs to.
        .frame(minHeight: small ? 52 : 58)
    }

    @ViewBuilder
    private func boxImage(_ k: CheckboxState) -> some View {
        ZStack {
            switch k {
            case .empty:
                // Controls need 3:1 contrast. `rand` at 12% is too little;
                // `schriftSehrLeise` gives 4.71:1 on `area`.
                Circle().strokeBorder(Theme.fontVeryQuiet, lineWidth: 1.6)
            case .part:
                Circle().fill(Theme.accent)
                Image(systemName: "minus").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
            case .full:
                Circle().fill(Theme.accent)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
            case .present:
                // **Quiet, no circle.** A checkmark in the accent color would mean
                // "selected"; this one only says nothing is left to do.
                Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
        }
        .frame(width: 22, height: 22)
        .animation(Theme.toggle, value: k)
    }

    /// What VoiceOver says for the circle. "Selected" is spoken by `isSelected`
    /// itself.
    private func boxValue(_ k: CheckboxState) -> Text {
        switch k {
        case .empty, .full: Text(verbatim: "")
        case .part: Text("teilweise")
        case .present: Text("geladen")
        }
    }

    // MARK: Selection and data

    private func toggle(_ list: [Item]) {
        let free = takeable(list)
        guard !free.isEmpty else { return }
        let allAn = free.allSatisfy { selected.contains($0.id) }
        withAnimation(Theme.toggle) {
            for f in free {
                if allAn { selected.remove(f.id) } else { selected.insert(f.id) }
            }
        }
    }

    /// After the switch: everything that can no longer be taken drops out.
    private func newCompute() {
        let allowed = Set(takeable(allEpisodes).map(\.id))
        withAnimation(Theme.toggle) { selected.formIntersection(allowed) }
    }

    private func bytesFrom(_ list: [Item]) -> Int64 {
        takeable(list).reduce(0) { $0 + Int64($1.mediaSources?.first?.size ?? 0) }
    }

    private func size(_ episode: Item) -> String {
        guard let b = episode.mediaSources?.first?.size, b > 0 else { return "—" }
        return DownloadRules.size(Int64(b))
    }

    /// **Every season once, and storage counts.**
    ///
    /// The series page has loaded only the selected season. For "whole series"
    /// the popover needs every season, otherwise it would show a wrong number.
    /// Seasons are fetched one after another so the server does not get seven
    /// requests at once, and ones already loaded are not fetched again.
    ///
    /// **`nil` means failed, `[]` means empty.** Failed requests are not cached,
    /// otherwise the empty list would later stand as fact.
    private func loadAll() async {
        loads = true
        disrupted = false
        model.downloads.spaceRefresh()
        episodes = preloaded
        for season in seasons where episodes[season.id] == nil {
            guard let list = await model.episodes(series: series.id, season: season.id) else {
                disrupted = true
                continue
            }
            episodes[season.id] = list
            SeriesCache.shared.remember(series.id) { $0.episodes[season.id] = list }
        }
        loads = false
        // Whatever was downloaded since last opening is no longer selectable;
        // otherwise the footer would still count it.
        newCompute()
    }
}

/// **The badge under a download selection, and the quality choice.** Same as
/// `QualityBadge` on iPhone: Original is the default; if the server may
/// transcode, a click opens a menu with the smaller levels and their
/// estimated size. Otherwise the badge stays put and a sentence says why
/// there is nothing to choose.
struct MacQualityBadge: View {
    @Binding var choice: DownloadQuality
    let offered: [DownloadQuality]
    let selectable: Bool
    /// Estimated size per level for the selection. 0 means no information.
    let size: (DownloadQuality) -> Int64

    var body: some View {
        if selectable, offered.count > 1 {
            Menu {
                ForEach(offered) { q in
                    Button {
                        withAnimation(Theme.toggle) { choice = q }
                    } label: {
                        if q == choice {
                            Label(row(q), systemImage: "checkmark")
                        } else {
                            Text(verbatim: row(q))
                        }
                    }
                }
            } label: {
                badge(expandable: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Qualität"))
            .accessibilityValue(Text(verbatim: choice.badge()))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                badge(expandable: false)
                if !selectable {
                    Text("Kleinere Fassungen gibt der Server für dieses Konto nicht frei.")
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "720p · 4 Mbit/s · ≈ 1,5 GB": the Mac menu has no second line, so the
    /// size is appended.
    private func row(_ q: DownloadQuality) -> String {
        let g = size(q)
        let parts = [q.name, q.addition()]
            + (g > 0 ? [(q.isOriginal ? "" : "≈ ") + DownloadRules.size(g)] : [])
        return parts.joined(separator: " · ")
    }

    private func badge(expandable: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: choice.isOriginal ? "checkmark" : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(verbatim: choice.badge()).font(Theme.small).monospacedDigit()
            if expandable {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.accent.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// **The audio choice, as a pill like the quality one.** A menu with a checkmark,
/// "All audio tracks" first. Same as `AudioBadge` on iPhone.
struct MacAudioBadge: View {
    @Binding var choice: DownloadAudioChoice
    let options: [DownloadAudioOption]

    private var current: String {
        options.first { $0.choice == choice }?.label ?? options.first?.label ?? ""
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    withAnimation(Theme.toggle) { choice = option.choice }
                } label: {
                    if option.choice == choice {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(verbatim: option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(verbatim: current).font(Theme.small).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.accent.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Ton"))
        .accessibilityValue(Text(verbatim: current))
    }
}
