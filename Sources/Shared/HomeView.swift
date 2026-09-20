import JellyfinKit
import SwiftUI

/// Die Startseite. Reihen mit Hochkant-Postern — was angefangen ist, zuerst.
struct HomeView: View {
    let model: AppModel

    @Environment(\.breit) private var breit
    @Environment(\.fensterknoepfe) private var fensterknoepfe
    @Environment(\.scenePhase) private var lebenslage

    /// Laden und Reihenfolge stehen in `Startseitenmodell` — geteilt mit
    /// der tvOS-Fassung.
    @State private var stand = Startseitenmodell()
    @State private var abspielen: Abspielwunsch?
    @State private var bereitet = false
    /// Keine der Anfragen kam durch.
    @State private var laedtNeu = false
    /// Wie weit die Seite gescrollt ist — **nur für den Farbschein und den
    /// Kopfverlauf.** Siehe ``Farbschein``.
    @State private var weg = Scrollweg()

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            inhalt
                // Der Wechsel zieht die Scrollflaeche heran — die Kopfzeile
                // darueber liegt fest, siehe `bereichsinhalt()`.
                // **Der Farbschein reist als Unterlage mit**, hinter dem
                // Inhalt und vor dem Grund. Siehe ``Farbschein``.
                .bereichsinhalt {
                    if breit {
                        FarbscheinBreit(weg: weg)
                    } else {
                        Farbschein(weg: weg, fenster: .hinterDemInhalt)
                    }
                }
                // Unter dem Kopf und unter der Uebernahmeauswahl, ueber dem
                // Inhalt — siehe `bereichsleiste()`.
                .bereichsleiste()

            kopf

            // **`alleLeer`, nicht drei eigene Abfragen.** Hier standen
            // Weiterschauen, Nächste Folge und die gemeinsame Neuzugangsreihe
            // — und nicht die getrennten Reihen „Neue Filme" und „Neue
            // Serien". Wer „Neuzugänge getrennt" an hat und nichts angefangen
            // hat, bekam deshalb „Hier ist noch nichts" **über** eine volle
            // Startseite gelegt: `zuletzt` ist dann immer leer, weil die
            // Titel in den getrennten Reihen stehen. Mac und Fernseher fragen
            // seit jeher `alleLeer`; nur hier stand die ältere Abschrift.
            if stand.geladen, stand.alleLeer {
                // Das Wann zum Wie aus `Leerzustand`: ohne animiertes
                // Einfuegen bleibt die `.transition` dort wirkungslos.
                nichtsDa
                    .animation(Stil.einblenden, value: stand.geladen)
            }
        }
        // **Nach dem Zusehen neu holen, ohne Frist.**
        //
        // Wer aus dem Player zurückkommt, hat die Stelle gerade verschoben —
        // „Weiterschauen" ist damit sicher veraltet, und die Folge ist unter
        // Umständen zu Ende und gehört gar nicht mehr in die Reihe.
        // **Die Einstellung greift sofort, nicht beim naechsten Ziehen.**
        //
        // Umschalten aendert, welche Reihen es ueberhaupt gibt — und die
        // stehen erst nach einer neuen Abfrage fest. Ohne das sah man seine
        // eigene Einstellung erst, wenn man die Seite von Hand nachlud, und
        // hielt sie fuer wirkungslos.
        .task(id: "\(model.neuzugangGetrennt)|\(model.genreChips)|\(model.startGenres.joined(separator: "|"))") {
            await laden()
        }
        // **Nicht an `phase` haengen.** Die steht beim Kontowechsel schon auf
        // `.ready` und aendert sich nicht — die Startseite lud nie neu und
        // zeigte die Titel des vorigen Kontos. Auf tvOS ist genau das bei
        // `kontowechsel` ist der Zaehler, der dafuer da ist.
        .onChange(of: model.kontowechsel) { _, _ in Task { await laden() } }
        // Neu geholt wird nach der Endmeldung, nicht beim Zumachen: beim
        // Zumachen ist sie noch unterwegs (`AppModel.wiedergabeBeendet`).
        .onChange(of: model.seitenAuffrischen) { _, _ in Task { await laden() } }
        .playerCover(item: $abspielen) { wunsch in
            PlayerScreen(model: model, item: wunsch.item,
                         plan: wunsch.plan, startAt: wunsch.startAt)
        }
        .task { if !stand.geladen { await laden() } }
    }

    /// Wortmarke links, Profilbild rechts.
    ///
    /// Der Inhalt läuft beim Scrollen sichtbar darunter durch, statt an einer
    /// harten schwarzen Kante abzuschneiden. Die Lupe ist weg — Suchen ist
    /// jetzt ein eigener Bereich in der Leiste unten.
    @ViewBuilder private var kopf: some View {
        if breit {
            // **Kein Verlauf.** Er trägt auf dem iPhone die Kopfzeile, die
            // oben liegt — hier liegt die Leiste links, und über dem Inhalt
            // ist nichts, worunter er durchlaufen müsste. Ein Verlauf ohne
            // Kopfzeile ist Zierde, und die hat diese Gestaltung nicht.
            EmptyView()
        } else {
            kopfzeile
        }
    }

    private var kopfzeile: some View {
        // **Der Farbschein haengt am Kopf, nicht an der Seite.** Siehe
        // ``Farbschein``: nur dort liegt er ueber `Kopfverlauf` statt
        // darunter. `kopfzeile` gibt es ohnehin nur schmal.
        // **Der Verlauf zieht erst beim Scrollen auf.** Im Ruhezustand liegt
        // unter dem Kopf noch kein Inhalt — dort deckt er nichts ab und nimmt
        // dem Farbschein nur die obere Kante weg, die seine kraeftigste ist.
        Kopfleser(weg: weg) {
            HStack(alignment: .center, spacing: 0) {
                Wortmarke(hoehe: 30)
                Spacer(minLength: 0)

                // **Drei Zeichen, eine Sprache.**
                //
                // Das Angebot war ein Kreis mit Flaeche und Rand — richtig,
                // solange es allein neben dem Profilbild stand: es ist ein
                // Angebot, keine dauerhafte Schaltflaeche, und sollte
                // auffallen. Sobald die Merkliste dazukam, las sich derselbe
                // Kreis neben einem nackten Zeichen wie zwei verschiedene
                // Arten von Knopf.
                //
                // Was es heraushebt, ist jetzt nicht die **Form**, sondern
                // die **Farbe** — und das ist ohnehin unsere Regel: der
                // Akzent traegt Zustand, keine Flaechen.
                //
                // **Das Angebot steht nicht mehr hier**, sondern in
                // `Kopfziele` selbst: es gehoert zu Merkliste und Profil und
                // damit auf jede Wurzelseite, nicht nur auf diese.
                Kopfziele(name: model.session?.userName ?? "?",
                          bild: model.benutzerbildURL())
            }
            .foregroundStyle(Stil.schrift)
        }
    }

    /// Statt eines leeren schwarzen Bildschirms: sagen, was los ist, und einen
    /// Weg zurück anbieten.
    ///
    /// Der Text nennt die Serveradresse. Das ist der eigentliche Gewinn — daran
    /// erkennt man auf einen Blick, ob der Server aus ist oder man im falschen
    /// Netz steckt. Vorher stand da nur, dass etwas nicht ging.
    @ViewBuilder private var nichtsDa: some View {
        if stand.gestoert {
            Leerzustand(
                symbol: "externaldrive.badge.xmark",
                kopfzeile: "Kein Kontakt zum Server",
                text: "\(model.serverAdresse ?? String(localized: "Der Server")) hat nicht geantwortet. Läuft der Server, und bist du im selben Netz?",
                laedt: laedtNeu,
                hauptknopf: laedtNeu ? nil : ("Erneut versuchen", { neuVersuchen() }),
                stillerKnopf: laedtNeu ? nil : ("Server wechseln", { model.signOut() }))
        } else {
            Leerzustand(
                symbol: "tray",
                kopfzeile: "Hier ist noch nichts",
                text: "Sobald in Jellyfin etwas liegt, taucht es hier auf.",
                stillerKnopf: ("Aktualisieren", { neuVersuchen() }))
        }
    }

    private func neuVersuchen() {
        laedtNeu = true
        Task {
            await laden()
            laedtNeu = false
        }
    }

    private var inhalt: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Stil.reihenAbstand) {
                // **Die Reihen stehen schon, bevor sie Inhalt haben.** Statt
                // eines Rings mitten auf der Seite: zwei Reihen in ihrer
                // Form, die überblenden, sobald die Titel da sind. Man sieht
                // sofort, was für eine Seite das wird.
                if !stand.geladen {
                    Reihenplatzhalter(quer: true)
                    Reihenplatzhalter()
                }
                // **Genres als Chips, ganz oben** — wenn eingeschaltet. Ein
                // Einstieg, kein Inhalt: ein Tipp öffnet das Genre.
                if model.genreChips, !model.startGenres.isEmpty { gattungschips }
                // **Die festen Reihen in der eingestellten Reihenfolge**, ohne
                // die ausgeblendeten — Einstellungen → Darstellung → Startseite.
                ForEach(model.startReihen.filter {
                    !model.startAus.contains($0) && $0.passt(getrennt: model.neuzugangGetrennt)
                }) { reihe in
                    feste(reihe)
                }
                // Die gewählten Genres als eigene Reihen, nach den festen.
                ForEach(stand.gattungsreihen) { r in
                    Reihe(model: model, titel: "", name: r.name, items: r.items,
                          nachGesehen: { await laden() })
                }
                // Die Reihe „Bibliotheken" ist entfallen — Filme und Serien
                // stehen jetzt in der Leiste unten.
            }
            .padding(.top, 8)
        }
        .animation(Stil.einblenden, value: stand.geladen)
        .scrollIndicators(.hidden)
        // Oben unter dem unscharfen Kopf durch, unten über der Leiste enden.
        //
        // Breit gibt es unten keine Leiste — die steht links. Der Platz, den
        // `leisteHoehe` freihält, wäre dort ein leerer Streifen.
        .contentMargins(.top, (breit ? Stil.kopfOben + 20 : 58)
                        + (fensterknoepfe ? Fensterknoepfe.hoehe : 0),
                        for: .scrollContent)
        .contentMargins(.bottom, breit ? 24 : Stil.leisteHoehe + 12,
                        for: .scrollContent)
        // Null im Ruhezustand: `contentOffset` startet bei minus dem oberen
        // Einzug, und was hier gebraucht wird, ist der zurueckgelegte Weg.
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.contentOffset.y + $0.contentInsets.top
        } action: { _, neu in
            // **Nicht jedes Bild, und nicht ueber 240.** Der Versatz stand als
            // `@State` in dieser Ansicht; jeder Scrollschritt baute damit die
            // ganze Scrollflaeche samt `refreshable` und `contentMargins` neu,
            // und unter iOS 18 lief die Seite dabei auf und ab. Jetzt lesen ihn
            // nur Farbschein und Kopf, und oberhalb von 240 aendert sich an
            // beiden sichtbar nichts mehr.
            let wert = min(max(neu, 0), 240)
            if abs(wert - weg.wert) >= 0.5 { weg.wert = wert }
        }
        .refreshable { await laden() }
    }

    /// Aus den Fortsetzen-Reihen direkt in die Folge, ohne Zwischenseite.
    private func starte(_ item: Item) {
        guard !bereitet else { return }
        bereitet = true
        Task {
            defer { bereitet = false }
            // Frisch holen: die Position im Listeneintrag ist oft veraltet.
            let aktuell = await model.item(id: item.id) ?? item
            guard let plan = await model.plan(for: aktuell.id) else { return }
            abspielen = Abspielwunsch(item: aktuell, plan: plan,
                                      startAt: aktuell.fortsetzenAb ?? 0)
        }
    }

    /// Eine feste Reihe — derselbe Aufbau wie vorher, nur einzeln abrufbar,
    /// damit die Reihenfolge aus den Einstellungen gilt.
    @ViewBuilder
    private func feste(_ reihe: Startreihe) -> some View {
        switch reihe {
        case .weiterschauen:
            if !stand.weiterschauen.isEmpty {
                Reihe(model: model, titel: "Weiterschauen",
                      items: stand.weiterschauen, quer: true, direkt: starte,
                      nachGesehen: { await laden() })
            }
        case .naechsteFolge:
            if !stand.naechsteFolge.isEmpty {
                // Ohne 'direkt': eine noch nicht angefangene Folge will
                // man erst ansehen, nicht sofort starten. Nur
                // 'Weiterschauen' springt direkt in die Wiedergabe.
                Reihe(model: model, titel: "Nächste Folge", items: stand.naechsteFolge,
                      nachGesehen: { await laden() })
            }
        // Hier führt der Tipp auf die Seite: was man noch nicht
        // angefangen hat, will man erst ansehen.
        case .neueFilme:
            if !stand.neueFilme.isEmpty {
                Reihe(model: model, titel: "Zuletzt hinzugefügte Filme",
                      items: stand.neueFilme, neuzugang: true,
                      nachGesehen: { await laden() })
            }
        case .neueSerien:
            if !stand.neueSerien.isEmpty {
                Reihe(model: model, titel: "Zuletzt hinzugefügte Serien",
                      items: stand.neueSerien, neuzugang: true,
                      nachGesehen: { await laden() })
            }
        case .neuzugaenge:
            if !stand.zuletzt.isEmpty {
                Reihe(model: model, titel: "Zuletzt hinzugefügt",
                      items: stand.zuletzt, neuzugang: true,
                      nachGesehen: { await laden() })
            }
        }
    }

    /// Deine Genres als Chips — dieselben, die sonst als Reihen stünden.
    /// Ecke wie ein Knopf, nicht rund: rund ist, was ein Bild ist.
    private var gattungschips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.startGenres, id: \.self) { name in
                    NavigationLink(value: GenreRoute(name: name)) {
                        // Vom Server, also nicht übersetzt.
                        Text(verbatim: name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Stil.schrift)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.ecke))
                            .overlay(RoundedRectangle(cornerRadius: Stil.ecke).strokeBorder(Stil.rand))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
        }
    }

    private func laden() async { await stand.laden(model) }
}

/// Eine waagerecht scrollende Reihe.
private struct Reihe: View {
    @Environment(\.breit) private var breit
    let model: AppModel
    let titel: LocalizedStringKey
    /// Statt `titel`, wenn die Überschrift vom Server kommt — ein Genre wird
    /// nicht übersetzt.
    var name: String? = nil
    let items: [Item]
    /// Waagerechte Kacheln statt hochkant — nur für „Weiterschauen".
    var quer = false
    /// Zeigt statt der Folgennummer, *was* neu dazugekommen ist.
    var neuzugang = false
    /// Gesetzt heißt: Tippen startet sofort, statt auf die Seite zu führen.
    var direkt: ((Item) -> Void)? = nil
    /// Wird nach „gesehen/ungesehen" gerufen, damit die Startseite nachzieht.
    var nachGesehen: (() async -> Void)? = nil

    /// Gesehen-Zustand setzen und die Startseite nachziehen.
    ///
    /// **Neu laden, nicht nur die Kachel ändern.** „Weiterschauen" und
    /// „Als Nächstes" hängen beide am Fortschritt: eine als gesehen markierte
    /// Folge verschwindet aus der einen Reihe und die nächste erscheint in
    /// der anderen. Nur die Kachel umzufärben ließe die Reihen falsch stehen.
    private func gesehenSetzen(_ item: Item, an: Bool) {
        Task {
            if let fehler = await model.setzeGesehen(item, an: an) {
                model.errorMessage = fehler
                return
            }
            await nachGesehen?()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // **Derselbe Rand wie die Kacheln darunter.** Der Baustein setzt
            // seit dem Herausloesen keinen eigenen mehr — auf tvOS gibt es
            // `randAbstand` nicht. Er muss hier `rand(breit:)` lesen, sonst
            // steht die Ueberschrift auf dem iPad schmaler als ihre Reihe.
            Group {
                if let name {
                    Text(verbatim: name)
                        .font(Stil.reihe)
                        .tracking(-0.3)
                        .foregroundStyle(Stil.schrift)
                } else {
                    Reihentitel(text: titel)
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))

            ScrollView(.horizontal, showsIndicators: false) {
                // Oben ausrichten: ohne das zentriert der Stapel, und eine
                // Kachel mit nur einer Textzeile — ein Film ohne Folgenkürzel
                // — sitzt tiefer als die Serien daneben.
                HStack(alignment: .top, spacing: Stil.kachelAbstand) {
                    ForEach(items) { item in
                        if let direkt {
                            Button { direkt(item) } label: {
                                Kachel(model: model, item: item, quer: quer, neuzugang: neuzugang)
                            }
                            .buttonStyle(.plain)
                            // Zur Serie kommt man weiterhin — nur nicht mehr
                            // im Weg der Wiedergabe.
                            .contextMenu {
                                NavigationLink(value: item) {
                                    Label("Zur Übersicht", systemImage: "info.circle")
                                }
                                // **Beide Eintraege immer, nicht der passende.**
                                //
                                // Erst stand hier nur der, der gerade zutraf.
                                // Das ging an einem Fall vorbei: eine Folge,
                                // durch die man nur durchgesprungen ist, gilt
                                // als angefangen — „ungesehen" setzt sie
                                // zurueck und holt sie aus „Weiterschauen".
                                // Wer das will, findet sonst nichts.
                                //
                                // Ein Umschalter mit Haeckchen waere die
                                // dritte Moeglichkeit und die schlechteste:
                                // er liest sich wie eine Anzeige, und man
                                // weiss vor dem Druecken nicht, was passiert.
                                Button {
                                    gesehenSetzen(item, an: true)
                                } label: {
                                    Label("Als gesehen markieren",
                                          systemImage: "checkmark.circle")
                                }
                                Button {
                                    gesehenSetzen(item, an: false)
                                } label: {
                                    Label("Als ungesehen markieren",
                                          systemImage: "eye.slash")
                                }
                            }
                        } else {
                            NavigationLink(value: item) {
                                Kachel(model: model, item: item, quer: quer, neuzugang: neuzugang)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
            }
        }
    }
}

private struct Kachel: View {
    @Environment(\.breit) private var breit
    let model: AppModel
    let item: Item
    var quer = false
    var neuzugang = false

    /// Waagerecht 16:9, so breit wie zwei Poster nebeneinander — sonst wirkt
    /// die Reihe leer.
    private var breite: CGFloat {
        quer ? Stil.reihenQuerBreite(breit: breit) : Stil.reihenBreite(breit: breit)
    }
    private var hoehe: CGFloat {
        quer ? Stil.reihenQuerHoehe(breit: breit) : Stil.reihenHoehe(breit: breit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Bild(url: quer ? model.querbildURL(for: item)
                           : model.imageURL(for: item, maxHeight: 500, hochkant: true),
                 breite: breite, hoehe: hoehe, ecke: Stil.eckeKachel,
                 fortschritt: fortschritt) {
                // Fehlt dem Titel ein waagerechtes Bild, tritt das Poster ein
                // — beschnitten, aber immer noch das Cover und kein Standbild.
                Bild(url: model.imageURL(for: item, maxHeight: 500, hochkant: true),
                     breite: breite, hoehe: hoehe, ecke: Stil.eckeKachel) {
                    // **Und wenn auch das fehlt, ein Zeichen statt Leere.**
                    //
                    // Eine leere Flaeche sieht aus wie ein Fehler in der App,
                    // und genau so wurde sie gemeldet. Ein Zeichen sagt: hier
                    // gehoert ein Bild hin, der Server hat keins.
                    Stil.flaeche.overlay {
                        Image(systemName: item.seriesId != nil ? "tv" : "film")
                            .font(.system(size: 22))
                            .foregroundStyle(Stil.schriftSehrLeise)
                    }
                }
            }
            #if DEBUG
            // Nur im Debug-Bau: in der ausgelieferten Fassung waere das eine
            // gebaute Adresse je Kachel, fuer nichts.
            .onAppear {
                guard quer, model.querbildURL(for: item) == nil else { return }
                Protokoll.schreib("[Bild] \(item.seriesName ?? item.name): kein Querbild — "
                    + "eigen=\(item.imageTags?.keys.sorted().joined(separator: ",") ?? "-") "
                    + "Serienposter=\(item.seriesPrimaryImageTag != nil) "
                    + "Serienhintergrund=\(item.parentBackdropImageTags?.count ?? 0) "
                    + "Serienvorschau=\(item.parentThumbImageTag != nil)")
            }
            #endif

            VStack(alignment: .leading, spacing: 1) {
                Text(item.seriesName ?? item.name)
                    .font(Stil.kachel)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                if let kuerzel = neuzugang ? item.neuzugangszeile : item.folgenkuerzel {
                    Text(kuerzel)
                        .font(Stil.klein)
                        .foregroundStyle(Stil.schriftLeise)
                }
            }
            .frame(width: breite, alignment: .leading)
        }
        // Eine Aussage je Kachel statt dreier Bruchstücke — und der
        // Fortschritt kommt mit. Er ist eine Zeichnung im Bild und fiel für
        // VoiceOver bisher ganz heraus; der tvOS-Chat hat es dort gefunden
        // und uns geprüft. Erst ab einem Prozent: „null Prozent gesehen" ist
        // keine Auskunft.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.trefferauskunft.isEmpty
                                 ? item.name
                                 : "\(item.seriesName ?? item.name), \(item.trefferauskunft)"))
        .accessibilityValue(fortschritt.map {
            Text("\(Int($0 * 100)) Prozent gesehen")
        } ?? Text(""))
    }

    private var fortschritt: Double? {
        guard let prozent = item.userData?.playedPercentage, prozent > 0 else { return nil }
        return prozent / 100
    }
}

/// **Der Farbschein über der Kopfzeile — ein Versuch auf Widerruf.**
///
/// Er kommt von der Webseite, wo hinter der Schlagzeile ein türkiser und
/// ein blauer Schein stehen. Dort ist das eine ausdrücklich notierte
/// Abweichung von `GESTALTUNG.md` („Flächen sind flach").
///
/// **Wenn er wieder rausgeht**, sind es vier Stellen: diese Struktur, das
/// `{ … Farbschein … }` am `bereichsinhalt()`, das `verlaufStaerke:` am
/// `Unschaerfekopf` und `versatz` samt seinem `onScrollGeometryChange`.
/// Die Überladungen in `Stil.swift` können stehen bleiben oder mitgehen —
/// ohne Aufrufer verhalten sie sich wie vorher.
///
/// **Vier Anläufe, alle an derselben Frage: welche Lage.** Der Reihe nach,
/// damit es niemand noch einmal durchprobiert:
///
/// 1. *Über dem Inhalt.* Dann liegt er über Schrift und Plakaten, und beim
///    Scrollen wandert das Bild unter einem farbigen Fleck durch.
/// 2. *Hinter der Scrollfläche.* Sauber gegenüber dem Inhalt — aber
///    `Kopfverlauf` deckt oben mit 0,98, also war die obere Kante schwarz,
///    an der der Schein am kräftigsten sein müsste.
/// 3. *Über dem Verlauf, unter dem Kopfinhalt.* Obere Kante endlich farbig,
///    dafür liegt er wieder über allem, was beim Scrollen unter dem Kopf
///    durchläuft — die Reihenüberschrift bekam beim Hochwischen einen
///    Farbstich.
/// 4. **Hinter der Scrollfläche, und der Verlauf zieht erst beim Scrollen
///    auf.** Das ist es.
///
/// Der vierte Anlauf ist keine Abwägung, sondern eine Beobachtung: **im
/// Ruhezustand liegt unter dem Kopf gar kein Inhalt.** Die Scrollfläche
/// beginnt bei 117 Punkt, der Kopf endet bei 101. Der Verlauf deckt dort
/// nichts ab — er ist erst nötig, wenn wirklich etwas darunter durchläuft.
/// Also zieht er mit dem Scrollen auf, und der Schein geht im selben Zug.
///
/// **Und er wird in zwei Fenstern gezeichnet, nicht in einem.** Das ist der
/// fuenfte Anlauf und der Grund, warum er ueberhaupt noch einen brauchte:
/// hinter dem Inhalt allein zog der Kopfverlauf beim Scrollen darueber auf
/// und fraß ihn genau dort auf, wo er noch stand — von aussen sieht das aus
/// wie Ausblenden, obwohl er faehrt.
///
/// Also oben, ueber dem Verlauf, die ersten 118 Punkt des **Schirms**; und
/// darunter, hinter dem Inhalt, der Rest. Beide zeichnen dasselbe an
/// derselben Stelle, deshalb ist die Naht nicht zu sehen. Die Fenster stehen
/// fest, die Farbe faehrt darunter durch: eins zu eins mit dem Inhalt, ohne
/// Ausblenden, nach 165 Punkten oben hinaus.
private struct Farbschein: View {
    /// Welcher Ausschnitt des Schirms gezeichnet wird. Siehe oben.
    enum Fenster { case ueberDemVerlauf, hinterDemInhalt }

    /// Der zurückgelegte Scrollweg, 0 im Ruhezustand.
    let weg: Scrollweg
    let fenster: Fenster

    /// So weit reicht `Kopfverlauf` (Kopf 101 + Zugabe 17). **Dieselbe Zahl
    /// wie dort** — geht sie dort hoch, gehört sie hier mit.
    private let kopfhoehe: CGFloat = 118

    /// Reicht bis unter die erste Reihenüberschrift.
    private let hoehe: CGFloat = 165

    var body: some View {
        // **Das Fenster steht fest auf dem Schirm, die Farbe fährt darunter
        // durch.** Nur so bleiben beide Hälften aneinander: teilte sich der
        // Schein an einer mitwandernden Kante, schoebe sich die untere
        // Haelfte unter den Verlauf und wuerde von unten aufgefressen.
        switch fenster {
        case .ueberDemVerlauf:
            gemalt
                .frame(height: kopfhoehe, alignment: .top)
                .clipped()
                .drumherum()
        case .hinterDemInhalt:
            gemalt
                .frame(maxHeight: .infinity, alignment: .top)
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: kopfhoehe)
                        Color.white
                    }
                }
                .drumherum()
        }
    }

    /// Zwei weichgezeichnete Kreise mit Ausklang nach unten — beide Fenster
    /// zeichnen **dasselbe**, an derselben Stelle. Deshalb ist die Naht
    /// zwischen ihnen nicht zu sehen.
    private var gemalt: some View {
        ZStack(alignment: .top) {
            // Die Mitten liegen auf der Oberkante des Schirms: dort ist der
            // Schein am kräftigsten, und nach unten läuft er von selbst aus.
            Circle()
                .fill(Stil.akzent)
                .frame(width: 320, height: 320)
                .opacity(0.28)
                .offset(x: -110, y: -160)
            Circle()
                .fill(Stil.kuehl)
                .frame(width: 340, height: 340)
                .opacity(0.24)
                .offset(x: 130, y: -180)
        }
        .blur(radius: 60)
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: hoehe, alignment: .top)
        .mask(alignment: .top) {
            LinearGradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .white.opacity(0.94), location: 0.34),
                .init(color: .white.opacity(0.72), location: 0.58),
                .init(color: .white.opacity(0.34), location: 0.80),
                .init(color: .white.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: hoehe)
        }
        // **Er fährt mit, und sonst nichts.** Eins zu eins mit dem Inhalt,
        // ohne Ausblenden: er verhält sich wie das oberste Stück der Seite.
        .offset(y: -weg.wert)
    }
}

private extension View {
    /// Was beide Fenster gleich brauchen.
    func drumherum() -> some View {
        ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// **Der Farbschein auf iPad und Mac — eine Lage, kein Fenster.**
///
/// Auf dem iPhone wird er in zwei Fenstern gezeichnet, weil `Kopfverlauf`
/// oben mit 0,98 deckt und ihn sonst verschluckt. Breit gibt es diesen
/// Verlauf nicht: dort steht kein Kopf über dem Inhalt.
///
/// **Und genau daran ist der erste Versuch gescheitert.** Die schmale
/// Fassung lässt die oberen 118 Punkt frei — dort zeichnet das andere
/// Fenster. Breit gibt es dieses andere Fenster nicht, also fehlte der
/// Streifen: der Schein begann erst unter dem freien Rand, und zwischen
/// Oberkante und Farbe stand eine Lücke.
///
/// **Kein Kreispaar, sondern ein Verlauf über die ganze Breite.** Auf dem
/// iPhone sind es zwei Kreise, und die überlappen sich dort, weil 390 Punkt
/// schmaler sind als die Kreise selbst. Auf über 900 Punkt tun sie das nicht
/// mehr: dann steht links Türkis, rechts Blau und dazwischen ein dunkles
/// Loch. Zwei Anläufe sind genau daran gescheitert — erst zu klein und in
/// der Mitte, dann an den Kanten und in der Mitte hohl.
///
/// Ein Verlauf von Kante zu Kante hat dieses Problem nicht: er ist
/// durchgehend, weil er aus einem Stück ist, und er passt sich jeder
/// Fensterbreite von selbst an. Schräg statt waagerecht, damit er nicht wie
/// ein Balken liest.
///
/// Er ist leiser als auf dem iPhone — 0,20 gegen 0,28. Dieselbe Farbe auf
/// der zweieinhalbfachen Fläche ist nicht dieselbe Menge Farbe.
private struct FarbscheinBreit: View {
    let weg: Scrollweg

    /// Endet über der ersten Reihenüberschrift. Die Scrollfläche beginnt
    /// breit bei `Stil.kopfOben + 20`, also bei 46.
    private let hoehe: CGFloat = 170

    var body: some View {
        LinearGradient(stops: [
            .init(color: Stil.akzent.opacity(0.22), location: 0),
            .init(color: Stil.akzent.opacity(0.17), location: 0.26),
            // Die Mitte ist die Stelle, an der die beiden Kreise ein Loch
            // liessen — hier traegt sie die Mischung aus beiden.
            .init(color: Stil.scheinMitte.opacity(0.15), location: 0.52),
            .init(color: Stil.kuehl.opacity(0.17), location: 0.76),
            .init(color: Stil.kuehl.opacity(0.20), location: 1),
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: hoehe, alignment: .top)
        .mask(alignment: .top) {
            LinearGradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .white.opacity(0.92), location: 0.34),
                .init(color: .white.opacity(0.66), location: 0.58),
                .init(color: .white.opacity(0.28), location: 0.80),
                .init(color: .white.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: hoehe)
        }
        .ignoresSafeArea(edges: .top)
        .offset(y: -weg.wert)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}


/// **Wie weit die Startseite gescrollt ist — ausserhalb der Seite.**
///
/// Als `@State` in `HomeView` machte jeder Scrollschritt die ganze Seite neu.
/// Als beobachtetes Objekt werden nur die Ansichten neu gebaut, die `wert`
/// tatsaechlich lesen: Farbschein und Kopf.
@Observable
final class Scrollweg {
    var wert: CGFloat = 0

    /// **Nur schreiben, wenn es jemand sieht.** Der Detailkopf aendert sich
    /// zwischen 150 und 220 Punkt; darueber hinaus und bei Bruchteilen eines
    /// Punkts bleibt der Wert stehen, und niemand wird neu gebaut. Die Grenzen
    /// selbst werden immer erreicht, damit der Kopf nie halb stehen bleibt.
    func setzen(_ neu: CGFloat, bis: CGFloat = 240) {
        let geklemmt = min(max(neu, 0), bis)
        guard geklemmt != wert else { return }
        if abs(geklemmt - wert) >= 0.5 || geklemmt == 0 || geklemmt == bis {
            wert = geklemmt
        }
    }
}

/// Der Detailkopf, der den Scrollweg selbst liest — damit nicht die ganze
/// Film- oder Serienseite es tut.
struct Detailkopfleser: View {
    let titel: String
    let weg: Scrollweg
    let zurueck: () -> Void

    var body: some View {
        Detailkopf(titel: titel, versatz: weg.wert, zurueck: zurueck)
    }
}

/// Der Kopf der Startseite, der den Scrollweg selbst liest — damit nicht
/// `HomeView` es tut.
private struct Kopfleser<Inhalt: View>: View {
    let weg: Scrollweg
    @ViewBuilder var inhalt: () -> Inhalt

    var body: some View {
        Unschaerfekopf(verlaufStaerke: min(Double(weg.wert) / 40, 1),
                       lage: AnyView(Farbschein(weg: weg, fenster: .ueberDemVerlauf)),
                       inhalt: inhalt)
    }
}
