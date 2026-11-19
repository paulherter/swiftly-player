import SwiftUI

// MARK: - Glass

/// **The backing of every bar part.** One glass, never switched by picture brightness: black 18 % over an
/// ultra-thin material (dark), a hairline inner edge of white 10 %, no shadow. It is only there so the symbols keep their
/// footing over a bright picture; it fades with the bar and is never animated by itself.
struct PlayerGlass<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    Theme.scrimGlass
                }
                .clipShape(shape)
            }
            .overlay { shape.strokeBorder(Theme.glassEdge, lineWidth: 1) }
    }
}

extension View {
    func playerGlass<S: InsettableShape>(_ shape: S) -> some View { modifier(PlayerGlass(shape: shape)) }
}
