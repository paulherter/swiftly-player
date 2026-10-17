import AppKit
import SwiftUI

/// **Player volume**: speaker button first in the icon row; hovering it unfolds a
/// horizontal slider to its left.
///
/// Dimensions: compartment 0 to 96 pt in 0.18 s (ease-out), slider 88 pt, track 4 pt,
/// thumb 12 pt, shown only while hovering or dragging.
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

    @State private var atop = false
    @State private var wheelSnap = WheelSnap()

    private var opened: Bool { atop || pulls || expanded }

    private var symbol: String {
        if value <= 0 { return "speaker.slash" }
        return value < 0.5 ? "speaker.wave.1" : "speaker.wave.3"
    }

    var body: some View {
        HStack(spacing: 0) {
            SliderControl(value: $value, pulls: $pulls, height: mass.button, large: opened)
                .frame(width: 88)
                .padding(.horizontal, 4)
                .frame(width: opened ? 96 : 0, height: mass.button)
                .clipped()
                .opacity(opened ? 1 : 0)
                // **Percentage only while adjusting**, under the thumb, outside `clipped()`
                // so the compartment does not cut it off.
                .overlay(alignment: .bottomLeading) {
                    if pulls || expanded {
                        Text(verbatim: "\(Int((value * 100).rounded())) %")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.fontQuiet)
                            .frame(width: 44)
                            .offset(x: 4 + Self.handleX(value, width: 88) - 22, y: 14)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .animation(Theme.motionReduced ? nil : .easeOut(duration: 0.12), value: pulls || expanded)
            IconButton(symbol: symbol,
                        label: value <= 0 ? "Ton an" : "Ton aus",
                        mass: mass, action: mutedToggle)
        }
        .onHover { inner in
            atop = inner
            if inner { wheelSnap.start(wheelRotated) } else { wheelSnap.finish() }
        }
        .onDisappear { wheelSnap.finish() }
        .animation(Theme.motionReduced ? nil : .easeOut(duration: 0.18), value: opened)
        .accessibilityElement(children: .contain)
    }

    /// Centre of the thumb. **The thumb stays fully inside the track**: its travel
    /// ends one radius before each end. At 0 and 100 % it used to stick out by half
    /// and the compartment cut it off with a hard edge.
    static func handleX(_ value: Double, width: CGFloat) -> CGFloat {
        6 + (width - 12) * CGFloat(min(max(value, 0), 1))
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

    private struct SliderControl: View {
        @Binding var value: Double
        @Binding var pulls: Bool
        let height: CGFloat
        let large: Bool

        var body: some View {
            GeometryReader { geo in
                let width = geo.size.width
                let x = VolumeSlider.handleX(value, width: width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(height: 4)
                    Capsule().fill(Theme.accent).frame(width: value <= 0 ? 0 : x, height: 4)
                    Circle().fill(Color.white)
                        .frame(width: 12, height: 12)
                        .offset(x: x - 6)
                        .opacity(large ? 1 : 0)
                        .scaleEffect(large ? 1 : 0.6)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        pulls = true
                        value = Double(min(max((g.location.x - 6) / max(width - 12, 1), 0), 1))
                    }
                    .onEnded { _ in pulls = false })
            }
            .frame(height: height)
            .accessibilityElement()
            .accessibilityLabel(Text("Lautstärke"))
            .accessibilityValue(Text("\(Int((value * 100).rounded())) %"))
            .accessibilityAdjustableAction { bearing in
                switch bearing {
                case .increment: value = min(value + 0.05, 1)
                case .decrement: value = max(value - 0.05, 0)
                @unknown default: break
                }
            }
        }
    }
}
