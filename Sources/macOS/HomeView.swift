import AppKit
import JellyfinKit
import SwiftUI

/// Die Startseite: Weiterschauen, Nächste Folge, Zuletzt hinzugefügt.
///
/// **Kein Kopfverlauf.** Auf iPhone und Fernseher liegt oben ein Verlauf,
/// weil dort Uhrzeit, Akku und die Wortmarke über dem scrollenden Inhalt
/// stehen und lesbar bleiben müssen. Im Fenster steht dort nichts — die
/// Wortmarke sitzt in der Seitenleiste. Ein Verlauf über Leerraum wäre eine
/// Verzierung ohne Aufgabe.
///
/// Eine Kachel in „Weiterschauen" startet **sofort** an der gemerkten Stelle,
/// „Nächste Folge" von vorn, „Zuletzt hinzugefügt" führt auf die Übersicht —
/// dort hat man noch nichts angefangen. Wörtlich die Regeln der
/// iPhone-Fassung.
struct HomeView: View {
    let model: AppModel
    @Environment(Abspielsteuerung.self) private var steuerung
    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    /// **Der geteilte Stand, nicht ein eigener.**
    ///
    /// Hier standen vier `@State`-Felder und eine eigene `laden()`. Das war
    /// ein Nachbau von `Startseitenmodell`, und er war schon auseinander
    /// gelaufen: er rief `naechsteFolge()` **ohne** Argument, sodass die
    /// Titel aus „Weiterschauen" gleich noch einmal unter „Nächste Folge"
    /// standen, und er räumte bei einem einzelnen Aussetzer die ganze Reihe
    /// leer — genau der Fehler, vor dem der Kommentar im geteilten Modell
    /// warnt.
    ///
    /// Der Stand liegt jetzt in `HauptView` und überlebt den Leistenwechsel.
    let stand: Startseitenmodell

    private var weiter: [Item] { stand.weiterschauen }
    private var naechste: [Item] { stand.naechsteFolge }
    private var neu: [Item] { stand.zuletzt }
    private var geladen: Bool { stand.geladen }

    /// Wo die Seite steht — als eigenes Objekt, damit ein Scrolltakt nicht den
    /// ganzen Rumpf neu auswertet. Begründung an `Kopfstand`.
    @State private var kopfstand = Kopfstand()

    var body: some View {
        ScrollView {
            // **Der Farbschein ist weg.** Er war im Code als Versuch auf
            // Widerruf angekuendigt (BAUTEILE 9.39) und wich von „Flaechen
            // sind flach" ab: der einzige Farbverlauf der App auf einer
            // Seitenflaeche, gebaut aus rohen Weisswerten. Rückmeldung vom 22.09.
            // nach dem Blick auf den Mac: raus. Damit faellt auch die
            // `ZStack` weg — es gibt nichts mehr zu ueberlagern.
            VStack(alignment: .leading, spacing: Stil.reihenAbstand) {

                // **Auch die Startseite trägt eine Überschrift.**
                //
                // Filme, Serien, Suche, Merkliste und Downloads hatten eine,
                // die Startseite nicht — sie fing mit „Weiterschauen" in 20
                // Punkt an. Rückmeldung vom 22.09.: „ich denke, wir sollten Startseite
                // hinzufügen." Damit fällt auch `reihenkopfAusgleich` weg: der
                // Ausgleich war dafür da, dass eine 20er Zeile so hoch stünde
                // wie ein 28er Titel. Jetzt steht dort ein 28er Titel.
                Text("Startseite")
                    .font(Stil.titelGross)
                    .tracking(Stil.sperrungTitel)
                    .foregroundStyle(Stil.schrift)
                    .padding(.horizontal, Stil.randAbstand)

                // **Genres als Chips, ganz oben** — wenn eingeschaltet. Ein
                // Einstieg, kein Inhalt: ein Klick öffnet das Genre.
                if model.genreChips, !model.startGenres.isEmpty { gattungschips }

                // **Die festen Reihen in der eingestellten Reihenfolge**, ohne
                // die ausgeblendeten — Einstellungen → Darstellung → Startseite.
                ForEach(model.startReihen.filter {
                    !model.startAus.contains($0) && $0.passt(getrennt: model.neuzugangGetrennt)
                }) { reihe in
                    feste(reihe)
                }

                // Die gewählten Genres als eigene Reihen, nach den festen.
                ForEach(stand.gattungsreihen) { gattung in
                    Reihe(name: gattung.name) {
                        ForEach(gattung.items, id: \.id) { titel in
                            Button { navigator.oeffne(.titel(titel), in: bereich) } label: {
                                Posterkachel(titel: titel.name,
                                             zweitzeile: titel.productionYear.map { "\($0)" },
                                             bild: model.imageURL(for: titel, hochkant: true),
                                             fortschritt: fortschritt(titel),
                                             zeichen: zeichen(titel),
                                             vorholen: { Serienspeicher.geteilt.vorholen(titel, mit: model) })
                            }
                            .buttonStyle(Stil.Druckknopf())
                        }
                    }
                }

                // **Gestört ist nicht leer.** Das Modell weiss den
                // Unterschied seit jeher (`Startseitenmodell.gestoert`), die
                // Mac-Fassung fragte ihn nur nicht: bei einem Server, der
                // nicht antwortet, stand hier „Hier ist noch nichts" — eine
                // falsche Auskunft, und sie schickt einen zum Server statt
                // zum Netz. Wortlaut und Zeichen sind die Serverformel, die
                // ueberall gleich lautet (BAUTEILE 6).
                if geladen, stand.gestoert {
                    Leerzustand(
                        symbol: "externaldrive.badge.xmark",
                        kopfzeile: "Server ist abgetaucht",
                        text: "\(model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                        hauptknopf: ("Erneut versuchen", { Task { await laden() } }))
                        .padding(.top, 120)
                } else if geladen, stand.alleLeer {
                    // `alleLeer` statt dreier Abfragen — dieselbe Aussage,
                    // und sie steht im geteilten `Startseitenmodell`.
                    Leerzustand(symbol: "tray", kopfzeile: "Hier ist noch nichts",
                                text: "Sobald der Server Titel hat, stehen sie hier.")
                        .padding(.top, 120)
                }
            }
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        // Derselbe stehende Titel wie auf Filme, Serien und Merkliste.
        .overlay(alignment: .top) {
            Bestandsleiste(titel: "Startseite", stand: kopfstand)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
            kopfstand.versatz = neu
        }
        // **Die milchige Leiste am oberen Rand.** macOS 26 legt sie von sich
        // aus über jede Scrollfläche — sie war nie in unserem Code, und
        // deshalb habe ich zweimal an der falschen Stelle gesucht. Über dem
        // Bild verlor sie sich, links auf blankem Grund stand sie als Balken.
        //
        // E4 wieder: was das Rahmenwerk ungefragt dazustellt, gehört ebenso
        // abgestellt wie das, was man selbst hinschreibt.
        .seitenscrollen()
        // Zwei Reihen in ihrer Form statt eines Rings — siehe GESTALTUNG G.
        .overlay(alignment: .topLeading) {
            if !geladen {
                VStack(alignment: .leading, spacing: Stil.reihenAbstand) {
                    Reihenplatzhalter(quer: true)
                    Reihenplatzhalter()
                }
                .padding(.horizontal, Stil.randAbstand)
                // Unter dem Titel, wie die Reihen, die er ersetzt.
                .padding(.top, Stil.inhaltOben + 33 + Stil.reihenAbstand)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(Stil.einblenden, value: geladen)
        .task { await laden() }
        // **Die Einstellung greift sofort, nicht beim nächsten Öffnen.**
        //
        // Umschalten ändert, welche Reihen es überhaupt gibt — und die stehen
        // erst nach einer neuen Abfrage fest. Ohne das sah man seine eigene
        // Einstellung erst beim nächsten Start und hielt sie für wirkungslos.
        .task(id: "\(model.neuzugangGetrennt)|\(model.genreChips)|\(model.startGenres.joined(separator: "|"))") {
            await auffrischen()
        }
        // **Der Kontowechsel hängt nicht an `phase`.**
        //
        // Naheliegend wäre gewesen, auf `model.phase` zu horchen. Der steht
        // beim Wechsel aber schon auf `.ready` und ändert sich nicht — die
        // Startseite lud nie neu und zeigte weiter die Titel des vorigen
        // Kontos. `.task` hilft ebenso wenig: die Ansicht bleibt stehen, sie
        // erscheint ja nicht neu. Der Zähler in `AppModel` ist das Einzige,
        // was sich zuverlässig ändert.
        //
        // Und es geht über `auffrischen()`, nicht über `laden()`: das würde
        // an `stand.geladen` abprallen. Geleert wird nichts — `Startseiten-
        // modell` ersetzt die Reihen selbst, sobald die neuen da sind.
        .onChange(of: model.kontowechsel) { _, _ in Task { await auffrischen() } }
        // **Auch beim Zurückkommen ins Fenster** (D8).
        //
        // `.task` deckt „Ansicht erscheint" ab — also den Leistenwechsel und
        // das Schliessen des Players. Nicht abgedeckt ist der Fall, für den
        // die Regel gemacht ist: am Fernseher zu Ende schauen und dann zum
        // Mac greifen. Dort stand die Folge sonst weiter in „Weiterschauen".
        //
        // Auf iOS ist das Gegenstück `scenePhase`; auf dem Mac ist
        // `didBecomeActiveNotification` das Genauere — `scenePhase` schlägt
        // dort auch um, wenn nur ein anderes Fenster derselben App nach vorn
        // kommt.
        //
        // Die Frist von 30 Sekunden steckt in `Auffrischung`, nicht hier.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            guard stand.brauchtAuffrischung else { return }
            Task { await auffrischen() }
        }
        // **Und beim Schliessen des Players** (D8) — die zweite Haelfte der
        // Regel, und sie fehlte.
        //
        // Der Kommentar oben behauptet, `.task` decke das ab, weil die
        // Ansicht dann wieder erscheine. Sie erscheint nicht: der Player
        // liegt auf dem Mac als `.overlay` ueber der **stehenbleibenden**
        // Startseite (`HauptView.swift:253-261`), und `schliessen()` setzt nur
        // `wunsch = nil`. Wer eine Folge zu Ende sah und den Player schloss,
        // sah in „Weiterschauen" weiter die alte Kachel mit dem alten Balken
        // — bis nach dreissig Sekunden Fensterwechsel oder einem
        // Kontowechsel. Genau der Fall, fuer den D8 gemacht ist.
        //
        // **Ohne Frist**, wie auf Linux (`Spieler.spielerSchliessen`): hier
        // ist gerade etwas geschehen, das den Stand aendert.
        //
        // **Nach der Endmeldung, nicht beim Zumachen.** Beim Zumachen ist sie
        // noch unterwegs; die Abfrage bekam den Stand des letzten Takts.
        // Siehe `AppModel.wiedergabeBeendet`.
        .onChange(of: model.seitenAuffrischen) { _, _ in Task { await auffrischen() } }
    }

    /// Eine feste Reihe — derselbe Aufbau wie vorher, nur einzeln abrufbar,
    /// damit die Reihenfolge aus den Einstellungen gilt.
    @ViewBuilder
    private func feste(_ reihe: Startreihe) -> some View {
        switch reihe {
        case .weiterschauen:
            if !weiter.isEmpty {
                Reihe(titel: "Weiterschauen", quer: true) {
                    ForEach(weiter, id: \.id) { titel in
                        Querkachel(titel: kopf(titel), zweitzeile: titel.kontextzeile,
                                   // **Fehlt das waagerechte Bild, tritt das
                                   // Plakat ein** — beschnitten, aber immer
                                   // noch das Cover und kein Standbild.
                                   // Wörtlich wie auf dem iPhone.
                                   bild: model.querbildURL(for: titel)
                                       ?? model.imageURL(for: titel, hochkant: true),
                                   fortschritt: fortschritt(titel),
                                   zeichen: zeichen(titel),
                                   auswahl: { steuerung.starte(titel) },
                                   uebersicht: { navigator.oeffne(.titel(titel), in: bereich) },
                                   vorholen: { Serienspeicher.geteilt.vorholen(titel, mit: model) })
                    }
                }
            }
        case .naechsteFolge:
            if !naechste.isEmpty {
                // **Hochkant, und der Klick führt auf die Seite.**
                //
                // Hier stand eine Querkachel, die sofort abspielte — beides
                // falsch, und beides ohne Grund, der mit Eingabe oder
                // Fenstergröße zu tun hätte.
                //
                // A2 im Register: „Nächste Folge **öffnet die Übersicht**,
                // sie startet nicht. Nur ‚Weiterschauen' springt direkt in
                // die Wiedergabe." Die iPhone-Fassung schreibt denselben Satz
                // an dieselbe Stelle. Waagerecht ist ebenfalls allein
                // „Weiterschauen" — iOS sagt es wörtlich, tvOS ruft die Reihe
                // mit `quer: false`.
                Reihe(titel: "Nächste Folge") {
                    ForEach(naechste, id: \.id) { folge in
                        Button { navigator.oeffne(.titel(folge), in: bereich) } label: {
                            Posterkachel(titel: kopf(folge),
                                         zweitzeile: folge.folgenkuerzel,
                                         bild: model.imageURL(for: folge, hochkant: true),
                                         zeichen: zeichen(folge),
                                         vorholen: { Serienspeicher.geteilt.vorholen(folge, mit: model) })
                        }
                        .buttonStyle(Stil.Druckknopf())
                    }
                }
            }
        // **Neue Filme und neue Serien einzeln**, damit man sie getrennt
        // schieben kann — wer Serien oben will und Filme unten, soll das
        // können. Welche es gibt, entscheidet „Neuzugänge getrennt".
        case .neueFilme:
            neuzugangsreihe(titel: "Zuletzt hinzugefügte Filme", stand.neueFilme)
        case .neueSerien:
            neuzugangsreihe(titel: "Zuletzt hinzugefügte Serien", stand.neueSerien)
        case .neuzugaenge:
            neuzugangsreihe(titel: "Zuletzt hinzugefügt", neu)
        }
    }

    @ViewBuilder
    private func neuzugangsreihe(titel: LocalizedStringKey, _ items: [Item]) -> some View {
        if !items.isEmpty {
            Reihe(titel: titel) {
                ForEach(items, id: \.id) { eintrag in
                    Button { navigator.oeffne(.titel(eintrag), in: bereich) } label: {
                        // **Der Serienname, nicht der Folgenname** — wie in
                        // `Kachel` auf dem iPhone. `Items/Latest` liefert
                        // Folgen, und dort stand dann der Folgentitel.
                        Posterkachel(titel: eintrag.seriesName ?? eintrag.name,
                                     zweitzeile: eintrag.neuzugangszeile,
                                     bild: model.imageURL(for: eintrag, hochkant: true),
                                     zeichen: zeichen(eintrag),
                                     vorholen: { Serienspeicher.geteilt.vorholen(eintrag, mit: model) })
                    }
                    .buttonStyle(Stil.Druckknopf())
                }
            }
        }
    }

    /// Deine Genres als Chips — dieselben, die sonst als Reihen stünden.
    /// Ecke wie ein Knopf, nicht rund: rund ist, was ein Bild ist.
    private var gattungschips: some View {
        // Feste Höhe, aus demselben Grund wie bei `Reihe`: eine waagerechte
        // `ScrollView` nimmt senkrecht, was der Stapel ihr zuteilt. 4 + 34 + 4.
        Blätterreihe(breiteJeStueck: 120, bildHoehe: 34) {
            ForEach(model.startGenres, id: \.self) { name in
                Button { navigator.oeffne(.gattung(name), in: bereich) } label: {
                    // Vom Server, also nicht übersetzt.
                    // Woertlich wie auf dem iPhone: 13 Medium, `flaeche`,
                    // durchgehende Ecke, **kein Rand**. 14 steht in keiner
                    // Leiter, und der Rand sagte ein zweites Mal, was die
                    // Flaeche schon sagt (BAUTEILE 9.25).
                    Text(verbatim: name)
                        .font(Stil.kachel)
                        .foregroundStyle(Stil.schrift)
                        // Genrenamen kommen vom Server. Der Chip hat eine
                        // feste Hoehe — ein umbrechender Name waere darin
                        // oben und unten abgeschnitten.
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Stil.flaeche,
                                    in: RoundedRectangle(cornerRadius: Stil.ecke,
                                                         style: .continuous))
                }
                .buttonStyle(Stil.Druckknopf())
            }
        }
        .frame(height: 42)
    }

    private func kopf(_ titel: Item) -> String {
        titel.seriesName ?? titel.name
    }

    /// **Aus `Item.gesehenerAnteil`** (`Sources/Shared/Titelangaben.swift`).
    ///
    /// Hier stand dieselbe Rechnung noch einmal. Ein Unterschied bestand:
    /// die geteilte Fassung gibt bei null Prozent `nil` zurück, diese gab
    /// `0.0`. Folgenlos, weil `Bildflaeche` den Balken ohnehin nur
    /// `if fortschritt > 0` zeichnet — beides führt zu keinem Balken.
    private func fortschritt(_ titel: Item) -> Double? { titel.gesehenerAnteil }

    /// Fernseher für alles, was zu einer Serie gehört, sonst Filmstreifen —
    /// dieselbe Unterscheidung wie in der iPhone-Fassung.
    private func zeichen(_ titel: Item) -> String { titel.seriesId != nil ? "tv" : "film" }

    private func laden() async {
        guard !stand.geladen else { return }
        await auffrischen()
    }

    /// Holt neu, ohne die Reihen vorher zu leeren — der alte Stand bleibt
    /// stehen, bis der neue da ist.
    private func auffrischen() async {
        // Das Vorholen der Serien stand hier und steht seit `9b0d58e` in
        // `Startseitenmodell.laden` — dort, wo die Reihen entstehen, also
        // bekommt es jede Plattform, statt dass drei es einzeln haben
        // müssen. `zuletzt` ist dabei; ohne die Zeile fiel der Normalfall
        // durch, weil `neueSerien` nur bei getrennten Reihen gefüllt ist.
        await stand.laden(model)
    }

}

/// Eine waagerechte Reihe mit Überschrift.
struct Reihe<Inhalt: View>: View {
    var titel: LocalizedStringKey = ""
    /// Statt `titel`, wenn die Überschrift vom Server kommt — ein Genre wird
    /// nicht übersetzt.
    var name: String? = nil
    /// Waagerechte Kacheln — nur „Weiterschauen".
    var quer = false
    @ViewBuilder let inhalt: Inhalt

    /// **Die Hoehe steht fest, sie wird nicht gemessen** — wörtlich die
    /// Rechnung aus `Reihe` auf dem iPhone.
    ///
    /// **Und das ist der Fehler, der dreimal auf einmal auftrat.**
    /// Eine waagerechte `ScrollView` ist senkrecht **flexibel**: sie nimmt,
    /// was ihr vorgeschlagen wird. In einem `VStack` in einer senkrechten
    /// `ScrollView` heisst das — sie bekommt einen *Anteil* der Fensterhöhe,
    /// und der hat mit der Kachel darin nichts zu tun. Eine `ScrollView`
    /// beschneidet ihren Inhalt: fiel der Anteil zu klein aus, fehlte die
    /// zweite Textzeile der Kachel und der ersten wurden die Unterlängen
    /// abgeschnitten; fiel er zu gross aus, klaffte unter der Reihe Luft, die
    /// mit der Kachelhöhe nichts zu tun hatte — bei „Weiterschauen" am
    /// deutlichsten, weil dort die flachen Querkacheln stehen.
    ///
    /// Titelzeile (20 Punkt, rund 24 Zeilenhöhe) · 12 Abstand · 4 (der
    /// senkrechte Rand der Blätterreihe) · Bildhöhe · 8 Abstand · Textblock
    /// (13 und 12 Punkt mit 1 dazwischen, rund 32) · 4.
    private var reihenhoehe: CGFloat {
        let bild = quer ? Stil.querHoehe : Stil.kachelHoehe
        return 24 + 12 + 4 + bild + 8 + 32 + 4
    }

    var body: some View {
        // 12, nicht 11: dieselbe Rolle traegt auf der Detailseite 12.
        VStack(alignment: .leading, spacing: 12) {
            // Der geteilte `Reihentitel` setzt keinen Rand — `randAbstand`
            // gibt es auf tvOS nicht, also gehört er zum Aufrufer. Auch die
            // Breite: ohne sie rutscht der Titel in die Mitte.
            Reihentitel(text: titel, name: name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Stil.randAbstand)
            // **Jede Reihe mit ihrem eigenen Maß.** Vorher rechnete auch die
            // Posterreihe mit der Querbreite — dann blättert sie zu weit —
            // und die Pfeile standen auf der Höhe einer Querkachel.
            Blätterreihe(breiteJeStueck: (quer ? Stil.querBreite : Stil.kachelBreite)
                            + Stil.kachelAbstand,
                         bildHoehe: quer ? Stil.querHoehe : Stil.kachelHoehe) { inhalt }
        }
        // Oben ausgerichtet, damit eine Kachel ohne Unterzeile nicht in der
        // Mitte hängt.
        .frame(height: reihenhoehe, alignment: .top)
    }
}

