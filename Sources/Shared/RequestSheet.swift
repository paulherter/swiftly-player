import SwiftUI
import SwiftlyCore

/// **The request sheet, like Seerr's own dialog** and in the app's own sheet shell: heading, the season
/// rows to tick (a series) or just the title (a film), the quota line, one text action, "Abbrechen".
///
/// **It opens complete.** Every row stands from the first frame and rides up with the card: the core
/// reads an administrator's quality and folder choices with the title page and, if they are not there
/// yet, gives the rows at their final size with an empty value. Only values and the quota line (whose
/// space is reserved) fill in later; no row is ever inserted while the card slides. A refusal from
/// Seerr is shown in the sheet in its own words, never as "session invalid".
struct RequestSheet: View {
    let flow: SeerrTitleFlow

    @State private var qualityOpen = false
    @State private var folderOpen = false

    private var sheet: SwiftlyCore.SeerrSheetInfo { flow.sheet }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(opened: Binding(get: { flow.sheetOpen }, set: { if !$0 { flow.close() } })) {
                content
            }
            .overlay { choice }
    }

    @ViewBuilder
    private var content: some View {
        SheetCategory(text: Text(verbatim: sheet.title))

        if !sheet.rows.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sheet.rows) { row in seasonRow(row) }
                }
            }
            .frame(height: min(CGFloat(sheet.rows.count) * 50, Theme.sheetListMax))
            .scrollIndicators(.hidden)
            .sheetListFade()
        }

        if let four = sheet.fourK {
            adminRow(label: four.label) {
                ToggleSwitch(an: Binding(get: { sheet.fourK?.on ?? false }, set: { flow.setFourK($0) }))
                    // **The switch must not stretch the card.** `ToggleSwitch` takes all the height it is offered
                    // for its hit area; in the card's column that was the whole screen, so the card jumped to nearly full
                    // height when the 4K row arrived and everything below it (quality, folder) arrived with a jump.
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let quality = sheet.quality {
            choiceRow(quality) { qualityOpen = true }
        }
        if let folder = sheet.folder {
            choiceRow(folder) { folderOpen = true }
        }

        // The line's space is always there: it fills in without moving the buttons.
        VStack(alignment: .leading, spacing: 6) {
            QuotaLine(text: sheet.quotaLine, warning: sheet.quotaWarning)
            if let error = sheet.error {
                Text(verbatim: error)
                    .font(Theme.small)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("request-error")
            }
        }
        .padding(.horizontal, Theme.edgeSpacing)
        .padding(.top, sheet.rows.isEmpty ? 0 : 10)
        .padding(.bottom, 14)

        SheetLine()
        Button {
            Task { await flow.confirm() }
        } label: {
            Text(verbatim: sheet.primary.text)
                .font(.app(size: 15, weight: .semibold))
                .foregroundStyle(sheet.primary.enabled ? Theme.accent : Theme.fontVeryQuiet)
                .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
        }
        .buttonStyle(Theme.PressRow())
        .disabled(!sheet.primary.enabled)
        .accessibilityIdentifier("request-confirm")
        SheetLine()
        SheetCancel { flow.close() }
    }

    private func seasonRow(_ row: SwiftlyCore.SeerrSeasonRowInfo) -> some View {
        Button {
            guard row.selectable else { return }
            flow.toggle(row.number)
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: row.title)
                    .font(.app(size: 15))
                    .foregroundStyle(row.selectable ? Theme.font : Theme.fontVeryQuiet)
                if let episodes = row.episodes {
                    Text(verbatim: "· \(episodes)").font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
                }
                Spacer(minLength: 8)
                if row.selectable {
                    Image(icon: row.selected ? "checkmark.square.fill" : "square", size: 17)
                        .font(.app(size: 17))
                        .foregroundStyle(row.selected ? Theme.accent : Theme.fontVeryQuiet)
                } else {
                    // What is already there or on its way says so in the row's end.
                    Text(verbatim: row.badge.word.isEmpty ? row.badge.line : row.badge.word)
                        .font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
                }
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
        .accessibilityLabel(Text(verbatim: row.title))
        .accessibilityAddTraits(row.selected ? .isSelected : [])
    }

    private func adminRow(label: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(verbatim: label).font(.app(size: 15)).foregroundStyle(Theme.font)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, Theme.edgeSpacing)
        .frame(minHeight: 50)
    }

    private func choiceRow(_ row: SwiftlyCore.SeerrChoiceRow, open: @escaping () -> Void) -> some View {
        // A reserved row (choices still being read) stands but does not open an empty list.
        Button { if !row.options.isEmpty { open() } } label: {
            HStack(spacing: 8) {
                Text(verbatim: row.label).font(.app(size: 15)).foregroundStyle(Theme.font)
                Spacer(minLength: 8)
                Text(verbatim: row.value).font(Theme.small).foregroundStyle(Theme.fontQuiet).lineLimit(1)
                Image(icon: "chevron.right", size: 11).font(.app(size: 11)).foregroundStyle(Theme.fontVeryQuiet)
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
    }

    /// The pick lists for quality and folder (the app's own selection sheet).
    private var choice: some View {
        ZStack {
            SelectionSheet(opened: $qualityOpen, title: "Qualität",
                           entries: sheet.quality?.options ?? [],
                           label: { $0.name }, isSelected: { $0.id == sheet.quality?.selected },
                           select: { flow.chooseQuality($0.id) })
            SelectionSheet(opened: $folderOpen, title: "Ordner",
                           entries: sheet.folder?.options ?? [],
                           label: { $0.name }, isSelected: { $0.id == sheet.folder?.selected },
                           select: { flow.chooseFolder($0.id) })
        }
    }
}
