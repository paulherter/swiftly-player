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
    @State private var blattOffen = false
    @State private var folgenOffen = false
    @State private var spurenGesetzt = false
    @State private var startGemeldet = false
    /// Vorspann, Rückblick, Abspann — leer, wenn der Server nichts weiß.
    @State private var abschnitte: [JellyfinKit.Abschnitt] = []
    /// Der Wechsel laeuft schon — sonst loest der Takt ihn mehrfach aus.
    @State private var wechselt = false
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
    /// Dieser Wisch hat die Steuerung geholt — und tut sonst nichts.
    ///
    /// **Der Wisch, der das Menü öffnet, spult nicht mit.** Vorher tat er
    /// beides: `wischBeginn` blendet die Steuerung ein, damit ist
    /// `steuerungDa` im selben Zug wahr, und die Bewegung desselben Fingers
    /// lief schon auf die Zeitleiste. Man wollte nur sehen, wo man ist, und
    /// stand danach woanders. Paul: „der Player zum Skippen soll sich ja erst
    /// angesprochen fühlen, wenn das Menü da ist und man dann scrollt."
    @State private var wischNurGeoeffnet = false
    @State private var naechste: Item?
    /// Nach einem Sprung kurz nicht überschreiben, sonst zieht die Anzeige
    /// auf den alten Wert zurück, bevor VLC nachgezogen hat.
    ///
    /// **Die 1,2 s sind ein Deckel, keine Wartezeit** — und die Zahl selbst
    /// ist nicht gemessen. Der Takt löscht den Riegel, sobald VLC dort steht,
    /// wo er hinsollte (siehe `beobachten`); meist ist das viel früher. Nur
    /// wenn ein Sprung gar nicht ankommt, läuft die Frist ab.
    ///
    /// Auf iOS und macOS steht 2 s, und dort gibt es **keinen** frühen
    /// Rücksetzer — die Frist wird immer abgesessen. Die drei Zahlen sind
    /// deshalb nicht vergleichbar: verschieden ist nicht der Wert, sondern
    /// die Mechanik. Gemeldet; ob angeglichen wird, entscheidet `main`.
    @State private var sprungBis: Date?

    /// **Ob gerade etwas laedt, obwohl laufen sollte.**
    ///
    /// Drei Faelle, die Paul alle drei erwischt hat und die vorher gleich
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
    /// Beim Verlassen der App wird angehalten — siehe unten.
    @Environment(\.scenePhase) private var phase

    enum Fokusziel: Hashable { case ruhe, leiste, einstellungen, folgen }

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
        steuerungSichtbar && erstesBildDa && !blattOffen && !folgenOffen
    }

    /// Ob die Fokusruhe gerade dran ist: keine Steuerung, kein Blatt.
    private var ruheDa: Bool { !steuerungDa && !blattOffen && !folgenOffen }

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
                .focusable(ruheDa)
                .focused($fokus, equals: .ruhe)
                .onMoveCommand { _ in steuerungWecken() }
                .onTapGesture { steuerungWecken() }

            VideoFlaeche(url: startPlan.url, startAt: startAt,
                         container: startPlan.container) { neu in
                flaeche = neu
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
                neu.laeuftGemeldet = { laeuftSetzen($0) }
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
            // gegen VLC gleichzurichten. Wer ihn zum Anzeigeschalter
            // umwidmet, haelt bei einem haengenden Wechsel auch den
            // Gleichrichter an. Genau daran kann Pauls verdrehter
            // Pausezustand gelegen haben.
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

            if erstesBildDa {
                // **Dieselbe Stelle, dieselbe Groesse wie das Pausezeichen.**
                //
                // Pauls Vorschlag, und er ist richtig: „man koennte es genau
                // dahin machen, wo der Pauseknopf ist, sodass es so aussieht
                // wie, als wuerde es an exakt derselben Stelle laden." Zwei
                // Zustandsauskuenfte ueber dieselbe Sache gehoeren an
                // denselben Platz — sonst sucht das Auge zweimal.
                if stockt {
                    // **Ohne Teller.** Der Ring bringt seine Form selbst mit;
                    // ein Kreis um einen Kreis sieht aus wie ein Versehen.
                    // Das Pausezeichen braucht ihn, weil zwei Striche auf
                    // hellen Szenen sonst verschwinden. Paul: „warum ist die
                    // da? Die ist ganz komisch."
                    zeichenmitte(teller: false) { Lader(groesse: 86, staerke: 7) }
                } else if !laeuft {
                    zeichenmitte {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 76, weight: .medium))
                            .foregroundStyle(Stil.schrift)
                    }
                }
            }

            schleier.opacity(steuerungDa ? 1 : 0)
            werkzeuge.opacity(steuerungDa ? 1 : 0)

            if blattOffen, let flaeche {
                Wiedergabeblatt(flaeche: flaeche, plan: plan, titel: item.name,
                                offen: $blattOffen, tempo: $tempo,
                                schlafminuten: $schlafminuten)
                    .transition(.opacity)
            }

            if folgenOffen {
                Folgenblatt(model: model, item: item, offen: $folgenOffen) { folge in
                    wechsleZu(folge)
                }
                .transition(.opacity)
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
        .onChange(of: steuerungDa) { _, da in
            guard !blattOffen, !folgenOffen else { return }
            fokus = da ? .leiste : .ruhe
        }
        // **Nach dem Anhalten den Fokus zurueckholen.**
        //
        // Paul: „dann geht nix mehr" — kein Klick, keine Richtung, nichts.
        // Das ist kein Play/Pause-Fehler, sondern ein Fokusverlust: ohne
        // fokussiertes Element nimmt tvOS ueberhaupt keine Eingabe mehr an,
        // und der Player steht als Standbild da. Dieselbe Lehre wie heute
        // Morgen — der Fokus kommt nicht von selbst, er muss gelegt werden.
        .onChange(of: laeuft) { _, _ in
            guard !blattOffen, !folgenOffen else { return }
            fokus = .leiste
            // **Und noch einmal einen Takt spaeter.**
            //
            // Der Beweis kam von Paul: oeffnet man das Blatt und schliesst
            // es wieder, laesst sich danach abspielen. Genau das macht
            // `steuerungWecken` — es legt den Fokus zurueck auf die Leiste.
            // Ohne Fokus nimmt tvOS keine Eingabe entgegen, und der Player
            // steht als Standbild da.
            //
            // Die Zuweisung oben allein reicht nicht: SwiftUI raeumt den
            // Fokus im selben Durchlauf noch auf und wirft sie weg. Deshalb
            // danach noch einmal, wenn sich alles gesetzt hat.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard !blattOffen, !folgenOffen else { return }
                fokus = .leiste
            }
        }
        .onPlayPauseCommand { anhaltenOderWeiter() }
        .onExitCommand {
            // Menue bricht zuerst das Spulen ab, nicht die Wiedergabe. Wer
            // sich verspult hat, will zurueck an seine Stelle — und nicht
            // aus dem Film heraus.
            if spulziel != nil {
                spulAufgabe?.cancel()
                spulziel = nil
                markeVomWisch = false
            }
            else if blattOffen { blattOffen = false }
            else if folgenOffen { folgenOffen = false }
            else { verlassen() }
        }
        // **Nach einem Blatt muss die Steuerung zurueckkommen.**
        //
        // Ein Blatt nimmt den Fokus an sich. Geht es zu, ohne dass ihn
        // jemand wieder annimmt, steht er im Nichts — und dann kommt auch
        // kein Bewegungsbefehl mehr an, mit dem sich die Steuerung wecken
        // liesse. Der Balken war weg und blieb weg.
        .onChange(of: blattOffen) { _, offen in if !offen { steuerungWecken() } }
        .onChange(of: folgenOffen) { _, offen in if !offen { steuerungWecken() } }
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
            flaeche.pause()
            laeuftSetzen(false)
            zeigen()
        }
        .onChange(of: schlafminuten) { _, neu in schlafzeitSetzen(neu) }
        .animation(.easeInOut(duration: 0.2), value: blattOffen)
        .onAppear {
            model.fernbefehl = ausfuehren
            // **Vor dem ersten Bild, nicht danach.** Der Server kennt die
            // Bildrate schon; der Fernseher kann also gleichzeitig mit dem
            // Aufbau des Stroms umschalten, statt hinterher. Was er nicht
            // sagt, holt der Takt spaeter aus VLCs Spuren nach.
            Bildtakt.anpassen(laut: plan.quelle.flatMap(Dateiangaben.videospur))
        }
        .onDisappear {
            // Der Ausgang gehoert wieder der Oberflaeche, die auf 60 Hz
            // gezeichnet ist.
            Bildtakt.loesen()
            schlafAufgabe?.cancel()
            spulAufgabe?.cancel()
            model.fernbefehl = nil
            flaeche?.stop()
            zentrale.abgeben()
            Task { await model.reportStopped(item: item, plan: plan, seconds: position) }
        }
        .task { await beobachten() }
        .task {
            naechste = await model.folgeNach(item)
            abschnitte = await model.abschnitte(fuer: item.id)
            // Erst jetzt steht fest, ob es einen „Weiter"-Griff geben darf.
            zentraleUebernehmen()
        }
        .onChange(of: dauer) { _, _ in zentraleMelden() }
        .task(id: ausblendMarke) {
            // Im Stehen nichts wegnehmen: wer angehalten hat, schaut gerade
            // nicht aufs Bild, sondern will wissen, wo er ist.
            guard steuerungSichtbar, laeuft else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !blattOffen, !folgenOffen else { return }
            steuerungSichtbar = false
        }
    }

    /// **Das Zeichen fuer „steht" gehoert in die Mitte, nicht an den Rand.**
    ///
    /// Erster Anlauf war ein kleines Dreieck/Doppelstrich links vor der
    /// verstrichenen Zeit — dort, wo der Systemplayer es hat. Paul: „die
    /// Anzeige links ob es laeuft oder nicht find ich Quark." Er hat recht:
    /// am Fernseher sitzt man drei Meter weg und sieht auf das Bild, nicht
    /// auf die Leiste. Ein Standbild sieht aus wie eine ruhige Einstellung,
    /// und die Antwort darauf muss dort stehen, wo man hinschaut.
    ///
    /// Es bleibt stehen, solange es steht — es ist kein Hinweis auf einen
    /// Tastendruck, sondern eine Zustandsauskunft.
    private func zeichenmitte<Inhalt: View>(teller: Bool = true,
                                           @ViewBuilder _ inhalt: () -> Inhalt) -> some View {
        inhalt()
            .frame(width: 190, height: 190)
            .background(teller ? Color.black.opacity(0.42) : .clear, in: Circle())
            .overlay(Circle().strokeBorder(teller ? Color.white.opacity(0.14) : .clear))
            .shadow(color: .black.opacity(teller ? 0.45 : 0), radius: 30)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.86)))
            .zIndex(3)
    }

    // MARK: - Schleier

    /// Abdunkeln plus Verlauf oben und unten. Ohne das sind weiße Symbole über
    /// hellen Szenen nicht zu erkennen — dieselbe Begründung wie auf iOS.
    private var schleier: some View {
        ZStack {
            Color.black.opacity(0.28)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.62), location: 0),
                .init(color: .black.opacity(0), location: 0.26),
                .init(color: .black.opacity(0), location: 0.58),
                .init(color: .black.opacity(0.82), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Knöpfe und Leiste

    private var werkzeuge: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Spacer(minLength: 0)
                if naechste != nil {
                    Button { folgenOffen = true } label: {
                        Image(systemName: "list.and.film")
                    }
                    .buttonStyle(KnopfStil(nurSymbol: true))
                    .focused($fokus, equals: .folgen)
                }
                Button { blattOffen = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(KnopfStil(nurSymbol: true))
                .focused($fokus, equals: .einstellungen)
            }
            .focusSection()

            Spacer(minLength: 0)

            fuss
        }
        .padding(.horizontal, Stil.randSeite)
        .padding(.vertical, Stil.randOben)
    }

    private var fuss: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom, spacing: 40) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Stil.schrift)
                        .lineLimit(1)
                    if let kontext = item.kontextzeile {
                        Text(kontext)
                            .font(Stil.koerper)
                            .foregroundStyle(Color.white.opacity(0.68))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                // **Wann welcher Knopf gilt, entscheidet `Abschnittslogik`.**
                //
                // Frueher stand hier nur „Naechste Folge", und der erschien
                // erst kurz vor Schluss. Seit den Abschnitten kann derselbe
                // Platz auch „Vorspann ueberspringen" tragen — also am Anfang
                // statt am Ende. Die Regel steht im Paket, damit die vier
                // Plattformen nicht auseinanderlaufen.
                if angebot.sichtbar {
                    Button(action: angebotAusfuehren) {
                        HStack(spacing: 10) {
                            Image(systemName: angebot.zeichen)
                            // Die Beschriftung entsteht als `String` im Paket;
                            // `verbatim` verhindert, dass sie ein zweites Mal
                            // nachgeschlagen wird.
                            Text(verbatim: angebot.beschriftung)
                        }
                    }
                    .buttonStyle(PillenStil())
                }
            }

            Zeitleiste(position: position, dauer: dauer, marke: spulziel,
                       zurueck: Double(model.zurueckSekunden),
                       vor: Double(model.vorSekunden),
                       springen: springen, wecken: zeigen, klick: klick)
                .focused($fokus, equals: .leiste)
                // Die Leiste ist eine Zeichnung: die Stelle steht nur als
                // Balkenlaenge da. Ohne Wert bliebe sie stumm.
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Abspielstelle")
                .accessibilityValue(Text("\(Spielzeit.text(position)) von \(Spielzeit.text(dauer))"))
        }
    }

    /// Welcher Knopf gerade gilt. Dieselbe Regel wie auf iOS — sie steht im
    /// Paket, damit die vier Plattformen nicht auseinanderlaufen.
    private var angebot: Knopfangebot {
        Abschnittslogik.angebot(position: position, dauer: dauer,
                                abschnitte: abschnitte,
                                hatNaechsteFolge: naechste != nil)
    }

    private func angebotAusfuehren() {
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
    private func anhaltenOderWeiter() {
        // **Nach dem eigenen Stand richten, nicht nach VLC** — siehe
        // `Schaltwerk.laeuft`. Aus der Klasse gelesen, nicht aus `@State`:
        // dieser Aufruf kommt auch aus festgehaltenen Rueckrufen.
        //
        // Und ohne den Zustand gleich mitzusetzen: die Wippe sagt nur „das
        // andere", also darf sie auch nur befehlen. Wie es ausgeht, meldet
        // VLC — siehe `laeuftGemeldet`. Die Sperre von 0,4 s haelt lange
        // genug, dass die Meldung (17–25 ms) vor dem naechsten Druck da ist.
        setzen(laeuft: !schaltwerk.laeuft, sofortAnzeigen: false)
    }

    /// Beide Haelften des Laufzustands zugleich: die Ansicht zeichnet aus
    /// `@State`, die Rueckrufe lesen aus der Klasse.
    private func laeuftSetzen(_ neu: Bool) {
        laeuft = neu
        schaltwerk.laeuft = neu
    }

    /// Anhalten oder weiterlaufen — **absolut**, nicht umschaltend.
    ///
    /// Frueher liefen `abspielen`, `anhalten` und `umschalten` alle drei auf
    /// dasselbe Umschalten. Solange beide Seiten denselben Stand haben, faellt
    /// das nicht auf. Laufen sie auseinander, ist es der Grund, warum man es
    /// nicht mehr geradeziehen kann: das Telefon schickt „Pause", wir schalten
    /// auf Wiedergabe, und je oefter man drueckt, desto verdrehter wird es.
    /// Paul: „Wenn ich jetzt wieder auf abspielen gehe, ist auf einmal auf
    /// Pause. Also hier geht gar nix mehr."
    ///
    /// Ein ausdruecklicher Befehl setzt deshalb einen Zustand; nur die
    /// Wippe auf der Fernbedienung schaltet um.
    ///
    /// `sofortAnzeigen` trennt Befehl von Anzeige: ein ausdrueckliches
    /// „spiel ab" oder „halt an" von aussen sagt, was gelten soll, und darf
    /// den Zustand setzen. Die Wippe sagt nur „das andere" — dort wartet die
    /// Anzeige auf VLCs Meldung.
    private func setzen(laeuft soll: Bool, sofortAnzeigen: Bool = true) {
        guard let flaeche else { return }
        // Die Sperre liegt im Schaltwerk, nicht im Zustand: sonst liest ein
        // alter Rueckruf einen alten Zeitpunkt und sie greift nie.
        guard Date().timeIntervalSince(schaltwerk.zuletzt) > 0.4 else { return }
        schaltwerk.zuletzt = Date()

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
            abspielen:   { setzen(laeuft: true) },
            anhalten:    { setzen(laeuft: false) },
            umschalten:  { anhaltenOderWeiter() },
            springenAuf: { ziel in
                flaeche?.seek(toSeconds: ziel)
                position = ziel
                sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
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
        guard dauer > 0 else { return }
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

    // MARK: - Wischen

    /// Der Finger auf der Flaeche setzt eine Marke, der mittlere Knopf
    /// bestaetigt sie — so machen es der Systemplayer und Infuse.
    private func wischBeginn() {
        guard dauer > 0, !blattOffen, !folgenOffen else { return }
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
        markeVomWisch = true

        let fein = 0.10
        let grob = max(dauer / 1600, fein)
        let anteil = min(Double(abs(tempo)) / 3000, 1)
        let takt = fein + (grob - fein) * anteil * anteil

        spulzielSetzen((spulziel ?? position) + Double(weg) * takt)
    }

    /// Auch dann, wenn der Klick das Wischen schon entwaffnet hat: `wischEnde`
    /// haelt die Schrittbefehle zurueck, die derselbe Wisch ausgeloest hat.
    private func wischSchluss() {
        wischt = false
        wischEnde = Date()
        wischNurGeoeffnet = false
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

    /// Ziel setzen, anzeigen, Steuerung wachhalten — ohne zu springen.
    private func spulzielSetzen(_ roh: Double) {
        guard dauer > 0 else { return }
        let ziel = min(max(roh, 0), dauer)
        spulziel = ziel
        zeigen()
    }

    private func sprungAusfuehren(_ ziel: Double) {
        guard let flaeche else { return }

        let vorher = position
        position = ziel
        spulziel = nil
        markeVomWisch = false
        spulAufgabe?.cancel()
        spulAufgabe = nil

        // **Der Finger liegt beim Klick noch auf der Flaeche.**
        //
        // Auf der Fernbedienung ist der mittlere Knopf die Flaeche selbst:
        // wer klickt, drueckt sie herunter, und dabei rutscht sie ein Stueck.
        // Diese Nachzuckung kam als `changed` herein, setzte eine neue Marke
        // — und die Leiste blieb im Spulzustand stehen, mit eingefrorenen
        // Zeiten, bis man den Player verliess. Genau das hat Paul gemeldet.
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
        // Solange der vorige Sprung nicht gelandet ist, steht die noch auf
        // der alten Stelle — der zweite rechnete von dort und landete zu
        // weit. Danach zog VLC sich wieder zurecht: erst lief es, dann
        // sprang ein Stueck, dann lief es weiter. Auch das hat Paul
        // beschrieben.
        if sprungBis != nil {
            spulAufgabe = Task {
                // **Warten, bis der vorige angekommen ist — nicht eine Frist
                // absitzen.** Der Takt loescht `sprungBis`, sobald VLC dort
                // steht; meist ist das viel frueher als jede feste Zahl. Der
                // Deckel ist nur dafuer da, dass ein Sprung, der nie ankommt,
                // den naechsten nicht verschluckt.
                let deckel = Date().addingTimeInterval(3)
                while !Task.isCancelled, sprungBis != nil, Date() < deckel {
                    try? await Task.sleep(for: .milliseconds(120))
                }
                guard !Task.isCancelled else { return }
                sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
                flaeche.seek(toSeconds: ziel)
            }
            return
        }

        sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
        flaeche.seek(toSeconds: ziel)
    }

    /// Im laufenden Player zur nächsten Folge wechseln, statt zurück in die
    /// Übersicht zu springen.
    private func wechsleZu(_ folge: Item) {
        wechselt = true
        folgenOffen = false
        Task {
            await model.reportStopped(item: item, plan: plan, seconds: position)
            guard let neuerPlan = await model.plan(for: folge.id) else {
                wechselt = false
                return
            }

            // **Erst der Zustand, dann der Strom.**
            //
            // `item` und `plan` sind der laufende Titel, nicht der geoeffnete.
            // Bleiben sie stehen, meldet die Schleife weiter die alte Folge
            // an den Server, das Blatt zeigt ihren Namen, und die Folgenliste
            // hebt die falsche Zeile hervor.
            item = folge
            plan = neuerPlan

            // Ein neuer Titel in derselben Schleife. Die Regel steht im Takt,
            // damit sie nicht in jedem Wechsel neu erfunden wird.
            //
            // `startGemeldet: true`, weil gleich hier gemeldet wird: Titel,
            // Plan und Stelle stehen in diesem Augenblick fest. Ueberliesse
            // man es der Schleife, meldete sie einen Titel, der sich zwischen
            // zwei Takten geaendert haben kann.
            var stand = Wiedergabetakt.Stand(position: position, dauer: dauer,
                                             laeuft: laeuft, erstesBildDa: erstesBildDa,
                                             spurenGesetzt: spurenGesetzt,
                                             startGemeldet: startGemeldet)
            Wiedergabetakt.neuerTitel(&stand, startGemeldet: true)
            position = stand.position
            spurenGesetzt = stand.spurenGesetzt
            startGemeldet = stand.startGemeldet
            erstesBildDa = false
            // **Die Uhr faengt von vorn an.**
            //
            // `Zeitannahme` misst alles gegen diesen Zeitpunkt: wie lange der
            // Ladeschirm stehen darf und wann eine Zeitangabe noch Aufbau-
            // zucken sein kann. Blieb er auf dem Oeffnen des Players stehen,
            // galt die neue Folge vom ersten Takt an als laengst aufgebaut —
            // VLC meldete aber noch das Ende der alten. Die Anzeige uebernahm
            // es, und das Weiterschalten sprang sofort noch einmal: von Folge
            // drei auf fuenf.
            seitStart = Date()

            flaeche?.play(url: neuerPlan.url, abSekunden: 0, container: neuerPlan.container)
            await model.reportStart(item: folge, plan: neuerPlan, seconds: 0)

            naechste = await model.folgeNach(folge)
            // **Die neue Folge hat eigene Abschnitte.** Ohne das truege sie
            // die des Vorgaengers, und der Knopf erschiene an dessen Stellen.
            abschnitte = await model.abschnitte(fuer: folge.id)
            zentraleUebernehmen()
            wechselt = false
            // Nach dem Wechsel steht der Fokus sonst im Nichts: die Folgen-
            // liste ist zu, und die Leiste hatte ihn nie.
            steuerungWecken()
        }
    }

    /// Befehle aus dem Jellyfin-Dashboard — und später vom iPhone, wenn die
    /// Wiedergabe übergeben wird.
    private func ausfuehren(_ befehl: Fernbefehl) {
        guard let flaeche else { return }
        switch befehl {
        case .pause:      flaeche.pause();  laeuftSetzen(false); zeigen()
        case .weiter:     flaeche.resume(); laeuftSetzen(true);  zeigen()
        case .umschalten: anhaltenOderWeiter()
        case .stopp:      verlassen()
        case .vor:        springen(Double(model.vorSekunden))
        case .zurueck:    springen(-Double(model.zurueckSekunden))
        case let .springenAuf(sekunden):
            position = sekunden
            sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
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
        var takte = 0

        while !Task.isCancelled {
            try? await Task.sleep(for: Wiedergabetakt.taktlaenge)
            guard let flaeche else { continue }

            // **Nur solange etwas offen ist.** Der Aufruf liest die
            // Spurliste, und die baut VLCKit jedesmal neu auf — im halben
            // Sekundentakt ist das kein Nachsehen mehr, sondern ein
            // Dauergriff in ein laufendes Medium. Sobald die Rate einmal
            // gemessen ist, bleibt VLC in Ruhe.
            if Bildtakt.nochNachzumessen {
                Bildtakt.anpassen(an: flaeche.player)
            }

            // **Angekommen heisst angekommen — nicht „1,2 Sekunden sind um".**
            //
            // Der Riegel nach einem Sprung stand auf einer festen Frist. Ist
            // VLC frueher da, bleibt die Zeit trotzdem stehen; braucht es
            // laenger, faellt der Riegel zu frueh und die Anzeige springt auf
            // die alte Stelle zurueck. Beides hat Paul gesehen. Gemessen wird
            // jetzt, ob VLC dort ist, wo wir hinwollten.
            if sprungBis != nil, abs(flaeche.positionSeconds - position) < Zeitannahme.sprungAngekommen {
                sprungBis = nil
            }

            stockungPruefen(flaeche)

            // Den Stand der Ansicht uebernehmen: Sprung, Folgenwechsel und
            // Anhalten aendern ihn zwischen zwei Takten.
            stand.position = position
            stand.dauer = dauer
            stand.laeuft = laeuft
            stand.erstesBildDa = erstesBildDa
            stand.spurenGesetzt = spurenGesetzt
            stand.startGemeldet = startGemeldet

            let auftrag = Wiedergabetakt.rechnen(
                &stand,
                messung: .init(dauer: flaeche.durationSeconds,
                               position: flaeche.positionSeconds,
                               guteStelle: flaeche.guteStelle,
                               zeigtBild: flaeche.zeigtBild,
                               stelltEin: flaeche.stelltEin,
                               laeuft: flaeche.isPlaying,
                               hatTonspuren: !flaeche.tonspuren.isEmpty),
                stelltWiederHer: stelltWiederHer,
                sprungLaeuft: sprungBis.map { Date() < $0 } ?? false,
                // Am Fernseher liegt kein Finger am Regler.
                amSchieben: false,
                seitStart: seitStart)

            position = stand.position
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
                                        automatisch: model.untertitelAutomatisch)
            }
            if auftrag.startMelden {
                await model.reportStart(item: item, plan: plan, seconds: startAt)
            }
            if auftrag.fortschrittMelden {
                await model.reportProgress(item: item, plan: plan,
                                           seconds: position, paused: !laeuft)
            }

            // **Im Stehen den Fokus halten.**
            //
            // Genau das bewirkt Pauls Umweg ueber die Einstellungen: das
            // Blatt geht zu, und dabei legt `steuerungWecken` den Fokus
            // zurueck auf die Leiste — danach laesst sich wieder abspielen.
            // Einmalig beim Umschalten reichte das nicht; SwiftUI raeumt den
            // Fokus danach noch auf. Solange angehalten ist und kein Blatt
            // offen steht, wird er deshalb in jedem Takt neu gesetzt.
            //
            // Nur im Stehen: waehrend der Wiedergabe soll der Fokus auf die
            // Knoepfe oben wandern duerfen. Und nur, wenn er **nirgends**
            // steht — auf einem Knopf gehoert er dorthin.
            if !laeuft, !blattOffen, !folgenOffen, fokus == nil {
                fokus = .leiste
            }

            takte += 1
            // Die Anzeige braucht die Stelle nur im Sekundentakt.
            if takte % 2 == 0 {
                zentrale.standNachziehen(position: position, laeuft: laeuft, tempo: tempo)
            }

            // Am Ende von selbst weiter. Der Schalter stand in den
            // Einstellungen, ohne dass ihn hier jemand gelesen haette.
            if model.naechsteAutomatisch, let folge = naechste, !wechselt,
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

/// Zeiten links und rechts, dazwischen die Leiste mit rundem Kopf — der
/// Aufbau der iPhone-Fassung.
///
/// Sie ist das einzige fokussierbare Stück im unteren Bereich, und links und
/// rechts springen darauf. Ein Schieber, auf den man den Fokus erst legen
/// muss, wäre auf der Fernbedienung ein Weg zu viel.
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

    @Environment(\.isFocused) private var fokus

    private var spult: Bool { marke != nil }
    /// Was die Zeiten und der Kopf zeigen: das Ziel, sonst der Stand.
    private var gezeigt: Double { marke ?? position }

    private func anteil(_ sekunden: Double) -> Double {
        guard dauer > 0 else { return 0 }
        return min(max(sekunden / dauer, 0), 1)
    }

    private var balkenHoehe: CGFloat { spult ? 16 : 8 }
    private var kopf: CGFloat { spult ? 38 : (fokus ? 30 : 26) }

    var body: some View {
        HStack(spacing: 26) {
            Text(Spielzeit.text(gezeigt))
                .foregroundStyle(spult ? Stil.akzent : Color.white.opacity(0.9))

            GeometryReader { rahmen in
                let breite = rahmen.size.width
                let stand = anteil(position)
                let ziel = anteil(gezeigt)

                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.24))
                        .frame(height: balkenHoehe)

                    // Bis zur wirklichen Stelle: das ist gesehen.
                    Capsule().fill(Stil.akzent)
                        .frame(width: breite * min(stand, ziel), height: balkenHoehe)

                    // **Die Strecke zwischen Stand und Ziel.**
                    //
                    // Ohne sie sagt die Leiste beim Spulen nur, wo man
                    // hinwill — nicht, wie weit das von hier ist. Genau das
                    // ist die Frage beim Wischen, und eine Zahl dafuer stand
                    // frueher als Blase mitten im Bild.
                    if spult {
                        Capsule().fill(Color.white.opacity(0.55))
                            .frame(width: breite * abs(ziel - stand),
                                   height: balkenHoehe)
                            .offset(x: breite * min(stand, ziel))
                    }

                    Circle()
                        .fill(spult ? Stil.akzent : Color.white)
                        .overlay(Circle().strokeBorder(Color.white,
                                                       lineWidth: spult ? 5 : 0))
                        .frame(width: kopf, height: kopf)
                        .offset(x: breite * ziel - kopf / 2)
                        .shadow(color: .black.opacity(spult ? 0.5 : 0), radius: 10)
                }
                .frame(height: kopf)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 40)

            Text("−" + Spielzeit.text(max(dauer - gezeigt, 0)))
                .foregroundStyle(spult ? Stil.akzent : Color.white.opacity(0.9))
        }
        .font(Stil.klein.monospacedDigit())
        .focusable()
        // Der mittlere Knopf landet auf der fokussierten Ansicht.
        .onTapGesture { klick() }
        .animation(Stil.fokusAnimation, value: fokus)
        .animation(.easeInOut(duration: 0.18), value: spult)
        .onMoveCommand { richtung in
            switch richtung {
            case .left:  springen(-zurueck)
            case .right: springen(vor)
            default:     wecken()
            }
        }
    }
}

/// Die Pille für „Nächste Folge" — heller Grund, wie auf dem iPhone.
struct PillenStil: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(fokus ? Stil.grund : Stil.schrift)
                .padding(.horizontal, 30)
                .frame(height: 68)
                .background(fokus ? Color.white : Color.white.opacity(0.16), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 2)
                        .opacity(fokus ? 0 : 1)
                }
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
    /// Wo im Titel der gelieferte Strom beginnt — siehe `PlaybackPlan`.
    let angelegt: (VLCPlayerView) -> Void

    func makeUIView(context: Context) -> VLCPlayerView {
        let view = VLCPlayerView()
        view.play(url: url, abSekunden: startAt, container: container)
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
    /// Wann zuletzt umgeschaltet wurde — gegen doppelte Zustellung desselben
    /// Tastendrucks ueber zwei Wege.
    var zuletzt = Date.distantPast

    /// **Ob gerade laeuft — und zwar so, wie der Zuschauer es sieht.**
    ///
    /// Stand vorher nur als `@State` in der Ansicht, und `anhaltenOderWeiter`
    /// fragte stattdessen `flaeche.isPlaying`. Der Kommentar darueber sagte
    /// schon das Richtige — „nach `laeuft` richten, nicht nach VLC" —, der
    /// Code tat das Gegenteil.
    ///
    /// Die Folge hat Paul beschrieben: „Jetzt ist es pausiert, aber das
    /// Pausesymbol ist weg. Wenn ich jetzt wieder auf abspielen gehe, ist auf
    /// einmal auf Pause." `isPlaying` hinkt dem Befehl nach; wer danach
    /// fragt, waehlt die Richtung nach einem Stand, den es nicht mehr gibt,
    /// und schaltet zurueck, was er eben geschaltet hat. Baut VLC gerade
    /// seine Bildausgabe wieder auf, dauert das Nachhinken Sekunden statt
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
    let endet: () -> Void

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

        init(_ eltern: Wischfeld) { self.eltern = eltern }

        @objc func gewischt(_ erkenner: UIPanGestureRecognizer) {
            let x = erkenner.translation(in: nil).x
            switch erkenner.state {
            case .began:
                letzte = x
                eltern.beginnt()
            case .changed:
                let weg = x - letzte
                letzte = x
                eltern.bewegt(weg, erkenner.velocity(in: nil).x)
            case .ended, .cancelled, .failed:
                eltern.endet()
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
