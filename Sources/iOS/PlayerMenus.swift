import AVKit
import SwiftUI

// MARK: - AirPlay and the screen lock

/// A hidden system route picker; `show` counts up to open it (the core's "AirPlay" row asks for it).
struct AirPlayPickerTrigger: UIViewRepresentable {
    let show: Int

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.alpha = 0.011
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        guard show > context.coordinator.shown else { return }
        context.coordinator.shown = show
        (view.subviews.compactMap { $0 as? UIButton }.first)?.sendActions(for: .touchUpInside)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var shown = 0 }
}

/// "Bildschirm sperren": swallows every touch; a tap says how to unlock, holding unlocks.
struct ScreenLockOverlay: View {
    let unlock: () -> Void
    @State private var hint = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            if hint {
                HStack(spacing: 8) {
                    Image(icon: "lock.fill", size: 14).font(.app(size: 14, weight: .semibold))
                    Text("Zum Entsperren gedrückt halten").font(.app(size: 14, weight: .semibold))
                }
                .foregroundStyle(Theme.font)
                .padding(.horizontal, 16).frame(height: 40)
                .background(Theme.raised, in: Capsule())
                .transition(.opacity)
            }
        }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { hint = true }
            hideTask?.cancel()
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { hint = false }
            }
        }
        .onLongPressGesture(minimumDuration: 0.6) { unlock() }
        .sensoryFeedback(.success, trigger: hint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Bildschirm gesperrt"))
        .accessibilityHint(Text("Zum Entsperren gedrückt halten"))
        .accessibilityAction(named: Text("Entsperren"), unlock)
    }
}
