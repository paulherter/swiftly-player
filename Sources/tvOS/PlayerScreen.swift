import GameController
import JellyfinKit
import SwiftUI
import VLCKit

/// Der Player — nach der Vorlage der iPhone-Fassung.
///
/// Oben rechts die Symbolknöpfe (Folgen, Einstellungen), unten links Titel
/// und Kontextzeile, unten rechts „Nächste Folge", darunter die Zeitleiste
/// mit den Zeiten links und rechts. Bild-im-Bild fällt weg — das gibt es auf
/// tvOS nicht.
///
/// **Der Fokus liegt auf der Zeitleiste, nicht auf einem Knopf.** Sie ist das
/// Werkzeug, das man im Player fast immer braucht; links und rechts springen,
/// nach oben kommt man zu den Knöpfen. Die Play/Pause-Taste der Fernbedienung
/// hält an — dafür gibt es bewusst keinen Knopf im Bild, so wie in Apples
/// eigenem Player auch.
struct PlayerScreen: View {
    let model: AppModel
    /// Der Titel beim Oeffnen. Die Videoflaeche haengt daran und darf sich
    /// nicht aendern — sonst legt SwiftUI sie neu an und der Strom faengt
    /// von vorn an.
    let startPlan: PlaybackPlan
    let startAt: Double
    /// Zumachen. Bewusst ein Rückruf und kein `dismiss`: der Player wird
    /// nicht als Blatt gezeigt, sondern als Auflage — siehe unten.
    let schliessen: () -> Void

    /// Laufender Titel — **aendert sich beim Wechsel zur naechsten Folge.**
    ///
    /// Stand hier `let`, wie es beim Bauen naheliegt, dann zeigte nach dem
    /// Wechsel alles weiter auf die alte Folge: Titel im Blatt, Folgenliste,
    /// und vor allem die Meldungen an den Server.
    @State private var item: Item
    @State private var plan: PlaybackPlan

    @State private var flaeche: VLCPlayerView?
    /// Zaehlt nur, solange das Schild an ist — siehe `Technikschild`.
    @AppStorage("technikschild") private var technikschild = false
    @State private var spielwerte: Spielwerte?
    @State private var position: Double
    /// Wann der Player geöffnet wurde — `Zeitannahme` braucht es, um
    /// Aufbauzucken von echter Bewegung zu unterscheiden.
    @State private var seitStart = Date()
    @State private var stelltWiederHer = false
    @State private var dauer: Double = 0
    @State private var laeuft = true
    @State private var erstesBildDa = false
    @State private var steuerungSichtbar = true
    @State private var ausblendMarke = 0
    /// Eine der drei Ebenen — Audio & Untertitel, Folgen, Einstellungen.
    @State private var offeneEbene: Playerebene?
    /// Vorschaubilder über der Leiste beim Spulen.
    @State private var trickplay = Trickplaybilder()
    @State private var spurenGesetzt = false
    @State private var startGemeldet = false
    /// Vorspann, Rückblick, Abspann — leer, wenn der Server nichts weiß.
    @State private var abschnitte: [JellyfinKit.Abschnitt] = []
    /// „Intro überspringen" und „Nächste Folge" über dem Bild, ohne Steuerung.
    /// Was wann zu sehen ist, steht in `Angebotsebene` im Paket.
    @State private var ebene = Angebotsebene()
    /// Der Wechsel laeuft schon — spiegelt den Riegel von `folgenwechsel`.
    @State private var wechselt = false
    @State private var folgenwechsel = Folgenwechsel()
    /// Zaehlt bei jedem Titelwechsel hoch; die Schleife setzt ihren Stand
    /// daraufhin ueber `Wiedergabetakt.neuerTitel` zurueck, wie auf iOS.
    /// Fehlte das, ueberlebte `seitMeldung` den Wechsel, und die erste
    /// Meldung der neuen Folge kam nach Sekunden statt nach zehn.
    @State private var titelwechsel = 0
    /// Startstelle einer Folge aus der Folgenebene, bis die Schleife sie übernimmt.
    @State private var startNachWechsel: Double?
    /// „Nächste Folge konnte nicht geladen werden." und Verwandte.
    @State private var hinweis: String?
    /// Der nächste Plan kommt aus einer Qualitätswahl — für den Hinweis.
    @State private var qualitaetGewechselt = false
    @State private var tempo: Float = 1.0
    /// Wiedergabetasten der Fernbedienung und die Anzeige im Kontrollzentrum.
    ///
    /// Auf dem Fernseher wiegt sie schwerer als am Telefon: die Siri Remote
    /// hat eigene Wiedergabetasten, und ohne Zentrale greifen sie ins Leere,
    /// sobald die App nicht vorn ist.
    @State private var zentrale = Wiedergabezentrale()
    /// **Der Schalter liegt in einer Klasse, nicht in der Ansicht.**
    ///
    /// Darin steht `zuletzt`, und das braucht es, weil **ein Tastendruck
    /// zweimal ankommt**: einmal als `onPlayPauseCommand` bei der
    /// fokussierten Ansicht, einmal als `togglePlayPauseCommand` der
    /// Wiedergabezentrale. Zwei Umschaltungen heben sich auf. Am Telefon
    /// faellt das nicht auf, dort gibt es nur den Weg ueber die Zentrale.
    ///
    /// Rueckrufe, die irgendwo liegenbleiben — bei der Wiedergabezentrale,
    /// beim System —, halten die Ansicht so fest, wie sie beim Eintragen war.
    /// Jedes `laeuft` darin ist der Stand von damals. Eine Klasse wird ueber
    /// die Verweisung gelesen und ist deshalb immer aktuell.
    @State private var schaltwerk = Schaltwerk()


    /// Das angepeilte Ziel, solange getippt wird — **getrennt von `position`**.
    ///
    /// Solange es steht, zeigt die Leiste das Ziel und nicht die laufende
    /// Stelle, und das Bild laeuft weiter.
    @State private var spulziel: Double?
    /// Wartet, bis das Tippen aufhoert, und springt dann einmal.
    @State private var spulAufgabe: Task<Void, Never>?
    /// Wann zuletzt ein Schritt kam. Daran haengt nur noch die Frage, ob
    /// gesammelt wird oder sofort gesprungen — die wachsende Schrittweite von
    /// frueher gibt es nicht mehr, siehe `springen`.
    @State private var letzterSchritt = Date.distantPast
    @State private var schlafminuten: Int?
    @State private var schlafAufgabe: Task<Void, Never>?
    /// Ob gerade ein Finger ueber die Flaeche zieht.
    ///
    /// Ein Wisch loest **auch** Schrittbefehle aus — dieselben, die der Ring
    /// beim Druck schickt. Ohne diese Unterscheidung spulte jeder Wisch
    /// zweimal: einmal ueber den Weg, einmal ueber den Schritt.
    @State private var wischt = false
    @State private var wischEnde = Date.distantPast
    /// Woher die Marke kommt. Eine erwischte Marke wartet auf den mittleren
    /// Knopf; eine ertippte springt von selbst, sobald das Tippen ruht.
    @State private var markeVomWisch = false
    /// Lief der Film, bevor das Schrubben ihn angehalten hat? Dann laeuft er
    /// nach dem Bestaetigen oder Verwerfen weiter — wie im Systemplayer.
    @State private var liefVorDemSchrubben = false
    /// Das Nachlaufen der Marke nach einem schnellen Wisch.
    @State private var ausrollen: Task<Void, Never>?
    /// Halten links/rechts auf dem Klickring: laeuft, solange gehalten wird.
    @State private var abtastAufgabe: Task<Void, Never>?
    @State private var tastet = false
    @State private var klickring = Klickring()
    /// Dieser Wisch hat die Steuerung geholt — und tut sonst nichts.
    ///
    /// **Der Wisch, der das Menü öffnet, spult nicht mit.** Vorher tat er
    /// beides: `wischBeginn` blendet die Steuerung ein, damit ist
    /// `steuerungDa` im selben Zug wahr, und die Bewegung desselben Fingers
    /// lief schon auf die Zeitleiste. Man wollte nur sehen, wo man ist, und
    /// stand danach woanders.
    @State private var wischNurGeoeffnet = false
    @State private var naechste: Item?
    /// Ein Sprung, bei dem VLC noch nicht angekommen ist — bis dahin zeigt die
    /// Leiste das Ziel (`Wiedergabetakt.Sprung`, Bug 17.09.2026).
    @State private var sprung: Wiedergabetakt.Sprung?
    /// Die Füllung der Karte als durchgehende Bewegung (`Fuellungsuhr`).
    @State private var fuellungsuhr = Fuellungsuhr()

    /// **Ob gerade etwas laedt, obwohl laufen sollte.**
    ///
    /// Drei Faelle, die alle drei aufgetreten sind und die vorher gleich
    /// aussahen — naemlich nach nichts: nach einem Sprung baut VLC den Strom
    /// neu auf; nach der Rueckkehr aus dem Hintergrund steht das Bild,
    /// waehrend der Ton schon laeuft; und bei einem Aussetzer der Leitung
    /// steht beides. „Aber ohne irgendwie 'n Ladezeichen oder so. Also da
    /// musst Du auf jeden Fall noch mal gucken."
    @State private var stockt = false
    @State private var stillSeit: Date?
    @State private var letzteVLCZeit: Double = -1

    /// **Wo der Fokus steht — und ob er ueberhaupt irgendwo steht.**
    ///
    /// Vorher war das ein `Bool` fuer die Leiste allein. Damit sah „auf dem
    /// Einstellungsknopf" genauso aus wie „nirgends", und das Zurueckholen im
    /// Stehen hat den Knopf jedesmal wieder weggerissen — man kam nicht mehr
    /// in die Einstellungen. Mit den Zielen als Aufzaehlung heisst `nil`
    /// wirklich „nirgends", und nur dann wird eingegriffen.
    @FocusState private var fokus: Fokusziel?
    /// Wohin der Fokus geht, wenn die Steuerung gleich erscheint — die
    /// Leiste, ausser „hoch" hat die Knoepfe oben verlangt.
    @State private var zielBeimZeigen: Fokusziel = .leiste
    /// Beim Verlassen der App wird angehalten — siehe unten.
    @Environment(\.scenePhase) private var phase

    enum Fokusziel: Hashable { case ruhe, leiste, spuren, einstellungen, folgen, angebot }

    init(model: AppModel, item: Item, plan: PlaybackPlan, startAt: Double,
         schliessen: @escaping () -> Void) {
        self.model = model
        self.startPlan = plan
        self.startAt = startAt
        self.schliessen = schliessen
        // **Nicht bei null anfangen.**
        //
        // Sonst steht der Balken kurz auf Anfang und springt sichtbar nach
        // vorn, sobald der Strom seine Stelle hat. Bei Serien fiel es kaum
        // auf, bei Filmen deutlich — die brauchen laenger zum Aufziehen.
        _position = State(initialValue: startAt)
        _item = State(initialValue: item)
        _plan = State(initialValue: plan)
    }

    private var steuerungDa: Bool {
        steuerungSichtbar && erstesBildDa && !ebeneOffen
    }

    private var ebeneOffen: Bool { offeneEbene != nil }

    /// **Die Einblendung über dem Bild** — nur ohne Steuerung und ohne Blatt.
    /// Bei offener Steuerung steht dasselbe Angebot unten in der Leiste.
    private var karteDa: Bool {
        ebene.anzeige.sichtbar && erstesBildDa && !steuerungDa
            && !ebeneOffen && !wechselt
    }

    /// **Der Angebotsknopf steht an einer Stelle, egal ob die Steuerung offen
    /// ist** (wie iOS, Paul 17.09.2026): Überspringen die ersten sechs
    /// Sekunden des Abschnitts, danach nur mit der Steuerung
    /// (`Angebotsebene.knopfdauer`); blendet er aus, wird `karteDa` falsch
    /// und der Fokus geht über `onChange(of: karteDa)` an die Ruhe. Die Karte bei geschlossener Steuerung, bei offener der normale
    /// Knopf „Nächste Folge". Die Leiste hält ihm nur den Platz frei.
    /// `karteDa` bleibt die Frage, ob er *ohne* Steuerung dasteht — daran
    /// hängen Fokus und Zurück.
    private var angebotDa: Bool {
        // Beim Spulen weicht sie der Vorschau über der Leiste.
        guard angebot.sichtbar, erstesBildDa, !ebeneOffen, !wechselt, spulziel == nil else { return false }
        return ebene.anzeige.sichtbar || (steuerungDa && angebot == .naechsteFolge)
    }

    /// Ob die Fokusruhe gerade dran ist: keine Steuerung, kein Blatt, keine
    /// Einblendung. Liegt die Einblendung da, gehört der Fokus ihr — sonst
    /// wandert er per Wischen auf die unsichtbare Fläche, und ein Klick hält
    /// an, statt zu überspringen.
    private var ruheDa: Bool { !steuerungDa && !ebeneOffen && !karteDa }

    var body: some View {
        ZStack {
            Color.black

            // **Ein Zuhause fuer den Fokus, auch wenn nichts zu sehen ist.**
            //
            // Drei Beschwerden, eine Ursache: `werkzeuge.opacity(0)` nimmt
            // die Bedienung nicht nur aus dem Bild, sondern **aus dem
            // Fokussystem**. Sobald sie nach vier Sekunden verschwand, stand
            // der Fokus im Nichts — und ohne Fokus nimmt tvOS ueberhaupt
            // keine Eingabe mehr an. Der Film lief weiter, die Fernbedienung
            // war tot, und die Menue-Taste fiel bis ans System durch: statt
            // den Player zu schliessen, verliess sie die App.
            //
            // Dasselbe galt **vor dem ersten Bild**, und genau deshalb ging
            // Zurueck in den ersten Sekunden auf den Apple-TV-Startbildschirm.
            // Wer frueh einmal angehalten hatte, merkte nichts davon: das
            // Ausblenden haengt an `laeuft`, im Stehen blieb die Steuerung
            // stehen und mit ihr der Fokus.
            //
            // Diese Ebene ist immer da und traegt den Fokus, wenn ihn sonst
            // niemand haelt. Fokussierbar nur dann — sonst nimmt sie ihn der
            // Leiste weg, sobald man sie braucht.
            Color.clear
                // **Und fokussierbar, solange sie ihn hat.** Wurde sie im
                // selben Zug unfokussierbar, in dem die Steuerung erschien,
                // und verwarf SwiftUI das Setzen auf die Leiste, sass der
                // Fokus auf einer Fläche, die keine Befehle mehr bekam:
                // hoch, links, rechts — nichts (22.09.). So kommt der
                // nächste Druck wieder hier an und holt die Steuerung.
                .focusable(ruheDa || fokus == .ruhe)
                .focused($fokus, equals: .ruhe)
                // **Hoch führt nach oben.** Der Fokus liegt nach dem Öffnen
                // noch hier, nicht auf der Leiste; ein Druck nach oben landete
                // erst auf der Leiste, erst der zweite bei den Knöpfen.
                .onMoveCommand { richtung in
                    if richtung == .up {
                        // Das Ziel wird vorgemerkt, gesetzt wird es beim
                        // Einblenden — siehe `onChange(of: steuerungDa)`.
                        zielBeimZeigen = .spuren
                        // Steht sie schon da, weil ein Setzen verworfen
                        // wurde, gibt es kein Einblenden mehr, das es
                        // nachholt — dann hier.
                        if steuerungDa { fokus = .spuren }
                        zeigen()
                    } else {
                        steuerungWecken()
                    }
                }
                .onTapGesture { steuerungWecken() }

            VideoFlaeche(url: startPlan.url, startAt: startAt,
                         container: startPlan.container,
                         puffer: model.pufferstufe,
                         untertitel: model.untertiteldateien(startPlan)) { neu in
                flaeche = neu
                // Was im Blatt unter „Bild" gewaehlt wurde, gilt auch fuer
                // die naechste Folge -- derselbe Schluessel wie die Geste
                // auf dem iPhone.
                neu.bildfuellend(UserDefaults.standard.bool(forKey: "bildfuellend"))
                neu.onWiederherstellung = { stelltWiederHer = $0 }
                // **Der Knopf haengt an VLCs Meldung, nicht am Druck.**
                //
                // Gemessen von der macOS-Sitzung: vom Klick bis VLC
                // „angehalten" meldet vergehen 17–25 ms, bis die Filmzeit
                // wirklich steht 26–36 ms. Im Druck gesetzt springt der Knopf
                // also **vor** dem Bild um, und das sieht aus wie ein Player,
                // der nicht reagiert. Am 500-ms-Takt waere er zu spaet.
                //
                // An dieser Meldung sind Knopf und Bild im selben Moment
                // still — der Abstand verschwindet nicht, weil er kleiner
                // wird, sondern weil es keine zwei Zeitpunkte mehr gibt.
                // Dem Server im selben Moment (T1-N1) — `model` hier
                // festgehalten, der Rueckruf lebt laenger als diese Ansicht.
                let melder = model
                neu.laeuftGemeldet = { [weak neu] an in
                    laeuftGemeldet(an)
                    melder.laufzustandGemeldet(laeuft: an, sekunden: neu?.positionSeconds ?? 0)
                }
                neu.sprungGemeldet = { ziel in melder.sprungGemeldet(ziel: ziel) }
                neu.spurenGemeldet = { spuren in melder.spurenGewaehlt(spuren) }
            }

            // **Deckend, nicht nur ein Ring.**
            //
            // Vorher stand hier `Lader()` allein — ein schwebender Ring ueber
            // dem laufenden Bild. VLC steuert die Fortsetzstelle erst nach dem
            // ersten Bild an, und in dieser Zeit war der Anfang des Films zu
            // sehen. Der Ladeschirm hat ihn nicht verdeckt, weil er nichts
            // verdeckte. Die iPhone-Fassung legt Schwarz darunter, seit jeher.
            // Der Moduswechsel gehoert hierher und **nicht** an
            // `erstesBildDa`: der Wert sagt „VLC liefert Bilder" und wird von
            // der geteilten Taktlogik gelesen — unter anderem, um `laeuft`
            // gegen VLC gleichzurichten. Wer ihn zum Anzeigeschalter umwidmet,
            // haelt bei einem haengenden Wechsel auch den Gleichrichter an.
            // Genau daran kann der verdrehte Pausezustand gelegen haben.
            if !erstesBildDa || Bildtakt.schaltetUm {
                ZStack {
                    Color.black
                    Lader.fern
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }

            // Liegt ueber allem und nimmt nichts an sich: der Erkenner
            // haengt am Fenster, nicht an dieser Flaeche.
            Wischfeld(beginnt: wischBeginn, bewegt: gewischt, endet: wischSchluss)
                .allowsHitTesting(false)

            // **Nur noch der Ring, kein Pausezeichen.** Angehalten zeigt die
            // Steuerung, die im Stehen stehen bleibt; ein Zeichen in der
            // Mitte gibt es im Entwurf nicht, bedient wird am Clickpad. Das
            // Pausezeichen lag ausserdem ueber dem Technikschild.
            if erstesBildDa, stockt || wechselt {
                Lader(groesse: 86, staerke: 7)
                    .frame(width: 190, height: 190)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
                    .zIndex(3)
            }

            schleier.opacity(steuerungDa ? 1 : 0)

            // **Das Technikschild.** Eine Auskunft, kein Bedienteil: nimmt
            // weder Fokus noch Eingaben. **Direkt auf dem Film** (Paul,
            // 22.09.2026): über dem Schleier, unter Titel, Knöpfen und Leiste
            // und damit auch unter den Ebenen. **Es gleitet mit der
            // Steuerung** (Paul, 22.09.2026): offen unter der Titelzeile, zu
            // an den oberen Rand, wo sie stand. Bewegung statt Blende, dieselbe
            // Kurve wie die Steuerung; mit reduzierter Bewegung springt es.
            //
            // **Ohne `.focusable(false)`.** Das klingt nach „nimmt keinen
            // Fokus", macht das Schild aber zu einem Fokusteilnehmer, der nie
            // fokussiert werden kann — und durch den Rahmen bis an alle Ränder
            // bedeckt er den ganzen Schirm. Die Fokussuche lief dagegen und
            // fand nichts mehr: bei eingeschaltetem Schild kam man von der
            // Leiste nicht zu den Knöpfen und zwischen den Knöpfen nicht
            // weiter (gemessen 22.09. im Simulator, Leiste hoch, Knopf
            // runter/rechts/links: mit Schild alle vier ohne Ziel, ohne Schild
            // und nach dem Entfernen alle vier am Ziel). Nicht fokussierbar
            // ist es ohnehin, es enthält nur Text.
            if technikschild {
                Technikschild(plan: plan, werte: spielwerte, flaeche: flaeche, fern: true)
                    .padding(.leading, Stil.randSeite)
                    .padding(.top, Stil.randOben + Playermass.knopf + Stil.kachelAbstand)
                    .offset(y: steuerungDa ? 0 : -(Playermass.knopf + Stil.kachelAbstand))
                    .animation(Stil.bewegungReduziert ? nil : .easeInOut(duration: 0.2),
                               value: steuerungDa)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            werkzeuge.opacity(steuerungDa ? 1 : 0)
                // Unter einer Ebene kein Fokusziel: sonst wandert der Fokus
                // seitlich aus der Ebene in die unsichtbare Steuerung.
                .disabled(ebeneOffen)

            // **Weich weg, nicht zack weg** — wie auf dem iPhone (c9298dd5):
            // das Entfernen aus dem Baum lief trotz Transition hart. Die Pille
            // bleibt im Baum, solange es ein Angebot gibt, und kommt und geht
            // über die Deckkraft. Die Fokussuche überspringt sie unsichtbar
            // schon selbst (gemessen 22.09., angehalten: Leiste hoch landet
            // bei den Knöpfen oben, mit und ohne Sperre). **`disabled` an der
            // Pille selbst** fängt den Rest: hält sie den Fokus noch, nimmt
            // sie keinen Klick — und `onChange(of: angebotDa)` gibt ihn ab.
            // Nicht `.focusable(false)` auf der Ebene: die reicht bis an alle
            // Ränder und sperrte die Fokussuche wie einst das Technikschild.
            if angebot.sichtbar {
                angebotsebene
                    .opacity(angebotDa ? 1 : 0)
                    .allowsHitTesting(angebotDa)
                    .accessibilityHidden(!angebotDa)
                    // Dieselbe Blende wie die Steuerung (`.animation` auf `steuerungDa`).
                    .animation(.easeInOut(duration: 0.2), value: angebotDa)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            // **Die drei Ebenen.** Vollbild über dem Bild, die Steuerung
            // darunter weicht (`steuerungDa`), der Ausblender ruht, Zurück
            // schliesst die Ebene und nicht den Player.
            if let offeneEbene {
                ebenenansicht(offeneEbene)
                    .transition(.opacity)
                    .zIndex(5)
            }

            stehenderTitel
                .zIndex(6)
        }
        .overlay(alignment: .bottom) {
            if let hinweis {
                Text(verbatim: hinweis)
                    // `.callout` ist Apples Stufe, nicht unsere — die Leiter
                    // kennt sie nicht. Fliesstext, also `Stil.koerper`.
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schrift)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, Stil.randOben)
                    .allowsHitTesting(false)
                    // Kein `.focusable(false)`: dasselbe wie beim
                    // Technikschild — es sperrt die Fokussuche über der
                    // Fläche, und die Leiste liegt direkt darüber.
                    // Sie steht nur Sekunden und ist nicht fokussierbar —
                    // ohne die Angabe liest VoiceOver sie nie vor.
                    .accessibilityAddTraits(.updatesFrequently)
                    .transition(.opacity)
            }
        }
        .animation(Stil.einblenden, value: hinweis)
        // **Gesagt, nicht nur gezeigt.** „Vorspann uebersprungen" und
        // „Keine Untertitel" erschienen und verschwanden, ohne dass
        // VoiceOver etwas davon mitbekam: die Meldung ist nicht
        // fokussierbar, also faehrt niemand hin.
        .onChange(of: hinweis) { _, neu in
            guard let neu else { return }
            AccessibilityNotification.Announcement(neu).post()
        }
        .animation(Stil.einblenden, value: technikschild)
        .task(id: technikschild) {
            guard technikschild else { return }
            while !Task.isCancelled {
                // Die Rate entsteht aus der Differenz zum letzten Mal —
                // siehe `Spielwerte`.
                spielwerte = Spielwerte(flaeche?.statistik, stelle: flaeche?.positionSeconds ?? 0,
                                        laeuft: flaeche?.isPlaying ?? false, vorher: spielwerte)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .ignoresSafeArea()
        // **Der Fokus kommt nicht von selbst.**
        //
        // Als Auflage ist der Player fuer die Fokusmaschine zunaechst
        // Dekoration: nichts darin ist gesetzt, und der Fokus bleibt, wo er
        // war. Die Folge war beides zugleich — keine Richtungstaste kam an,
        // also erschien nie eine Steuerung, und `onExitCommand` hing an
        // keiner fokussierten Ansicht, fiel also bis ans System durch. tvOS
        // hat die Menue-Taste dann als „App verlassen" verstanden.
        //
        // Im Navigationsstapel bekam der Player den Fokus geschenkt. Das war
        // geliehen, nicht gebaut.
        .focusSection()
        // Anfangs auf die Ruhe: die Leiste gibt es erst mit dem ersten Bild,
        // und eine Zuweisung auf etwas Unfokussierbares tut nichts.
        .onAppear { fokus = .ruhe }
        // **Der Fokus wandert mit der Steuerung**, statt mit ihr zu
        // verschwinden. Beim Oeffnen eines Blattes greift die Sperre: dort
        // nimmt das Blatt den Fokus, und wir haetten ihn ihm weggenommen.
        //
        // **Und beim Einblenden nachgefasst.** Die Zuweisung faellt in den
        // Durchlauf, in dem die Steuerung erst fokussierbar wird, und SwiftUI
        // verwirft sie manchmal — gemessen am 22.09.: der Fokus blieb auf der
        // Ruhe, die im selben Zug unfokussierbar wurde. Dort sass er fest:
        // hoch, links und rechts fanden kein Ziel, nichts reagierte. Wie bei
        // der Einblendung (`karteDa`) wird deshalb nachgesetzt, bis er sitzt.
        .onChange(of: steuerungDa) { _, da in
            guard !ebeneOffen else { return }
            guard da else { fokus = karteDa ? .angebot : .ruhe; return }
            let ziel = zielBeimZeigen
            zielBeimZeigen = .leiste
            fokus = ziel
            Task { @MainActor in
                for warten in [80, 250, 600] {
                    try? await Task.sleep(for: .milliseconds(warten))
                    guard steuerungDa, !ebeneOffen else { return }
                    guard fokus == nil || fokus == .ruhe else { return }
                    fokus = ziel
                    Protokoll.schreib("[Fokus] nachgesetzt auf \(ziel) nach \(warten) ms")
                }
            }
        }
        // **Eine ausgeblendete Pille hält den Fokus nicht.** Sie bleibt
        // zum weichen Ausblenden im Baum; lag der Fokus auf ihr, blieb er
        // dort — auf einem Knopf, den niemand sieht (gemessen 22.09. im
        // Simulator, angehalten: nach dem Ausblenden weiter `.angebot`).
        // Ohne Steuerung regelt das `onChange(of: karteDa)` darunter, bei
        // offener geht er auf die Leiste direkt unter der Pille.
        .onChange(of: angebotDa) { _, da in
            guard !da, steuerungDa, !ebeneOffen, fokus == .angebot else { return }
            fokus = .leiste
        }
        // **Die Einblendung nimmt den Fokus, und gibt ihn an die Fläche zurück.**
        //
        // Wie bei Streamyfin einen Takt später noch einmal: die erste
        // Zuweisung fällt in denselben Durchlauf, in dem der Knopf erst
        // eingehängt wird, und SwiftUI verwirft sie. Zurück geht er an die
        // Ruhe, nicht an die Leiste (Plezy #1890): sonst öffnet der nächste
        // Klick die Steuerung, statt anzuhalten.
        .onChange(of: karteDa) { _, da in
            Protokoll.schreib("[Angebot] \(da ? "ein" : "aus") \(ebene.anzeige)")
            if da {
                fokus = .angebot
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard karteDa else { return }
                    fokus = .angebot
                    Protokoll.schreib("[Angebot] Fokus \(String(describing: fokus))")
                }
            } else if !steuerungDa, !ebeneOffen {
                fokus = .ruhe
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard ruheDa else { return }
                    if fokus == nil || fokus == .angebot { fokus = .ruhe }
                    Protokoll.schreib("[Angebot] Fokus zurück \(String(describing: fokus))")
                }
            }
        }
        // **Nach dem Anhalten den Fokus zurueckholen.**
        //
        // kein Klick, keine Richtung, nichts. Das ist kein Play/Pause-Fehler,
        // sondern ein Fokusverlust: ohne fokussiertes Element nimmt tvOS
        // ueberhaupt keine Eingabe mehr an, und der Player steht als Standbild
        // da. Dieselbe Lehre wie heute Morgen — der Fokus kommt nicht von
        // selbst, er muss gelegt werden.
        .onChange(of: laeuft) { _, _ in
            guard !ebeneOffen else { return }
            fokus = .leiste
            // **Und noch einmal einen Takt spaeter.**
            //
            // Der Beweis kam von Genau das macht `steuerungWecken` — es legt
            // den Fokus zurueck auf die Leiste. Ohne Fokus nimmt tvOS keine
            // Eingabe entgegen, und der Player steht als Standbild da.
            //
            // Die Zuweisung oben allein reicht nicht: SwiftUI raeumt den Fokus
            // im selben Durchlauf noch auf und wirft sie weg. Deshalb danach
            // noch einmal, wenn sich alles gesetzt hat.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard !ebeneOffen else { return }
                fokus = .leiste
            }
        }
        // Die Einblendung hoert auf die gewollte Steuerung: beim Oeffnen steht
        // sie schon auf „an", und ihr erstes Ausblenden ist kein Blick hinein,
        // der „Rückblick überspringen" wegschicken duerfte.
        .onChange(of: steuerungSichtbar, initial: true) { _, offen in
            ebene.steuerung(offen: offen)
            fuellungStellen()
        }
        .onPlayPauseCommand { wiedergabetaste() }
        .onExitCommand {
            // Menue bricht zuerst das Spulen ab, nicht die Wiedergabe. Wer
            // sich verspult hat, will zurueck an seine Stelle — und nicht
            // aus dem Film heraus.
            if spulziel != nil { markeVerwerfen() }
            // Eine offene Ebene schliesst Zurück, nicht den Player.
            else if offeneEbene != nil { ebeneSchliessen() }
            // **Steht die Steuerung da, geht erst sie weg** — erst der
            // zweite Druck verlässt den Film. Wer sie nur aufgeweckt hat,
            // will weiterschauen, nicht hinaus.
            else if steuerungDa {
                steuerungSichtbar = false
                Protokoll.schreib("[Zurück] Steuerung aus")
            }
            // Zurück schließt nur die Einblendung, der Film läuft weiter.
            else if karteDa {
                ebene.schliessen()
                Protokoll.schreib("[Angebot] Zurück schließt")
            }
            else { verlassen() }
        }
        // **Nach einem Blatt muss die Steuerung zurueckkommen.**
        //
        // Ein Blatt nimmt den Fokus an sich. Geht es zu, ohne dass ihn
        // jemand wieder annimmt, steht er im Nichts — und dann kommt auch
        // kein Bewegungsbefehl mehr an, mit dem sich die Steuerung wecken
        // liesse. Der Balken war weg und blieb weg.
        .animation(.easeInOut(duration: 0.2), value: steuerungDa)
        .animation(.easeInOut(duration: 0.22), value: laeuft)
        .animation(.easeInOut(duration: 0.22), value: stockt)
        // **Wer die App verlaesst, will nicht weiterhoeren.**
        //
        // `onDisappear` greift hier nicht: die Ansicht verschwindet nicht,
        // wenn tvOS die App in den Hintergrund legt — sie bleibt stehen, und
        // VLC spielt weiter. Der Ton lief also auf dem Startbildschirm des
        // Apple TV weiter.
        //
        // Nur `.background`, nicht `.inactive`: das kommt auch beim kurzen
        // Einblenden des Systems, und dabei anzuhalten waere aufdringlich.
        //
        // Beim Zurueckkommen laeuft es **nicht** von selbst weiter. Wer
        // zurueckkommt, drueckt Wiedergabe — das ist eine Entscheidung, keine
        // Nebenwirkung.
        .onChange(of: phase) { _, neu in
            guard neu == .background, let flaeche, flaeche.isPlaying else { return }
            // **Erst melden, dann anhalten** (T3 #5): VLCs Rueckmeldung kaeme
            // womoeglich erst, wenn tvOS die App schon eingefroren hat, und
            // am Server stuende bis zu zehn Sekunden „spielt" mit alter Stelle.
            if startGemeldet, !wechselt {
                model.hintergrundMelden(item: item, plan: plan, seconds: position, paused: true)
            }
            flaeche.pause()
            laeuftSetzen(false)
            zeigen()
        }
        .onChange(of: schlafminuten) { _, neu in schlafzeitSetzen(neu) }
        .animation(.easeInOut(duration: 0.2), value: offeneEbene)
        .onAppear {
            model.playerOffen = true
            model.fernbefehl = ausfuehren
            // **Vor dem ersten Bild, nicht danach.** Der Server kennt die
            // Bildrate schon; der Fernseher kann also gleichzeitig mit dem
            // Aufbau des Stroms umschalten, statt hinterher. Was er nicht
            // sagt, holt der Takt spaeter aus VLCs Spuren nach.
            Bildtakt.anpassen(laut: plan.quelle.flatMap(Dateiangaben.videospur))
            klickring.beobachten(beginnt: haltenBeginnt, endet: haltenEndet)
        }
        .onDisappear {
            klickring.loesen()
            abtastAufgabe?.cancel()
            // Der Ausgang gehoert wieder der Oberflaeche, die auf 60 Hz
            // gezeichnet ist.
            Bildtakt.loesen()
            schlafAufgabe?.cancel()
            spulAufgabe?.cancel()
            model.fernbefehl = nil
            // Vor `stop()`: `position` ist der Stand der Ansicht, aber wer die
            // Zeilen tauscht, soll nicht über VLCs Null stolpern.
            model.fertigGeschaut(position: position, dauer: dauer)
            flaeche?.stop()
            zentrale.abgeben()
            model.playerOffen = false
            // Ueber den Wechsel: laeuft gerade einer, bricht er ab, und ist
            // der Start der neuen Folge unterwegs, geht der Stopp danach.
            let laufend = (item: item, plan: plan, stelle: position)
            folgenwechsel.schliessen {
                await model.reportStopped(item: laufend.item, plan: laufend.plan,
                                          seconds: laufend.stelle)
            }
        }
        .task { await beobachten() }
        .task { await nachschlagen(fuer: item) }
        // Je Titel einmal nachsehen, ob der Server Vorschaubilder hat.
        .task(id: item.id) { await trickplay.laden(model: model, item: item, plan: plan) }
        // Die Folgenebene soll beim Öffnen schon stehen.
        .task(id: item.id) {
            if hatFolgen { await FolgenEbene.vorladen(model: model, item: item) }
        }
        .onChange(of: dauer) { _, _ in zentraleMelden() }
        .task(id: ausblendMarke) {
            // Im Stehen nichts wegnehmen: wer angehalten hat, schaut gerade
            // nicht aufs Bild, sondern will wissen, wo er ist.
            guard steuerungSichtbar, laeuft else { return }
            // 8 s statt 4: die Leiste verschwand spuerbar schneller als bei
            // anderen Apple-TV-Clients (Swiftfin 10 s, 18.09.2026).
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, !ebeneOffen else { return }
            // Eine Marke, die niemand mehr sieht, ist keine Absicht mehr.
            // Bliebe sie stehen, zeigte die Leiste beim naechsten Einblenden
            // ihre alte Zeit statt des Stands — siehe `markeVerwerfen`.
            markeVerwerfen()
            steuerungSichtbar = false
        }

        // **Der Ausblender muss neu anlaufen, wenn VLC den Stand meldet.**
        //
        // Die Wippe befiehlt nur; `laeuft` setzt erst der Rueckruf 17-25 ms
        // spaeter (siehe `setzen`). `zeigen` stoesst die Aufgabe oben aber
        // sofort an — die liest dann noch den Stand von *vor* dem Druck und
        // faellt bei „fortsetzen" ueber `guard laeuft` heraus. Danach ruehrt
        // sich nichts mehr: die Marke aendert sich nur in `zeigen`, und die
        // Steuerung blieb stehen, bis
        //
        // iOS hatte die Zeile von Anfang an (`iOS/PlayerScreen.swift:401`),
        // tvOS nie — beim Ableiten uebersehen. Dort steht
        // `zentraleUebernehmen()` daneben; das braucht tvOS nicht, weil
        // `anhaltenOderWeiter` aus `schaltwerk` liest und nicht aus der
        // festgehaltenen Ansicht.
        // Pause hält auch die Füllung der Karte sofort an.
        .onChange(of: laeuft) { _, _ in ausblendMarke += 1; fuellungStellen() }
    }

    // MARK: - Schleier

    /// **Flach, ohne Verläufe** — rgba(11,11,13,.42) wie im Entwurf und auf
    /// dem iPhone. Ohne Abdunklung wären weiße Zeichen über hellen Szenen
    /// nicht zu erkennen.
    /// **Reines Schwarz** — `Stil.grund` hob im HDR-Modus des Fernsehers
    /// dunkle Szenen an, siehe `Ebenengrund`.
    private var schleier: some View {
        // **Die Flaeche traegt nur die Mitte, die Raender tragen Baender.**
        //
        // Hier stand 0,42 flach ueber dem ganzen Bild. Das erkauft Lesbarkeit
        // an zwei Raendern damit, dass die **Mitte des Films** dunkler wird,
        // sobald man die Steuerung zeigt — und auf einem Fernseher faellt das
        // staerker auf als auf einem Telefon. Dieselbe Loesung wie am iPhone:
        // eine leichte Flaeche fuer das Zeichen in der Mitte, dazu je ein
        // Verlaufsband oben und unten fuer Titel und Zeitzeile.
        //
        // Die Baender sind das Doppelte der iPhone-Masse (400 statt 200, 520
        // statt 260) — dieselbe Regel wie bei der Schrift.
        //
        // Als `overlay` auf der Flaeche zaehlen sie fuer die Groesse nicht
        // mit; am iPhone hat genau das den Player gesprengt, als sie in einem
        // Stapel standen.
        Color.black.opacity(0.30)
            .overlay(alignment: .top) {
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                       .init(color: .black.opacity(0.55), location: 0.45),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 400)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black.opacity(0.42), location: 0.55),
                                       .init(color: .black.opacity(0.62), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 520)
            }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: - Kopf und Leiste

    /// Bei einer Folge die Serie, sonst der Titel selbst.
    private var titelzeile: String {
        if item.type == "Episode", let serie = item.seriesName, !serie.isEmpty { return serie }
        return item.name
    }

    /// „Staffel 1 · Folge 3" — beim Film Jahr, Laufzeit und Genre.
    private var metatext: String? {
        if item.type == "Episode" {
            if let staffel = item.parentIndexNumber, let folge = item.indexNumber {
                return String(localized: "Staffel \(staffel) · Folge \(folge)")
            }
            return item.kontextzeile
        }
        let zeile = item.nebenzeile
        return zeile.isEmpty ? nil : zeile
    }

    /// Nur Folgen einer Serie haben eine Folgenliste.
    private var hatFolgen: Bool { item.type == "Episode" && item.seriesId != nil }

    /// Beim Spulen steht eine Marke — dann zählt nur die Leiste.
    private var spult: Bool { spulziel != nil }

    private var symbolanzahl: Int { hatFolgen ? 3 : 2 }

    /// **Oben links der Titel, unten die Leiste — dazwischen nichts.** Kein
    /// Pauseknopf und keine Sprungknöpfe in der Mitte: bedient wird am
    /// Clickpad. Kein Schliessen-Knopf: das macht die Zurück-Taste.
    private var werkzeuge: some View {
        VStack(alignment: .leading, spacing: 0) {
            kopf

            Spacer(minLength: 0)

            Zeitleiste(position: position, dauer: dauer, marke: spulziel,
                       zurueck: Double(model.zurueckSekunden),
                       vor: Double(model.vorSekunden),
                       springen: springen, wecken: zeigen, klick: klick,
                       laeuft: laeuft,
                       vorschau: { trickplay.bild(bei: $0, model: model) },
                       // Beide Grenzen, nicht nur der Anfang: wo der Vorspann
                       // anfaengt, sagt nicht, wo er aufhoert.
                       abschnittsgrenzen: abschnitte.flatMap { [$0.von, $0.bis] })
                .focused($fokus, equals: .leiste)
                // Die Leiste ist eine Zeichnung: die Stelle steht nur als
                // Balkenlaenge da. Ohne Wert bliebe sie stumm.
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Abspielstelle")
                .accessibilityValue(Text("\(Spielzeit.text(position)) von \(Spielzeit.text(dauer))"))
        }
        .padding(.horizontal, Stil.randSeite)
        .padding(.vertical, Stil.randOben)
    }

    /// Links Platz für den Titel und darunter die Metazeile, rechts die
    /// Symbole. Den Titel selbst zeigt `stehenderTitel`. Beim Spulen weichen
    /// die Symbole der Vorschau.
    private var kopf: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: Playermass.titelAbstand) {
                Text(verbatim: titelzeile)
                    .font(Playermass.titel)
                    .tracking(Stil.sperrungTitel)
                    .lineLimit(1)
                    .hidden()
                    .accessibilityHidden(true)
                HStack(spacing: 16) {
                    if let metatext { Text(verbatim: metatext) }
                    if !plan.isLossless {
                        Label(plan.method.rawValue, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Stil.warnung)
                    }
                }
                .font(Playermass.meta)
                .foregroundStyle(Stil.schriftLeise)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            symbolreihe
                .opacity(spult ? 0 : 1)
                .disabled(spult)
        }
        .focusSection()
    }

    /// Audio & Untertitel, Folgen (nur bei Folgen), Einstellungen.
    private var symbolreihe: some View {
        HStack(spacing: Playermass.knopfAbstand) {
            Symbolknopf(symbol: "captions.bubble", beschriftung: "Audio & Untertitel") {
                ebeneOeffnen(.spuren)
            }
            .focused($fokus, equals: .spuren)
            if hatFolgen {
                Symbolknopf(symbol: "rectangle.stack", beschriftung: "Folgen") {
                    ebeneOeffnen(.folgen)
                }
                .focused($fokus, equals: .folgen)
            }
            Symbolknopf(symbol: "slider.horizontal.3", beschriftung: "Einstellungen") {
                ebeneOeffnen(.einstellungen)
            }
            .focused($fokus, equals: .einstellungen)
        }
    }

    /// **Der Titel oben links, eine Ebene über allem.** Bei offener
    /// Folgenebene bleibt er genau hier stehen; läge er im Kopf, blendete er
    /// mit der Steuerung aus und in der Ebene wieder ein — er flackerte.
    private var stehenderTitel: some View {
        let da = steuerungDa || offeneEbene == .folgen
        return HStack(alignment: .top, spacing: 24) {
            Text(verbatim: titelzeile)
                .font(Playermass.titel)
                .tracking(Stil.sperrungTitel)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
            Spacer(minLength: 0)
            // Derselbe Platz wie die Symbole im Kopf, damit der Titel hier
            // genauso breit wird.
            Color.clear.frame(width: Playermass.symbolreihe(anzahl: symbolanzahl), height: 1)
        }
        .padding(.horizontal, Stil.randSeite)
        .padding(.top, Stil.randOben)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .opacity(da ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: da)
    }

    // MARK: - Ebenen

    private func ebeneOeffnen(_ ziel: Playerebene) {
        Protokoll.schreib("[Ebene] auf \(ziel)")
        offeneEbene = ziel
    }

    /// Zurück an den Knopf, der die Ebene geöffnet hat — eine Ebene ist kein
    /// Ortswechsel. Die Steuerung kommt wieder, der Ausblender läuft neu an.
    private func ebeneSchliessen() {
        guard let war = offeneEbene else { return }
        Protokoll.schreib("[Ebene] zu \(war)")
        offeneEbene = nil
        zeigen()
        let ziel: Fokusziel = switch war {
        case .spuren: .spuren
        case .folgen: hatFolgen ? .folgen : .leiste
        case .einstellungen: .einstellungen
        }
        fokus = ziel
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard offeneEbene == nil, steuerungDa else { return }
            fokus = ziel
        }
    }

    @ViewBuilder
    private func ebenenansicht(_ welche: Playerebene) -> some View {
        switch welche {
        case .spuren:
            SpurenEbene(flaeche: flaeche)
        case .einstellungen:
            EinstellungsEbene(flaeche: flaeche, schlafminuten: $schlafminuten, qualitaet: qualitaetswahl)
        case .folgen:
            FolgenEbene(model: model, item: item, titel: titelzeile) { folge in
                ebeneSchliessen()
                // Die laufende Folge wählen heißt: weiterschauen.
                guard folge.id != item.id else { return }
                wechsleZu(folge, ab: folge.fortsetzenAb ?? 0)
            }
        }
    }

    // MARK: - Überspringen

    /// **Der Angebotsknopf**, rechts direkt über der Leiste — bei offener wie
    /// geschlossener Steuerung an derselben Stelle. Beim Countdown füllt sich
    /// die Pille von links. Ein Klick führt aus, Zurück schließt nur die
    /// Einblendung.
    private var angebotsebene: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                angebotspille
                    .disabled(!angebotDa)
                    .focused($fokus, equals: .angebot)
                    // Ohne Steuerung holt eine Richtungstaste sie, sonst wäre der
                    // Fokus in der Pille gefangen. Eine Karte „Nächste Folge" ist
                    // damit abgesagt (`Angebotsebene.steuerung`), ein
                    // Überspringen-Knopf bleibt stehen. Bei offener Steuerung
                    // wandert der Fokus wie gewohnt.
                    .onMoveCommand { _ in
                        guard !steuerungDa else { return }
                        Protokoll.schreib("[Angebot] Richtung holt die Steuerung")
                        steuerungWecken()
                    }
                    .accessibilityValue(countdownAnteil.map {
                        _ in Text("Startet in \(ebene.countdownRest) Sekunden")
                    } ?? Text(verbatim: ""))
            }
        }
        .padding(.horizontal, Stil.randSeite)
        // Dieselben Maße wie die Leiste der Steuerung — so überlappt die
        // Pille sie nie, ob die Steuerung offen ist oder nicht.
        .padding(.bottom, Stil.randOben + Playermass.leiste + Playermass.ueberLeiste)
    }

    private var angebotspille: some View {
        Button(action: angebotAusfuehren) {
            // **Weiße Pille mit dem Überspringen-Zeichen** — für beide
            // Angebote, wie im Entwurf und auf dem iPhone. Die Beschriftung
            // entsteht als `String` im Paket; `verbatim` verhindert, dass sie
            // ein zweites Mal nachgeschlagen wird.
            HStack(spacing: 14) {
                Image(systemName: "forward.end.fill")
                Text(verbatim: angebot.beschriftung)
            }
        }
        .buttonStyle(PillenStil(fuellung: countdownAnteil == nil ? nil : fuellungsuhr))
        .accessibilityLabel(Text(verbatim: angebot.beschriftung))
    }

    private var countdownAnteil: Double? {
        if case let .karte(anteil) = ebene.anzeige { return anteil }
        return nil
    }

    /// Welcher Knopf gerade gilt. Dieselbe Regel wie auf iOS — sie steht im
    /// Paket, damit die vier Plattformen nicht auseinanderlaufen.
    private var angebot: Knopfangebot {
        // Waehrend des Wechsels kein Knopf — ein zweiter Druck hiess zwei Wechsel.
        guard !wechselt else { return .keiner }
        return Abschnittslogik.angebot(position: position, dauer: dauer,
                                abschnitte: abschnitte,
                                hatNaechsteFolge: naechste != nil)
    }

    private func angebotAusfuehren() {
        ebene.gedrueckt()
        Protokoll.schreib("[Angebot] gedrückt \(angebot)")
        switch angebot {
        case .keiner:
            break
        case let .ueberspringen(nach, _):
            sprungAusfuehren(nach)
        case .naechsteFolge:
            if let folge = naechste { wechsleZu(folge) }
        }
    }

    // MARK: - Befehle

    /// **Den Ausgang freigeben, bevor die Ansicht weggeht.**
    ///
    /// Der Fernseher braucht fuer den Moduswechsel ein paar Sekunden, in
    /// denen er schwarz ist. Stand die Freigabe in `onDisappear`, fiel das
    /// Schwarz auf die schon zurueckgekehrte Oberflaeche — man war wieder in
    /// der Uebersicht, und dann ging das Bild weg. Hier faellt es in den
    /// Uebergang, wo der Schirm ohnehin dunkel ist.
    ///
    /// `loesen` ist mehrfach aufrufbar; die Sicherung in `onDisappear` bleibt
    /// fuer die Wege, die hier nicht vorbeikommen.
    private func verlassen() {
        Bildtakt.loesen()
        schliessen()
    }

    /// Fokus zurueck auf die Leiste und die Steuerung zeigen.
    private func steuerungWecken() {
        fokus = .leiste
        zeigen()
    }

    private func zeigen() {
        steuerungSichtbar = true
        ausblendMarke += 1
    }

    /// Anhalten oder weiterspielen — **ein Weg fuer alles**.
    ///
    /// Zwei Dinge, die uns einen Nachmittag gekostet haben, sind hier
    /// ausdruecklich ausgeschaltet:
    ///
    /// 1. **Was das System schickt, entscheidet nichts.** Auf dem Apple TV
    ///    kommt der Druck auf die Wiedergabetaste ueber die Zentrale, und
    ///    tvOS waehlt selbst zwischen „abspielen", „anhalten" und
    ///    „umschalten". Es waehlte immer „anhalten": der erste Druck hielt
    ///    an, jeder weitere hatte nichts mehr zu tun. Deshalb fuehren jetzt
    ///    **alle drei** Befehle hierher, und hier wird umgeschaltet.
    ///
    /// 2. **Der Stand wird nicht aus der Ansicht gelesen.** `flaeche` ist
    ///    eine Klasse und sagt die Wahrheit, auch aus einem Rueckruf heraus,
    ///    der Wochen alt sein koennte. `laeuft` in einer festgehaltenen
    ///    Ansichtskopie sagt nur, was beim Eintragen galt.
    private func anhaltenOderWeiter(_ quelle: String = "Klick") {
        // **Nach dem eigenen Stand richten, nicht nach VLC** — siehe
        // `Schaltwerk.laeuft`. Aus der Klasse gelesen, nicht aus `@State`:
        // dieser Aufruf kommt auch aus festgehaltenen Rueckrufen.
        //
        // Und ohne den Zustand gleich mitzusetzen: die Wippe sagt nur „das
        // andere", also darf sie auch nur befehlen. Wie es ausgeht, meldet
        // VLC — siehe `laeuftGemeldet`.
        //
        // **Umgeschaltet wird gegen den gewollten Stand, nicht gegen VLCs
        // Meldung.** Die kommt erst nach dem Befehl; wer schnell zweimal
        // drückte, schaltete gegen den alten Stand — der zweite Druck
        // befahl noch einmal dasselbe und ging verloren.
        Protokoll.schreib("[Taste] \(quelle): \(schaltwerk.gewollt ? "anhalten" : "abspielen")")
        setzen(laeuft: !schaltwerk.gewollt, sofortAnzeigen: false)
    }

    /// **Die Wiedergabetaste der Fernbedienung.** Sie kommt zweimal an:
    /// hier und über die Wiedergabezentrale (`vonDerZentrale`). Dieser Weg
    /// gilt; der andere wird verworfen, wenn er in ihre Nähe fällt.
    private func wiedergabetaste() {
        schaltwerk.letzteTaste = Date()
        anhaltenOderWeiter("Wiedergabetaste")
    }

    /// **Befehle der Wiedergabezentrale — mit kurzer Wartezeit.**
    ///
    /// Vorher sperrte eine Frist von 0,4 s jeden zweiten Befehl, um den
    /// doppelt zugestellten Tastendruck abzufangen. Das schluckte auch echte
    /// schnelle Drücke. Und kam die Zentrale **zuerst**, entschied tvOS dort
    /// nach der Anzeige im Kontrollzentrum zwischen „abspielen" und
    /// „anhalten" — stand die noch auf dem alten Stand, befahl sie dasselbe
    /// noch einmal, und die Sperre verwarf danach den richtigen Druck.
    ///
    /// Jetzt wartet die Zentrale 150 ms und tritt zurück, wenn die Taste
    /// selbst in 300 ms Nähe angekommen ist. Ohne Taste — Kontrollzentrum,
    /// iPhone als Fernbedienung — kommt sie danach unverändert durch.
    private func vonDerZentrale(_ name: String, _ tun: @escaping () -> Void) {
        let an = Date()
        let werk = schaltwerk
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            let abstand = abs(werk.letzteTaste.timeIntervalSince(an))
            guard abstand > 0.3 else {
                Protokoll.schreib("[Taste] Zentrale \(name) verworfen, Taste \(Int(abstand * 1000)) ms daneben")
                return
            }
            Protokoll.schreib("[Taste] Zentrale \(name)")
            tun()
        }
    }

    /// **Ein Befehl, der nichts ändern würde, ist ein Umschalten.**
    ///
    /// Gemessen am 19.09.: Jeder Druck auf die Wiedergabetaste kommt auf
    /// **einem** Weg an — mal als Taste, mal über die Zentrale. Über die
    /// Zentrale entscheidet tvOS selbst zwischen „abspielen" und „anhalten",
    /// nach dem Stand, den es zuletzt gemeldet bekam. Der hinkt kurz nach
    /// einem Wechsel hinterher: nach „abspielen" per Taste kam ein halbe
    /// Sekunde später „abspielen" über die Zentrale — der Film lief schon,
    /// der Druck verpuffte. Wer drückt, will den Zustand wechseln; befiehlt
    /// die Zentrale den, der schon gilt, wird deshalb umgeschaltet.
    private func zentraleWill(laufen soll: Bool) {
        if soll == schaltwerk.gewollt {
            Protokoll.schreib("[Taste] Zentrale veraltet (\(soll ? "abspielen" : "anhalten")), schalte um")
            anhaltenOderWeiter("Zentrale")
        } else {
            setzen(laeuft: soll)
        }
    }

    /// Beide Haelften des Laufzustands zugleich: die Ansicht zeichnet aus
    /// `@State`, die Rueckrufe lesen aus der Klasse.
    private func laeuftSetzen(_ neu: Bool) {
        laeuft = neu
        schaltwerk.laeuft = neu
        schaltwerk.gewollt = neu
    }

    /// **VLCs Meldung.** Kurz nach einem Befehl ist sie dessen Echo oder das
    /// eines älteren; den gewollten Stand übernimmt sie erst danach — dann
    /// ist sie etwas, das VLC von selbst getan hat (Ende, Unterbrechung).
    private func laeuftGemeldet(_ neu: Bool) {
        laeuft = neu
        schaltwerk.laeuft = neu
        if Date().timeIntervalSince(schaltwerk.zuletzt) > 1 { schaltwerk.gewollt = neu }
    }

    /// Anhalten oder weiterlaufen — **absolut**, nicht umschaltend.
    ///
    /// Frueher liefen `abspielen`, `anhalten` und `umschalten` alle drei auf
    /// dasselbe Umschalten. Solange beide Seiten denselben Stand haben, faellt
    /// das nicht auf. Laufen sie auseinander, ist es der Grund, warum man es
    /// nicht mehr geradeziehen kann: das Telefon schickt „Pause", wir schalten
    /// auf Wiedergabe, und je oefter man drueckt, desto verdrehter wird es.
    ///
    /// Ein ausdruecklicher Befehl setzt deshalb einen Zustand; nur die Wippe
    /// auf der Fernbedienung schaltet um.
    ///
    /// `sofortAnzeigen` trennt Befehl von Anzeige: ein ausdrueckliches „spiel
    /// ab" oder „halt an" von aussen sagt, was gelten soll, und darf den
    /// Zustand setzen. Die Wippe sagt nur „das andere" — dort wartet die
    /// Anzeige auf VLCs Meldung.
    private func setzen(laeuft soll: Bool, sofortAnzeigen: Bool = true) {
        guard let flaeche else { return }
        // Im Schaltwerk, nicht im Zustand: sonst liest ein alter Rueckruf
        // einen alten Stand.
        schaltwerk.zuletzt = Date()
        schaltwerk.gewollt = soll
        // Anhalten/Weiter heisst „hier", nicht „dorthin" — die Marke wird
        // verworfen, nicht bestaetigt. Bestaetigen bleibt der mittlere Knopf.
        markeVerwerfen(fortsetzen: false)

        if soll { flaeche.resume() } else { flaeche.pause() }
        if sofortAnzeigen { laeuftSetzen(soll) }
        zentrale.standNachziehen(position: position, laeuft: soll, tempo: tempo)
        zeigen()
    }

    /// Ob VLC noch liefert, was es liefern soll.
    ///
    /// Zwei Anzeichen, weil es zwei Arten von Stocken gibt. **Die Zeit steht**
    /// — dann fehlen Daten, nach einem Sprung oder bei einem Aussetzer der
    /// Leitung. **Es gibt keine Bildausgabe** — dann laeuft der Ton weiter und
    /// nur das Bild steht; so kommt VLC aus dem Hintergrund zurueck, wenn ihm
    /// tvOS den Zugriff aufs Bild entzogen hat.
    ///
    /// Erst nach einer knappen Sekunde: jeder Sprung steht kurz, und ein
    /// Ladezeichen, das bei jedem Tastendruck aufblitzt, ist schlimmer als
    /// keins.
    private func stockungPruefen(_ flaeche: VLCPlayerView) {
        guard laeuft, erstesBildDa else {
            stillSeit = nil
            stockt = false
            letzteVLCZeit = flaeche.positionSeconds
            return
        }

        let jetzt = flaeche.positionSeconds
        if abs(jetzt - letzteVLCZeit) < 0.05 {
            stillSeit = stillSeit ?? Date()
        } else {
            stillSeit = nil
        }
        letzteVLCZeit = jetzt

        // **Nur die Uhr, nicht `zeigtBild`.**
        //
        // `hasVideoOut` sagt, ob ein Ausgabemodul haengt — nicht, ob Bilder
        // kommen. Als zweites Anzeichen genommen, haette ein Modul, das aus
        // anderen Gruenden nichts meldet, das Ladezeichen dauerhaft stehen
        // lassen. Ein Ladezeichen, das immer da ist, sagt nichts mehr aus.
        // Die stehende Uhr ist eindeutig: kommen keine Daten, kommt die Zeit
        // nicht voran.
        let zeitSteht = stillSeit.map { Date().timeIntervalSince($0) > 0.9 } ?? false
        let neu = zeitSteht || stelltWiederHer
        if neu != stockt {
            withAnimation(.easeInOut(duration: 0.22)) { stockt = neu }
        }
    }

    private func zentraleUebernehmen() {
        zentrale.uebernehmen(.init(
            // **Ausdrueckliche Befehle setzen, die Wippe schaltet um.**
            //
            // Vorher taten alle drei dasselbe. Das war richtig gegen das
            // Problem von damals — die Rueckrufe lasen einen eingefrorenen
            // Zustand, also durfte keiner von ihnen fragen. Inzwischen steht
            // der Stand im `Schaltwerk` und ist ueber die Verweisung immer
            // die Gegenwart; fragen ist also wieder erlaubt.
            //
            // Und noetig: umschaltende Befehle machen einen auseinander
            // gelaufenen Stand unheilbar. Wer am Telefon „Pause" drueckt und
            // Wiedergabe bekommt, kann es mit keiner Zahl von Versuchen
            // richten.
            abspielen:   { vonDerZentrale("abspielen") { zentraleWill(laufen: true) } },
            anhalten:    { vonDerZentrale("anhalten") { zentraleWill(laufen: false) } },
            umschalten:  { vonDerZentrale("umschalten") { anhaltenOderWeiter("Zentrale") } },
            springenAuf: { ziel in
                flaeche?.seek(toSeconds: ziel)
                gesprungen(auf: ziel)
            },
            vor:         { springen(Double(model.vorSekunden)) },
            zurueck:     { springen(-Double(model.zurueckSekunden)) },
            naechste:    naechste.map { folge in { wechsleZu(folge) } }))
        zentraleMelden()
    }

    private func zentraleMelden() {
        zentrale.melden(item: item, position: position, dauer: dauer, tempo: tempo,
                        laeuft: laeuft,
                        sprungweite: (model.zurueckSekunden, model.vorSekunden),
                        bildURL: model.sperrbildURL(for: item))
    }

    /// Spulen: sammeln, beschleunigen, **einmal** springen.
    ///
    /// Vier Regeln, und die dritte ist die, an der es zweimal gescheitert ist.
    ///
    /// 1. **Der erste Druck bei versteckter Steuerung zeigt sie nur.** Am
    ///    Telefon tippt man auf einen sichtbaren Knopf; hier drueckt man blind
    ///    eine Richtung, und dann darf nicht gleich gesprungen werden.
    ///
    /// 2. **Ein einzelner Druck springt sofort** — zehn zurueck, dreissig vor,
    ///    wie am Telefon. Frueher sammelte auch der einzelne Druck erst eine
    ///    Marke ein; man drueckte und es geschah nichts, bis man bestaetigte.
    ///
    /// 3. **Schnelles Tippen sammelt trotzdem.** VLC baut bei jedem Sprung den
    ///    Strom neu auf; ein Sprung je Druck liess den Player hoerbar durch
    ///    die Datei rauschen. Wer weitertippt, verschiebt darum nur die Marke,
    ///    und gesprungen wird einmal, sobald das Tippen ruht. Wie schnell das
    ///    war, steht nirgends mehr als Zahl da — es steht in den Zeiten unter
    ///    der Leiste.
    ///
    /// 4. **Wisch schlaegt Schritt.** Ein Wisch ueber die Flaeche erzeugt
    ///    dieselben Schrittbefehle wie ein Druck auf den Ring. Waehrend und
    ///    kurz nach einem Wisch bleibt der Schritt darum aus, sonst spulte
    ///    jeder Wisch zweimal.
    private func springen(_ sekunden: Double) {
        guard dauer > 0, !tastet else { return }
        guard steuerungDa else { zeigen(); return }
        guard !wischt, Date().timeIntervalSince(wischEnde) > 0.35 else { return }

        let seitLetztem = Date().timeIntervalSince(letzterSchritt)
        letzterSchritt = Date()
        zeigen()

        let ziel = min(max((spulziel ?? position) + sekunden, 0), dauer)

        // Eine erwischte Marke wartet auf den mittleren Knopf. Der Ring
        // verschiebt sie dann nur — er darf sie nicht hinter dem Ruecken
        // dessen bestaetigen, der noch am Suchen ist.
        if markeVomWisch {
            spulziel = ziel
            zeigen()
            return
        }

        spulAufgabe?.cancel()
        if spulziel == nil, seitLetztem > 0.45 {
            sprungAusfuehren(ziel)
            return
        }

        spulziel = ziel
        spulAufgabe = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let stelle = spulziel else { return }
            sprungAusfuehren(stelle)
        }
    }

    // MARK: - Halten

    /// **Halten links/rechts spult in Stufen**, wie im Systemplayer.
    ///
    /// Vorher sammelte Halten nur Einzelsprünge. Jetzt: nach einer halben
    /// Sekunde hält der Film an, die Marke läuft los — 10, dann 30, dann 90
    /// Sekunden Film je Sekunde, alle zwei Sekunden eine Stufe schneller.
    /// Loslassen springt dorthin und lässt weiterlaufen, Menü verwirft.
    ///
    /// **Die Marke, nicht die Abspielrate.** Apple spielt beim Vorspulen
    /// schneller ab; VLC kann das rückwärts gar nicht und bei 4K-HEVC im
    /// Direct Play vorwärts nur ruckelnd. So verhalten sich beide Richtungen
    /// gleich und der Decoder bleibt in Ruhe.
    private func haltenBeginnt(_ richtung: Int) {
        guard dauer > 0, !ebeneOffen else { return }
        abtastAufgabe?.cancel()
        abtastAufgabe = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            tastet = true
            spulAufgabe?.cancel()
            spulAufgabe = nil
            ausrollen?.cancel()
            if !liefVorDemSchrubben, schaltwerk.laeuft, let flaeche {
                flaeche.pause()
                laeuftSetzen(false)
                liefVorDemSchrubben = true
            }
            markeVomWisch = true
            if spulziel == nil { spulzielSetzen(sprung?.ziel ?? position) }
            let beginn = Date()
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(beginn)
                let tempo: Double = t < 2 ? 10 : (t < 4 ? 30 : 90)
                spulzielSetzen((spulziel ?? position) + Double(richtung) * tempo * 0.1)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func haltenEndet() {
        abtastAufgabe?.cancel()
        abtastAufgabe = nil
        guard tastet else { return }
        tastet = false
        if let ziel = spulziel { sprungAusfuehren(ziel) }
    }

    // MARK: - Wischen

    /// Der Finger auf der Flaeche setzt eine Marke, der mittlere Knopf
    /// bestaetigt sie — so machen es der Systemplayer und Infuse.
    private func wischBeginn() {
        guard dauer > 0, !ebeneOffen else { return }
        guard fokus == .leiste || fokus == .ruhe else { return }
        // **Vor `zeigen()` merken.** Danach ist `steuerungDa` wahr, und die
        // Frage „war sie schon da?" nicht mehr zu beantworten.
        wischNurGeoeffnet = !steuerungDa
        wischt = true
        zeigen()
    }

    /// **Langsam ziehen heisst treffen, schnell wischen heisst ankommen.**
    ///
    /// Ein fester Massstab taugt fuer keins von beidem: rechnet man die ganze
    /// Datei auf die Flaeche, verschiebt der kleinste Wackler eine halbe
    /// Minute; rechnet man fein, braucht ein Zweistundenfilm ein Dutzend
    /// Wische. Das Tempo des Fingers entscheidet, quadratisch gewichtet,
    /// damit die ruhige Hand die feine Stufe wirklich behaelt.
    private func gewischt(weg: CGFloat, tempo: CGFloat) {
        guard wischt, dauer > 0 else { return }
        guard steuerungDa else { zeigen(); return }
        // Dieser Finger hat die Steuerung geholt. Er darf sie wachhalten,
        // aber nicht spulen — dafür ist der nächste Wisch da.
        guard !wischNurGeoeffnet else { zeigen(); return }

        spulAufgabe?.cancel()
        spulAufgabe = nil
        ausrollen?.cancel()
        // **Schrubben haelt an, wie im Systemplayer.** Vorher lief der Film
        // weiter, waehrend die Leiste schon ganz woanders stand: Bild und
        // Ton sagten das eine, die Marke das andere (Paul, 18.09.2026 —
        // Vergleich mit Apples Player und Swiftfin, die beide anhalten).
        if !markeVomWisch, schaltwerk.laeuft, let flaeche {
            flaeche.pause()
            laeuftSetzen(false)
            liefVorDemSchrubben = true
        }
        markeVomWisch = true
        markeSchieben(weg: weg, tempo: tempo)
    }

    /// Die Marke um einen Fingerweg verschieben. Das Tempo des Fingers
    /// entscheidet, quadratisch gewichtet (siehe `gewischt`).
    private func markeSchieben(weg: CGFloat, tempo: CGFloat) {
        let fein = 0.10
        let grob = max(dauer / 1600, fein)
        let anteil = min(Double(abs(tempo)) / 3000, 1)
        let takt = fein + (grob - fein) * anteil * anteil
        spulzielSetzen((spulziel ?? position) + Double(weg) * takt)
    }

    /// Auch dann, wenn der Klick das Wischen schon entwaffnet hat: `wischEnde`
    /// haelt die Schrittbefehle zurueck, die derselbe Wisch ausgeloest hat.
    private func wischSchluss(tempo: CGFloat) {
        let rollt = wischt && markeVomWisch && spulziel != nil && abs(tempo) > 600
        wischt = false
        wischEnde = Date()
        wischNurGeoeffnet = false
        guard rollt else { return }
        // **Nach einem schnellen Wisch laeuft die Marke nach und bremst ab**
        // — wie bei Apple und Swiftfin (dort x0,78 alle 30 ms). Ohne das blieb
        // sie genau unter dem Finger stehen und wirkte hart.
        ausrollen?.cancel()
        ausrollen = Task {
            var v = tempo
            while !Task.isCancelled, abs(v) > 60, spulziel != nil {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled, spulziel != nil else { return }
                markeSchieben(weg: v * 0.03, tempo: v)
                v *= 0.78
            }
        }
    }

    /// Der mittlere Knopf.
    ///
    /// **Zwei Bedeutungen, wie beim Systemplayer.** Steht eine Marke, wird
    /// sie bestaetigt und erst dann gesprungen. Steht keine, haelt der Klick
    /// an oder laesst weiterlaufen.
    ///
    /// Vorher sprang der Player von selbst, sobald das Tippen 350 ms ruhte.
    /// Damit lief er die Folge in Schritten ab, statt an einer Stelle zu
    /// bleiben, bis man sich entschieden hat — und weil VLC bei jedem Sprung
    /// den Strom neu aufbaut, ruckelte er sich hoerbar durch.
    private func klick() {
        if let ziel = spulziel {
            sprungAusfuehren(ziel)
        } else {
            anhaltenOderWeiter()
        }
    }

    /// **Eine Marke darf den Stand nicht dauerhaft verdecken.**
    ///
    /// Die Leiste zeigt Zeit und Kopf an der Marke, solange eine steht, und
    /// dazwischen die helle Strecke bis zum wirklichen Stand. Bestaetigt oder
    /// verworfen wurde sie bisher nur mit dem mittleren Knopf oder Menue. Wer
    /// im Stehen den Daumen auf die Flaeche legte (Wisch → Marke an der
    /// aktuellen Stelle) und dann mit der Wiedergabetaste weiterspielte,
    /// behielt sie fuer den Rest des Films: Zeit eingefroren, Kopf bei 4 %,
    /// die helle Strecke wuchs mit dem Film mit — gemeldet von einem Apple TV
    /// (1.0.3, „Avatar", 7:24 nach 20 Minuten). VLC und `Zeitannahme` waren
    /// unschuldig: gegen einen Server, der ruhende Verbindungen nach 25 s
    /// schliesst, lief `time` nach der Pause lueckenlos weiter (16.09.2026).
    private func markeVerwerfen(fortsetzen: Bool = true) {
        spulAufgabe?.cancel()
        spulAufgabe = nil
        ausrollen?.cancel()
        ausrollen = nil
        spulziel = nil
        markeVomWisch = false
        // Verworfen heisst: zurueck an die alte Stelle und weiter wie vorher.
        if fortsetzen, liefVorDemSchrubben, let flaeche {
            flaeche.resume()
            laeuftSetzen(true)
        }
        liefVorDemSchrubben = false
    }

    /// Ziel setzen, anzeigen, Steuerung wachhalten — ohne zu springen.
    private func spulzielSetzen(_ roh: Double) {
        guard dauer > 0 else { return }
        let ziel = min(max(roh, 0), dauer)
        spulziel = ziel
        zeigen()
    }

    private func sprungAusfuehren(_ ziel: Double) {
        guard let flaeche else { return }

        let vorher = sprung?.ziel ?? position
        // **Vor `gesprungen` festhalten, ob der vorige noch unterwegs ist.**
        // `gesprungen` traegt den neuen Sprung als offen ein; wurde danach
        // gefragt, war immer einer offen — der eigene. Jeder Sprung wartete
        // dann auf sich selbst, bis der Deckel nach 3 s griff: die Zeit stand
        // sofort am Ziel, das Bild lief weiter und sprang erst Sekunden
        // spaeter (Paul, Apple TV, 18.09.2026).
        let vorigesZiel = sprung?.ziel
        gesprungen(auf: ziel)
        spulziel = nil
        markeVomWisch = false
        spulAufgabe?.cancel()
        spulAufgabe = nil
        ausrollen?.cancel()
        ausrollen = nil
        // Bestaetigt: springen und, wenn er vorher lief, weiterlaufen.
        if liefVorDemSchrubben {
            liefVorDemSchrubben = false
            flaeche.resume()
            laeuftSetzen(true)
        }

        // **Der Finger liegt beim Klick noch auf der Flaeche.**
        //
        // Auf der Fernbedienung ist der mittlere Knopf die Flaeche selbst: wer
        // klickt, drueckt sie herunter, und dabei rutscht sie ein Stueck.
        // Diese Nachzuckung kam als `changed` herein, setzte eine neue Marke —
        // und die Leiste blieb im Spulzustand stehen, mit eingefrorenen
        // Zeiten, bis man den Player verliess. Genau das hat
        //
        // Ein neuer Wisch faengt bei `began` wieder an; bis dahin ist er
        // entwaffnet.
        wischt = false
        wischEnde = Date()

        // Unter einer Sekunde ist es kein Sprung, sondern ein Neuaufbau des
        // Stroms fuer nichts.
        guard abs(ziel - vorher) >= 1 else { return }

        // **Nie zwei Spruenge uebereinander.**
        //
        // `seek(toSeconds:)` rechnet den Abstand aus VLCs **eigener** Zeit.
        // Solange der vorige Sprung nicht gelandet ist, steht die noch auf der
        // alten Stelle — der zweite rechnete von dort und landete zu weit.
        // Danach zog VLC sich wieder zurecht: erst lief es, dann sprang ein
        // Stueck, dann lief es weiter. Auch das hat
        if let vorigesZiel {
            spulAufgabe = Task {
                // **Warten, bis der vorige angekommen ist — nicht eine Frist
                // absitzen.** Gemessen an VLCs eigener Zeit, nicht an
                // `sprung`: den hat `gesprungen` oben schon auf das neue Ziel
                // gesetzt. Der Deckel ist nur dafuer da, dass ein Sprung, der
                // nie ankommt, den naechsten nicht verschluckt.
                let deckel = Date().addingTimeInterval(3)
                while !Task.isCancelled, Date() < deckel,
                      abs(flaeche.positionSeconds - vorigesZiel) > 2 {
                    try? await Task.sleep(for: .milliseconds(80))
                }
                guard !Task.isCancelled else { return }
                gesprungen(auf: ziel)
                flaeche.seek(toSeconds: ziel)
            }
            return
        }

        flaeche.seek(toSeconds: ziel)
    }

    /// **Jeder Sprung:** Leiste und Knopf stehen sofort auf dem Ziel, der Takt
    /// übergibt an VLCs Zeit, sobald VLC dort ist (Bug 17.09.2026).
    private func gesprungen(auf ziel: Double) {
        var stand = Wiedergabetakt.Stand(position: position, dauer: dauer)
        Wiedergabetakt.gesprungen(&stand, ziel: ziel)
        position = stand.position
        sprung = stand.sprung
        angebotNachziehen(vergangen: 0)
    }

    /// Die Einblendung an die angezeigte Stelle anpassen — mit `vergangen: 0`
    /// direkt nach einem Sprung, sonst einmal je Takt.
    @discardableResult
    private func angebotNachziehen(vergangen: Double) -> Bool {
        guard !wechselt else { return false }
        var neu = ebene
        let fertig = neu.takt(angebot: angebot,
                          karteFaellig: Abschnittslogik.karteFaellig(position: position, dauer: dauer,
                                                                     abschnitte: abschnitte,
                                                                     hatNaechsteFolge: naechste != nil),
                          // Nur zaehlen, solange man es sehen koennte:
                          // nicht unter dem Ladeschirm.
                          laeuft: laeuft && erstesBildDa && !Bildtakt.schaltetUm,
                          vergangen: vergangen,
                          countdown: Abschnittslogik.countdown(position: position, dauer: dauer))
        // Blendet der Überspringen-Knopf von selbst aus (`knopfdauer`), soll
        // er so weich gehen, wie er kam: der Takt läuft ohne Animation, also
        // den Wechsel der Sichtbarkeit hier ausdrücklich animieren.
        if neu.anzeige.sichtbar != ebene.anzeige.sichtbar {
            withAnimation(.smooth(duration: 0.34)) { ebene = neu }
        } else {
            ebene = neu
        }
        fuellungStellen()
        return fertig
    }

    private func fuellungStellen() {
        fuellungsuhr.stellen(anteil: countdownAnteil,
                             laeuft: laeuft && erstesBildDa && !Bildtakt.schaltetUm,
                             laenge: ebene.countdownLaenge)
    }

    /// Im laufenden Player zur nächsten Folge wechseln, statt zurück in die
    /// Übersicht zu springen.
    ///
    /// **Der Ablauf steht im Paket** (`Folgenwechsel`), gemeinsam mit iOS und
    /// macOS. Hier fehlte bisher der Riegel: ein zweiter Druck startete einen
    /// zweiten Wechsel, am Server blieben zwei Sitzungen offen (Audit
    /// 16.09.2026, T1-H1). Stopp und Plan liefen nacheinander statt
    /// nebeneinander, und ein gescheiterter Wechsel sagte nichts (T1-M6).
    /// - Parameter ab: Startstelle — aus der Folgenebene die Fortsetzstelle,
    ///   sonst der Anfang.
    /// Direct Play oder Obergrenze — nur, wenn vom Server gespielt wird und
    /// das Konto umwandeln darf.
    private var qualitaetswahl: Qualitaetswahl? {
        guard model.downloads.datei(fuer: item.id) == nil, model.umwandelnErlaubt else { return nil }
        return Qualitaetswahl(directPlay: model.immerDirectPlay, grenze: model.bitratenGrenze) { wert in
            let vorher = (model.immerDirectPlay, model.bitratenGrenze)
            if let wert {
                model.immerDirectPlay = false
                model.bitratenGrenze = wert
            } else {
                model.immerDirectPlay = true
            }
            guard vorher != (model.immerDirectPlay, model.bitratenGrenze) else { return }
            Protokoll.schreib("[Qualität] \(model.immerDirectPlay ? "Direct Play" : "\(model.bitratenGrenze) Mbit/s") — neu laden bei \(Int(position)) s")
            qualitaetGewechselt = true
            wechsleZu(item, ab: position)
        }
    }

    private func wechsleZu(_ folge: Item, ab: Double = 0) {
        guard !wechselt else { return }
        wechselt = true
        offeneEbene = nil
        // **Die Spulmarke gehoert der alten Folge.**
        //
        // Sie zeigt eine Stelle *in diesem* Titel an; die naechste Folge faengt
        // bei null an und weiss von ihr nichts. Blieb sie liegen, zeigte die
        // Zeitleiste im neuen Titel weiter die alte Zeit und den Knopf an
        // deren Fleck — die Anzeige stand still, waehrend das Bild lief.
        // Weggeraeumt wurde sie bisher nur per Klick, Menue, Anhalten oder
        // beim Ausblenden der Steuerung (`markeVerwerfen`), und das
        // Ausblenden ruht im Stehen: wer angehalten hat, wischt, oeffnet die
        // Folgenliste und waehlt die naechste Folge, nahm die Marke mit
        // hinueber. Dieselbe Sorte Rest wie am 16.09. an der Wiedergabetaste.
        markeVerwerfen()
        model.fertigGeschaut(position: position, dauer: dauer)
        let alt = (item: item, plan: plan, stelle: position)
        Task {
            let ergebnis = await folgenwechsel.ausfuehren(.init(
                stoppen: { await model.reportStopped(item: alt.item, plan: alt.plan,
                                                     seconds: alt.stelle) },
                planen: { await model.plan(for: folge.id) },
                anwenden: { neuerPlan in folgeAnwenden(folge, neuerPlan, ab: ab) },
                starten: { neuerPlan in await model.reportStart(item: folge, plan: neuerPlan,
                                                           seconds: ab) },
                gescheitert: {
                    hinweisZeigen(String(localized: "Nächste Folge konnte nicht geladen werden."))
                    // Die alte Folge laeuft weiter, der Server kennt sie aber
                    // schon als beendet. Die Schleife meldet sie neu an.
                    startGemeldet = false
                }))
            Protokoll.schreib("[Wechsel] \(ergebnis) → \(folge.id)")
            wechselt = false
            guard ergebnis == .gewechselt else { return }
            // Nach dem Wechsel steht der Fokus sonst im Nichts: die Folgen-
            // liste ist zu, und die Leiste hatte ihn nie.
            steuerungWecken()
            await nachschlagen(fuer: folge)
        }
    }

    /// Die neue Folge übernehmen — alles, was der alten gehörte, zurück.
    private func folgeAnwenden(_ folge: Item, _ neuerPlan: PlaybackPlan, ab: Double = 0) {
        // **Erst der Zustand, dann der Strom.**
        //
        // `item` und `plan` sind der laufende Titel, nicht der geoeffnete.
        // Bleiben sie stehen, meldet die Schleife weiter die alte Folge
        // an den Server, das Blatt zeigt ihren Namen, und die Folgenliste
        // hebt die falsche Zeile hervor.
        item = folge
        plan = neuerPlan
        // Grenze gewählt, aber es läuft das Original: entweder reicht die Datei
        // schon, oder der Server wandelt nicht um. Sagen statt schweigen.
        if qualitaetGewechselt {
            qualitaetGewechselt = false
            if !model.immerDirectPlay, neuerPlan.method == .directPlay {
                hinweisZeigen(String(localized: "Läuft in Originalqualität. Der Server wandelt nichts um."))
            }
        }

        // Ein neuer Titel in derselben Schleife: Stelle, Spuren, Startmeldung,
        // erstes Bild. `startGemeldet: true`, weil der Wechsel den Start meldet.
        var stand = Wiedergabetakt.Stand(position: position, dauer: dauer,
                                         laeuft: laeuft, erstesBildDa: erstesBildDa,
                                         spurenGesetzt: spurenGesetzt,
                                         startGemeldet: startGemeldet)
        Wiedergabetakt.neuerTitel(&stand, startGemeldet: true)
        position = stand.position
        sprung = stand.sprung
        spurenGesetzt = stand.spurenGesetzt
        startGemeldet = stand.startGemeldet
        erstesBildDa = stand.erstesBildDa
        // **Mitten in der Folge anfangen ist ein Sprung** — wie auf iOS. Die
        // Anzeige steht gleich auf der Startstelle und hält sie, bis VLC dort
        // ist; die Schleife setzt dasselbe nach ihrem Neuanfang.
        if ab > 0 {
            position = ab
            sprung = Wiedergabetakt.Sprung(ziel: ab)
            startNachWechsel = ab
        }
        titelwechsel += 1
        // **Die Uhr faengt von vorn an.**
        //
        // `Zeitannahme` misst alles gegen diesen Zeitpunkt. Blieb er auf dem
        // Oeffnen des Players stehen, galt die neue Folge vom ersten Takt an
        // als laengst aufgebaut — VLC meldete aber noch das Ende der alten.
        // Die Anzeige uebernahm es, und das Weiterschalten sprang sofort noch
        // einmal: von Folge drei auf fuenf.
        seitStart = Date()
        // **Nichts zeigt mehr auf die alte Folge** (T1-M4).
        naechste = nil
        abschnitte = []
        ebene.neueFolge()
        zentraleUebernehmen()

        // **Auch hier, sonst behaelt die naechste Folge die Stufe vom
        // Oeffnen.** Wer waehrend einer Folge umstellt, meint die
        // naechste mit — und `play` liest den Wert beim Aufsetzen.
        flaeche?.puffer = model.pufferstufe
        flaeche?.play(url: neuerPlan.url, abSekunden: ab, container: neuerPlan.container,
                      untertitel: model.untertiteldateien(neuerPlan))
    }

    /// Nächste Folge und Abschnitte zum laufenden Titel. Kommt ein Ergebnis
    /// erst nach dem nächsten Wechsel, verwirft es `Folgenwechsel`.
    private func nachschlagen(fuer titel: Item) async {
        await folgenwechsel.nachschlagen(holen: { await model.folgeNach(titel) },
                                         uebernehmen: { naechste = $0 })
        // **Die neue Folge hat eigene Abschnitte.** Ohne das truege sie
        // die des Vorgaengers, und der Knopf erschiene an dessen Stellen.
        await folgenwechsel.nachschlagen(holen: { await model.abschnitte(fuer: titel.id) },
                                         uebernehmen: { abschnitte = $0 })
        // Erst jetzt steht fest, ob es einen „Weiter"-Griff geben darf.
        zentraleUebernehmen()
    }

    /// Ein kurzer Hinweis unten im Bild, der von selbst geht.
    private func hinweisZeigen(_ text: String) {
        hinweis = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if hinweis == text { hinweis = nil }
        }
    }

    /// Befehle aus dem Jellyfin-Dashboard — und später vom iPhone, wenn die
    /// Wiedergabe übergeben wird.
    private func ausfuehren(_ befehl: Fernbefehl) {
        guard let flaeche else { return }
        switch befehl {
        case .pause:      markeVerwerfen(fortsetzen: false); flaeche.pause();  laeuftSetzen(false); zeigen()
        case .weiter:     markeVerwerfen(fortsetzen: false); flaeche.resume(); laeuftSetzen(true);  zeigen()
        case .umschalten: anhaltenOderWeiter("Fernbefehl")
        case .stopp:      verlassen()
        case .vor:        springen(Double(model.vorSekunden))
        case .zurueck:    springen(-Double(model.zurueckSekunden))
        case let .springenAuf(sekunden):
            gesprungen(auf: sekunden)
            flaeche.seek(toSeconds: sekunden)
            zeigen()
        case .naechste:
            if let folge = naechste { wechsleZu(folge) }
        case .vorige:
            break
        }
    }

    /// Hält nach so vielen Minuten an — und lässt den Player offen, damit
    /// man weiß, wo man war.
    private func schlafzeitSetzen(_ minuten: Int?) {
        schlafAufgabe?.cancel()
        guard let minuten else { return }
        schlafAufgabe = Task {
            try? await Task.sleep(for: .seconds(minuten * 60))
            guard !Task.isCancelled else { return }
            flaeche?.pause()
            laeuftSetzen(false)
            zeigen()
        }
    }

    // MARK: - Beobachten und melden

    private func beobachten() async {
        // Die Regeln stehen in `Wiedergabetakt`, geteilt mit den anderen
        // Plattformen. Hier bleibt nur, was der Fernseher anders macht.
        var stand = Wiedergabetakt.Stand()
        var letzterWechsel = titelwechsel
        var takte = 0

        var nurZeit = false
        while !Task.isCancelled {
            try? await Task.sleep(for: Wiedergabetakt.anzeigetakt)
            guard let flaeche else { continue }

            // **Dazwischen nur die Zeit**, wie auf iOS (Paul, 17.09.2026).
            nurZeit.toggle()
            if nurZeit {
                if !wechselt {
                    stand.position = position
                    stand.sprung = sprung
                    stand.erstesBildDa = erstesBildDa
                    Wiedergabetakt.zeitUebernehmen(&stand, gemeldet: stelltWiederHer ? flaeche.guteStelle : flaeche.positionSeconds,
                                                   amSchieben: false, seitStart: seitStart)
                    position = stand.position
                    sprung = stand.sprung
                }
                continue
            }

            // **Nur solange etwas offen ist.** Der Aufruf liest die
            // Spurliste, und die baut VLCKit jedesmal neu auf — im halben
            // Sekundentakt ist das kein Nachsehen mehr, sondern ein
            // Dauergriff in ein laufendes Medium. Sobald die Rate einmal
            // gemessen ist, bleibt VLC in Ruhe.
            if Bildtakt.nochNachzumessen {
                Bildtakt.anpassen(an: flaeche.player)
            }

            // **Angekommen heisst angekommen.** Ob VLC am Ziel eines Sprungs
            // steht, entscheidet `Wiedergabetakt` anhand von `stand.sprung`.
            // Der Riegel davor fiel nach 1,2 bzw. 2 s, auch wenn VLC noch nicht
            // da war, und die Leiste sprang zurueck (Bug 17.09.2026).

            stockungPruefen(flaeche)

            // Den Stand der Ansicht uebernehmen: Sprung, Folgenwechsel und
            // Anhalten aendern ihn zwischen zwei Takten.
            stand.position = position
            stand.sprung = sprung
            stand.dauer = dauer
            stand.laeuft = laeuft
            stand.erstesBildDa = erstesBildDa
            stand.spurenGesetzt = spurenGesetzt
            stand.startGemeldet = startGemeldet
            if titelwechsel != letzterWechsel {
                letzterWechsel = titelwechsel
                Wiedergabetakt.neuerTitel(&stand, startGemeldet: true)
                // Aus der Folgenebene mitten in eine Folge: siehe `folgeAnwenden`.
                if let ab = startNachWechsel {
                    startNachWechsel = nil
                    stand.nachWechsel = false
                    stand.position = ab
                    stand.sprung = Wiedergabetakt.Sprung(ziel: ab)
                }
            }

            let auftrag = Wiedergabetakt.rechnen(
                &stand,
                messung: .init(dauer: flaeche.durationSeconds,
                               position: flaeche.positionSeconds,
                               guteStelle: flaeche.guteStelle,
                               zeigtBild: flaeche.zeigtBild,
                               stelltEin: flaeche.stelltEin,
                               laeuft: flaeche.isPlaying,
                               // **Die Spurliste nur lesen, solange sie
                               // gebraucht wird.** `Wiedergabetakt` fragt
                               // `hatTonspuren` allein, bis die Spuren gesetzt
                               // sind; danach ist der Wert unbenutzt. Gelesen
                               // wurde er trotzdem -- zweimal je Sekunde, den
                               // ganzen Film lang. `player.audioTracks` baut die
                               // Liste jedes Mal neu auf, unter der Sperre des
                               // laufenden Players. Genau der Dauergriff, vor
                               // dem der Kommentar an `Bildtakt.nochNachzumessen`
                               // ein paar Zeilen weiter oben warnt; das `||`
                               // kuerzt ihn weg, sobald er nichts mehr traegt.
                               hatTonspuren: spurenGesetzt || !flaeche.tonspuren.isEmpty),
                stelltWiederHer: stelltWiederHer,
                // Am Fernseher liegt kein Finger am Regler.
                amSchieben: false,
                seitStart: seitStart)

            position = stand.position
            sprung = stand.sprung
            dauer = stand.dauer
            // **Der Takt ist der Gleichrichter.** `Wiedergabetakt` zieht den
            // Stand aus `flaeche.isPlaying` nach, sobald ein Bild steht —
            // beide Haelften muessen ihn bekommen, sonst driftet die Klasse
            // gegen die Ansicht und wir haetten den alten Fehler an neuer
            // Stelle.
            laeuftSetzen(stand.laeuft)
            spurenGesetzt = stand.spurenGesetzt
            startGemeldet = stand.startGemeldet

            // Waehrend des Moduswechsels ist der Ausgang schwarz. Den
            // Ladeschirm da wegzunehmen hiesse, ein totes Bild zu zeigen.
            if auftrag.ladeschirmWeg {
                withAnimation(.easeOut(duration: 0.3)) { erstesBildDa = true }
            }
            if auftrag.spurenAnwenden {
                flaeche.wendeSprachenAn(ton: model.tonSprache,
                                        untertitel: model.untertitelSprache,
                                        automatisch: model.untertitelAutomatisch,
                                        quelle: plan.quelle,
                                        titel: Spurgedaechtnis.titel(fuer: item))
            }
            // Waehrend des Wechsels schweigen, wie auf iOS: sonst geht nach dem
            // Stopp noch Fortschritt fuer die alte Folge hinaus (T1-M2).
            //
            // **Abgesetzt, nicht abgewartet** (T1-H2): hier stand `await`, und
            // die Zeitleiste stand, solange der Server nicht antwortete — ohne
            // Netz bis zu 20 s, beim Start bis zu 40.
            if auftrag.startMelden, !wechselt {
                // Die erreichte Stelle, nicht das Ziel: verfehlt der
                // Startsprung, stimmt sonst die erste Meldung nicht (T1-N7).
                model.reportStart(item: item, plan: plan, seconds: position)
            }
            if auftrag.fortschrittMelden, !wechselt {
                model.reportProgress(item: item, plan: plan,
                                     seconds: position, paused: !laeuft)
            }

            // **Im Stehen den Fokus halten.**
            //
            // Genau das bewirkt der Umweg ueber die Einstellungen: das Blatt
            // geht zu, und dabei legt `steuerungWecken` den Fokus zurueck auf
            // die Leiste — danach laesst sich wieder abspielen. Einmalig beim
            // Umschalten reichte das nicht; SwiftUI raeumt den Fokus danach
            // noch auf. Solange angehalten ist und kein Blatt offen steht,
            // wird er deshalb in jedem Takt neu gesetzt.
            //
            // Nur im Stehen: waehrend der Wiedergabe soll der Fokus auf die
            // Knoepfe oben wandern duerfen. Und nur, wenn er **nirgends**
            // steht — auf einem Knopf gehoert er dorthin.
            if !laeuft, !ebeneOffen, fokus == nil {
                fokus = .leiste
            }

            takte += 1
            // Die Anzeige braucht die Stelle nur im Sekundentakt.
            if takte % 2 == 0 {
                zentrale.standNachziehen(position: position, laeuft: laeuft, tempo: tempo)
                #if DEBUG
                // Herzschlag fuer den Messlauf (HauptView `-messlauf`): steht
                // der Takt, fehlen hier Zeilen.
                if ProcessInfo.processInfo.arguments.contains("-messlauf") {
                    Protokoll.schreib("[Takt] \(String(format: "%.1f", position)) laeuft \(laeuft)")
                }
                #endif
            }

            // **Die Einblendung.** Der Countdown laeuft nur, solange der Film
            // laeuft; im Stehen haelt er an.
            if angebotNachziehen(vergangen: Wiedergabetakt.taktlaenge / .seconds(1)),
               let folge = naechste {
                Protokoll.schreib("[Angebot] Countdown abgelaufen")
                wechsleZu(folge)
            }

            // Am Ende von selbst weiter — nur mit Karte (Abspann-Abschnitt vom
            // Server), und nicht, wenn sie abgesagt wurde. „Nächste Folge
            // automatisch" spielt dafuer keine Rolle mehr (Paul, 17.09.2026).
            if ebene.weiterAmEnde, let folge = naechste, !wechselt,
               // Erst wenn die neue Folge wirklich steht. Sonst zaehlt noch
               // die Zeit der alten, und die ist naturgemaess am Ende.
               erstesBildDa,
               Folgenende.weiterschalten(position: position, dauer: dauer,
                                         seitOeffnen: Date().timeIntervalSince(seitStart)) {
                wechsleZu(folge)
            }
        }
    }
}

// MARK: - Zeitleiste

/// Zeit links, Restzeit rechts, dazwischen die Leiste — der Aufbau der
/// iPhone-Fassung.
///
/// Sie ist das einzige fokussierbare Stück im unteren Bereich, und links und
/// rechts springen darauf. Ein Schieber, auf den man den Fokus erst legen
/// muss, wäre auf der Fernbedienung ein Weg zu viel.
///
/// **Im Stehen nur der Strich, beim Spulen Griff in Akzentfarbe** — die
/// einzige Stelle im Player, an der die Akzentfarbe auftaucht. Darüber das
/// Vorschaubild aus Jellyfins Trickplay mit der Zielzeit, ohne Trickplay nur
/// die Zeit.
struct Zeitleiste: View {
    /// Wo der Film wirklich steht.
    let position: Double
    let dauer: Double
    /// Das Ziel, solange eine Marke steht — beim Wischen und beim schnellen
    /// Tippen. `nil` heisst: die Leiste zeigt den Stand, nicht eine Absicht.
    let marke: Double?
    /// Aus den Einstellungen, nicht fest verdrahtet — dieselben Werte, die
    /// auch die Fernsteuerung benutzt.
    let zurueck: Double
    let vor: Double
    let springen: (Double) -> Void
    let wecken: () -> Void
    /// Der mittlere Knopf: bestaetigt eine Marke, sonst anhalten/weiter.
    let klick: () -> Void
    /// Angehalten steht das Pausezeichen vor der Zeit.
    var laeuft = true
    /// Das Trickplay-Bild zur Stelle, oder `nil`.
    var vorschau: (Double) -> CGImage? = { _ in nil }
    /// **Die Grenzen der Abschnitte in Sekunden — Kerben auf der Leiste.**
    ///
    /// Der Player laedt sie ohnehin, fuer die Ueberspringen-Karte und den
    /// Countdown; die Leiste wusste nichts davon. Eine Leiste mit Kerben sagt
    /// in einem Blick, wie der Film gebaut ist — wo der Vorspann endet, wo der
    /// Abspann anfaengt. Dieselbe Ergaenzung wie am iPhone.
    var abschnittsgrenzen: [Double] = []

    private var spult: Bool { marke != nil }

    /// Die Grenzen als Anteil, ohne die an den beiden Kanten: eine Kerbe
    /// direkt am Rand liest sich als Ausfransen.
    private func kerben() -> [Double] {
        guard dauer > 0 else { return [] }
        return abschnittsgrenzen.map { $0 / dauer }.filter { $0 > 0.01 && $0 < 0.99 }
    }
    /// Wohin der Griff zeigt: das Ziel, sonst der Stand.
    private var gezeigt: Double { marke ?? position }

    private func anteil(_ sekunden: Double) -> Double {
        guard dauer > 0 else { return 0 }
        return min(max(sekunden / dauer, 0), 1)
    }

    private var balkenHoehe: CGFloat { spult ? 12 : 8 }
    private let griff: CGFloat = 36

    var body: some View {
        HStack(spacing: 28) {
            // **Angehalten sieht man hier**, am Anfang der Leiste — nicht in
            // der Bildmitte, wo es über dem Technikschild lag. Nur das
            // Pausezeichen: wer läuft, braucht kein Zeichen dafür.
            HStack(spacing: 16) {
                if !laeuft {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(Stil.schrift)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
                Text(Spielzeit.text(position))
            }
            .animation(.easeInOut(duration: 0.18), value: laeuft)

            GeometryReader { rahmen in
                let breite = rahmen.size.width
                let stand = anteil(position)
                let ziel = anteil(gezeigt)

                ZStack(alignment: .leading) {
                    Capsule().fill(Playermass.leisteGrund)
                        .frame(height: balkenHoehe)

                    // Bis zur wirklichen Stelle: das ist gesehen.
                    Capsule().fill(Stil.schrift)
                        .frame(width: breite * min(stand, ziel), height: balkenHoehe)

                    // **Die Strecke zwischen Stand und Ziel.** Ohne sie sagt
                    // die Leiste beim Spulen nur, wo man hinwill — nicht, wie
                    // weit das von hier ist.
                    if spult {
                        Capsule().fill(Color.white.opacity(0.55))
                            .frame(width: breite * abs(ziel - stand), height: balkenHoehe)
                            .offset(x: breite * min(stand, ziel))
                    }

                    // **Kerben an den Abschnittsgrenzen.** Vier Punkt breit
                    // — auf drei Meter das Doppelte der iPhone-Kerbe —, in
                    // `grund`, weil sie sowohl auf der hellen Spur als auch
                    // auf dem weissen Balken zu sehen sein muessen.
                    ForEach(kerben(), id: \.self) { stelle in
                        Rectangle().fill(Stil.grund)
                            .frame(width: 4, height: balkenHoehe)
                            .offset(x: breite * stelle - 2)
                    }

                    Circle()
                        .fill(Stil.akzent)
                        .frame(width: griff, height: griff)
                        .scaleEffect(spult ? 1 : 0.4)
                        .opacity(spult ? 1 : 0)
                        .offset(x: breite * ziel - griff / 2)
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if spult { vorschauKasten(breite: breite, anteil: ziel) }
                }
            }
            .frame(height: Playermass.leiste)

            Text("−" + Spielzeit.text(max(dauer - position, 0)))
        }
        .font(.system(size: Playermass.zeit).monospacedDigit())
        .foregroundStyle(Stil.schriftLeise)
        .focusable()
        // Der mittlere Knopf landet auf der fokussierten Ansicht.
        .onTapGesture { klick() }
        .animation(.easeInOut(duration: 0.18), value: spult)
        .onMoveCommand { richtung in
            switch richtung {
            case .left:  springen(-zurueck)
            case .right: springen(vor)
            default:     wecken()
            }
        }
    }

    /// **Über dem Griff: Vorschaubild, darunter die Zeit.** Am Rand bleibt der
    /// Kasten ganz auf der Leiste stehen; ohne Trickplay nur die Zeit — kein
    /// leerer Kasten.
    private func vorschauKasten(breite: CGFloat, anteil: Double) -> some View {
        let bild = vorschau(gezeigt)
        let bildbreite: CGFloat = 400
        let bildhoehe = bildbreite * 9 / 16
        let zeitHoehe: CGFloat = 40
        let halb = bild == nil ? 70 : bildbreite / 2
        let x = min(max(breite * anteil, halb), max(breite - halb, halb))
        let hoehe = (bild == nil ? 0 : bildhoehe + 12) + zeitHoehe
        return VStack(spacing: 12) {
            if let bild {
                Image(decorative: bild, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: bildbreite, height: bildhoehe)
                    .clipShape(RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 2))
            }
            Text(Spielzeit.text(gezeigt))
                .font(.system(size: Playermass.vorschauZeit, weight: .semibold).monospacedDigit())
                .foregroundStyle(Stil.schrift)
                .frame(height: zeitHoehe)
        }
        .fixedSize()
        // Unterkante knapp über der Zeile der Leiste.
        .position(x: x, y: -hoehe / 2 - 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// **Die Überspringen-Pille: weiß, dunkle Schrift** — wie im Entwurf und auf
/// dem iPhone. Fokus hebt sie heraus; weiß bleibt sie in beiden Fällen.
struct PillenStil: ButtonStyle {
    /// Countdown: die Uhr der Füllung von links. `nil` ohne.
    var fuellung: Fuellungsuhr? = nil

    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration, fuellung: fuellung)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        let fuellung: Fuellungsuhr?
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .font(Stil.knopf)
                .foregroundStyle(Stil.grund)
                .padding(.horizontal, 32)
                .frame(height: 72)
                // **Der Countdown als Füllung, nicht als Zahl.** Dunkel auf
                // Weiß, nicht in Akzentfarbe: die gehört im Player allein dem
                // Griff der Leiste beim Spulen.
                .background {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous).fill(Stil.schrift)
                        if let fuellung {
                            TimelineView(.animation) { zeit in
                                GeometryReader { g in
                                    Rectangle()
                                        .fill(Stil.grund.opacity(0.16))
                                        .frame(width: g.size.width * fuellung.anteil(jetzt: zeit.date))
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
                }
                // **Kein Schatten.** BRAND 4: „Keine Schatten. Nicht am
                // iPhone, nicht am Fernseher unter der fokussierten Kachel,
                // nirgends." Lupe und Flaeche leisten es schon; ein weicher
                // Schatten wird auf drei Meter zu Schlamm.
                .scaleEffect(configuration.isPressed ? 0.97 : (fokus ? Stil.fokusLupe : 1))
                .animation(Stil.fokusAnimation, value: fokus)
        }
    }
}

// MARK: - Die Zeichenfläche

/// Hängt VLCs Bildfläche in SwiftUI ein.
///
/// Ohne `dismantleUIView` läuft der Wachhund-Timer der abgeräumten View
/// endlos weiter — dieselbe Falle wie auf dem iPhone. Auf `stop()` im
/// `onDisappear` ist kein Verlass: das trifft die View, auf die der Zustand
/// zeigt, nicht zwingend jede, die SwiftUI angelegt hat.
struct VideoFlaeche: UIViewRepresentable {
    let url: URL
    let startAt: Double
    let container: String?
    /// **Vor `play`, nicht danach.** Die Stufe geht als Startoption an
    /// libvlc; nachtraeglich gesetzt gilt sie erst beim naechsten Oeffnen.
    let puffer: Pufferstufe
    /// Externe Untertitel, ebenfalls vor `play` (T1-H4).
    var untertitel: [Untertiteldatei] = []
    /// Wo im Titel der gelieferte Strom beginnt — siehe `PlaybackPlan`.
    let angelegt: (VLCPlayerView) -> Void

    func makeUIView(context: Context) -> VLCPlayerView {
        let view = VLCPlayerView()
        view.puffer = puffer
        view.play(url: url, abSekunden: startAt, container: container, untertitel: untertitel)
        DispatchQueue.main.async { angelegt(view) }
        return view
    }

    func updateUIView(_ view: VLCPlayerView, context: Context) {}

    static func dismantleUIView(_ view: VLCPlayerView, coordinator: ()) {
        MainActor.assumeIsolated { view.stop() }
    }
}


/// Der Schalter des Players, als Klasse.
///
/// Alles, was ein liegengebliebener Rueckruf **lesen** muss, gehoert hierher.
/// `@State` in einer Ansicht wird beim Festhalten mitkopiert; eine Klasse
/// wird ueber ihre Verweisung gelesen und ist deshalb immer die Gegenwart.
@MainActor
final class Schaltwerk {
    /// Wann zuletzt ein Befehl an VLC ging.
    var zuletzt = Date.distantPast
    /// Wann die Wiedergabetaste zuletzt direkt ankam — gegen ihre zweite
    /// Zustellung über die Wiedergabezentrale.
    var letzteTaste = Date.distantPast
    /// **Was zuletzt gewollt war.** Danach richtet sich das Umschalten; VLCs
    /// Meldung (`laeuft`) kommt erst hinterher.
    var gewollt = true

    /// **Ob gerade laeuft — und zwar so, wie der Zuschauer es sieht.**
    ///
    /// Stand vorher nur als `@State` in der Ansicht, und `anhaltenOderWeiter`
    /// fragte stattdessen `flaeche.isPlaying`. Der Kommentar darueber sagte
    /// schon das Richtige — „nach `laeuft` richten, nicht nach VLC" —, der
    /// Code tat das Gegenteil.
    ///
    /// Die Folge hat `isPlaying` hinkt dem Befehl nach; wer danach fragt,
    /// waehlt die Richtung nach einem Stand, den es nicht mehr gibt, und
    /// schaltet zurueck, was er eben geschaltet hat. Baut VLC gerade seine
    /// Bildausgabe wieder auf, dauert das Nachhinken Sekunden statt
    /// Millisekunden — dann laeuft es endgueltig auseinander.
    ///
    /// Hier und nicht in der Ansicht, weil die Fernsteuerung aus
    /// festgehaltenen Rueckrufen liest. Siehe die Erklaerung oben an dieser
    /// Klasse.
    var laeuft = true
}

/// Die Wischfläche der Fernbedienung.
///
/// **Warum UIKit.** SwiftUI meldet vom Trackpad nur `onMoveCommand` — ein
/// Schritt je Wisch, ohne Weg und ohne Tempo. Zum Spulen braucht es die
/// Fingerbewegung selbst, und die gibt tvOS allein über einen
/// `UIPanGestureRecognizer` mit indirekten Berührungen heraus.
///
/// **Warum am Fenster.** Indirekte Berührungen haben keinen Ort auf dem Bild;
/// tvOS stellt sie der fokussierten Ansicht zu und lässt sie von dort die
/// Kette hinauflaufen. Eine Ebene im ZStack ist Geschwister der Leiste, nicht
/// ihr Vorfahr — dort käme nie etwas an. Das Fenster ist der einzige Punkt,
/// an dem beides zusammenläuft. Der Player füllt es ganz, und beim Abbau
/// nimmt `dismantleUIView` den Erkenner wieder weg.
struct Wischfeld: UIViewRepresentable {
    let beginnt: () -> Void
    /// Weg seit dem letzten Ruf und das Tempo, beides in Punkten.
    let bewegt: (CGFloat, CGFloat) -> Void
    let endet: (CGFloat) -> Void

    func makeUIView(context: Context) -> Traeger {
        let traeger = Traeger()
        traeger.isUserInteractionEnabled = false
        let erkenner = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Melder.gewischt(_:)))
        erkenner.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        // Der Fokus muss weiterlaufen: derselbe Wisch bewegt auch ihn, und
        // ein Erkenner, der die Berührung schluckt, legt die Bedienung lahm.
        erkenner.cancelsTouchesInView = false
        erkenner.delaysTouchesBegan = false
        erkenner.delegate = context.coordinator
        traeger.erkenner = erkenner
        return traeger
    }

    func updateUIView(_ traeger: Traeger, context: Context) {
        context.coordinator.eltern = self
    }

    static func dismantleUIView(_ traeger: Traeger, coordinator: Melder) {
        guard let erkenner = traeger.erkenner else { return }
        erkenner.view?.removeGestureRecognizer(erkenner)
    }

    func makeCoordinator() -> Melder { Melder(self) }

    /// Hängt den Erkenner ans Fenster, sobald es eines gibt.
    final class Traeger: UIView {
        var erkenner: UIPanGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let erkenner else { return }
            erkenner.view?.removeGestureRecognizer(erkenner)
            window?.addGestureRecognizer(erkenner)
        }
    }

    final class Melder: NSObject, UIGestureRecognizerDelegate {
        var eltern: Wischfeld
        private var letzte: CGFloat = 0
        /// Erst ein eindeutig waagerechter Wisch ist Spulen.
        private var aktiv = false

        init(_ eltern: Wischfeld) { self.eltern = eltern }

        /// **Nur waagerecht spult.** Vorher genuegte jede Beruehrung: wer nach
        /// oben wischte, um zu „Naechste Folge" oder den Einstellungen zu
        /// kommen, bekam die Spulmarke (Paul, 19.09.2026). Jetzt beginnt das
        /// Spulen erst nach 40 Punkten, die mindestens doppelt so weit zur
        /// Seite gehen wie nach oben oder unten. Alles andere bleibt dem Fokus.
        @objc func gewischt(_ erkenner: UIPanGestureRecognizer) {
            let t = erkenner.translation(in: nil)
            switch erkenner.state {
            case .began:
                aktiv = false
                letzte = 0
            case .changed:
                if !aktiv {
                    guard abs(t.x) > 40, abs(t.x) > abs(t.y) * 2 else { return }
                    aktiv = true
                    letzte = t.x
                    eltern.beginnt()
                    return
                }
                let weg = t.x - letzte
                letzte = t.x
                eltern.bewegt(weg, erkenner.velocity(in: nil).x)
            case .ended:
                if aktiv { eltern.endet(erkenner.velocity(in: nil).x) }
                aktiv = false
            case .cancelled, .failed:
                if aktiv { eltern.endet(0) }
                aktiv = false
            default:
                break
            }
        }

        // Neben dem Fokussystem, nicht statt seiner.
        func gestureRecognizer(_ erkenner: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith anderer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Liest den Klickring der Siri Remote direkt — gedrückt **und** losgelassen.
///
/// SwiftUIs `onMoveCommand` meldet nur einzelne Schritte; ob jemand hält,
/// erfährt es nicht. Über GameController kommt der Druck samt Stelle auf der
/// Fläche: links außen, rechts außen, oder Mitte (die bleibt dem Fokus).
@MainActor
final class Klickring {
    private var beginnt: ((Int) -> Void)?
    private var endet: (() -> Void)?
    private var beobachter: NSObjectProtocol?
    private var gehalten = false

    func beobachten(beginnt: @escaping (Int) -> Void, endet: @escaping () -> Void) {
        self.beginnt = beginnt
        self.endet = endet
        allesEinrichten()
        beobachter = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            // Nicht das Geraet aus der Nachricht weiterreichen — das kreuzt
            // die Aktorgrenze. Einfach alle neu einrichten; das ist billig
            // und idempotent.
            MainActor.assumeIsolated { self?.allesEinrichten() }
        }
    }

    func loesen() {
        if let beobachter { NotificationCenter.default.removeObserver(beobachter) }
        beobachter = nil
        for c in GCController.controllers() {
            c.microGamepad?.buttonA.pressedChangedHandler = nil
            c.microGamepad?.reportsAbsoluteDpadValues = false
        }
        beginnt = nil
        endet = nil
    }

    private func allesEinrichten() {
        GCController.controllers().forEach(einrichten)
    }

    private func einrichten(_ c: GCController) {
        guard let pad = c.microGamepad else { return }
        pad.reportsAbsoluteDpadValues = true
        pad.buttonA.pressedChangedHandler = { [weak self, weak pad] _, _, gedrueckt in
            let x = pad?.dpad.xAxis.value ?? 0
            DispatchQueue.main.async { self?.gedrueckt(x: x, an: gedrueckt) }
        }
    }

    private func gedrueckt(x: Float, an: Bool) {
        if an {
            guard abs(x) > 0.5 else { return }
            gehalten = true
            beginnt?(x < 0 ? -1 : 1)
        } else if gehalten {
            gehalten = false
            endet?()
        }
    }
}
