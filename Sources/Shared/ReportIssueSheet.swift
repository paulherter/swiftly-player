import JellyfinKit
import SwiftUI
import SwiftlyCore

/// **"Problem melden"** in the app's own sheet shell: the kind (Bild, Ton, Untertitel, Sonstiges), a few words,
/// and the place it is about (season, episode and the player's position). The sheet only draws what the core's
/// report flow answers (`flow.info`): every word, the phase and whether "Melden" is live come from the core, and
/// so does its refusal, shown in Seerr's own words.
struct ReportIssueSheet: View {
    @Binding var opened: Bool
    let flow: SeerrReportFlow

    /// The words in the field. The core keeps them too (`setMessage`); this is only what the field edits.
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(opened: $opened) { content }
            .onChange(of: opened) { _, open in
                if open {
                    draft = flow.info?.message ?? ""
                } else {
                    flow.dismiss()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let info = flow.info {
            SheetCategory(text: Text(verbatim: info.heading))
            if !info.title.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: info.title)
                        .font(.app(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.font)
                        .lineLimit(1)
                    if let line = info.line {
                        Text(verbatim: line).font(Theme.small).foregroundStyle(Theme.fontQuiet)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.bottom, 10)
            }
            if info.phase == .sent {
                sent(info)
            } else {
                form(info)
            }
        }
    }

    private func sent(_ info: SwiftlyCore.ReportIssueInfo) -> some View {
        Group {
            HStack(spacing: 10) {
                Image(icon: "checkmark.circle", size: 18)
                    .font(.app(size: 18))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(verbatim: info.sentText)
                    .font(.app(size: 15))
                    .foregroundStyle(Theme.font)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .frame(minHeight: Theme.rowHeight)
            .accessibilityIdentifier("report-sent")
            SheetLine()
            Button { opened = false } label: {
                Text(verbatim: info.doneText)
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
            }
            .buttonStyle(Theme.PressRow())
        }
    }

    private func form(_ info: SwiftlyCore.ReportIssueInfo) -> some View {
        Group {
            ForEach(Array(info.kinds.enumerated()), id: \.offset) { pair in
                let row = pair.element
                Button { flow.setKind(row.kind) } label: {
                    HStack {
                        Text(verbatim: row.text).font(.app(size: 15)).foregroundStyle(Theme.font)
                        Spacer(minLength: 8)
                        if row.selected {
                            Image(icon: "checkmark", size: 14)
                                .font(.app(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, Theme.edgeSpacing)
                    .frame(minHeight: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressRow())
                .accessibilityAddTraits(row.selected ? .isSelected : [])
                .accessibilityIdentifier("report-kind-\(pair.offset)")
            }
            TextField(info.placeholder, text: $draft)
                .font(.app(size: 15))
                .focused($typing)
                .submitLabel(.done)
                .onSubmit { typing = false }
                .onChange(of: draft) { _, words in flow.setMessage(words) }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.vertical, 10)
                .accessibilityIdentifier("report-message")
            if case .failed(let text) = info.phase {
                Text(verbatim: text)
                    .font(Theme.small)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.edgeSpacing)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("report-error")
            }
            SheetLine()
            Button {
                typing = false
                Task { await flow.send() }
            } label: {
                Text(verbatim: info.sendLabel)
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(info.canSend ? Theme.accent : Theme.fontVeryQuiet)
                    .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
            }
            .buttonStyle(Theme.PressRow())
            .disabled(!info.canSend)
            .accessibilityIdentifier("report-send")
            SheetLine()
            SheetCancel(text: info.cancelText) { opened = false }
        }
    }
}
