import JellyfinKit
import SwiftUI

/// One person: who they are and what exists with them.
/// Built like a detail page: backdrop on the right, bottom left the round head
/// with name, birth date and place, below it the role and biography, then the
/// rows: what is on the server and, with Seerr, what can be requested.
/// The banner cross-fades between the backgrounds of their titles, softly and
/// slowly. With only one, it stays.
struct PersonView: View {
    let model: AppModel
    let route: PersonRoute

    @State private var inquiry: Item?
    @State private var title: [Item] = []
    @State private var requestable: [SeerrHit] = []
    @State private var loaded = false
    /// `nil` from `title(person:)` means disturbed; otherwise a silent server would show "nothing else on your server".
    @State private var disrupted = false
    /// Seerr has answered; only then does "nothing else" hold.
    @State private var seerrReady = false
    @State private var banner: [URL] = []
    @State private var bannerPoint = 0

    private var person: Person { route.person }
    private var bannerNow: URL? { banner.isEmpty ? nil : banner[bannerPoint % banner.count] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                // Before `loaded` there was nothing here but name, picture and an empty area, while loading as well as with a silent server.
                if !loaded {
                    railsSection {
                        RailTitle(text: "Auf deinem Server")
                    } content: {
                        strip {
                            ForEach(0 ..< 5, id: \.self) { _ in
                                LoadField()
                                    .frame(width: Theme.posterWidth,
                                           height: Theme.posterHeight)
                            }
                        }
                    }
                    .transition(.opacity)
                } else if !title.isEmpty {
                    railsSection {
                        RailTitle(text: "Auf deinem Server")
                    } content: {
                        TitleStrip(model: model, items: title)
                    }
                    .transition(.opacity)
                }

                if !requestable.isEmpty {
                    railsSection {
                        RailTitle(text: "Kann angefragt werden")
                    } content: {
                        strip {
                            ForEach(requestable) { t in
                                NavigationLink(value: t) { SeerrTile(hit: t) }
                                    .buttonStyle(TileStyle())
                            }
                        }
                    }
                    .transition(.opacity)
                }

                if disrupted, title.isEmpty {
                    // Seerr is not awaited: what the own server says is the main answer of this page.
                    DisturbState(model: model, retry: { Task { await load() } })
                        .frame(height: Theme.posterHeight)
                } else if loaded, seerrReady, title.isEmpty, requestable.isEmpty {
                    Text("Auf deinem Server gibt es sonst nichts mit \(person.name).")
                        .font(Theme.tile)
                        .foregroundStyle(Theme.fontQuiet)
                        .padding(.horizontal, Theme.edgePage)
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, Theme.completionPadding)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .imageReason(url: bannerNow)
        .task(id: person.id) { await load() }
        // Seen/saved elsewhere: reload quietly (`load` keeps what was there on failure).
        .onChange(of: model.pagesRefresh) { _, _ in Task { await load() } }
        .task(id: banner.count) {
            // Fade softly, slowly enough to notice before it moves on. With one picture there is nothing to switch.
            guard banner.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                withAnimation(Theme.motion(.easeInOut(duration: 1.2))) { bannerPoint += 1 }
            }
        }
    }

    // MARK: Header

    /// No `focusSection`: the header has nothing focusable, and a registered area
    /// without a target swallows the press and drops it, which once got the cast
    /// row stuck. See `Detailrahmen.focusable`.
    private var header: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                Backdrop(url: bannerNow)
                    .id(bannerPoint)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            HeaderShadow()

            block
                .padding(.leading, Theme.edgePage)
                // Same line where the detail page has its title.
                .padding(.top, 140 + Theme.headerOffsetDetail)
        }
        .frame(height: Theme.heroHeightDetail, alignment: .topLeading)
    }

    private var block: some View {
        HStack(alignment: .top, spacing: 40) {
            // Round because it is a picture, like the cast tiles. Half the edge length is not a corner-ladder step, it is the circle itself.
            Picture(url: model.personImage(person, maxHeight: 600),
                 width: 208, height: 208, corner: 208 / 2)

            VStack(alignment: .leading, spacing: 0) {
                Text(person.name)
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                // The two lines have their place from the start and only fade in; arriving at load they would push everything below down.
                VStack(alignment: .leading, spacing: 2) {
                    Text(birthRow ?? " ")
                    Text(place ?? " ")
                }
                .font(Theme.tile)
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
                .opacity(loaded ? 1 : 0)
                .padding(.top, 10)

                if let role = person.role, !role.isEmpty, let origin = route.origin {
                    Text("\(role) in \(origin)")
                        .font(Theme.tile)
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .padding(.top, 12)
                }

                if let text = inquiry?.description {
                    Text(text)
                        .font(Theme.body)
                        .lineSpacing(Theme.descriptionPadding)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .lineLimit(3)
                        .padding(.top, 16)
                        .transition(.opacity)
                }
            }
            // Like the detail pages' header text: never beyond the backdrop.
            .frame(width: 1000, alignment: .leading)
        }
    }

    private var birthRow: String? {
        guard let tag = inquiry?.daysDate,
              let date = Calendar.current.date(from: tag) else { return nil }
        return String(localized: "Geboren \(date.formatted(date: .long, time: .omitted))")
    }

    private var place: String? {
        guard let place = inquiry?.productionLocations?.first, !place.isEmpty else { return nil }
        return place
    }

    // MARK: Loading

    private func load() async {
        // Own server first, Seerr alongside. For a filmography Seerr asks TMDB first and sometimes needs seconds; the whole page used to wait for that.
        async let ownOnes = model.title(person: person.id)
        let a = await model.item(id: person.id)
        async let foreignOnes = filmography(tmdb: a?.tmdbId)
        let fetched = await ownOnes
        // Failed: the page keeps what it had and says so.
        let b = fetched.map(ListRules.withoutDouble) ?? title

        // Only real landscape images cycle; if none of the titles has one, the banner takes what the first offers as a substitute.
        var images = b.compactMap { model.landscapeImageReal(for: $0) }
        if images.isEmpty, let firstOne = b.first, let substitute = model.headerImageURL(for: firstOne) {
            images = [substitute]
        }

        withAnimation(Theme.reveal) {
            inquiry = a
            disrupted = fetched == nil
            title = b
            banner = images
            loaded = true
        }

        // Only what is not already there. Seerr knows what it manages; what reached the server otherwise shows there as open, and the name check catches it.
        let ownNames = Set(b.map { $0.name.lowercased() })
        let new = await foreignOnes.filter { !$0.state.alreadyPresent && !ownNames.contains($0.title.lowercased()) }
        withAnimation(Theme.reveal) {
            requestable = new
            seerrReady = true
        }
    }

    private func filmography(tmdb: Int?) async -> [SeerrHit] {
        guard model.seerr.connected, let tmdb else { return [] }
        return await model.seerr.filmography(person: tmdb)
    }
}
