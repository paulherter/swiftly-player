import SwiftUI

/// Maße, Schriftgrößen und Bausteine für das iPhone. Die Farben stehen in
/// `Farben.swift`, weil sie sich beide Plattformen teilen.
///
/// Bewusst weg von iOS-Standardmaterialien: kein `.ultraThinMaterial`, keine
/// Glaseffekte, keine Systemhintergründe. Flächen sind flach und
/// undurchsichtig, damit das Bildmaterial die einzige Farbe im Raum ist.
extension Stil {

    /// Wie ein Blatt von unten hereinfährt.
    ///
    /// **Auf Apples Blatt gelegt, nicht geraten.** Schnell heran, kein
    /// Nachschwingen — dieselbe Kennlinie, die `.sheet` zeigt. Sie steht
    /// hier und nicht an den Aufrufstellen, weil sonst vier Blätter vier
    /// Kurven hätten.
    static let blattbewegung: Animation = .spring(response: 0.35,
                                                  dampingFraction: 0.86)


    // MARK: Maße — iPhone

    static let ecke: CGFloat = 6
    /// Kacheln sind eine Spur runder als der Rest. Ausdrücklich nur eine
    /// Spur — „wirklich minimal" war die Vorgabe.
    static let eckeKachel: CGFloat = 8
    static let randAbstand: CGFloat = 18
    static let kachelAbstand: CGFloat = 12
    static let reihenAbstand: CGFloat = 28

    /// Poster sind überall hochkant, 2:3. Von 132 × 198 verkleinert: die
    /// Kacheln waren zu wuchtig, mehr passt nebeneinander.
    static let kachelBreite: CGFloat = 112
    static let kachelHoehe: CGFloat = 168

    /// Heldenbild auf den Detailseiten — für Film und Serie **gleich**.
    static let heldHoehe: CGFloat = 300

    /// Höhe der Navigationsleiste ohne den Bereich des Home-Indikators.
    static let leisteHoehe: CGFloat = 54

    // MARK: Maße — iPad

    /// Die Leiste liegt auf dem iPad **links**, nicht oben.
    ///
    /// Der Fernseher hat sie oben, und die Versuchung war groß, das
    /// abzuschreiben. Dort bedient aber eine Fernbedienung — Erreichbarkeit
    /// spielt keine Rolle. An einem gehaltenen iPad ist die obere Kante die
    /// schlechteste Stelle überhaupt. Vom Fernseher kommt deshalb die
    /// Komposition der Seiten, nicht die Griffhöhe.
    ///
    /// 88 Punkt, weil die Wortmarke bei 20 Punkt Höhe 59 breit ist und mit
    /// je 14 Punkt Luft hineinpasst.
    static let seitenleisteBreite: CGFloat = 88

    /// Seitlicher Rand auf der breiten Fassung. Zwischen iPhone (18) und
    /// Fernseher (80); dort sind die 80 zur Hälfte Überstrahlung am Bildrand,
    /// die es hier nicht gibt.
    static let randSeiteBreit: CGFloat = 28

    /// Heldenbild auf der breiten Fassung.
    ///
    /// Bemisst sich am **Inhalt**, nicht am Schirm: Poster 252 plus 40 unten
    /// plus 128 Luft oben. Auf dem Fernseher füllt das Heldbild die ganzen
    /// 1080 Punkt, und das trägt dort auch — auf 768 hieße volle Höhe nur,
    /// dass man zur Beschreibung erst scrollen muss.
    static let heldHoeheBreit: CGFloat = 420

    /// Poster auf den Detailseiten der breiten Fassung: 2:3 wie überall.
    static let heldPosterBreite: CGFloat = 168
    static var heldPosterHoehe: CGFloat { heldPosterBreite * 1.5 }

    /// Zielbreite einer Kachel im Raster. Geht in `spalten(nutzbar:breit:)`.
    ///
    /// Schmal 104, und das ist nicht frei gewählt: damit ergibt die Formel auf
    /// **jedem** iPhone genau drei Spalten, von 375 (SE) bis 440 (Pro Max).
    /// Der ausgelieferte Stand bleibt Zeichen für Zeichen, wie er ist.
    ///
    /// Breit 124. Mit 104 auch auf dem iPad kamen dort neun Spalten heraus
    /// und damit Kacheln von 104 Punkt — **schmaler als auf dem iPhone**, wo
    /// sie 110 messen. Auf dem größten Schirm die kleinsten Plakate: das war
    /// im Bild sofort zu sehen und ist offensichtlich verkehrt herum.
    static func kachelZiel(breit: Bool) -> CGFloat { breit ? 124 : 104 }

    /// Breite für Fließtext und Listenzeilen auf der breiten Fassung.
    ///
    /// Eine Beschreibung über 1036 Punkt ist eine Zeile mit 140 Zeichen, und
    /// eine Folgenzeile über 1036 Punkt setzt den Haken einen halben Meter
    /// neben den Titel. Galerien und Raster gehen weiter über die volle
    /// Breite — die sind zum Überfliegen da, nicht zum Lesen.
    static let lesebreite: CGFloat = 700

    static func rand(breit: Bool) -> CGFloat { breit ? randSeiteBreit : randAbstand }

    /// Wo die Haarlinie zwischen zwei Zeilen beginnt: hinter dem Symbol.
    ///
    /// Die 52 auf dem iPhone sind nicht frei gewählt, sondern Rand 18 plus
    /// Symbol 20 plus Abstand 14. Mit dem breiten Rand werden daraus 62 —
    /// wer nur den Rand ändert und diese Zahl stehen lässt, bekommt Linien,
    /// die gegenüber dem Text verrutschen.
    ///
    /// **Nicht bündig mit dem Text, und das ist keine Nachlässigkeit,
    /// sondern eine Messung.** `Trennlinie` bringt selbst noch
    /// `.padding(.leading, randAbstand)` mit; die Linie beginnt deshalb
    /// weitere 18 Punkt weiter rechts als der Text. Auf dem iPhone ist das
    /// seit jeher so. Diese Formel gibt genau dasselbe Verhältnis auch auf
    /// dem iPad — am Simulator nachgemessen: Text bei 167, Linie bei 184.
    static func trennEinzug(breit: Bool) -> CGFloat { rand(breit: breit) + 34 }

    /// Wie tief unter dem sicheren Bereich eine Seitenkopfzeile beginnt.
    ///
    /// Derselbe Wert, mit dem die Wortmarke in der Seitenleiste sitzt — sonst
    /// stehen Überschrift und Wortmarke auf verschiedenen Höhen, und das
    /// sieht man sofort: die Seite fängt oben an, die Leiste daneben ein
    /// Stück tiefer.
    static let kopfOben: CGFloat = 26

    /// Kachelmaße der Reihen auf der Startseite.
    ///
    /// Auf dem iPhone messen Reihe und Raster praktisch dasselbe — 112 gegen
    /// 110 —, und auf dem Fernseher steht für beides eine einzige Zahl (208).
    /// Auf dem iPad wuchs nur das Raster mit der Breite, die Reihen blieben
    /// bei 112: dasselbe Plakat war auf der Startseite ein Fünftel kleiner
    /// als in der Bibliothek. Auf einem Gerät, zwei Größen.
    ///
    /// Die Reihen bleiben trotzdem **fest** — sie zeigen bei mehr Platz mehr,
    /// nicht Größeres. Nur der feste Wert ist breit ein anderer, gewählt in
    /// der Mitte dessen, was das Raster dort ergibt: 126 hochkant, 138 quer.
    static func reihenBreite(breit: Bool) -> CGFloat { breit ? 132 : kachelBreite }
    static func reihenHoehe(breit: Bool) -> CGFloat { reihenBreite(breit: breit) * 1.5 }

    /// Waagerecht 16:9 für „Weiterschauen", rund doppelt so breit wie ein
    /// Poster — dasselbe Verhältnis wie auf dem iPhone (236 zu 112) und auf
    /// dem Fernseher (448 zu 208).
    static func reihenQuerBreite(breit: Bool) -> CGFloat { breit ? 280 : 236 }
    static func reihenQuerHoehe(breit: Bool) -> CGFloat { breit ? 158 : 133 }

    /// Ab dieser Fensterbreite liegen Abspielknopf und Aktionsreihe
    /// nebeneinander. Poster 168 + 32 Abstand + rund 620 Knopfreihe + zweimal
    /// Rand ergeben knapp 900.
    static let querKopfAbBreite: CGFloat = 900

    /// Breite für Anmeldung, Server und Quick Connect.
    ///
    /// Ein Eingabefeld über 1288 Punkt ist kein Feld mehr, sondern ein
    /// Streifen — und der Weg vom Anfang der Zeile zum Knopf darunter ist
    /// absurd. 420 ist die Breite, die dieselben Seiten auf einem großen
    /// iPhone haben; mehr braucht ein Formular aus drei Zeilen nicht.
    static let formularbreite: CGFloat = 420

    /// Wie viele Spalten in die nutzbare Breite passen.
    ///
    /// Der Fernseher hat dafür eine Konstante (`gitterSpalten = 7`), und das
    /// genügt dort: sein Schirm ist immer 1920 breit. Ein iPad ist es nicht —
    /// im geteilten Bildschirm bleiben davon 320 übrig.
    ///
    /// Mindestens zwei. Bei 320 Punkt Fensterbreite wären drei Kacheln
    /// 87 Punkt breit, und darunter ist ein Poster kein Poster mehr.
    static func spalten(nutzbar: CGFloat, breit: Bool) -> Int {
        max(2, Int((nutzbar + kachelAbstand) / (kachelZiel(breit: breit) + kachelAbstand)))
    }

    /// Ob das Gerät ein iPad ist — unabhängig davon, wie breit das Fenster
    /// gerade ist.
    ///
    /// `@MainActor`, und das ist nicht Zierde: `UIDevice.current` gehört dem
    /// Hauptakteur. Ohne die Angabe stand hier eine nicht isolierte
    /// Eigenschaft, die auf Zustand des Hauptakteurs zugreift — dieselbe
    /// Klasse Fehler wie in der Wiedergabezentrale, nur andersherum. Der
    /// Übersetzer hat sie hier gemeldet, weil ich nichts zugesichert hatte,
    /// was er hätte glauben können.
    @MainActor
    static var amPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    // MARK: Schrift — iPhone

    // Durchweg eine Stufe größer als vorher — die Schrift war zu klein.
    // Maßstab an Plex genommen, die genauen Werte stehen im Canvas unter
    // „Maßstab".
    static let titelGross = Font.system(size: 28, weight: .bold)
    static let titel      = Font.system(size: 27, weight: .bold)
    static let reihe      = Font.system(size: 20, weight: .semibold)   // war 17
    static let koerper    = Font.system(size: 15)
    static let kachel     = Font.system(size: 14, weight: .medium)     // war 12
    static let klein      = Font.system(size: 12)                      // war 11
    static let listentitel = Font.system(size: 15, weight: .semibold)
    static let plakette   = Font.system(size: 10, weight: .semibold)
}

// MARK: - Breite Fassung

private struct BreitSchluessel: EnvironmentKey {
    static let defaultValue = false
}

private struct WeitSchluessel: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Genug Breite, um die Knopfreihe der Detailseite **neben** das Poster
    /// zu legen.
    ///
    /// `breit` allein reicht dafür nicht, und das war ein teurer Irrtum: ein
    /// iPad im Hochformat ist `regular`, hat neben dem Poster aber nur 476
    /// Punkt. „Fortsetzen ab 53 min" plus „Von vorn" plus vier Aktionsknöpfe
    /// brauchen rund 620. SwiftUI hat die Beschriftungen daraufhin senkrecht
    /// gesetzt — ein Buchstabe je Zeile.
    ///
    /// Auf dem Fernseher konnte das nicht auffallen: der ist immer quer.
    var weit: Bool {
        get { self[WeitSchluessel.self] }
        set { self[WeitSchluessel.self] = newValue }
    }

    /// Die breite Fassung: Seitenleiste statt Leiste unten, Detailseiten
    /// quer komponiert, Einstellungen zweispaltig.
    ///
    /// Gesetzt wird sie **einmal** in `RootView` aus Größenklasse und Gerät,
    /// nicht überall neu ausgerechnet. Beide Bedingungen sind nötig: ein
    /// iPhone Pro Max meldet im Querformat ebenfalls `regular`, und dort
    /// wäre eine Seitenleiste falsch — die App liegt dort ohnehin hochkant
    /// fest, aber verlassen will ich mich darauf nicht.
    var breit: Bool {
        get { self[BreitSchluessel.self] }
        set { self[BreitSchluessel.self] = newValue }
    }
}

// MARK: - Schrift, die mitwächst

/// Eine Schriftgröße, die der Systemeinstellung folgt.
///
/// `@ScaledMetric` gibt bei der Standardeinstellung genau die übergebene Zahl
/// zurück — die Gestaltung sieht also unverändert aus und wächst erst, wenn
/// jemand die Schrift größer stellt. Genau deshalb steht hier keine Umstellung
/// auf Apples Textstile: `Font.system(.body)` sind 17 Punkt, unser Fließtext
/// misst 15, und das wäre eine sichtbare Änderung ohne Not.
///
/// **Bewusst nicht überall angewandt.** Kacheln, Navigationsleiste und die
/// Player-Steuerung stehen auf festen Punktmaßen (112 × 168, Leistenhöhe 54,
/// Knöpfe 44). Dort würde größere Schrift aus dem Rahmen laufen, statt ihn zu
/// dehnen. Angewandt ist sie da, wo der Rahmen mitgeht: Fließtext,
/// Listenzeilen, Einstellungen, Leerzustände. Der Rest ist ein eigener
/// Arbeitsblock — er verlangt, jede feste Höhe durchzugehen.
struct Mitwachsend: ViewModifier {
    @ScaledMetric private var groesse: CGFloat
    private let gewicht: Font.Weight

    init(groesse: CGFloat, gewicht: Font.Weight) {
        _groesse = ScaledMetric(wrappedValue: groesse, relativeTo: .body)
        self.gewicht = gewicht
    }

    func body(content: Content) -> some View {
        content.font(.system(size: groesse, weight: gewicht))
    }
}

extension View {
    /// Wie `.font(.system(size:weight:))`, nur folgt die Größe der
    /// Systemeinstellung.
    func mitwachsend(_ groesse: CGFloat, _ gewicht: Font.Weight = .regular) -> some View {
        modifier(Mitwachsend(groesse: groesse, gewicht: gewicht))
    }
}

// MARK: - Knöpfe

/// Der große weiße Knopf, der auf jeder Detailseite oben steht. Weiß mit
/// schwarzer Schrift, damit er über jedem Poster lesbar bleibt.
struct HauptknopfStil: ButtonStyle {
    /// Gesperrt heißt gedämpft, nicht durchscheinend.
    ///
    /// Weiß auf 40 Prozent über unserem Grund ergibt ein kräftiges Grau — das
    /// sieht nach einem Knopf aus, der einfach nicht reagiert, statt nach
    /// einem, der noch auf eine Eingabe wartet. Eine dunkle Fläche mit leiser
    /// Schrift sagt dasselbe wie überall sonst in der App.
    @Environment(\.isEnabled) private var freigegeben

    /// Über die volle Breite, oder nur so breit wie die Beschriftung.
    ///
    /// Schmal ist die volle Breite richtig: der Knopf steht allein in seiner
    /// Zeile. Breit steht er neben der Aktionsreihe und darf sie nicht
    /// wegdrücken.
    var dehnt = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(freigegeben ? .black : Stil.schriftSehrLeise)
            .padding(.horizontal, dehnt ? 0 : 28)
            .frame(maxWidth: dehnt ? .infinity : nil, minHeight: 48)
            .background(flaeche(gedrueckt: configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: Stil.ecke))
    }

    private func flaeche(gedrueckt: Bool) -> Color {
        guard freigegeben else { return Stil.flaeche }
        return Color.white.opacity(gedrueckt ? 0.75 : 1)
    }
}

/// Zweitrangig: gedämpfte Fläche, weiße Schrift.
struct NebenknopfStil: ButtonStyle {
    var dehnt = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Stil.schrift)
            .padding(.horizontal, dehnt ? 0 : 22)
            .frame(maxWidth: dehnt ? .infinity : nil, minHeight: 46)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.10),
                        in: RoundedRectangle(cornerRadius: Stil.ecke))
    }
}

// MARK: - Kleinteile



/// Dünner Fortschrittsbalken am unteren Rand einer Kachel.
///
/// Misst sich selbst statt am umgebenden Rahmen. `containerRelativeFrame`
/// nahm die Breite des nächsten *Containers* — in einer waagerechten Reihe ist
/// das die ganze Reihe, nicht die Kachel. Der Balken lief dadurch weit über
/// die Kachel hinaus und schob in der Reihe „Weiterschauen" sogar den Titel
/// nach unten. `GeometryReader` geht hier trotzdem nicht: der dehnt sich
/// gierig aus. `onGeometryChange` misst, ohne das Layout anzufassen.
struct Fortschrittsbalken: View {
    let anteil: Double
    @State private var breite: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(.white.opacity(0.25))
            Rectangle().fill(Stil.akzent)
                .frame(width: breite * min(max(anteil, 0), 1))
        }
        // Vier statt drei Punkt — bei drei war er auf den Kacheln kaum zu
        // erkennen.
        .frame(height: 4)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { breite = $0 }
    }
}

/// Derselbe Balken, aber nur, wenn der Schalter in den Einstellungen es
/// erlaubt.
///
/// Der Schalter heißt „Fortschritt auf Kacheln" und meint genau das — der
/// Balken unter dem Abspielknopf auf der Serienseite bleibt davon unberührt
/// und nimmt deshalb weiter den nackten `Fortschrittsbalken`.
///
/// Dass die Abfrage hier steht und nicht in `Bild`, ist keine Feinheit:
/// `@AppStorage` hängt einen Beobachter an die Voreinstellungen, und in `Bild`
/// bekam den jede Kachel — bei hundert sichtbaren Plakaten hundert Beobachter
/// für einen Schalter, der sich beim Scrollen nie ändert. Hier bekommen ihn
/// nur die wenigen Titel, die überhaupt einen Fortschritt haben.
struct Kachelfortschritt: View {
    let anteil: Double
    @AppStorage("fortschritt") private var zeigen = true

    var body: some View {
        if zeigen { Fortschrittsbalken(anteil: anteil) }
    }
}

/// Bild in fester Größe.
///
/// Wichtig: die Größe kommt vom Rahmen, das Bild legt sich nur darüber.
/// Setzt man stattdessen `aspectRatio(.fill)` direkt auf das Bild, wird es
/// breiter als sein Rahmen — `clipped()` beschneidet dann zwar die Darstellung,
/// nicht aber die Layoutgröße, und der ganze Aufbau drumherum verrutscht.
struct Bild<Platzhalter: View>: View {
    let url: URL?
    var breite: CGFloat?
    var hoehe: CGFloat?
    /// Statt einer festen Höhe: die Höhe folgt der Breite.
    ///
    /// Nötig, sobald die Kachel ihre Spalte füllt, statt ein festes Maß zu
    /// haben. Vorher rechnete das Plakatraster die Höhe aus `kachelBreite`
    /// — auf dem iPhone stimmte das zufällig, weil drei Spalten dort rund
    /// 110 Punkt breit sind. Auf iPad und Mac sind die Spalten breiter, die
    /// Höhe blieb bei 168, und die Plakate standen gestaucht.
    var verhaeltnis: CGFloat?
    var ecke: CGFloat = Stil.ecke
    /// Fortschritt am unteren Rand. Bewusst **hier** und nicht als Auflage
    /// von aussen: eine Auflage liegt ausserhalb der Maske, dann steht der
    /// Balken mit eckigen Enden ueber die runden Ecken hinaus.
    var fortschritt: Double? = nil
    @ViewBuilder var platzhalter: () -> Platzhalter

    var body: some View {
        rahmen
            .overlay {
                AsyncImage(url: url) { phase in
                    if case let .success(bild) = phase {
                        bild.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        platzhalter()
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let fortschritt {
                    Kachelfortschritt(anteil: fortschritt)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: ecke))
    }

    /// Die Flaeche, an der sich alles misst.
    private var flaeche: some View {
        Color.clear
            .frame(width: breite, height: hoehe)
            .frame(maxWidth: breite == nil ? .infinity : nil)
    }

    /// **`aspectRatio` nur, wenn es ein Verhaeltnis gibt.**
    ///
    /// `aspectRatio(nil, contentMode: .fit)` heisst nicht „lass es bleiben",
    /// sondern „nimm das Verhaeltnis des Inhalts" — und der Inhalt ist hier
    /// ein `Color.clear`, das keins hat. Wo eine Breite gesetzt ist, faellt
    /// das nicht auf: die Flaeche steht dann ohnehin fest. Wo nur eine Hoehe
    /// gesetzt ist, bleibt nichts uebrig, woran die Breite haengt — die
    /// Flaeche fiel auf einen Streifen am linken Rand zusammen.
    ///
    /// Genau so kam `Heldbild` daher (Hoehe ja, Breite nein, Verhaeltnis
    /// nein), und damit das Bild oben auf jeder Detailseite im schmalen
    /// Aufbau. Das Verhaeltnis kam nachtraeglich aus main dazu, fuer das
    /// Plakatraster; die Aufrufer ohne eines waren nicht mitgedacht.
    @ViewBuilder
    private var rahmen: some View {
        if let verhaeltnis {
            flaeche.aspectRatio(verhaeltnis, contentMode: .fit)
        } else {
            flaeche
        }
    }
}

extension Bild where Platzhalter == Color {
    init(url: URL?, breite: CGFloat? = nil, hoehe: CGFloat? = nil,
         verhaeltnis: CGFloat? = nil, ecke: CGFloat = Stil.ecke,
         fortschritt: Double? = nil) {
        self.init(url: url, breite: breite, hoehe: hoehe,
                  verhaeltnis: verhaeltnis, ecke: ecke,
                  fortschritt: fortschritt) {
            Stil.flaeche
        }
    }
}

/// Eigene Auswahl statt `Menu` oder `Picker`.
///
/// Apples Menü bringt sein eigenes Erscheinungsbild mit — abgerundetes Glas,
/// eigene Schrift, eigene Abstände. Das steht neben unserer flachen, dunklen
/// Gestaltung wie ein Fremdkörper. Diese Auswahl gehört uns vollständig:
/// abgedunkelter Grund, flache Fläche, unsere Schrift, unser Akzent.
struct Auswahlblatt<Eintrag: Identifiable>: View {
    @Binding var offen: Bool
    /// Wie hoch die Einträge zusammen sind — gemessen, nicht angenommen.
    @State private var inhaltshoehe: CGFloat = 0
    /// Wie weit über dem unteren Rand das Blatt endet.
    ///
    /// **Die Seite reicht hinter die Leiste.** In den Bibliotheken liegt
    /// unten die Bereichsleiste über dem Inhalt; ohne diesen Abstand
    /// verschwindet „Abbrechen" darunter. In den Einstellungen gibt es keine
    /// Leiste, dort ist er null — deshalb sagt es der Aufrufer und nicht
    /// dieser Baustein, der seine Umgebung nicht kennt.
    var unterrand: CGFloat = 0
    let titel: LocalizedStringKey
    let eintraege: [Eintrag]
    let beschriftung: (Eintrag) -> String
    let istGewaehlt: (Eintrag) -> Bool
    let waehlen: (Eintrag) -> Void

    var body: some View {
        // **Der Stapel bleibt, die Kinder wechseln.**
        //
        // Wird das ganze Blatt eingefügt, animiert SwiftUI nur dieses
        // Einfügen — die Übergänge der Kinder kommen gar nicht zum Zug, und
        // heraus kommt ein Aufblenden. Erst wenn Schleier und Karte einzeln
        // erscheinen, kann der eine blenden und die andere fahren.
        ZStack(alignment: .bottom) {
            if offen {
            // Abdunkeln; Tippen daneben schließt.
            Rectangle()
                .fill(.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture { schliessen() }
                .transition(.opacity)

            VStack(spacing: 0) {
                Text(titel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Stil.schriftLeise)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Stil.randAbstand)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(eintraege) { eintrag in
                            Button {
                                waehlen(eintrag)
                                schliessen()
                            } label: {
                                HStack {
                                    Text(beschriftung(eintrag))
                                        .font(.system(size: 16))
                                        .foregroundStyle(Stil.schrift)
                                    Spacer()
                                    if istGewaehlt(eintrag) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Stil.akzent)
                                    }
                                }
                                .padding(.horizontal, Stil.randAbstand)
                                .frame(height: 50)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Rectangle().fill(Stil.linie).frame(height: 1)
                                .padding(.leading, Stil.randAbstand)
                        }
                    }
                    // Gemessen, nicht angenommen — siehe unten.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height }
                        action: { inhaltshoehe = $0 }
                }
                // **So hoch wie die Einträge, höchstens 340.**
                //
                // `.frame(maxHeight:)` allein reicht nicht: eine `ScrollView`
                // ist senkrecht gierig und nimmt sich die 340 auch dann, wenn
                // vier Zeilen nur 204 brauchen. Übrig blieb ein Hohlraum
                // unter der letzten Zeile, der nichts tut.
                .frame(height: min(inhaltshoehe, 340))
                .scrollIndicators(.hidden)

                Button { schliessen() } label: {
                    Text("Abbrechen")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Stil.schriftLeise)
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.plain)
            }
            .background {
                UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12)
                    .fill(Stil.flaeche)
                    .ignoresSafeArea(edges: unterrand > 0 ? [] : .bottom)
            }
            .padding(.bottom, unterrand)
            // Von unten herein — derselbe Weg, den `.sheet` nimmt.
            .transition(.move(edge: .bottom))
            }
        }
        // Der Stapel muss den Schirm füllen; sonst bemisst sich die Auflage
        // am Inhalt und die Karte sitzt oben.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(offen)
    }

    private func schliessen() {
        // Dieselbe Feder wie beim Öffnen — sonst kommt es anders zurück,
        // als es gegangen ist.
        withAnimation(Stil.blattbewegung) { offen = false }
    }
}

/// Eigener Schalter statt `Toggle`.
///
/// Apples Schalter bringt eigene Maße, eigenen Radius und eigene Animation
/// mit und wirkt neben flachen Flächen wie ein Fremdkörper.
struct Schalter: View {
    @Binding var an: Bool

    var body: some View {
        Button {
            an.toggle()
        } label: {
            ZStack(alignment: an ? .trailing : .leading) {
                Capsule()
                    .fill(an ? Stil.akzent : Color.white.opacity(0.16))
                    .frame(width: 46, height: 28)
                Circle()
                    .fill(an ? Stil.grund : Color.white)
                    .frame(width: 22, height: 22)
                    .padding(.horizontal, 3)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: an)
        // Eigene Steuerelemente sind für VoiceOver zunächst nur „Taste".
        // `isToggle` sagt, worum es geht, und liest den Zustand mit vor.
        .accessibilityRepresentation {
            Toggle(isOn: $an) { Text("Ein") }
        }
    }
}

/// Rubrik über einer Gruppe von Zeilen.
struct Gruppentitel: View {
    let text: LocalizedStringKey
    var body: some View {
        // `textCase` statt `uppercased()`: aus einem Schlüssel lässt sich
        // keine Zeichenkette machen, ohne die Übersetzung zu verlieren.
        Text(text)
            .textCase(.uppercase)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Stil.schriftSehrLeise)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Stil.randAbstand)
            .padding(.bottom, 8)
    }
}

/// Rubrik plus die Zeilen darunter, oben und unten von einer Haarlinie
/// gefasst.
///
/// Stand zweimal da — in `EinstellungenView` und in
/// `WiedergabeEinstellungenView` —, zeichengleich bis in den Kommentar über
/// `textCase` hinein. Der Mac-Chat hat es beim Nachbauen gemeldet: er hatte
/// es bei sich von vornherein als **einen** Baustein.
///
/// Keine Karte, keine Umrandung: getrennt wird nur durch Leerraum und den
/// kleinen gesperrten Titel.
struct Einstellungsgruppe<Inhalt: View>: View {
    let titel: LocalizedStringKey
    @ViewBuilder var inhalt: () -> Inhalt

    // `Stil.swift` geht nur ins iOS-Ziel — Fernseher und Mac haben eigene
    // Fassungen. Hier kann also nichts auseinanderlaufen; auf dem iPhone
    // bleibt `breit` falsch und damit alles, wie es war.
    @Environment(\.breit) private var breit

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Kein `uppercased()`: aus einem Schlüssel lässt sich keine
            // Zeichenkette machen, ohne die Übersetzung zu verlieren.
            // `textCase` macht dasselbe, nur eine Ebene später.
            Text(titel)
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.4))
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 26)
                .padding(.bottom, 8)
            VStack(spacing: 0) { inhalt() }
                .background(alignment: .top) { Trennlinie() }
                .background(alignment: .bottom) { Trennlinie() }
        }
    }
}

/// Haarlinie zwischen Zeilen, links eingerückt wie im Entwurf.
struct Trennlinie: View {
    var body: some View {
        Rectangle().fill(Stil.linie).frame(height: 1)
            .padding(.leading, Stil.randAbstand)
    }
}

/// Kopfzeile einer Unterseite: Pfeil links, Titel linksbündig daneben.
/// Nicht Apples zentrierter Titel, kein grauer Kreis.
struct Unterseitenkopf<Rechts: View>: View {
    /// Trägt den Namen einer Bibliothek — der kommt vom Server und wird
    /// deshalb nicht übersetzt.
    let titel: String
    let zurueck: () -> Void
    @ViewBuilder var rechts: () -> Rechts

    var body: some View {
        HStack(spacing: 4) {
            Button(action: zurueck) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Stil.schrift)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(titel)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)

            Spacer(minLength: 0)
            rechts()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
    }
}

extension Unterseitenkopf where Rechts == EmptyView {
    init(titel: String, zurueck: @escaping () -> Void) {
        self.init(titel: titel, zurueck: zurueck) { EmptyView() }
    }
}

/// Runder Knopf mit Beschriftung darunter — die Aktionsreihe auf Detailseiten.
struct Aktionsknopf: View {
    let symbol: String
    let titel: LocalizedStringKey
    var aktiv: Bool = false
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(aktiv ? Stil.grund : Stil.schrift)
                    .frame(width: 44, height: 44)
                    .background(aktiv ? Stil.akzent : Color.white.opacity(0.09), in: Circle())
                Text(titel)
                    .font(.system(size: 11))
                    .foregroundStyle(Stil.schrift.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(width: 68)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(titel))
        .accessibilityAddTraits(aktiv ? [.isButton, .isSelected] : .isButton)
    }
}

/// Reiterreihe mit Akzentstrich unter dem aktiven Eintrag.
struct Reiter: View {
    let titel: [LocalizedStringKey]
    @Binding var gewaehlt: Int

    var body: some View {
        HStack(spacing: 26) {
            ForEach(Array(titel.enumerated()), id: \.offset) { paar in
                let aktiv = paar.offset == gewaehlt
                Button {
                    withAnimation(Stil.umschalten) { gewaehlt = paar.offset }
                } label: {
                    Text(paar.element)
                        .font(.system(size: 15, weight: aktiv ? .semibold : .regular))
                        .foregroundStyle(aktiv ? Stil.schrift : Stil.schriftLeise)
                        .padding(.bottom, 11)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(aktiv ? Stil.akzent : .clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Welcher Reiter offen ist, hing allein am Akzentstrich und an
                // der Fettung — für VoiceOver waren alle drei gleich. Der
                // tvOS-Chat hat den Fall bei sich gefunden: überall dort, wo
                // ein Zustand nur an der Farbe hängt, wird er nicht gesprochen.
                .accessibilityAddTraits(aktiv ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Stil.randAbstand)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Stil.linie).frame(height: 1)
        }
    }
}

/// Zeile im Datei-Auszug: Bezeichnung links, Wert rechts.
struct Dateizeile: View {
    /// „Video", „Ton", „Untertitel" — feste Beschriftungen.
    let bezeichnung: LocalizedStringKey
    let wert: String
    var hervorgehoben = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(bezeichnung)
                .foregroundStyle(Stil.schriftLeise)
            Spacer(minLength: 0)
            Text(wert)
                .foregroundStyle(hervorgehoben ? Stil.akzent : Stil.schrift)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
        .padding(.vertical, 9)
    }
}

/// Rundes Porträt mit Name und Rolle.
struct Besetzungskachel: View {
    let bild: URL?
    let name: String
    let rolle: String?

    var body: some View {
        VStack(spacing: 7) {
            Bild(url: bild, breite: 76, hoehe: 76, ecke: 38)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Stil.schrift)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let rolle, !rolle.isEmpty {
                Text(rolle)
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftLeise)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
        }
        .frame(width: 84)
    }
}

/// Pille, unter der eine Liste direkt aufklappt — nach Netflix-Vorbild.
/// Kein Blatt von unten: die Entscheidung bleibt am Ort, an dem sie
/// ausgelöst wurde.
struct Aufklappliste<Eintrag: Identifiable>: View {
    let beschriftung: String
    let eintraege: [Eintrag]
    let text: (Eintrag) -> String
    let istGewaehlt: (Eintrag) -> Bool
    let waehlen: (Eintrag) -> Void
    @Binding var offen: Bool

    var body: some View {
        Button {
            if eintraege.count > 1 { offen.toggle() }
        } label: {
            HStack(spacing: 8) {
                Text(beschriftung)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Stil.schrift)
                if eintraege.count > 1 {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Stil.schriftLeise)
                        .rotationEffect(.degrees(offen ? 180 : 0))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: 5))
        }
        .accessibilityLabel(beschriftung)
        .accessibilityHint(eintraege.count > 1 ? "Öffnet die Auswahl" : "")
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if offen {
                VStack(spacing: 0) {
                    ForEach(eintraege) { eintrag in
                        Button {
                            waehlen(eintrag)
                            offen = false
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(istGewaehlt(eintrag) ? Stil.akzent : .clear)
                                    .frame(width: 14)
                                Text(text(eintrag))
                                    .font(.system(size: 15))
                                    .foregroundStyle(istGewaehlt(eintrag) ? Stil.schrift
                                                                          : Stil.schrift.opacity(0.75))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 200, alignment: .leading)
                .background(Color(red: 0.09, green: 0.09, blue: 0.102),
                            in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.6), radius: 16, y: 8)
                .offset(y: 44)
                .zIndex(10)
            }
        }
    }
}

/// Drehender Ring fuer Wartezeiten.
///
/// Eigener Baustein statt ProgressView: der Systemring bringt seine eigene
/// Strichstaerke und sein eigenes Grau mit und faellt neben den uebrigen
/// Bausteinen auf. Hier bestimmen Akzentfarbe und Staerke das Bild.
extension Stil {
    /// Fuer alles, was springt — Knoepfe wie Doppeltipp.
    ///
    /// Die Bewegung selbst macht SF Symbols mit '.bounce'. Ein eigener
    /// Drehwinkel war ein Fehler: er liess sich nur aufaddieren, nie
    /// zuruecknehmen, und die Knoepfe blieben schief stehen.
    static let sprung = Animation.snappy(duration: 0.22)
    /// Umschalten zwischen zwei Zustaenden, etwa Wiedergabe und Pause.
    static let umschalten = Animation.snappy(duration: 0.1)
}


/// Zeitregler im Player: 3-px-Balken mit kleinem runden Griff.
///
/// Eigener Baustein statt Slider. Apples Regler bringt einen grossen
/// Schattengriff und eine eigene Spurhoehe mit — neben dem uebrigen Player
/// sieht das aus wie ein Fremdkoerper, und im Entwurf steht ein duenner
/// Strich. Die Grifflaeche bleibt trotzdem 28 pt hoch, damit man ihn mit dem
/// Daumen trifft; sichtbar sind davon nur die drei Punkt.
struct Zeitregler: View {
    /// „1 Stunde 12 Minuten" statt „1:12:30" — VoiceOver liest Doppelpunkte
    /// als Doppelpunkte vor.
    static func gesprochen(_ sekunden: Double) -> String {
        let ganz = Int(max(0, sekunden))
        let stunden = ganz / 3600, minuten = (ganz % 3600) / 60
        if stunden > 0 {
            return "\(stunden) Stunden \(minuten) Minuten"
        }
        return "\(minuten) Minuten"
    }

    @Binding var wert: Double
    let bis: Double
    var beimSchieben: (Bool) -> Void

    @State private var breite: CGFloat = 0
    @State private var amSchieben = false

    private var anteil: CGFloat {
        guard bis > 0 else { return 0 }
        return min(max(CGFloat(wert / bis), 0), 1)
    }

    var body: some View {
        let dicke: CGFloat = amSchieben ? 6 : 3
        let griff: CGFloat = amSchieben ? 18 : 13

        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.24)).frame(height: dicke)
            Capsule().fill(.white).frame(width: breite * anteil, height: dicke)
            Circle().fill(.white).frame(width: griff, height: griff)
                .offset(x: breite * anteil - griff / 2)
        }
        .animation(Stil.umschalten, value: amSchieben)
        // Für VoiceOver ein Regler, nicht eine namenlose Fläche: mit
        // `adjustableAction` lässt sich die Stelle auch wischend ändern.
        .accessibilityElement()
        .accessibilityLabel("Abspielstelle")
        .accessibilityValue(String(localized: "\(Self.gesprochen(wert)) von \(Self.gesprochen(bis))"))
        .accessibilityAdjustableAction { richtung in
            let schritt = max(bis / 20, 10)
            switch richtung {
            case .increment: wert = min(bis, wert + schritt)
            case .decrement: wert = max(0, wert - schritt)
            @unknown default: break
            }
            beimSchieben(false)
        }
        // 44 statt 28: der Balken ist drei Punkt hoch, treffen muss man ihn
        // trotzdem mit dem Daumen. Sichtbar bleibt nur der Strich.
        .frame(height: 44)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { breite = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { geste in
                    amSchieben = true
                    beimSchieben(true)
                    guard breite > 0 else { return }
                    wert = Double(min(max(geste.location.x / breite, 0), 1)) * bis
                }
                .onEnded { _ in
                    amSchieben = false
                    beimSchieben(false)
                }
        )
    }
}

// MARK: - Navigationsleiste

/// Die vier Bereiche unten. Ersetzt die Knöpfe „Filme" und „Serien", die
/// vorher als Kacheln auf der Startseite standen.
enum Bereich: Int, CaseIterable, Identifiable {
    case start, filme, serien, suche
    var id: Int { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .start:  "Start"
        case .filme:  "Filme"
        case .serien: "Serien"
        case .suche:  "Suche"
        }
    }

    var symbol: String {
        switch self {
        case .start:  "house"
        case .filme:  "film"
        case .serien: "tv"
        case .suche:  "magnifyingglass"
        }
    }
}

/// Ein Bereich in der Leiste — unten auf dem iPhone, links auf dem iPad.
///
/// **Ein Baustein für beide Leisten.** Er stand zweimal da, siebzehn Zeilen
/// wortgleich, und der Kommentar an `Seitenleiste` sagte es selbst:
/// „Gleiche Symbole, gleiche Größen, gleicher Akzent". Genau so fangen die
/// Fassungen an auseinanderzulaufen — wer die Auswahlfarbe ändert, ändert
/// eine von zwei Leisten und sieht die andere erst auf dem anderen Gerät.
///
/// Verschieden sind nur zwei Dinge, und beide stehen jetzt als Parameter da:
/// die Seitenleiste gibt eine feste Zeilenhöhe vor, und bei ihr trägt
/// keiner der vier Bereiche die Auswahl, solange das Profil offen ist.
private struct Bereichsknopf: View {
    let bereich: Bereich
    let aktiv: Bool
    /// Feste Zeilenhöhe. Die Leiste unten gibt keine vor — dort teilen sich
    /// die vier die Höhe der Leiste selbst.
    var hoehe: CGFloat?
    let waehlen: () -> Void

    var body: some View {
        Button(action: waehlen) { inhalt }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(bereich.name))
            .accessibilityAddTraits(aktiv ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var inhalt: some View {
        let kern = VStack(spacing: 4) {
            Image(systemName: bereich.symbol)
                .font(.system(size: 20, weight: aktiv ? .semibold : .regular))
            Text(bereich.name)
                .font(.system(size: 10, weight: aktiv ? .semibold : .medium))
        }
        .foregroundStyle(aktiv ? Stil.akzent : Color.white.opacity(0.42))
        .frame(maxWidth: .infinity)

        // Nicht `.frame(height: hoehe)` mit einem `nil`: das legt auch dann
        // eine Rahmenschicht ein, wenn keine gemeint ist. Hier soll die
        // Leiste unten genau den Baum bekommen, den sie vorher hatte.
        if let hoehe {
            kern.frame(height: hoehe).contentShape(Rectangle())
        } else {
            kern.contentShape(Rectangle())
        }
    }
}

/// Eigene Leiste statt `TabView`.
///
/// Apples Leiste bringt auf iOS 26 ihr eigenes Glasmaterial mit, dazu eigene
/// Höhe, eigene Symbolgrößen und eine Auswahlfarbe, die sich nur teilweise
/// setzen lässt. Diese hier gehört uns: unscharfer Grund in unserem Ton,
/// Haarlinie oben, 22-pt-Symbole.
struct Navileiste: View {
    @Binding var gewaehlt: Bereich

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Bereich.allCases) { bereich in
                Bereichsknopf(bereich: bereich, aktiv: bereich == gewaehlt) {
                    gewaehlt = bereich
                }
            }
        }
        .padding(.top, 9)
        .frame(height: Stil.leisteHoehe, alignment: .top)
        // Der Grund muss bis zur Unterkante laufen, nicht nur bis zum
        // sicheren Bereich — sonst blitzt unter der Leiste weiter Inhalt
        // durch, im Bereich des Home-Indikators.
        .background {
            // Fast deckend. Der weiche Blur gehört an den oberen Rand, wo man
            // Titel über durchlaufendem Bild lesen muss — hier unten stehen
            // nur vier Beschriftungen, die einfach stehen sollen.
            ZStack {
                Unschaerfe()
                Stil.grund.opacity(0.86)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Stil.linie).frame(height: 1)
        }
    }
}

/// Dieselbe Leiste, um 90 Grad gedreht — für die breite Fassung.
///
/// **Nicht die Kopfleiste vom Fernseher.** Die liegt dort oben, weil eine
/// Fernbedienung bedient und Erreichbarkeit keine Rolle spielt. An einem
/// gehaltenen iPad ist die obere Kante die schlechteste Stelle. Vom
/// Fernseher kommt die Komposition der Seiten, nicht die Griffhöhe.
///
/// Gleiche Symbole, gleiche Größen, gleicher Akzent, gleiches Glas wie
/// `Navileiste` — nur die Haarlinie sitzt rechts statt oben.
///
/// Wortmarke und Profilzeichen wandern hier hinein. Auf dem iPhone stehen
/// sie im Kopf jeder Seite; das kostet dort nichts, weil der Kopf ohnehin
/// da ist. Nebengewinn: das Profil ist damit zum ersten Mal aus **allen
/// vier** Bereichen erreichbar — in der Suche fehlte es bisher.
///
/// Sie weicht auf Unterseiten **nicht**, anders als unten auf dem iPhone.
/// Dort gibt das Weichen 54 Punkt Höhe zurück; hier gäbe es 88 Punkt Breite
/// zurück und verschöbe dabei jedes Poster. Ein waagerechter Sprung stört
/// mehr als ein senkrechter.
struct Seitenleiste: View {
    @Environment(\.fensterknoepfe) private var fensterknoepfe
    @Binding var gewaehlt: Bereich
    /// Die Profilseite ist offen — dann trägt keiner der vier Bereiche die
    /// Auswahl, sondern das Zeichen unten.
    var imProfil = false
    let name: String
    var bild: URL?
    let aufsProfil: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Wortmarke(hoehe: 20)
                .padding(.top, Stil.kopfOben + (fensterknoepfe ? Fensterknoepfe.hoehe : 0))
                .padding(.bottom, 30)

            ForEach(Bereich.allCases) { bereich in
                Bereichsknopf(bereich: bereich,
                              aktiv: bereich == gewaehlt && !imProfil,
                              hoehe: 64) {
                    gewaehlt = bereich
                }
            }

            Spacer(minLength: 0)

            Button(action: aufsProfil) {
                Profilzeichen(name: name, bild: bild, hervorgehoben: imProfil)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .frame(width: Stil.seitenleisteBreite)
        // Wie unten: der Grund muss bis an beide Kanten laufen, nicht nur bis
        // zum sicheren Bereich.
        .background {
            ZStack {
                Unschaerfe()
                Stil.grund.opacity(0.86)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Stil.linie).frame(width: 1).ignoresSafeArea()
        }
    }
}

/// Unscharfer Grund, der nach unten weich ausläuft.
///
/// **Die Maske muss in UIKit liegen, nicht in SwiftUI.** Eine
/// `UIVisualEffectView` verwischt, was in der Ebenenhierarchie *hinter* ihr
/// liegt. SwiftUIs `.mask` schiebt sie dafür in eine eigene Zeichenebene —
/// dort gibt es keinen Hintergrund mehr, und es bleibt nur die Eigenfarbe des
/// Materials übrig. Genau das war vorher zu sehen: ein grauer Streifen, aber
/// nie Unschärfe.
///
/// Als `layer.mask` auf derselben Ansicht bleibt der Hintergrund erhalten.
struct Unschaerfe: UIViewRepresentable {
    /// Das dünnste Material — jedes dickere hellt sichtbar auf.
    ///
    /// Dunkel wird es nicht durch die Wahl des Materials, sondern durch den
    /// Grundton darüber. Alle Materialien tragen eine helle Schicht; je dicker,
    /// desto mehr. `.dark` wäre von Haus aus dunkel, ist aber seit iOS 13
    /// abgekündigt und zeichnet mit einer Ebenenmaske gar nicht mehr.
    var stil: UIBlurEffect.Style = .systemUltraThinMaterialDark
    /// Anteil der Höhe, bis zu dem die Unschärfe voll steht. Darunter
    /// verläuft sie aus. `nil` heißt: über die ganze Fläche, ohne Verlauf.
    var vollBis: CGFloat? = nil
    /// 0 bis 1. Geregelt wird über die **Maske**, nicht über `.opacity` —
    /// letzteres schiebt die Ansicht in eine eigene Zeichenebene, und dann
    /// hat sie keinen Hintergrund mehr zu verwischen.
    var staerke: Double = 1

    final class Ansicht: UIVisualEffectView {
        let verlauf = CAGradientLayer()
        var mitVerlauf = false

        override func layoutSubviews() {
            super.layoutSubviews()
            // Ohne das bleibt die Maske auf der Größe von null stehen und die
            // ganze Ansicht ist unsichtbar.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            verlauf.frame = bounds
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> Ansicht {
        let ansicht = Ansicht(effect: UIBlurEffect(style: stil))
        ansicht.isUserInteractionEnabled = false
        ansicht.verlauf.startPoint = CGPoint(x: 0.5, y: 0)
        ansicht.verlauf.endPoint = CGPoint(x: 0.5, y: 1)
        setze(ansicht)
        return ansicht
    }

    func updateUIView(_ ansicht: Ansicht, context: Context) { setze(ansicht) }

    private func setze(_ ansicht: Ansicht) {
        ansicht.effect = UIBlurEffect(style: stil)
        let a = CGFloat(min(max(staerke, 0), 1))

        guard let vollBis else {
            // Ohne Verlauf: die Stärke sitzt dann in einer gleichmäßigen Maske.
            ansicht.verlauf.colors = [UIColor.black.withAlphaComponent(a).cgColor,
                                      UIColor.black.withAlphaComponent(a).cgColor]
            ansicht.verlauf.locations = [0, 1]
            ansicht.layer.mask = a < 1 ? ansicht.verlauf : nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ansicht.verlauf.colors = [UIColor.black.withAlphaComponent(a).cgColor,
                                  UIColor.black.withAlphaComponent(a).cgColor,
                                  UIColor.black.withAlphaComponent(a * 0.45).cgColor,
                                  UIColor.clear.cgColor]
        ansicht.verlauf.locations = [0, NSNumber(value: Double(vollBis)),
                                     NSNumber(value: Double((vollBis + 1) / 2)), 1]
        ansicht.layer.mask = ansicht.verlauf
        CATransaction.commit()
    }
}

/// Eine Leiste wie in Apples Apps: gleichmäßig unscharf, mit Haarlinie.
///
/// **Kein Verlauf.** Der sah unruhig aus, weil die Unschärfe auf halber Höhe
/// anfing zu verschwinden und die Kanten der Buchstaben dahinter wieder
/// scharf wurden. Apples Leisten sind über ihre ganze Höhe gleich und setzen
/// unten eine Haarlinie — das liest sich als Fläche, nicht als Schleier.
struct Leistenglas: View {
    var staerke: Double = 1
    /// Wie viel Grundton mit hineinspielt.
    var tiefe: Double = 0.5

    var body: some View {
        ZStack {
            Unschaerfe(staerke: staerke)
            Stil.grund.opacity(tiefe * staerke)
        }
        .allowsHitTesting(false)
    }
}

/// Kopfzeile, die beim Scrollen unscharf wird statt hart abzuschneiden.
///
/// Vorher war dort schwarze Fläche mit harter Kante. Der Inhalt läuft jetzt
/// sichtbar darunter durch.
struct Unschaerfekopf<Inhalt: View>: View {
    @Environment(\.breit) private var breit
    @Environment(\.fensterknoepfe) private var fensterknoepfe
    @ViewBuilder var inhalt: () -> Inhalt

    var body: some View {
        inhalt()
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, (breit ? Stil.kopfOben : 0)
                     + (fensterknoepfe ? Fensterknoepfe.hoehe : 0))
            .padding(.bottom, 12)
            .background {
                // Nur ein Verlauf, keine Unschärfe.
                //
                // Auf der Startseite laufen Kacheln durch, keine Schrift —
                // dort muss nichts lesbar gehalten werden, es soll nur nicht
                // hart abschneiden. Ein Verlauf tut das ruhiger als Glas und
                // braucht keine Haarlinie.
                Kopfverlauf()
            }
    }
}

/// Der Verlauf am oberen Rand scrollbarer Seiten.
///
/// Oben kräftig, unten weich. Mit drei Stützpunkten sah der Übergang wie eine
/// Kante aus: zwischen zwei Werten rechnet SwiftUI geradlinig, und ein gerader
/// Abfall liest sich als Knick. Sieben Punkte, ungleich verteilt — weit am
/// Anfang, dicht am Ende — ergeben den weichen Auslauf.
struct Kopfverlauf: View {
    /// Wie weit er unter die Kopfzeile hinausreicht.
    ///
    /// Knapp bemessen, und das ist der Punkt: der Verlauf soll den Kopf
    /// tragen, nicht den Inhalt darunter einfärben.
    ///
    /// Gerechnet für die engste Seite, die Startseite. Der Kopf endet dort bei
    /// rund 101 Punkt (sicherer Bereich 59 + Wortmarke 30 + Abstand 12), die
    /// erste Zeile — „Weiterschauen" — beginnt bei 117. Dazwischen liegen
    /// 16 Punkt, und in die passt der Ausklang gerade hinein. Mit 60 lag er
    /// 44 Punkt über der Zeile, mit 88 waren es 72; beides hat den Text
    /// sichtbar abgedunkelt.
    ///
    /// Wer hier erhöht, muss die Zahl gegen `contentMargins(.top:)` der
    /// Startseite prüfen — die ist die knappste im Projekt.
    var zugabe: CGFloat = 14

    var body: some View {
        LinearGradient(stops: [
            .init(color: Stil.grund.opacity(0.92), location: 0),
            .init(color: Stil.grund.opacity(0.90), location: 0.40),
            .init(color: Stil.grund.opacity(0.74), location: 0.60),
            .init(color: Stil.grund.opacity(0.46), location: 0.74),
            .init(color: Stil.grund.opacity(0.22), location: 0.86),
            .init(color: Stil.grund.opacity(0.07), location: 0.94),
            .init(color: Stil.grund.opacity(0),    location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .padding(.bottom, -zugabe)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}


/// Suchfeld im Hausstil. Kein `.searchable` — das bringt Systemhöhe,
/// Systemgrau und Systemecken mit.
struct Suchfeld: View {
    @Binding var text: String
    var platzhalter: LocalizedStringKey = "Filme, Serien, Folgen"
    /// Von aussen gesteuert, damit ein Abbrechen-Knopf die Tastatur schliessen
    /// kann.
    @FocusState.Binding var amTippen: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(Color.white.opacity(0.45))

            TextField("", text: $text, prompt: Text(platzhalter)
                .foregroundColor(Color.white.opacity(0.38)))
                .font(.system(size: 16))
                .foregroundStyle(Stil.schrift)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($amTippen)

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Stil.grund)
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Eingabe löschen")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Stil.rand) }
    }
}

/// Beschreibung, die einzeilig steht und beim Antippen aufklappt.
///
/// Der volle Text war auf den Detailseiten zu wuchtig.
struct Klapptext: View {
    let text: String
    @State private var offen = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { offen.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Text(text)
                    .mitwachsend(15)
                    .lineSpacing(3)
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(offen ? nil : 1)
                    .multilineTextAlignment(.leading)
                    // Ohne das meldet der einzeilige Text die Breite des
                    // *ganzen* Satzes als Wunschmaß. Der Stapel drumherum
                    // richtete sich danach, und beim Aufklappen sprang die
                    // ganze Seite um ein, zwei Punkte in der Breite.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .rotationEffect(.degrees(offen ? 180 : 0))
                    .padding(.top, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver liest den ganzen Text ohnehin vor — die Kürzung ist eine
        // rein sichtbare Sache. Deshalb hier nur der Hinweis, was der Tipp tut.
        .accessibilityLabel(text)
        .accessibilityHint(offen ? "Zuklappen" : "Aufklappen")
    }
}

/// Weicher Auslauf am unteren Rand des Heldenbilds.
///
/// Vorher stiess das Bild hart auf die dunkle Fläche darunter. Der Verlauf
/// läuft über die letzten 130 Punkt in den Grundton aus — bewusst flach, ein
/// starker Verlauf frisst das Bild auf.
struct Heldauslauf: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: Stil.grund.opacity(0),    location: 0),
            .init(color: Stil.grund.opacity(0.55), location: 0.45),
            .init(color: Stil.grund,               location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .frame(height: 130)
        .allowsHitTesting(false)
    }
}

/// Die Zeile unter dem Abspielknopf: Direct Play, Bewertung, Freigabe.
///
/// Sie stand vorher über dem Knopf und zusammen mit Jahr, Laufzeit und Genres
/// in zwei Zeilen — das war überladen. Jahr und Laufzeit sitzen jetzt im
/// Heldenbild, hier bleibt nur, was die Wiedergabe betrifft.
struct Belegzeile: View {
    var direktplay: Bool
    var hinweis: String?
    var bewertung: Double?
    var freigabe: String?

    var body: some View {
        HStack(spacing: 14) {
            if direktplay {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                    Text("Direct Play").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Stil.akzent)
            } else if let hinweis {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(hinweis).font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Stil.warnung)
            }

            if let bewertung {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill").font(.system(size: 11))
                    Text(String(format: "%.1f", bewertung).replacingOccurrences(of: ".", with: ","))
                        .font(.system(size: 13))
                }
                .foregroundStyle(Color.white.opacity(0.8))
            }

            if let freigabe { Plakette(text: freigabe) }

            Spacer(minLength: 0)
        }
    }
}

/// Kopf einer Detailseite: Zurückpfeil, der beim Scrollen zur unscharfen
/// Leiste mit Titel wird.
///
/// Vorher lief der Inhalt beim Scrollen ungebremst unter Uhrzeit und Akku
/// durch, und der Pfeil schwebte ohne Grund über dem Text.
struct Detailkopf: View {
    @Environment(\.fensterknoepfe) private var fensterknoepfe
    let titel: String
    /// Wie weit gescrollt wurde. Ab `ab` steht die Leiste voll.
    let versatz: CGFloat
    var ab: CGFloat = Stil.heldHoehe - 150
    let zurueck: () -> Void

    private var staerke: Double {
        guard ab > 0 else { return 1 }
        return Double(min(max((versatz - ab) / 70, 0), 1))
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: zurueck) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Stil.schrift)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Erscheint mit der Leiste, nicht davor: früher stand er kurz
            // über dem Titel im Heldenbild.
            Text(titel)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .opacity(staerke)

            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .padding(.trailing, Stil.randAbstand)
        .padding(.top, fensterknoepfe ? Fensterknoepfe.hoehe : 0)
        .padding(.bottom, 6)
        .background(alignment: .bottom) {
            Rectangle().fill(Stil.linie).frame(height: 1).opacity(staerke)
        }
        .background {
            ZStack {
                // Solange das Bild oben steht, nur ein weicher Verlauf, damit
                // der Pfeil auf hellem Bild lesbar bleibt.
                LinearGradient(colors: [Stil.grund.opacity(0.7), Stil.grund.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(1 - staerke)
                Leistenglas(staerke: staerke)
            }
            .ignoresSafeArea(edges: .top)
        }
    }
}

/// Zeile, die sich nach links ziehen lässt und dabei eine Handlung freigibt.
///
/// **Keine eigene Zuggeste.** Zwei Gesten um dieselbe Bewegung streiten zu
/// lassen geht nicht sauber aus: mit `.gesture` verlor die Liste das
/// senkrechte Scrollen, mit `.simultaneousGesture` blieb der Finger an den
/// Zeilen hängen. Die Entscheidung, ob eine Bewegung waagerecht oder senkrecht
/// gemeint ist, trifft UIKit seit jeher selbst — man muss sie nur stellen.
///
/// Deshalb ist jede Zeile eine waagerechte Scrollfläche mit zwei Feldern:
/// dem Inhalt in voller Breite und der Handlung daneben. Senkrechtes Scrollen
/// gehört damit weiterhin der Liste, das Einrasten übernimmt
/// `scrollTargetBehavior`, und das Nachfedern kommt gratis dazu.
///
/// `.swipeActions` wäre der kürzere Weg, gibt es aber nur in `List` — und die
/// Folgenliste steht auf der Serienseite mitten in einer laufenden Seite.
struct Wischzeile<Inhalt: View>: View {
    let symbol: String
    let beschriftung: LocalizedStringKey
    var farbe: Color = Stil.akzent
    let aktion: () -> Void
    let tippen: () -> Void
    @ViewBuilder var inhalt: () -> Inhalt

    private enum Feld: Hashable { case inhalt, handlung }
    @State private var sichtbar: Feld? = .inhalt
    @State private var weite: CGFloat = 0
    @State private var ausgeloest = false
    /// Zählt hoch, um die Scrollfläche neu aufzubauen.
    @State private var lauf = 0

    private let breite: CGFloat = 96
    /// Ab hier löst das Ziehen von selbst aus, ohne den Knopf zu treffen.
    private let schwelle: CGFloat = 168

    /// Handlung ausführen und die Zeile wieder zufahren.
    private func ausloesen() {
        ausgeloest = true
        aktion()
        // Die Scrollfläche neu aufbauen statt sie zurückzustellen.
        //
        // Über `scrollPosition` ging es nicht zu: sie setzt während des
        // Loslassens ihre eigene Stellung fertig und überschreibt den
        // gesetzten Wert — auch einen Takt später noch. Eine frische Fläche
        // beginnt dagegen immer bei null. Der Preis ist, dass sie zuschnappt
        // statt zuzufahren; da die Zeile im selben Moment ihren Haken
        // wechselt, fällt das nicht auf.
        lauf += 1
        sichtbar = .inhalt
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                inhalt()
                    .containerRelativeFrame(.horizontal)
                    // Deckend, damit die Handlungsfarbe darunter nicht
                    // durchscheint, solange die Zeile zu ist.
                    .background(Stil.grund)
                    .contentShape(Rectangle())
                    .onTapGesture { tippen() }
                    #if os(iOS)
                    // Muss **im** Inhalt liegen, nicht als Hintergrund der
                    // Scrollfläche: von dort aus findet die Hilfsansicht sie
                    // beim Hochlaufen der Hierarchie gar nicht.
                    .overlay(alignment: .topLeading) {
                        RandGesteVorrang().frame(width: 0, height: 0)
                    }
                    #endif
                    .id(Feld.inhalt)

                Button { ausloesen() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                        Text(beschriftung).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Stil.grund)
                    .frame(width: breite)
                    .frame(maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .id(Feld.handlung)
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, neu in
            weite = neu
            // Weit genug gezogen: auslösen, ohne den Knopf zu treffen.
            if neu > schwelle, !ausgeloest { ausloesen() }
            if neu <= 1 { ausgeloest = false }
        }
        // Die Handlungsfarbe liegt unter der ganzen Zeile, nicht nur unter dem
        // Knopf. Zieht man über den Anschlag hinaus, füllt sie mit, statt eine
        // Kante freizugeben — so macht es iOS auch.
        //
        // Nur wenn wirklich gezogen wird: sonst blitzt sie beim Aufbau der
        // Liste kurz auf, etwa beim Wechsel zwischen den Reitern.
        .background(weite > 0.5 ? farbe : Stil.grund)
        // Rastet entweder ganz zu oder ganz auf — nichts bleibt halb offen.
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $sichtbar, anchor: .leading)
        .id(lauf)
    }
}

/// Zurückpfeil oben links auf Unterseiten ohne eigene Kopfzeile.
///
/// Eigener Baustein, weil er sonst auf jeder Seite eine andere Höhe bekommt —
/// genau das war zwischen Profil und Quick Connect zu sehen.
struct Seitenpfeil: View {
    @Environment(\.fensterknoepfe) private var fensterknoepfe
    let zurueck: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: zurueck) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Stil.schrift)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zurück")
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.top, 6 + (fensterknoepfe ? Fensterknoepfe.hoehe : 0))
            // Der Verlauf hängt hier, weil ihn alle Unterseiten über den Pfeil
            // bekommen — sonst scrollte dort der Inhalt hart unter die
            // Statusleiste, während er auf den übrigen Seiten weich ausläuft.
            .background { Kopfverlauf() }
            Spacer(minLength: 0)
        }
    }
}

/// Eine Zeile auf der Profilseite: Symbol, Text, Pfeil, Haarlinie darunter.
///
/// Die Linie beginnt erst hinter dem Symbol — so liest sich die Gruppe als
/// zusammengehörig, statt in gleich breite Streifen zu zerfallen.
struct Profilzeile<Ziel: Hashable>: View {
    @Environment(\.breit) private var breit
    let symbol: String
    let titel: LocalizedStringKey
    var unter: LocalizedStringKey?
    var akzent = false
    var letzte = false
    /// Führt die Zeile weiter, trägt sie ein Sprungziel — sonst eine
    /// Handlung an Ort und Stelle.
    var ziel: Ziel?
    var aktion: () -> Void = {}

    var body: some View {
        Group {
            if let ziel {
                NavigationLink(value: ziel) { rumpf }
            } else {
                Button(action: aktion) { rumpf }
            }
        }
        .buttonStyle(.plain)
    }

    private var rumpf: some View {
        VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 17))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titel).font(.system(size: 16))
                        if let unter {
                            Text(unter)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.28))
                }
                .foregroundStyle(akzent ? Stil.akzent : Stil.schrift)
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.vertical, 15)

            if !letzte { Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit)) }
        }
        .contentShape(Rectangle())
    }
}

extension Profilzeile where Ziel == Never {
    init(symbol: String, titel: LocalizedStringKey, unter: LocalizedStringKey? = nil,
         akzent: Bool = false, letzte: Bool = false,
         aktion: @escaping () -> Void) {
        self.init(symbol: symbol, titel: titel, unter: unter, akzent: akzent,
                  letzte: letzte, ziel: nil, aktion: aktion)
    }
}

/// Heldenbild, das beim Überziehen wächst statt wegzurutschen.
///
/// Die Oberkante bleibt an der Oberkante des Bildschirms hängen; gezogen wird
/// nur die Unterkante nach unten. Beim Loslassen federt es zurück.
///
/// Gemessen wird mit `GeometryReader` und **nicht** über den Scrollversatz im
/// Zustand: der kommt einen Bildaufbau zu spät, und genau dieser eine Rahmen
/// war die harte Kante, die oben aufblitzte. Der Leser sitzt hier in einem
/// festen Rahmen, dehnt sich also nicht gierig aus.
struct Heldbild: View {
    let url: URL?
    var hoehe: CGFloat = Stil.heldHoehe
    var raum: String = "blatt"

    var body: some View {
        GeometryReader { rahmen in
            let oben = rahmen.frame(in: .named(raum)).minY
            let dehnung = max(0, oben)
            Bild(url: url, hoehe: hoehe + dehnung, ecke: 0)
                .offset(y: -dehnung)
        }
        .frame(height: hoehe)
    }
}

/// Reihe, die bei Platzmangel umbricht.
///
/// `HStack` bricht nie um, und `LazyVGrid` braucht feste Spalten — für Chips
/// unterschiedlicher Breite passt beides nicht.
struct FlussReihe: Layout {
    var waagerecht: CGFloat = 7
    var senkrecht: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let breite = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, zeilenhoehe: CGFloat = 0
        for teil in subviews {
            let mass = teil.sizeThatFits(.unspecified)
            if x > 0, x + mass.width > breite {
                x = 0
                y += zeilenhoehe + senkrecht
                zeilenhoehe = 0
            }
            x += mass.width + waagerecht
            zeilenhoehe = max(zeilenhoehe, mass.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + zeilenhoehe)
    }

    func placeSubviews(in rahmen: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = rahmen.minX, y = rahmen.minY, zeilenhoehe: CGFloat = 0
        for teil in subviews {
            let mass = teil.sizeThatFits(.unspecified)
            if x > rahmen.minX, x + mass.width > rahmen.maxX {
                x = rahmen.minX
                y += zeilenhoehe + senkrecht
                zeilenhoehe = 0
            }
            teil.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(mass))
            x += mass.width + waagerecht
            zeilenhoehe = max(zeilenhoehe, mass.height)
        }
    }
}

/// Auswahlchip: eine Möglichkeit aus wenigen, ohne Liste.
///
/// Für Filter und kurze Wertebereiche. Eine Liste wäre hier mehr Aufwand als
/// Nutzen — man sieht ohnehin alles auf einmal.
struct Wahlchip: View {
    let text: String
    let an: Bool
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            Text(text)
                .font(.system(size: 13, weight: an ? .semibold : .regular))
                .foregroundStyle(an ? Stil.grund : Stil.schrift)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(an ? Stil.akzent : Stil.erhoeht, in: Capsule())
                .overlay { Capsule().strokeBorder(an ? Stil.akzent : Stil.rand) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityAddTraits(an ? [.isButton, .isSelected] : .isButton)
    }
}

/// Liste von Handlungen, die von unten aufgeht.
///
/// Anders als `Auswahlblatt`: dort wählt man einen Wert und sieht, welcher
/// gilt. Hier löst jede Zeile etwas aus und das Blatt schließt sich.
struct Handlungsblatt: View {
    @Binding var offen: Bool
    /// Woran das Blatt arbeitet — nicht das Wort „Mehr". Das stand schon auf
    /// dem Knopf, und die Stelle ist zu wertvoll, um sie zu wiederholen.
    let titel: String
    /// Der Typ liegt in `Titelhandlung` und nicht hier: an diesen Baustein
    /// gebunden, konnten die anderen Plattformen dieselben Listen nicht
    /// bauen, obwohl die Handlungen überall dieselben sind.
    let handlungen: [Titelhandlung]

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture { schliessen() }

            // Genau die Werte des Auswahlblatts: obere Ecken 12, Titel 13
            // halbfett in schriftLeise, Zeilen 50, unten Abbrechen mit 54.
            // Vorher sprach dieses Blatt eine eigene Sprache — Versalien,
            // Ecke 14, kein Abbrechen — und stach damit heraus.
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

                Rectangle().fill(Stil.linie).frame(height: 1)
                    .padding(.leading, Stil.randAbstand)

                Button { schliessen() } label: {
                    Text("Abbrechen")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Stil.schriftLeise)
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.plain)
            }
            // Die Fläche muss selbst in den unteren Sicherheitsbereich
            // reichen, nicht der Inhalt.
            //
            // `clipShape` plus `ignoresSafeArea` auf dem Inhalt sieht richtig
            // aus, ist es aber nicht: der Stapel richtet den Inhalt unten
            // innerhalb des sicheren Bereichs aus, er wächst nicht von selbst
            // nach unten. Unter dem Blatt blieb dadurch ein Streifen in Höhe
            // des Home-Indikators, durch den die Seite dahinter schien.
            .background {
                UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12)
                    .fill(Stil.flaeche)
                    .ignoresSafeArea(edges: .bottom)
            }
            .transition(.move(edge: .bottom))
        }
    }

    private func schliessen() {
        withAnimation(.snappy(duration: 0.22)) { offen = false }
    }
}

/// Kurze Rückmeldung am unteren Rand.
///
/// Für Dinge, die der Server im Hintergrund tut — dort gibt es nichts zu
/// bestätigen, nur zu sagen, dass es angekommen ist.
struct Hinweisstreifen: View {
    let text: String
    let schliessen: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Stil.schrift)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Stil.erhoeht, in: Capsule())
                .overlay { Capsule().strokeBorder(Stil.rand) }
                .padding(.bottom, 34)
                .padding(.horizontal, 24)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .id(text)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            schliessen()
        }
    }
}

// MARK: - Leere und gestörte Ansichten

/// Was zu sehen ist, wenn nichts zu sehen ist.
///
/// Vorher hing so etwas direkt unter der Kopfzeile: ein kleines Systemsymbol,
/// grauer Text, eine graue Pille — darunter zwei Drittel Schwarz. Das liest
/// sich als Absturz, nicht als Hinweis. Hier sitzt der Block mittig im
/// verfügbaren Raum, das Zeichen steht in derselben Kreisfläche, die auch
/// sonst Flächen trägt, und der Text nennt Ross und Reiter.
struct Leerzustand: View {
    let symbol: String
    let kopfzeile: LocalizedStringKey
    let text: LocalizedStringKey
    /// Statt des Symbols dreht sich ein Ring — für „wird gerade versucht".
    var laedt = false
    var hauptknopf: (titel: LocalizedStringKey, tun: () -> Void)?
    var stillerKnopf: (titel: LocalizedStringKey, tun: () -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Stil.flaeche)
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.10)) }
                    .frame(width: 78, height: 78)
                if laedt {
                    Lader()
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Stil.schriftLeise)
                }
            }

            Text(kopfzeile)
                .mitwachsend(19, .semibold)
                .tracking(-0.3)
                .foregroundStyle(Stil.schrift)

            Text(text)
                .mitwachsend(14)
                .foregroundStyle(Stil.schriftLeise)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 262)

            // Der Hauptknopf ist sonst so breit wie die Seite. Hier steht er
            // mittig und nur so breit wie sein Text — eine Störung ist kein
            // Formular, das man ausfüllt.
            if let hauptknopf {
                Button(hauptknopf.titel, action: hauptknopf.tun)
                    .buttonStyle(HauptknopfStil())
                    .fixedSize()
                    .padding(.top, 6)
            }
            if let stillerKnopf {
                Button(stillerKnopf.titel, action: stillerKnopf.tun)
                    .buttonStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 34)
    }
}

// MARK: - Eingabefeld

/// Unser Feld statt `.roundedBorder`.
///
/// Dieselben Werte wie das Suchfeld — Fläche, Haarlinie, Ecke 10 —, nur 48
/// statt 44 hoch, damit es mit dem 48er Hauptknopf darunter eine Zeile bildet.
struct Eingabefeld: View {
    @Binding var text: String
    let symbol: String
    /// Als Schlüssel, nicht als Zeichenkette: sonst bleibt der Platzhalter in
    /// der Ausgangssprache stehen, während die Seite drumherum übersetzt ist.
    /// Genau das war auf der Anmeldeseite zu sehen — „Benutzername" und
    /// „Passwort" deutsch zwischen lauter englischen Beschriftungen.
    var platzhalter: LocalizedStringKey = ""
    var geheim = false
    var tastatur: Weise = .normal
    var abschluss: () -> Void = {}

    enum Weise { case normal, adresse }

    @State private var zeigt = false
    @FocusState private var amTippen: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(Color.white.opacity(0.42))
                .frame(width: 20)

            Group {
                if geheim, !zeigt {
                    SecureField("", text: $text, prompt: platz)
                } else {
                    TextField("", text: $text, prompt: platz)
                }
            }
            .font(.system(size: 16))
            .foregroundStyle(Stil.schrift)
            .focused($amTippen)
            .onSubmit(abschluss)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(tastatur == .adresse ? .URL : .default)
            .submitLabel(.go)
            #endif

            if geheim, !text.isEmpty {
                Button { zeigt.toggle() } label: {
                    Image(systemName: zeigt ? "eye.slash" : "eye")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.white.opacity(0.42))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(amTippen ? Stil.akzent.opacity(0.55) : Stil.rand)
        }
        .animation(.easeOut(duration: 0.15), value: amTippen)
    }

    private var platz: Text {
        Text(platzhalter).foregroundColor(Color.white.opacity(0.38))
    }
}
