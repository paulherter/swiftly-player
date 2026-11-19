#if DEBUG
import SwiftUI

/// A stand-in player for the menu box, with made-up data: `-menuPreview tracks45|tracks2|settings|offset|speed`.
/// It draws the real box, rows and buttons so size, scrolling and motion can be checked without a server.
struct PlayerMenuPreview: View {
    let scene: String
    @State private var session = PlayerMenuSession()
    @State private var anchors = PlayerMenuAnchors()
    @State private var tab = "subtitle"
    @State private var selected = "sub:0"
    @State private var offsetMs = 300
    private let mass = PlayerMetric(pad: false, inWindow: false, portrait: true)

    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-menuPreview"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private var count: Int { scene == "tracks2" ? 2 : 45 }
    private var kind: PlayerMenuKind { scene.hasPrefix("tracks") || scene == "offset" ? .tracks : .settings }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.18).ignoresSafeArea()
            Text(verbatim: "Video").foregroundStyle(.white.opacity(0.2)).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 2) {
                Spacer()
                IconButton(symbol: "captions.bubble", label: "Audio & Untertitel", mass: mass,
                           open: session.isOpen && session.kind == .tracks) { toggle(.tracks) }
                    .menuAnchor(.tracks, into: $anchors)
                IconButton(symbol: "slider.horizontal.3", label: "Einstellungen", mass: mass,
                           open: session.isOpen && session.kind == .settings) { toggle(.settings) }
                    .menuAnchor(.settings, into: $anchors)
                IconButton(symbol: "xmark", label: "Schließen", mass: mass) {}
            }
            .padding(.horizontal, 16).padding(.top, 8)
            if let kind = session.kind {
                MenuPresenter(isOpen: session.isOpen, anchor: anchors.frames[kind] ?? .zero, navigator: session.navigator,
                              close: { session.close() }, root: {
                    MenuLevelView(spec: root(kind)) { act($0) }
                }, pushed: { id in MenuLevelView(spec: pushed(id)) { act($0) } })
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            session.open(kind)
            if scene == "offset" { try? await Task.sleep(for: .milliseconds(500)); session.navigator.push("offset") }
            if scene == "speed" { try? await Task.sleep(for: .milliseconds(500)); session.navigator.push("speed") }
        }
    }

    private func toggle(_ k: PlayerMenuKind) { session.isOpen && session.kind == k ? session.close() : session.open(k) }

    private func root(_ kind: PlayerMenuKind) -> MenuLevelSpec {
        if kind == .settings {
            var spec = MenuLevelSpec(id: "root", rows: [
                .value(id: "speed", label: "Geschwindigkeit", value: "Normal"), .value(id: "sleep", label: "Schlafzeit", value: "Aus"),
                .divider, .value(id: "picture", label: "Bild", value: "Original"), .value(id: "quality", label: "Qualität", value: "Direct Play"),
            ])
            spec.footer = [MenuFooterButton(id: "report", label: "Problem melden …", symbol: "exclamationmark.triangle", quiet: true)]
            return spec
        }
        var rows: [MenuRowSpec] = []
        if tab == "subtitle" {
            rows.append(.check(id: "sub:none", label: "Aus", selected: selected == "sub:none"))
            for i in 0..<count {
                rows.append(.check(id: "sub:\(i)", label: i % 7 == 3 ? "Englisch (SDH) mit einem sehr langen Namen aus der Datei \(i)" : "Deutsch \(i + 1)",
                                   detail: i % 2 == 0 ? "SRT" : "PGS", selected: selected == "sub:\(i)"))
            }
        } else {
            for i in 0..<min(count, 4) { rows.append(.check(id: "aud:\(i)", label: "Deutsch \(i + 1)", detail: "Dolby Digital 5.1", selected: i == 0)) }
        }
        var spec = MenuLevelSpec(id: "root", rows: rows)
        spec.segments = MenuSegmentsSpec(items: [MenuCapsule(id: "subtitle", label: "Untertitel"), MenuCapsule(id: "audio", label: "Ton")],
                                         selected: tab, search: tab == "subtitle")
        spec.fixedRows = [.value(id: "offset", label: "Zeit anpassen", value: "+0,3 s"), .value(id: "look", label: "Aussehen", value: "Groß · Fläche")]
        return spec
    }

    private func pushed(_ id: String) -> MenuLevelSpec {
        if id == "speed" {
            return MenuLevelSpec(id: id, backTitle: "Geschwindigkeit",
                                 rows: ["0,75×", "Normal", "1,25×", "1,5×", "2×"].map { .check(id: $0, label: $0, selected: $0 == "Normal") })
        }
        var spec = MenuLevelSpec(id: "offset", backTitle: "Zeit anpassen")
        spec.segments = MenuSegmentsSpec(items: [MenuCapsule(id: "subtitle", label: "Untertitel"), MenuCapsule(id: "audio", label: "Ton")], selected: tab)
        let text = offsetMs == 0 ? "0 s" : String(format: "%@%.1f s", offsetMs > 0 ? "+" : "−", abs(Double(offsetMs)) / 1000).replacingOccurrences(of: ".", with: ",")
        spec.step = MenuStepSpec(value: text, caption: offsetMs == 0 ? "Passt" : "Untertitel kommen später", earlierLabel: "Früher", laterLabel: "Später",
                                 earlierMs: -100, laterMs: 100, resetLabel: "Zurücksetzen", canReset: offsetMs != 0)
        return spec
    }

    private func act(_ action: MenuAction) {
        switch action {
        case .back: session.navigator.pop()
        case let .segment(id): withAnimation(Motion.menuOpen) { tab = id }
        case let .select(id):
            if ["speed", "offset"].contains(id) { session.navigator.push(id) } else if id.hasPrefix("sub:") { selected = id }
        case let .step(ms): offsetMs += ms
        case .reset: offsetMs = 0
        default: break
        }
    }
}
#endif
