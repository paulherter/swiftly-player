import JellyfinKit
import SwiftUI

/// **Playback -> "Subtitle look" (iPhone and iPad).** The look of text subtitles on one
/// page, with a picture that shows it. Layout and numbers: `Notizen/Mehrserver/
/// UNTERTITEL-ENTWURF.md`.
///
/// **Narrow (iPhone, iPad upright): the picture stands still at the top**, the rows scroll
/// below it. **Wide (iPad landscape): two columns**, picture left, rows right; a picture
/// across the whole width would be so tall at 900 pt that the rows fall out of view.
///
/// The values are written to `AppModel.subtitleLook` on every tap; it travels with the
/// profile settings. The player takes it when the library is created, see
/// `VLCPlayerView.library`.
struct SubtitleLookView: View {
    let model: AppModel

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    /// The look before "Reset", for the strip's "Undo" (4 seconds).
    @State private var undo: SubtitleLook?
    @State private var undoTimer: Task<Void, Never>?

    private var look: SubtitleLook { model.subtitleLook }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 0) {
                SubpageHeader(title: String(localized: "Untertitel"), back: { back() }, bottom: wide ? 18 : 8) { EmptyView() }
                if wide {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 10) {
                            preview
                            notes
                            Spacer(minLength: 0)
                        }
                        .frame(minWidth: 420, maxWidth: 640)
                        .padding(.leading, Theme.margin(wide: true))
                        rows
                    }
                } else {
                    preview
                        .padding(.horizontal, Theme.margin(wide: false))
                    rows
                }
            }
            strip
        }
        .tint(Theme.accent)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        .onDisappear { undoTimer?.cancel() }
    }

    // MARK: Preview

    private var preview: some View {
        SubtitlePreview(look: look, cornerRadius: Theme.cornerArea)
    }

    /// Under the picture, wide only; narrow it is the foot of the group.
    @ViewBuilder
    private var notes: some View {
        Footer("Gilt für Untertitel aus Text. Die von Blu-rays sind Bilder und bleiben, wie sie sind.")
    }

    // MARK: Rows

    private var rows: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                appearance
                if !wide {
                    Footer("Gilt für Untertitel aus Text. Die von Blu-rays sind Bilder und bleiben, wie sie sind.")
                        .padding(.horizontal, Theme.margin(wide: false))
                        .padding(.top, 8)
                }
                fancy
                resetGroup
            }
            .padding(.bottom, 80)
        }
        .scrollIndicators(.hidden)
        // The ground runs out under the picture: no line, no glass (spec section 2).
        .overlay(alignment: .top) {
            LinearGradient(colors: [Theme.reason, Theme.reason.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 20)
                .allowsHitTesting(false)
        }
    }

    private func set(_ change: (inout SubtitleLook) -> Void) {
        var next = model.subtitleLook
        change(&next)
        guard next != model.subtitleLook else { return }
        withAnimation(Motion.change) { model.subtitleLook = next }
    }

    private var appearance: some View {
        SettingGroup(title: "Aussehen") {
            segmentRow(symbol: "textformat.size", title: String(localized: "Größe"),
                       options: SubtitleLook.Size.allCases, value: look.size, name: \.name,
                       choose: { value in set { $0.size = value } }) { size in
                Text("A").font(.app(size: size.glyphSize, weight: .semibold))
            }
            SheetLine()
            segmentRow(symbol: "paintpalette", title: String(localized: "Farbe"),
                       options: SubtitleLook.Colour.allCases, value: look.colour, name: \.name,
                       choose: { value in set { $0.colour = value } }) { colour in
                Text("A").font(.app(size: 17, weight: .semibold)).foregroundStyle(colour.color)
            }
            SheetLine()
            segmentRow(symbol: "character.textbox", title: String(localized: "Rand"),
                       options: SubtitleLook.Outline.allCases, value: look.outline, each: 70, name: \.name,
                       choose: { value in set { $0.outline = value } }) { outline in
                Text(outline.name)
            }
            SheetLine()
            ChoiceRow(symbol: "shadow", title: Text("Schatten"),
                      an: Binding(get: { look.shadow }, set: { value in set { $0.shadow = value } }))
            SheetLine()
            ChoiceRow(symbol: "rectangle.inset.filled", title: Text("Dunkler Hintergrund"),
                      an: Binding(get: { look.background }, set: { value in set { $0.background = value } }))
            SheetLine()
            segmentRow(symbol: "align.vertical.bottom", title: String(localized: "Position"),
                       options: SubtitleLook.Position.allCases, value: look.position, each: 70, name: \.name,
                       choose: { value in set { $0.position = value } }) { position in
                Text(position.name)
            }
        }
    }

    private var fancy: some View {
        SettingGroup(title: "Aufwendige Untertitel") {
            let adjustable = model.fileStyleAdjustable
            ChoiceRow(symbol: "doc.richtext", title: Text("Gestaltung aus der Datei übernehmen"),
                      under: adjustable
                        ? Text(look.fileStyleLine)
                        : Text("Bei Plex-Servern kommt die Gestaltung immer aus der Datei."),
                      an: Binding(get: { look.keepFileStyle || !adjustable },
                                  set: { value in set { $0.keepFileStyle = value } }))
                .disabled(!adjustable)
                .animation(.easeInOut(duration: 0.10), value: look.keepFileStyle)
        }
    }

    private var resetGroup: some View {
        let locked = look.isStandard
        return CardView {
            Button(action: reset) {
                RowsLayout(symbol: "arrow.counterclockwise", title: Text("Zurücksetzen"),
                           under: nil, dimmedDown: locked) { EmptyView() }
            }
            .buttonStyle(Theme.PressButton())
            .disabled(locked)
        }
        .padding(.top, 26)
    }

    /// One row with segments: title left, segments right; when they do not fit side by
    /// side (large system type, long translation) the segments go below, full width.
    private func segmentRow<Value: Hashable, Label: View>(
        symbol: String, title: String, options: [Value], value: Value, each: CGFloat = 48,
        name: @escaping (Value) -> String, choose: @escaping (Value) -> Void,
        @ViewBuilder label: @escaping (Value) -> Label
    ) -> some View {
        let strip = GlyphSegments(group: title, options: options, value: value, name: name,
                                  choose: choose, each: each, label: label)
        return ViewThatFits(in: .horizontal) {
            RowsLayout(symbol: symbol, title: Text(verbatim: title), under: nil, dimmedDown: false) { strip }
            VStack(alignment: .leading, spacing: 0) {
                RowsLayout(symbol: symbol, title: Text(verbatim: title), under: nil, dimmedDown: false) { EmptyView() }
                    .padding(.bottom, -6)
                strip.frame(maxWidth: .infinity).padding(.horizontal, Theme.margin(wide: wide)).padding(.bottom, 10)
            }
        }
    }

    // MARK: Reset

    private func reset() {
        let before = model.subtitleLook
        guard !before.isStandard else { return }
        Theme.jerk(.lightweight)
        withAnimation(Motion.change) {
            // The file switch is part of the look and goes back with it (spec section 3).
            model.subtitleLook = .standard
            undo = before
        }
        undoTimer?.cancel()
        undoTimer = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
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
    }

    /// **"Reset" and "Undo" for 4 seconds:** it does not ask first, because it can be
    /// reversed (BRAND 7).
    @ViewBuilder
    private var strip: some View {
        if undo != nil {
            HStack {
                Text("Zurückgesetzt")
                    .growing(15, .semibold)
                    .foregroundStyle(Theme.font)
                Spacer(minLength: 12)
                Button(action: takeBack) {
                    Text("Rückgängig")
                        .growing(15)
                        .foregroundStyle(Theme.fontQuiet)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}

/// **Segments whose labels are views** (the "A" in its size or colour), drawn like
/// `Segments`: one surface moved by an offset, 0.25 s without overshoot. The chosen one
/// takes surface and full type, not more weight or size (BRAND 5). Each segment says what
/// it is to VoiceOver ("Size, Large"), because the "A"s carry no text of their own.
private struct GlyphSegments<Value: Hashable, Label: View>: View {
    let group: String
    let options: [Value]
    let value: Value
    let name: (Value) -> String
    let choose: (Value) -> Void
    /// Width of one segment: 48 for an "A", 70 for a word.
    let each: CGFloat
    @ViewBuilder let label: (Value) -> Label

    var body: some View {
        let index = options.firstIndex(of: value) ?? 0
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    guard option != value else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    choose(option)
                } label: {
                    label(option)
                        .font(.app(size: 13, weight: .semibold))
                        .foregroundStyle(value == option ? Theme.font : Theme.fontQuiet)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(group), \(name(option))"))
                .accessibilityAddTraits(value == option ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .frame(width: CGFloat(options.count) * each + 2, height: 32)
        .background(alignment: .leading) {
            GeometryReader { geometry in
                let width = (geometry.size.width - 4 - CGFloat(options.count - 1) * 2) / CGFloat(max(options.count, 1))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(white: 0.29))
                    .frame(width: width, height: geometry.size.height - 4)
                    .offset(x: 2 + CGFloat(index) * (width + 2), y: 2)
            }
        }
        // On the card the track is one step lighter than the card (`Theme.raised`):
        // `area` is hardly visible on `groupsArea`.
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        .frame(height: 44)
        .animation(Motion.select, value: index)
    }
}
