import JellyfinKit
import SwiftUI

// MARK: - Der Reihenabschnitt

/// Kopf und Streifen einer Reihe, mit den Abstaenden des Entwurfs.
///
/// **Eine Funktion, keine `View`-Struktur** — und das ist kein Geschmack.
/// tvOS haelt einen Reihentitel beim Fokussieren nur frei, wenn er ein
/// `Section`-Kopf ist (WWDC24, „Migrate your TVML app to SwiftUI": „that title
/// will automatically move out of the way as your lockups gain focus to avoid
/// being occluded"). Steckt die `Section` im `body` einer eigenen Struktur,
/// sieht der Stapel darueber nur noch diese Struktur, und die
/// Section-Eigenschaft ist weg. Eine Funktion mit `some View` reicht den
/// Abschnitt dagegen unveraendert durch.
///
/// Die Abstaende, einmal an einer Stelle:
///
///     ueber dem Titel   reihenKopfLuft   24
///     Titel bis Kacheln titelAbstand     36  (16 + reihenLuft)
///     Reihe bis Reihe   reihenAbstand    72  (28 + 20 + 24)
///
/// Startseite, Filmseite und Serienseite benutzen dieselbe Funktion. Wer sie
/// kopiert, laesst die Seiten auseinanderlaufen — genau das ist bei
/// `nachladen()` schon einmal passiert.
func reihenabschnitt<Kopf: View, Inhalt: View>(
    @ViewBuilder kopf: () -> Kopf,
    @ViewBuilder inhalt: () -> Inhalt
) -> some View {
    Section {
        inhalt()
            .padding(.bottom, Stil.reihenAbstand - Stil.reihenLuft - Stil.reihenKopfLuft)
    } header: {
        kopf()
            .padding(.horizontal, Stil.randSeite)
            .padding(.top, Stil.reihenKopfLuft)
            .padding(.bottom, Stil.titelAbstand - Stil.reihenLuft)
    }
}

/// Die waagerechte Flaeche unter einem Reihenkopf.
///
/// `scrollClipDisabled` ist Voraussetzung, kein Feinschliff: die fokussierte
/// Kachel waechst um 1,08 ueber ihre Layoutgroesse hinaus, und die Flaeche
/// wuerde sie an ihrer Kante beschneiden. `reihenLuft` faengt dieselbe
/// Vergroesserung senkrecht **innerhalb** der Reihe ab — nur deshalb darf die
/// senkrechte Flaeche darueber beschneiden, ohne je eine Kachel anzuschneiden.
/// **`hoehe` macht die Reihe unabhaengig vom Fokus.**
///
/// Ohne sie misst SwiftUI die Reihe an ihrem Inhalt — und der waechst, sobald
/// eine Kachel fokussiert ist (`fokusLupe` 1,08). Die Reihe wurde damit je
/// nach Fokus verschieden hoch gemessen, und ihr Abstand zum Reihenkopf
/// aenderte sich beim Hinein- und Herausgehen. Paul: „gehe ich runter auf die
/// Folge, geht die ganze Reihe ein Stueck nach unten; gehe ich wieder hoch,
/// ist der Abstand wieder richtig."
///
/// Das hat mich heute mehrfach in die Irre gefuehrt: es sah aus wie ein
/// Unterschied **zwischen Staffeln**, war aber einer zwischen fokussiert und
/// nicht. Feste Hoehe am Container half nicht — der waagerechte Streifen ist
/// darin gierig und zentriert seinen Inhalt. Sie gehoert an die Flaeche
/// selbst.
///
/// `reihenLuft` faengt das Wachsen weiter ab; sie sorgt dafuer, dass die
/// groessere Kachel innerhalb dieser Hoehe Platz hat, statt beschnitten zu
/// werden.
func streifen<Inhalt: View>(stand: Binding<String?>? = nil,
                            hoehe: CGFloat? = nil,
                            @ViewBuilder _ inhalt: () -> Inhalt) -> some View {
    let flaeche = ScrollView(.horizontal) {
        // Waagerecht bleibt der faule Stapel: hier setzt niemand den Fokus
        // von aussen, also kann keine Zuweisung an eine noch nicht erzeugte
        // Kachel ins Leere gehen. Auf der Startseite ist das anders, dort
        // steht aus genau diesem Grund ein `HStack`.
        LazyHStack(alignment: .top, spacing: Stil.kachelAbstand, content: inhalt)
            // Nur, damit `scrollPosition` sagen kann, welche Kachel vorn
            // liegt. Ein `scrollTargetBehavior` steht bewusst nicht dabei —
            // es soll nichts einrasten.
            .scrollTargetLayout()
    }
    .frame(height: hoehe)
    // **Die Fokusluft liegt aussen, nicht im Inhalt.**
    //
    // Sie stand als `padding` am `LazyHStack`, also **innerhalb** der
    // Scrollflaeche. Von dort aus wirkt sie erst, wenn die Flaeche ihren
    // Inhalt wirklich ausmisst — und das tut sie erst, wenn der Fokus
    // hineingeht. Beim Oeffnen fehlte sie deshalb, und die Kacheln standen
    // 20 Punkt zu hoch; beim ersten Fokussieren kam sie dazu und alles
    // rueckte.
    //
    // An Pauls zwei Bildern gemessen: Reihentitel steht in beiden bei 683,
    // die Kacheln bei 742 und 762. Die Differenz ist auf den Punkt
    // `reihenLuft` — deshalb war es nie ein Scrollen und nie das
    // Section-Verhalten, obwohl beides danach aussah.
    //
    // Aussen liegt sie im Layout und gilt immer. Beschnitten wird die
    // gewachsene Kachel trotzdem nicht: dafuer sorgt `scrollClipDisabled`.
    .padding(.vertical, Stil.reihenLuft)
    // **Am linken Rand ausfedern, nicht schneiden.**
    //
    // Ist die Reihe vorgescrollt, steht die vorige Kachel im seitlichen Rand
    // und wird dort hart abgeschnitten — samt halber Beschriftung. Uebermalen
    // geht nicht: der Grund ist gefaerbt, und eine Flaeche in #0B0B0D stuende
    // als Fleck darin. Also eine Maske, so breit wie der Rand.
    //
    // Sie kostet nichts, wenn nicht gescrollt ist: die erste Kachel beginnt
    // bei `randSeite`, also genau dort, wo die Maske voll deckt.
    .mask {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .white],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: Stil.randSeite)
            Color.white
        }
    }
    .scrollClipDisabled()
    .scrollIndicators(.hidden)
    // **Der seitliche Rand ist ein Inhaltsrand, kein Padding.**
    //
    // Als `padding` am Stapel lag er *innerhalb* der Scrollflaeche, und
    // `scrollPosition(anchor: .leading)` weiter unten richtet die Zielkachel
    // an der Kante der **Flaeche** aus, nicht am Rand — die 80 Punkt
    // scrollten also mit hinaus, und die Folgenreihe klebte am Bildrand.
    // Sichtbar nur dort, wo eine Bindung uebergeben wird; die Startseite
    // ohne `stand` sah immer richtig aus. `contentMargins` gehoert der
    // Flaeche, nicht dem Inhalt, und wird beim Anfahren mitgerechnet.
    .contentMargins(.horizontal, Stil.randSeite, for: .scrollContent)
    // Ohne das sucht tvOS senkrecht nach einer Kachel in derselben Spalte.
    // Reihen verschiedener Laenge lassen den Fokus dann zwei Reihen tief
    // fallen. Als Abschnitt gilt die Reihe als Ganzes.
    .focusSection()

    // **Vorgescrollt, wo es einen Anfang gibt, der nicht der erste ist.**
    //
    // Die Folgenreihe soll dort stehen, wo es weitergeht, nicht bei F1. Der
    // Fokus faellt beim Hereinkommen ohnehin auf die vorderste Kachel —
    // dieselbe Regel wie auf der Startseite —, also entscheidet der
    // Scrollstand, welche Folge angeboten wird.
    //
    // **`scrollPosition` und nicht `ScrollViewReader`.** Der Reader gibt
    // seinen Proxy in eine entkommende Schliessung, und der ist nicht
    // `Sendable`; unter Swift 6 uebersetzt das nicht. Ausserdem muesste man
    // den richtigen Zeitpunkt zum Anfahren selbst treffen — `scrollTo` auf
    // eine Kachel, die der faule Stapel noch nicht erzeugt hat, tut nichts.
    // Die Bindung traegt den Wunsch dagegen, bis er einloesbar ist.
    //
    // Nur wo eine Bindung uebergeben wird: die anderen Streifen sollen den
    // Fokusmotor allein scrollen lassen.
    return Group {
        if let stand {
            flaeche.scrollPosition(id: stand, anchor: .leading)
        } else {
            flaeche
        }
    }
}

// MARK: - Die Streifen

/// Die Besetzung.
///
/// **Die Kachel muss fokussierbar sein, obwohl sie nirgendwohin fuehrt.**
/// Auf dem iPhone ist die Besetzung ein Streifen zum Wischen ohne Ziel beim
/// Antippen. Eins zu eins uebernommen entsteht auf dem Fernseher ein
/// Sackgassen-Abschnitt: `focusSection` meldet einen Bereich an, in dem nichts
/// zu holen ist, tvOS zieht den Druck nach unten dorthin, findet kein Ziel und
/// laesst ihn fallen — der Fokus verschwindet, und weder vor noch zurueck geht
/// etwas. Dazu kommt: eine waagerechte Liste laesst sich hier nur ueber den
/// Fokus bewegen. Ein leerer Rueckruf ist deshalb kein Behelf, sondern die
/// Sache selbst — die Kachel ist ein Halt zum Weiterlaufen.
struct Besetzungsstreifen: View {
    let model: AppModel
    let leute: [Person]

    var body: some View {
        streifen {
            ForEach(leute) { person in
                Button {} label: {
                    Besetzungskachel(bild: model.personBild(person, maxHeight: 440),
                                     name: person.name, rolle: person.role)
                }
                .buttonStyle(KachelStil())
            }
        }
    }
}

/// Eine Reihe Titel — fuer „Aehnliches" und „Extras".
struct Titelstreifen: View {
    let model: AppModel
    let items: [Item]
    /// Extras fuehren nicht auf eine Seite, sie laufen sofort.
    var starten: ((Item) -> Void)?

    var body: some View {
        streifen {
            ForEach(items) { item in
                if let starten {
                    Button { starten(item) } label: {
                        Kachelinhalt(bild: model.querbildURL(for: item, breite: 900)
                                           ?? model.imageURL(for: item, maxHeight: 600),
                                     titel: item.name, quer: true)
                    }
                    .buttonStyle(KachelStil())
                } else {
                    NavigationLink(value: item) {
                        Kachelinhalt(bild: model.imageURL(for: item, maxHeight: 600,
                                                          hochkant: true),
                                     titel: item.name, mitUnterzeile: false)
                    }
                    .buttonStyle(KachelStil())
                }
            }
        }
    }
}

/// Die Folgen einer Staffel als waagerechter Streifen.
///
/// Vorher war das eine senkrechte Liste mit Vorschaubild links
/// (`Folgenzeile`), uebernommen vom iPhone. Der Entwurf macht daraus eine
/// Reihe wie jede andere — dieselbe Querkachel wie „Weiterschauen" auf der
/// Startseite, damit es keine dritte Kachelform gibt.
///
/// `Folgenzeile` bleibt bestehen: das Folgenblatt im Player benutzt sie
/// weiter, und dort ist die Liste richtig — sie liegt ueber dem laufenden Bild.
struct Folgenstreifen: View {
    let model: AppModel
    let folgen: [Item]
    let starten: (Item) -> Void
    /// Meldet nach oben, welche Folge unter dem Fokus steht — und nimmt den
    /// Startfokus entgegen.
    @FocusState.Binding var amFolge: String?

    /// Welche Kachel vorn steht. Beim Erscheinen die Folge, bei der es
    /// weitergeht — danach fuehrt die Scrollflaeche den Wert selbst nach.
    ///
    /// Als Anfangswert und nicht in `onAppear`: gesetzt heisst hier auch
    /// angewandt, weil die Bindung schon im ersten Zeichendurchgang steht.
    /// Nachgereicht waere es wieder ein Wettlauf mit dem Fokusmotor.
    @State private var vorne: String?

    init(model: AppModel, folgen: [Item], weiterMit: String?,
         amFolge: FocusState<String?>.Binding,
         starten: @escaping (Item) -> Void) {
        self.model = model
        self.folgen = folgen
        self.starten = starten
        self._amFolge = amFolge
        _vorne = State(initialValue: weiterMit)
    }

    var body: some View {
        // **Ohne feste Hoehe.** Einmal versucht, mit 80 Punkt fuer die zwei
        // Beschriftungszeilen — am Bild gemessen sind es rund 122. Der
        // Rahmen war damit zu klein fuer seinen Inhalt, und der waagerechte
        // Streifen zentriert darin: es wurde schlimmer, nicht besser.
        //
        // Der eigentliche Befund lag ohnehin woanders, siehe unten.
        streifen(stand: $vorne) {
            ForEach(folgen) { folge in
                Button { starten(folge) } label: {
                    // `querbildURL` baut die Adresse aus `seriesId ?? id` —
                    // bei einer Folge ist `seriesId` gesetzt, es kaeme also
                    // fuer jede Folge derselbe Serienhintergrund heraus.
                    // `imageURL` loest dagegen ueber `imageTags["Primary"]`
                    // das eigene Vorschaubild der Folge auf.
                    Kachelinhalt(bild: model.imageURL(for: folge, maxHeight: 360)
                                       ?? model.querbildURL(for: folge, breite: 640),
                                 titel: kopfzeile(folge),
                                 unterzeile: dauerzeile(folge),
                                 quer: true,
                                 fortschritt: folge.gesehenerAnteil)
                }
                .buttonStyle(KachelStil())
                .focused($amFolge, equals: folge.id)
            }
        }
    }

    private func kopfzeile(_ folge: Item) -> String {
        guard let nummer = folge.indexNumber else { return folge.name }
        return "F\(nummer) · \(folge.name)"
    }

    /// „52 Min", und wo etwas angefangen ist, dahinter der Rest.
    private func dauerzeile(_ folge: Item) -> String? {
        var teile: [String] = []
        if let sekunden = folge.runtimeSeconds, sekunden > 0 {
            teile.append(String(localized: "\(Int(sekunden / 60)) Min"))
        }
        if let rest = folge.restzeitText {
            teile.append(rest)
        } else if folge.istGesehen {
            teile.append(String(localized: "Gesehen"))
        }
        return teile.isEmpty ? nil : teile.joined(separator: " · ")
    }
}
