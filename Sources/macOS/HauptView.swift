import JellyfinKit
import SwiftUI

/// Welchen Bereich die Seitenleiste zeigt. Dieselben vier wie in der Leiste
/// unten auf dem iPhone.
enum Bereich: String, Hashable, CaseIterable {
    case start, filme, serien, merkliste, downloads, suche

    /// Was in der Seitenleiste steht. **H1:** ohne den Schalter gibt es die
    /// Downloadzeile nicht.
    ///
    /// Downloads steht **oben bei den Bereichen**, nicht unten bei den
    /// Sammlungen — anders als die Merkliste. Die ist eine Bibliothek, deren
    /// Grenze der Haken ist; Downloads ist keine Auswahl aus dem Server,
    /// sondern das, was auf dieser Maschine liegt. Auf dem iPhone ist es aus
    /// demselben Grund ein Reiter und kein Ziel im Kopf.
    /// **Oben, was der Server hat.** Vier Zeilen, wie eh und je.
    static let obenGruppe: [Bereich] = [.start, .filme, .serien, .suche]

    /// **Und darunter, was mir gehoert.**
    ///
    /// Sechs gleichrangige Zeilen untereinander lasen sich als eine Liste, in
    /// der nichts mehr zusammengehoert Merkliste und Downloads sind aber nicht
    /// dieselbe Sorte Ort wie Filme und Serien: die beiden sind **Sammlungen
    /// des Servers**, diese zwei sind **meine** — was ich mir gemerkt und was
    /// ich auf diese Maschine geholt habe. Die Trennung stand also schon da,
    /// sie war nur nicht zu sehen.
    ///
    /// Leer, solange Downloads aus ist und nichts gemerkt wurde — dann gibt es
    /// die Rubrik gar nicht.
    static func meinsGruppe(downloads: Bool) -> [Bereich] {
        downloads ? [.merkliste, .downloads] : [.merkliste]
    }

    var symbol: String {
        switch self {
        case .start:     "house"
        case .filme:     "film"
        case .serien:    "tv"
        case .suche:     "magnifyingglass"
        case .downloads: "arrow.down.circle"
        case .merkliste: "bookmark.fill"
        }
    }

    var beschriftung: LocalizedStringKey {
        switch self {
        case .start:     "Start"
        case .filme:     "Filme"
        case .serien:    "Serien"
        case .suche:     "Suche"
        case .downloads: "Downloads"
        case .merkliste: "Merkliste"
        }
    }
}

/// Das Fenster: Seitenleiste links, Inhalt rechts.
///
/// Die Leiste unten des iPhones wandert hier an die Seite. Der Grund ist
/// nicht Geschmack: unten lag sie in Daumenreichweite, und sie setzte eine
/// feste Bildschirmhöhe voraus. Beides gibt es in einem Fenster nicht.
struct HauptView: View {
    let model: AppModel

    @State private var bereich: Bereich = .start
    @State private var steuerung: Abspielsteuerung
    @State private var navigator = Navigator()

    /// **Die Stände der vier Bereiche liegen hier, nicht in den Ansichten.**
    ///
    /// Die Wurzel trägt `.id(bereich)` — beim Wechsel wird sie also
    /// weggeworfen und neu gebaut. Lag ihr Stand in ihr, war er mit weg: die
    /// Startseite stand eine Sekunde lang schwarz, die Regale zeigten wieder
    /// ihren Ladebalken, obwohl längst alles geholt war.
    @State private var startseite = Startseitenmodell()
    /// Läuft auf einem anderen Gerät etwas? Siehe ``Uebernahmemodell``.
    @State private var uebernahme = Uebernahmemodell()
    /// Bei mehr als einem Gerät wird gefragt statt geraten.
    @State private var auswahlOffen = false
    @State private var filmregal = Bibliotheksmodell()
    @State private var serienregal = Bibliotheksmodell()
    /// Welche Bibliothek der jeweiligen Gattung gezeigt wird — ein Server
    /// kann mehrere haben. Liegt aus demselben Grund hier wie die Regale.
    @State private var filmbibliothek: Item?
    @State private var serienbibliothek: Item?
    /// **Eine der uebrigen Bibliotheken, als Wurzel.**
    ///
    /// Nicht als Seite auf dem Stapel: eine Seite faehrt von rechts herein und
    /// traegt einen Zurueckpfeil, und Filme und Serien sind Wurzeln — also ist
    /// das hier eine. Gesetzt heisst: sie steht statt der Wurzel des Bereichs;
    /// jeder Klick auf einen Bereich setzt sie zurueck.
    @State private var offeneBibliothek: Item?

    init(model: AppModel) {
        self.model = model
        _steuerung = State(initialValue: Abspielsteuerung(model: model))
    }

    var body: some View {
        HStack(spacing: 0) {
            Seitenleiste(model: model, bereich: $bereich,
                         uebernahme: uebernahme.angebot,
                         uebernehmen: { abzeichenGedrueckt() },
                         bibliothekWaehlen: { bibliothekAusLeiste($0) },
                         gewaehlteBibliothek: { art in
                             art == "movies" ? filmbibliothek : serienbibliothek
                         },
                         bibliothekOeffnen: { offeneBibliothek = $0 },
                         offeneKennung: offeneBibliothek?.id,
                         schliesseBibliothek: { offeneBibliothek = nil },
                         zumProfil: { navigator.oeffne(.profil, in: bereich) })
            // **Der Sicherheitsrand der Titelleiste gilt links genauso wenig
            // wie rechts.** Vorher hielt nur der Inhaltsbereich ihn nicht
            // ein; die Leiste stand deshalb rund dreissig Punkt tiefer als
            // das Fenster — samt ihrer Fläche und ihrer Kante. Dazu kam, dass
            // sie oben nochmal `ampelHoehe` freihält: der Abstand lag also
            // doppelt an.
            .ignoresSafeArea(.container, edges: .vertical)

            // **Die Kante als eigene Spalte, nicht als Auflage.**
            //
            // Als `.overlay` auf der Leiste hing sie an deren Rahmen und
            // hörte dort auf, wo der Rahmen aufhörte — nicht am Fensterrand.
            // Hier ist sie eine Spalte für sich, volle Höhe, ohne
            // Sicherheitsrand.
            Rectangle()
                .fill(Stil.linie)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .vertical)
            // **Die Leiste liegt oben — sichtbar und fuer Klicks.**
            //
            // In einem `HStack` zeichnet das spaetere Kind ueber dem
            // frueheren, und die Leiste steht als erste da. Das war so lange
            // egal, wie der Inhalt in seiner Spalte blieb. Bleibt er aber
            // nicht: `wurzel` bekommt beim Oeffnen einer Seite `mitgang`, also
            // **minus dreissig Prozent der Inhaltsbreite**, und ragte damit
            // unter die Leiste — dort oben auf, weil spaeter deklariert. Ein
            // Klick auf „Lieblingsfolgen" landete auf dem Poster, das
            // zufaellig darunter lag; Und wer auf „Serien" klickte, schaltete
            // nichts um, weil die Leiste den Klick nie bekam — daher „die
            // gesamte Leiste reagiert auf nichts mehr".
            .zIndex(1)

            ZStack {
                Stil.grund
                inhalt
            }
            // **Und der Inhalt bleibt in seiner Spalte — auch fuer Klicks.**
            //
            // Hier stand zuerst `clipped()`. Das schneidet nur das **Bild**:
            // die Wurzel war danach sauber an der Haarlinie abgeschnitten,
            // und der Klick auf „Filme" landete trotzdem weiter im Raster
            // dahinter. Am laufenden Fenster nachgesehen — der Baum zeigte
            // die Chips der Wurzel bei **x = −117**, also unter der Leiste,
            // und ein Klick auf die Leistenzeile wurde an die Scrollflaeche
            // zugestellt.
            //
            // `clipShape` beschneidet **auch die Trefferflaeche**; das sagt
            // Apples Beschreibung ausdruecklich, `clipped()` sagt es nicht.
            // Der Versatz selbst bleibt — er ist die Bewegung, die den
            // Eindruck von Ebenen macht.
            .clipShape(Rectangle())
            // **Der Leistenwechsel wird nicht überblendet.**
            //
            // Hier stand `.animation(Stil.zeitSeite, value: bereich)`. Eine
            // Anweisung mit `value:` gilt für **alles**, was sich in diesem
            // Durchgang im Unterbau ändert — nicht nur für den Tausch der
            // Wurzel. Beim Wechsel der Leiste ändert sich aber noch mehr:
            // Seiten des alten Bereichs verschwinden, Versatz und Schleier
            // fallen auf den Stand des neuen. All das wurde dadurch bewegt,
            // und was man sah, war ein Seitenschub samt Schattenkante, wo
            // nichts hätte fahren sollen.
            //
            // Auf dem Mac ist die Blende ohnehin fehl am Platz: eine
            // Seitenleiste schaltet dort sofort um — Finder, Mail,
            // Systemeinstellungen. Die Blende war aus der iPhone-Fassung
            // mitgenommen, wo der Wechsel unten in der Leiste sitzt.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // **Der Sicherheitsrand der Titelleiste fällt hier weg, nicht auf
            // jeder Seite einzeln.**
            //
            // Gemessen: die Scrollfläche saß 32 Punkt tief und trug oben
            // einen Rand von 32 — das war die schwarze Leiste. Und sie kam
            // nicht überall an: die Kulisse landete mal bei 0, mal bei 32,
            // was Film- und Serienseite um genau diesen Betrag gegeneinander
            // verschob. Ein Rand, der an mehreren Stellen halb entfernt wird,
            // ist schlimmer als einer, der überall steht.
            //
            // Die Seiten setzen ihren oberen Abstand selbst — `inhaltOben`.
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Stil.grund)
        .environment(steuerung)
        // **Der Socket, ohne den der Mac keine Sitzung ist.**
        //
        // iOS und tvOS starten ihn je in ihrer eigenen `HauptView`; die des
        // Macs hatte ihn nie. Ohne ihn meldet Jellyfin
        // `SupportsRemoteControl: false` — der Mac liess sich also weder von
        // aussen bedienen noch uebernehmen, und im Dashboard blieben die
        // Knoepfe grau. Es fiel nicht auf, weil die App fuer sich einwandfrei
        // lief.
        .task { await model.fernsteuerungStarten() }
        .onDisappear { Task { await model.fernsteuerungBeenden() } }
        // **Nur solange kein Player läuft** — im Player ist die Leiste weg,
        // und der Server hätte alle zehn Sekunden eine Anfrage mehr.
        .task(id: steuerung.wunsch == nil) {
            if steuerung.wunsch == nil { uebernahme.starten(model) }
            else { uebernahme.beenden() }
        }
        .onDisappear { uebernahme.beenden() }
        .overlay {
            if auswahlOffen {
                Uebernahmeauswahl(sitzungen: uebernahme.angebote,
                                  waehlen: { hierWeiterschauen($0) },
                                  abbrechen: { auswahlOffen = false })
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: auswahlOffen)
        .environment(navigator)
        .environment(\.bereich, bereich)
        // **G4: Der Seitenstapel gehört zum Konto.** Was darauf liegt, gehört
        // nach dem Wechsel dem vorigen — eine Detailseite hängt an
        // `.task(id: titel.id)`, eine Serienseite an der Staffel, die Suche
        // am Begriff, und keine dieser Kennungen ändert sich dabei. Man sähe
        // die Haken und Fortschrittsbalken des anderen Kontos, und ein Druck
        // auf Abspielen setzte an dessen Stelle an.
        //
        // Hier und nicht in jeder Seite: das wären fünf Stellen, und die
        // nächste neue Seite vergisst es.
        .onChange(of: model.kontowechsel) { _, _ in navigator.alleLeeren() }
        // Der Player nimmt das ganze Fenster ein, Seitenleiste eingeschlossen.
        .overlay {
            if let wunsch = steuerung.wunsch {
                PlayerScreen(model: model, wunsch: wunsch) { steuerung.schliessen() }
                    // Aufsteigen — die dritte der drei Bewegungen. Von unten
                    // herauf und wieder hinunter; deshalb zeigt der Winkel
                    // oben links nach unten.
                    .transition(.move(edge: .bottom))
            }
        }
        // **Der helle Streifen war kein Anstrich, sondern ein Rand.**
        //
        // Die Auflage wird im Sicherheitsbereich ausgelegt, also unterhalb
        // der Titelleiste — das Bild fing dort an, und darüber blieb die
        // Leiste stehen. Ein `.ignoresSafeArea()` **innerhalb** des Players
        // half nicht: die Auflage selbst war da schon eingerückt, und ein
        // Kind kann den Rahmen seines Elternteils nicht wieder aufmachen.
        //
        // Nachgesehen habe ich zuerst bei Apple: es gibt einen bekannten
        // Rückschritt in macOS 26, bei dem die Titelleiste trotz
        // `titlebarAppearsTransparent` gezeichnet wird — ausgelöst von genau
        // unserem Aufbau, einer Scrollfläche mit einer Ansicht links daneben.
        // Der ist aber seit 26.1 behoben, und dieser Rechner läuft auf 26.5.
        // Also lag es doch an uns.
        .ignoresSafeArea()
        .animation(Stil.zeitSprung, value: steuerung.wunsch?.id)
        .onReceive(NotificationCenter.default.publisher(for: Kommandopost.name)) { post in
            guard let kommando = Kommandopost.empfangen(post) else { return }
            ausfuehren(kommando)
        }
    }

    /// Wie viele Seiten **gezeigt** werden. Das ist bewusst nicht dasselbe
    /// wie `navigator.seiten(bereich).count`: beim Tiefergehen hinkt der Wert
    /// ein Einzelbild hinterher, und genau darin liegt der Trick.
    ///
    /// **Warum überhaupt.** Mit `.transition(.move)` legt SwiftUI die neue
    /// Seite an und bewegt sie im selben Einzelbild. In dieses eine Bild
    /// fällt dann der gesamte Aufbau der Detailseite — Kulisse, Kopf,
    /// Besetzung, Ähnliches. Das Bild kommt zu spät, die Bewegung setzt mit
    /// einem Sprung ein, und keine Kurve der Welt bügelt das aus. Ein
    /// `UINavigationController` macht es seit jeher andersherum: die neue
    /// Ansicht kommt in den Behälter, wird ausgelegt, und **erst danach**
    /// startet der Animator.
    ///
    /// Also: Seite anlegen, um eine volle Breite nach rechts versetzt, ein
    /// Bild warten, dann fahren. Beim Zurückgehen entfällt das Warten — dort
    /// steht längst alles.
    /// **Je Bereich getrennt.** Vorher stand hier eine einzige Zahl für alle
    /// vier Bereiche. Wer in „Filme" eine Seite offen ließ und in der Leiste
    /// auf „Start" wechselte, setzte sie damit von 1 auf 0 zurück — und weil
    /// am Elternteil `.animation(zeitSeite, value: bereich)` hängt, lief
    /// dieser Rücksprung als Bewegung ab: die Wurzel fuhr ihren Mitgang
    /// zurück und der Schleier blendete aus. **Das war die komische
    /// Einblendung mit dem dunklen Verlauf beim Leistenwechsel.**
    ///
    /// Der Stapel liegt im `Navigator` seit jeher je Bereich getrennt; diese
    /// Zahl gehört daneben.
    @State private var gezeigteTiefe: [Bereich: Int] = [:]

    /// Wie viele Seiten im **aktuellen** Bereich gezeigt werden.
    private var tiefe: Int { gezeigteTiefe[bereich] ?? 0 }

    /// Was gerade die Wurzel ist — ein Bereich oder eine der uebrigen
    /// Bibliotheken. Aendert sie sich, wird die Wurzel neu gebaut.
    private var wurzelkennung: String { offeneBibliothek?.id ?? bereich.rawValue }

    private var inhalt: some View {
        GeometryReader { raum in
            let breite = raum.size.width
            // Wie weit die darunterliegende Seite mitgeht. Ein Drittel — so
            // hält es die Systemnavigation, und daher kommt der Eindruck von
            // Ebenen statt von einem Rechteck, das vorbeischiebt.
            let mitgang = -breite * 0.3

            ZStack {
                // Die Wurzel des Bereichs liegt immer unten.
                // **Mitgang und Schleier gehören *unter* die Kennung.**
                //
                // Standen sie darüber, galten sie für die ausscheidende
                // Wurzel genauso wie für die neue — und beide lasen `tiefe`
                // des *neuen* Bereichs. Wer in „Filme" eine Seite offen ließ
                // und auf „Start" wechselte, sah deshalb, wie die alte Wurzel
                // ihren Mitgang zurückfuhr und der Schleier ausblendete: eine
                // Bewegung mit dunklem Verlauf, die dort nichts zu suchen
                // hat. Bei „Filme" und „Serien" fiel es nicht auf, weil dort
                // eine Seite obendrauf lag, die es verdeckte.
                //
                // Unter der Kennung gehören sie zur jeweiligen Wurzel. Die
                // ausscheidende behält ihren Stand und blendet einfach aus.
                wurzel
                    // **Der Wechsel blendet ueber — und zwar nur die Wurzel.**
                    //
                    // Hier stand nichts, und die uebrigen Bibliotheken
                    // erschienen deshalb hart, waehrend alles andere weich
                    // kommt.
                    //
                    // **Die Reihenfolge ist der Punkt.** Die Anweisung steht
                    // unmittelbar an der Wurzel, also vor dem Versatz und dem
                    // Schleier darum. Frueher hing am Elternteil ein
                    // `.animation(value: bereich)` — das galt fuer *alles*,
                    // was sich im selben Durchgang aenderte, also auch fuer
                    // `tiefe`: die ausscheidende Wurzel fuhr ihren Mitgang
                    // zurueck und der Schleier blendete aus. Genau das ist
                    // "die komische Einblendung mit dem dunklen Verlauf"
                    // gewesen, und genau deshalb steht sie hier innen.
                    .transition(.opacity)
                    .animation(Stil.einblenden, value: wurzelkennung)
                    .offset(x: tiefe > 0 ? mitgang : 0)
                    .overlay {
                        Color.black.opacity(tiefe > 0 ? 0.28 : 0)
                            .allowsHitTesting(false)
                    }
                    // **Was unter einer Seite liegt, nimmt keine Klicks.**
                    //
                    // Das ist die eigentliche Regel — der Schleier darueber
                    // sagt sie ja schon: die Wurzel ist verdeckt, also ist sie
                    // nicht bedienbar. Ohne diese Zeile blieb sie es, und weil
                    // `mitgang` sie um dreissig Prozent nach links schiebt,
                    // lagen ihre Chips und Poster **unter der Seitenleiste**.
                    // Am laufenden Fenster nachgesehen: der Filterchip
                    // „Serien" stand bei x = 4, die Leistenzeile „Filme" bei x
                    // = 12 — und der Klick ging an den Chip. Das war das
                    // „ich druecke links und es oeffnet sich Attack on Titan"
                    // und ebenso das „die Leiste reagiert auf nichts mehr":
                    // sie bekam den Klick nie.
                    //
                    // `clipped()` half nicht und `clipShape` auch nicht —
                    // beide beschneiden das Bild, die Trefferflaeche der
                    // Kinder bleibt, wo sie ist.
                    .allowsHitTesting(tiefe == 0)
                    // **Und aus dem Bedienungshilfen-Baum ebenso.** Eine
                    // verdeckte Seite gehoert dort nicht hin — VoiceOver
                    // liefe sonst durch Knoepfe, die niemand sieht. Es ist
                    // dieselbe Aussage wie `allowsHitTesting`, nur fuer den
                    // zweiten Weg hinein; ohne sie stand die Wurzel weiter im
                    // Baum, mit Chips bei x = 4 unter der Leiste.
                    .accessibilityHidden(tiefe > 0)
                    .id(bereich)
                    // **Die Wurzel liegt ausdrücklich unten.** Ohne feste
                    // Ebenen fuhr die Seite unter den Kacheln der Startseite
                    // herein, und das sah aus wie Durchsichtigkeit.
                    .zIndex(0)

                // **Der Seitenstapel als Ganzes, mit eigener Kennung.**
                //
                // Ohne sie stand der `ForEach` unmittelbar in diesem Stapel.
                // Beim Wechsel der Leiste wechselte damit sein Inhalt — von
                // den Seiten des einen Bereichs auf die des anderen —, und
                // SwiftUI spielte für jede verschwindende Seite ihre
                // **Hinausfahr-Bewegung** ab: von rechts hinaus, mit der
                // Schattenkante obendrauf. Wer in „Filme" eine Seite offen
                // liess und auf „Start" ging, sah deshalb einen Seitenschub,
                // wo nur überblendet werden sollte.
                //
                // Mit `.id(bereich)` wird der Stapel als **ein** Stück
                // getauscht. Dann gilt die Überblendung dieses Stücks, und
                // die Bewegungen darin bleiben dem Tiefergehen vorbehalten,
                // wofür sie gedacht sind.
                ZStack {
                    ForEach(Array(navigator.seiten(bereich).enumerated()), id: \.element.id) { platz, ziel in
                        let obenauf = platz == tiefe - 1
                        let gezeigt = platz < tiefe

                        ZStack {
                            Stil.grund
                            seite(ziel)
                        }
                        // Rechts draußen, bis sie an der Reihe ist; darunter
                        // liegende Seiten gehen ein Stück mit.
                        .offset(x: gezeigt ? (obenauf ? 0 : mitgang) : breite)
                        .overlay {
                            Color.black.opacity(gezeigt && !obenauf ? 0.28 : 0)
                                .allowsHitTesting(false)
                        }
                        // Der Schlagschatten an der Vorderkante. Als schmaler
                        // Verlauf **neben** der Seite, nicht als `.shadow` —
                        // ein Schatten um eine bildschirmgroße Ansicht zwingt
                        // sie in einen eigenen Zwischenspeicher, und den baut
                        // das System in jedem Einzelbild neu auf.
                        .overlay(alignment: .leading) {
                            LinearGradient(colors: [.black.opacity(0.45), .clear],
                                           startPoint: .trailing, endPoint: .leading)
                                .frame(width: 28)
                                .offset(x: -28)
                                .allowsHitTesting(false)
                        }
                        // Dieselbe Regel eine Ebene hoeher: von den Seiten
                        // des Stapels nimmt nur die oberste Klicks. Die
                        // darunter tragen denselben Schleier wie die Wurzel,
                        // und was rechts draussen wartet, ist gar nicht da.
                        .allowsHitTesting(obenauf)
                        .accessibilityHidden(!obenauf)
                        .zIndex(Double(platz + 1))
                        // **Losfahren, sobald die Seite wirklich steht.**
                        //
                        // Vorher wartete hier ein `Task.sleep(16 ms)`. Das war
                        // ein Rennen: ein Einzelbild dauert bei 120 Hz gut acht
                        // Millisekunden, mal lag der Weckruf davor, mal dahinter.
                        // Lag er davor, fielen Anlegen und Losfahren in denselben
                        // Vorgang — dann sprang die Seite ohne Bewegung an ihren
                        // Platz. **Genau das ist „manchmal normal, manchmal
                        // hart".** Es war nie die Kurve.
                        //
                        // `DispatchQueue.main.async` aus `onAppear` heraus läuft
                        // dagegen zugesichert nach dem Abschluss des laufenden
                        // Vorgangs. Kein Wecker, keine Millisekunden, kein Rennen.
                        .onAppear {
                            // Steht die Seite schon, ist das ein Rückkehrer aus
                            // einem Leistenwechsel — der fährt nicht noch einmal.
                            guard platz >= tiefe else { return }
                            // **Nur dieser eine Schreibzugriff.** Vorher stand
                            // daneben ein zweiter, unanimierter (`ruht = false`).
                            // Beides ist Zustand derselben Ansicht und landet in
                            // einem Aktualisierungslauf — für den sucht SwiftUI
                            // sich *eine* Transaktion aus. Fällt die Wahl auf die
                            // leere, wird der Versatz ohne Bewegung gesetzt. Es
                            // war der einzige Ort im Baum, an dem eine laufende
                            // Bewegung überhaupt kippen konnte.
                            DispatchQueue.main.async {
                                withAnimation(Stil.zeitSeitenschub) { gezeigteTiefe[bereich] = platz + 1 }
                            }
                        }
                        // **Nur das Hinausfahren ist ein Übergang.** Das
                        // Hereinfahren macht der Versatz oben, damit die Seite
                        // vorher fertig ausgelegt ist. Blenden tut hier nichts:
                        // unterwegs durchsichtig sieht nach Fehler aus.
                        .transition(.asymmetric(insertion: .identity,
                                                removal: .move(edge: .trailing)))
                }
                .zIndex(1)
                }
            }
            // **Sonst tritt die Wurzel über den Rand.** Der Mitgang schiebt
            // sie um ein Drittel nach links — ohne Beschnitt landet dieses
            // Drittel über der Seitenleiste, und man sieht Startseite und
            // Seitenleiste übereinander. Genau das war im Bild zu sehen.
            .clipped()
            // **Der Bereich als Ganzes, mit einer Kennung.**
            //
            // Vorher trugen Wurzel und Seitenstapel je eine eigene. Dann
            // verschwindet ein offener Seitenstapel schlagartig, während die
            // Wurzel darunter noch blendet. Ein Bereich ist ein Stück — was in
            // ihm offen war, geht mit ihm. **Die offene Bibliothek gehoert in
            // diese Kennung.**
            //
            // Hier stand `bereich` allein. Ein Wechsel zwischen den uebrigen
            // Bibliotheken aendert den Bereich aber nicht — die Kennung blieb
            // also gleich, das Stueck wurde nicht getauscht, und die
            // Fade-Through-Blende lief nie.
            //
            // Ich hatte es zuerst an der Wurzel selbst versucht, eine Ebene
            // tiefer. Das kann nicht wirken: beim Wechsel wird die Wurzel samt
            // ihren Modifikatoren weggeworfen und neu gebaut, ein `.animation`
            // an ihr kennt ihr eigenes Erscheinen also gar nicht. Anweisungen
            // fuer Ein- und Austritt gehoeren an das, was bleibt — und das ist
            // dieses Stueck hier.
            .id(wurzelkennung)
            // „Fade Through": das Alte blendet in 100 ms aus, danach kommt
            // das Neue in 200 ms und wächst dabei von 92 % auf 100 %. Die
            // Zahlen und das Warum stehen bei `Stil.zeitBereichHerein`.
            .transition(.bereichswechsel)
            // **Nur hier, nicht am Elternteil.** Genau daran ist der erste
            // Versuch gescheitert: eine Anweisung mit `value:` gilt für
            // alles, was sich im Unterbau ändert, und hat damals auch
            // Seitenversatz und Schleier mitbewegt — sichtbar als
            // Seitenschub samt Schattenkante, wo nichts fahren sollte. Hier
            // steht sie an dem Stück, das getauscht wird; darin gibt es
            // nichts zu bewegen, weil das alte seinen Stand behält und das
            // neue frisch gezeichnet wird.
            .animation(.default, value: wurzelkennung)
        }
        .onChange(of: navigator.seiten(bereich).count, initial: true) { alt, neu in
            guard neu != tiefe else { return }
            if neu > alt {
                // Tiefergehen macht die Seite selbst, siehe `onAppear` oben.
            } else {
                // Zurück: `Navigator.zurueck` animiert das Entfernen bereits,
                // der Mitgang muss im selben Zug zurück.
                withAnimation(Stil.zeitSeitenschub) { gezeigteTiefe[bereich] = neu }
            }
        }
    }

    @ViewBuilder
    private var wurzel: some View {
        if let bib = offeneBibliothek {
            Bibliotheksseite(model: model, bibliothek: bib)
        } else {
            bereichswurzel
        }
    }

    @ViewBuilder
    private var bereichswurzel: some View {
        switch bereich {
        case .start:  HomeView(model: model, stand: startseite)
        case .filme:  BibliothekView(model: model, art: "movies", titel: "Filme",
                                     regal: filmregal, gewaehlt: $filmbibliothek)
        case .serien: BibliothekView(model: model, art: "tvshows", titel: "Serien",
                                     regal: serienregal, gewaehlt: $serienbibliothek)
        case .suche:  SucheView(model: model)
        case .downloads: DownloadsView(model: model)
        case .merkliste: MerklisteView(model: model)
        }
    }

    @ViewBuilder
    private func seite(_ ziel: Seitenziel) -> some View {
        switch ziel {
        case let .titel(item):  DetailView(model: model, item: item) { zurueck() }
        case .seerr:            SeerrEinstellungenView(model: model, seerr: model.seerr) { zurueck() }
        case let .seerrTitel(t): SeerrDetailView(model: model, treffer: t) { zurueck() }
        // Nicht mehr erreichbar — eine Bibliothek ist eine Wurzel. Der Fall
        // steht hier, damit ein wiederhergestellter alter Stapel nicht bricht.
        case .bibliothek: Color.clear.onAppear { zurueck() }
        case .profil:           ProfilView(model: model) { zurueck() }
        // Nicht mehr erreichbar — die Merkliste ist ein Bereich. Der Fall
        // steht hier, damit ein wiederhergestellter alter Stapel nicht
        // bricht; er schliesst sich einfach.
        case .merkliste:        Color.clear.onAppear { zurueck() }
        case .einstellungen:    EinstellungenView(model: model) { zurueck() }
        case .wiedergabe:       WiedergabeEinstellungenView(model: model) { zurueck() }
        case .quickConnect:     QuickConnectView(model: model) { zurueck() }
        case .kontoHinzufuegen: KontoHinzufuegenView(model: model) { zurueck() }
        }
    }

    private func zurueck() { navigator.zurueck(in: bereich) }

    /// Eine Bibliothek aus der Seitenleiste: sie **wählt** die Sammlung und
    /// wechselt in deren Bereich. Die Wahl wird gemerkt, damit sie beim
    /// nächsten Öffnen noch gilt — dieselbe Stelle, die auch die Chips über
    /// dem Regal benutzen.
    private func bibliothekAusLeiste(_ bib: Item) {
        model.bibliothekWaehlen(bib, art: bib.collectionType ?? "")
        switch bib.collectionType {
        case "movies":  filmbibliothek = bib;   bereich = .filme
        case "tvshows": serienbibliothek = bib; bereich = .serien
        default:        break
        }
    }

    private func ausfuehren(_ kommando: Kommando) {
        switch kommando {
        case .start:  bereich = .start
        case .filme:  bereich = .filme
        case .serien: bereich = .serien
        case .suche:  bereich = .suche
        case .zurueck:
            zurueck()
        }
    }
}

// MARK: - Seitenleiste

extension HauptView {

    /// Bei einem Gerät sofort, bei mehreren erst fragen.
    fileprivate func abzeichenGedrueckt() {
        if uebernahme.mehrereDa { auswahlOffen = true }
        else if let eine = uebernahme.angebot { hierWeiterschauen(eine) }
    }

    /// Drüben beenden, hier an derselben Stelle weitermachen.
    ///
    /// Erst der Befehl, dann der Start — geht das Beenden schief, passiert
    /// hier gar nichts. Sonst liefen zwei Tonspuren im Raum.
    fileprivate func hierWeiterschauen(_ sitzung: Fremdsitzung) {
        auswahlOffen = false
        Task {
            guard let (titel, ab) = await uebernahme.uebernehmen(sitzung, model: model)
            else { return }
            steuerung.starte(titel, ab: ab)
        }
    }
}

struct Seitenleiste: View {
    let model: AppModel
    @Binding var bereich: Bereich
    /// Was auf einem anderen Gerät läuft — `nil`, wenn nichts.
    var uebernahme: Fremdsitzung?
    var uebernehmen: () -> Void
    let bibliothekWaehlen: (Item) -> Void
    /// Welche Sammlung der jeweiligen Gattung gerade gezeigt wird. Als
    /// Abfrage und nicht als Wert: die Stände liegen in `HauptView`, und die
    /// Leiste soll sie nicht doppelt führen.
    let gewaehlteBibliothek: (String) -> Item?
    let bibliothekOeffnen: (Item) -> Void
    /// Welche der uebrigen Bibliotheken gerade offen ist, wenn eine.
    let offeneKennung: String?
    private var bibliothekOffen: Bool { offeneKennung != nil }
    private func bibliothekSchliessen() { schliesseBibliothek() }
    let schliesseBibliothek: () -> Void
    let zumProfil: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Platz für die Fensterampel — sie liegt über der Seitenleiste.
            Color.clear.frame(height: Stil.ampelHoehe)

            Wortmarke(hoehe: 28)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(Bereich.obenGruppe, id: \.self) { fall in
                    Seitenleistenzeile(symbol: fall.symbol,
                                       beschriftung: fall.beschriftung,
                                       aktiv: bereich == fall && !bibliothekOffen) {
                        bereich = fall
                        bibliothekSchliessen()
                    }
                }
            }
            .padding(.horizontal, 12)

            Seitenleistenrubrik(text: "Meins")
                .padding(.horizontal, 12)
                .padding(.top, 26)
                .padding(.bottom, 8)

            VStack(spacing: 2) {
                ForEach(Bereich.meinsGruppe(downloads: model.downloadsAn), id: \.self) { fall in
                    Seitenleistenzeile(symbol: fall.symbol,
                                       beschriftung: fall.beschriftung,
                                       aktiv: bereich == fall && !bibliothekOffen) {
                        bereich = fall
                        bibliothekSchliessen()
                    }
                }
            }
            .padding(.horizontal, 12)

            // **Die Rubrik stand da, die Zeilen darunter fehlten.** Ein
            // Titel über nichts — beim Vergleich mit der Linux-Fassung
            // aufgefallen, wo die Sammlungen aufgeführt sind.
            //
            // Aufgeführt wird, was wir auch öffnen können: Filme und Serien.
            // Eine Musiksammlung stünde sonst da und führte ins Leere.
            if !sammlungen.isEmpty {
                Seitenleistenrubrik(text: "Bibliotheken")
                    .padding(.horizontal, 12)
                    .padding(.top, 26)
                    .padding(.bottom, 8)

                VStack(spacing: 2) {
                    ForEach(sammlungen, id: \.id) { bib in
                        // **Eine eigene Seite, kein Umschalter.** Vorher rief
                        // das hier `bibliothekWaehlen` — der Filme-Bereich
                        // sprang auf diese Sammlung um, und ueber "Filmabend"
                        // stand dann die Ueberschrift "Filme".
                        Seitenleistenzeile(symbol: bib.collectionType == "movies" ? "film" : "tv",
                                           name: bib.name,
                                           aktiv: offeneKennung == bib.id) {
                            bibliothekOeffnen(bib)
                        }
                    }
                }
                .padding(.horizontal, 12)

                // **Die Merkliste stand hier und steht jetzt oben bei den
                // Bereichen.** Sie war eine Seite, die von rechts hereinfuhr —
                // mit Zurueckpfeil, ohne Hervorhebung in der Leiste (`aktiv:
                // false` stand fest verdrahtet da), und auf einem Stapel, auf
                // den danach auch das Profil kam.
                //
                // Er hat recht, und die alte Begruendung war schief: dass ihre
                // Grenze der Haken ist, macht sie zu einer Bibliothek — und
                // Bibliotheken fahren hier auch nicht herein. Ein Ort in der
                // Leiste ist ein Ort, kein Weg.
            }

            Spacer(minLength: 0)

            // **Über der Trennlinie, nicht darunter.** Auf dem Mac gibt es
            // kein Profilbild oben rechts; die Seitenleiste endet mit dem
            // Konto. Das Angebot gehört daneben, wo man ohnehin hinsieht —
            // dieselbe Stelle wie das Abzeichen auf iPhone und Fernseher,
            // nur in der Form dieser Leiste.
            if let uebernahme {
                Button(action: uebernehmen) {
                    Uebernahmezeile(sitzung: uebernahme)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .transition(.opacity)
            }

            Divider().overlay(Stil.linie)

            // Kein `NavigationLink`: die Seitenleiste liegt **neben** dem
            // Stapel, nicht darin. Sie schiebt das Ziel deshalb selbst auf
            // den Stapel des sichtbaren Bereichs.
            Button { zumProfil() } label: { Profilzeile(model: model) }
                .buttonStyle(.plain)
                .padding(12)
        }
        .frame(width: Stil.seitenleisteBreite)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Stil.flaeche)
        .animation(.easeInOut(duration: 0.22), value: uebernahme?.id)
        .task { if model.views.isEmpty { await model.loadViews() } }
    }

    /// **Die Rubrik zeigt die uebrigen Bibliotheken.**
    ///
    /// Oben stehen Filme und Serien; die beiden Sammlungen, die diese Bereiche
    /// zeigen, gehoeren nicht noch einmal hierher.
    ///
    /// **Gefragt wird das Modell, nicht die Ansicht.**
    /// `model.gewaehlteBibliothek(art:)` liest die gemerkte Wahl aus den
    /// Einstellungen und faellt still auf die erste zurueck. Vorher stand hier
    /// `filmbibliothek`, also der Zustand der *Ansicht* — und der ist beim
    /// ersten Aufbau noch `nil`. Die Liste zeigte deshalb erst „Filme", und
    /// sobald die Bibliotheksseite ihre Wahl gesetzt hatte, sprang sie auf
    /// „Filmabend".
    ///
    /// Bleibt nichts uebrig, faellt die Rubrik ganz weg: dann *sind* Filme und
    /// Serien die Bibliotheken, und sie stehen schon oben.
    private var sammlungen: [Item] {
        let offen = Set([model.gewaehlteBibliothek(art: "movies")?.id,
                         model.gewaehlteBibliothek(art: "tvshows")?.id].compactMap { $0 })
        return model.views
            .filter { $0.collectionType == "movies" || $0.collectionType == "tvshows" }
            .filter { !offen.contains($0.id) }
    }

    /// Hervorgehoben wird eine Sammlung nur, wenn ihr Bereich auch offen ist
    /// — sonst stünden zwei Zeilen gleichzeitig im Akzent, ohne dass eine
    /// davon zu sehen wäre.
    private func istAktiv(_ bib: Item) -> Bool {
        switch bib.collectionType {
        case "movies":  bereich == .filme  && gewaehlteBibliothek("movies")?.id == bib.id
        case "tvshows": bereich == .serien && gewaehlteBibliothek("tvshows")?.id == bib.id
        default:        false
        }
    }
}

/// Wer angemeldet ist, und wo. Unten in der Seitenleiste — auf dem iPhone
/// sitzt dasselbe oben rechts als Profilzeichen.
struct Profilzeile: View {
    let model: AppModel
    @State private var schwebt = false

    var body: some View {
        HStack(spacing: 10) {
            zeichen
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: model.session?.userName ?? "—")
                    .font(Stil.kachelTitel)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                Text(verbatim: model.serverName ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(schwebt ? Stil.schrift.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: Stil.ecke))
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
    }

    /// **Bei mehreren Konten liegen zwei Kreise übereinander.** Das aktive
    /// vorn mit Akzentring, dahinter angeschnitten das nächste — der Rand in
    /// der Farbe der Leiste schneidet es frei, wie bei einer Gruppe von
    /// Teilnehmerbildern.
    ///
    /// Es bleibt bei **einem** zweiten Kreis, auch wenn es mehr Konten sind.
    /// Hier unten ist die Aussage „da ist noch eines" — welche und wie viele
    /// steht auf der Profilseite, einen Klick entfernt.
    @ViewBuilder
    private var zeichen: some View {
        let weitere = model.konten.first { $0.userID != model.session?.userID }
        HStack(spacing: -9) {
            Profilzeichen(name: model.session?.userName ?? "?",
                          bild: model.benutzerbildURL(groesse: 60), groesse: 26,
                          hervorgehoben: weitere != nil)
                // **Das verbundene Konto liegt oben.** Ein `HStack` mit
                // negativem Abstand zeichnet in der Reihenfolge der Auslage,
                // also läge sonst das zweite obenauf — und damit das Bild
                // vorn, an dem gerade niemand angemeldet ist.
                .zIndex(1)
                // Freigeschnitten wird das obere, nicht das untere: ein Saum
                // in der Farbe der Leiste, zwei Punkt breit, damit die beiden
                // Kreise sich nicht berühren. Er liegt hinter dem Bild, sonst
                // deckte er den Akzentring zu.
                .background { Circle().fill(Stil.flaeche).padding(-2) }
            if let weitere {
                Profilzeichen(name: weitere.userName,
                              bild: model.benutzerbildURL(fuer: weitere, groesse: 60),
                              groesse: 26)
                    .opacity(0.55)
            }
        }
    }

}

