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
            VStack(spacing: 0) {
                SubpageHeader(title: String(localized: "Darstellung")) { back() }
                // **Two columns when wide**, like Settings and Playback: on the left what the page
                // shows at all, on the right the genres. A narrow list in a wide window was the
                // only page that did not.
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        list { general; looks; rails }
                        list { libraryRails; genres }
                    }
                } else {
                    list { general; looks; rails; libraryRails; genres }
                }
            }
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
            .contentMargins(.horizontal, Theme.margin(wide: wide), for: .scrollContent)
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
    }

    // MARK: General

    @ViewBuilder
    private var general: some View {
        Section {
            // This row is missing on iPad on purpose: the app must not force rotation there. See `Orientierung`.
            if Orientierung.landscapeLockPossible {
                ChoiceRow(symbol: "rectangle.on.rectangle",
                          title: Text("Querformat im Player sperren"),
                          an: Binding(get: { model.landscapeFixed },
                                      set: { model.landscapeFixed = $0 }))
                    .row()
            }
            ChoiceRow(symbol: "chart.bar.fill", title: Text("Fortschritt auf Kacheln"),
                      an: Binding(get: { model.progressOnTiles },
                                  set: { model.progressOnTiles = $0 }))
                .row()
            ChoiceRow(symbol: "textformat.abc", title: Text("Alphabetische Suche in Listen"),
                      an: Binding(get: { model.alphabetShown },
                                  set: { model.alphabetShown = $0 }))
                .row()
            #if os(iOS)
            ChoiceRow(symbol: "textformat", title: Text("Titel als Logo"),
                      under: Text("Auf Film- und Serienseiten, wenn dein Server eins hat"),
                      an: $titleAsLogo)
                .row()
            #endif
        } header: {
            Category(text: "Allgemein")
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
        Section {
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
                    .growing(15, .semibold)
                    .foregroundStyle(Theme.font)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Ändern")
                    .growing(15, .semibold)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .row()
        .deleteDisabled(true)
        .accessibilityLabel(Text("Dein Look: \(look.name)"))
        .accessibilityHint(Text("Ändern"))
    }

    // MARK: Rows

    private var visibleRails: [StartRail] {
        model.startRails.filter { $0.fits(disconnected: model.newAccessDisconnected) }
    }

    private var rails: some View {
        Section {
            ForEach(visibleRails) { rail in
                ChoiceRow(symbol: rail.symbol, title: Text(rail.name),
                          an: Binding(get: { !model.startOut.contains(rail) },
                                      set: { an in
                                          if an { model.startOut.remove(rail) }
                                          else { model.startOut.insert(rail) }
                                      }))
                    .row()
            }
            .onMove { from, to in move(from: from, to: to) }
            .deleteDisabled(true)

            ChoiceRow(symbol: "square.split.2x1",
                      title: Text("Neuzugänge getrennt"),
                      under: Text("Neue Filme und neue Serien als eigene Reihen"),
                      an: Binding(get: { model.newAccessDisconnected },
                                  set: { model.newAccessDisconnected = $0 }))
                .row()
        } header: {
            Category(text: "Startseite")
        } footer: {
            Footer("Zum Umsortieren an den Griffen rechts ziehen.")
        }
    }

    /// Moving happens in the visible list. What is not visible right now (the shared
    /// row when separate, or vice versa) is appended at the end and reappears there on
    /// toggling.
    private func move(from: IndexSet, to: Int) {
        var visible = visibleRails
        visible.move(fromOffsets: from, toOffset: to)
        model.startRails = visible + model.startRails.filter { !visible.contains($0) }
    }

    // MARK: Libraries and collections

    /// **Own rows from the server**: a library or collection added to the home page
    /// with "+", in the order of this list, after the fixed rows. Remove by swiping or
    /// in edit mode.
    private var libraryRails: some View {
        Section {
            ForEach(model.startLibraries) { entryRecord in
                // From the server, so not translated.
                Text(verbatim: entryRecord.name)
                    .growing(15)
                    .foregroundStyle(Theme.font)
                    .listRowBackground(Theme.groupsArea)
            }
            .onMove { model.startLibraries.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { model.startLibraries.remove(atOffsets: $0) }

            Button { librarySelection = true } label: {
                Label("Bibliothek hinzufügen", systemImage: "plus")
                    .growing(15, .semibold)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(Theme.PressRow())
            .listRowBackground(Theme.groupsArea)
            .deleteDisabled(true)
        } header: {
            Category(text: "Bibliotheken und Sammlungen")
        }
    }

    // MARK: Genres

    /// **One list, two forms.** Which genres is set once; whether they appear as rows
    /// below or as chips on top is only the form. Before, "as chips" switched the list
    /// away and showed all the server's genres instead: two different sets behind one
    /// switch, and nobody understood why.
    private var genres: some View {
        Section {
            form("Als eigene Reihen", symbol: "rectangle.grid.1x2", an: !model.genreChips) { model.genreChips = false }
            form("Als Chips über den Reihen", symbol: "capsule", an: model.genreChips) { model.genreChips = true }

            ForEach(model.startGenres, id: \.self) { name in
                // From the server, so not translated.
                Text(verbatim: name)
                    // Body text from the ladder instead of its own number: the same size, just
                    // without the number in the caller. Before: `.system(size: 15)`.
                    // **Growing with the text, not fixed**. Size and weight are
                    // the tokens', they just follow the system font. The checkmarks and angles stay
                    // fixed: those are symbols, not text.
                    .growing(15)
                    .foregroundStyle(Theme.font)
                    .listRowBackground(Theme.groupsArea)
            }
            .onMove { model.startGenres.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { model.startGenres.remove(atOffsets: $0) }

            // A button, not a link: in edit mode a link in a list leads nowhere.
            Button { genreSelection = true } label: {
                Label("Genre hinzufügen", systemImage: "plus")
                    // List row: 15 Semibold. 15 Medium is on no ladder; there is no step between body text and list row. Before: `.system(size: 15, weight: .medium)`.
                    .growing(15, .semibold)
                    .foregroundStyle(Theme.accent)
            }
            // **This row also responds to the press.** It was the one button on the page without any feedback.
            .buttonStyle(Theme.PressRow())
            .listRowBackground(Theme.groupsArea)
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
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
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
private struct Category: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .growing(20, .semibold)
            .tracking(Theme.lockRail)
            .foregroundStyle(Theme.fontQuiet)
    }
}

private extension View {
    /// A row from our components inside Apple's list: its inner margin removed, since the row brings its own, and our ground.
    func row(selected: Bool = false) -> some View {
        listRowInsets(EdgeInsets())
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
                SubpageHeader(title: String(localized: "Genre hinzufügen")) { back() }
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
                SubpageHeader(title: String(localized: "Bibliothek hinzufügen")) { back() }
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
