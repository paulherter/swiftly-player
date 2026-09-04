import JellyfinKit
import SwiftUI

/// Die Marken als Vektorpfade, unverändert aus den SVG-Vorlagen.
///
/// Die Zeichenketten sind bewusst **nicht** umbrochen. Ein Umbruch mitten in
/// einer Zahl macht aus „2.37" die beiden Zahlen „2." und „37" — der Pfad
/// zerfällt dann in ein paar Punkte, ohne dass irgendwo ein Fehler auftritt.
enum Marke {

    /// viewBox einschließlich Ursprung — der liegt hier nicht bei null.
    static let wortmarkeBox = CGRect(x: Markenpfade.wortmarkeRahmen.x,
                                     y: Markenpfade.wortmarkeRahmen.y,
                                     width: Markenpfade.wortmarkeRahmen.breite,
                                     height: Markenpfade.wortmarkeRahmen.hoehe)
    static let signetBox = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    /// Die Abspielform etwas größer als in der Vorlage, um ihre eigene Mitte.
    /// Derselbe Wert steckt im App-Symbol.
    static let signetLupe: CGFloat = 1.14

    /// Eckenradius des Zeichens, als Anteil seiner Kantenlänge.
    static let signetEcke: CGFloat = 230.0 / 1024

    /// Die Farben der Vorlage. Bewusst eigene Werte und nicht `Stil.akzent`:
    /// die Marke ist gesetzt, das Erscheinungsbild der App darf sich davon
    /// unabhängig bewegen.
    static let markeAkzent = Color(red: 0.184, green: 0.859, blue: 0.753)   // #2FDBC0
    static let markeFlaeche = Color(red: 0.090, green: 0.094, blue: 0.106)  // #17181B

    /// Die Buchstaben „swiftly“.
    static let wortmarkeSchrift = Markenpfade.wortmarke

    /// Das Zeichen über dem „i“.
    static let wortmarkeAkzent = "M1407.4 -748.5 L1508.1 -690.8 A28.0 28.0 0 0 1 1508.1 -642.2 L1407.4 -584.5 A28.0 28.0 0 0 1 1365.5 -608.8 L1365.5 -724.2 A28.0 28.0 0 0 1 1407.4 -748.5 Z"

    /// Die Abspielform im App-Zeichen.
    static let signetForm = "M440.1,280l285,163.2c38,21.7,51.2,70,29.6,108-7,12.3-17.2,22.5-29.6,29.6l-285,163.2c-37.9,21.8-86.3,8.6-108.1-29.3-6.9-12-10.5-25.6-10.5-39.4v-326.6c0-43.7,35.5-79.2,79.2-79.2,13.8,0,27.4,3.6,39.4,10.5Z"
}

// MARK: - Ansichten

/// Die Wortmarke „swiftly“.
struct Wortmarke: View {
    /// Gesamthöhe der Vorlage — Zeichen oben und Unterlänge des „y“ zählen mit,
    /// die Buchstaben selbst sind rund die Hälfte davon.
    var hoehe: CGFloat = 32
    var schrift: Color = Stil.schrift
    var akzent: Color = Marke.markeAkzent

    private var breite: CGFloat {
        hoehe * (Marke.wortmarkeBox.width / Marke.wortmarkeBox.height)
    }

    var body: some View {
        ZStack {
            SVGForm(daten: Marke.wortmarkeSchrift, box: Marke.wortmarkeBox).fill(schrift)
            SVGForm(daten: Marke.wortmarkeAkzent, box: Marke.wortmarkeBox).fill(akzent)
        }
        .frame(width: breite, height: hoehe)
        .accessibilityLabel("Swiftly")
    }
}

/// Das Zeichen: abgerundetes Quadrat mit der Abspielform.
///
/// Flach und ohne Zutaten — genau wie die Vorlage. Die Fläche ist ein
/// abgerundetes Rechteck statt eines Pfades, damit die Ecke bei jeder Größe
/// sauber bleibt.
struct Signet: View {
    var groesse: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: groesse * Marke.signetEcke, style: .continuous)
                .fill(Marke.markeFlaeche)
            SVGForm(daten: Marke.signetForm, box: Marke.signetBox)
                .fill(Marke.markeAkzent)
                // Um die Mitte der Form, nicht um die des Quadrats — eine
                // Abspielform sitzt bewusst etwas rechts davon.
                .scaleEffect(Marke.signetLupe,
                             anchor: UnitPoint(x: (322 + 755) / 2 / 1024,
                                               y: (270 + 744) / 2 / 1024))
        }
        .frame(width: groesse, height: groesse)
        .accessibilityLabel("Swiftly")
    }
}
