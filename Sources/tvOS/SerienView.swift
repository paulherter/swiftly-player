import JellyfinKit
import SwiftUI

/// Die Serienseite: oben derselbe Kopf wie bei einem Film, darunter die
/// Folgen, die Besetzung und Ähnliches.
///
/// **Keine Reiter mehr.** Vorher standen „Folgen", „Besetzung" und
/// „Ähnliches" als drei Schalter nebeneinander, und nur einer war jeweils zu
/// sehen. Der Entwurf legt sie stattdessen untereinander — dieselbe Bauart
/// wie die Startseite, jede Reihe ein `Section`-Abschnitt. Damit entfällt
/// auch der Umweg, den die Reiter nötig gemacht hatten: ein eigener
/// `onMoveCommand`, der den Fokus von Hand nach oben schob, weil links über
/// „Folgen" nichts Fokussierbares stand.
///
/// Die Folgen sind jetzt ein waagerechter Streifen mit denselben Querkacheln
/// wie „Weiterschauen", nicht mehr eine senkrechte Liste. `Folgenzeile`
/// bleibt trotzdem — das Folgenblatt im Player benutzt sie weiter.
/// **Was einmal geholt wurde, bleibt fuer den Rueckweg liegen.**
///
/// Die Serienseite holte bei jedem Oeffnen alles neu: Staffeln, Stand,
/// Folgen. Solange der Seitenwechsel ueberblendete, hat das niemand gesehen —
/// die Ueberblendung war laenger als der Abruf. Ohne sie schneidet man hart
/// hinein und sieht „Laedt…" am Hauptknopf und den Ring, wo die Folgen
/// stehen. Paul: „die Seite laedt jetzt total immer, anstatt instant smooth
/// reinzukommen."
///
/// Der Abruf ist nicht langsamer geworden, er war nur verdeckt. Die Antwort
/// ist deshalb nicht, die Ueberblendung zurueckzuholen, sondern beim zweiten
/// Mal gar nicht erst zu warten.
///
/// Absichtlich **nur fuers Bild**, nicht als Wahrheit: beim Erscheinen laeuft
/// der Abruf trotzdem und schreibt frische Werte darueber. Wer eine Folge als
/// gesehen markiert und zurueckkommt, sieht den neuen Stand — nur eben ohne
/// Loch davor.
@MainActor
final class Serienspeicher {
    static let geteilt = Serienspeicher()

    struct Stand {
        /// Die Serie selbst — fuer den Umweg von einer Folge aus, der sie
        /// sonst jedes Mal nachholt. Siehe `StaffelZiel`.
        var serie: Item?
        var staffeln: [Item] = []
        var weiterMit: Item?
        var folgen: [String: [Item]] = [:]   // je Staffel
    }

    private var bekannt: [String: Stand] = [:]
    private var reihenfolge: [String] = []

    func stand(_ serie: String) -> Stand? { bekannt[serie] }

    func merken(_ serie: String, _ aendern: (inout Stand) -> Void) {
        if bekannt[serie] == nil {
            bekannt[serie] = Stand()
            reihenfolge.append(serie)
        }
        aendern(&bekannt[serie]!)
        while reihenfolge.count > 12 { bekannt[reihenfolge.removeFirst()] = nil }
    }
}

struct SerienView: View {
    let model: AppModel
    let serie: Item
    /// Kommt man über eine einzelne Folge, ist deren Staffel schon gewählt.
    var startStaffelID: String?
    /// **Und diese Folge ist zugleich die Stelle, an der es weitergeht.**
    ///
    /// Der Hauptknopf wartete sonst auf `standInSerie` — einen Abruf, dessen
    /// Ergebnis der Aufrufer schon in der Hand hat. Auf dem Weg über
    /// „Weiterschauen" oder „Nächste Folge" ist die geöffnete Folge genau
    /// das, was der Knopf nennen soll.
    ///
    /// Nur als Anfangswert: `laden()` holt den frischen Stand und schreibt
    /// darüber. Wer die Serie direkt aus der Bibliothek öffnet, hat ihn
    /// nicht — dort bleibt es beim Abruf, und beim zweiten Mal greift der
    /// `Serienspeicher`.
    var startFolge: Item?

    /// **Der Anfangsstand kommt aus dem Speicher, nicht aus dem Nichts.**
    ///
    /// Dieselbe Ueberlegung wie bei `Bildgrund` und `Kulisse`: ein
    /// nachgereichter Wert kommt zu spaet, der leere Durchgang hat dann
    /// schon stattgefunden — und genau der ist das „Laedt…". Siehe
    /// `Serienspeicher`.
    @MainActor init(model: AppModel, serie: Item,
                    startStaffelID: String? = nil, startFolge: Item? = nil) {
        self.model = model
        self.serie = serie
        self.startStaffelID = startStaffelID
        self.startFolge = startFolge

        let gemerkt = Serienspeicher.geteilt.stand(serie.id)
        _staffeln = State(initialValue: gemerkt?.staffeln ?? [])
        _weiterMit = State(initialValue: gemerkt?.weiterMit ?? startFolge)

        // Die Staffel, die auch `laden()` waehlen wuerde — sonst stuende
        // beim Wiederkommen die erste vorn statt der zuletzt gesehenen.
        let gesucht = startStaffelID ?? gemerkt?.weiterMit?.seasonId ?? startFolge?.seasonId
        // Der Server kann an einer Folge kein `SeasonId` liefern — dann ueber
        // die Nummer, die immer dasteht. Am Geraet gemessen.
        let gesuchteNummer = startFolge?.parentIndexNumber ?? gemerkt?.weiterMit?.parentIndexNumber
        let staffel = gemerkt?.staffeln.first { $0.id == gesucht }
                   ?? gemerkt?.staffeln.first { $0.indexNumber != nil
                                                && $0.indexNumber == gesuchteNummer }
                   ?? gemerkt?.staffeln.first
        _gewaehlteStaffel = State(initialValue: staffel)

        let folgen = staffel.flatMap { gemerkt?.folgen[$0.id] } ?? []
        _folgen = State(initialValue: folgen)
        _laedtFolgen = State(initialValue: folgen.isEmpty)
    }

    /// **Was neu ist, blendet beim Erscheinen ein — nicht beim Laden.**
    ///
    /// Vorher hing die Ueberblendung an der Ankunft der Daten. Seit die
    /// Zwischenspeicher greifen, kommen die aber schon im ersten Durchgang
    /// mit, also gab es nichts mehr zu animieren: beim ersten Mal war es
    /// etwas weich, ab dem zweiten hart. Paul: „ab dem zweiten Mal ist es gar
    /// nicht mehr smooth." Das war ein Widerspruch in meinem eigenen Aufbau —
    /// erst instant machen, dann Uebergaenge an Ereignisse haengen, die es
    /// nicht mehr gibt.
    ///
    /// Am Erscheinen aufgehaengt, blendet es **jedes Mal** ein, ob die Daten
    /// schon dastehen oder nicht.
    @State private var eingeblendet = false

    @State private var frisch: Item?
    @State private var plan: PlaybackPlan?
    @State private var staffeln: [Item]
    @State private var gewaehlteStaffel: Item?
    @State private var folgen: [Item]
    @State private var laedtFolgen: Bool
    @State private var gemerkt = false
    @State private var gesehen = false
    @State private var meldung: String?
    /// Der Player liegt im Rahmen — siehe `HauptView`.
    @Environment(\.abspielwunsch) private var abspielen
    @State private var bereitet = false
    @State private var weiterMit: Item?
    @State private var aehnliche: [Item] = []
    @State private var mehrOffen = false
    @State private var staffelwahlOffen = false
    /// Welche Folgenkachel den Fokus hat.
    @FocusState private var amFolge: String?
    /// Ob der Hauptknopf den Fokus hat — er ist der Startpunkt der Seite.
    @FocusState private var amHauptknopf: Bool
    /// **Wohin der Fokus zurueckkehrt, wenn eine Tafel zugeht.**
    ///
    /// Er sprang auf den Hauptknopf — den Startfokus der Seite —, obwohl man
    /// gerade am Mehr-Knopf beziehungsweise an der Staffelpille stand. Paul:
    /// „aus einer Logik heraus muesste er ja auf den drei Punkten sein, weil
    /// ich da ja gerade war."
    ///
    /// Stimmt: eine Tafel ist kein Ortswechsel, sondern etwas, das ueber dem
    /// Knopf aufklappt (E5). Wer sie schliesst, steht wieder an dem Knopf,
    /// mit dem er sie geoeffnet hat.
    @FocusState private var amMehrknopf: Bool
    @FocusState private var amStaffelpille: Bool

    private var aktuell: Item { frisch ?? serie }
    private var darsteller: [Person] { (aktuell.people ?? []).filter(\.istDarsteller) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                kopf

                reihenabschnitt {
                    HStack(spacing: 34) {
                        Reihentitel(text: "Folgen")
                        if staffeln.count > 1, let staffel = gewaehlteStaffel {
                            Staffelpille(name: staffel.name, offen: $staffelwahlOffen)
                                .focused($amStaffelpille)
                        }
                    }
                } inhalt: {
                    folgenstreifen
                }
                .opacity(eingeblendet ? 1 : 0)

                if !darsteller.isEmpty {
                    reihenabschnitt {
                        Reihentitel(text: "Besetzung")
                    } inhalt: {
                        Besetzungsstreifen(model: model, leute: darsteller)
                    }
                    .opacity(eingeblendet ? 1 : 0)
                    .transition(.opacity)
                }
                if !aehnliche.isEmpty {
                    reihenabschnitt {
                        Reihentitel(text: "Ähnliches")
                    } inhalt: {
                        Titelstreifen(model: model, items: aehnliche)
                    }
                    .opacity(eingeblendet ? 1 : 0)
                    .transition(.opacity)
                }
            }
            .padding(.bottom, Stil.abschlussLuft)
        }
        .scrollIndicators(.hidden)
        // Rand wie auf der Filmseite — siehe dort.
        .ignoresSafeArea()
        // **Der Grund der ganzen Seite faerbt sich nach der Kulisse.**
        //
        // **Nach `ignoresSafeArea`, nicht davor.** Davor bekam er die um
        // den sicheren Bereich verkleinerte Flaeche — 1760 x 960 statt
        // 1920 x 1080. Das Netz rechnet in Bruchteilen seiner Flaeche,
        // sass damit auf der Detailseite anders als auf der Startseite,
        // und beim Oeffnen sah man den Unterschied als Schrumpfen. Paul:
        // „die Maske um das Bild wird einmal komplett klein und dann
        // wieder normal."
        //
        // Die Startseite hatte es von Anfang an nach `ignoresSafeArea`;
        // dass die beiden verschieden standen, war der Unterschied.
        //
        // An der Seite und nicht am Kopf: sonst endet die Faerbung an dessen
        // Unterkante, und quer ueber dem Schirm steht eine Naht. Siehe
        // `Bildgrund`.
        .bildgrund(url: model.querbildURL(for: aktuell, breite: 1600)
                        ?? model.backdropURL(for: aktuell))
        // Die Staffelwahl liegt auf der **Seite**, nicht am Pillenknopf —
        // siehe `Handlungstafel.unterDemReihenkopf`.
        //
        // **Solange eine Tafel offen ist, ist der Rest kein Fokusziel.**
        //
        // `focusSection` haelt den Fokus nicht fest, es ordnet ihn nur. Ein
        // Druck nach links oder rechts sprang deshalb aus der offenen Tafel
        // heraus in die Folgen dahinter — die Tafel blieb stehen und ging
        // erst weg, wenn man die Seite verliess. Paul hat es an der
        // Staffelauswahl und am Mehr-Blatt gefunden, es ist dieselbe Stelle.
        //
        // Gesperrt wird **vor** den Auflagen: die Tafeln haengen danach und
        // bleiben damit selbst bedienbar.
        .disabled(mehrOffen || staffelwahlOffen)
        .overlay(alignment: .topLeading) {
            if staffelwahlOffen {
                Handlungstafel(handlungen: staffelhandlungen, offen: $staffelwahlOffen)
                    .padding(.leading, Stil.randSeite)
                    .padding(.top, Handlungstafel.unterDemReihenkopf)
                    .transition(.opacity)
            }
        }
        // Das Mehr-Blatt an derselben Stelle wie auf der Filmseite. Es hing
        // vorher am Knopf und klappte nach oben auf, weil die Knopfreihe
        // unter den Folgen stand; jetzt steht sie wieder im Kopf, also gilt
        // wieder der feste Platz (VERHALTEN.md D7).
        .overlay(alignment: .topLeading) {
            if mehrOffen {
                Handlungstafel(handlungen: mehrHandlungen, offen: $mehrOffen)
                    .padding(.leading, Stil.randSeite)
                    .padding(.top, Handlungstafel.unterDerKnopfreihe)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: mehrOffen)
        .animation(.easeInOut(duration: 0.18), value: staffelwahlOffen)
        .overlay(alignment: .top) {
            if let meldung {
                Hinweisstreifen(text: meldung) { self.meldung = nil }
                    .padding(.top, Stil.randOben)
            }
        }
        // **Beim Oeffnen steht der Fokus auf der laufenden Folge.**
        //
        // Der Streifen ist ohnehin dorthin gescrollt; ohne Zuweisung faende
        // tvOS die vorderste Kachel meist von selbst. „Meist" ist zu wenig,
        // wenn es darauf ankommt, wo die Seite aufmacht.
        //
        // **Der Startfokus gehoert auf den Hauptknopf, nicht auf eine
        // Folge.** Hier stand das Gegenteil, mit der Begruendung, der Kopf
        // habe seit dem Umbau nichts Fokussierbares mehr — das galt fuer die
        // Zwischenfassung ohne Knopfreihe und stimmt nicht mehr, seit sie
        // zurueck ist. Auf der Filmseite landet der Fokus ebenfalls dort, und
        // A4 sagt, was der Knopf tut: die Folge, bei der es weitergeht.
        //
        // `folgeVorn` bleibt trotzdem — es entscheidet weiter, welche Folge
        // in der Reihe **vorn steht**. Das ist der Scrollstand, nicht der
        // Fokus, und die beiden waren hier verwechselt.
        .defaultFocus($amHauptknopf, true, priority: .userInitiated)
        .onChange(of: mehrOffen) { _, offen in if !offen { amMehrknopf = true } }
        .onChange(of: staffelwahlOffen) { _, offen in if !offen { amStaffelpille = true } }
        .task {
            // Erst den Fokus setzen, dann aufblenden: ein Knopf mit
            // Deckkraft 0 ist fuer tvOS kein Ziel, und der Startfokus ginge
            // sonst verloren.
            amHauptknopf = true
            withAnimation(.easeOut(duration: 0.3)) { eingeblendet = true }
            await laden()
        }
        .task(id: gewaehlteStaffel?.id) { await folgenLaden() }
    }

    // MARK: Kopf

    /// **Kopf wie auf der Filmseite: Text und Knopfreihe.**
    ///
    /// Eine Zwischenfassung hatte den Abspielknopf hier entfernt, mit dem
    /// Argument, die Folge stehe ja fokussiert in der Reihe darunter. Das
    /// stand gegen die freigegebene Tafel (`Serie-Neu.dc.html`), in der
    /// „Fortsetzen · S2 F4", „Von vorn", „Merkliste" und „Gesehen" im Kopf
    /// stehen, und gegen A9 und E6 im Verhaltensregister: dieselbe
    /// Reihenfolge auf jeder Plattform, ein Hauptknopf je Seite. Paul hat
    /// die Tafel bestaetigt — der Knopf gehoert her.
    ///
    /// **Weiss wird er nicht durch einen eigenen Stil, sondern durch den
    /// Fokus.** `KnopfStil` faerbt die fokussierte Pille weiss, und der
    /// Fokus faellt beim Oeffnen auf den ersten Knopf der Reihe. So loest
    /// tvOS E6 — dieselbe Regel wie ueberall hier: Fokus ist weiss.
    private var kopf: some View {
        Detailkopf(model: model, item: aktuell, plan: plan) {
            // **Instant gilt nur fuer das, was schon da war.**
            //
            // Paul: „der Button und alles, was vorher nicht da war, muss ja
            // sowieso eingeblendet werden — instant ergibt nur Sinn fuer die
            // Sachen, die vorher schon da waren."
            //
            // Das ist die klarere Regel. Titel, Angaben, Beschreibung, Bild
            // und Grund standen auf der Startseite schon: die stehen sofort
            // und ruehren sich nicht. Die Knopfreihe gab es dort nicht — sie
            // darf kommen, wenn sie etwas zu sagen hat.
            //
            // **Der Hauptknopf ist davon ausgenommen, und zwar zweimal
            // begruendet.** Eingeblendet sah er falsch aus: die Animation
            // hing am Wert, also wuchs die Pille sichtbar von „Laedt…" auf
            // „Fortsetzen S1 • E3" — ein Schieben nach rechts, keine Blende.
            // Und mit Deckkraft 0 ist er fuer tvOS kein Fokusziel mehr, also
            // ging der Startfokus verloren.
            //
            // Er muss deshalb von Anfang an richtig dastehen. Auf dem
            // ueblichen Weg geht das auch: wer ueber eine Folge hereinkommt,
            // bringt genau die Folge mit, bei der es weitergeht — siehe
            // `startFolge`.
            HStack(spacing: 24) {
                Button { starte(weiterMit) } label: {
                    Label(hauptknopftext, systemImage: "play.fill")
                }
                .buttonStyle(KnopfStil())
                // **Nicht abschalten, solange geladen wird.**
                //
                // Ein abgeschalteter Knopf ist auf tvOS kein Fokusziel. Wer
                // aus der Suche auf eine Serie ging, traf den Hauptknopf
                // deshalb abgeschaltet an — die Folgen waren noch unterwegs,
                // `weiterMit` noch nil — und der Fokusmotor nahm den
                // naechsten in der Reihe: Merkliste. Kam die Folge an, wurde
                // der Knopf wieder fokussierbar, aber der Fokus wandert nicht
                // von selbst zurueck. Auf den ueblichen Wegen fiel es nicht
                // auf, weil dort die Folge schon im Zwischenspeicher liegt.
                //
                // Der Kommentar zwoelf Zeilen weiter oben beschreibt genau
                // diesen Fehler in seiner anderen Form: mit Deckkraft 0 ist
                // der Knopf ebenfalls kein Fokusziel mehr. Zweimal dieselbe
                // Ursache im selben Block.
                //
                // `serienknopf` hat fuer diesen Moment schon die richtige
                // Beschriftung — „Laedt…". Sie wurde nie gezeigt, weil die
                // Abschaltung den Knopf vorher unerreichbar machte. Jetzt
                // steht sie da, der Knopf ist von Anfang an fokussierbar, und
                // `starte` tut ohne Folge ohnehin nichts.
                //
                // Abgeschaltet bleibt er, wenn wirklich nichts da ist
                // („Keine Folgen") und waehrend `bereitet` — das ist der
                // kurze Moment nach dem Druck.
                .disabled(bereitet || (weiterMit == nil && !laedtFolgen))
                .focused($amHauptknopf)

                // Nur, wenn ueberhaupt etwas fortzusetzen ist — sonst meinte
                // „Von vorn" dasselbe wie der Knopf daneben.
                if angefangen {
                    Button { starte(weiterMit, ab: 0) } label: {
                        Image(systemName: "arrow.counterclockwise").font(Stil.knopf)
                    }
                    .buttonStyle(KnopfStil(nurSymbol: true))
                    .accessibilityLabel(Text("Von vorn"))
                    .disabled(bereitet)
                }

                Zustandsknoepfe(model: model, item: aktuell,
                                gemerkt: $gemerkt, gesehen: $gesehen,
                                meldung: $meldung)

                Mehrknopf(offen: $mehrOffen)
                    .focused($amMehrknopf)
            }
            .opacity(eingeblendet ? 1 : 0)
        }
    }

    /// Ob die Folge, bei der es weitergeht, schon angefangen ist.
    private var angefangen: Bool {
        (weiterMit?.userData?.playbackPositionTicks ?? 0) > 0
    }

    /// „Fortsetzen S1 • E3" — aus `Titelangaben`, geteilt mit allen.
    ///
    /// Stand hier als eigene Fassung, nachgelesen bei iOS. Der Hauptchat hat
    /// sie in `Item.serienknopf(folge:laedt:)` gehoben, bevor die dritte
    /// Kopie daraus wurde; damit faellt unsere weg. Genau der Weg, den die
    /// Regel vorsieht: geteilte Logik zuerst nach iOS, dann uebernehmen.
    private var hauptknopftext: String {
        Item.serienknopf(folge: weiterMit, laedt: laedtFolgen)
    }

    // MARK: Folgen

    @ViewBuilder
    private var folgenstreifen: some View {
        // **Ein Stapel, damit sich die beiden denselben Platz teilen.**
        //
        // Waehrend der Ueberblendung sind alte und neue Reihe **beide** im
        // Layout. Untereinander gesetzt steht die neue damit unter der alten
        // und rutscht erst hoch, wenn die alte draussen ist — Paul: „die
        // Staffel 2 ist ein paar Zentimeter tiefer als Staffel 1."
        //
        // Im `ZStack` liegen sie uebereinander, also an derselben Stelle.
        // Die feste Hoehe haelt den Platz auch dann, wenn gerade nichts
        // dasteht; sonst zoege sich die Seite waehrend des Wechsels zusammen.
        ZStack(alignment: .topLeading) {
            if laedtFolgen {
                // Nur damit die Seite nicht zusammenschnurrt, solange nichts
                // dasteht — der Streifen selbst bringt seine Hoehe mit.
                Color.clear
                    .frame(height: Stil.querHoehe + 2 * Stil.reihenLuft + 80)
            } else if folgen.isEmpty {
                Leerzustand(symbol: "rectangle.stack",
                            titel: "Keine Folgen in dieser Staffel")
                    .frame(height: Stil.querHoehe + 2 * Stil.reihenLuft + 80)
            } else {
                Folgenstreifen(model: model, folgen: folgen,
                               weiterMit: folgeVorn, amFolge: $amFolge) { folge in
                    starte(folge)
                }
                .id(folgen.first?.id ?? "leer")
                .transition(.opacity)
            }
        }
        // **Keine erzwungene Hoehe.** Sie war meine Zutat gegen das
        // Untereinanderstehen waehrend der Ueberblendung — und hat den
        // Unterschied erst gemacht: der waagerechte Streifen ist gierig, er
        // fuellt eine vorgegebene Hoehe aus, und sein Inhalt sitzt darin
        // mittig. Wie hoch der Inhalt gerade ist, haengt am Zustand; also
        // sass er je Staffel anders. Erst zentriert (32 Punkt Unterschied),
        // dann oben (Staffel 1 zu hoch) — beides Symptome derselben Zutat.
        //
        // Der Stapel allein reicht: er legt alte und neue Reihe uebereinander
        // und nimmt seine Hoehe vom Inhalt, wie vorher auch.
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Welche Folge vorn stehen soll.
    ///
    /// Nur, wenn `weiterMit` **in der gezeigten Staffel** liegt. Sonst waere
    /// es die falsche Reihe: nach einem Staffelwechsel will man F1 sehen,
    /// nicht eine Folge aus einer anderen Staffel, die hier gar nicht steht.
    private var folgeVorn: String? {
        guard let stand = weiterMit,
              stand.seasonId == gewaehlteStaffel?.id,
              folgen.contains(where: { $0.id == stand.id })
        else { return nil }
        return stand.id
    }

    /// Die Staffeln als Handlungstafel — kein `Menu`, wie überall in der App.
    private var staffelhandlungen: [Titelhandlung] {
        staffeln.map { staffel in
            Titelhandlung(symbol: gewaehlteStaffel?.id == staffel.id
                                  ? "checkmark.circle.fill" : "circle",
                          text: "\(staffel.name)") {
                gewaehlteStaffel = staffel
            }
        }
    }

    // MARK: Beschriftung und Laden

    private func laden() async {
        async let frischeSerie = model.item(id: serie.id)
        async let liste = model.staffeln(serie)
        async let stand = model.standInSerie(serie)

        frisch = await frischeSerie
        staffeln = await liste
        weiterMit = await stand
        Serienspeicher.geteilt.merken(serie.id) {
            $0.serie = frisch ?? serie
            $0.staffeln = staffeln
            $0.weiterMit = weiterMit
        }
        gemerkt = aktuell.userData?.isFavorite ?? false
        gesehen = aktuell.userData?.played ?? false

        if gewaehlteStaffel == nil {
            // Über eine Folge gekommen: deren Staffel steht vorn. Sonst die,
            // in der es weitergeht — und erst dann die erste.
            let gesucht = startStaffelID ?? weiterMit?.seasonId
            // Und ueber die Nummer, wenn der Server keine Kennung mitgibt.
            let nummer = startFolge?.parentIndexNumber ?? weiterMit?.parentIndexNumber
            gewaehlteStaffel = staffeln.first { $0.id == gesucht }
                ?? staffeln.first { $0.indexNumber != nil && $0.indexNumber == nummer }
                ?? staffeln.first
        }
        if let ziel = weiterMit {
            plan = await model.plan(for: ziel.id)
        }
        let neueAehnliche = await model.aehnliche(serie)
        withAnimation(.easeOut(duration: 0.3)) { aehnliche = neueAehnliche }
    }

    private func folgenLaden() async {
        guard let staffel = gewaehlteStaffel else { return }
        if folgen.isEmpty { laedtFolgen = true }
        let geholt = await model.folgen(serie: serie.id, staffel: staffel.id)

        // Ein Zug, eine Kurve. Den Wechsel von Hand zu fuehren — ausblenden,
        // warten, tauschen, einblenden — war der falsche Weg: er flackerte,
        // weil ihm die Ansicht unter den Haenden getauscht wurde. Siehe die
        // Kennung am Streifen.
        withAnimation(.easeInOut(duration: 0.28)) {
            folgen = geholt
            laedtFolgen = false
        }
        Serienspeicher.geteilt.merken(serie.id) { $0.folgen[staffel.id] = geholt }
    }

    private var mehrHandlungen: [Titelhandlung] {
        // Gesehen steht vorn, wie auf der Filmseite — aus der Knopfreihe
        // heraus und eine Ebene tiefer. Siehe `gesehenHandlung`.
        [gesehenHandlung(model: model, item: aktuell,
                         gesehen: $gesehen, meldung: $meldung)]
        + Titelhandlungen.fuerSerie(aktuell, stand: weiterMit, staffel: gewaehlteStaffel,
                                  model: model,
                                  folgeStarten: { folgeStarten($0, ab: $1) },
                                  melden: { meldung = $0 },
                                  auffrischen: { await auffrischen() })
    }

    private func folgeStarten(_ folge: Item, ab: Double) {
        Task {
            guard let plan = await model.plan(for: folge.id) else {
                meldung = String(localized: "Die Folge konnte nicht geladen werden.")
                return
            }
            abspielen.wrappedValue = Abspielwunsch(item: folge, plan: plan, startAt: ab)
        }
    }

    /// **Alles neu, nicht nur die Serie.**
    ///
    /// Erster Anlauf holte Titel und Folgen, aber nicht `weiterMit`. Nach
    /// „Staffel als gesehen" haette der Hauptknopf weiter „Folge 3
    /// fortsetzen" angeboten, obwohl der Server sie als gesehen fuehrt — und
    /// der Beleg haette den Plan der alten Folge gezeigt.
    ///
    /// Deshalb ueber `laden()`: was beim Oeffnen geholt wird, muss auch beim
    /// Auffrischen geholt werden, sonst laufen die beiden Wege auseinander.
    /// Die gewaehlte Staffel bleibt dabei stehen.
    private func auffrischen() async {
        await laden()
        await folgenLaden()
    }

    /// `ab` uebersteuert die gemerkte Stelle — das ist „Von vorn".
    ///
    /// Ohne Angabe gilt A5: eine Folge startet an **ihrer eigenen** Stelle.
    private func starte(_ folge: Item?, ab: Double? = nil) {
        guard let folge, !bereitet else { return }
        bereitet = true
        Task {
            defer { bereitet = false }
            let ziel = await model.item(id: folge.id) ?? folge
            guard let plan = await model.plan(for: ziel.id) else {
                meldung = String(localized: "Der Server nennt keine Quelle für diese Folge.")
                return
            }
            abspielen.wrappedValue = Abspielwunsch(item: ziel, plan: plan,
                                      startAt: ab ?? ziel.fortsetzenAb ?? 0)
        }
    }
}

// MARK: - Eine Folge in der Liste

/// Vorschaubild links, Titel, Laufzeit und zwei Zeilen Beschreibung rechts —
/// derselbe Aufbau wie auf dem iPhone, nur in Fernsehmaßen.
///
/// Steht seit dem neuen Entwurf **nur noch im Folgenblatt** des Players: dort
/// liegt die Liste über dem laufenden Bild, und eine senkrechte Liste ist
/// dafür richtig. Auf der Serienseite sind die Folgen jetzt ein waagerechter
/// Streifen — siehe `Folgenstreifen`.
struct Folgenzeile: View {
    let model: AppModel
    let folge: Item
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            HStack(alignment: .top, spacing: 34) {
                // `querbildURL` baut die Adresse aus `seriesId ?? id` — bei
                // einer Folge ist `seriesId` gesetzt, also kam für jede Folge
                // derselbe Serienhintergrund heraus. `imageURL` ohne
                // `hochkant` löst dagegen über `imageTags["Primary"]` das
                // eigene Vorschaubild der Folge auf; genau so macht es die
                // iPhone-Fassung. Nur wenn eine Folge keines hat, tritt der
                // Serienhintergrund als Rückfall ein.
                Bild(url: model.imageURL(for: folge, maxHeight: 360)
                          ?? model.querbildURL(for: folge, breite: 640),
                     breite: 320, hoehe: 180, ecke: Stil.ecke,
                     fortschritt: fortschritt)

                VStack(alignment: .leading, spacing: 0) {
                    Text(kopfzeile)
                        .font(.system(size: 31, weight: .semibold))
                        .lineLimit(1)

                    if let sekunden = folge.runtimeSeconds {
                        Text("\(Int(sekunden / 60)) Min")
                            .font(Stil.klein)
                            .foregroundStyle(Stil.schriftSehrLeise)
                            .padding(.top, 4)
                    }

                    if let text = folge.overview, !text.isEmpty {
                        Text(text)
                            .font(Stil.kachel)
                            .lineSpacing(9)
                            .foregroundStyle(Stil.schriftLeise)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.top, 12)
                    }
                }
                .padding(.top, 6)

                Spacer(minLength: 0)

                // Gesehene Folgen tragen einen leisen Haken am rechten Rand
                // — genau wie auf dem iPhone. Ohne den sieht man der Liste
                // nicht an, wo man stehengeblieben ist.
                if folge.istGesehen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Stil.schriftSehrLeise)
                        .padding(.top, 12)
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 26)
        }
        .buttonStyle(FolgenStil())
    }

    private var kopfzeile: String {
        if let nummer = folge.indexNumber { return "F\(nummer) · \(folge.name)" }
        return folge.name
    }

    private var fortschritt: Double? { folge.gesehenerAnteil }
}

/// Fokus auf einer Folgenzeile: eine ruhige Fläche.
///
/// Anders als bei Kacheln, wo nur die Größe spricht — eine Zeile ist kein
/// Bild, sie kann nicht heller werden. Dieselbe Fläche wie ein ruhender Chip.
struct FolgenStil: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .foregroundStyle(Stil.schrift)
                .background(fokus ? Color.white.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: Stil.eckeKachel))
                .animation(Stil.fokusAnimation, value: fokus)
        }
    }
}
