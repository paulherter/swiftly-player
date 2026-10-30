import JellyfinKit
import SwiftUI

/// **What gets downloaded is selected, not guessed.**
///
/// There used to be three ways to download and none for "give me seasons 2
/// and 3". The most visible was a round chip next to the season picker that took
/// exactly one season, the currently selected one. Two seasons meant two taps; a
/// whole series seven.
///
/// Instead this is a tree with three levels, **whole series, season, episode**,
/// and each level carries the same round box in three states: empty, partial,
/// full. Checking a season checks its episodes; unchecking an episode makes the
/// season partial.
///
/// **The toggle selects nothing.** "Unwatched only" decides *what* a check
/// selects. Flipping it does not lose the selection; it is recalculated.
///
/// Nothing is downloaded here. At the end the sheet hands the chosen episodes to
/// `LoadSheet`, where the same three cases apply unchanged: space, Wi-Fi, normal
/// case. Selection is a step **before**, not a second path beside it.
///
/// **Layout like the Mac panel (`MacLadeauswahl`), tones as there.** This had
/// almost the same layout, but the sheet was `area` and the cards in it too,
/// so only the lines remained of the two groups. The Mac puts cards one level
/// *darker* than its panel. For the phone the other direction was chosen: **depth
/// goes up**. The sheet stays `area` like every sheet, the cards sit on
/// `erhoeht`. Something darker inside something lighter would read as a hole.
struct LoadSelection: View {
    @Binding var opened: Bool
    let model: AppModel
    let series: Item
    let seasons: [Item]
    /// The episodes the series page already has, usually the selected season.
    let preloaded: [String: [Item]]
    /// What the selection yields: the episodes to download and in what quality.
    let proceed: ([Item], DownloadQuality, DownloadAudioChoice) -> Void

    @State private var episodes: [String: [Item]] = [:]
    @State private var selected: Set<String> = []
    @State private var openSeason: String?
    @State private var onlyUnwatched = false
    /// Original, until someone taps the badge and picks something else.
    @State private var quality: DownloadQuality = .original
    /// `nil` until someone picks: then the audio language from the settings applies.
    @State private var audioChosen: DownloadAudioChoice?
    @State private var loads = true
    /// **The failure case belongs here**, as on the Mac. If the request fails the
    /// selection must not stand empty; nobody would know whether the series has no
    /// episodes or the server is not answering.
    @State private var disrupted = false

    private var allEpisodes: [Item] { seasons.compactMap { episodes[$0.id] }.flatMap { $0 } }

    /// **What a check selects.** Without the toggle everything; with it only what is
    /// open, and what is already on the device never.
    private func takeable(_ list: [Item]) -> [Item] {
        list.filter { episode in
            guard model.downloads.entries(for: episode.id) == nil else { return false }
            guard onlyUnwatched else { return true }
            return !(episode.userData?.played ?? false)
        }
    }

    private var selectedEpisodes: [Item] { allEpisodes.filter { selected.contains($0.id) } }
    /// **The footer calculates in the chosen quality.** For Original the real size,
    /// otherwise the estimate from bitrate times runtime. "Free afterwards" follows
    /// when another level is chosen.
    private var bytes: Int64 { bytes(in: quality) }

    /// **Audio as languages**, because the same language sits at a different index in
    /// every file. Only offered when the selected files hold more than one.
    private var audioOptions: [DownloadAudioOption] {
        DownloadAudio.languageOptions(selectedEpisodes.map { $0.mediaSources?.first?.mediaStreams ?? [] })
    }
    private var audioOffered: Bool {
        DownloadAudio.offered(selection: selectedEpisodes.map { $0.mediaSources?.first?.mediaStreams ?? [] })
    }
    /// The chosen language, or the one from the settings, or all tracks; never one the
    /// selection does not hold.
    private var audio: DownloadAudioChoice {
        let wished = audioChosen ?? .language(model.audioLanguage)
        return audioOffered && audioOptions.contains { $0.choice == wished } ? wished : .all
    }

    private func bytes(in q: DownloadQuality) -> Int64 {
        selectedEpisodes.reduce(0) {
            $0 + q.estimatedBytes(original: Int64($1.mediaSources?.first?.size ?? 0),
                                    runtimeTicks: $1.runTimeTicks)
        }
    }

    /// Which levels are offered: based on the best file in the selection, or the
    /// whole series while nothing is selected.
    private var offered: [DownloadQuality] {
        let base = selectedEpisodes.isEmpty ? allEpisodes : selectedEpisodes
        return DownloadQuality.offered(
            selectable: model.downloadQualitySelectable,
            sourceBitrateOf: DownloadQuality.sourceBitrateOf(base.map {
                (Int64($0.mediaSources?.first?.size ?? 0), $0.runTimeTicks)
            }))
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(opened: $opened) { content }
            .task(id: opened) { if opened { await loadAll() } }
    }

    /// Combined height of the two cards, measured so the sheet does not get taller
    /// than its content.
    @State private var contentHeight: CGFloat = 0

    private var content: some View {
        VStack(spacing: 0) {
            SheetCategory(text: Text(verbatim: series.name))

            if disrupted, allEpisodes.isEmpty {
                DisturbHint(model: model, retry: { Task { await loadAll() } },
                             spacingTop: 10)
                    .padding(.bottom, 16)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        seriesCard
                        seasonCard
                    }
                    .padding(.bottom, 12)
                    // Measured, not assumed.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height }
                        action: { heightSet($0) }
                }
                // **As tall as the cards, at most 440.**
                //
                // Without a cap the sheet grows past the screen with fifteen seasons, and the
                // footer with the button goes with it. The cap alone is not enough: a
                // `ScrollView` is vertically greedy and takes the full height even with two
                // seasons. Then a void sits below the last card, and because the footer below
                // still sticks to the sheet edge, the sheet looks as if something slipped.
                //
                // 440 instead of the Mac's 360: the phone has the height, and the footer with
                // the button still stays in thumb reach. The Mac panel hangs off the series
                // button and has no such room.
                .frame(height: min(max(contentHeight, 58), 440))
                .scrollIndicators(.hidden)

                footer
            }
        }
    }

    /// **The sheet grows along instead of jumping.**
    ///
    /// Rows expanded in an animation but the height above did not: it is measured
    /// only after expanding, and the value arrived without animation. So the sheet
    /// jumped tall and the rows slid in afterwards ("bang up, bang down"). Now the
    /// height runs in the same curve as the sheet itself (`sheetMotion`, a fade
    /// with Reduce Motion). Only the first measurement applies hard, otherwise the
    /// sheet would grow from zero on opening.
    private func heightSet(_ new: CGFloat) {
        guard contentHeight > 0, opened else { contentHeight = new; return }
        withAnimation(Theme.sheetMotion) { contentHeight = new }
    }

    // MARK: The cards

    /// **Cards on `erhoeht`, corner 14.** `cornerCard` like every group and like on
    /// the Mac; 16 is the corner of a surface of its own, and it used to be here.
    private var cardsShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous)
    }

    private var seriesCard: some View {
        VStack(spacing: 0) {
            row(box: stateAll, title: String(localized: "Ganze Serie"),
                  right: seriesRight) {
                toggle(allEpisodes)
            }
            SheetLine()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 13) {
                    Text("Nur ungesehene")
                        // **Growing, not fixed**. Row titles and sublines follow
                        // the system font, and the row heights are minimums for that. The number column
                        // on the right, the footer and the badge stay fixed: tabular digits and a bar.
                        .growing(15, .semibold)
                        .foregroundStyle(Theme.font)
                    Spacer(minLength: 12)
                    ToggleSwitch(an: $onlyUnwatched)
                }
                Text("Entscheidet, was ein Haken auswählt.")
                    .growing(12)
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // A toggle with a name instead of title, sentence and "On".
            .accessibilityRepresentation { Toggle(isOn: $onlyUnwatched) { Text("Nur ungesehene") } }
            .accessibilityHint(Text("Entscheidet, was ein Haken auswählt."))
        }
        .background(Theme.raised, in: cardsShape)
        .padding(.horizontal, 16)
        // Flipping the toggle changes not the selection but its base set, so it is
        // recalculated.
        .onChange(of: onlyUnwatched) { _, _ in newCompute() }
    }

    /// **"Whole series" names only what is still missing.** What is already on the
    /// device does not count, otherwise it would say 38 episodes of which eleven can
    /// no longer be downloaded.
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
                row(box: box, title: season.name,
                      right: seasonRight(episodes[season.id], visible: ownOnes, box),
                      expanded: openSeason == season.id) {
                    toggle(ownOnes)
                } expand: {
                    withAnimation(Theme.sheetMotion) {
                        openSeason = openSeason == season.id ? nil : season.id
                    }
                }
                if openSeason == season.id {
                    // **Only indented, no second surface.** In dark mode depth goes up; something
                    // darker inside a light card looks like a hole.
                    ForEach(ownOnes) { episode in
                        // Full width, also under the indented episodes: a line starting at 38 while
                        // the one above starts at 18 has no edge to align with. The reasoning is at
                        // `SheetLine`.
                        SheetLine()
                        let entries = model.downloads.entries(for: episode.id)
                        row(box: entries != nil ? .present
                                      : (selected.contains(episode.id) ? .full : .empty),
                              title: episode.name,
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
        .background(Theme.raised, in: cardsShape)
        .padding(.horizontal, 16)
        // The toggle removes episodes from the list; they leave softly, not abruptly,
        // and the sheet shrinks in the same curve.
        .animation(Theme.sheetMotion, value: onlyUnwatched)
    }

    /// **What is in the list.** With "Unwatched only" watched episodes are not
    /// there at all and count nowhere; before, they stayed visible and were only no
    /// longer selectable.
    private func visible(_ list: [Item]) -> [Item] {
        onlyUnwatched ? list.filter { !watched($0) } : list
    }

    private func watched(_ episode: Item) -> Bool { episode.userData?.played ?? false }

    /// **Watched is shown before choosing.** Without the toggle watched episodes
    /// stay selectable: a circle like any other, but quiet title and "watched" on
    /// the right before the size. The circle distinguishes it from the quiet check
    /// of downloaded episodes: the check means "nothing left to do", the circle
    /// "selectable".
    private func episodesRight(_ episode: Item) -> String {
        watched(episode) ? String(localized: "gesehen") + " · " + size(episode)
                       : size(episode)
    }

    /// Right side of the season row: what a check there would still take.
    ///
    /// **"All there" only when true.** It used to appear whenever nothing was left
    /// to take, also while the season was still being read and also when "Unwatched
    /// only" had excluded everything.
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
        return episodesNumber(free.count)
    }

    /// **A downloaded episode says it is there.** Before, an empty circle stood
    /// there that did nothing on tap.
    private func loadState(_ entries: DownloadItem) -> String {
        switch entries.state {
        case .done: String(localized: "geladen")
        case .loads: String(localized: "lädt")
        default: String(localized: "wartet")
        }
    }

    /// **The footer calculates too.** Left, what is selected; right, what stays free
    /// afterwards, not what is free now. The number you want is the one after
    /// downloading.
    private var footer: some View {
        VStack(spacing: 10) {
            SheetLine()
            HStack(spacing: 10) {
                Text(verbatim: selected.isEmpty
                     ? String(localized: "Nichts gewählt")
                     : numberAndSize(selected.count, bytes))
                    // "Title under poster" from the scale, as on the Mac. This used 13 Semibold,
                    // a step outside the scale.
                    .font(Theme.tile)
                    .foregroundStyle(Theme.font)
                    .monospacedDigit()
                Spacer(minLength: 8)
                spaceDetail
            }
            .padding(.horizontal, 16)
            // **The quality is shown, not in fine print.** Swiftly downloads the original
            // file, and at 35 GB that is the explanation for the number above, not a
            // side note. If the server may transcode, the badge is also the choice of a
            // smaller version.
            QualityBadge(choice: $quality, offered: offered,
                               selectable: model.downloadQualitySelectable,
                               size: { selected.isEmpty ? 0 : bytes(in: $0) })
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                // If the chosen level disappears because the selection got smaller, Original
                // applies again, never a level that is no longer offered.
                .onChange(of: offered) { _, new in
                    if !new.contains(quality) { quality = .original }
                }
            if audioOffered {
                AudioBadge(choice: Binding(get: { audio }, set: { audioChosen = $0 }),
                           options: audioOptions)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }

            // **With arrow, as on the Mac.** The same arrow is in the series' button row,
            // which is where you came from. If space is insufficient the button stays on:
            // it leads to the "Not enough space" sheet, which offers the way out via
            // watched titles.
            Button {
                opened = false
                proceed(selectedEpisodes, quality, audio)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down")
                        .font(Theme.categoryLarge)
                        .accessibilityHidden(true)
                    Text(verbatim: selected.isEmpty
                         ? String(localized: "Laden")
                         : String(localized: "\(selectedNumber) laden"))
                }
            }
            // Disabled on `erhoeht`: on a sheet in `area` a disabled button in `area`
            // would be just quiet text.
            .buttonStyle(PrimaryButtonStyle(lockedArea: Theme.raised))
            .disabled(selected.isEmpty)
            .padding(.horizontal, 16)
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// **Right in the footer: free afterwards, or what is missing.** With too little
    /// space it used to say "0 GB free afterwards": correctly calculated and still
    /// wrong, because it did not say it does not fit. Whether it fits is decided by
    /// `DownloadRules.footSpace`, with the same reserve as the following sheet.
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
            // `warning` on `area`: 5.58:1.
            .foregroundStyle(Theme.warning)
        }
    }

    private var selectedNumber: String { episodesNumber(selected.count) }

    private func episodesNumber(_ n: Int) -> String {
        n == 1 ? String(localized: "1 Folge") : String(localized: "\(n) Folgen")
    }

    /// "23 episodes · 31.4 GB": count and size in one go, so the line carries one
    /// statement and not two.
    private func numberAndSize(_ count: Int, _ bytes: Int64) -> String {
        episodesNumber(count) + " · " + DownloadRules.size(bytes)
    }

    // MARK: - The box and the row

    /// Four states: the three of the selection, and **there** for what is already on
    /// the device and can no longer be selected.
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
    /// While not every season is read, the series is not "there", even if the first
    /// one read happens to be fully downloaded.
    private var stateAll: CheckboxState { state(allEpisodes, presentCounts: !loads) }

    private func row(box: CheckboxState, title: String, right: String,
                       small: Bool = false, inset: CGFloat = 16,
                       expanded: Bool? = nil,
                       quiet: Bool = false,
                       perform: @escaping () -> Void,
                       expand: (() -> Void)? = nil) -> some View {
        // **Circle 22, hit area 44**. The 44 extends 11 beyond the circle on
        // each side; inset and spacing subtract it again so the circle stays where it
        // was.
        HStack(spacing: 13 - 11) {
            Button(action: perform) {
                boxImage(box)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressButton())
            .disabled(box == .present)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityValue(boxValue(box))
            .accessibilityAddTraits(box == .full ? .isSelected : [])
            // Without an expander the row next to it does the same as the circle, so
            // VoiceOver reads it once, not twice.
            .accessibilityHidden(expand == nil)

            Button { (expand ?? perform)() } label: {
                HStack(spacing: 10) {
                    Text(verbatim: title)
                        .growing(small ? 13 : 15, small ? .medium : .semibold)
                        .foregroundStyle(box == .present || quiet ? Theme.fontQuiet : Theme.font)
                        .lineLimit(1)
                    Spacer(minLength: 10)
                    Text(verbatim: right)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .monospacedDigit()
                    if let expanded {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.fontVeryQuiet)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressRow())
            .accessibilityValue(expand == nil ? boxValue(box) : Text(verbatim: ""))
            .accessibilityAddTraits(expand == nil && box == .full ? .isSelected : [])
            .accessibilityHint(expanded.map { Text($0 ? LocalizedStringKey("Zuklappen") : LocalizedStringKey("Aufklappen")) }
                               ?? Text(verbatim: ""))
        }
        .padding(.leading, inset - 11)
        .padding(.trailing, 16)
        // **The episode row carries the 52 of the other sheets, the season row one
        // step above.**
        //
        // This said both heights are "the same as in the other sheets", true only for
        // 52. The 58 is the exception and is intended: the indented episode row should
        // sit flatter than the season it belongs to. Before they were 46 and 52, which
        // put the episode row below the sheet standard.
        .frame(minHeight: small ? 52 : 58)
    }

    /// What VoiceOver says for the circle. "Selected" is said by the `isSelected`
    /// trait itself.
    private func boxValue(_ k: CheckboxState) -> Text {
        switch k {
        case .empty, .full: Text(verbatim: "")
        case .part: Text("teilweise")
        case .present: Text("geladen")
        }
    }

    @ViewBuilder
    private func boxImage(_ k: CheckboxState) -> some View {
        ZStack {
            switch k {
            case .empty:
                // **The most important state was the least visible.** This used white 26%:
                // calculated 2.36:1 on `erhoeht`, and white 28% (2.50:1) is already
                // forbidden. Control marks need 3:1. `Theme.rand` would be even less at 12%;
                // `schriftSehrLeise` gives 4.58:1 on `erhoeht`, the card it now sits on.
                Circle().strokeBorder(Theme.fontVeryQuiet, lineWidth: 1.6)
            case .part:
                Circle().fill(Theme.accent)
                // Semibold, not `.heavy`: three weights, and `.heavy` is dropped.
                Image(systemName: "minus").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
            case .full:
                Circle().fill(Theme.accent)
                Image(systemName: "checkmark").font(Theme.group)
                    .foregroundStyle(Theme.onAccent)
            case .present:
                // **Quiet, without a circle.** A check in accent would mean "selected"; this
                // only says nothing is left to do.
                Image(systemName: "checkmark").font(Theme.listTitle)
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
        }
        .frame(width: 22, height: 22)
        .animation(Theme.toggle, value: k)
    }

    // MARK: - Selection and data

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

    /// After the toggle: everything that can no longer be taken drops out.
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

    /// **Each season once, and the cache counts.**
    ///
    /// The series page has only loaded the selected season. "Whole series" needs
    /// every one, otherwise it would show a wrong number. Fetching runs three at a
    /// time so the server does not get seven requests at once, and what is already
    /// there is not refetched.
    ///
    /// **`nil` means failed, `[]` means empty.** Failed requests are not remembered,
    /// otherwise the empty list would later stand as fact.
    private func loadAll() async {
        loads = true
        disrupted = false
        model.downloads.spaceRefresh()
        episodes = preloaded
        // At most three seasons at once: with 20 seasons it used to be 20 round trips
        // in a row.
        let opened = seasons.filter { episodes[$0.id] == nil }
        let seriesIdentifier = series.id
        for beginning in stride(from: 0, to: opened.count, by: 3) {
            let stack = Array(opened[beginning..<min(beginning + 3, opened.count)])
            let model = model
            let respond = await withTaskGroup(of: (Item, [Item]?).self) { group in
                for season in stack {
                    group.addTask { (season, await model.episodes(series: seriesIdentifier, season: season.id)) }
                }
                var all: [(Item, [Item]?)] = []
                for await answer in group { all.append(answer) }
                return all
            }
            for (season, list) in respond {
                guard let list else { disrupted = true; continue }
                episodes[season.id] = list
                SeriesCache.shared.remember(seriesIdentifier) { $0.episodes[season.id] = list }
            }
        }
        loads = false
        // What was downloaded since the last open is no longer selectable, otherwise
        // the footer would still count it.
        newCompute()
    }
}

/// **The badge under a download selection, and the choice of quality.**
///
/// This used to say only "Direct Play · Original quality". That promise stays
/// the default: without action Swiftly downloads the original file. If the
/// server may transcode for this account, a tap opens a list of smaller levels,
/// each with its estimated size. If not, the badge stays as it was and a
/// sentence below says why there is nothing to choose.
///
/// A system menu and not a list of our own: it sits over the sheet instead of
/// pushing a second sheet in, and brings VoiceOver and checkmarks.
struct QualityBadge: View {
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
                        if size(q) > 0 {
                            Text(verbatim: (q.isOriginal ? "" : "≈ ")
                                 + DownloadRules.size(size(q)))
                        }
                    }
                }
            } label: {
                badge(expandable: true)
            }
            .accessibilityLabel(Text("Qualität"))
            .accessibilityValue(Text(verbatim: choice.badge()))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                badge(expandable: false)
                if !selectable {
                    Text("Kleinere Fassungen gibt der Server für dieses Konto nicht frei.")
                        .growing(12)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// „Original · Direct Play", „720p · 4 Mbit/s".
    private func row(_ q: DownloadQuality) -> String {
        q.name + " · " + q.addition()
    }

    private func badge(expandable: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: choice.isOriginal ? "checkmark" : "arrow.down.right.and.arrow.up.left")
                .font(Theme.group)
                .accessibilityHidden(true)
            Text(verbatim: choice.badge())
                .font(Theme.small)
                .monospacedDigit()
                .contentTransition(.numericText())
            if expandable {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.accent.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        // Tappable, the hit area grows to 44 while the badge stays as small as it was
        //.
        .frame(minHeight: expandable ? 44 : nil)
        .contentShape(Rectangle())
    }
}

/// **The audio choice, as a pill like the quality one.** A system menu with a
/// checkmark, "All audio tracks" first. Used in the series selection and in the load
/// sheet of a film.
struct AudioBadge: View {
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
                    .font(Theme.group)
                    .accessibilityHidden(true)
                Text(verbatim: current)
                    .font(Theme.small)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.accent.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Ton"))
        .accessibilityValue(Text(verbatim: current))
    }
}
