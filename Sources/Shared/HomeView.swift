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
    /// Läuft auf einem anderen Gerät etwas? Siehe ``Uebernahmemodell``.
    @State private var uebernahme = Uebernahmemodell()
    /// Bei mehr als einem Gerät wird gefragt statt geraten.
    @State private var auswahlOffen = false

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            inhalt
                // Der Wechsel zieht die Scrollflaeche heran — die Kopfzeile
                // darueber liegt fest, siehe `bereichsinhalt()`.
                .bereichsinhalt()
                // Unter dem Kopf und unter der Uebernahmeauswahl, ueber dem
                // Inhalt — siehe `bereichsleiste()`.
                .bereichsleiste()

            // **Ein Versuch, und er steht bewusst allein.** Siehe
            // ``Farbschein``: eine Struktur, ein Aufruf, eine Zeile weniger,
            // wenn er wieder rausgeht. Er steht **über** dem Inhalt, weil
            // `bereichsinhalt()` einen deckenden Grund hinter die
            // Scrollflaeche legt — darunter waere er unsichtbar.
            if !breit { Farbschein() }

            kopf

            if stand.geladen, stand.weiterschauen.isEmpty,
               stand.naechsteFolge.isEmpty, stand.zuletzt.isEmpty {
                // Das Wann zum Wie aus `Leerzustand`: ohne animiertes
                // Einfuegen bleibt die `.transition` dort wirkungslos.
                nichtsDa
                    .animation(Stil.einblenden, value: stand.geladen)
            }

            // **Eigenes Blatt statt `confirmationDialog`.**
            //
            // Der Systemdialog legt seinen eigenen, sehr hellen Schleier auf;
            // ueber einer dunklen Startseite voller Plakate hebt er sich kaum
            // ab. Mit einem eigenen Blatt ist der Schleier unsere Entscheidung
            // — und es sieht aus wie das auf dem Fernseher.
            if auswahlOffen {
                Uebernahmeauswahl(sitzungen: uebernahme.angebote,
                                  waehlen: { hierWeiterschauen($0) },
                                  abbrechen: { auswahlOffen = false })
                    .transition(.opacity)
                    .zIndex(5)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: auswahlOffen)
        // **Nach dem Zusehen neu holen, ohne Frist.**
        //
        // Wer aus dem Player zurückkommt, hat die Stelle gerade verschoben —
        // „Weiterschauen" ist damit sicher veraltet, und die Folge ist unter
        // Umständen zu Ende und gehört gar nicht mehr in die Reihe.
        // **Nur solange kein Player läuft.** Im Player ist die Kopfzeile weg,
        // und der Server hätte alle zehn Sekunden eine Anfrage mehr zu
        // beantworten, während es aufs Bild ankommt.
        .task(id: abspielen == nil) {
            if abspielen == nil { uebernahme.starten(model) } else { uebernahme.beenden() }
        }
        .onDisappear { uebernahme.beenden() }
        // **Die Einstellung greift sofort, nicht beim naechsten Ziehen.**
        //
        // Umschalten aendert, welche Reihen es ueberhaupt gibt — und die
        // stehen erst nach einer neuen Abfrage fest. Ohne das sah man seine
        // eigene Einstellung erst, wenn man die Seite von Hand nachlud, und
        // hielt sie fuer wirkungslos.
        .task(id: model.neuzugangGetrennt) { await laden() }
        // **Nicht an `phase` haengen.** Die steht beim Kontowechsel schon auf
        // `.ready` und aendert sich nicht — die Startseite lud nie neu und
        // zeigte die Titel des vorigen Kontos. Auf tvOS ist genau das bei
        // `kontowechsel` ist der Zaehler, der dafuer da ist.
        .onChange(of: model.kontowechsel) { _, _ in Task { await laden() } }
        .fullScreenCover(item: $abspielen, onDismiss: { Task { await laden() } }) { wunsch in
            PlayerScreen(model: model, item: wunsch.item,
                         plan: wunsch.plan, startAt: wunsch.startAt)
        }
        .task { if !stand.geladen { await laden() } }
        // **Beim Zurückkommen neu holen, mit Frist.**
        //
        // Hier lag der Fehler: die Seite lud genau einmal je App-Start, weil
        // `geladen` nie zurückgenommen wurde. Eine auf dem Fernseher zu Ende
        // gesehene Folge stand darum weiter mit Balken in der Reihe, während
        // der Player beim Antippen die Stelle frisch nachholte und richtig
        // bei null anfing. Die Kachel log, nicht der Player.
        //
        // Die Frist steht in `Auffrischung` und nicht hier: tvOS und macOS
        // zeigen dieselben Reihen und brauchen dieselbe Antwort.
        .onChange(of: lebenslage) { _, neu in
            guard neu == .active, stand.brauchtAuffrischung else { return }
            Task { await laden() }
        }
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
        Unschaerfekopf {
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
                // **Und zwar `kuehl`, nicht `akzent`.** Der Akzent sagt „hier
                // laeuft was" — er steht als Fortschrittsbalken zwei Zeilen
                // tiefer auf jeder angefangenen Kachel. Dieses Zeichen sagt
                // „woanders laeuft was". Zwei Aussagen, also zwei Farben;
                // im selben Ton war der Unterschied nicht zu sehen.
                Kopfziele(name: model.session?.userName ?? "?",
                          bild: model.benutzerbildURL()) {
                    if let angebot = uebernahme.angebot {
                        Button { abzeichenGedrueckt() } label: {
                            Image(systemName: angebot.geraetezeichen)
                                .font(.system(size: 20))
                                .foregroundStyle(Stil.kuehl)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Hier weiterschauen"))
                        .accessibilityValue(Text(angebot.titelzeile))
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
            }
            .foregroundStyle(Stil.schrift)
            .animation(.easeInOut(duration: 0.22), value: uebernahme.angebot?.id)
        }
    }

    // MARK: - Auf diesem Gerät weiterschauen

    /// Bei einem Gerät sofort, bei mehreren erst fragen.
    private func abzeichenGedrueckt() {
        if uebernahme.mehrereDa { auswahlOffen = true }
        else if let eine = uebernahme.angebot { hierWeiterschauen(eine) }
    }

    /// Drüben beenden, hier an derselben Stelle weitermachen.
    ///
    /// Erst der Befehl, dann der Plan, dann der Start — geht das Beenden
    /// schief, passiert hier gar nichts. Sonst liefen zwei Tonspuren im Raum.
    private func hierWeiterschauen(_ sitzung: Fremdsitzung) {
        auswahlOffen = false
        Task { abspielen = await uebernahme.wunsch(fuer: sitzung, model: model) }
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
                if !stand.weiterschauen.isEmpty {
                    Reihe(model: model, titel: "Weiterschauen",
                          items: stand.weiterschauen, quer: true, direkt: starte,
                          nachGesehen: { await laden() })
                }
                if !stand.naechsteFolge.isEmpty {
                    // Ohne 'direkt': eine noch nicht angefangene Folge will
                    // man erst ansehen, nicht sofort starten. Nur
                    // 'Weiterschauen' springt direkt in die Wiedergabe.
                    Reihe(model: model, titel: "Nächste Folge", items: stand.naechsteFolge,
                          nachGesehen: { await laden() })
                }
                // Hier führt der Tipp auf die Seite: was man noch nicht
                // angefangen hat, will man erst ansehen.
                if !stand.neueFilme.isEmpty {
                    Reihe(model: model, titel: "Zuletzt hinzugefügte Filme",
                          items: stand.neueFilme, neuzugang: true,
                          nachGesehen: { await laden() })
                }
                if !stand.neueSerien.isEmpty {
                    Reihe(model: model, titel: "Zuletzt hinzugefügte Serien",
                          items: stand.neueSerien, neuzugang: true,
                          nachGesehen: { await laden() })
                }
                if !stand.zuletzt.isEmpty {
                    Reihe(model: model, titel: "Zuletzt hinzugefügt",
                          items: stand.zuletzt, neuzugang: true,
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

    private func laden() async { await stand.laden(model) }
}

/// Eine waagerecht scrollende Reihe.
private struct Reihe: View {
    @Environment(\.breit) private var breit
    let model: AppModel
    let titel: LocalizedStringKey
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
            Reihentitel(text: titel)
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
/// Abweichung von `GESTALTUNG.md` („Flächen sind flach"), und eine
/// Abweichung wandert normalerweise nicht dorthin zurück, wovon sie
/// abweicht. Er steht hier, weil er am Gerät beurteilt werden soll und
/// nicht am Entwurf.
///
/// **Wenn er wieder rausgeht**, ist es diese Struktur und die eine Zeile
/// `if !breit { Farbschein() }` in ``HomeView`` — sonst nichts.
///
/// Vier Sachen, an denen er hängt:
///
/// - **Er liegt über dem Inhalt, nicht darunter.** `bereichsinhalt()` legt
///   einen deckenden Grund hinter die Scrollfläche, damit beim Heranziehen
///   an den Rändern nichts freikommt. Darunter war der Schein schlicht
///   nicht zu sehen — im ersten Anlauf genau so gebaut und am Simulator
///   aufgefallen.
/// - **`plusLighter`, kein Schleier.** Über dem Grund gibt er Licht dazu;
///   über einem hellen Plakat fällt eine Zugabe von vierzehn Prozent nicht
///   auf. Mit normaler Deckkraft läge er als Nebel über den Postern.
/// - **Die Maske blendet ihn weg, bevor die erste Reihe anfängt.** Sonst
///   endet er an einer Kante, und eine Kante ist genau das, was ein Schein
///   nicht haben darf.
/// - **Er nimmt keine Eingaben.** Über ihm liegt die Kopfzeile mit drei
///   Zielen.
private struct Farbschein: View {
    var body: some View {
        // Die Kreise sind größer als der Ausschnitt und sitzen zur Hälfte
        // außerhalb: ein Kreis, dessen Rand im Bild liegt, liest sich als
        // Fleck. Der weiche Rand muss aus dem Bild heraus.
        ZStack(alignment: .top) {
            Circle()
                .fill(Stil.akzent)
                .frame(width: 300, height: 300)
                .opacity(0.50)
                .offset(x: -110, y: -70)
            Circle()
                .fill(Stil.kuehl)
                .frame(width: 320, height: 320)
                .opacity(0.44)
                .offset(x: 130, y: -90)
        }
        .blur(radius: 64)
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: 300, alignment: .top)
        .mask(alignment: .top) {
            LinearGradient(colors: [.white, .white.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 300)
        }
        .blendMode(.plusLighter)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
