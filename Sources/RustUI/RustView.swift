import UIKit
import QuartzCore

/// Hosts the shared Rust UI: a CAMetalLayer that Rust draws into through wgpu, a display link at the panel's rate, and the
/// raw touch / press events handed to the Rust gesture, scroll and focus engines. No UIKit controls: the picture is Rust's.
final class RustView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    nonisolated(unsafe) private var handle: OpaquePointer?
    nonisolated(unsafe) private var link: CADisplayLink?
    private var fingers: [ObjectIdentifier: UInt64] = [:]
    private var nextFinger: UInt64 = 1
    private var lastSize = CGSize.zero
    /// The real app (default) draws over a video layer; `--demo` keeps the scripted suite.
    private let live = HostPlatform.isLive
    var engine: AVEngine?
    private var keyboardInset: CGFloat = 0
    private var idleTimer: Timer?
    private var background = false
    #if os(tvOS)
    private var alertShown = false
    #endif
    #if os(iOS)
    let keyboard = KeyboardBridge()
    #endif

    private var form: Int32 {
        #if os(tvOS)
        return 2
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? 1 : 0
        #endif
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(iOS)
        isMultipleTouchEnabled = true
        #endif
        isOpaque = !live
        backgroundColor = live ? .clear : UIColor(white: 0.0627, alpha: 1)
        if let layer = layer as? CAMetalLayer {
            layer.isOpaque = !live
            layer.framebufferOnly = true
        }
        #if os(iOS)
        keyboard.owner = self
        #endif
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appearanceChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(enteredBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        #if os(iOS)
        nc.addObserver(self, selector: #selector(keyboardMoved(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardMoved(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        #endif
    }

    // MARK: Lifecycle and keyboard

    @objc private func enteredBackground() {
        background = true
        link?.isPaused = true
        idleTimer?.invalidate()
        idleTimer = nil
        engine?.suspend()
        if handle != nil { _ = swiftly_rust_set_active(handle, 0) }
    }

    @objc private func willForeground() {
        background = false
        if handle != nil { apply(swiftly_rust_set_active(handle, 1)) }
        wake()
    }

    #if os(iOS)
    @objc private func keyboardMoved(_ n: Notification) {
        let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        let local = convert(end, from: nil)
        keyboardInset = n.name == UIResponder.keyboardWillHideNotification ? 0 : max(0, bounds.maxY - local.minY)
        setNeedsLayout()
    }
    #endif

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        link?.invalidate()
        swiftly_rust_destroy(handle)
    }

    #if os(tvOS)
    override var canBecomeFocused: Bool { true }
    #endif

    // MARK: Layout and handle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            link?.isPaused = true
        } else {
            start()
            wake()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        guard bounds.width > 0, bounds.height > 0, scale > 0 else { return }
        let px = (UInt32(bounds.width * scale), UInt32(bounds.height * scale))
        if let layer = layer as? CAMetalLayer {
            layer.contentsScale = scale
            layer.drawableSize = CGSize(width: Int(px.0), height: Int(px.1))
        }
        if handle == nil {
            handle = swiftly_rust_create(form, px.0, px.1, Float(scale), Unmanaged.passUnretained(layer).toOpaque())
            swiftly_rust_set_haptics(handle) { kind in Haptics.play(kind) }
            pushAppearance()
        } else if bounds.size != lastSize {
            _ = swiftly_rust_resize(handle, px.0, px.1, Float(scale))
        }
        lastSize = bounds.size
        let s = safeAreaInsets
        _ = swiftly_rust_insets(handle, Float(s.top), Float(s.left), Float(max(s.bottom, keyboardInset)), Float(s.right))
        wake()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        pushAppearance()
    }

    @objc private func appearanceChanged() { pushAppearance() }

    private func pushAppearance() {
        guard handle != nil else { return }
        let dark = traitCollection.userInterfaceStyle != .light
        apply(swiftly_rust_appearance(handle, dark ? 1 : 0, UIAccessibility.isReduceMotionEnabled ? 1 : 0))
    }

    // MARK: Display link (ProMotion rate; paused while the UI is still)

    private func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func wake() {
        guard !background else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        link?.isPaused = false
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard handle != nil else { return }
        let flags = swiftly_rust_frame(handle, l.timestamp)
        drainEngine()
        // Keep running while the UI animates; a touch or press wakes it again. The real app also polls a few times a
        // second while idle, because network answers arrive without any event.
        l.isPaused = flags & 1 == 0
        if l.isPaused { startIdlePoll() }
        textFlags(flags)
    }

    private func startIdlePoll() {
        guard live, idleTimer == nil, !background else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.handle != nil, !self.background else { return }
                let flags = swiftly_rust_frame(self.handle, CACurrentMediaTime())
                self.drainEngine()
                self.textFlags(flags)
                if flags & 1 != 0 || flags & 4 != 0 { self.wake() }
            }
        }
    }

    /// Hands the commands Rust queued to the AVPlayer.
    private func drainEngine() {
        guard live, let engine, let p = swiftly_rust_engine_commands() else { return }
        let lines = String(cString: p)
        swiftly_rust_free_string(p)
        if !lines.isEmpty { engine.apply(lines) }
    }

    private func textFlags(_ flags: Int32) {
        #if os(iOS)
        keyboard.update(wanted: flags & 2 != 0)
        #else
        if flags & 2 != 0 { presentTextEntry() } else { alertShown = false }
        #endif
    }

    private func apply(_ flags: Int32) {
        if flags & 4 != 0 || flags & 1 != 0 { wake() }
        textFlags(flags)
    }

    // MARK: Touch

    private func send(_ touches: Set<UITouch>, phase: Int32) {
        guard handle != nil else { return }
        for t in touches {
            let key = ObjectIdentifier(t)
            let id: UInt64
            if let known = fingers[key] {
                id = known
            } else {
                id = nextFinger
                nextFinger += 1
                fingers[key] = id
            }
            let p = t.location(in: self)
            apply(swiftly_rust_touch(handle, id, phase, Float(p.x), Float(p.y), t.timestamp))
            if phase >= 2 { fingers[key] = nil }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, phase: 0) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, phase: 1) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, phase: 2) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, phase: 3) }

    // MARK: Remote (tvOS)

    #if os(tvOS)
    private func code(_ type: UIPress.PressType) -> Int32? {
        switch type {
        case .upArrow: 0
        case .downArrow: 1
        case .leftArrow: 2
        case .rightArrow: 3
        case .select: 4
        case .menu: 5
        case .playPause: 6
        default: nil
        }
    }

    private func presses(_ set: Set<UIPress>, down: Bool, event: UIPressesEvent?, pass: (Set<UIPress>, UIPressesEvent?) -> Void) {
        var rest = Set<UIPress>()
        for p in set {
            guard handle != nil, let c = code(p.type) else { rest.insert(p); continue }
            let flags = swiftly_rust_press(handle, c, down ? 1 : 0, p.timestamp)
            apply(flags)
            // Menu with nothing to go back to: the system leaves the app.
            if flags & 8 != 0 { rest.insert(p) }
            // A select on a field that still has the keyboard asks for the entry again.
            if !down, c == 4, flags & 2 != 0 { alertShown = false; presentTextEntry() }
        }
        if !rest.isEmpty { pass(rest, event) }
    }

    // MARK: Text entry on Apple TV (the system keyboard in an alert field)

    private func presentTextEntry() {
        guard !alertShown, let host = window?.rootViewController else { return }
        alertShown = true
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .alert)
        alert.addTextField { f in
            f.autocorrectionType = .no
            f.autocapitalizationType = .none
            f.keyboardType = .default
            f.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            self.text(5, alert?.textFields?.first?.text ?? "")
            self.text(4, nil)
        })
        alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { [weak self] _ in
            self?.text(2, nil)
            self?.alertShown = false
        })
        host.present(alert, animated: true)
    }

    override func pressesBegan(_ set: Set<UIPress>, with event: UIPressesEvent?) {
        presses(set, down: true, event: event) { super.pressesBegan($0, with: $1) }
    }

    override func pressesEnded(_ set: Set<UIPress>, with event: UIPressesEvent?) {
        presses(set, down: false, event: event) { super.pressesEnded($0, with: $1) }
    }

    override func pressesCancelled(_ set: Set<UIPress>, with event: UIPressesEvent?) {
        presses(set, down: false, event: event) { super.pressesCancelled($0, with: $1) }
    }
    #endif

    // MARK: Text bridge

    func text(_ kind: Int32, _ s: String?) {
        guard handle != nil else { return }
        if let s { s.withCString { apply(swiftly_rust_text(handle, kind, $0)) } } else { apply(swiftly_rust_text(handle, kind, nil)) }
    }
}

/// The haptics seam: Rust asks, UIKit buzzes. Not present on Apple TV.
enum Haptics {
    static func play(_ kind: Int32) {
        #if os(iOS)
        switch kind {
        case 1: UISelectionFeedbackGenerator().selectionChanged()
        case 2: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case 3: UINotificationFeedbackGenerator().notificationOccurred(.success)
        default: break
        }
        #endif
    }
}
