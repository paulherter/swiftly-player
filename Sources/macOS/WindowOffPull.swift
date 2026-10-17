#if DEBUG
import AppKit
import OSLog
import SwiftUI

/// **A look at the app's own work, without screen access.**
///
/// A session working on the UI cannot see it, and a green build is not a look: an
/// active profile picture once carried a veil (`disabled` lays one over it in
/// SwiftUI) and the stacked circles in the sidebar were in the wrong order, both of
/// which built fine.
///
/// A screen capture would be the obvious route, deliberately not taken: a capture
/// permission can do more than needed, as it sees the whole screen including
/// everything else that is open. It would not work anyway: `screencapture -l`
/// answers "could not create image from window", and `CGWindowListCreateImage` was
/// removed in macOS 15.
///
/// Instead **the view draws itself**. `cacheDisplay(in:to:)` is AppKit's own way of
/// putting a view into a bitmap; only this app is involved. The image lands next to
/// the log in the container, where a session reads anyway.
///
/// **What is not in the image:**
///
/// - **The player's video picture.** `VLCOpenGLVideoView` draws into its own surface,
/// leaving a hole. The controls above it show, the picture below does not.
/// - **Popovers, menus and the traffic lights.** AppKit puts them in their own
/// windows, and exactly one window is drawn.
///
/// **Development builds only.** This file does not exist in the shipped version, the
/// same conditional as around `AppLog.write`.
@MainActor
enum WindowOffPull {

    /// Same folder as the log: under the sandbox that is
    /// `~/Library/Containers/<bundle id>/Data/Documents`.
    private static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// To get an image, create this file. It is deleted as soon as the image exists; the
    /// presence of the file is the request.
    static var kickoff: URL { folder.appendingPathComponent("abzug.jetzt") }
    static var image: URL { folder.appendingPathComponent("abzug.png") }

    /// **A file as trigger, not a key shortcut.**
    ///
    /// Someone would have to press a shortcut, which defeats the purpose: the session
    /// should look for itself before reporting. A file in the app's own container is
    /// something it can create.
    ///
    /// A 1.5 second tick: slow enough not to stand out, fast enough not to wait for.
    static func eavesdrop() {
        let tick = Timer(timeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard FileManager.default.fileExists(atPath: kickoff.path) else { return }
                try? FileManager.default.removeItem(at: kickoff)
                produce()
            }
        }
        // In `.common` mode, otherwise the timer stalls while the mouse button is held or a
        // menu is open.
        RunLoop.main.add(tick, forMode: .common)
    }

    /// Draws the frontmost visible window.
    ///
    /// **A covered window does not draw.** macOS stops drawing once a window is fully
    /// behind others, and SwiftUI stops updating it. `cacheDisplay` then returns the
    /// **last drawn** image, which looks like "nothing changed". That once produced a
    /// wrong conclusion (four commands, four identical images, "menu control is dead");
    /// the window was in fact covered (`occlusionState` without `visible`, not key
    /// window, app not active) because simulators were running on the same machine.
    ///
    /// So the state is now in the log line. A tool that silently shows stale content is
    /// worse than none.
    ///
    /// **A second cause for a wrong image: two instances.** The trigger file lives in the
    /// container, which all copies of the same app share. If a second one is running,
    /// from `DerivedData` or an older build, it may take the request first, and the image
    /// shows its window. Before a capture check that
    /// `pgrep -f "Contents/MacOS/Swiftly" | wc -l` is **1**.
    static func produce() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let content = window.contentView else {
            AppLog.writeOut("[Abzug] kein sichtbares Fenster")
            return
        }
        let area = content.bounds
        guard area.width > 1, area.height > 1,
              let store = content.bitmapImageRepForCachingDisplay(in: area) else {
            AppLog.writeOut("[Abzug] keine Ablage für \(Int(area.width))x\(Int(area.height))")
            return
        }
        content.cacheDisplay(in: area, to: store)
        guard let data = store.representation(using: .png, properties: [:]) else {
            AppLog.writeOut("[Abzug] liess sich nicht als PNG schreiben")
            return
        }
        do {
            try data.write(to: image)
            let visible = window.occlusionState.contains(.visible)
            AppLog.writeOut("[Abzug] \(Int(area.width))x\(Int(area.height)) Punkte, "
                + "\(store.pixelsWide)x\(store.pixelsHigh) Bildpunkte, \(data.count) B"
                + (visible ? "" : " — ACHTUNG: Fenster verdeckt, das Bild ist der "
                                 + "letzte gezeichnete Stand und kann alt sein"))
        } catch {
            AppLog.writeOut("[Abzug] \(error)")
        }
    }
}

/// **Frame cadence, measured instead of felt.**
///
/// Scrolling felt like 30 Hz while animations felt smooth. Those two claims nearly
/// contradict each other, so this measures rather than guesses.
///
/// `NSView.displayLink(target:selector:)` (macOS 14) follows the clock **of the
/// screen the window is on** and is called for every frame the window receives. The
/// gaps between calls show the rate the window actually runs at and how many frames
/// are dropped.
///
/// **Into the unified log, not `AppLog.write`.** That file sits in the app's
/// container and cannot be read from outside; a measurement nobody can read is none.
/// `Logger` writes to the log that `log show` returns.
///
/// **Development builds only**, like the rest of this file.
final class FrameTick: NSView {
    private static let log = Logger(subsystem: "de.paulherter.swiftly", category: "bildtakt")
    private var connection: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var spacings: [Double] = []
    private var windowStart = CACurrentMediaTime()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        connection?.invalidate()
        guard window != nil else { connection = nil; return }
        let new = displayLink(target: self, selector: #selector(tick))
        new.add(to: .main, forMode: .common)
        connection = new
        if let screen = window?.screen {
            Self.log.notice("""
                Bildschirm \(screen.localizedName, privacy: .public),                 maximal \(screen.maximumFramesPerSecond) Hz,                 Fenster \(Int(self.window?.frame.width ?? 0))x\(Int(self.window?.frame.height ?? 0))
                """)
        }
    }

    @objc private func tick(_ connection: CADisplayLink) {
        let now = CACurrentMediaTime()
        defer { last = now }
        guard last > 0 else { return }
        spacings.append((now - last) * 1000)

        // One line every two seconds: rate, spread, dropped frames.
        guard now - windowStart >= 2 else { return }
        let n = spacings.count
        guard n > 1 else { spacings.removeAll(); windowStart = now; return }
        let sorted = spacings.sorted()
        let medium = sorted[n / 2]
        let should = connection.targetTimestamp - connection.timestamp
        let shouldMs = should > 0 ? should * 1000 : 1000 / 120
        // A frame counts as dropped when it took more than 1.5 times the target: one
        // skipped frame or more.
        let dropped = spacings.filter { $0 > shouldMs * 1.5 }.count
        let row = String(
            format: "%.0f Bilder/s · Mittel %.2f ms · min %.2f · max %.2f · Soll %.2f · %d ausgefallen (%.0f%%)",
            Double(n) / (now - windowStart), medium, sorted[0], sorted[n - 1],
            shouldMs, dropped, Double(dropped) * 100 / Double(n))
        Self.log.notice("\(row, privacy: .public)")
        spacings.removeAll()
        windowStart = now
    }
}

/// Attaches the `FrameTick` to the window.
struct ImageTickMeasure: NSViewRepresentable {
    func makeNSView(context: Context) -> FrameTick { FrameTick(frame: .zero) }
    func updateNSView(_ viewRef: FrameTick, context: Context) {}
}

/// **A measured scroll run instead of a feeling.**
///
/// Scrolling felt like 30 Hz on **all** pages, even in Settings where no image is
/// shown, while animations were smooth. That difference is the key finding: once
/// handed over, an animation keeps running on the render server, but scrolling asks
/// the main run loop for a new frame **each time**. If only scrolling stutters, a
/// frame costs too much.
///
/// This probe drives itself: it sends real scroll-wheel events to its own app via
/// `NSApp.postEvent`, with no access to other programs, no permission, and the same
/// route a trackpad takes. `FrameTick` alongside logs how many frames drop.
///
/// Started through the environment so a session can trigger it unattended:
///
/// SWIFTLY_SCROLLPROBE=1 .../Swiftly.app/Contents/MacOS/Swiftly
///
/// **Development builds only.**
@MainActor
enum ScrollProbe {
    private static let log = Logger(subsystem: "de.paulherter.swiftly", category: "scrollprobe")
    private static var tick: Timer?
    private static var steps = 0
    private static weak var area: NSScrollView?
    private static var beginning: CGFloat = 0
    private static var wideItTravel: CGFloat = 0
    private static var range: CGFloat = 0
    /// How often a scrollable page has been searched for already.
    private static var rampUps = 0

    static var demanded: Bool {
        ProcessInfo.processInfo.environment["SWIFTLY_SCROLLPROBE"] != nil
    }

    /// Which section is opened before the run. Home and a library page are **not** the
    /// same: one reads the scroll offset only in its bar, the other also in its own
    /// body, and that difference is what is being measured.
    ///
    /// SWIFTLY_SCROLLPROBE=filme   (or serien, merkliste, start)
    private static var section: AppCommand? {
        switch ProcessInfo.processInfo.environment["SWIFTLY_SCROLLPROBE"] {
        case "filme": .movies
        case "serien": .seriesList
        case "merkliste": .watchlist
        case "downloads": .downloads
        case "einstellungen": .settings
        default: nil
        }
    }

    /// Waits until the page is settled, then scrolls down and up.
    static func start() {
        guard demanded else { return }
        log.notice("Probe angefordert — Start in 6 s")
        // Open the section first, then wait for it to settle: a probe on a page shorter
        // than its window measures nothing.
        if let section {
            Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
                MainActor.assumeIsolated {
                    log.notice("oeffne \(section.rawValue, privacy: .public)")
                    CommandPost.dispatch(section)
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 18, repeats: false) { _ in
            MainActor.assumeIsolated { drive() }
        }
    }

    private static func drive() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            log.notice("kein sichtbares Fenster")
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // **Check first that there is something to scroll.** A probe that moves nothing
        // measures nothing, and "zero dropped frames" would have looked like success.
        area = largeScrollArea(in: window.contentView)
        guard let f = area else {
            log.notice("keine Scrollflaeche gefunden — Probe sagt nichts aus")
            return
        }
        // **A page shorter than its window cannot scroll.** Content of 446 in a window of
        // 833 gives a maximum travel of 0 pt, and would have looked like "zero dropped
        // frames" success.
        let height = f.documentView?.frame.height ?? 0
        guard height > f.frame.height + 40 else {
            // **Look again instead of giving up.** The page may not be there yet, and "nothing
            // to scroll" would look like a finding. Ten attempts one second apart settle it.
            rampUps += 1
            guard rampUps < 12 else {
                log.notice("Inhalt \(Int(height)) in \(Int(f.frame.height)) — nichts zu scrollen")
                return
            }
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
                MainActor.assumeIsolated { drive() }
            }
            return
        }
        range = height - f.frame.height
        beginning = f.contentView.bounds.origin.y
        wideItTravel = 0
        log.notice("""
            Scrollflaeche \(Int(f.frame.width))x\(Int(f.frame.height)),             Inhalt \(Int(f.documentView?.frame.height ?? 0)),             Schluesselfenster \(window.isKeyWindow), aktiv \(NSApp.isActive)
            """)
        log.notice("Fahrt beginnt bei \(Int(beginning))")
        steps = 0
        // 120 events per second, as dense as a trackpad delivers them.
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { step(window) }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    /// **AppKit's own route, not a rebuilt event.**
    ///
    /// Rebuilt scroll-wheel events posted via `NSApp.postEvent` do not reach an
    /// `NSScrollView` (maximum travel measured as 0 pt). Instead the clip view itself is
    /// moved. That is neither the rubber band nor a trackpad's momentum, but it is the
    /// part that matters here: the content moves under our overlays once per frame at
    /// 120 Hz.
    private static func step(_ window: NSWindow) {
        steps += 1
        guard let f = area, let doc = f.documentView else { return }
        guard steps <= 720 else {
            tick?.invalidate(); tick = nil
            log.notice("""
                Fahrt beendet nach \(steps) Bildern,                 weitester Weg \(Int(wideItTravel)) Punkt
                """)
            return
        }
        // Six seconds: three times down, three times up, 120 frames each.
        let phase = Double(steps % 240) / 240
        let share = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        let target = CGPoint(x: 0, y: (doc.isFlipped ? 1 : -1) * range * share)
        f.contentView.scroll(to: target)
        f.reflectScrolledClipView(f.contentView)
        let distance = abs(f.contentView.bounds.origin.y - beginning)
        if distance > wideItTravel { wideItTravel = distance }
    }

    /// The largest scroll area in the tree: the page, not a row within it.
    private static func largeScrollArea(in viewRef: NSView?) -> NSScrollView? {
        guard let viewRef else { return nil }
        var best: NSScrollView?
        func go(_ v: NSView) {
            // **Choose by content, not by frame.** On a section change the old root stays in
            // the tree; both areas are then equally tall, and "the first with the largest
            // height" picked the wrong one.
            if let s = v as? NSScrollView, s.frame.height > 200,
               (s.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) {
                best = s
            }
            v.subviews.forEach(go)
        }
        go(viewRef)
        // **Name all of them, not just the chosen one.** Without this line it is not
        // visible whether the page is missing or the wrong area was chosen.
        var all: [String] = []
        func tally(_ v: NSView) {
            if let sv = v as? NSScrollView {
                all.append("\(Int(sv.frame.width))x\(Int(sv.frame.height))"
                    + "/Inhalt \(Int(sv.documentView?.frame.height ?? 0))")
            }
            v.subviews.forEach(tally)
        }
        tally(viewRef)
        log.notice("Scrollflaechen: \(all.joined(separator: " · "), privacy: .public)")
        return best
    }
}

/// **The bare comparison view: the halving.**
///
/// A `ScrollView` over a hundred plain rows without any of our building blocks: no
/// style, no overlay, no bar, no `pagesScroll()`, no measurement. Only SwiftUI and
/// AppKit.
///
/// It answers the one question nothing else can: **is the stutter caused by what we
/// lay on top, or by the window?** If it feels smooth, our structure is the
/// difference; if it feels equally sluggish, window, framework or device is the
/// cause and our pages offer nothing to fix.
///
/// The way there goes through the environment so nobody sees it by accident and
/// nobody has to click:
///
/// SWIFTLY_NACKT=1 .../Swiftly.app/Contents/MacOS/Swiftly
///
/// **Development builds only.**
struct BareSame: View {
    static var demanded: Bool {
        ProcessInfo.processInfo.environment["SWIFTLY_NACKT"] != nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0 ..< 100, id: \.self) { nr in
                    Text(verbatim: "Zeile \(nr + 1)")
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .frame(height: 46)
                    Divider()
                }
            }
        }
    }
}
#endif
