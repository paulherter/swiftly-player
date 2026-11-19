import SwiftUI

// **The rows of the player's menu box** and the data they are drawn from.
//
// A level is described by a `MenuLevelSpec` (plain data); `MenuLevelView` draws it and sends back a `MenuAction`.
// The lists come from the core model (speeds, offset steps, tracks, and what the core adds next: sleep, picture,
// quality, group, season button, handoff). Nothing here decides which options exist.
// Included in the iPhone/iPad (and Mac) targets; iPhone look first.

// MARK: - Row look

/// The highlight of the row under the pointer or the keyboard cursor (one cursor for both). Touch screens never set it.
private struct MenuHighlight: ViewModifier {
    @Environment(\.menuNavigator) private var navigator
    let id: String

    func body(content: Content) -> some View {
        let on = navigator?.cursor == id
        content
            .background(Theme.selected.opacity(on ? 1 : 0), in: RoundedRectangle(cornerRadius: MenuMetric.rowRadius, style: .continuous))
            .onHover { inside in
                guard let navigator else { return }
                if inside { navigator.cursor = id } else if navigator.cursor == id { navigator.cursor = nil }
            }
    }
}

extension View {
    fileprivate func menuHighlight(_ id: String) -> some View { modifier(MenuHighlight(id: id)) }
}

private struct MenuPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Theme.pressedArea.opacity(configuration.isPressed ? 1 : 0))
            .clipShape(RoundedRectangle(cornerRadius: MenuMetric.rowRadius, style: .continuous))
            // Pressed shows at once, lets go in 160 ms.
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private func menuText(_ text: String, size: CGFloat = 15, weight: Font.Weight = .semibold, lines: Int = 1,
                      _ color: Color = Theme.font) -> some View {
    // Names from the file are verbatim; fixed words come translated from the model.
    Text(verbatim: text).font(.app(size: size, weight: weight)).foregroundStyle(color).lineLimit(lines).truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
}

struct MenuValueRow: View {
    @Environment(\.menuRow) private var row
    let label: String
    let value: String?
    var enabled = true
    var loading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // The label keeps its width; a long value gives way first.
                menuText(label).layoutPriority(1)
                Spacer(minLength: 8)
                if loading {
                    Loader(size: 16, strength: 2)
                } else if let value {
                    menuText(value, size: 15, weight: .regular, Theme.fontVeryQuiet)
                        .contentTransition(.opacity)
                }
                Image(icon: "chevron.right", size: 12).font(.app(size: 12, weight: .semibold)).foregroundStyle(Theme.fontVeryQuiet)
            }
            .padding(.horizontal, MenuMetric.pad)
            .frame(height: row)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPress())
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled || loading)
        .animation(Theme.toggle, value: value)
    }
}

struct MenuCheckRow: View {
    @Environment(\.menuRow) private var row
    let label: String
    var detail: String?
    let selected: Bool
    var loading = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // The slot keeps its width, so the label never moves; a circle replaces the check while it switches.
                ZStack {
                    if loading { Loader(size: 14, strength: 2) }
                    else { Image(icon: "checkmark", size: 14).font(.app(size: 14, weight: .semibold)).opacity(selected ? 1 : 0) }
                }
                .frame(width: 18)
                .accessibilityHidden(true)
                // A long name from the file takes a second line before it is cut.
                menuText(label, lines: 2, Theme.font)
                Spacer(minLength: 8)
                if let detail { menuText(detail, size: 13, weight: .regular, Theme.fontVeryQuiet).layoutPriority(1) }
            }
            .padding(.horizontal, MenuMetric.pad)
            .padding(.vertical, 6)
            .frame(minHeight: row)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPress())
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled || loading)
        .animation(Theme.toggle, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MenuSwitchRow: View {
    @Environment(\.menuRow) private var row
    let label: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack {
            menuText(label)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { isOn }, set: set)).labelsHidden().tint(Theme.accent)
        }
        .padding(.horizontal, MenuMetric.pad)
        .frame(height: row)
        .animation(Motion.select, value: isOn)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// Numbers as capsules (minutes, Mbit/s): nothing has to roll.
struct MenuCapsuleRow: View {
    let caption: String
    let items: [MenuCapsule]
    let selected: String?
    /// The "Aussehen" variant (design): 3/6 padding, caption gap 5.
    var compact = false
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            menuText(caption, size: 13, weight: .regular, Theme.fontVeryQuiet)
            HStack(spacing: 6) {
                ForEach(items) { item in
                    let on = item.id == selected
                    Button { pick(item.id) } label: {
                        menuText(item.label, size: 15, weight: .semibold, on ? Theme.reason : Theme.fontQuiet)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(on ? Theme.font : Theme.area, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(Theme.PressButton())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .animation(Motion.select, value: selected)
        }
        .padding(.horizontal, MenuMetric.pad)
        .padding(.top, compact ? 3 : 6).padding(.bottom, compact ? 6 : 10)
    }
}

/// The readout and "Früher / Später". The readout rolls; "Zurücksetzen" keeps its place and fades.
struct MenuStepRow: View {
    @Environment(\.menuRow) private var row
    let spec: MenuStepSpec
    let act: (MenuAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: spec.value)
                        .font(.app(size: 28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.font)
                        .contentTransition(.numericText())
                        .animation(Theme.motionReduced ? Theme.fadeReduced : .easeOut(duration: 0.15), value: spec.value)
                    menuText(spec.caption, size: 13, weight: .regular, Theme.fontVeryQuiet)
                }
                Spacer(minLength: 8)
                Button { act(.reset) } label: {
                    menuText(spec.resetLabel, size: 13, weight: .semibold, Theme.accent).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .opacity(spec.canReset ? 1 : 0)
                .disabled(!spec.canReset)
                .animation(Theme.motionReduced ? Theme.fadeReduced : .easeOut(duration: 0.15), value: spec.canReset)
            }
            .padding(.horizontal, MenuMetric.pad).padding(.top, 8).padding(.bottom, 12)
            HStack(spacing: 6) {
                stepButton(spec.earlierLabel, symbol: "minus", ms: spec.earlierMs, enabled: spec.earlierEnabled)
                stepButton(spec.laterLabel, symbol: "plus", ms: spec.laterMs, enabled: spec.laterEnabled)
            }
            .padding(.horizontal, 2).padding(.bottom, 4)
        }
    }

    private func stepButton(_ label: String, symbol: String, ms: Int, enabled: Bool) -> some View {
        Button { act(.step(ms: ms)) } label: {
            HStack(spacing: 8) {
                Image(icon: symbol, size: 15).font(.app(size: 15, weight: .semibold))
                menuText(label)
            }
            .frame(maxWidth: .infinity, minHeight: row + 4)
            .background(Theme.area, in: RoundedRectangle(cornerRadius: MenuMetric.rowRadius + 2, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        // Held: the system repeats; the first repeat comes after its own delay (about 0.4 s).
        .buttonRepeatBehavior(.enabled)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
        .sensoryFeedback(.selection, trigger: spec.value)
    }
}

struct MenuFooterRow: View {
    let buttons: [MenuFooterButton]
    let act: (MenuAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(buttons.enumerated()), id: \.element.id) { index, button in
                if index > 0 { Spacer(minLength: 8) }
                Button { act(.footer(button.id)) } label: {
                    HStack(spacing: 7) {
                        Image(icon: button.symbol, size: 15).font(.app(size: 15, weight: .semibold))
                        menuText(button.label, size: 13, weight: .semibold, button.quiet ? Theme.fontQuiet : Theme.font)
                    }
                    .foregroundStyle(button.quiet ? Theme.fontQuiet : Theme.font)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuPress())
                .menuHighlight(button.id)
            }
        }
        .frame(height: 44)
    }
}

struct MenuDeviceRow: View {
    @Environment(\.menuRow) private var row
    let name: String
    let kind: String
    var symbol = "tv"
    var loading = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    if loading { Loader(size: 16, strength: 2) } else { Image(icon: symbol, size: 17).font(.app(size: 17, weight: .regular)) }
                }
                .frame(width: 17)
                menuText(name)
                Spacer(minLength: 8)
                menuText(loading ? String(localized: "Verbinde …") : kind, size: 13, weight: .regular, Theme.fontVeryQuiet)
            }
            .padding(.horizontal, MenuMetric.pad)
            .frame(height: row)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPress())
        .opacity(enabled ? 1 : 0.4)
        .animation(Motion.select, value: enabled)
        .disabled(!enabled || loading)
    }
}

struct MenuBackRow: View {
    @Environment(\.menuRow) private var row
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(icon: "chevron.left", size: 15).font(.app(size: 15, weight: .semibold))
                menuText(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MenuMetric.pad - 4)
            .frame(height: row)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPress())
        .menuHighlight("back")
        .accessibilityLabel(Text("Zurück"))
        .accessibilityValue(Text(verbatim: title))
    }
}

struct MenuDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, MenuMetric.pad).padding(.vertical, 6)
    }
}

/// "Untertitel | Ton": the light surface glides to the other segment; the magnifier sits beside it.
struct MenuSegments: View {
    @Environment(\.menuRow) private var row
    let spec: MenuSegmentsSpec
    let act: (MenuAction) -> Void
    @Namespace private var glide

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(spec.items) { item in
                    let on = item.id == spec.selected
                    Button { act(.segment(item.id)) } label: {
                        menuText(item.label, size: 13, weight: .semibold, on ? Theme.font : Theme.fontQuiet)
                            .frame(maxWidth: .infinity, minHeight: row - 8 - 6)
                            .background {
                                if on {
                                    RoundedRectangle(cornerRadius: MenuMetric.rowRadius - 2, style: .continuous)
                                        .fill(Theme.raised).matchedGeometryEffect(id: "segment", in: glide)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Theme.area, in: RoundedRectangle(cornerRadius: MenuMetric.rowRadius, style: .continuous))
            .animation(Motion.select, value: spec.selected)
            if spec.search {
                Button { act(.search) } label: {
                    Image(icon: "magnifyingglass", size: 17).font(.app(size: 17, weight: .regular))
                        .frame(width: row - 4, height: row - 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .accessibilityLabel(Text("Untertitel suchen …"))
            }
        }
        .padding(.horizontal, 2)
        .frame(height: row)
    }
}

// MARK: - One level from its data

struct MenuRowsView: View {
    @Environment(\.menuRow) private var unit
    let rows: [MenuRowSpec]
    let act: (MenuAction) -> Void

    var body: some View {
        // The first rows fade in 20 ms apart after the box (only the first four), input is never blocked.
        ForEach(rows) { row in
            switch row {
            case let .value(id, label, value, enabled, loading):
                MenuValueRow(label: label, value: value, enabled: enabled, loading: loading) { act(.select(id)) }
                    .menuHighlight(id)
            case let .check(id, label, detail, selected, loading, enabled):
                MenuCheckRow(label: label, detail: detail, selected: selected, loading: loading, enabled: enabled) { act(.select(id)) }
                    .menuHighlight(id)
            case let .toggle(id, label, isOn):
                MenuSwitchRow(label: label, isOn: isOn) { act(.toggle(id, $0)) }
                    .menuHighlight(id)
            case let .capsules(id, caption, items, selected, compact):
                MenuCapsuleRow(caption: caption, items: items, selected: selected, compact: compact) { act(.capsule(id, $0)) }
            case let .device(id, name, kind, loading, enabled, symbol):
                MenuDeviceRow(name: name, kind: kind, symbol: symbol, loading: loading, enabled: enabled) { act(.select(id)) }
                    .menuHighlight(id)
            case let .person(name, status):
                HStack(spacing: 8) {
                    menuText(name)
                    Spacer(minLength: 8)
                    menuText(status, size: 13, weight: .regular, Theme.fontVeryQuiet)
                }
                .padding(.horizontal, MenuMetric.pad).frame(height: unit)
                .accessibilityElement(children: .combine)
            case let .action(id, label, symbol, destructive):
                Button { act(.select(id)) } label: {
                    HStack(spacing: 8) {
                        if let symbol { Image(icon: symbol, size: 15).font(.app(size: 15, weight: .semibold)).frame(width: 18) }
                        menuText(label, destructive ? Theme.warning : Theme.font)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, MenuMetric.pad).frame(height: unit).contentShape(Rectangle())
                }
                .buttonStyle(MenuPress())
                .menuHighlight(id)
            case let .section(text):
                menuText(text, size: 13, weight: .semibold, Theme.fontVeryQuiet)
                    .padding(.horizontal, MenuMetric.pad).frame(maxWidth: .infinity, alignment: .leading).frame(height: unit - 12)
            case let .hint(text):
                Text(verbatim: text).font(.app(size: 13)).foregroundStyle(Theme.fontVeryQuiet)
                    .padding(.horizontal, MenuMetric.pad).padding(.top, 4).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .divider:
                MenuDivider()
            }
        }
    }
}

struct MenuLevelView: View {
    @Environment(\.menuNavigator) private var navigator
    @Environment(\.menuLevelID) private var levelID
    let spec: MenuLevelSpec
    let act: (MenuAction) -> Void

    var body: some View {
        MenuLevel {
            if let title = spec.backTitle { MenuBackRow(title: title) { act(.back) } }
            if let segments = spec.segments { MenuSegments(spec: segments, act: act) }
        } list: {
            MenuRowsView(rows: spec.rows, act: act)
        } bottom: {
            if let step = spec.step { MenuStepRow(spec: step, act: act) }
            if !spec.fixedRows.isEmpty { MenuDivider(); MenuRowsView(rows: spec.fixedRows, act: act) }
            if !spec.footer.isEmpty { MenuFooterRow(buttons: spec.footer, act: act) }
        }
        .onChange(of: live, initial: true) { _, now in if now { register() } }
        .onChange(of: keyed.map(\.id)) { _, _ in if live { register() } }
    }

    private var live: Bool { (navigator?.current ?? "") == levelID }

    /// The rows the keyboard can reach, in the order they are drawn: back, list, fixed rows, footer.
    private var keyed: [(id: String, row: MenuRowSpec?)] {
        var out: [(String, MenuRowSpec?)] = []
        if spec.backTitle != nil { out.append(("back", nil)) }
        for row in spec.rows + spec.fixedRows {
            switch row {
            case .value, .check, .toggle, .device, .action: out.append((row.id, row))
            default: break
            }
        }
        for button in spec.footer { out.append((button.id, nil)) }
        return out
    }

    private func register() {
        let keys = keyed
        var drill = Set<String>()
        for (id, row) in keys { if case .value? = row { drill.insert(id) } }
        let rows = Dictionary(uniqueKeysWithValues: keys.compactMap { key in key.row.map { (key.id, $0) } })
        let footer = Set(spec.footer.map(\.id))
        navigator?.register(keys: keys.map(\.id), drill: drill, back: spec.backTitle == nil ? nil : { act(.back) }) { id in
            if id == "back" { act(.back); return }
            if footer.contains(id) { act(.footer(id)); return }
            if case let .toggle(_, _, isOn)? = rows[id] { act(.toggle(id, !isOn)); return }
            act(.select(id))
        }
    }
}
