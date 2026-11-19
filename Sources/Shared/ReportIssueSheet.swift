import JellyfinKit
import SwiftUI
import SwiftlyCore

/// **"Problem melden"** in the app's own sheet shell: the kind (Bild, Ton, Untertitel, Sonstiges), a few words,
/// and the place it is about (season, episode and the player's position, filled in by the host). The core creates
/// the issue; its refusal is shown in the sheet in Seerr's own words.
struct ReportIssueSheet: View {
    @Binding var opened: Bool
    let flow: SeerrReportFlow
    let model: AppModel

    @FocusState private var typing: Bool

    private static let kinds: [(SwiftlyCore.IssueKind, String)] = [
        (.video, String(localized: "Bild")),
        (.audio, String(localized: "Ton")),
        (.subtitles, String(localized: "Untertitel")),
        (.other, String(localized: "Sonstiges")),
    ]

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(opened: $opened) { content }
    }

    @ViewBuilder
    private var content: some View {
        SheetCategory(text: Text("Problem melden"))
        if let place = flow.place {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: place.title)
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                if let line = place.line {
                    Text(verbatim: line).font(Theme.small).foregroundStyle(Theme.fontQuiet)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.bottom, 10)
        }
        if flow.phase == .sent {
            HStack(spacing: 10) {
                Image(icon: "checkmark.circle", size: 18)
                    .font(.app(size: 18))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Gemeldet. Danke.")
                    .font(.app(size: 15))
                    .foregroundStyle(Theme.font)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .frame(minHeight: Theme.rowHeight)
            .accessibilityIdentifier("report-sent")
            SheetLine()
            Button { opened = false } label: {
                Text("Fertig")
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
            }
            .buttonStyle(Theme.PressRow())
        } else {
            ForEach(Array(Self.kinds.enumerated()), id: \.offset) { pair in
                let selected = flow.kind == pair.element.0
                Button { flow.kind = pair.element.0 } label: {
                    HStack {
                        Text(verbatim: pair.element.1).font(.app(size: 15)).foregroundStyle(Theme.font)
                        Spacer(minLength: 8)
                        if selected {
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
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("report-kind-\(pair.offset)")
            }
            TextField("Was stimmt nicht?", text: Binding(get: { flow.message }, set: { flow.message = $0 }))
                .font(.app(size: 15))
                .focused($typing)
                .submitLabel(.done)
                .onSubmit { typing = false }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.vertical, 10)
                .accessibilityIdentifier("report-message")
            if case .failed(let text) = flow.phase {
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
                Task { await flow.send(model) }
            } label: {
                Text(flow.phase == .sending ? "Wird gemeldet …" : "Melden")
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(canSend ? Theme.accent : Theme.fontVeryQuiet)
                    .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
            }
            .buttonStyle(Theme.PressRow())
            .disabled(!canSend)
            .accessibilityIdentifier("report-send")
            SheetLine()
            SheetCancel { opened = false }
        }
    }

    /// A report needs a few words; the core sends nothing empty.
    private var canSend: Bool {
        flow.phase != .sending && !flow.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
