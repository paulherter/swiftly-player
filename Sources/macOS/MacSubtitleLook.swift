import JellyfinKit
import SwiftUI

/// **Playback -> "Subtitle look" (Mac).** Same groups, rows, words and values as the
/// iPhone page (`Sources/iOS/SubtitleLookView.swift`); the form follows the pointer: two
/// columns, picture left and standing, rows right and scrolling, segments 28 tall, the
/// pointer lights a segment, the arrow keys step through one when it has the keyboard.
///
/// The look is written to `AppModel.subtitleLook` on every click. A player already open
/// keeps the old one: the library is created once (`VLCPlayerView.library`), the foot
/// under the picture says so.
struct SubtitleLookView: View {
    let model: AppModel
    let back: () -> Void

    /// The look before "Reset", for "Undo" (4 seconds).
    @State private var undo: SubtitleLook?
    @State private var undoTimer: Task<Void, Never>?

    private var look: SubtitleLook { model.subtitleLook }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubpageHeader(title: "Untertitel", back: back)
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.top, Theme.contentTop)
                .padding(.bottom, 14)
            HStack(alignment: .top, spacing: Theme.edgeSpacing + 4) {
                VStack(alignment: .leading, spacing: 10) {
                    SubtitlePreview(look: look, cornerRadius: Theme.cornerArea)
                    if VLCPlayerView.playersOpen {
                        note(Text("Gilt ab dem nächsten Video."))
                    }
                    note(Text("Gilt für Untertitel aus Text. Die von Blu-rays sind Bilder und bleiben, wie sie sind."))
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 420, maxWidth: 640)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        appearance
                        fancy
                        resetGroup
                    }
                    .padding(.bottom, 60)
                }
                .scrollIndicators(.never)
                .pagesScroll()
            }
            .padding(.leading, Theme.edgeSpacing)
            .padding(.trailing, Theme.edgeSpacing)
        }
        .frame(maxWidth: Theme.settingWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { strip }
        .onDisappear { undoTimer?.cancel() }
    }

    private func note(_ text: Text) -> some View {
        text.font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
    }

    private func set(_ change: (inout SubtitleLook) -> Void) {
        var next = model.subtitleLook
        change(&next)
        guard next != model.subtitleLook else { return }
        withAnimation(Motion.change) { model.subtitleLook = next }
    }

    // MARK: Groups

    private var appearance: some View {
        SettingGroup(title: "Aussehen") {
            segmentRow(symbol: "textformat.size", title: String(localized: "Größe"),
                       options: SubtitleLook.Size.allCases, value: look.size, name: \.name,
                       choose: { value in set { $0.size = value } }) { size in
                Text("A").font(.app(size: size.glyphSize, weight: .semibold))
            }
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            segmentRow(symbol: "paintpalette", title: String(localized: "Farbe"),
                       options: SubtitleLook.Colour.allCases, value: look.colour, name: \.name,
                       choose: { value in set { $0.colour = value } }) { colour in
                Text("A").font(.app(size: 17, weight: .semibold)).foregroundStyle(colour.color)
            }
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            segmentRow(symbol: "character.textbox", title: String(localized: "Rand"),
                       options: SubtitleLook.Outline.allCases, value: look.outline, each: 70, name: \.name,
                       choose: { value in set { $0.outline = value } }) { outline in
                Text(outline.name)
            }
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            ToggleRow(symbol: "shadow", title: Text("Schatten"),
                      an: Binding(get: { look.shadow }, set: { value in set { $0.shadow = value } }))
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            ToggleRow(symbol: "rectangle.inset.filled", title: Text("Dunkler Hintergrund"),
                      an: Binding(get: { look.background }, set: { value in set { $0.background = value } }))
            SheetLine().padding(.leading, Theme.separatorInsetCard)
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
            ToggleRow(symbol: "doc.richtext", title: Text("Gestaltung aus der Datei übernehmen"),
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
                HStack(spacing: 14) {
                    Image(icon: "arrow.counterclockwise")
                        .font(Theme.body)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text("Zurücksetzen").font(Theme.listTitle)
                    Spacer(minLength: 0)
                }
                // Locked is quiet, not translucent (spec section 6).
                .foregroundStyle(locked ? Theme.fontVeryQuiet : Theme.font)
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressRow())
            .disabled(locked)
        }
        .padding(.top, 26)
    }

    /// A row with segments: title left, segments right; stacked when they do not fit.
    private func segmentRow<Value: Hashable, Label: View>(
        symbol: String, title: String, options: [Value], value: Value, each: CGFloat = 46,
        name: @escaping (Value) -> String, choose: @escaping (Value) -> Void,
        @ViewBuilder label: @escaping (Value) -> Label
    ) -> some View {
        let strip = MacSegments(group: title, options: options, value: value, name: name,
                                choose: choose, each: each, label: label)
        let head = HStack(spacing: 14) {
            Image(icon: symbol)
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(verbatim: title).font(Theme.listTitle).foregroundStyle(Theme.font)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { head; Spacer(minLength: 12); strip }
                .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 46)
            VStack(alignment: .leading, spacing: 8) { head; strip }
                .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    // MARK: Reset

    private func reset() {
        let before = model.subtitleLook
        guard !before.isStandard else { return }
        withAnimation(Motion.change) {
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

    /// "Reset" does not ask first, because it can be reversed (BRAND 7).
    @ViewBuilder
    private var strip: some View {
        if undo != nil {
            HStack {
                Text("Zurückgesetzt").font(Theme.listTitle).foregroundStyle(Theme.font)
                Spacer(minLength: 12)
                Button(action: takeBack) {
                    Text("Rückgängig").font(Theme.body).foregroundStyle(Theme.fontQuiet)
                        .frame(minHeight: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(width: 360, height: 48)
            .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}

/// **Segments drawn by the app, for the pointer:** 28 tall, one surface moved by an offset,
/// the pointer lights a segment (white 6 %), and with the keyboard on it the left and right
/// arrows step through. Each segment names itself to VoiceOver ("Size, Large").
private struct MacSegments<Value: Hashable, Label: View>: View {
    let group: String
    let options: [Value]
    let value: Value
    let name: (Value) -> String
    let choose: (Value) -> Void
    let each: CGFloat
    @ViewBuilder let label: (Value) -> Label

    @State private var hovered: Value?
    @FocusState private var focused: Bool

    var body: some View {
        let index = options.firstIndex(of: value) ?? 0
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    choose(option)
                } label: {
                    label(option)
                        .font(.app(size: 13, weight: .semibold))
                        .foregroundStyle(value == option ? Theme.font : Theme.fontQuiet)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: each, height: 24)
                        .background(hovered == option && value != option ? Theme.hoverArea : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = option } else if hovered == option { hovered = nil }
                }
                .accessibilityLabel(Text(verbatim: "\(group), \(name(option))"))
                .accessibilityAddTraits(value == option ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(white: 0.29))
                .frame(width: each, height: 24)
                .offset(x: 2 + CGFloat(index) * (each + 2))
        }
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        .overlay {
            // The keyboard's focus shows as a surface, not as a ring (spec section 7).
            RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                .fill(Color.white.opacity(focused ? 0.12 : 0))
                .allowsHitTesting(false)
        }
        .animation(Motion.select, value: index)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { step(-1, from: index) }
        .onKeyPress(.rightArrow) { step(1, from: index) }
    }

    private func step(_ by: Int, from index: Int) -> KeyPress.Result {
        let next = index + by
        guard options.indices.contains(next) else { return .handled }
        choose(options[next])
        return .handled
    }
}
