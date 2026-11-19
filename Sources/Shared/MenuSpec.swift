import SwiftUI

// **Plain data of the player's menu box**, shared by iPhone/iPad and Apple TV (each draws it its own way),
// plus the navigator between levels and the menu motions.

// MARK: - Data

struct MenuCapsule: Identifiable, Equatable {
    let id: String
    let label: String
}

enum MenuRowSpec: Identifiable {
    case value(id: String, label: String, value: String?, enabled: Bool = true, loading: Bool = false)
    case check(id: String, label: String, detail: String? = nil, selected: Bool, loading: Bool = false, enabled: Bool = true)
    case toggle(id: String, label: String, isOn: Bool)
    case capsules(id: String, caption: String, items: [MenuCapsule], selected: String?, compact: Bool = false)
    case device(id: String, name: String, kind: String, loading: Bool = false, enabled: Bool = true, symbol: String = "tv")
    case person(name: String, status: String)
    case action(id: String, label: String, symbol: String?, destructive: Bool = false)
    case section(String)
    case hint(String)
    case divider

    var id: String {
        switch self {
        case let .value(id, _, _, _, _), let .check(id, _, _, _, _, _), let .toggle(id, _, _),
             let .capsules(id, _, _, _, _), let .device(id, _, _, _, _, _), let .action(id, _, _, _): id
        case let .section(text): "section:" + text
        case let .person(name, _): "person:" + name
        case let .hint(text): "hint:" + text
        case .divider: "divider"
        }
    }
}

struct MenuSegmentsSpec {
    let items: [MenuCapsule]
    let selected: String
    /// A magnifier next to the segments.
    var search = false
}

/// "Früher / Später": the readout and two buttons. The step sizes come from the core (`earlierMs`, `laterMs`).
struct MenuStepSpec {
    let value: String
    let caption: String
    let earlierLabel: String
    let laterLabel: String
    let earlierMs: Int
    let laterMs: Int
    let resetLabel: String
    let canReset: Bool
    var earlierEnabled = true
    var laterEnabled = true
}

struct MenuFooterButton {
    let id: String
    let label: String
    let symbol: String
    var quiet = false
}

struct MenuLevelSpec {
    let id: String
    /// Set: the level opens with a back row of this title.
    var backTitle: String?
    var segments: MenuSegmentsSpec?
    /// Rows that scroll (when they do not fit).
    var rows: [MenuRowSpec] = []
    var step: MenuStepSpec?
    /// Rows that stay put below the list.
    var fixedRows: [MenuRowSpec] = []
    var footer: [MenuFooterButton] = []
}

enum MenuAction {
    case back
    case select(String)
    case toggle(String, Bool)
    case capsule(String, String)
    case segment(String)
    case search
    case step(ms: Int)
    case reset
    case footer(String)
}


extension Motion {
    /// **Box appears / levels change height**: spring 0.30 s, no overshoot.
    static var menuOpen: Animation {
        Theme.motionReduced ? Theme.fadeReduced : .spring(duration: 0.30, bounce: 0)
    }
    /// **Box closes back into the button**: faster than it opened.
    static var menuClose: Animation {
        Theme.motionReduced ? Theme.fadeReduced : .timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
    }
    /// **One menu turns into the next** (from the other button of the capsule): box moves and resizes, content cross-fades.
    static var menuSwitch: Animation {
        Theme.motionReduced ? Theme.fadeReduced : .spring(duration: 0.30, bounce: 0)
    }
    /// **A level slides** 12 pt: ease-in-out 220 ms.
    static var menuLevel: Animation {
        Theme.motionReduced ? Theme.fadeReduced : .timingCurve(0.77, 0, 0.175, 1, duration: 0.22)
    }
}


// MARK: - Navigation between levels

/// Which level shows. The root has no id; a pushed level is a string the host knows.
@Observable @MainActor
final class MenuNavigator {
    private(set) var path: [String] = []
    /// A popped level stays mounted until its slide is over.
    private(set) var leaving: String?

    var current: String? { path.last }

    // Keyboard and pointer (Mac, iPad with a keyboard): the row the cursor is on, among the rows the live level registered.
    /// The id of the highlighted row; the pointer sets it too, so hover and arrow keys share one highlight.
    var cursor: String?
    @ObservationIgnored private(set) var keys: [String] = []
    @ObservationIgnored private var drill: Set<String> = []
    @ObservationIgnored private var activate: (String) -> Void = { _ in }
    @ObservationIgnored private var goBack: (() -> Void)?

    /// The live level says which rows can be reached by key and what activating one does.
    func register(keys: [String], drill: Set<String>, back: (() -> Void)?, activate: @escaping (String) -> Void) {
        if self.keys != keys, let c = cursor, !keys.contains(c) { cursor = nil }
        self.keys = keys; self.drill = drill; self.goBack = back; self.activate = activate
    }

    enum Key { case up, down, left, right, enter }

    /// One key press. Returns false when the menu has nothing to do with it.
    @discardableResult
    func press(_ key: Key) -> Bool {
        switch key {
        case .down, .up:
            guard !keys.isEmpty else { return false }
            let at = cursor.flatMap(keys.firstIndex(of:))
            let next = key == .down ? (at.map { min($0 + 1, keys.count - 1) } ?? 0)
                                    : (at.map { max($0 - 1, 0) } ?? keys.count - 1)
            cursor = keys[next]
        case .enter:
            guard let c = cursor else { return false }
            activate(c)
        case .right:
            guard let c = cursor, drill.contains(c) else { return false }
            activate(c)
        case .left:
            guard let goBack else { return false }
            goBack()
        }
        return true
    }

    func push(_ id: String) {
        guard path.last != id else { return }
        leaving = nil
        cursor = nil
        withAnimation(Motion.menuLevel) { path.append(id) }
    }

    func pop() {
        guard let gone = path.last else { return }
        cursor = nil
        leaving = gone
        withAnimation(Motion.menuLevel) { path.removeLast() }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            if self?.leaving == gone { self?.leaving = nil }
        }
    }

    func reset() { path = []; leaving = nil; cursor = nil }
}

