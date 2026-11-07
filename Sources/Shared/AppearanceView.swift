import JellyfinKit
import SwiftUI

/// **Profile -> Appearance.** How things look and what is on the home page, on one
/// page, next to "Playback".
///
/// **Apple's list for reordering, not our own.** The first attempt dragged rows
/// itself after a long press, which worked only sometimes. The list in edit mode
/// brings the handles known from the system apps, and they work every time. Tinted
/// like our cards.
struct PresentationView: View {
    let model: AppModel

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var genreSelection = false
    @State private var librarySelection = false
    #if os(iOS)
    @AppStorage("titelAlsLogo") private var titleAsLogo = false
    #endif

    var body: some View {
        ZStack(alignment: .top) {
            // The same ground as every other page. It was briefly its own (`gruppengrund`)
            // because pure black under a card was the whole distance at once; since the ground
            // is #101010 the jump is a fifth of that and needs no exception.
            Theme.reason.ignoresSafeArea()
            // **Two columns when wide**, like Settings and Playback: on the left what the page
            // shows at all, on the right the genres. A narrow list in a wide window was the
            // only page that did not.
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        list { rails; general; looks }
                        list { genres }
                    }
                } else {
                    list { rails; genres; general; looks }
                }
            }
            .fadingUnderSubpageHeader(title: String(localized: "Darstellung")) { back() }
        }
        .tint(Theme.accent)
        .navigationDestination(isPresented: $genreSelection) { GenreSelectionView(model: model) }
        .navigationDestination(isPresented: $librarySelection) { LibrarySelectionView(model: model) }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
    }

    /// Apple's list, framed like our cards: the same margin as every other page, the headings in our size.
    private func list<ContentBody: View>(@ViewBuilder _ content: () -> ContentBody) -> some View {
        List { content() }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .listSectionSpacing(Theme.groupTop)
            .contentMargins(.horizontal, Theme.margin(wide: wide), for: .scrollContent)
            .contentMargins(.top, Theme.groupTop - Theme.firstGroupTrim, for: .scrollContent)
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
    }

    // MARK: General

    @ViewBuilder
    private var general: some View {
        KitSection {
            ChoiceRow(symbol: "chart.bar", title: Text("Fortschritt auf Kacheln"),
                      an: Binding(get: { model.progressOnTiles },
                                  set: { model.progressOnTiles = $0 }))
                .row()
            ChoiceRow(symbol: "bookmark", title: Text("Merkliste"),
                      under: Text("Auf Film- und Serienseiten"),
                      an: Binding(get: { model.watchlistShown },
                                  set: { model.watchlistShown = $0 }))
                .row()
            // Only once a server has shown it has the plugin.
            if model.watchersPluginHere {
                ChoiceRow(symbol: "eye", title: Text("Gesehen von"),
                          under: Text("Zeigt auf Titelseiten, wer einen Titel gesehen hat"),
                          an: Binding(get: { model.watchersShown },
                                      set: { model.watchersShown = $0 }))
                    .row()
            }
            ChoiceRow(symbol: "textformat.abc", title: Text("Alphabet in Listen"),
                      an: Binding(get: { model.alphabetShown },
                                  set: { model.alphabetShown = $0 }))
                .row()
            #if os(iOS)
            ChoiceRow(symbol: "textformat", title: Text("Titel als Logo"),
                      under: Text("Wenn dein Server eins hat"),
                      an: $titleAsLogo)
                .row()
            #endif
        } header: {
            Category(text: "Filme und Serien")
        }
    }

    // MARK: Looks

    /// **Looks, in the flow of the page: one list with all of them.** Looks this person may
    /// wear (the original, gifts picked up or in their window) switch at once; the others
    /// are greyed with "Supporters only", and a tap shows them as a preview on the home page.
    @ViewBuilder
    private var looks: some View {
        let store = LookStore.shared
        let saved = store.saved
        KitSection {
            currentLookRow(saved.look)
            if let season = saved.look.availability, season.isActive(at: LookClock.now) {
                ChoiceRow(symbol: "sparkles", title: Text("Fledermäuse und Spinnennetz"),
                          under: Text("Bis \(LooksPanel.end(of: season)) dabei. Farbe und Icon bleiben."),
                          an: Binding(get: { store.effectsOn }, set: { store.effectsOn = $0 }))
                    .row()
            }
            if saved.look.iconName != nil {
                ChoiceRow(symbol: "app", title: Text("App-Icon"),
                          an: Binding(get: { saved.usesLookIcon != false },
                                      set: { on in
                                          var next = store.saved
                                          next.usesLookIcon = on ? nil : false
                                          _ = store.choose(next)
                                          let icon = store.palette.iconName
                                          Task { await LookIcon.apply(icon) }
                                      }))
                    .row()
            }
        } header: {
            Category(text: "Looks")
        }
    }

    /// **The look being worn, with "Change"**: the choice itself happens in the one looks
    /// panel on the home page, where the change is visible at once, like from the profile.
    private func currentLookRow(_ look: Look) -> some View {
        Button {
            #if os(iOS)
            UISelectionFeedbackGenerator().selectionChanged()
            #endif
            GiftFlow.shared.openLooksOnHome()
        } label: {
            HStack(spacing: 14) {
                LookTile(look: look, size: 32)
                Text(look.name)
                    .growing(Theme.rowTitleSize, .medium)
                    .foregroundStyle(Theme.font)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Ändern")
                    .growing(15, .semibold)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .frame(minHeight: Theme.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .row()
        .deleteDisabled(true)
        .accessibilityLabel(Text("Dein Look: \(look.name)"))
        .accessibilityHint(Text("Ändern"))
    }

    // MARK: Rows

    private var visibleEntries: [StartEntry] { model.startListed }

    /// **Fixed rows, libraries and collections in one list.** Each gets a handle, so a
    /// library can stand above "Weiterschauen" or between two fixed rows. A fixed row is
    /// switched off, a library removed by swiping; "+" adds one at the end.
    private var rails: some View {
        KitSection {
            ForEach(visibleEntries) { entry in
                switch entry {
                case .rail(let rail):
                    ChoiceRow(symbol: rail.symbol, title: Text(rail.name),
                              an: Binding(get: { !model.startOut.contains(rail) },
                                          set: { an in
                                              if an { model.startOut.remove(rail) }
                                              else { model.startOut.insert(rail) }
                                          }))
                        .row(handle: true)
                        .deleteDisabled(true)
                case .library(let id):
                    let library = model.startLibraries.first { $0.id == id }
                    // From the server, so not translated.
                    RowsLayout(symbol: library?.collection == true ? "square.stack" : "rectangle.stack",
                               title: Text(verbatim: library?.name ?? ""), under: nil, dimmedDown: false) {
                        EmptyView()
                    }
                    .row(handle: true)
                }
            }
            .onMove { from, to in move(from: from, to: to) }
            .onDelete { offsets in
                let gone = Set(offsets.map { visibleEntries[$0] })
                model.startLibraries.removeAll { gone.contains(.library($0.id)) }
            }

            ChoiceRow(symbol: "square.split.2x1",
                      title: Text("Neuzugänge getrennt"),
                      under: Text("Als eigene Reihen"),
                      an: Binding(get: { model.newAccessDisconnected },
                                  set: { model.newAccessDisconnected = $0 }))
                .row(handleSpace: true)
                .deleteDisabled(true)

            // A button, not a link: in edit mode a link in a list leads nowhere.
            Button { librarySelection = true } label: {
                HStack(spacing: 14) {
                    Image(icon: "plus", size: Theme.rowSymbolSize)
                        .font(.app(size: Theme.rowSymbolSize))
                        .frame(width: Theme.rowIconWidth)
                    Text("Bibliothek hinzufügen")
                        .growing(Theme.rowTitleSize, .medium)
                }
                    .foregroundStyle(Theme.accent)
                    .plainRow()
                    .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressRow())
            .row()
            .deleteDisabled(true)
        } header: {
            Category(text: "Startseite")
        } footer: {
            Footer("Zum Umsortieren an den Griffen rechts ziehen.")
        }
    }

    private func move(from: IndexSet, to: Int) {
        var visible = visibleEntries
        visible.move(fromOffsets: from, toOffset: to)
        model.startArrange(visible)
    }

    // MARK: Genres

    /// **One list, two forms.** Which genres is set once; whether they appear as rows
    /// below or as chips on top is only the form. Before, "as chips" switched the list
    /// away and showed all the server's genres instead: two different sets behind one
    /// switch, and nobody understood why.
    private var genres: some View {
        KitSection {
            form("Als eigene Reihen", symbol: "rectangle.grid.1x2", an: !model.genreChips) { model.genreChips = false }
            form("Als Chips über den Reihen", symbol: "capsule", an: model.genreChips) { model.genreChips = true }

            ForEach(model.startGenres, id: \.self) { name in
                // From the server, so not translated.
                Text(verbatim: name)
                    // Body text from the ladder instead of its own number: the same size, just
                    // without the number in the caller. Before: `.app(size: 15)`.
                    // **Growing with the text, not fixed**. Size and weight are
                    // the tokens', they just follow the system font. The checkmarks and angles stay
                    // fixed: those are symbols, not text.
                    .growing(Theme.rowTitleSize, .medium)
                    .foregroundStyle(Theme.font)
                    .plainRow()
                    .row()
            }
            .onMove { model.startGenres.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { model.startGenres.remove(atOffsets: $0) }

            // A button, not a link: in edit mode a link in a list leads nowhere.
            Button { genreSelection = true } label: {
                HStack(spacing: 14) {
                    Image(icon: "plus", size: Theme.rowSymbolSize)
                        .font(.app(size: Theme.rowSymbolSize))
                        .frame(width: Theme.rowIconWidth)
                    Text("Genre hinzufügen")
                        .growing(Theme.rowTitleSize, .medium)
                }
                    .foregroundStyle(Theme.accent)
                    .plainRow()
                    .contentShape(Rectangle())
            }
            // **This row also responds to the press.** It was the one button on the page without any feedback.
            .buttonStyle(Theme.PressRow())
            .row()
            .deleteDisabled(true)
        } header: {
            Category(text: "Genres")
        }
    }

    /// Like the rows above: symbol, title, checkmark, no smaller.
    private func form(_ title: LocalizedStringKey, symbol: String, an: Bool, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            RowsLayout(symbol: symbol, title: Text(title), under: nil, dimmedDown: false) {
                if an {
                    Image(icon: "checkmark", size: Theme.chevronSize)
                        .font(.app(size: Theme.chevronSize, weight: .semibold))
                        // **Selected means white and weight, not color.** The checkmark used to be teal;
                        // that is ranking among siblings, and the accent carries only state. Semibold is
                        // already the row's title.
                        .foregroundStyle(Theme.font)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .row(selected: an)
        .deleteDisabled(true)
        .accessibilityAddTraits(an ? .isSelected : [])
    }
}

/// The heading above a group, the same as `Gruppentitel` on the other settings
/// pages, without its own margin, which the list sets.
///
/// **This used to be the old version**: 11 point, uppercase, tracked. When
/// `Gruppentitel` switched to normal case at the row-heading size, this copy was
/// left behind, and exactly one of the four settings pages looked different from
/// the other three.
///
/// There is a reason for a copy at all: `Gruppentitel` brings its page margin, and
/// in a list the list sets it. The size still belongs in one place, so this reads
/// it from there instead of writing it again.
private struct KitSection<Body0: View, Head: View, Foot: View>: View {
    @ViewBuilder var content: () -> Body0
    @ViewBuilder var header: () -> Head
    @ViewBuilder var footer: () -> Foot
    var body: some View {
        Section {
            content()
        } header: {
            header()
                .textCase(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
                .listRowInsets(EdgeInsets())
        } footer: {
            footer()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .listRowInsets(EdgeInsets())
        }
    }
}

private extension KitSection where Foot == EmptyView {
    init(@ViewBuilder content: @escaping () -> Body0, @ViewBuilder header: @escaping () -> Head) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

private struct Category: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .growing(22, .bold)
            .tracking(Theme.lockSection)
            .foregroundStyle(Theme.font)
    }
}

private extension View {
    func plainRow() -> some View {
        frame(maxWidth: .infinity, minHeight: Theme.rowHeight, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
    }

    /// A row from our components inside Apple's list: its inner margin removed, since the row brings its own,
    /// the line across the full width like every other card. `handleSpace` keeps a row without a handle
    /// in line with the switches of the rows that have one; the handle column is 40 wide.
    func row(selected: Bool = false, handle: Bool = false, handleSpace: Bool = false) -> some View {
        padding(.trailing, handleSpace ? 40 : 0)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { d in d.width + (handle ? 40 : 0) }
            .listRowInsets(EdgeInsets())
            // **Selected means one step higher.** As long as the checkmark was teal, the
            // color was the whole message; in white the selected row needs its ground too,
            // otherwise it no longer stands out. `erhoeht` is the same tone the selected
            // filter chip carries: one sign for "selected", not two.
            .listRowBackground(selected ? Theme.raised : Theme.groupsArea)
    }
}

/// **Pick a genre for the home page** from those the server knows. A tap adds it
/// and goes back; what is already chosen no longer appears here.
struct GenreSelectionView: View {
    let model: AppModel

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var all: [String] = []
    @State private var loaded = false
    /// Without this flag, every network error showed "no genres on your server", a statement about the server the app could not make.
    @State private var disrupted = false

    private var free: [String] { all.filter { !model.startGenres.contains($0) } }

    var body: some View {
        ZStack(alignment: .top) {
            // The same ground as every other page. It was briefly its own (`gruppengrund`)
            // because pure black under a card was the whole distance at once; since the ground
            // is #101010 the jump is a fifth of that and needs no exception.
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if disrupted, all.isEmpty {
                            DisturbHint(model: model) { Task { await genresLoad() } }
                        } else if loaded, free.isEmpty {
                            Text(all.isEmpty ? "Auf deinem Server sind keine Genres hinterlegt."
                                              : "Alle Genres stehen schon auf der Startseite.")
                                .growing(15)
                                .foregroundStyle(Theme.fontQuiet)
                                .padding(.horizontal, Theme.margin(wide: wide))
                                .padding(.top, 8)
                        } else if !free.isEmpty {
                            SettingGroup(title: "Auf deinem Server") {
                                ForEach(Array(free.enumerated()), id: \.element) { spot, name in
                                    if spot > 0 {
                                        SheetLine()
                                    }
                                    Button {
                                        model.startGenres.append(name)
                                        back()
                                    } label: {
                                        ValueRow(symbol: "tag", title: Text(verbatim: name))
                                    }
                                    .buttonStyle(Theme.PressButton())
                                }
                            }
                        }
                    }
                    .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
            .fadingUnderSubpageHeader(title: String(localized: "Genre hinzufügen")) { back() }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task { await genresLoad() }
    }

    private func genresLoad() async {
        let fetched = await model.genres()
        disrupted = fetched == nil
        if let fetched { all = fetched }
        loaded = true
    }
}


/// **Pick a library or collection as a home row.** A tap adds it and goes back; what is already chosen no longer appears here.
struct LibrarySelectionView: View {
    let model: AppModel

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var pick: [Item] = []
    @State private var loaded = false

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if loaded, pick.isEmpty {
                            Text(model.views.isEmpty ? "Auf deinem Server gibt es keine Bibliotheken."
                                                     : "Alle Bibliotheken und Sammlungen stehen schon auf der Startseite.")
                                .growing(15)
                                .foregroundStyle(Theme.fontQuiet)
                                .padding(.horizontal, Theme.margin(wide: wide))
                                .padding(.top, 8)
                        } else if !pick.isEmpty {
                            SettingGroup(title: "Auf deinem Server") {
                                ForEach(Array(pick.enumerated()), id: \.element.id) { spot, item in
                                    if spot > 0 {
                                        SheetLine()
                                    }
                                    Button {
                                        model.startLibraries.append(StartLibrary(item))
                                        back()
                                    } label: {
                                        ValueRow(symbol: item.type == "BoxSet" ? "square.stack" : "rectangle.stack",
                                                  title: Text(verbatim: item.name))
                                    }
                                    .buttonStyle(Theme.PressButton())
                                }
                            }
                        }
                    }
                    .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
            .fadingUnderSubpageHeader(title: String(localized: "Bibliothek hinzufügen")) { back() }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task {
            pick = await model.startSelection()
            loaded = true
        }
    }
}
