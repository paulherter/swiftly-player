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
/// aenderte sich beim Hinein- und Herausgehen.
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
                            auslauf: CGFloat? = nil,
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
    // hineingeht. Beim Oeffnen fehlte sie deshalb, und die Kacheln standen 20
    // Punkt zu hoch; beim ersten Fokussieren kam sie dazu und alles rueckte.
    //
    // An zwei Bildschirmfotos gemessen: Reihentitel steht in beiden bei 683, die
    // Kacheln bei 742 und 762. Die Differenz ist auf den Punkt `reihenLuft` —
    // deshalb war es nie ein Scrollen und nie das Section-Verhalten, obwohl
    // beides danach aussah.
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
    .contentMargins(.leading, Stil.randSeite, for: .scrollContent)
    // **Rechts so viel Luft, dass auch die letzte Kachel vorn stehen kann**
    // (`auslauf`). Ohne sie hoerte die Flaeche auf, sobald die letzte Kachel
    // rechts anschlug: in einer Staffel mit zehn Folgen liess sich F8 nicht
    // an die erste Stelle fahren, und `scrollPosition` blieb davor stehen.
    .contentMargins(.trailing, auslauf ?? Stil.randSeite, for: .scrollContent)
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
    /// Woher man kommt — steht auf der Personenseite über der Rolle.
    var herkunft: String? = nil

    var body: some View {
        streifen {
            ForEach(leute) { person in
                // **Hier stand ein Knopf mit leerer Aktion.** Er sah aus wie
                // ein Weg und war keiner — gebaut, aber nicht angeschlossen.
                NavigationLink(value: PersonRoute(person: person, herkunft: herkunft)) {
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
                                     titel: item.name, quer: true,
                                     zeichen: item.kachelzeichen)
                    }
                    .buttonStyle(KachelStil())
                } else {
                    NavigationLink(value: item) {
                        Kachelinhalt(bild: model.imageURL(for: item, maxHeight: 600,
                                                          hochkant: true),
                                     titel: item.name,
                                     fortschritt: item.userData?.playedPercentage
                                         .map { $0 / 100 },
                                     mitUnterzeile: false,
                                     marke: Anzeigeregeln.kachelmarke(
                                        art: item.type,
                                        staffeln: item.childCount,
                                        gesehen: item.userData?.played,
                                        offeneFolgen: item.userData?.unplayedItemCount),
                                     zeichen: item.kachelzeichen)
                    }
                    .buttonStyle(KachelStil())
                    .kachelmenue(item, model: model)
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
/// Dieselbe Reihe steht in der Folgenebene des Players (`FolgenEbene`).
struct Folgenstreifen: View {
    let model: AppModel
    let folgen: [Item]
    let starten: (Item) -> Void
    /// Meldet nach oben, welche Folge unter dem Fokus steht — und nimmt den
    /// Startfokus entgegen.
    @FocusState.Binding var amFolge: String?
    /// **Langer Druck: das Kachelmenü, wie an jeder anderen Folge**
    /// (``Kachelmenue``) — gesehen/ungesehen, Gemeinsam schauen. Vorher
    /// stand hier nur „Gemeinsam schauen", im Player gar nichts.
    ///
    /// Im Player ohne Abspielen und Gemeinsam — siehe `Kachelmenue.imPlayer`.
    var imPlayer = false
    /// Nach einer Änderung am Sehstand, damit Haken und Balken nachziehen.
    var nachher: (() async -> Void)? = nil

    /// Welche Kachel vorn steht. Beim Erscheinen die Folge, bei der es
    /// weitergeht — danach fuehrt die Scrollflaeche den Wert selbst nach.
    ///
    /// **Nicht als Anfangswert, sondern gleich danach gesetzt** (siehe
    /// `anfahren()`). Als Anfangswert stand hier seit 1.0.0 die Behauptung
    /// „gesetzt heisst angewandt" — am Apple TV (27.09.) stimmte das nicht:
    /// die Bindung trug die Folge, `defaultFocus` fand sie auch, aber die
    /// Reihe stand bei F1. Vermutlich liest `scrollPosition` den
    /// Anfangswert, bevor der faule Stapel etwas ausgemessen hat, und
    /// verwirft ihn; eine **Aenderung** der Bindung faehrt an. Frueher fiel das
    /// nicht auf, weil der Startfokus auf der Folge lag und der Fokusmotor
    /// sie ins Bild holte (entfernt in 87dd181e).
    @State private var vorne: String?
    /// Ob man schon selbst in der Reihe war. Bis dahin steht die Folge, bei
    /// der es weitergeht, vorn — auch wenn der Stand erst spaeter kommt.
    /// Danach gehoert der Scrollstand dem Nutzer.
    @State private var selbstDagewesen = false
    /// Die Folge, bei der es weitergeht, wie die Seite sie gerade kennt.
    ///
    /// **Sie kann sich nach dem Erscheinen noch aendern** — und genau das
    /// war der Fehler bei „From" (27.09.). Die Serienseite baut den Streifen
    /// beim zweiten Besuch sofort aus dem `Serienspeicher`, samt dem
    /// gemerkten Stand. Der ist alt, sobald man seitdem weitergeschaut hat;
    /// der frische kommt erst mit `laden()`. `vorne` nahm aber nur den
    /// Anfangswert, und `.equatable()` liess die Aenderung gar nicht erst
    /// durch: die Reihe blieb bei F1 (oder der alten Folge) stehen, obwohl
    /// der Knopf darueber schon die neue Folge nannte. Wo Speicher und
    /// Server uebereinstimmen oder die Seite zum ersten Mal aufgeht, fiel es
    /// nicht auf — so bei The Mentalist.
    let weiterMit: String?

    init(model: AppModel, folgen: [Item], weiterMit: String?,
         amFolge: FocusState<String?>.Binding,
         imPlayer: Bool = false,
         nachher: (() async -> Void)? = nil,
         starten: @escaping (Item) -> Void) {
        self.model = model
        self.folgen = folgen
        self.imPlayer = imPlayer
        self.nachher = nachher
        self.starten = starten
        self._amFolge = amFolge
        self.weiterMit = weiterMit
    }

    var body: some View {
        // **Ohne feste Hoehe.** Einmal versucht, mit 80 Punkt fuer die zwei
        // Beschriftungszeilen — am Bild gemessen sind es rund 122. Der
        // Rahmen war damit zu klein fuer seinen Inhalt, und der waagerechte
        // Streifen zentriert darin: es wurde schlimmer, nicht besser.
        //
        // Der eigentliche Befund lag ohnehin woanders, siehe unten.
        streifen(stand: $vorne,
                 // Die letzte Folge darf vorn stehen — siehe `auslauf`.
                 auslauf: Stil.schirmBreite - Stil.randSeite - Stil.querBreite) {
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
                                 // Ein voller Balken **und** ein Haken wären
                                 // dieselbe Auskunft zweimal.
                                 fortschritt: folge.istGesehen ? nil : folge.gesehenerAnteil,
                                 marke: folge.istGesehen ? .gesehen : nil,
                                 gesehen: folge.istGesehen,
                                 zeichen: folge.kachelzeichen)
                }
                .buttonStyle(KachelStil())
                .focused($amFolge, equals: folge.id)
                .kachelmenue(folge, model: model, quer: true,
                             imPlayer: imPlayer, nachher: nachher)
            }
        }
        // **Kein Nachziehen im Streifen.** Beim Oeffnen kommt die Liste der
        // Staffel zweimal: aus dem `Serienspeicher` sofort, frisch vom
        // Server in der animierten Transaktion von `laden()`. Dieselben
        // Folgen, aber mit neuem Sehstand, anderer Restzeit, mal einem
        // anderen Bild — und jede dieser Aenderungen lief animiert durch
        // den Streifen. Unterschiedlich breite Beschriftungen schoben die
        // Nachbarn im faulen Stapel hin und her, und der Stand vorne wurde
        // nachgefahren: das Zittern beim Oeffnen, das nur kam, wenn sich
        // zwischen Speicher und Server etwas geaendert hatte — also selten.
        //
        // Eingeblendet wird der Streifen weiter, aber von aussen (die
        // Uebergaenge an der Serienseite und am Player). Innen steht er
        // still; die Fokuskurven der Kacheln haengen an ihrem eigenen Wert
        // und gelten weiter.
        .transaction { $0.animation = nil }
        // **Runter aus dem Kopf landet auf der Folge vorn** — beim Oeffnen
        // ist das die, bei der es weitergeht. tvOS sucht sonst geometrisch
        // und nahm die Kachel unter dem Hauptknopf, also meist F1.
        // `.userInitiated`, weil genau der Druck nach unten gemeint ist.
        // Hat man selbst gescrollt, ist `vorne` die Kachel, die jetzt vorn
        // steht — der Fokus springt nicht zurueck an eine unsichtbare Stelle.
        .defaultFocus($amFolge, vorne ?? weiterMit, priority: .userInitiated)
        // **Beim Erscheinen und bei jedem spaeteren Stand vorn**, solange
        // man nicht selbst in der Reihe war. Der Streifen blendet von aussen
        // ein; der Zug nach vorn faellt in dessen ersten Augenblick und ist
        // unanimiert (`.transaction` oben), es rutscht also nichts sichtbar
        // nach.
        .task(id: weiterMit) { await anfahren() }
        .onChange(of: amFolge) { _, jetzt in
            if jetzt != nil { selbstDagewesen = true }
        }
    }

    /// Faehrt die Folge, bei der es weitergeht, an die erste Stelle.
    private func anfahren() async {
        guard !selbstDagewesen, let ziel = weiterMit else { return }
        // Einen Durchgang abwarten: dann steht die Scrollflaeche, und die
        // Aenderung der Bindung faehrt an, statt wie ein Anfangswert
        // verworfen zu werden.
        await Task.yield()
        // Abgelöst (neuer Stand kam nach): dessen Lauf fährt an, nicht dieser.
        guard !Task.isCancelled, !selbstDagewesen, vorne != ziel else { return }
        vorne = ziel
    }

    private func kopfzeile(_ folge: Item) -> String {
        // Übersetzt: Deutsch „F" wie Folge, Englisch „E" wie Episode — stand
        // hier fest als „F", auch auf Englisch (gemeldet 27.09.2026).
        guard let nummer = folge.indexNumber else { return folge.name }
        return String(localized: "F\(nummer)") + " · " + folge.name
    }

    /// „52 Min", und wo etwas angefangen ist, dahinter der Rest.
    private func dauerzeile(_ folge: Item) -> String? {
        var teile: [String] = []
        // Die Regel aus dem Paket, nicht eine eigene Pruefung daneben.
        if Anzeigeregeln.laufzeitZeigen(sekunden: folge.runtimeSeconds),
           let sekunden = folge.runtimeSeconds {
            teile.append(String(localized: "\(Int(sekunden / 60)) Min"))
        }
        // „Gesehen" steht als Haken im Bild, nicht als Wort.
        if let rest = folge.restzeitText { teile.append(rest) }
        return teile.isEmpty ? nil : teile.joined(separator: " · ")
    }
}

/// **Der Streifen zeichnet sich nur neu, wenn sich seine Folgen aendern.**
///
/// Dasselbe Muster wie `FolgenEbene` im Player (27.09.2026): `starten` und
/// `nachher` sind bei jedem Durchgang der Seite neue Bloecke, SwiftUI kann
/// sie nicht vergleichen und rechnete deshalb den ganzen Streifen samt
/// Kachelmenues neu — auf der Serienseite bei jedem Zustand, der sich beim
/// Oeffnen setzt: Fokus, Plan, Merkliste, Gesehen, Einblenden. Siehe den
/// Kommentar zu `tafelhandlungen` in `PlayerEbenen.swift`.
///
/// Verglichen wird, was der Streifen zeigt. `starten` und `nachher` lesen
/// ihren Zustand beim Aufruf, ein aelterer Block tut dasselbe wie ein neuer.
/// `weiterMit` zaehlt mit: der frische Stand muss durchkommen, siehe dort.
extension Folgenstreifen: @MainActor Equatable {
    static func == (links: Folgenstreifen, rechts: Folgenstreifen) -> Bool {
        links.folgen == rechts.folgen && links.imPlayer == rechts.imPlayer
            && links.weiterMit == rechts.weiterMit
            && links.model === rechts.model
    }
}

// MARK: - Teil der Sammlung

/// **Die Reihe „Teil der Sammlung" auf der Filmseite** — die anderen Titel
/// der Sammlung, in ihrer Folge. Dieselbe Regel wie am iPhone
/// (`Sammlungsreihe` in `Sammlungsseite.swift`): die Mitgliedschaft steht im
/// ``Sammlungsverzeichnis``, nur die Plakate kommen frisch; hoechstens zwei
/// Reihen; fehlt die Sammlung, fehlt die Reihe.
///
/// **Der Weg auf die Sammlungsseite ist eine Kapsel neben der Ueberschrift.**
/// Am iPhone ist die Ueberschrift selbst der Knopf; auf dem Fernseher ist
/// eine Ueberschrift kein Fokusziel, und ein Weg, den der Fokus nicht
/// erreicht, ist keiner (VERHALTEN F, Eingabe). Die Kapsel traegt den Namen
/// der Sammlung — dieselbe Angabe, die am iPhone darunter steht.
///
/// **Geladen wird auf der Filmseite, nicht hier** — wie am iPhone seit
/// 24.09.2026. Die Reihe holte sich ihre Titel selbst und kam spaeter als
/// alles andere; jetzt wartet die Filmseite auf sie wie auf Extras und
/// Aehnliches und blendet alles zusammen ein.
struct Sammlungsreihe: View {
    let model: AppModel
    let titel: Item
    let reihen: [AppModel.Sammlungsreihendaten]

    private var art: String? { Bibliotheksgattung.art(zuTyp: titel.type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(reihen, id: \.sammlung.id) { reihe in
                reihenabschnitt {
                    HStack(alignment: .center, spacing: 24) {
                        Reihentitel(text: "Teil der Sammlung")
                        NavigationLink(value: SammlungRoute(sammlung: reihe.sammlung.item, art: art)) {
                            Text(verbatim: reihe.sammlung.item.name)
                        }
                        .buttonStyle(KapselStil(pfeil: "chevron.right"))
                    }
                    .focusSection()
                } inhalt: {
                    Titelstreifen(model: model, items: reihe.titel)
                }
            }
        }
    }
}
