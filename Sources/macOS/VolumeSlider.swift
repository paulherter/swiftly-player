import AppKit
import SwiftUI

/// **Player volume**: the speaker is the last half of the menu capsule; hovering it (or the pill) drops a
/// vertical slider DOWN from the button, top = 100 %.
///
/// Dimensions (the same as the desktop player, `vol_dropdown`): pill 40 wide, 126 high (10 top, track 88 with a 4 pt
/// line and a 12 pt thumb, value label 14 below, 8 bottom), 4 pt under the half, glass of the bar, grows with the sheet
/// spring and goes back when the pointer has left both the button and the pill (60 ms bridge for the 4 pt gap).
///
/// **Why it could stay open:** the hover callbacks are the only thing that closed it, and AppKit sends no "exited" while
/// a mouse button is down (a drag on the pill that ends outside it) nor when the pointer leaves the window fast. The
/// flag then stayed true for good. While it is open, the real pointer position is now compared with the control's area
/// (`PointerProbe`), so a lost "exited" cannot keep it open; only a running drag keeps it open.
struct VolumeSlider: View {
    let mass: PlayerMetric
    /// 0 to 1.
    @Binding var value: Double
    /// A key (arrows, M) opened the slider briefly.
    let expanded: Bool
    /// Is someone dragging? The player then keeps the control bar visible.
    @Binding var pulls: Bool
    let mutedToggle: () -> Void
    /// The wheel changed the value (fraction from 0 to 1, signed). The player then
    /// keeps the bar and slider open.
    let wheelRotated: (Double) -> Void

    @State private var overSpeaker = false
    @State private var overPill = false
    /// The pointer wants the pill out; follows `overSpeaker || overPill` at once when true, 140 ms late when false.
    @State private var held = false
    @State private var wheelSnap = WheelSnap()
    @State private var probe = PointerProbe.Box()

    private var wants: Bool { overSpeaker || overPill }
    private var opened: Bool { held || pulls || expanded }

    private static let pillWidth: CGFloat = 40
    private static let padTop: CGFloat = 10
    private static let track: CGFloat = 88
    private static let inset: CGFloat = 6
    private static let labelGap: CGFloat = 6
    private static let labelHeight: CGFloat = 14
    private static let padBottom: CGFloat = 8
    private static let pillHeight: CGFloat = padTop + track + labelGap + labelHeight + padBottom
    /// Gap between the lower edge of the half (36) and the pill.
    private static let gap: CGFloat = 4

    /// Only `speaker.wave.2` has a Phosphor asset (`IconMap`); muted adds a slash drawn in the same stroke.
    private let symbol = "speaker.wave.2"

    var body: some View {
        IconButton(symbol: symbol,
                   label: value <= 0 ? "Ton an" : "Ton aus",
                   mass: mass, key: "M", slashed: value <= 0, bar: .half, tip: !opened, action: mutedToggle)
            .onHover { overSpeaker = $0 }
            .background(PointerProbe(box: probe))
            .overlay(alignment: .top) { pill.offset(y: 36 + Self.gap) }
            .zIndex(opened ? 2 : 0)
            .task(id: wants) {
                if wants { held = true; return }
                try? await Task.sleep(for: .milliseconds(60))
                if !Task.isCancelled { held = false }
            }
            // The watchdog: while the pill is out and nobody drags, the real pointer must be over the button or the pill.
            .task(id: opened) {
                while opened, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !pulls, !Task.isCancelled else { continue }
                    if (overSpeaker || overPill), !probe.contains(pillBelow: Self.gap + Self.pillHeight, pillWidth: Self.pillWidth) {
                        overSpeaker = false
                        overPill = false
                    }
                }
            }
            .onChange(of: wants) { _, now in
                if now { wheelSnap.start(wheelRotated) } else { wheelSnap.finish() }
            }
            .onDisappear { wheelSnap.finish() }
            .accessibilityElement(children: .contain)
    }

    /// The glass pill. Full size inside, the frame grows from the top and clips; so it unfolds downwards.
    private var pill: some View {
        let motion: Animation = Motion.sheet
        return ZStack(alignment: .top) {
            Capsule().fill(Color.white.opacity(0.18)).frame(width: 4, height: Self.track)
                .padding(.top, Self.padTop)
            Capsule().fill(Theme.accent).frame(width: 4, height: fillHeight)
                .padding(.top, Self.padTop + Self.track - fillHeight)
            Circle().fill(Color.white).frame(width: 12, height: 12)
                .padding(.top, Self.padTop + Self.track - Self.inset - 6 - (Self.track - 2 * Self.inset) * CGFloat(level))
            Text(verbatim: "\(Int((level * 100).rounded())) %")
                .font(.app(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.fontQuiet)
                .frame(width: Self.pillWidth, height: Self.labelHeight)
                .padding(.top, Self.padTop + Self.track + Self.labelGap)
        }
        .frame(width: Self.pillWidth, height: Self.pillHeight, alignment: .top)
        .playerGlass(Capsule())
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                pulls = true
                value = Self.level(at: g.location.y)
            }
            .onEnded { _ in pulls = false })
        .onHover { overPill = $0 }
        .frame(width: Self.pillWidth, height: opened ? Self.pillHeight : 0, alignment: .top)
        .clipped()
        .opacity(opened ? 1 : 0)
        .allowsHitTesting(opened)
        .animation(motion, value: opened)
        .accessibilityElement()
        .accessibilityLabel(Text("Lautstärke"))
        .accessibilityValue(Text("\(Int((level * 100).rounded())) %"))
        .accessibilityAdjustableAction { bearing in
            switch bearing {
            case .increment: value = min(value + 0.05, 1)
            case .decrement: value = max(value - 0.05, 0)
            @unknown default: break
            }
        }
    }

    private var level: Double { min(max(value, 0), 1) }

    /// The fill runs from the bottom to the thumb's centre; nothing at 0.
    private var fillHeight: CGFloat {
        level <= 0 ? 0 : Self.inset + (Self.track - 2 * Self.inset) * CGFloat(level)
    }

    /// Volume for a pointer height inside the pill (top of the track = 100 %); clamps outside the pill, so a drag
    /// that leaves it keeps working.
    static func level(at y: CGFloat) -> Double {
        let top = padTop + inset
        return Double(1 - min(max((y - top) / (track - 2 * inset), 0), 1))
    }

    /// **Mouse wheel and two-finger scroll over slider and speaker.**
    ///
    /// An event monitor instead of a view on top, which would cover the slider and
    /// take its clicks. It runs only while the pointer is over the control and
    /// **swallows** the event, otherwise whatever would normally receive the wheel
    /// underneath would scroll too.
    ///
    /// `scrollingDeltaY` already includes the system direction (natural scrolling on
    /// or off); up is louder. A wheel clicks: one detent is 5 %, at most three at a
    /// time. A trackpad delivers points: 24 points are 5 %, **without rounding** so
    /// no small push is lost.
    @MainActor
    final class WheelSnap {
        private var snap: Any?

        func start(_ rotated: @escaping (Double) -> Void) {
            guard snap == nil else { return }
            snap = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                let d = Double(event.scrollingDeltaY)
                guard d != 0 else { return nil }
                let step = event.hasPreciseScrollingDeltas
                    ? d / 24 * 0.05
                    : min(max(d, -3), 3) * 0.05
                rotated(step)
                return nil
            }
        }

        func finish() {
            if let snap { NSEvent.removeMonitor(snap) }
            snap = nil
        }
    }
}

/// The control's place on screen, read from AppKit so no coordinate guess is involved: the button plus the pill below it.
struct PointerProbe: NSViewRepresentable {
    @MainActor final class Box {
        weak var view: NSView?

        /// Is the real pointer over the button or the pill under it (centred below, `gap` + height tall)?
        func contains(pillBelow height: CGFloat, pillWidth: CGFloat) -> Bool {
            guard let view, let window = view.window else { return true }
            let spot = window.mouseLocationOutsideOfEventStream
            let button = view.convert(view.bounds, to: nil)
            // Window coordinates grow upwards: "below" is a smaller y.
            let pill = NSRect(x: button.midX - pillWidth / 2, y: button.minY - height, width: pillWidth, height: height)
            return button.insetBy(dx: -1, dy: -1).contains(spot) || pill.insetBy(dx: -1, dy: -1).contains(spot)
        }
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}
