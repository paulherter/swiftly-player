import JellyfinKit
import SwiftUI
import SwiftlyCore

/// One row of the season chooser: the selection row of `SelectionSheet` (check on the left, 17 pt, 60 high),
/// and for a season the own server does not have yet the label turns very quiet and the tile's capsule
/// stands at the end (`+`, `wartet`, `62 %`, `28. Nov.`).
struct SeasonPickerRow: View {
    let title: String
    var selected = false
    /// The core's badge for a season that is not on the server; `nil` for an own season.
    var badge: SwiftlyCore.SeerrBadge?
    /// A grey row that does nothing when tapped (already requested, or Seerr says it is there).
    var inert = false
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 14) {
                // The check's space is always reserved, so no label moves when the choice changes.
                Image(icon: "checkmark", size: 17)
                    .font(.app(size: 17, weight: .semibold))
                    .foregroundStyle(selected ? Theme.font : .clear)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(.app(size: 17, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.font : (badge == nil ? Theme.fontQuiet : Theme.fontVeryQuiet))
                Spacer(minLength: 0)
                if let badge {
                    SeerrBadgeCapsule(symbol: badge.symbol, word: badge.word, tint: badge.kind.tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .frame(minHeight: Theme.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var label: String {
        guard let badge else { return title }
        let word = badge.line.isEmpty ? badge.word : badge.line
        return word.isEmpty ? title : "\(title), \(word)"
    }
}

/// **"Staffel wählen", now also for a series with a single season** (when Seerr is connected). Own seasons
/// switch the page as before; the others stand greyed in the same list, and a tap on one opens the request
/// sheet with that season ticked. Without Seerr the rows are exactly the old `SelectionSheet`'s.
struct SeasonPickerSheet: View {
    @Binding var opened: Bool
    let library: [SeasonRow]
    let selectedID: String?
    /// The core's rows (all seasons Seerr knows); empty without Seerr or before it answered.
    let seerr: [SwiftlyCore.SeerrSeasonRowInfo]
    let selectLibrary: (SeasonRow) -> Void
    let request: (Int64) -> Void

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(opened: $opened) {
                SheetCategory(text: Text("Staffel wählen"))
                ScrollView {
                    VStack(spacing: 0) {
                        if seerr.isEmpty {
                            ForEach(library) { season in
                                SeasonPickerRow(title: season.name, selected: season.id == selectedID) {
                                    selectLibrary(season); opened = false
                                }
                            }
                        } else {
                            ForEach(seerr) { row in line(row) }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(contentHeight, Theme.sheetListMax))
                .scrollIndicators(.hidden)
                .sheetListFade()
                SheetLine()
                SheetCancel { opened = false }
            }
    }

    @ViewBuilder
    private func line(_ row: SwiftlyCore.SeerrSeasonRowInfo) -> some View {
        if row.onServer, let own = library.first(where: { $0.number == row.number }) {
            SeasonPickerRow(title: own.name, selected: own.id == selectedID) {
                selectLibrary(own); opened = false
            }
        } else {
            SeasonPickerRow(title: row.title, badge: row.badge, inert: !row.selectable) {
                guard row.selectable else { return }
                opened = false
                request(row.number)
            }
        }
    }
}
