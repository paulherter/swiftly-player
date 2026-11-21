import JellyfinKit
import SwiftUI
import SwiftlyCore

/// **"Vom Server löschen"** in the app's own sheet shell. Confirm: one row per version (tick to delete, size
/// where known). Then the core's steps (Dateien gelöscht, In Seerr entfernt, Jellyfin liest neu ein, Prüfen), each
/// with its state; a step that hangs says why and "Nochmal versuchen" resumes at that step only.
struct DeleteFlowSheet: View {
    @Binding var opened: Bool
    let flow: SeerrDeleteFlow
    /// The title is gone from the library: the page behind goes back.
    let finished: () -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(opened: $opened) { content }
    }

    @ViewBuilder
    private var content: some View {
        if let info = flow.info {
            switch info.phase {
            case .confirm: confirm(info)
            case .running, .failed, .done: steps(info)
            }
        }
    }

    // MARK: Confirm

    @ViewBuilder
    private func confirm(_ info: SwiftlyCore.SeerrDeleteInfo) -> some View {
        SheetCategory(text: Text("Vom Server löschen"))
        Text(verbatim: info.title)
            .font(.app(size: 15, weight: .semibold))
            .foregroundStyle(Theme.font)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
        Text("Die Dateien werden gelöscht. Das lässt sich nicht zurücknehmen.")
            .font(Theme.small)
            .foregroundStyle(Theme.fontQuiet)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, 4)
            .padding(.bottom, 10)
        ForEach(info.versions) { version in
            let on = version.chosen
            Button { flow.toggle(version.is4k) } label: {
                HStack(spacing: 10) {
                    Image(icon: on ? "checkmark.square.fill" : "square", size: 17)
                        .font(.app(size: 17))
                        .foregroundStyle(on ? Theme.accent : Theme.fontVeryQuiet)
                        .accessibilityHidden(true)
                    Text(verbatim: version.label).font(.app(size: 15)).foregroundStyle(Theme.font)
                    Spacer(minLength: 8)
                    if let size = version.size {
                        Text(verbatim: size).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
                    }
                }
                .padding(.horizontal, Theme.edgeSpacing)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressRow())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityIdentifier("delete-version-\(version.label)")
        }
        SheetLine()
        Button {
            Task { await flow.run() }
        } label: {
            Text("Löschen (Titel vom Server)")
                .font(.app(size: 15, weight: .semibold))
                .foregroundStyle(flow.anyChosen ? Theme.warning : Theme.fontVeryQuiet)
                .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
        }
        .buttonStyle(Theme.PressRow())
        .disabled(!flow.anyChosen)
        .accessibilityIdentifier("delete-confirm")
        SheetLine()
        SheetCancel { opened = false }
    }

    // MARK: Steps

    @ViewBuilder
    private func steps(_ info: SwiftlyCore.SeerrDeleteInfo) -> some View {
        SheetCategory(text: Text(verbatim: info.headline ?? info.title))
        ForEach(info.steps) { step in
            HStack(spacing: 12) {
                mark(step.state)
                    .frame(width: 22, height: 22)
                Text(verbatim: step.label)
                    .font(.app(size: 15))
                    .foregroundStyle(step.state == .pending ? Theme.fontVeryQuiet : Theme.font)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .frame(minHeight: 46)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: step.label))
            .accessibilityValue(Text(verbatim: word(step.state)))
            .accessibilityIdentifier("delete-step-\(step.kind)")
        }
        if let error = info.error {
            Text(verbatim: error)
                .font(Theme.small)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.vertical, 10)
                .accessibilityIdentifier("delete-error")
        }
        if info.phase != .running {
            SheetLine()
            if info.canRetry {
                Button { Task { await flow.retry() } } label: {
                    Text("Nochmal versuchen")
                        .font(.app(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
                }
                .buttonStyle(Theme.PressRow())
                .accessibilityIdentifier("delete-retry")
                SheetLine()
            }
            Button {
                opened = false
                if info.phase == .done { finished() }
            } label: {
                Text("Schließen")
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.fontQuiet)
                    .frame(maxWidth: .infinity, minHeight: Theme.rowHeight)
            }
            .buttonStyle(Theme.PressRow())
            .accessibilityIdentifier("delete-close")
        }
    }

    @ViewBuilder
    private func mark(_ state: SwiftlyCore.StepState) -> some View {
        switch state {
        case .done:
            Image(icon: "checkmark.circle.fill", size: 19).font(.app(size: 19)).foregroundStyle(Theme.accent)
        case .running:
            ProgressView().controlSize(.small)
        case .failed:
            Image(icon: "exclamationmark.triangle.fill", size: 18).font(.app(size: 18)).foregroundStyle(Theme.warning)
        case .pending:
            Image(icon: "circle", size: 17).font(.app(size: 17)).foregroundStyle(Theme.fontVeryQuiet)
        }
    }

    /// What VoiceOver and the tests read for a step's state.
    private func word(_ state: SwiftlyCore.StepState) -> String {
        switch state {
        case .done: "done"
        case .running: "running"
        case .failed: "failed"
        case .pending: "pending"
        }
    }
}
