import JellyfinKit
import SwiftUI

/// Der Kopf der Detailseiten in der **breiten** Fassung: quer komponiert.
///
/// Auf dem iPhone liegt das Heldbild oben und alles Weitere darunter — bei
/// 390 Punkt Breite gibt es keine andere Möglichkeit. Sobald Breite da ist,
/// ist das die falsche Anordnung: ein 300 Punkt hoher Streifen über 1000
/// Punkt ist kein Heldbild mehr, sondern ein Briefschlitz, und der Text
/// darunter läuft über eine Zeilenlänge, die niemand liest.
///
/// Diese Anordnung ist vom **Fernseher** übernommen, wo sie sich bewährt hat
/// (`Sources/tvOS/DetailView.swift`): das Bild füllt die Fläche als Grund,
/// Poster und Textblock stehen nebeneinander, alles linksbündig unten. Zwei
/// Schleier machen es lesbar — einer von links für die Schrift, einer von
/// unten für die Knöpfe. Ohne den linken steht weiße Schrift irgendwann auf
/// einem hellen Himmel.
///
/// Der schöne Nebeneffekt: **das Poster setzt das Maß.** Der Textblock ist
/// so breit, wie neben einem 168er Poster übrig bleibt — es braucht keine
/// erfundene Lesespalte, um die Zeilen kurz zu halten.
///
/// Die Höhe bemisst sich am Inhalt, nicht am Schirm: Poster 252 plus 40
/// unten plus Luft. Auf dem Fernseher füllt das Heldbild die vollen 1080
/// Punkt, und das trägt dort — auf einem iPad hieße volle Höhe nur, dass man
/// zur Beschreibung erst scrollen muss.
///
/// Steht bewusst in einem eigenen Baustein: Film- und Serienseite teilen
/// diesen Kopf. Zweimal geschrieben wäre er zweimal zu ändern.
struct Heldkopf<Inhalt: View>: View {
    let bild: URL?
    let poster: URL?
    let titel: String
    let nebenzeile: String
    /// Anteil des schon Gesehenen, als Balken am unteren Rand des Posters.
    ///
    /// Dort und nicht im Knopf — dieselbe Entscheidung wie auf dem
    /// Fernseher: „Fortsetzen ab 51:10" bricht um und reißt die Knopfreihe
    /// schief. Fortschritt zeigt diese App ohnehin überall als Balken.
    var fortschritt: Double?
    /// Belegzeile, Knöpfe, Aktionsreihe — was unter dem Titel steht,
    /// entscheidet die Seite.
    @ViewBuilder var inhalt: () -> Inhalt

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            hintergrund

            HStack(alignment: .bottom, spacing: 32) {
                Bild(url: poster,
                     breite: Stil.heldPosterBreite, hoehe: Stil.heldPosterHoehe,
                     ecke: Stil.eckeKachel, fortschritt: fortschritt) {
                    Stil.flaeche.overlay {
                        Image(systemName: "film").foregroundStyle(Stil.schriftSehrLeise)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(titel)
                        .font(.system(size: 40, weight: .bold))
                        .tracking(-1)
                        .foregroundStyle(Stil.schrift)
                        .lineLimit(2)
                    Text(nebenzeile)
                        .font(.system(size: 14))
                        .foregroundStyle(Stil.schriftLeise)
                        .lineLimit(1)
                        .padding(.top, 8)
                    inhalt()
                        .padding(.top, 12)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Stil.randSeiteBreit)
            .padding(.bottom, 40)
        }
        .frame(height: Stil.heldHoeheBreit)
        .clipped()
    }

    private var hintergrund: some View {
        ZStack {
            Stil.grund
            Bild(url: bild, ecke: 0)
            // Von links, damit die Schrift steht.
            LinearGradient(stops: [
                .init(color: Stil.grund.opacity(0.96), location: 0),
                .init(color: Stil.grund.opacity(0.82), location: 0.32),
                .init(color: Stil.grund.opacity(0.18), location: 0.62),
                .init(color: Stil.grund.opacity(0),    location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            // Von unten, damit die Knopfreihe steht und der Übergang in die
            // Seite darunter nicht abschneidet.
            LinearGradient(stops: [
                .init(color: Stil.grund,               location: 0),
                .init(color: Stil.grund.opacity(0.95), location: 0.26),
                .init(color: Stil.grund.opacity(0.72), location: 0.44),
                .init(color: Stil.grund.opacity(0.30), location: 0.60),
                .init(color: Stil.grund.opacity(0),    location: 0.78),
            ], startPoint: .bottom, endPoint: .top)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Handlungen als Tafel

/// Wo der Mehr-Knopf steht. Die Tafel hängt sich daran.
///
/// Über eine Ankervorgabe und nicht über feste Koordinaten: der Knopf sitzt
/// auf Film- und Serienseite an verschieden weit rechts endenden Knopfreihen,
/// und die Reihe verschiebt sich mit der Länge der Beschriftung
/// („Fortsetzen ab 1:42:10" gegen „Abspielen").
struct Handlungsanker: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?,
                       nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Merkt sich diesen Knopf als Aufhängepunkt für die Handlungstafel.
    func alsHandlungsanker() -> some View {
        anchorPreference(key: Handlungsanker.self, value: .bounds) { $0 }
    }
}

/// Dieselben Handlungen wie im `Handlungsblatt`, aber als Tafel am Auslöser.
///
/// Auf 1024 Punkt Breite ist ein Blatt von unten falsch: der Eintrag wäre
/// 50 Punkt hoch und 1000 breit, und der Weg vom Knopf bis zum unteren
/// Bildrand ist der ganze Schirm.
///
/// Drei Unterschiede zum Blatt, und jeder hat denselben Grund — die Tafel ist
/// klein und ihr Auslöser bleibt sichtbar daneben stehen:
/// - **alle vier Ecken** 12 statt nur die oberen,
/// - **keine Abbrechen-Zeile**; daneben tippen schließt. Eine Abbrechen-Zeile
///   ist die Grammatik eines Blatts, das die halbe Höhe einnimmt,
/// - **30 Prozent Abdunkelung** statt 55. Ein 320er Kasten braucht keinen
///   halben Vorhang.
///
/// Zeilen, Haarlinien, Titelgröße und Farben sind unverändert die des Blatts.
struct Handlungstafel: View {
    @Binding var offen: Bool
    let titel: String
    let handlungen: [Titelhandlung]
    /// Rahmen des Auslösers im selben Raum wie diese Tafel.
    let anker: CGRect
    /// Der Raum, in dem die Tafel liegen darf — damit sie nicht aus dem
    /// Fenster läuft.
    let raum: CGSize

    private static let breite: CGFloat = 320
    private static let abstand: CGFloat = 12

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.black.opacity(0.30))
                .ignoresSafeArea()
                .onTapGesture { schliessen() }

            tafel
                .frame(width: Self.breite)
                .offset(x: links, y: oben)
        }
        .transition(.opacity)
    }

    /// Rechtsbündig zum Auslöser, aber nie über den Rand hinaus.
    private var links: CGFloat {
        let gewuenscht = anker.maxX - Self.breite
        return min(max(Stil.randSeiteBreit, gewuenscht),
                   raum.width - Self.breite - Stil.randSeiteBreit)
    }

    /// Unter dem Auslöser — es sei denn, darunter ist kein Platz mehr; dann
    /// darüber.
    private var oben: CGFloat {
        let hoehe = 48 + CGFloat(handlungen.count) * 50
        let darunter = anker.maxY + Self.abstand
        guard darunter + hoehe > raum.height - 24 else { return darunter }
        return max(24, anker.minY - Self.abstand - hoehe)
    }

    private var tafel: some View {
        VStack(spacing: 0) {
            Text(titel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Stil.schriftLeise)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Stil.randAbstand)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ForEach(Array(handlungen.enumerated()), id: \.element.id) { paar in
                if paar.offset > 0 {
                    Rectangle().fill(Stil.linie).frame(height: 1)
                        .padding(.leading, 52)
                }
                Button {
                    schliessen()
                    paar.element.tun()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: paar.element.symbol)
                            .font(.system(size: 17))
                            .frame(width: 20)
                        Text(paar.element.text)
                            .font(.system(size: 16))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(paar.element.warnend ? Stil.warnung : Stil.schrift)
                    .padding(.horizontal, Stil.randAbstand)
                    .frame(height: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12).fill(Stil.flaeche)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Stil.rand)
        }
    }

    private func schliessen() {
        withAnimation(.snappy(duration: 0.22)) { offen = false }
    }
}

// MARK: - Wenn iPadOS seine Knöpfe auf unser Fenster legt

private struct FensterknoepfeSchluessel: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// iPadOS legt eigene Fensterknöpfe über die obere linke Ecke.
    ///
    /// Sobald die App sich den Schirm teilt — geteilter Bildschirm, Stage
    /// Manager —, setzt iPadOS seine Ampel auf das Fenster. Genau dort sitzt
    /// unser Zurückpfeil: `Seitenpfeil` hält 8 Punkt von links und 6 von
    /// oben. Im Vollbild schiebt ihn die Statusleiste nach unten, in einem
    /// Fenster gibt es die nicht — und die Knöpfe decken ihn zu.
    ///
    /// Erkannt wird es an der Breite, nicht an der Größenklasse: „teilt sich
    /// den Schirm" heißt genau, dass das Fenster schmaler ist als der Schirm.
    /// Slide Over, halber und Zweidrittel-Schirm fallen alle darunter,
    /// Vollbild nicht.
    var fensterknoepfe: Bool {
        get { self[FensterknoepfeSchluessel.self] }
        set { self[FensterknoepfeSchluessel.self] = newValue }
    }
}


/// Wo iPadOS seine Fensterknöpfe hinlegt, und wie viel Platz sie brauchen.
///
/// **Warum das eine Funktion ist und nicht nur der Umgebungswert oben:** der
/// Player ist ein `fullScreenCover`. Er hängt nicht unter `HauptView`, und
/// er ignoriert den sicheren Bereich ausdrücklich — dort liegt schließlich
/// das Bild. Ein Sicherheitsabstand, den sich der Rahmen nimmt, erreicht ihn
/// deshalb nicht. Was im Player oben Platz braucht, muss ihn sich selbst
/// nehmen.
///
/// Genau daran ist die erste Fassung gescheitert: sie hat den Rahmen
/// gepolstert und den Player vergessen, weil er wie ein Teil davon aussieht.
enum Fensterknoepfe {
    /// Höhe, die freizuhalten ist. Die Ampel sitzt in einem rund 44 Punkt
    /// hohen Feld oben links; 32 zusätzlich zu den 18, die die Kopfzeilen
    /// ohnehin halten, schiebt den Knopf darunter.
    static let hoehe: CGFloat = 32

    /// Die App teilt sich den Schirm — geteilter Bildschirm, Slide Over,
    /// Stage Manager. Erkannt an der Breite: „teilt sich den Schirm" heißt
    /// genau, dass das Fenster schmaler ist als der Schirm.
    @MainActor
    static func imFenster(fensterbreite: CGFloat) -> Bool {
        guard Stil.amPad, fensterbreite > 0 else { return false }
        let schirm = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 0
        return schirm > 0 && fensterbreite < schirm - 8
    }
}
