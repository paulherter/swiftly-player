import JellyfinKit
import SwiftUI
import SwiftlyCore

/// The page of a title the own server does not have yet.
///
/// **The same page as usual, just a different action.** Hero, status row, one big button, description, cast
/// and similar titles are the series page's building blocks line by line (the spacing, the hero that
/// measures itself in the "blatt" space, the weak gradient). What deviates: the status stands in the proof
/// row, the big button asks instead of playing, and a series lists its seasons with their state.
///
/// Everything that is a decision (state words, the button, the quota, which seasons can be ticked) comes
/// from the core's `SeerrTitleScreen` through ``SeerrTitleFlow``; this view draws it.
struct SeerrDetailView: View {
    let model: AppModel
    let hit: JellyfinKit.SeerrHit

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide

    @State private var offset: CGFloat = 0
    @State private var flow: SeerrTitleFlow?
    @State private var adminBusy: Int64?

    private var info: SwiftlyCore.SeerrTitleInfo? { flow?.info }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.reason.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero

                    VStack(alignment: .leading, spacing: 14) {
                        proofRow
                        primaryBlock
                        description
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 14)

                    seasons
                    episodes
                    cast
                    similarRail
                    if flow == nil || info?.load == .offline || info?.load == .failed {
                        DisturbHint(model: model, retry: { Task { await load() } },
                                    address: model.seerr.address)
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named("blatt"))
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
                let clamped = min(max(new, 0), Theme.heroHeightValue - 110)
                if clamped != offset { offset = clamped }
            }
            .ignoresSafeArea(edges: .top)

            DetailHeader(title: title, offset: offset) { back() }

            if let flow {
                RequestSheet(flow: flow).zIndex(20)
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task { await load() }
    }

    private func load() async {
        guard model.seerr.connected else { return }
        let made = flow ?? SeerrTitleFlow(hub: model.seerr.hub, art: hit.art, tmdb: Int64(hit.id))
        flow = made
        await made.start()
        #if DEBUG
        // Proof hook (Werkzeuge/sheet-ride-run.sh): `-SwiftlyLiveOpenSheet <season|0>` opens the request sheet once the page rests.
        let args = ProcessInfo.processInfo.arguments
        if let at = args.firstIndex(of: "-SwiftlyLiveOpenSheet"), at + 1 < args.count {
            try? await Task.sleep(for: .seconds(3))
            let season = Int64(args[at + 1]) ?? 0
            made.open(season: season > 0 ? season : nil)
        }
        #endif
    }

    // MARK: Parts

    private var title: String {
        guard let name = info?.title, !name.isEmpty else { return hit.title }
        return name
    }

    private var hero: some View {
        HeroImage(url: info?.backdrop.flatMap { URL(string: $0) } ?? hit.backdrop())
            .overlay(alignment: .bottom) { HeroRunOut() }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: title)
                        .font(Theme.title)
                        .tracking(Theme.lockTitle)
                        .foregroundStyle(Theme.font)
                    Text(verbatim: secondaryLine)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(1)
                }
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.bottom, 16)
            }
    }

    private var secondaryLine: String {
        if let line = info?.secondaryLine, !line.isEmpty { return line }
        return hit.isSeries ? String(localized: "Serie") : String(localized: "Film")
    }

    /// The state in the app's proof row (the same row as "Direct Play" there), then the stars.
    private var proofRow: some View {
        ProofRow(rating: info?.rating.flatMap { $0 > 0 ? $0 : nil },
                 own: info?.badge.map { (symbol: $0.symbol, word: $0.line, color: $0.kind.tint) })
            .animation(Theme.reveal, value: info?.badge)
    }

    /// **A status is not a button.** What waits or loads says so instead of offering a second request; what is
    /// locked (limit reached) stays a muted button with the reason right under it.
    @ViewBuilder
    private var primaryBlock: some View {
        if let info, info.primary.kind != .hidden {
            VStack(alignment: .leading, spacing: 9) {
                Button { flow?.open(season: nil) } label: {
                    HStack(spacing: 8) {
                        if info.primary.kind == .request {
                            Image(icon: "plus", size: 15).font(.app(size: 15, weight: .semibold))
                        } else if info.primary.kind == .requested {
                            Image(icon: "checkmark", size: 15).font(.app(size: 15, weight: .semibold))
                        }
                        Text(verbatim: info.primary.text)
                    }
                }
                .buttonStyle(PrimaryButtonStyle(stretches: true))
                .disabled(info.primary.kind != .request || !info.primary.enabled)
                .accessibilityIdentifier("seerr-primary")
                if info.primary.kind == .request || info.primary.kind == .locked {
                    QuotaLine(text: flow?.quota, warning: info.primary.kind == .locked)
                }
            }
            .animation(Theme.leap, value: info.primary.kind)
        }
    }

    @ViewBuilder
    private var description: some View {
        if let text = info?.overview, !text.isEmpty {
            CollapsibleText(text: text)
        }
    }

    // MARK: Seasons

    /// The seasons with their state: a line of words, and a thin progress bar while one is on its way.
    @ViewBuilder
    private var seasons: some View {
        let rows = info?.seasons ?? []
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Staffeln")
                    .font(Theme.section).tracking(Theme.lockSection)
                    .foregroundStyle(Theme.font)
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(rows.enumerated()), id: \.element.number) { index, row in
                    if index > 0 { SheetLine() }
                    seasonStatus(row)
                }
            }
            .padding(.top, 28)
        }
    }

    private func seasonStatus(_ row: SwiftlyCore.SeerrSeasonRowInfo) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                guard row.selectable else { return }
                flow?.open(season: row.number)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(verbatim: row.title).font(.app(size: 15, weight: .medium)).foregroundStyle(Theme.font)
                        if let episodes = row.episodes {
                            Text(verbatim: "· \(episodes)").font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
                        }
                    }
                    HStack(spacing: 5) {
                        Image(icon: row.badge.symbol, size: 11).font(.app(size: 11))
                        Text(verbatim: row.badge.line.isEmpty ? row.badge.word : row.badge.line).font(Theme.small)
                    }
                    .foregroundStyle(row.badge.kind.tint)
                    if let share = row.badge.progress {
                        ProgressBar(share: Double(share), round: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressRow())
            .accessibilityElement(children: .combine)

            if let request = SeasonAdmin.waitingRequest(row, model: model) {
                HStack(spacing: 8) {
                    ValuePill(symbol: "xmark", text: String(localized: "Ablehnen")) { decide(request, approve: false) }
                    ValuePill(symbol: "checkmark", text: String(localized: "Freigeben")) { decide(request, approve: true) }
                }
                .opacity(adminBusy == request ? 0.5 : 1)
                .disabled(adminBusy == request)
            }
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.vertical, 12)
    }

    private func decide(_ request: Int64, approve: Bool) {
        adminBusy = request
        Task {
            await SeasonAdmin.decide(request, approve: approve, model: model, flow: flow)
            adminBusy = nil
        }
    }

    // MARK: Episodes

    /// **The episodes of a title the server does not have, like a library page lists them** (`SeerrEpisodes`, the
    /// same view the Mac and the TV draw; the season rule is the core's).
    @ViewBuilder
    private var episodes: some View {
        if let flow, flow.episodeSeasonRow != nil {
            SeerrEpisodes(flow: flow, margin: Theme.margin(wide: wide))
                .padding(.top, 28)
        }
    }

    // MARK: Cast and similar

    /// Word for word as `ItemDetailView.cast`, only with TMDB's heads, limit twelve. A tap opens the person page with
    /// the TMDB id (`PersonRoute(seerrCast:)`), like a library cast tile.
    @ViewBuilder
    private var cast: some View {
        let folks = info?.cast ?? []
        if !folks.isEmpty {
            Segment(title: "Besetzung") {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(folks.prefix(12).enumerated()), id: \.offset) { _, person in
                        NavigationLink(value: PersonRoute(seerrCast: person, origin: info?.title)) {
                            CastTile(image: person.image.flatMap { URL(string: $0) }, name: person.name, role: person.role)
                        }
                        .buttonStyle(Theme.PressButton())
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
            }
        }
    }

    @ViewBuilder
    private var similarRail: some View {
        let other = info?.similar ?? []
        if !other.isEmpty {
            Segment(title: "Ähnliche Titel") {
                HStack(alignment: .top, spacing: Theme.tileSpacing) {
                    ForEach(other) { card in
                        NavigationLink(value: card.route) {
                            SeerrTile(card: card, width: Theme.tileWidth)
                        }
                        .buttonStyle(Theme.PressButton())
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
            }
        }
    }
}
