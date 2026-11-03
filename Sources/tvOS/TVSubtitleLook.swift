import JellyfinKit
import SwiftUI

/// **Settings > Languages > "Subtitle look" (Apple TV).** An own full page: the picture on
/// the left and standing, the rows on the right and scrolling. Layout and numbers:
/// `Notizen/Mehrserver/UNTERTITEL-ENTWURF.md`.
///
/// There is no pointer and four targets in a row are too small at three meters, so Size,
/// Colour, Outline and Position are rows that unfold their steps below them. **Focus on a
/// step shows it in the picture**, a press takes it and folds the row, Back folds it and
/// the picture jumps back to the saved value. Only one row is open at a time.
struct TVSubtitleLookView: View {
    let model: AppModel
    let close: () -> Void

    private enum Part: Hashable { case size, colour, outline, position }
    private enum Place: Hashable {
        case row(Part)
        case step(Part, Int)
        case shadow, background, file, reset, undo
    }

    /// One step of an unfolded row: its words and what it does to a look.
    private struct Step {
        let name: String
        var swatch: Color?
        let apply: (inout SubtitleLook) -> Void
        let isCurrent: (SubtitleLook) -> Bool
    }

    @State private var opened: Part?
    /// The look under the focused step; the picture shows it instead of the saved one.
    @State private var trial: SubtitleLook?
    @State private var undo: SubtitleLook?
    @State private var undoTimer: Task<Void, Never>?
    @FocusState private var focus: Place?

    private var look: SubtitleLook { model.subtitleLook }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.reason.ignoresSafeArea()
            HStack(alignment: .top, spacing: 60) {
                left
                    .frame(width: 1000, alignment: .topLeading)
                right
                    .frame(width: 700)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
            }
            .padding(.horizontal, Theme.edgePage)
            .padding(.vertical, Theme.edgeTop)
        }
        .ignoresSafeArea(edges: .horizontal)
        .defaultFocus($focus, .row(.size))
        .onChange(of: focus) { _, new in
            if case let .step(group, index) = new {
                var next = look
                steps(group)[index].apply(&next)
                trial = next
            } else {
                trial = nil
            }
        }
        .onExitCommand {
            if let group = opened {
                focus = .row(group)
                withAnimation(Theme.motion(.easeInOut(duration: TVSpec.valueExpandDuration))) { opened = nil }
            } else {
                close()
            }
        }
        .onDisappear { undoTimer?.cancel() }
    }

    // MARK: Left

    private var left: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Untertitel")
                .font(.app(size: 44, weight: .bold))
                .foregroundStyle(Theme.font)
            SubtitlePreview(look: trial ?? look, cornerRadius: 24)
            VStack(alignment: .leading, spacing: 8) {
                if VLCPlayerView.playersOpen {
                    Text("Gilt ab dem nächsten Video.")
                }
                Text("Gilt für Untertitel aus Text. Die von Blu-rays sind Bilder und bleiben, wie sie sind.")
            }
            .font(.app(size: 24))
            .foregroundStyle(Theme.fontVeryQuiet)
        }
    }

    // MARK: Right

    private var right: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                groupTitle("Aussehen")
                valueRow("Größe", .size, value: look.size.name)
                SeparatorLine()
                valueRow("Farbe", .colour, value: look.colour.name)
                SeparatorLine()
                valueRow("Rand", .outline, value: look.outline.name)
                SeparatorLine()
                ToggleRow(title: "Schatten", an: look.shadow) { set { $0.shadow.toggle() } }
                    .focused($focus, equals: .shadow)
                SeparatorLine()
                ToggleRow(title: "Dunkler Hintergrund", an: look.background) { set { $0.background.toggle() } }
                    .focused($focus, equals: .background)
                SeparatorLine()
                valueRow("Position", .position, value: look.position.name)

                groupTitle("Aufwendige Untertitel").padding(.top, 40)
                fileSwitch

                SeparatorLine().padding(.top, 20)
                ActionRow(title: "Zurücksetzen", action: reset)
                    .disabled(look.isStandard)
                    .focused($focus, equals: .reset)
                if undo != nil {
                    ActionRow(title: "Zurückgesetzt · Rückgängig", action: takeBack)
                        .focused($focus, equals: .undo)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 80)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func groupTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.app(size: 30, weight: .semibold))
            .foregroundStyle(Theme.fontVeryQuiet)
            .padding(.leading, TVSpec.rowInset)
            .padding(.bottom, 16)
    }

    /// The file switch with its line under it: the line says what applies now.
    private var fileSwitch: some View {
        let adjustable = model.fileStyleAdjustable
        return VStack(alignment: .leading, spacing: 0) {
            ToggleRow(title: "Gestaltung aus der Datei übernehmen",
                      an: look.keepFileStyle || !adjustable) {
                set { $0.keepFileStyle.toggle() }
            }
            .disabled(!adjustable)
            .focused($focus, equals: .file)
            Group {
                if adjustable { Text(look.fileStyleLine) }
                else { Text("Bei Plex-Servern kommt die Gestaltung immer aus der Datei.") }
            }
            .font(.app(size: 24))
            .foregroundStyle(Theme.fontQuiet)
            .padding(.horizontal, TVSpec.rowInset)
            .padding(.top, 4)
        }
    }

    // MARK: Unfolding rows

    private func valueRow(_ title: LocalizedStringKey, _ group: Part, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ActionRow(title: title, value: value, expanded: opened == group) {
                withAnimation(Theme.motion(.easeInOut(duration: TVSpec.valueExpandDuration))) {
                    opened = opened == group ? nil : group
                }
            }
            .focused($focus, equals: .row(group))

            if opened == group {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps(group).enumerated()), id: \.offset) { index, step in
                        let current = step.isCurrent(look)
                        Button {
                            set { step.apply(&$0) }
                            trial = nil
                            focus = .row(group)
                            withAnimation(Theme.motion(.easeInOut(duration: TVSpec.valueExpandDuration))) { opened = nil }
                        } label: {
                            HStack(spacing: 24) {
                                // The checkmark is in the type colour, not the accent (spec).
                                Image(icon: current ? "checkmark" : "")
                                    .font(.app(size: TVSpec.valueIcon, weight: .semibold))
                                    .foregroundStyle(Theme.font)
                                    .frame(width: TVSpec.choiceCheckWidth)
                                if let swatch = step.swatch {
                                    Circle().fill(swatch).frame(width: 26, height: 26)
                                        .accessibilityHidden(true)
                                }
                                Text(verbatim: step.name)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(RowsStyle())
                        .focused($focus, equals: .step(group, index))
                        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.leading, TVSpec.rowInset)
                .focusSection()
                .transition(.opacity)
            }
        }
    }

    private func steps(_ group: Part) -> [Step] {
        switch group {
        case .size:
            SubtitleLook.Size.allCases.map { value in
                Step(name: value.name, apply: { $0.size = value }, isCurrent: { $0.size == value })
            }
        case .colour:
            SubtitleLook.Colour.allCases.map { value in
                Step(name: value.name, swatch: value.color,
                     apply: { $0.colour = value }, isCurrent: { $0.colour == value })
            }
        case .outline:
            SubtitleLook.Outline.allCases.map { value in
                Step(name: value.name, apply: { $0.outline = value }, isCurrent: { $0.outline == value })
            }
        case .position:
            SubtitleLook.Position.allCases.map { value in
                Step(name: value.name, apply: { $0.position = value }, isCurrent: { $0.position == value })
            }
        }
    }

    // MARK: Changing

    private func set(_ change: (inout SubtitleLook) -> Void) {
        var next = model.subtitleLook
        change(&next)
        guard next != model.subtitleLook else { return }
        withAnimation(Motion.change) { model.subtitleLook = next }
    }

    private func reset() {
        let before = model.subtitleLook
        guard !before.isStandard else { return }
        withAnimation(Motion.change) {
            model.subtitleLook = .standard
            undo = before
        }
        // The locked reset row cannot keep focus; the way back takes it.
        focus = .undo
        undoTimer?.cancel()
        undoTimer = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if focus == .undo { focus = .row(.size) }
            withAnimation(Motion.change) { undo = nil }
        }
    }

    private func takeBack() {
        guard let before = undo else { return }
        undoTimer?.cancel()
        withAnimation(Motion.change) {
            model.subtitleLook = before
            undo = nil
        }
        focus = .reset
    }
}
