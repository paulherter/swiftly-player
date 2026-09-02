import SwiftUI

/// Das Hintergrundbild einer Detailseite — **rechts, nicht über die volle
/// Breite**, und mit einer Maske statt eines Anstrichs ausgeblendet.
///
/// Wörtlich von der tvOS-Fassung (`Kulisse` und `Kulissenblende` in
/// `Sources/tvOS/TVBausteine.swift`), nur auf Fenstermaße gebracht: dort
/// 1180 × 700 in einem 1920 breiten Bild, hier derselbe Anteil.
///
/// **Warum Maske und nicht Anstrich:** Ein Anstrich endet in
/// undurchsichtigem `Stil.grund` und setzt damit voraus, dass der Hintergrund
/// genau das ist. Sobald er sich einfärbt — und das tut er, siehe
/// `Bildfarbe` —, steht die übermalte Fläche als Fleck darin. Eine Maske
/// endet in Durchsichtigkeit, und was dahinterliegt kommt durch.
struct Kulisse: View {
    let url: URL?
    var hoehe: CGFloat

    var body: some View {
        GeometryReader { raum in
            let breite = max(raum.size.width * 0.62, 520)
            bild
                .frame(width: breite, height: hoehe)
                .clipped()
                .kulissenblende()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: hoehe)
        .allowsHitTesting(false)
    }

    private var bild: some View {
        ZStack {
            if let url {
                AsyncImage(url: url) { stufe in
                    if let abbild = stufe.image {
                        abbild.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }
        }
    }
}

extension View {
    func kulissenblende() -> some View { modifier(Kulissenblende()) }
}

/// Die Kurve stammt unverändert aus der tvOS-Fassung — dort ist sie nach
/// vier Umbauten entstanden, und der Kommentar dort erklärt, warum jede
/// Änderung daran sie verschlechtert hat.
struct Kulissenblende: ViewModifier {
    func body(content: Content) -> some View {
        content
            .mask {
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.00), location: 0),
                    .init(color: .white.opacity(0.05), location: 0.15),
                    .init(color: .white.opacity(0.22), location: 0.29),
                    .init(color: .white.opacity(0.50), location: 0.45),
                    .init(color: .white.opacity(0.75), location: 0.57),
                    .init(color: .white.opacity(0.90), location: 0.70),
                    .init(color: .white.opacity(0.98), location: 0.85),
                    .init(color: .white.opacity(1.00), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
            .mask {
                LinearGradient(stops: [
                    .init(color: .white.opacity(1.00), location: 0),
                    .init(color: .white.opacity(1.00), location: 0.50),
                    .init(color: .white.opacity(0.88), location: 0.60),
                    .init(color: .white.opacity(0.62), location: 0.70),
                    .init(color: .white.opacity(0.34), location: 0.80),
                    .init(color: .white.opacity(0.14), location: 0.89),
                    .init(color: .white.opacity(0.04), location: 0.95),
                    .init(color: .white.opacity(0.00), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
    }
}

/// Nebenknopf der Knopfreihe: abgerundetes Quadrat, **nur Symbol**.
///
/// tvOS hat sich bewusst gegen Beschriftungen entschieden — „Merkliste
/// erreicht eigentlich das Merklistensymbol an sich". Ohne Beschriftung ist
/// der Name für VoiceOver Pflicht (E8), deshalb der ausdrückliche `titel`.
struct Nebenknopf: View {
    let symbol: String
    let titel: LocalizedStringKey
    var aktiv = false
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(aktiv ? Stil.grund : Stil.schrift)
                .frame(width: Stil.hauptknopfHoehe, height: Stil.hauptknopfHoehe)
                .background(aktiv ? Stil.schrift
                                  : Stil.schrift.opacity(schwebt ? 0.22 : 0.14),
                            in: RoundedRectangle(cornerRadius: Stil.ecke))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityLabel(Text(titel))
        .accessibilityAddTraits(aktiv ? [.isButton, .isSelected] : .isButton)
    }
}
