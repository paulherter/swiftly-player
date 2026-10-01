import JellyfinKit
import SwiftUI

// MARK: - Der Kopf, den Film und Serie teilen

/// Kulisse, Titel, Angaben, Beschreibung und Knopfreihe — die obere Haelfte
/// jeder Detailseite.
///
/// Auf dem iPhone sind Film- und Serienseite **dieselbe Seite**: gleicher
/// Kopf, gleiche Belegzeile, gleicher weisser Knopf, gleiche Aktionsreihe. Nur
/// die Beschriftung des Knopfes wechselt, und bei Serien kommen darunter die
/// Folgen. Genau so ist es hier — deshalb steht der Kopf in einem eigenen
/// Baustein und nicht zweimal.
///
/// **510 hoch, nicht 1080.** Vorher fuellte der Kopf den ganzen Schirm, das
/// Poster stand links und der Text daneben. Der Entwurf nimmt stattdessen die
/// Kopfzone der Startseite: Kulisse rechts, Text links, und darunter beginnen
/// bei 534 die Reihen — **dieselbe Zeile, in der auf der Startseite der erste
/// Reihentitel steht** (510 + `Stil.reihenKopfLuft`). Beim Wechsel von Start
/// auf Detail bleiben die Reihen also stehen. Das ist der Griff, der die
/// beiden Seiten zusammenhaelt.
///
/// Das Poster faellt damit weg. Es trug den Fortschrittsbalken; der steht
/// jetzt dort, wo er auf jeder anderen Kachel auch steht — an der Folge in
/// der Reihe darunter.
///
/// Kein Zurueckpfeil und keine Reiterleiste: die Seite ist aufgeschlagen,
/// nicht eine Ebene der Startseite. Zurueck macht auf tvOS die Menue-Taste.
struct Detailkopf<Knoepfe: View>: View {
    let model: AppModel
    let item: Item
    let plan: PlaybackPlan?
    /// Ob der Kopf ueberhaupt etwas Fokussierbares enthaelt.
    ///
    /// Die Serienseite hat seit dem Umbau keine Knopfreihe mehr — dort steht
    /// nur Text. Ein `focusSection` ohne Ziel darin ist kein leerer Aufwand,
    /// sondern schaedlich: tvOS meldet einen Bereich an, zieht den Druck
    /// dorthin, findet nichts und laesst ihn fallen. Genau daran ist die
    /// Besetzungsreihe schon einmal haengengeblieben.
    var fokussierbar = true
    @ViewBuilder var knoepfe: () -> Knoepfe

    @ViewBuilder
    var body: some View {
        if fokussierbar { rumpf.focusSection() } else { rumpf }
    }

    private var rumpf: some View {
        ZStack(alignment: .topLeading) {
            Kulisse(url: model.querbildURL(for: item, breite: 1600)
                         ?? model.kopfbildURL(for: item))
                .frame(maxWidth: .infinity, alignment: .trailing)

            // **Derselbe Kopfschatten wie auf der Startseite.**
            //
            // Hier hat er keine Leiste zu tragen — es gibt keine. Er steht
            // trotzdem, und zwar aus einem Grund, der nichts mit Lesbarkeit
            // zu tun hat: er war die letzte Ebene, die es nur auf einer der
            // beiden Seiten gab. Beim Oeffnen blendete er weg, und das war
            // das Aufhellen oben, das nach einer Ueberblendung aussah,
            // obwohl sich Bild und Netz gar nicht aenderten.
            //
            // Dieselbe Regel wie beim Kopfblock, bei der Kulissenblende und
            // beim gefaerbten Grund: was auf beiden Seiten gleich aussehen
            // soll, muss dieselbe Ebene sein — sonst sieht man den
            // Unterschied genau im Uebergang.
            Kopfschatten()

            block
                .padding(.leading, Stil.randSeite)
                // 140 aus der Tafel, plus der Versatz, der die nicht
                // gezeichnete Kopfleiste freihaelt — siehe
                // `Stil.kopfversatzDetail`. Zusammen 196, also dieselbe
                // Zeile, in der die Startseite ihren Titel hat.
                .padding(.top, 140 + Stil.kopfversatzDetail)
        }
        // Nicht beschnitten: die Kulisse ist 700 hoch und darf nach unten
        // ueberragen, ihr eigener Verlauf beendet sie. Die erste Reihe
        // zeichnet darueber, sie ist das naechste Geschwister.
        //
        // 566 statt 510: die Zone waechst um denselben Versatz wie der Text
        // darin, sonst waere der Abstand zur ersten Reihe um 56 kleiner als
        // in der Tafel.
        .frame(height: Stil.heldenHoeheDetail, alignment: .topLeading)
    }

    // **Der ganze Kopf ist ein Fokusabschnitt, nicht nur die Knopfreihe.**
    //
    // tvOS sucht geometrisch. Ohne den Abschnitt findet ein Druck nach oben
    // aus der ersten Reihe nur, was zufaellig in derselben Spalte steht — und
    // links steht die Kulisse, die kein Ziel ist. Umfasst der Abschnitt den
    // ganzen Kopf, landet jeder Weg nach oben auf dem einzigen
    // Fokussierbaren darin: der Knopfreihe. Siehe `fokussierbar`.

    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **Derselbe Baustein wie auf der Startseite.** Der Header ist
            // dort und hier identisch; das Einzige, was hier dazukommt, ist
            // die Knopfreihe. Siehe `Kopfauskunft`.
            Kopfauskunft(item: item, logoModell: model) {
                // **Der Beleg blendet ein, der Rest des Kopfes nicht.**
                //
                // Er haengt an `plan`, und der kommt vom Server — im Kopf,
                // der sonst still steht, erschien er sonst mitten hinein.
                // Er gehoert zu dem, was neu dazukommt: auf der Startseite
                // gibt es ihn nicht, dort ist noch kein Plan geholt.
                if let plan {
                    Belegmarken(direktplay: plan.isLossless,
                                hinweis: plan.isLossless ? nil : plan.method.rawValue,
                                belegZuletzt: true)
                        .transition(.opacity)
                }
            }
            // **Die Blende haengt am Plan, nicht an der Transaktion des
            // Aufrufers.**
            //
            // `.transition` allein blendet nur, wenn der Plan in einer
            // animierten Transaktion ankommt. Die Filmseite setzt ihn in
            // ihrem `withAnimation`; die Serienseite holt ihn seit
            // fb4ce5a5 (24.09., „ein Einblenden statt mehrerer Stufen")
            // nach dem gemeinsamen Einblenden ohne Animation — und seitdem
            // sprang die Direct-Play-Marke dort herein. Hier festgemacht
            // gilt die Blende fuer jede Seite, die den Kopf traegt, egal
            // wie sie ihren Plan setzt. Die Marke steht zuletzt in der
            // Zeile, es verschiebt sich also nichts.
            .animation(Stil.bewegung(.easeOut(duration: 0.3)), value: plan != nil)

            // Die Knopfreihe darf breiter werden als die 1000 des Textes.
            // Deshalb liegt der Deckel am Text und nicht am ganzen Block;
            // einmal stand er aussen, und jede Beschriftung war
            // abgeschnitten.
            //
            // 36 aus `Film-Neu.dc.html`. Weil `auskunftHoehe` fest ist,
            // sitzt die Reihe damit auf **jeder** Detailseite bei 490.
            knoepfe()
                .padding(.top, 36)
        }
    }

}

// MARK: - Merkliste und Gesehen

/// Der Merklistenknopf — **nur das Symbol, ohne Beschriftung.**
///
/// Stimmt: das Lesezeichen ist eines der wenigen Symbole, die für sich stehen,
/// und gefüllt gegen leer sagt den Zustand mit. Fünf beschriftete Pillen waren
/// zu viel für eine Reihe.
///
/// „Gesehen" ist ganz aus der Reihe heraus und steht in der Handlungstafel —
/// siehe `Titelhandlung.sehstand`. Damit bleiben vier Ziele: Fortsetzen, Von vorn,
/// Merkliste, Mehr.
///
/// **Ohne Beschriftung ist die Beschriftung Pflicht.** Für VoiceOver ist ein
/// Symbolknopf sonst namenlos (E8), deshalb der ausdrückliche Name.
struct Zustandsknoepfe: View {
    let model: AppModel
    let item: Item
    @Binding var gemerkt: Bool
    @Binding var gesehen: Bool
    @Binding var meldung: String?

    var body: some View {
        Group {
            Button {
                gemerkt.toggle()
                // Sofort umschalten, damit der Knopf antwortet — aber
                // zurückdrehen, wenn der Server nein sagt.
                Task {
                    if let grund = await model.setzeMerkliste(item, an: gemerkt) {
                        gemerkt.toggle()
                        meldung = grund
                    }
                }
            } label: {
                Image(systemName: gemerkt ? "bookmark.fill" : "bookmark")
                    .font(Stil.knopf)
            }
            .buttonStyle(KnopfStil(nurSymbol: true, aktiv: gemerkt))
            .accessibilityLabel(Text("Merkliste"))
            // Gefuelltes gegen leeres Symbol ist der ganze Unterschied —
            // fuer VoiceOver heissen beide „Merkliste".
            .accessibilityAddTraits(gemerkt ? [.isButton, .isSelected] : .isButton)
        }
    }
}

// „Gesehen" steht nicht als Pille in der Knopfreihe, sondern in der
// Handlungstafel — **Anordnung, kein Verhalten** (VERHALTEN.md F): D6 verlangt,
// dass Gesehen sofort umschaltet und der Zustand die Antwort ist; das tut es
// dort weiter, nur eine Ebene tiefer. Am Fernseher zaehlt jedes Fokusziel in
// der Reihe, und fuenf davon nebeneinander waren zu viele. Der Eintrag selbst
// kommt aus dem gemeinsamen Baustein: `Titelhandlung.sehstand` in
// `Sources/Shared/Kachelmenue.swift`.

// MARK: - Filmseite

/// Kopf mit Knopfreihe, darunter „Ähnliche Filme", „Extras" und „Besetzung" —
/// jede Reihe ein `Section`-Abschnitt wie auf der Startseite.
struct DetailView: View {
    let model: AppModel
    let item: Item

    @State private var frisch: Item?
    @State private var plan: PlaybackPlan?
    /// Zählt die Abrufe von Titel und Plan; nur der jüngste schreibt (Öffnen und
    /// Auffrischen können sich überholen).
    @State private var titellauf = 0
    @State private var gemerkt = false
    @State private var gesehen = false
    @State private var meldung: String?
    /// Der Player liegt im Rahmen — siehe `HauptView`.
    @Environment(\.abspielwunsch) private var abspielen
    /// **Alles unter dem Kopf ist beantwortet** — Sammlung, Aehnliches,
    /// Extras, Besetzung. Gesetzt in derselben animierten Transaktion wie die
    /// Daten, deshalb blendet es jedes Mal ein, auch wenn die Zwischenspeicher
    /// schon alles hatten.
    ///
    /// Vorher hiess das `eingeblendet` und hing am Erscheinen der Seite: die
    /// Reihen standen dann zwar weich da, aber jede fuer sich, sobald ihre
    /// Daten kamen, und die Sammlungsreihe als eigener Abruf zuletzt. Noch
    /// frueher hing die Ueberblendung an der Ankunft der Daten und war ab dem
    /// zweiten Oeffnen hart — beides ist mit dem gemeinsamen Schalter erledigt.
    @State private var untenDa = false
    @State private var sammlungsreihen: [AppModel.Sammlungsreihendaten] = []
    /// **Wohin der Fokus zurueckkehrt, wenn eine Tafel zugeht.**
    ///
    /// Er sprang auf den Hauptknopf — den Startfokus der Seite, obwohl man
    /// gerade am Mehr-Knopf beziehungsweise an der Staffelpille stand.
    ///
    /// Stimmt: eine Tafel ist kein Ortswechsel, sondern etwas, das ueber dem
    /// Knopf aufklappt (E5). Wer sie schliesst, steht wieder an dem Knopf, mit
    /// dem er sie geoeffnet hat.
    @FocusState private var amMehrknopf: Bool
    /// **Der Startfokus gehoert auf den Hauptknopf.**
    ///
    /// Er stand hier nirgends — tvOS suchte sich geometrisch etwas aus, und
    /// wer ueber die Suche hereinkam, landete auf „Merkliste". Die
    /// Serienseite setzt ihn seit heute ausdruecklich; die Filmseite hatte
    /// es nur bisher zufaellig richtig getroffen, weil der Fokus meist von
    /// oben links kam.
    @FocusState private var amHauptknopf: Bool
    /// **Wohin der Fokus zurueckkehrt, wenn der Player zugeht.**
    ///
    /// Derselbe Grund wie bei `amMehrknopf`, nur fuer den Player: er liegt im
    /// Rahmen als Geschwister, die Seite bleibt beim Abspielen durchgehend
    /// eingehaengt, nur `disabled` — und das setzt `amHauptknopf`/`amMehrknopf`
    /// dabei auf `false` zurueck. Ohne diese Erinnerung sucht sich tvOS beim
    /// Entfernen des Players geometrisch etwas aus und landet oben am ersten
    /// Reiter der Kopfleiste.
    private enum Fokusziel { case hauptknopf, mehrknopf }
    @State private var zuletztFokus: Fokusziel = .hauptknopf

    @State private var bereitet = false
    @State private var aehnliche: [Item] = []
    @State private var extras: [Item] = []
    @State private var mehrOffen = false

    private var aktuell: Item { frisch ?? item }
    private var darsteller: [Person] { (aktuell.people ?? []).filter(\.istDarsteller) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                kopf

                // **Alles unter dem Kopf kommt auf einmal** — wie am iPhone
                // (`untenDa` in `BrowseViews.swift`, 24.09.2026). Sammlung,
                // Aehnliches, Extras und Besetzung trafen einzeln ein; die
                // Sammlungsreihe lud sogar selbst und kam als letzte. Jetzt
                // wartet die Seite auf alle und blendet sie gemeinsam ein.
                if untenDa {
                    VStack(alignment: .leading, spacing: 0) {
                        // Ueber „Aehnliche Filme": die Sammlung ist die naehere
                        // Verwandtschaft. Nur bei Titeln, die in einer stehen.
                        Sammlungsreihe(model: model, titel: item, reihen: sammlungsreihen)

                        if !aehnliche.isEmpty {
                            reihenabschnitt {
                                Reihentitel(text: "Ähnliche Filme")
                            } inhalt: {
                                Titelstreifen(model: model, items: aehnliche)
                            }
                        }
                        if !extras.isEmpty {
                            // **Der Trailer wohnt hier**, nicht als sechste Pille.
                            // Ein Trailer ist etwas zum Abspielen, keine Auskunft —
                            // ein Regalplatz passt besser als eine Zeile in der
                            // Handlungstafel.
                            reihenabschnitt {
                                Reihentitel(text: "Extras")
                            } inhalt: {
                                Titelstreifen(model: model, items: extras) { extra in
                                    starte(extra, ab: 0)
                                }
                            }
                        }
                        if !darsteller.isEmpty {
                            reihenabschnitt {
                                Reihentitel(text: "Besetzung")
                            } inhalt: {
                                Besetzungsstreifen(model: model, leute: darsteller, herkunft: item.name)
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.bottom, Stil.abschlussLuft)
        }
        .scrollIndicators(.hidden)
        // **Der seitliche Rand wird einmal vergeben, nicht zweimal.**
        //
        // tvOS haelt links und rechts von sich aus 80 Punkt frei, und die
        // Seite legt `Stil.randSeite` (auch 80) darauf. Zusammen waren es
        // 160 — doppelt so viel wie im Entwurf, der immer ab 80 misst.
        // Deshalb faellt der Systemrand hier weg; `randSeite` misst danach
        // ab der Bildkante.
        //
        // **An jeder Seite einzeln, nicht am Rahmen.** Im Rahmen versucht
        // steht es wirkungslos da: der `NavigationStack` in `stapel(b)`
        // setzt den sicheren Bereich fuer seinen Inhalt neu. Gemessen, nicht
        // vermutet — die Wortmarke rueckte, der Inhalt darunter nicht.
        .ignoresSafeArea()
        // **Der Grund der ganzen Seite faerbt sich nach der Kulisse.**
        //
        // **Nach `ignoresSafeArea`, nicht davor.** Davor bekam er die um den
        // sicheren Bereich verkleinerte Flaeche — 1760 x 960 statt 1920 x
        // 1080. Das Netz rechnet in Bruchteilen seiner Flaeche, sass damit auf
        // der Detailseite anders als auf der Startseite, und beim Oeffnen sah
        // man den Unterschied als Schrumpfen.
        //
        // Die Startseite hatte es von Anfang an nach `ignoresSafeArea`; dass
        // die beiden verschieden standen, war der Unterschied.
        //
        // An der Seite und nicht am Kopf: sonst endet die Faerbung an dessen
        // Unterkante, und quer ueber dem Schirm steht eine Naht. Siehe
        // `Bildgrund`.
        .bildgrund(url: model.querbildURL(for: aktuell, breite: 1600)
                        ?? model.kopfbildURL(for: aktuell))
        // **Solange eine Tafel offen ist, ist der Rest kein Fokusziel.**
        //
        // `focusSection` haelt den Fokus nicht fest, es ordnet ihn nur. Ein
        // Druck nach links oder rechts sprang deshalb aus der offenen Tafel
        // heraus in die Folgen dahinter — die Tafel blieb stehen und ging erst
        // weg, wenn man die Seite verliess.
        //
        // Gesperrt wird **vor** den Auflagen: die Tafeln haengen danach und
        // bleiben damit selbst bedienbar.
        .defaultFocus($amHauptknopf, true, priority: .userInitiated)
        .onChange(of: mehrOffen) { _, offen in if !offen { amMehrknopf = true } }
        .onChange(of: amHauptknopf) { _, an in if an { zuletztFokus = .hauptknopf } }
        .onChange(of: amMehrknopf) { _, an in if an { zuletztFokus = .mehrknopf } }
        // Siehe `zuletztFokus`: der Player hinterlaesst denselben leeren
        // Fokus wie eine offene Tafel, nur eine Ebene hoeher — dieselbe
        // Zuweisung holt ihn zurueck.
        .onChange(of: abspielen.wrappedValue == nil) { vorher, geschlossen in
            guard geschlossen, vorher == false else { return }
            fokusZurueck()
        }
        // **Dasselbe nach „Gemeinsam schauen".** Die Tafel liegt im Rahmen
        // ueber allem und sperrt die Seite wie der Player. Geht sie zu, ohne
        // dass ein Player aufgeht, steht der Fokus wieder am Ausloeser.
        .onChange(of: Gemeinsammodell.geteilt.anlegenFuer == nil) { vorher, zu in
            guard zu, vorher == false, abspielen.wrappedValue == nil else { return }
            fokusZurueck()
        }
        .disabled(mehrOffen)
        // Unter dem Mehr-Knopf, an seiner Kante — siehe `Tafelanker`. Vorher
        // `unterDerKnopfreihe`: aus dem Kopfaufbau gerechnet und um den
        // sicheren Rand daneben. Der Knopf steht ganz rechts, die Tafel ist
        // breiter als er — `Handlungstafel.links` klemmt sie deshalb an seine
        // rechte Kante statt sie aus dem Bild laufen zu lassen.
        .tafel(unter: mehrOffen ? "mehr" : nil) {
            Handlungstafel(handlungen: mehrHandlungen, offen: $mehrOffen)
                .transition(.opacity)
        }
        .animation(Stil.bewegung(.easeInOut(duration: 0.18)), value: mehrOffen)
        .overlay(alignment: .top) {
            if let meldung {
                Hinweisstreifen(text: meldung) { self.meldung = nil }
                    .padding(.top, Stil.randOben)
            }
        }
        // Nach dem Player neu holen — er liegt als Ebene darüber, `.task`
        // läuft kein zweites Mal. Siehe `AppModel.wiedergabeBeendet`.
        .onChange(of: model.seitenAuffrischen) { _, _ in Task { await auffrischen() } }
        .task {
            titellauf += 1
            let meiner = titellauf
            async let frischerTitel = model.item(id: item.id)
            async let planung = model.plan(for: item.id)
            async let aehnlich = model.aehnliche(item)
            async let extra = model.extras(item)
            async let vorschau = model.trailer(zu: item)
            async let sammlung = model.sammlungsreihen(zu: item)
            // **Einmal aufblenden, nicht dreimal.**
            //
            // `.transition` allein greift nicht — sie wirkt nur, wenn die
            // Aenderung in einer **animierten Transaktion** stattfindet, und
            // Werte aus `await` tragen keine. Deshalb war zuerst alles hart
            // da, obwohl die Uebergaenge dranstanden.
            //
            // Danach standen drei getrennte `withAnimation` hier: Titel und
            // Plan, dann die Extras, dann die Folgen. Jeder Schub blendete
            // fuer sich, und das ueberlagerte sich zu einem Flackern statt
            // eines Uebergangs. Jetzt wird **alles abgewartet und einmal**
            // gezeigt.
            //
            // Instant bleibt, was schon auf der Startseite stand: Titel,
            // Angaben, Beschreibung, Bild, Grund. Ueberblendet wird nur, was
            // neu dazukommt.
            // **Titel und Plan zuerst und gleich.** Hauptknopf („Fortsetzen
            // ab ..."), Merken, Gesehen und die Direct-Play-Marke haengen nur
            // an diesen beiden; sie warten nicht auf Trailer und Sammlungen.
            let neuerTitel = await frischerTitel
            let neuerPlan = await planung
            if meiner == titellauf {
                withAnimation(Stil.bewegung(.easeOut(duration: 0.32))) {
                    if let neuerTitel { frisch = neuerTitel }
                    plan = neuerPlan
                }
                gemerkt = aktuell.userData?.isFavorite ?? false
                gesehen = aktuell.istGesehen
            }
            let neueAehnliche = Listenregeln.ohneDoppelte((await aehnlich) ?? [])

            // Der Trailer steht vorn in den Extras: er war einmal eine eigene
            // Pille, und die Knopfreihe des Entwurfs hat dafuer keinen Platz.
            // Ersatzlos streichen waere falsch — ein Trailer ist etwas zum
            // Abspielen, und dafuer gibt es hier ein Regal.
            var regal = (await extra) ?? []
            if let vorschau = await vorschau { regal.insert(vorschau, at: 0) }
            let neueSammlungen = await sammlung

            withAnimation(Stil.bewegung(.easeOut(duration: 0.32))) {
                aehnliche = neueAehnliche
                extras = regal
                sammlungsreihen = neueSammlungen
                untenDa = true
            }
        }
    }

    /// Kulisse, Text und Knopfreihe.
    ///
    /// **Ein einziger beschrifteter Knopf, der Rest sind Symbole.** Das ist
    /// auch E6 — ein Hauptknopf je Seite, hier nur konsequenter gelesen als
    /// vorher: was nicht der Hauptknopf ist, muss sich auch nicht wie einer
    /// ausbreiten.
    ///
    /// Fuenf beschriftete Pillen waren rund 1400 Punkt breit und lasen sich
    /// wie fuenf gleichwertige Angebote. Jetzt traegt „Fortsetzen"
    /// beziehungsweise „Abspielen" den Text, daneben stehen drei quadratische
    /// Symbole: zurueck, Merkliste, Mehr.
    ///
    /// Jedes davon nennt VoiceOver seinen Namen ausdruecklich — ein
    /// Symbolknopf erbt keine Beschriftung (E8).
    ///
    /// **Langer Druck auf den Hauptknopf: das Kachelmenü des Titels** —
    /// dasselbe wie an seiner Kachel (``Kachelmenue``). Vorher gab es auf der
    /// Detailseite keins.
    private var kopf: some View {
        Detailkopf(model: model, item: aktuell, plan: plan) {
            HStack(spacing: 24) {
                if let ab = aktuell.fortsetzenAb {
                    Button { starte(ab: ab) } label: {
                        Label("Fortsetzen", systemImage: "play.fill")
                    }
                    .buttonStyle(KnopfStil())
                    .disabled(bereitet)
                    .focused($amHauptknopf)
                    .kachelmenue(aktuell, model: model)

                    // Neu und ausdruecklich im Entwurf: wer schon angefangen
                    // hat, kam sonst nur ueber die Tafel an den Anfang zurueck.
                    Button { starte(ab: 0) } label: {
                        Image(systemName: "arrow.counterclockwise").font(Stil.knopf)
                    }
                    .buttonStyle(KnopfStil(nurSymbol: true))
                    .accessibilityLabel(Text("Von vorn"))
                    .disabled(bereitet)
                } else {
                    Button { starte(ab: 0) } label: {
                        Label("Abspielen", systemImage: "play.fill")
                    }
                    .buttonStyle(KnopfStil())
                    .disabled(bereitet)
                    .focused($amHauptknopf)
                    .kachelmenue(aktuell, model: model)
                }

                Zustandsknoepfe(model: model, item: aktuell,
                                gemerkt: $gemerkt, gesehen: $gesehen, meldung: $meldung)

                Mehrknopf(offen: $mehrOffen)
                    .focused($amMehrknopf)
                    .tafelausloeser("mehr")
            }
        }
    }

    // MARK: Starten

    /// Zurueck an den Knopf oder die Folge, an der man zuletzt stand.
    private func fokusZurueck() {
        switch zuletztFokus {
        case .hauptknopf: amHauptknopf = true
        case .mehrknopf: amMehrknopf = true
        }
    }

    private var mehrHandlungen: [Titelhandlung] {
        // Gesehen steht vorn — es ist das, wofuer die Tafel jetzt am
        // haeufigsten geoeffnet wird. Die geteilte Liste bleibt unangetastet.
        [Titelhandlung.sehstand(aktuell, model: model, gesehen: $gesehen,
                                 melden: { meldung = $0 })]
        + Titelhandlungen.fuerFilm(aktuell, plan: plan, model: model,
                                   starten: { starte(ab: $0) },
                                   melden: { meldung = $0 },
                                   gemeinsam: Gemeinsammodell.geteilt.darfAnlegen
                                       ? { [aktuell] in Gemeinsammodell.geteilt.anlegenFuer = aktuell } : nil)
    }

    private func auffrischen() async {
        // Auch den Plan: er traegt den Direct-Play-Beleg, und ein Stand ohne
        // seinen Plan ist ein halber Stand.
        titellauf += 1
        let meiner = titellauf
        async let frischerTitel = model.item(id: item.id)
        async let planung = model.plan(for: item.id)
        let neu = await frischerTitel
        let neuerPlan = await planung
        guard meiner == titellauf else { return }
        if let neu { frisch = neu }
        plan = neuerPlan
        gemerkt = aktuell.userData?.isFavorite ?? false
        gesehen = aktuell.istGesehen
    }

    /// Frisch geholt: die Position im Listeneintrag ist oft veraltet.
    private func starte(ab: Double) {
        starte(aktuell, ab: ab, frisch: true)
    }

    /// Einen Titel starten — denselben oder ein Extra.
    private func starte(_ titel: Item, ab: Double, frisch: Bool = false) {
        Abspielwunsch.starten(titel, ab: ab, frisch: frisch, model: model, bereitet: $bereitet,
                              fehlt: { meldung = String(localized: "Der Server hat keine Datei zu diesem Titel.") },
                              abspielen: { abspielen.wrappedValue = $0 })
    }
}
