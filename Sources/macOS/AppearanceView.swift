import JellyfinKit
import SwiftUI

/// **Profile → Appearance.** How things look and what is on the home page,
/// on one page next to "Wiedergabe", as on iPhone and iPad.
///
/// It briefly lived under Settings because Command-comma promises everything
/// there. That put the same page in a different place than on every other
/// device and made the categories disappear from the profile. Settings keep
/// what concerns the device.
///
/// **Dragging uses the handle on the right.** The first attempt put Apple's
/// `List` in the card: it brought its own top edge, so the card was square at
/// the top and round at the bottom, its rows did not fill the width, and
/// nothing could be dragged: without edit mode a `List` does not react on the
/// Mac. Now these are ordinary rows in our card: a click toggles, the handle
/// on the right drags, and a line shows where the row will land.
///
/// Two columns as in Settings: on the left what the page shows at all, on the
/// right the genres.
struct PresentationView: View {
    let model: AppModel
    let back: () -> Void

    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    /// What the dragged row is currently hovering over; the line goes there.
    @State private var over: String?
    @AppStorage("titelAlsLogo") private var titleAsLogo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: "Darstellung", back: back)

                HStack(alignment: .top, spacing: Theme.edgeSpacing * 2) {
                    VStack(alignment: .leading, spacing: 0) { general; rails }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) { libraryRails; genres }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: Theme.settingWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .pagesScroll()
    }

    // MARK: General

    /// "Lock landscape in player" does **not** exist here: a window has no
    /// orientation to lock. That is not an omission but a setting with no
    /// counterpart.
    private var general: some View {
        SettingGroup(title: "Allgemein") {
            ToggleRow(symbol: "chart.bar.fill",
                          title: Text("Fortschritt auf Kacheln"),
                          an: Binding(get: { model.progressOnTiles },
                                      set: { model.progressOnTiles = $0 }))
            ToggleRow(symbol: "textformat",
                          title: Text("Titel als Logo"),
                          under: Text("Auf Film- und Serienseiten, wenn dein Server eins hat"),
                          an: $titleAsLogo)
        }
    }

    // MARK: Rows

    private var visibleRails: [StartRail] {
        model.startRails.filter { $0.fits(disconnected: model.newAccessDisconnected) }
    }

    private var rails: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingGroup(title: "Reihen") {
                ForEach(Array(visibleRails.enumerated()), id: \.element) { spot, rail in
                    if spot > 0 { SheetLine().padding(.leading, Theme.separatorInsetCard) }
                    ChoiceRow(symbol: rail.symbol, title: Text(rail.name),
                              an: Binding(get: { !model.startOut.contains(rail) },
                                          set: { an in
                                              if an { model.startOut.remove(rail) }
                                              else { model.startOut.insert(rail) }
                                          }))
                        .dragBar(rail.rawValue, over: $over) { source in
                            railStore(source, on: rail)
                        }
                }
            }
            Footer(text: "Zum Umsortieren eine Zeile ziehen.")

            SettingGroup(title: "Neuzugänge") {
                ToggleRow(symbol: "square.split.2x1",
                              title: Text("Neuzugänge getrennt"),
                              under: Text("Neue Filme und neue Serien als eigene Reihen"),
                              an: Binding(get: { model.newAccessDisconnected },
                                          set: { model.newAccessDisconnected = $0 }))
            }
        }
    }

    /// The dragged row moves to the position of the one it lands on.
    ///
    /// **The target position is looked up after removal, not before.** It used to
    /// be fixed before the row left the list, and when dragging downward the
    /// removal shifts everything by one. The row ended up **behind** the one it
    /// was dropped on: A onto C gave B · C · A instead of B · A · C. Upward it was
    /// fine because nothing before the target shifts, which is why this kind of
    /// bug is easy to miss when trying it out.
    private func railStore(_ source: String, on target: StartRail) {
        guard let moved = StartRail(rawValue: source), moved != target else { return }
        var visible = visibleRails
        guard let from = visible.firstIndex(of: moved) else { return }
        withAnimation(Theme.reveal) {
            visible.remove(at: from)
            let spot = visible.firstIndex(of: target) ?? visible.endIndex
            visible.insert(moved, at: spot)
            model.startRails = visible + model.startRails.filter { !visible.contains($0) }
        }
    }


    // MARK: Libraries and collections

    /// Custom rows from the server, in the order of this list, after the fixed
    /// rows. As with genres: drag the handle, cross to remove.
    private var libraryRails: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingGroup(title: "Bibliotheken und Sammlungen") {
                ForEach(model.startLibraries) { entryRecord in
                    GenreRow(name: entryRecord.name, symbol: entryRecord.collection ? "square.stack" : "rectangle.stack") {
                        withAnimation(Theme.reveal) {
                            model.startLibraries.removeAll { $0.id == entryRecord.id }
                        }
                    }
                    .dragBar("bibliothek:" + entryRecord.id, over: $over) { source in
                        libraryStore(source, on: entryRecord.id)
                    }
                    SheetLine().padding(.leading, Theme.separatorInsetCard)
                }
                Button { navigator.openIt(.librarySelection, in: section) } label: {
                    ValuesRow(symbol: "plus", title: Text("Bibliothek hinzufügen"),
                               accent: true, arrow: true, hoverable: true)
                }
                .buttonStyle(Theme.PressRow())
            }
        }
        .padding(.bottom, 22)
    }

    private func libraryStore(_ source: String, on target: String) {
        let moved = String(source.dropFirst("bibliothek:".count))
        guard moved != target,
              let from = model.startLibraries.firstIndex(where: { $0.id == moved }),
              let to = model.startLibraries.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(Theme.reveal) {
            let entryRecord = model.startLibraries.remove(at: from)
            model.startLibraries.insert(entryRecord, at: to)
        }
    }

    // MARK: Genres

    /// **One list, two forms.** Which genres is set once; whether they appear as
    /// rows below or as chips above is only the form. Before, "as chips" hid the
    /// list and showed all genres of the server instead: two different sets behind
    /// one switch, and nobody understood why.
    private var genres: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingGroup(title: "Genres") {
                form("Als eigene Reihen", symbol: "rectangle.grid.1x2", an: !model.genreChips) { model.genreChips = false }
                SheetLine().padding(.leading, Theme.separatorInsetCard)
                form("Als Chips über den Reihen", symbol: "capsule", an: model.genreChips) { model.genreChips = true }

                ForEach(model.startGenres, id: \.self) { name in
                    SheetLine().padding(.leading, Theme.separatorInsetCard)
                    GenreRow(name: name) {
                        withAnimation(Theme.reveal) {
                            model.startGenres.removeAll { $0 == name }
                        }
                    }
                    .dragBar("genre:" + name, over: $over) { source in
                        genreStore(source, on: name)
                    }
                }

                SheetLine()
                Button { navigator.openIt(.genreSelection, in: section) } label: {
                    ValuesRow(symbol: "plus", title: Text("Genre hinzufügen"),
                               accent: true, arrow: true, hoverable: true)
                }
                .buttonStyle(Theme.PressRow())
            }
        }
    }

    private func genreStore(_ source: String, on target: String) {
        let moved = String(source.dropFirst("genre:".count))
        guard moved != target,
              let from = model.startGenres.firstIndex(of: moved),
              let to = model.startGenres.firstIndex(of: target) else { return }
        withAnimation(Theme.reveal) {
            model.startGenres.remove(at: from)
            model.startGenres.insert(moved, at: to)
        }
    }

    /// Like the rows above: icon, title, checkmark, not smaller.
    private func form(_ title: LocalizedStringKey, symbol: String, an: Bool,
                      select: @escaping () -> Void) -> some View {
        ValuesRow(symbol: symbol, title: Text(title), action: select, checkmark: an)
            .accessibilityAddTraits(an ? .isSelected : [])
    }

}

/// A chosen genre: the name, with a cross on the right to remove it.
///
/// **No swipe to delete.** That is a finger gesture; with a pointer there is
/// a button, as everywhere else in the window.
private struct GenreRow: View {
    let name: String
    var symbol = "tag"
    let remove: () -> Void

    @State private var hovers = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .frame(width: 20)
                .accessibilityHidden(true)
            // From the server, so not translated.
            Text(verbatim: name)
                .font(Theme.listTitle)
                .foregroundStyle(Theme.font)
                // Genre names come from the server; the row has a fixed minimum height, so
                // a line break would be cut off inside it.
                .lineLimit(1)
            Spacer(minLength: 12)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(Theme.small.weight(.semibold))
                    .foregroundStyle(Theme.fontQuiet)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressRow())
            .opacity(hovers ? 1 : 0.35)
            .accessibilityLabel(Text("Entfernen"))
            Handle()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(hovers ? Theme.hoverArea : .clear)
        .contentShape(Rectangle())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
    }
}

/// A row with a switch and a handle, **deliberately not a button.**
///
/// A `Button` and a drag gesture fight over the same click on the Mac: with
/// `ToggleRow` the row could not be moved. A tap recognizer does not
/// fight, and the row toggles just the same.
private struct ChoiceRow: View {
    let symbol: String
    let title: Text
    @Binding var an: Bool

    @State private var hovers = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .frame(width: 20)
            title
                .font(Theme.listTitle)
                .foregroundStyle(Theme.font)
            Spacer(minLength: 12)
            ToggleSwitch(an: an)
            Handle()
        }
        .padding(.horizontal, 12)
        // **The whole row, not just its content.** In Apple's list the hover surface
        // was only as wide as the text and did not fill the card.
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(hovers ? Theme.hoverArea : .clear)
        .contentShape(Rectangle())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .onTapGesture { an.toggle() }
        .accessibilityRepresentation { Toggle(isOn: $an) { title } }
    }
}

/// The three bars that say: this can be moved.
private struct Handle: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(Theme.tile)
            .foregroundStyle(Theme.fontVeryQuiet)
            .frame(width: 22, height: 28)
            .accessibilityHidden(true)
    }
}

private extension View {
    /// **Drag and drop on a row.**
    ///
    /// The whole row is dragged and dropped onto another; the dragged one takes
    /// its place. The line above shows beforehand where it goes.
    func dragBar(_ identifier: String, over: Binding<String?>,
                 stash: @escaping (String) -> Void) -> some View {
        draggable(identifier)
            .overlay(alignment: .top) {
                if over.wrappedValue == identifier {
                    Rectangle().fill(Theme.accent).frame(height: 2)
                }
            }
            .dropDestination(for: String.self) { values, _ in
                over.wrappedValue = nil
                guard let source = values.first else { return false }
                stash(source)
                return true
            } isTargeted: { an in
                if an { over.wrappedValue = identifier }
                else if over.wrappedValue == identifier { over.wrappedValue = nil }
            }
    }
}

/// The small sentence under a card: an explanation, not a title.
private struct Footer: View {
    let text: LocalizedStringKey
    var body: some View {
        // 12 in `schriftSehrLeise`. "White 40%" gives 3.84:1 by calculation, too
        // little for text and explicitly forbidden.
        Text(text)
            .font(Theme.small)
            .foregroundStyle(Theme.fontVeryQuiet)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            .padding(.horizontal, 2)
    }
}

/// **Choose a genre for the home page** from those the server knows. A click
/// adds it and goes back; what is already chosen is not listed here anymore.
struct GenreSelectionView: View {
    let model: AppModel
    let back: () -> Void

    @State private var all: [String] = []
    @State private var loaded = false
    /// Otherwise the page claims on every network error that the server has no
    /// genres, a statement it could not have made.
    @State private var disrupted = false

    private var free: [String] { all.filter { !model.startGenres.contains($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: "Genre hinzufügen", back: back)

                if disrupted, all.isEmpty {
                    DisturbHint(model: model, retry: { Task { await genresLoad() } },
                                 spacingTop: 22)
                } else if loaded, free.isEmpty {
                    Text(all.isEmpty ? "Auf deinem Server sind keine Genres hinterlegt."
                                      : "Alle Genres stehen schon auf der Startseite.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.fontQuiet)
                        .padding(.top, 22)
                } else if !free.isEmpty {
                    SettingGroup(title: "Auf deinem Server") {
                        ForEach(Array(free.enumerated()), id: \.element) { spot, name in
                            if spot > 0 { SheetLine().padding(.leading, Theme.separatorInsetCard) }
                            Button {
                                model.startGenres.append(name)
                                back()
                            } label: {
                                ValuesRow(symbol: "tag", title: Text(verbatim: name),
                                           hoverable: true)
                            }
                            .buttonStyle(Theme.PressRow())
                        }
                    }
                }
            }
            .frame(maxWidth: Theme.readWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .pagesScroll()
        .task { await genresLoad() }
    }

    private func genresLoad() async {
        let fetched = await model.genres()
        disrupted = fetched == nil
        if let fetched { all = fetched }
        loaded = true
    }
}


/// **Choose a library or collection as a home row.** A click adds it and goes
/// back; what is already chosen is not listed here anymore.
struct LibrarySelectionView: View {
    let model: AppModel
    let back: () -> Void

    @State private var pick: [Item] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: "Bibliothek hinzufügen", back: back)

                if loaded, pick.isEmpty {
                    Text(model.views.isEmpty ? "Auf deinem Server gibt es keine Bibliotheken."
                                             : "Alle Bibliotheken und Sammlungen stehen schon auf der Startseite.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.fontQuiet)
                        .padding(.top, 22)
                } else if !pick.isEmpty {
                    SettingGroup(title: "Auf deinem Server") {
                        ForEach(Array(pick.enumerated()), id: \.element.id) { spot, item in
                            if spot > 0 { SheetLine().padding(.leading, Theme.separatorInsetCard) }
                            Button {
                                model.startLibraries.append(StartLibrary(item))
                                back()
                            } label: {
                                ValuesRow(symbol: item.type == "BoxSet" ? "square.stack" : "rectangle.stack",
                                           title: Text(verbatim: item.name), hoverable: true)
                            }
                            .buttonStyle(Theme.PressRow())
                        }
                    }
                }
            }
            .frame(maxWidth: Theme.readWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .pagesScroll()
        .task {
            pick = await model.startSelection()
            loaded = true
        }
    }
}
