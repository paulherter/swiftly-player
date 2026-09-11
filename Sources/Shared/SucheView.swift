import JellyfinKit
import SwiftUI

/// Volltextsuche über Filme, Serien und Folgen.
struct SucheView: View {
    let model: AppModel
    /// Der Bereich ist gerade offen. Der Tab bleibt nach dem ersten Besuch
    /// bestehen, deshalb reicht `onAppear` nicht — das Feld bekaeme nur beim
    /// allerersten Mal den Fokus.
    var aktiv: Bool = true
    /// Wisch nach rechts, wenn die Tastatur schon zu ist: zurück dorthin, wo
    /// man vorher war.
    var zurueck: (() -> Void)? = nil


    @State private var begriff = ""
    @State private var treffer: [Item] = []
    @State private var sucht = false
    @State private var aufgabe: Task<Void, Never>?
    /// Was Seerr kennt und der eigene Server nicht hat.
    ///
    /// **Eigener Zustand, eigene Aufgabe.** Die beiden Abrufe laufen
    /// nebeneinander; kommt von Seerr nichts oder kommt es spät, steht
    /// trotzdem sofort da, was der eigene Server hat.
    @State private var seerrtreffer: [Seerrtreffer] = []
    @FocusState private var imFeld: Bool

    /// **Die Seite ist im Suchzustand — Kopf weg, Feld oben, Ausweg rechts.**
    ///
    /// Getrennt von ``imFeld``, und das ist der Punkt: die Tastatur geht bei
    /// jedem Tipp ins Leere zu, der Suchzustand nicht. Wer etwas eingegeben
    /// hat und die Tastatur wegtippt, will seine Treffer ansehen — faehrt die
    /// Seite dabei wieder auseinander, wandert alles unter dem Daumen weg.
    /// Zurueck kommt man ueber den Ausweg rechts, sonst nicht.
    @State private var suchmodus = false

    /// **Was zuletzt gesucht wurde — die letzten acht, juengstes zuerst.**
    ///
    /// Gemerkt wird beim Abschicken, nicht beim Tippen: wer „Ga", „Gam",
    /// „Game" eingibt, hat einmal gesucht und nicht dreimal.
    @AppStorage(Suchverlauf.schluessel) private var letzteRoh = ""

    @Environment(\.breit) private var breit
    @Environment(\.fensterknoepfe) private var fensterknoepfe
    /// Der zweite Tipp auf den schon offenen Reiter — siehe `HauptView`.
    @Environment(\.reiterNochmal) private var nochmal

    private var letzte: [String] { Suchverlauf.liste(letzteRoh) }

    /// Die Regel selbst steht in `Suchverlauf` — der Fernseher zeigt dieselbe
    /// Liste, und eine zweite Fassung davon wäre eine kopierte Funktion.
    private func merken(_ wort: String) {
        letzteRoh = Suchverlauf.merken(wort, in: letzteRoh)
    }

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            GeometryReader { rahmen in
            // **Die Animation liegt an der ganzen Spalte, nicht am Feld.**
            //
            // Am Feld allein wanderte nur das Feld: die Trefferflaeche
            // darunter bringt ueber `bereichsinhalt()` einen deckenden Grund
            // mit, und deren Rahmen sprang beim Wegfallen des Kopfes ohne
            // Uebergang nach oben. Zu sehen war eine schwarze Kante, die
            // sofort ein Stueck hochruckt, und ein Feld, das dahinter
            // hervorwandert. Beide gehoeren in dieselbe Bewegung — es ist
            // eine Umschichtung der Spalte, nicht die Reise eines Bauteils.
            VStack(spacing: 0) {
                // **Doch ein Kopf auf der Suchseite.**
                //
                // Hier stand keiner, und die Begruendung war das Suchfeld: es
                // sei das einzige Bedienelement der Seite und wolle von Rand
                // zu Rand, ein Zeichen daneben mache aus einem Feld eine Zeile
                // mit Anhaengsel.
                //
                // Der Fehler daran ist die Annahme, das Zeichen muesse
                // **neben** das Feld. Es steht jetzt darueber, in derselben
                // Zeile wie der Seitentitel — genau wie auf Downloads und in
                // der Bibliothek.
                //
                // **Und zwar in `Unschaerfekopf`, nicht in einer eigenen
                // Zeile.** Mit eigenen Abstaenden sass er acht Punkt tiefer
                // als auf den drei anderen Wurzelseiten; am Geraet sieht man
                // genau das, wenn man zwischen den Reitern wechselt. Der
                // Baustein bringt Grad, Sperrung und beide Abstaende mit —
                // dieselbe Regel wie ueberall: eine Rolle, ein Baustein.
                //
                // **Den Titel gibt es breit wie schmal, die Kopfziele nur
                // schmal.** Er stand zuerst nur schmal — damit war die Suche
                // auf dem iPad genau das, was sie auf dem iPhone vorher war:
                // die einzige Wurzelseite ohne Titel, waehrend Filme und
                // Serien einen tragen. Die Kopfziele dagegen wohnen breit in
                // der Seitenleiste, dort waeren sie das zweite Mal.
                if !suchmodus {
                    Unschaerfekopf {
                        HStack(alignment: .top, spacing: 0) {
                            Text("Suchen").font(Stil.titelGross).tracking(-0.6)
                            Spacer(minLength: 0)
                            if !breit {
                                Kopfziele(name: model.session?.userName ?? "?",
                                          bild: model.benutzerbildURL())
                            }
                        }
                        .foregroundStyle(Stil.schrift)
                    }
                    // **Nur ausblenden, nicht wegfahren.**
                    //
                    // Mit `.move(edge: .top)` schob sich der Kopf samt seinem
                    // `Kopfverlauf` nach oben aus dem Bild — und der Verlauf
                    // steht oben bei 0,98. Was man sah, war eine schwarze
                    // Flaeche, die kurz aufpoppte und hinter der das Feld
                    // durchwanderte. Das Feld rueckt ohnehin nach, sobald der
                    // Kopf keinen Platz mehr braucht; die Bewegung entsteht
                    // aus dem Layout, sie muss nicht zusaetzlich gefahren
                    // werden.
                    .transition(.opacity)
                }

                HStack(spacing: 12) {
                    Suchfeld(text: $begriff, amTippen: $imFeld,
                             abschicken: { merken(begriff) })
                        // Breit ein Maß, aber linksbündig: mittig wäre es
                        // gegen das Raster darunter versetzt, über die volle
                        // Breite ein 1036 Punkt langer Kasten für ein Wort.
                        .frame(maxWidth: breit ? Stil.lesebreite : .infinity,
                               alignment: .leading)

                    // **Der Ausweg steht neben dem Feld, nicht darin.**
                    // Im Feld liegt schon der Loeschknopf, und der loescht
                    // nur das Wort; dieser hier schliesst die Tastatur. Zwei
                    // Kreuze nebeneinander waeren zwei Bedeutungen in einem
                    // Zeichen.
                    // Breit wie schmal: der Ausweg gehoert zum Suchzustand,
                    // nicht zur Fenstergroesse. Ohne ihn kaeme man auf dem
                    // iPad gar nicht mehr aus der Suche heraus — dort gibt es
                    // die Wischgeste zurueck nicht, die das schmal noch
                    // auffangen wuerde.
                    if suchmodus {
                        Button {
                            // Der Ausweg raeumt die Seite ab: Wort weg,
                            // Tastatur zu, Kopf wieder da. Das Kreuz **im**
                            // Feld loescht nur das Wort — zwei Zeichen, zwei
                            // Reichweiten.
                            begriff = ""
                            imFeld = false
                            suchmodus = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Stil.schriftLeise)
                                .frame(width: 36, height: 36)
                                .background(Stil.erhoeht, in: Circle())
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Suche schließen"))
                        // **Es kommt zuletzt und geht zuerst.**
                        //
                        // An derselben Kurve wie der Rest stand es schon da,
                        // waehrend das Profilbild noch ausblendete — eines
                        // lag ueber dem anderen, und es sah aus, als poppe es
                        // auf. Mit Verzoegerung wartet es, bis die Spalte
                        // umgeschichtet und der Kopf weg ist, und erscheint
                        // dann in den freien Platz. Beim Schliessen
                        // umgekehrt: sofort weg, damit es dem Profilbild
                        // nicht im Weg steht.
                        .transition(.asymmetric(
                            insertion: .opacity.animation(Stil.blattbewegung.delay(0.14)),
                            removal: .opacity.animation(.easeOut(duration: 0.09))))
                    }

                    if breit { Spacer(minLength: 0) }
                }

                .padding(.horizontal, Stil.rand(breit: breit))
                // Schmal traegt `Unschaerfekopf` darueber den oberen Abstand;
                // ist er weg, weil getippt wird, uebernimmt ihn das Feld.
                .padding(.top, breit ? Stil.kopfOben
                                       + (fensterknoepfe ? Fensterknoepfe.hoehe : 0)
                                     : (suchmodus ? 8 + (fensterknoepfe ? Fensterknoepfe.hoehe : 0) : 4))
                .padding(.bottom, 16)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if begriff.isEmpty {
                            if letzte.isEmpty { leerhinweis } else { zuletzt }
                        } else if sucht, treffer.isEmpty, seerrtreffer.isEmpty {
                            // **Kein Ring.** Solange noch nichts da ist,
                            // steht das Raster in seiner Form; sind schon
                            // Treffer da, bleiben die stehen, statt einem
                            // Ring zu weichen.
                            Rasterplatzhalter(
                                spalten: Stil.spalten(
                                    nutzbar: rahmen.size.width - 2 * Stil.rand(breit: breit),
                                    breit: breit),
                                reihen: 2)
                                .padding(.horizontal, Stil.rand(breit: breit))
                                .padding(.top, 12)
                                .transition(.opacity)
                        } else if treffer.isEmpty, seerrtreffer.isEmpty {
                            // **Beide leer, nicht nur die Bibliothek.** Hier
                            // stand `treffer.isEmpty`, und damit gewann dieser
                            // Zweig, sobald der eigene Server nichts hatte —
                            // der Seerr-Block darunter wurde nie erreicht.
                            // Genau der Fall, für den die ganze Anbindung
                            // gebaut ist: „Blade Runner" gibt es hier nicht,
                            // und *deshalb* will man ihn anfragen. Von
                            Text("Keine Treffer für \u{201E}\(begriff)\u{201C}")
                                .font(Stil.koerper)
                                .foregroundStyle(Stil.schriftLeise)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                            // Nach Art gruppiert, wie bei Plex: in der Liste
                            // liest man Titel und Art auf einen Blick.
                            let nutzbar = rahmen.size.width - 2 * Stil.rand(breit: breit)
                            // **Ohne Seerr keine Überschrift.** Wer nichts
                            // angebunden hat, soll nicht „Auf deinem Server"
                            // lesen und sich fragen, wo der andere Block ist.
                            // Die Überschrift trägt nur, wenn darunter
                            // wirklich etwas steht — sonst kündigt sie einen
                            // leeren Block an.
                            if !seerrtreffer.isEmpty, !treffer.isEmpty {
                                blockTitel("Auf deinem Server", treffer.count)
                            }
                            gruppe("Serien", treffer.filter { $0.type == "Series" },
                                   nutzbar: nutzbar)
                            gruppe("Filme", treffer.filter { $0.type == "Movie" },
                                   nutzbar: nutzbar)
                            gruppe("Folgen", treffer.filter { $0.type == "Episode" },
                                   nutzbar: nutzbar)
                            gruppe("Weiteres", treffer.filter {
                                !["Series", "Movie", "Episode"].contains($0.type ?? "")
                            }, nutzbar: nutzbar)
                            if !seerrtreffer.isEmpty {
                                blockTitel("Kann angefragt werden", seerrtreffer.count).padding(.top, 8)
                                seerrRaster(nutzbar: nutzbar)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.bottom, breit ? 24 : Stil.leisteHoehe + 12,
                                for: .scrollContent)
                // Tippen ins Leere schliesst die Tastatur — sonst kommt man
                // aus dem Feld gar nicht mehr heraus.
                .simultaneousGesture(TapGesture().onEnded { imFeld = false })
                // Nur die Trefferflaeche zieht sich heran, nicht das Suchfeld
                // darueber — siehe `bereichsinhalt()`.
                .bereichsinhalt()
            }
            .animation(Stil.blattbewegung, value: suchmodus)
            }
            // Ueber dem Inhalt, unter allem, was die Seite sonst noch
            // auflegt — siehe `bereichsleiste()`.
            .bereichsleiste()
        }
        // Erst die Tastatur, dann der Weg zurück — wie überall in iOS.
        //
        // Nebenläufig, nicht ausschließlich: mit `.gesture` gewinnt die Liste
        // darunter, und der Wisch kam nie an. So darf die Geste mitlaufen,
        // ohne dem Scrollen etwas wegzunehmen — sie wertet ohnehin nur aus,
        // was am Ende herauskam.
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onEnded { geste in
                    guard geste.translation.width > 55,
                          abs(geste.translation.height) < 55 else { return }
                    if imFeld { imFeld = false } else { zurueck?() }
                }
        )
        // **Der Reiter oeffnet die Tastatur nicht mehr.**
        //
        // Sie sprang beim Betreten des Bereichs von selbst auf — man landete
        // also nie auf der Suchseite, sondern immer schon im Tippen, und was
        // die Seite sonst zu bieten hat, sah man nie. Jede andere App auf dem
        // Geraet macht es andersherum: ein Tipp bringt einen hin, das Feld
        // oeffnet man selbst. Beim Verlassen geht die Tastatur weiterhin zu,
        // sonst bliebe sie ueber dem naechsten Bereich stehen.
        .onChange(of: imFeld) { _, drin in if drin { suchmodus = true } }

        // **Beim Verlassen geht nur die Tastatur zu, sonst nichts.**
        //
        // Der Suchzustand ueberlebt den Bereichswechsel. Wer bei einem
        // Treffer nachsieht, wo die Folge herkommt, und dann zurueck auf
        // Suche geht, will seine Suche vorfinden und nicht die leere Seite —
        // sonst tippt man dasselbe Wort zweimal. Zu ist sie, wenn man das
        // Kreuz drueckt, und sonst nie.
        .onChange(of: aktiv) { _, offen in if !offen { imFeld = false } }
        // **Der zweite Tipp auf den Reiter oeffnet das Feld.** Der erste
        // bringt einen nur her — siehe `reiterNochmal`.
        .onChange(of: nochmal) { _, _ in if aktiv { imFeld = true } }
        .onChange(of: begriff) { _, neu in suchen(neu) }
    }

    @ViewBuilder
    private func gruppe(_ titel: String, _ eintraege: [Item],
                        nutzbar: CGFloat) -> some View {
        if !eintraege.isEmpty {
            Text(titel)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Stil.schriftLeise)
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 14)
                .padding(.bottom, breit ? 10 : 6)

            // Schmal eine Zeilenliste, breit ein Gitter — so macht es der
            // Fernseher. Eine Zeile mit 52er Vorschaubild und danach 900 Punkt
            // Nichts ist keine Liste mehr.
            //
            // **A7 gilt in beiden Formen**: kein Treffer startet, jeder führt
            // auf seine Seite. Vorher startete hier, was sich abspielen ließ —
            // das stand so im Kommentar und war trotzdem die Ausnahme von der
            // Regel, die überall sonst gilt.
            if breit {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                             spacing: Stil.kachelAbstand),
                                         count: Stil.spalten(nutzbar: nutzbar, breit: breit)),
                          alignment: .leading, spacing: 20) {
                    ForEach(eintraege) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item, breite: nil,
                                       auskunft: item.trefferauskunft)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.bottom, 10)
            } else {
                // **Auch schmal ein Raster, nicht mehr eine Zeilenliste.**
                // Mit Seerr stehen zwei Blöcke untereinander, und ein Plakat
                // sagt auf einen Blick, ob ein Titel da ist — eine Zeile mit
                // 52er Vorschaubild kann das nicht.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                             spacing: Stil.kachelAbstand),
                                         count: Stil.spalten(nutzbar: nutzbar, breit: breit)),
                          alignment: .leading, spacing: 16) {
                    ForEach(eintraege) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item, breite: nil,
                                       auskunft: item.trefferauskunft)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.bottom, 10)
            }
        }
    }

    /// **Die Rubrik sagt jetzt auch, wie viel.**
    ///
    /// Bibliothek und Merkliste tragen rechts eine Zählmarke; sie beantwortet
    /// „bin ich hier durch?". In der Suche fehlte sie — dabei ist gerade dort
    /// interessant, wie viel überhaupt kam, und beim zweiten Block nebenbei,
    /// wie viel Seerr anzubieten hat.
    private func blockTitel(_ text: LocalizedStringKey, _ anzahl: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(Stil.schriftSehrLeise)
            Spacer(minLength: 8)
            if anzahl > 0 { Zaehlmarke(anzahl: anzahl) }
        }
        .padding(.horizontal, Stil.rand(breit: breit))
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func seerrRaster(nutzbar: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                     spacing: Stil.kachelAbstand),
                                 count: Stil.spalten(nutzbar: nutzbar, breit: breit)),
                  alignment: .leading, spacing: 16) {
            ForEach(seerrtreffer) { t in
                NavigationLink(value: t) { Seerrkachel(treffer: t) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Stil.rand(breit: breit))
        .padding(.bottom, 10)
    }

    /// **Breit steht er unter dem Feld, nicht in der Mitte.**
    ///
    /// Schmal fuellt das Suchfeld die Zeile, und ein mittiger Hinweis steht
    /// unter seiner Mitte. Breit ist das Feld nur `lesebreite` lang und sitzt
    /// links — der Hinweis stand dann in der Mitte des Fensters, also neben
    /// dem, worauf er sich bezieht.
    /// **Wonach zuletzt gesucht wurde.**
    ///
    /// Der Platz unter dem Feld stand leer und trug einen Satz, der erklaerte,
    /// was ein Suchfeld ist. Wer zum zweiten Mal hier steht, sucht meistens
    /// dasselbe noch einmal — und ein angetipptes Wort ist schneller als
    /// zehn Tastenanschlaege.
    ///
    /// Antippen fuellt das Feld, es sucht dann von selbst. Es oeffnet die
    /// Tastatur ausdruecklich **nicht**: wer aus der Liste waehlt, will das
    /// Ergebnis und nicht weitertippen.
    private var zuletzt: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Gruppentitel(text: "Zuletzt gesucht")
                Spacer(minLength: 8)
                Button { letzteRoh = "" } label: {
                    Text("Löschen")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, 18)

            ForEach(Array(letzte.enumerated()), id: \.offset) { stelle, wort in
                Button {
                    begriff = wort
                    imFeld = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 15))
                            .foregroundStyle(Stil.schriftSehrLeise)
                            .frame(width: 20)
                        Text(verbatim: wort)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Stil.schrift)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Stil.rand(breit: breit))
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if stelle < letzte.count - 1 {
                    Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
                }
            }
        }
        .frame(maxWidth: breit ? Stil.lesebreite : .infinity, alignment: .leading)
    }

    private var leerhinweis: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Stil.schriftSehrLeise)
            Text("Filme, Serien und Folgen durchsuchen")
                .font(Stil.koerper)
                .foregroundStyle(Stil.schriftLeise)
        }
        // **Mittig unter dem Feld, nicht mittig im Fenster.**
        //
        // Er stand in der Mitte der ganzen Breite, das Feld darueber aber
        // links in seiner Lesebreite — der Hinweis schwebte also neben dem,
        // worauf er sich bezieht. Linksbuendig war es dann das andere Extrem:
        // Zeichen und Satz klebten an der Kante eines leeren Fensters. Jetzt
        // bekommt er dieselbe Spalte wie das Feld und steht in deren Mitte.
        .frame(maxWidth: breit ? Stil.lesebreite : .infinity)
        .frame(maxWidth: .infinity, alignment: breit ? .leading : .center)
        .padding(.horizontal, breit ? Stil.rand(breit: true) : 0)
        .padding(.top, 70)
    }


    /// Mit Verzögerung, damit nicht jeder Tastendruck eine Anfrage auslöst.
    private func suchen(_ begriff: String) {
        aufgabe?.cancel()
        let sauber = begriff.trimmingCharacters(in: .whitespaces)
        // Die Schwelle steht im Paket, damit sie auf allen sechs Fassungen
        // dieselbe ist — sie stand bisher überall einzeln getippt.
        guard Anzeigeregeln.suchbegriffTaugt(sauber) else {
            treffer = []
            seerrtreffer = []
            sucht = false
            return
        }
        sucht = true
        aufgabe = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // **Nebeneinander, nicht nacheinander.** Der eigene Server ist
            // der Grund, warum jemand die App benutzt; er darf nicht auf
            // eine Zugabe warten. Deshalb wird zuerst gezeigt, was er hat.
            async let fremd = model.seerr.suchen(sauber)
            let ergebnis = await model.suche(sauber)
            guard !Task.isCancelled else { return }
            // Doppelte Kennungen lassen einen Tipp danebengreifen.
            treffer = Listenregeln.ohneDoppelte(ergebnis)
            sucht = false

            let dazu = await fremd
            guard !Task.isCancelled else { return }
            // Was der eigene Server schon hat, gehört nicht in den unteren
            // Block — sonst stünde derselbe Titel zweimal auf der Seite.
            seerrtreffer = dazu.filter { !$0.stand.schonDa }
        }
    }
}
