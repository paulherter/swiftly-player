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
    let startItem: Item
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
    /// Der Wechsel laeuft schon — sonst loest der Takt ihn mehrfach aus.
    @State private var wechselt = false
    @State private var tempo: Float = 1.0
    /// Wiedergabetasten der Fernbedienung und die Anzeige im Kontrollzentrum.
    ///
    /// Auf dem Fernseher wiegt sie schwerer als am Telefon: die Siri Remote
    /// hat eigene Wiedergabetasten, und ohne Zentrale greifen sie ins Leere,
    /// sobald die App nicht vorn ist.
    @State private var zentrale = Wiedergabezentrale()
    /// Wann zuletzt umgeschaltet wurde.
    ///
    /// **Ein Tastendruck kommt zweimal an**: einmal als `onPlayPauseCommand`
    /// bei der fokussierten Ansicht, einmal als `togglePlayPauseCommand` der
    /// Wiedergabezentrale. Zwei Umschaltungen heben sich auf. Ob dabei etwas
    /// zu sehen war, hing daran, wie schnell VLC seinen Zustand nachzog —
    /// Pausieren ging, Fortsetzen nicht, und ein paar Tastendrucke spaeter
    /// ging es doch. Am Telefon faellt das nicht auf, dort gibt es nur den
    /// einen Weg ueber die Zentrale.
    /// **Der Schalter liegt in einer Klasse, nicht in der Ansicht.**
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
    /// Wann zuletzt ein Schritt kam — daraus waechst das Tempo.
    @State private var letzterSchritt = Date.distantPast
    /// Wie oft hintereinander schnell getippt wurde.
    @State private var schrittfolge = 0
    @State private var schlafminuten: Int?
    @State private var schlafAufgabe: Task<Void, Never>?
    /// Kurze Rückmeldung nach einem Sprung — „+30 s".
    @State private var sprungAnzeige: (richtung: Int, sekunden: Int)?
    @State private var naechste: Item?
    /// Nach einem Sprung kurz nicht überschreiben, sonst zieht die Anzeige
    /// auf den alten Wert zurück, bevor VLC nachgezogen hat.
    @State private var sprungBis: Date?

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
        self.startItem = item
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
            }

            // **Deckend, nicht nur ein Ring.**
            //
            // Vorher stand hier `Lader()` allein — ein schwebender Ring ueber
            // dem laufenden Bild. VLC steuert die Fortsetzstelle erst nach dem
            // ersten Bild an, und in dieser Zeit war der Anfang des Films zu
            // sehen. Der Ladeschirm hat ihn nicht verdeckt, weil er nichts
            // verdeckte. Die iPhone-Fassung legt Schwarz darunter, seit jeher.
            if !erstesBildDa {
                ZStack {
                    Color.black
                    Lader()
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }

            if let anzeige = sprungAnzeige { sprungRueckmeldung(anzeige) }

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
        .onChange(of: laeuft) { _, _ in
            guard !blattOffen, !folgenOffen else { return }
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
                guard !blattOffen, !folgenOffen else { return }
                fokus = .leiste
            }
        }
        // Voruebergehend: sagt uns, ob der Fokus wirklich abhandenkommt.
        .onPlayPauseCommand { anhaltenOderWeiter() }
        .onExitCommand {
            // Menue bricht zuerst das Spulen ab, nicht die Wiedergabe. Wer
            // sich verspult hat, will zurueck an seine Stelle — und nicht
            // aus dem Film heraus.
            if spulziel != nil {
                spulAufgabe?.cancel()
                spulziel = nil
                sprungAnzeige = nil
            }
            else if blattOffen { blattOffen = false }
            else if folgenOffen { folgenOffen = false }
            else { schliessen() }
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
        .animation(.easeInOut(duration: 0.15), value: sprungAnzeige?.sekunden)
        .task(id: sprungAnzeige?.sekunden) {
            guard sprungAnzeige != nil else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            guard !Task.isCancelled else { return }
            sprungAnzeige = nil
        }
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
            laeuft = false
            zeigen()
        }
        .onChange(of: schlafminuten) { _, neu in schlafzeitSetzen(neu) }
        .animation(.easeInOut(duration: 0.2), value: blattOffen)
        .onAppear {
            model.fernbefehl = ausfuehren
        }
        .onDisappear {
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
            // Erst jetzt steht fest, ob es einen „Weiter"-Griff geben darf.
            zentraleUebernehmen()
        }
        .onChange(of: dauer) { _, _ in zentraleMelden() }
        // **Hier wurden die Griffe frueher neu eingetragen.**
        //
        // Das war ein Notbehelf gegen das eingefrorene `laeuft` in den
        // Rueckrufen. Der Stand kommt inzwischen von `flaeche.isPlaying` und
        // die Sperre aus dem `Schaltwerk`, beides Klassen — der Notbehelf ist
        // damit ueberfluessig.
        //
        // Und er war schaedlich: `uebernehmen` nimmt alle Befehlsziele weg
        // und traegt sie neu ein. Das geschah unmittelbar nach dem ersten
        // Druck, und der zweite kam nicht mehr an — ohne jede Spur, weil er
        // gar nicht mehr bei uns landete.
        .task(id: ausblendMarke) {
            // Im Stehen nichts wegnehmen: wer angehalten hat, schaut gerade
            // nicht aufs Bild, sondern will wissen, wo er ist.
            guard steuerungSichtbar, laeuft else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !blattOffen, !folgenOffen else { return }
            steuerungSichtbar = false
        }
    }

    /// Zeigt kurz, wie weit gesprungen wurde.
    ///
    /// Auf dem iPhone gibt es sie beim Doppeltipp. Hier ist sie noch nötiger:
    /// die Fernbedienung gibt keine Rückmeldung, und ohne Anzeige weiß man
    /// nicht, ob der Druck angekommen ist.
    private func sprungRueckmeldung(_ anzeige: (richtung: Int, sekunden: Int)) -> some View {
        HStack(spacing: 0) {
            if anzeige.richtung > 0 { Spacer() }
            HStack(spacing: 14) {
                Image(systemName: anzeige.richtung > 0 ? "goforward" : "gobackward")
                    .font(.system(size: 44, weight: .medium))
                Text("\(anzeige.sekunden) s")
                    .font(.system(size: 40, weight: .semibold))
            }
            .foregroundStyle(Stil.schrift)
            .padding(.horizontal, 44)
            .padding(.vertical, 30)
            .background(Color.black.opacity(0.55), in: Capsule())
            .padding(.horizontal, 160)
            if anzeige.richtung < 0 { Spacer() }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
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

                // Erscheint erst, wenn die Folge fast durch ist — sonst steht
                // sie zwei Stunden lang im Weg. Dieselbe Regel wie auf iOS.
                if let folge = naechste, fastDurch {
                    Button { wechsleZu(folge) } label: {
                        Label("Nächste Folge", systemImage: "forward.end.fill")
                    }
                    .buttonStyle(PillenStil())
                }
            }

            Zeitleiste(position: spulziel ?? position, dauer: dauer,
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

    private var fastDurch: Bool {
        Folgenende.knopfZeigen(position: position, dauer: dauer)
    }

    // MARK: - Befehle

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
        guard let flaeche else { return }
        // Die Sperre liegt im Schaltwerk, nicht im Zustand: sonst liest ein
        // alter Rueckruf einen alten Zeitpunkt und sie greift nie.
        guard Date().timeIntervalSince(schaltwerk.zuletzt) > 0.4 else { return }
        schaltwerk.zuletzt = Date()
        let vorher = flaeche.isPlaying

        // **Nach `laeuft` richten, nicht nach VLC.**
        //
        // `isPlaying` hinkt dem Befehl nach. Wer danach fragt, waehlt die
        // Richtung nach einem Stand, den es schon nicht mehr gibt, und schaltet
        // zurueck, was er eben geschaltet hat. Die iPhone-Fassung nimmt
        // deshalb den eigenen Zustand — der ist das, was der Zuschauer sieht.
        if vorher { flaeche.pause() } else { flaeche.resume() }
        laeuft = !vorher
        zentrale.standNachziehen(position: position, laeuft: laeuft, tempo: tempo)
        zeigen()
    }

    private func zentraleUebernehmen() {
        zentrale.uebernehmen(.init(
            // **Ohne Blick auf den Zustand.**
            //
            // Diese Rueckrufe liegen in der Zentrale und werden spaeter
            // aufgerufen — sie halten die Ansicht so fest, wie sie beim
            // Eintragen war. Ein `if !laeuft` darin fragt also nicht, was
            // gerade laeuft, sondern was beim Oeffnen des Players lief. Das
            // war immer „ja", und damit hat `anhalten` jedesmal angehalten
            // und `abspielen` nie abgespielt.
            //
            // Schreiben geht: `@State` legt seine Werte ausserhalb der
            // Struktur ab. Nur Lesen liefert den alten Stand. Deshalb hier
            // ausschliesslich befehlen und schreiben, nie fragen.
            // **Alle drei tun dasselbe.** Welchen der drei tvOS schickt,
            // ist seine Entscheidung und war immer dieselbe falsche. Ein
            // Druck auf die Taste schaltet um, Punkt.
            abspielen:   { anhaltenOderWeiter() },
            anhalten:    { anhaltenOderWeiter() },
            umschalten:  { anhaltenOderWeiter() },
            springenAuf: { ziel in
                flaeche?.seek(toSeconds: ziel)
                position = ziel
                sprungBis = Date().addingTimeInterval(1.2)
            },
            vor:         { springen(Double(model.vorSekunden)) },
            zurueck:     { springen(-Double(model.zurueckSekunden)) },
            naechste:    naechste.map { folge in { wechsleZu(folge) } }))
        zentraleMelden()
    }

    private func zentraleMelden() {
        zentrale.melden(item: item, position: position, dauer: dauer, tempo: tempo,
                        laeuft: laeuft,
                        sprungweite: (model.zurueckSekunden, model.vorSekunden))
    }

    /// Spulen: sammeln, beschleunigen, **einmal** springen.
    ///
    /// Drei Regeln, und die dritte ist die, an der es zweimal gescheitert ist.
    ///
    /// 1. **Der erste Druck bei versteckter Steuerung zeigt sie nur.** Am
    ///    Telefon tippt man auf einen sichtbaren Knopf; hier drueckt man blind
    ///    eine Richtung, und dann darf nicht gleich gesprungen werden.
    ///
    /// 2. **Schnelles Tippen laesst die Schrittweite wachsen.** Einzelne
    ///    Tipper bleiben klein — zehn zurueck, dreissig vor —, damit man eine
    ///    Stelle genau treffen kann. Wer weiter will, tippt schnell weiter und
    ///    kommt zuegig voran. Die Fernbedienung wiederholt beim Halten von
    ///    selbst, also traegt dieselbe Regel auch das Gedrueckthalten.
    ///
    /// 3. **Gesprungen wird genau einmal, wenn das Tippen aufhoert.** Ein
    ///    Sprung je Druck laesst VLC den Strom jedesmal neu aufbauen; der
    ///    Player rauschte hoerbar durch den Film und blieb haengen. Bis dahin
    ///    bewegt sich nur die Marke, das Bild laeuft weiter.
    private func springen(_ sekunden: Double) {
        guard dauer > 0 else { return }
        guard steuerungDa else { zeigen(); return }

        let seitLetztem = Date().timeIntervalSince(letzterSchritt)
        schrittfolge = seitLetztem < 0.6 ? schrittfolge + 1 : 0
        letzterSchritt = Date()

        // Erst ab dem vierten schnellen Tipp waechst es, und hoechstens auf
        // das Achtfache. Sonst schiesst schon der zweite Tipp uebers Ziel.
        // Sanft: die ersten sechs Tipper bleiben bei der eingestellten
        // Weite, danach waechst es langsam. Vorher schoss schon der vierte
        // Tipp weit uebers Ziel.
        let faktor = min(1 + max(schrittfolge - 5, 0) / 3, 6)
        spulzielSetzen((spulziel ?? position) + sekunden * Double(faktor))

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
            schrittfolge = 0
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
        sprungAnzeige = (ziel < position ? -1 : 1, Int(abs(ziel - position).rounded()))
        zeigen()
    }

    private func sprungAusfuehren(_ ziel: Double) {
        guard let flaeche else { return }
        position = ziel
        spulziel = nil
        sprungBis = Date().addingTimeInterval(1.2)
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
        case .pause:      flaeche.pause();  laeuft = false; zeigen()
        case .weiter:     flaeche.resume(); laeuft = true;  zeigen()
        case .umschalten: anhaltenOderWeiter()
        case .stopp:      schliessen()
        case .vor:        springen(Double(model.vorSekunden))
        case .zurueck:    springen(-Double(model.zurueckSekunden))
        case let .springenAuf(sekunden):
            position = sekunden
            sprungBis = Date().addingTimeInterval(1.2)
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
            laeuft = false
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
            laeuft = stand.laeuft
            spurenGesetzt = stand.spurenGesetzt
            startGemeldet = stand.startGemeldet

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
            // Genau das bewirkt Einmalig beim Umschalten reichte das nicht;
            // SwiftUI raeumt den Fokus danach noch auf. Solange angehalten ist
            // und kein Blatt offen steht, wird er deshalb in jedem Takt neu
            // gesetzt.
            //
            // Nur im Stehen: waehrend der Wiedergabe soll der Fokus auf die
            // Knoepfe oben wandern duerfen. Nur wenn er **nirgends** steht.
            // Steht er auf einem Knopf, gehoert er dorthin.
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
               Folgenende.weiterschalten(position: position, dauer: dauer) {
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
    let position: Double
    let dauer: Double
    /// Aus den Einstellungen, nicht fest verdrahtet — dieselben Werte, die
    /// auch die Fernsteuerung benutzt.
    let zurueck: Double
    let vor: Double
    let springen: (Double) -> Void
    let wecken: () -> Void
    /// Der mittlere Knopf: bestaetigt eine Marke, sonst anhalten/weiter.
    let klick: () -> Void

    @Environment(\.isFocused) private var fokus

    private var anteil: Double {
        guard dauer > 0 else { return 0 }
        return min(max(position / dauer, 0), 1)
    }

    var body: some View {
        HStack(spacing: 26) {
            Text(Spielzeit.text(position))
            GeometryReader { rahmen in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.24))
                        .frame(height: 8)
                    Capsule().fill(Stil.akzent)
                        .frame(width: rahmen.size.width * anteil, height: 8)
                    Circle().fill(Color.white)
                        .frame(width: fokus ? 30 : 26, height: fokus ? 30 : 26)
                        .offset(x: rahmen.size.width * anteil - (fokus ? 15 : 13))
                }
                .frame(height: 30)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 30)
            Text("−" + Spielzeit.text(max(dauer - position, 0)))
        }
        .font(Stil.klein.monospacedDigit())
        .foregroundStyle(Color.white.opacity(0.9))
        .focusable()
        // Der mittlere Knopf landet auf der fokussierten Ansicht.
        .onTapGesture { klick() }
        .animation(Stil.fokusAnimation, value: fokus)
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
}
