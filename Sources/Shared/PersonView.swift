import JellyfinKit
import SwiftUI

/// **A person: who this is, and what exists for them.**
///
/// Tapping a cast member used to lead nowhere. Built like the detail page: a
/// banner on top with image and name at the bottom left, below it the role you
/// came through, and the biography. Then two rows: what the server has, and (only
/// with Seerr) what can be requested. Everything personal comes from the own
/// server; if it is missing there, that part is dropped.
///
/// **The banner cycles** through the backdrops of this person's titles, softly and
/// slowly. With only one, it stays.
///
/// **Nothing jumps in afterwards.** Image and name appear immediately, as they
/// come with the tap. Everything else fades in together once both requests are
/// back; until then the rows stand as placeholders in their shape. Before, birthday,
/// rows and requestable items arrived one after another and the page jerked.
struct PersonView: View {
    let model: AppModel
    let route: PersonRoute

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var inquiry: Item?
    @State private var title: [Item] = []
    /// Entries the server has in total, and how many are already fetched (not
    /// `title.count`: duplicates drop out per page).
    @State private var total = 0
    @State private var retrieved = 0
    @State private var loadsPost = false
    @State private var requestable: [SeerrHit] = []
    @State private var loaded = false
    /// **`nil` means failed.** With a silent server it used to say "Nothing else on
    /// your server with ...", a statement about a collection the page never saw.
    @State private var disrupted = false
    /// Seerr has answered; only then does "there is nothing else" hold.
    @State private var seerrReady = false
    @State private var wholeBiography = false
    @State private var offset: CGFloat = 0
    @State private var banner: [URL] = []
    @State private var bannerPoint = 0

    private var person: Person { route.person }
    private var bannerNow: URL? { banner.isEmpty ? nil : banner[bannerPoint % banner.count] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.reason.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // **One layout, not two.** On wide screens this used `HeroHeader`, the detail
                    // page header with the **square-cornered poster** on the left. For a title that
                    // is right, for a person it is not: iPhone and Mac show a round head, like the
                    // cast tiles, and the iPad alone showed a rectangle. Now all three share the
                    // same head; only its size differs.
                    hero
                    // The role comes with the tap; it waits for nothing.
                    roleRow
                        .padding(.horizontal, Theme.margin(wide: wide))
                        .padding(.top, 14)
                    biography
                        .frame(maxWidth: wide ? Theme.readWidth : .infinity,
                               alignment: .leading)
                        .padding(.horizontal, Theme.margin(wide: wide))
                    rails
                }
                // **Never wider than the screen.** A child that is wider (on the first attempt
                // a row of placeholder tiles) made the whole column that wide, and the scroll
                // view centered it: the content stood off the left edge and slid into place on
                // loading.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named("blatt"))
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
                offset = new
            }

            DetailHeader(title: person.name, offset: offset) { back() }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task(id: person.id) { await load() }
        // **The images no longer change on their own.**
        //
        // A loop ran here: the next banner every six seconds with a 1.2 second
        // crossfade while the page was open. That was the only place in the app that
        // moved without input, and section 6 of the reference rules out continuous
        // motion ("Nothing moves decoratively"). It also ignored Reduce Motion, the very
        // setting meant for that.
        //
        // It stays on the first image. Whoever wants more sees the filmography below,
        // which is what the page is for.
    }

    // MARK: Header

    /// The banner as on the detail page, image and name at the bottom left.
    private var hero: some View {
        ZStack {
            HeroImage(url: bannerNow, height: wide ? Theme.heroHeightWide : Theme.heroHeightValue)
                .id(bannerPoint)
                .transition(.opacity)
        }
        .overlay(alignment: .bottom) { HeroRunOut() }
        .overlay(alignment: .bottomLeading) {
            HStack(alignment: .bottom, spacing: 14) {
                // Round because it is a picture of a person, like the cast tiles.
                Picture(url: model.personImage(person, maxHeight: 300),
                     width: headerSize, height: headerSize, corner: headerSize / 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: person.name)
                        .font(Theme.title)
                        .tracking(Theme.lockTitle)
                        .foregroundStyle(Theme.font)
                        .lineLimit(2)
                    // **The two lines have their place from the start** and only fade in. If they
                    // were added on load they pushed the name up mid-slide.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: birthRow ?? " ")
                        Text(verbatim: place ?? " ")
                    }
                    // Birthday and place are one detail, and that is 12 on the scale, like the
                    // subline under every hero image. 13 Regular is not a level.
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontQuiet)
                    .lineLimit(1)
                    .opacity(loaded ? 1 : 0)
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.bottom, 16)
        }
    }

    /// Wide screens get a larger head: the same shape, at arm's length instead of in
    /// the hand.
    private var headerSize: CGFloat { wide ? 104 : 76 }

    private var birthRow: String? {
        guard let tag = inquiry?.daysDate, let date = Calendar.current.date(from: tag) else { return nil }
        return String(localized: "Geboren \(date.formatted(date: .long, time: .omitted))")
    }

    private var place: String? {
        guard let place = inquiry?.productionLocations?.first, !place.isEmpty else { return nil }
        return place
    }

    @ViewBuilder
    private var roleRow: some View {
        if let role = person.role, !role.isEmpty, let origin = route.origin {
            Text("\(role) in \(origin)")
                // 13 Medium is `Theme.tile`; the number stood here.
                .font(Theme.tile)
                .foregroundStyle(Theme.accent)
                .lineLimit(2)
        }
    }

    /// Four lines, then "More". A biography is information here, not the reason to
    /// open the page; it should not push the titles down before you want it.
    @ViewBuilder
    private var biography: some View {
        if let text = inquiry?.description {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: text)
                    .font(Theme.body)
                    .lineSpacing(3)
                    .foregroundStyle(Theme.fontQuiet)
                    .lineLimit(wholeBiography ? nil : 4)
                Button {
                    withAnimation(Theme.leap) { wholeBiography.toggle() }
                } label: {
                    Text(wholeBiography ? LocalizedStringKey("Weniger") : LocalizedStringKey("Mehr"))
                }
                .buttonStyle(Theme.PressButton())
                // The same "More" as in `CollapsibleText`, so the same level: 13 Medium. Semibold at
                // 13 is on no scale.
                .font(Theme.tile)
                .foregroundStyle(Theme.font)
            }
            .padding(.top, 14)
            .transition(.opacity)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var rails: some View {
        // **Nothing stood in front of `loaded`.** Opening a person showed name and
        // image and below an empty area, the same whether loading, for a person without
        // titles, or for a silent server. Three states, one picture.
        if !loaded {
            // **In the shape of the row that is coming: heading and tiles.** Before, only
            // three tiles stood there without a heading; on arrival the heading pushed
            // everything down by its height. The tiles sit in an area no wider than the
            // screen; see the column above.
            Color.clear
                .frame(height: Theme.railsHeight(wide: wide) + 30)
                .overlay(alignment: .topLeading) { RailsPlaceholder() }
                .clipped()
                .padding(.top, Theme.railsSpacing)
                .transition(.opacity)
        } else {
            if !title.isEmpty {
                Segment(title: "Auf deinem Server") {
                    LazyHStack(alignment: .top, spacing: Theme.tileSpacing) {
                        ForEach(title) { item in
                            NavigationLink(value: item) {
                                PosterTile(model: model, item: item)
                            }
                            .buttonStyle(Theme.PressButton())
                            .tileMenu(item, model: model)
                            .onAppear {
                                guard ListRules.postLoadSection(item.id, in: title, columns: 1)
                                else { return }
                                Task { await loadMore() }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                }
                .transition(.opacity)
            }
            if !requestable.isEmpty {
                Segment(title: "Kann angefragt werden") {
                    LazyHStack(alignment: .top, spacing: Theme.tileSpacing) {
                        ForEach(requestable) { t in
                            NavigationLink(value: t) {
                                SeerrTile(hit: t, width: Theme.tileWidth)
                            }
                            .buttonStyle(Theme.PressButton())
                        }
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                }
                .transition(.opacity)
            }
            if disrupted, title.isEmpty {
                // Seerr is not waited for: what the own server says is this page's main
                // answer.
                DisturbHint(model: model, retry: { Task { await load() } },
                             spacingTop: 26)
            } else if title.isEmpty, requestable.isEmpty, seerrReady {
                Text("Auf deinem Server gibt es sonst nichts mit \(person.name).")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontQuiet)
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 26)
            }
        }
    }

    // MARK: Laden

    private func load() async {
        // **The own server first, Seerr beside it.** For a filmography Seerr asks TMDB
        // first and sometimes needs seconds; the whole page used to wait for that. Now
        // the page appears once the server has answered, and "Can be requested" is added
        // below, below so nothing above shifts.
        async let ownOnes = model.titleWithNumber(person: person.id)
        let a = await model.item(id: person.id)
        async let foreignOnes = filmography(tmdb: a?.tmdbId)
        let fetched = await ownOnes
        // Failed: the page keeps what it had and says so.
        let b = fetched?.items ?? title

        // Only real landscape images cycle; if none of the titles has one, the banner
        // takes what the first offers as a substitute.
        var images = b.compactMap { model.landscapeImageReal(for: $0) }
        if images.isEmpty, let firstOne = b.first, let substitute = model.headerImageURL(for: firstOne) {
            images = [substitute]
        }

        // Everything from the server in one go, and softly. Opacity only: the column
        // keeps its width, and what is new fades in at its place.
        withAnimation(Theme.reveal) {
            inquiry = a
            disrupted = fetched == nil
            title = b
            if let fetched {
                total = fetched.total
                retrieved = AppModel.pagesSize
            }
            banner = images
            loaded = true
        }

        // **Only what is not already there.** Seerr knows what it manages itself; what
        // reached the server another way shows as open there. The name catches it.
        let ownNames = Set(b.map { $0.name.lowercased() })
        let new = await foreignOnes.filter { !$0.state.alreadyPresent && !ownNames.contains($0.title.lowercased()) }
        withAnimation(Theme.reveal) {
            requestable = new
            seerrReady = true
        }
    }

    /// The next page of the filmography; people in big series have more than one.
    private func loadMore() async {
        guard retrieved < total, !loadsPost, loaded else { return }
        loadsPost = true
        defer { loadsPost = false }
        let since = retrieved
        guard let page = await model.titleWithNumber(person: person.id, startIndex: since),
              since == retrieved else { return }
        // The page only merges its own duplicates; across pages, appending catches them
        // by id.
        title = ListRules.append(page.items, an: title)
        total = page.total
        retrieved = since + AppModel.pagesSize
    }

    private func filmography(tmdb: Int?) async -> [SeerrHit] {
        guard model.seerr.connected, let tmdb else { return [] }
        return await model.seerr.filmography(person: tmdb)
    }
}
