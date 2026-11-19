import JellyfinKit
import SwiftUI
import SwiftlyCore

// The Mac's Seerr pages. They draw what the shared flows hand over (`SeerrSearchFlow`, `SeerrTitleFlow`,
// `SeerrRequestsFlow`, `SeerrAdminFlow`, all in `Sources/Shared/SeerrBridge+*.swift`): every word, state, quota
// and verb comes from the core, the same as on iPhone and Apple TV. Only the window chrome is the Mac's own.

// MARK: - Discover rails (empty Search page)

/// Trending, popular films and series, coming soon. A title the own server has is a normal poster and opens its
/// normal page; every other one is a Seerr tile. Nothing is drawn while Seerr is not connected or has nothing.
struct MacSeerrRails: View {
    let model: AppModel
    let flow: SeerrSearchFlow

    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    var body: some View {
        if flow.ready, let rails = flow.rails, rails.load == .content {
            VStack(alignment: .leading, spacing: Theme.railsSpacing) {
                ForEach(rails.rails, id: \.id) { rail in
                    VStack(alignment: .leading, spacing: 12) {
                        RailTitle(name: rail.title)
                        PagingRail(margin: 0) {
                            ForEach(rail.tiles) { card in tile(card) }
                        }
                    }
                }
            }
            .padding(.top, 30)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func tile(_ card: SeerrCard) -> some View {
        if case .title(let item)? = flow.own[card.id] {
            Button { navigator.openIt(.title(item), in: section) } label: {
                PosterCell(title: item.name, secondLine: item.productionYear.map { "\($0)" },
                           image: model.imageURL(for: item, portrait: true),
                           progress: nil, mark: nil, symbolText: item.tileCharacter)
            }
            .buttonStyle(Theme.PressButton())
            .tileMenu(item, model: model)
        } else {
            Button { navigator.openIt(.seerrTitle(card.route), in: section) } label: {
                SeerrTile(card: card, width: Theme.tileWidth)
            }
            .buttonStyle(Theme.PressButton())
        }
    }
}

// MARK: - Title page

/// The page of a title the own server does not have yet: the library's detail page (`FilmView`) with the same head
/// (`DetailHeadBlock`, `DetailHeadFrame`), the same gaps and rows, but the big button asks. The request sheet
/// (`MacRequestSheet`) is the core's; a series lists its seasons with their state.
struct SeerrDetailView: View {
    let model: AppModel
    let hit: JellyfinKit.SeerrHit
    let back: () -> Void

    @State private var flow: SeerrTitleFlow?
    @State private var headerState = HeaderState()
    /// The request being decided (its buttons dim until the page has read again).
    @State private var adminBusy: Int64?

    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    private var info: SwiftlyCore.SeerrTitleInfo? { flow?.info }
    private var title: String {
        guard let name = info?.title, !name.isEmpty else { return hit.title }
        return name
    }
    private var backdropURL: URL? { info?.backdrop.flatMap { URL(string: $0) } ?? hit.backdrop(width: 1280) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The header draws over what is below it (as on the library's page).
                hero.zIndex(1)
                VStack(alignment: .leading, spacing: 26) {
                    seasons
                    episodes
                    cast
                    similar
                    if flow == nil || info?.load == .offline || info?.load == .failed {
                        // Seerr's address, not the own server's: that one runs, or the user would not be here.
                        DisturbHint(model: model, retry: { Task { await load() } },
                                    spacingTop: 0, address: model.seerr.address)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DetailPageMetric.left)
                .padding(.top, 36)
            }
            .padding(.bottom, 40)
            .background(alignment: .top) { StretchedMood(url: backdropURL, state: headerState) }
            .environment(\.onImageTint, true)
            .environment(\.imageColorSource, backdropURL)
        }
        .scrollIndicators(.never)
        .pagesScroll()
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(Theme.reason)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        .overlay(alignment: .top) {
            DetailHeader(title: title, state: headerState, back: back, mood: backdropURL)
        }
        .modifier(MacRequestSheet(flow: flow))
        .task { await load() }
        .task { await Self.openSheetForProof(flow: { flow }) }
    }

    private func load() async {
        guard model.seerr.connected else { return }
        let made = flow ?? SeerrTitleFlow(hub: model.seerr.hub, art: hit.art, tmdb: Int64(hit.id))
        // The answer is applied once the page has stopped sliding (`InTravel`).
        made.settle = { await InTravel.waitFor() }
        flow = made
        await made.start()
    }

    /// Proof hook: `-SwiftlyOpenRequestSheet [season]` opens the request sheet once the title page stands.
    static func openSheetForProof(flow: @escaping () -> SeerrTitleFlow?) async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: "-SwiftlyOpenRequestSheet") else { return }
        let season = args.indices.contains(at + 1) ? Int64(args[at + 1]) : nil
        try? await Task.sleep(for: .seconds(4))
        flow()?.open(season: season)
        #endif
    }

    // MARK: Hero

    private var hero: some View {
        DetailHeadBlock(title: title, details: secondaryLine) {
            chipRail
        } buttons: {
            action.frame(height: DetailPageMetric.buttonHeight, alignment: .leading)
        } below: {
            // The description is part of the head, in its own place under the buttons, as on the library's page.
            if let overview = info?.overview, !overview.isEmpty {
                DetailOverview(text: overview).padding(.top, 36)
            }
        }
        .detailHeadFrame(state: headerState) {
            Backdrop(url: backdropURL, height: DetailPageMetric.heroImage)
        }
    }

    /// Rating and the status in its colour: chips of a fixed height, even when empty, so nothing below moves when
    /// the title's answer arrives.
    private var chipRail: some View {
        HStack(spacing: 8) {
            if let rating = info?.rating, rating > 0 {
                DetailChip(symbol: "star.fill", text: String(format: "%.1f", rating),
                           color: Theme.font, fill: Color.white.opacity(0.08))
            }
            if let badge = info?.badge {
                DetailChip(symbol: badge.symbol, text: badge.line, color: badge.kind.tint,
                           fill: badge.kind.tint.opacity(0.15))
            }
        }
        .transaction { $0.animation = nil }
        .frame(height: 26, alignment: .leading)
    }

    private var secondaryLine: String {
        if let line = info?.secondaryLine, !line.isEmpty { return line }
        return hit.isSeries ? String(localized: "Serie") : String(localized: "Film")
    }

    /// **A status is not a button.** What waits or loads says so instead of offering a second request.
    @ViewBuilder
    private var action: some View {
        if let info, info.primary.kind == .request || info.primary.kind == .locked {
            HStack(spacing: 16) {
                DetailPlayButton(label: info.primary.text, symbol: "plus") {
                    flow?.open(season: nil)
                }
                .disabled(!info.primary.enabled)
                .opacity(info.primary.enabled ? 1 : 0.5)
                if let quota = flow?.quota {
                    Text(verbatim: quota)
                        .font(Theme.secondLine)
                        .foregroundStyle(info.primary.kind == .locked ? Theme.warning : Theme.fontVeryQuiet)
                        .lineLimit(2)
                }
            }
        } else if let info, info.primary.kind != .hidden {
            Text(verbatim: info.primary.text)
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.formWidth, alignment: .leading)
                .padding(.vertical, 13).padding(.horizontal, 14)
                .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        }
    }

    // MARK: Seasons, cast, similar

    @ViewBuilder
    private var seasons: some View {
        let rows = info?.seasons ?? []
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                RailTitle(text: "Staffeln")
                ForEach(rows) { row in
                    Button {
                        guard row.selectable else { return }
                        flow?.open(season: row.number)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(verbatim: row.title).font(.app(size: 15, weight: .medium)).foregroundStyle(Theme.font)
                                if let episodes = row.episodes {
                                    Text(verbatim: "· \(episodes)").font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
                                }
                            }
                            HStack(spacing: 5) {
                                Image(icon: row.badge.symbol).font(.app(size: 11))
                                Text(verbatim: row.badge.line.isEmpty ? row.badge.word : row.badge.line).font(Theme.small)
                            }
                            .foregroundStyle(row.badge.kind.tint)
                            if let share = row.badge.progress {
                                ProgressBar(share: Double(share), round: true).frame(maxWidth: 240)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Theme.PressButton())
                    .accessibilityElement(children: .combine)
                    // A waiting request of this season, for an account that may decide (the core's rule, shared).
                    if let request = SeasonAdmin.waitingRequest(row, model: model) {
                        HStack(spacing: 8) {
                            SeasonAdminPill(symbol: "xmark", text: String(localized: "Ablehnen")) { decide(request, approve: false) }
                            SeasonAdminPill(symbol: "checkmark", text: String(localized: "Freigeben")) { decide(request, approve: true) }
                        }
                        .opacity(adminBusy == request ? 0.5 : 1)
                        .disabled(adminBusy == request)
                        .padding(.bottom, 4)
                    }
                }
            }
            .frame(maxWidth: Theme.readWidth, alignment: .leading)
        }
    }

    private func decide(_ request: Int64, approve: Bool) {
        adminBusy = request
        Task {
            await SeasonAdmin.decide(request, approve: approve, model: model, flow: flow)
            adminBusy = nil
        }
    }

    /// The episode list, as on the other platforms (`SeerrEpisodes`); the page's own margin already surrounds it.
    @ViewBuilder
    private var episodes: some View {
        if let flow, flow.episodeSeasonRow != nil {
            SeerrEpisodes(flow: flow, margin: 0)
                .frame(maxWidth: Theme.readWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private var cast: some View {
        let folks = info?.cast ?? []
        if !folks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                RailTitle(text: "Besetzung")
                PagingRail(margin: 0, widthJePiece: 84 + 22, imageHeight: 84) {
                    ForEach(Array(folks.prefix(12).enumerated()), id: \.offset) { _, person in
                        Button {
                            let route = PersonRoute(seerrCast: person, origin: info?.title)
                            navigator.openIt(.person(route.person, origin: route.origin, seerr: route.seerr), in: section)
                        } label: {
                            HeaderImage(name: person.name, role: person.role,
                                        image: person.image.flatMap { URL(string: $0) })
                                .padding(.trailing, 10)
                        }
                        .buttonStyle(Theme.PressButton())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var similar: some View {
        let other = flow?.similar ?? []
        if !other.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                RailTitle(text: "Ähnliche Titel")
                PagingRail(margin: 0) {
                    ForEach(other) { card in
                        Button { navigator.openIt(.seerrTitle(card.route), in: section) } label: {
                            SeerrTile(card: card, width: Theme.tileWidth)
                        }
                        .buttonStyle(Theme.PressButton())
                    }
                }
            }
        }
    }
}

// MARK: - Request sheet

/// **The request sheet** as a native window sheet (Esc cancels, Return asks): the core's `SeerrSheetInfo` laid out
/// like the iPhone's card: heading, the seasons to tick (a series) or just the title (a film), an administrator's
/// 4K / quality / folder, the quota line, "Abbrechen" and one action. A refusal from Seerr stands in the sheet in
/// its own words.
///
/// **It opens complete and nothing moves while it slides in.** The core reserves every row at its final size
/// (`openSheet`) and puts the answer in without the sheet's animation; here every height is derived from the row
/// count, never measured after the first frame, and no row is inserted.
struct MacRequestSheet: ViewModifier {
    let flow: SeerrTitleFlow?

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { flow?.sheetOpen ?? false },
                                           set: { if !$0 { flow?.close() } })) {
            if let flow {
                MacRequestSheetContent(flow: flow)
                    .presentationBackground(Theme.area)
            }
        }
    }
}

private struct MacRequestSheetContent: View {
    let flow: SeerrTitleFlow

    private static let rowHeight: CGFloat = 44
    private static let listMax: CGFloat = 264
    private static let side: CGFloat = 24

    /// How far the season list is scrolled: the soft edges show only where there is more behind them.
    @State private var scroll = ListScroll()

    private var sheet: SwiftlyCore.SeerrSheetInfo { flow.sheet }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: sheet.title)
                .font(.app(size: 20, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Theme.font)
                .lineLimit(2)
                .padding(.horizontal, Self.side)
                .padding(.top, 24)
                .padding(.bottom, sheet.rows.isEmpty ? 6 : 12)

            if !sheet.rows.isEmpty { seasonList }
            if let four = sheet.fourK {
                adminRow(label: four.label) {
                    Toggle("", isOn: Binding(get: { sheet.fourK?.on ?? false }, set: { flow.setFourK($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            if let quality = sheet.quality {
                choice(quality) { flow.chooseQuality($0.id) }
            }
            if let folder = sheet.folder {
                choice(folder) { flow.chooseFolder($0.id) }
            }

            // The line's space is always there: it fills in without moving the buttons.
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: sheet.quotaLine ?? " ")
                    .font(Theme.secondLine)
                    .foregroundStyle(sheet.quotaWarning ? Theme.warning : Theme.fontVeryQuiet)
                if let error = sheet.error {
                    Text(verbatim: error)
                        .font(Theme.secondLine)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Self.side)
            .padding(.top, 12)
            .padding(.bottom, 20)

            HStack(spacing: 10) {
                Button { flow.close() } label: { Text("Abbrechen") }
                    .buttonStyle(SecondaryButtonStyle(area: Theme.raised))
                    .keyboardShortcut(.cancelAction)
                Button { Task { await flow.confirm() } } label: { Text(verbatim: sheet.primary.text) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!sheet.primary.enabled)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Self.side)
            .padding(.bottom, Self.side)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The seasons. Their height is the row count's (capped), so it is final in the first frame; the edges fade
    /// only where the list goes on.
    private var seasonList: some View {
        let height = min(CGFloat(sheet.rows.count) * Self.rowHeight + 12, Self.listMax)
        return ScrollView {
            VStack(spacing: 0) { ForEach(sheet.rows) { row in seasonRow(row) } }
                .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .frame(height: height)
        .onScrollGeometryChange(for: ListScroll.self) { geo in
            ListScroll(above: geo.contentOffset.y > 1,
                       below: geo.contentOffset.y + geo.containerSize.height < geo.contentSize.height - 1)
        } action: { _, new in scroll = new }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(scroll.above ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
                Color.black
                LinearGradient(colors: [.black, .black.opacity(scroll.below ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
            }
        }
    }

    private func seasonRow(_ row: SwiftlyCore.SeerrSeasonRowInfo) -> some View {
        MacSeasonLine(row: row) {
            guard row.selectable else { return }
            flow.toggle(row.number)
        }
        .frame(height: Self.rowHeight)
    }

    private func adminRow(label: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(verbatim: label).font(Theme.body).foregroundStyle(Theme.font)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, Self.side)
        .frame(height: Self.rowHeight)
    }

    private func choice(_ row: SwiftlyCore.SeerrChoiceRow,
                        pick: @escaping (SwiftlyCore.SeerrChoiceOption) -> Void) -> some View {
        // A reserved row (choices still being read) stands but has no list to open.
        Menu {
            ForEach(row.options) { option in
                Button(option.name) { pick(option) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: row.label).font(Theme.body).foregroundStyle(Theme.font)
                Spacer(minLength: 8)
                Text(verbatim: row.value).font(Theme.secondLine).foregroundStyle(Theme.fontQuiet).lineLimit(1)
                Image(icon: "chevron.up.chevron.down", size: 11).font(.app(size: 11))
                    .foregroundStyle(Theme.fontVeryQuiet).accessibilityHidden(true)
            }
            .padding(.horizontal, Self.side)
            .frame(maxWidth: .infinity)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        // `.button` with a plain style lets the label take the row's full width (`.borderlessButton` shrinks it to its content).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(row.options.isEmpty)
    }
}

/// Which ends of a scrolling list have more behind them.
private struct ListScroll: Equatable {
    var above = false
    var below = false
}

/// One season of the request sheet: title and episode count, and at the end the tick (a season that can be asked
/// for) or its state in a word (already there, waiting, ...). A season that cannot be asked for stays quiet.
private struct MacSeasonLine: View {
    let row: SwiftlyCore.SeerrSeasonRowInfo
    let perform: () -> Void
    @State private var hovers = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                Text(verbatim: row.title).font(Theme.body)
                    .foregroundStyle(row.selectable ? Theme.font : Theme.fontVeryQuiet)
                if let episodes = row.episodes {
                    Text(verbatim: "· \(episodes)").font(Theme.secondLine).foregroundStyle(Theme.fontVeryQuiet)
                }
                Spacer(minLength: 8)
                if row.selectable {
                    Image(icon: row.selected ? "checkmark.square.fill" : "square", size: 17)
                        .font(.app(size: 17))
                        .foregroundStyle(row.selected ? Theme.accent : Theme.fontVeryQuiet)
                        .accessibilityHidden(true)
                } else {
                    Text(verbatim: row.badge.word.isEmpty ? row.badge.line : row.badge.word)
                        .font(Theme.secondLine).foregroundStyle(Theme.fontVeryQuiet)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: .infinity)
            .background(hovers && row.selectable ? Color.white.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
        .accessibilityLabel(Text(verbatim: row.title))
        .accessibilityAddTraits(row.selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - "Meine Anfragen" and the administrator's queue

/// One request: poster, title, who asked and what, its state, and the verbs the core allows for the row.
private struct MacRequestRow: View {
    let row: SwiftlyCore.SeerrRequestRow
    var withAsker = false
    var withdraw: (() -> Void)?
    var approve: (() -> Void)?
    var decline: (() -> Void)?
    var retry: (() -> Void)?
    /// A click on the row opens its detail card (a sheet); the verbs below keep their own clicks.
    var open: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Picture(url: row.poster.flatMap { URL(string: $0) }, corner: Theme.cornerTile)
                .frame(width: 64, height: 96)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: row.title).growing(15, .semibold).foregroundStyle(Theme.font).lineLimit(2)
                Text(verbatim: meta).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet).lineLimit(1)
                HStack(spacing: 6) {
                    Image(icon: row.badge.symbol).font(.app(size: 11, weight: .semibold)).accessibilityHidden(true)
                    Text(verbatim: row.badge.line).font(Theme.tile).lineLimit(2)
                }
                .foregroundStyle(row.badge.kind.tint)
                if let progress = row.badge.progress {
                    ProgressBar(share: Double(progress), round: true).frame(maxWidth: 260)
                }
                verbs.padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { open?() }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Anfrage öffnen")) { open?() }
    }

    @ViewBuilder private var verbs: some View {
        if row.work == .working {
            Text(verbatim: row.workText ?? "").font(Theme.tile).foregroundStyle(Theme.accent)
        } else {
            HStack(spacing: 8) {
                if row.canApprove, let approve { verb("checkmark", "Freigeben", approve) }
                if row.canDecline, let decline { verb("xmark", "Ablehnen", decline) }
                if row.canRetry, let retry { verb("arrow.clockwise", "Nochmal", retry) }
                if row.canWithdraw, let withdraw { verb("arrow.uturn.backward", "Zurückziehen", withdraw) }
            }
            if row.work == .failed, let text = row.workText {
                Text(verbatim: text).font(Theme.small).foregroundStyle(Theme.error)
            }
        }
    }

    private func verb(_ symbol: String, _ text: LocalizedStringKey, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                Image(icon: symbol).font(.app(size: 11, weight: .semibold))
                Text(text).font(Theme.tile)
            }
            .foregroundStyle(Theme.font)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.area, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(Theme.PressButton())
    }

    private var meta: String {
        let art = row.art == "tv" ? String(localized: "Serie") : String(localized: "Film")
        return [art, row.detail, withAsker ? row.requestedBy : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The request detail card as a native sheet (Esc closes it): the shared `RequestDetailView`, 480 pt wide.
private struct RequestIdentity: Identifiable { let id: Int64 }

private extension View {
    func requestDetailSheet(_ opened: Binding<Int64?>, model: AppModel, flow: SeerrAdminFlow,
                            changed: @escaping () -> Void) -> some View {
        sheet(item: Binding(get: { opened.wrappedValue.map(RequestIdentity.init) },
                            set: { opened.wrappedValue = $0?.id })) { item in
            RequestDetailView(model: model, flow: flow, id: item.id, changed: changed)
                .frame(width: 480, height: 640)
                .background(Theme.area)
                .presentationBackground(Theme.area)
        }
    }
}

/// The filter pills of a request list (the core names them and counts them).
private struct MacRequestPills: View {
    let pills: [SwiftlyCore.SeerrPillInfo]
    let select: (SwiftlyCore.RequestPill) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(pills, id: \.pill) { pill in
                Button { withAnimation(Theme.reveal) { select(pill.pill) } } label: {
                    Text(verbatim: "\(pill.title) \(pill.count)")
                        .font(Theme.tile)
                        .foregroundStyle(pill.selected ? Theme.reason : Theme.font)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(pill.selected ? Theme.font : Theme.area, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(Theme.PressButton())
                .accessibilityAddTraits(pill.selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}

/// Management page, section "Anfragen" for an account that only reads its own: what it asked Seerr for, with filter
/// pills and "Zurückziehen".
struct MacRequestsContent: View {
    let model: AppModel

    @State private var flow = SeerrRequestsFlow()
    @State private var detailFlow = SeerrAdminFlow()
    @State private var opened: Int64?

    var body: some View {
        // In a stack: `content` is empty until the first answer, and a modifier on an empty view never appears, so its `.task` never ran.
        VStack(alignment: .leading, spacing: 0) { content }
            .opacity(flow.settled ? 1 : 0)
            .animation(Theme.reveal, value: flow.settled)
            .task { await flow.load(model) }
            .requestDetailSheet($opened, model: model, flow: detailFlow) { Task { await flow.load(model) } }
            .task { await MacRequestsContent.openForProof($opened) }
    }

    /// Proof hook: `-SwiftlyOpenRequest <id>` opens that request's card once the list stands.
    static func openForProof(_ opened: Binding<Int64?>) async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: "-SwiftlyOpenRequest"), at + 1 < args.count, let id = Int64(args[at + 1]) else { return }
        try? await Task.sleep(for: .seconds(3))
        opened.wrappedValue = id
        #endif
    }

    @ViewBuilder private var content: some View {
        if let info = flow.info, info.load == .content || info.load == .loading {
            VStack(alignment: .leading, spacing: 0) {
                MacRequestPills(pills: info.pills) { flow.select($0) }
                if let quota = info.quotaSummary {
                    Text(verbatim: quota).font(Theme.secondLine).foregroundStyle(Theme.fontVeryQuiet)
                        .padding(.top, 10)
                }
                ForEach(info.rows) { row in
                    MacRequestRow(row: row, withdraw: { Task { await flow.withdraw(row.id) } }, open: { opened = row.id })
                        .transition(.opacity)
                }
                .padding(.top, 8)
            }
            .animation(Theme.reveal, value: info.rows.map(\.id))
        } else if flow.settled {
            if let error = flow.info?.error, flow.info?.load == .offline || flow.info?.load == .failed {
                EmptyState(symbol: "wifi.slash", headerLine: "Seerr antwortet gerade nicht",
                           text: LocalizedStringKey(error),
                           quietButton: ("Erneut versuchen", { Task { await flow.load(model) } }))
                    .frame(minHeight: 360)
            } else {
                EmptyState(symbol: "tray", headerLine: "Noch nichts angefragt",
                           text: "Was du bei Seerr anfragst, steht hier mit seinem Stand.")
                    .frame(minHeight: 360)
            }
        }
    }
}

/// Management page, section "Anfragen" for a manager: the queue of requests (Freigeben, Ablehnen, Nochmal).
struct MacAdminContent: View {
    let model: AppModel

    @State private var flow = SeerrAdminFlow()
    @State private var declining: SwiftlyCore.SeerrRequestRow?
    @State private var opened: Int64?

    var body: some View {
        // In a stack: `content` is empty until the first answer, and a modifier on an empty view never appears, so its `.task` never ran.
        VStack(alignment: .leading, spacing: 0) { content }
            .opacity(flow.settled ? 1 : 0)
            .animation(Theme.reveal, value: flow.settled)
            .task { await flow.load(model) }
            .requestDetailSheet($opened, model: model, flow: flow) {}
            .task { await MacRequestsContent.openForProof($opened) }
        // **"Ablehnen" asks once.** Seerr takes no reason with a decline, so the dialog says what the person sees.
        .confirmationDialog(
            Text("\"\(declining?.title ?? "")\" ablehnen?"),
            isPresented: Binding(get: { declining != nil }, set: { if !$0 { declining = nil } }),
            titleVisibility: .visible
        ) {
            Button("Ablehnen", role: .destructive) {
                if let row = declining { Task { await flow.decline(row.id) } }
                declining = nil
            }
            Button("Abbrechen", role: .cancel) { declining = nil }
        } message: {
            Text("Die Person sieht nur, dass die Anfrage abgelehnt wurde.")
        }
    }

    @ViewBuilder private var content: some View {
        if flow.settled, !flow.connected || flow.tabs.isEmpty {
            EmptyState(symbol: "tray", headerLine: "Nichts zu verwalten",
                       text: "Hier erscheint, worüber du bei Seerr entscheidest.")
                .frame(minHeight: 360)
        } else if let info = flow.queue {
            VStack(alignment: .leading, spacing: 0) {
                MacRequestPills(pills: info.pills) { flow.selectPill($0) }
                if info.rows.isEmpty {
                    EmptyState(symbol: "checkmark.circle", headerLine: "Nichts zu entscheiden",
                               text: "Neue Anfragen erscheinen hier.")
                        .frame(minHeight: 300)
                }
                ForEach(info.rows) { row in
                    MacRequestRow(row: row, withAsker: true,
                                  approve: { Task { await flow.approve(row.id) } },
                                  decline: { declining = row },
                                  retry: { Task { await flow.retry(row.id) } },
                                  open: { opened = row.id })
                        .transition(.opacity)
                }
                .padding(.top, 8)
            }
            .animation(Theme.reveal, value: info.rows.map(\.id))
        }
    }
}

// MARK: - Profile entry and management page

/// The one Profile row for requests and reports ("Verwaltung" or "Meine Anfragen"), as the core decides it
/// (`ManagementEntryFlow`). Nothing without Seerr and without administrator rights. The Mac draws the sections it has
/// (`MacManagementPage.drawn`); a role without any of them gets no row.
struct MacManagementEntry: View {
    let model: AppModel

    @State private var flow = ManagementEntryFlow()
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    var body: some View {
        // A `VStack` and not a `Group`: without an entry the content is empty, and a modifier on an empty `Group` has no
        // view to appear with, so its `.task` never ran and the row never came.
        VStack(spacing: 0) {
            if let entry = flow.entry, !MacManagementPage.drawn(entry.sections.map { "\($0.kind)" }).isEmpty {
                RowsGroup {
                    Button { navigator.openIt(.management(ManagementHubRoute(entry)), in: section) } label: {
                        ValuesRow(symbol: entry.kind == .admin ? "speedometer" : "arrow.down.circle",
                                  title: Text(verbatim: entry.title),
                                  under: entry.under.map { Text(verbatim: $0) },
                                  value: entry.kind == .admin && entry.count > 0 ? "\(entry.count)" : nil,
                                  arrow: true, hoverable: true)
                    }
                    .buttonStyle(Theme.PressRow())
                    .accessibilityIdentifier("profile-management")
                }
                .padding(.top, 18)
                .transition(.opacity)
            }
        }
        .animation(Theme.reveal, value: flow.entry)
        // Again when Seerr connects or its session turns valid, so the row comes when the answer does.
        .task(id: "\(model.seerr.connected)-\(model.seerr.carries)") { await flow.load(model) }
    }
}

/// Profile > "Verwaltung" / "Meine Anfragen": the one page behind the one row, with a tab row over the core's
/// sections (one section alone: no tab row), the same sections and words as on iPhone: Anfragen, Meldungen, Server.
struct MacManagementPage: View {
    let model: AppModel
    let route: ManagementHubRoute
    let back: () -> Void

    @State private var selected = 0
    #if DEBUG
    /// `-SwiftlyOpenManagementTab <kind>`: which tab the page opens on (running-app proofs).
    private static var debugTab: String? {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.firstIndex(of: "-SwiftlyOpenManagementTab").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
    #endif

    static func drawn(_ kinds: [String]) -> [String] { kinds.filter { ["requests", "issues", "server"].contains($0) } }

    private var sections: [ManagementHubRoute.Section] { route.sections.filter { Self.drawn([$0.kind]).count == 1 } }

    private var section: ManagementHubRoute.Section? {
        sections.indices.contains(selected) ? sections[selected] : sections.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(name: route.title, back: back)
                if sections.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { index, item in
                            Button { withAnimation(Theme.reveal) { selected = index } } label: {
                                Text(verbatim: item.count > 0 ? "\(item.title) \(item.count)" : item.title)
                                    .font(Theme.tile)
                                    .foregroundStyle(index == selected ? Theme.reason : Theme.font)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(index == selected ? Theme.font : Theme.area, in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(Theme.PressButton())
                            .accessibilityAddTraits(index == selected ? .isSelected : [])
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 18)
                }
                Group {
                    if let section {
                        switch section.kind {
                        case "requests":
                            if section.manage { MacAdminContent(model: model) } else { MacRequestsContent(model: model) }
                        case "issues": MacIssuesContent(model: model)
                        case "server": MacServerContent(model: model)
                        default: EmptyView()
                        }
                    }
                }
                .id(section?.kind)
                .padding(.top, 18)
            }
            .frame(maxWidth: Theme.readWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .pagesScroll()
        .accessibilityIdentifier("management-hub")
        #if DEBUG
        .onAppear {
            if let kind = Self.debugTab, let i = sections.firstIndex(where: { $0.kind == kind }) { selected = i }
        }
        #endif
    }
}

/// The iPhone's `ValuePill` for the Mac: a capsule with a symbol and a word, a lighter fill under the pointer.
private struct SeasonAdminPill: View {
    let symbol: String
    let text: String
    let perform: () -> Void
    @State private var hovers = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 6) {
                Image(icon: symbol, size: 11).font(.app(size: 11, weight: .medium)).accessibilityHidden(true)
                Text(verbatim: text).font(.app(size: 13, weight: .medium))
            }
            .foregroundStyle(Theme.font)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(hovers ? Theme.raised : Theme.area, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
    }
}
