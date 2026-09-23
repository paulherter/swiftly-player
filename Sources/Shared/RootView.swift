import JellyfinKit
import StoreKit
import SwiftUI

struct RootView: View {
    @State private var model = AppModel()
    /// Der Vorhang liegt über allem, bis die Animation durch ist.
    @State private var gestartet = false
    #if os(iOS)
    /// Apples eigene Bewertungsabfrage. Wann sie kommt, entscheidet
    /// `Bewertungsfrage` im Paket; Apple zeigt sie höchstens dreimal im Jahr.
    @Environment(\.requestReview) private var bewerten
    #endif
    /// Der einmalige Hinweis auf den Discord, nach dem fünften Titel.
    @State private var discordBlatt = false

    /// Nur hier gelesen. Die Ansichten fragen `\.breit` ab, damit die Regel
    /// an einer Stelle steht und nicht in jeder Ansicht neu.
    @Environment(\.horizontalSizeClass) private var breitenklasse

    private var breit: Bool { breitenklasse == .regular && Stil.amPad }

    /// Gemessene Fensterbreite. Die Größenklasse allein sagt nichts darüber,
    /// ob eine Knopfreihe nebeneinander passt.
    @State private var fensterbreite: CGFloat = 0


    /// Die App teilt sich den Schirm — dann liegt iPadOS' Ampel auf unserer
    /// oberen linken Ecke. Siehe `Fensterknoepfe`.
    private var imFenster: Bool {
        Fensterknoepfe.imFenster(fensterbreite: fensterbreite)
    }

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()
            switch model.phase {
            case .disconnected, .connecting:
                ConnectView(model: model)
            case let .needsLogin(serverName, version):
                LoginView(model: model, serverName: serverName, version: version)
            case .ready:
                HauptView(model: model)
            }
        }
        // **Einmal an der Wurzel, nicht an jeder Kachel.** Welche Kachel
        // ihren Fortschrittsbalken zeigt, entscheidet eine Einstellung — und
        // die 33 Aufrufstellen, die `fortschritt:` weiterreichen, sollen
        // nichts davon wissen muessen. Gelesen wird sie dort, wo der Balken
        // entsteht. Siehe `EnvironmentValues.fortschrittAufKacheln`.
        .environment(\.fortschrittAufKacheln, model.fortschrittAufKacheln)
        #if os(iOS)
        // **Erst nach dem Player, und mit einem Atemzug Abstand.** Die Frage
        // kommt, wenn jemand gerade etwas zu Ende geschaut hat — nicht mitten
        // in der Wiedergabe und nicht beim Start.
        //
        // **Erst wenn der Player zu ist.** Der Wechsel zur nächsten Folge
        // zählt den Titel, während der Player offen bleibt — vorher kam die
        // Abfrage dann 1,5 s später über die laufende Folge.
        .onChange(of: model.bewertungFaellig && !model.playerOffen) { _, jetzt in
            guard jetzt else { return }
            model.bewertungFaellig = false
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !model.playerOffen else { model.bewertungFaellig = true; return }
                bewerten()
            }
        }
        #endif
        .onChange(of: model.discordHinweisFaellig && !model.playerOffen) { _, jetzt in
            guard jetzt else { return }
            model.discordHinweisFaellig = false
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !model.playerOffen else { model.discordHinweisFaellig = true; return }
                discordBlatt = true
            }
        }
        .overlay { Discordhinweis(offen: $discordBlatt) }
        .overlay {
            #if os(iOS)
            if !gestartet {
                Startvorhang {
                    // 0,28 aus `Stil.einblenden` statt eigener 0,45: der
                    // Vorhang geht auf wie jeder andere Inhalt, der da ist —
                    // eine Dauer, nicht zwei. Vorher `.easeOut(0,45)`.
                    withAnimation(Stil.einblenden) { gestartet = true }
                }
            }
            #endif
        }
        // Verbinden → Anmelden → Hauptansicht ist ein Bereichswechsel und
        // kein Systemstandard. `.default` war die letzte Bewegung der App
        // ohne Token; jetzt dieselbe Kennlinie wie jeder Reiterwechsel.
        .animation(Stil.bereichswechsel, value: model.phase)
        // Deckel für die Schriftgröße.
        //
        // Die Gestaltung steht auf festen Punktmaßen — Kacheln 112 × 168,
        // Leiste 54, Knöpfe 44. Die obersten Stufen der Systemeinstellung
        // (bis „AX5") verdreifachen die Schrift; das sprengt jede dieser
        // Höhen. Bis `accessibility1` geht alles mit, darüber bliebe nur ein
        // Umbau jeder festen Höhe — das ist ein eigenes Vorhaben.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // Ein helles Thema gibt es nicht — die Gestaltung ist auf Dunkel gebaut.
        .preferredColorScheme(.dark)
        .tint(Stil.akzent)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { neu in
            fensterbreite = neu
        }
        .environment(\.breit, breit)
        .environment(\.weit, breit && fensterbreite >= Stil.querKopfAbBreite)
        .environment(\.fensterknoepfe, imFenster)
    }
}

// MARK: - Server eingeben

/// Erster Schritt: wo steht der Server.
///
/// Bewusst nur die Wortmarke, kein Signet daneben — zwei Zeichen übereinander
/// sind eines zu viel. Und keine Überschrift plus Beschriftung plus
/// Platzhalter: dreimal dasselbe zu sagen war der Fehler vorher, ein Satz
/// genügt.
struct ConnectView: View {
    let model: AppModel
    @State private var adresse = ""
    /// „Erweitert" — eigene Header für einen Dienst vor dem Server.
    @State private var koepfe: [Kopfzeile] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Wortmarke(hoehe: 40)
                    .padding(.top, 172)

                Text("Wo steht dein Jellyfin-Server?")
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .padding(.top, 44)

                Eingabefeld(text: $adresse, symbol: "globe",
                            platzhalter: "tv.beispiel.de", tastatur: .adresse,
                            abschluss: verbinden)
                    .padding(.top, 18)

                Text("https:// kannst du weglassen.")
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 9)
                    .padding(.leading, 2)

                Erweitertbereich(zeilen: $koepfe)
                    .padding(.top, 6)

                // **Der Knopf bleibt stehen und sagt, was laeuft.** Hier
                // wechselte er gegen einen Ring — die Seite sprang, und
                // wohin man gedrueckt hatte, war weg.
                do {
                    Button(model.phase == .connecting ? "Verbinden…" : "Verbinden",
                           action: verbinden)
                        .buttonStyle(HauptknopfStil())
                        .padding(.top, 22)
                        .disabled(adresse.isEmpty || model.phase == .connecting)
                        .opacity(adresse.isEmpty ? 0.4 : 1)
                }

                if let fehler = model.errorMessage {
                    // Der Fehler steht unter dem Feld, das ihn ausgelöst hat,
                    // nicht am Seitenende.
                    // **`fehler`, nicht `warnung`.** Eine abgelehnte
                    // Anmeldung ist schiefgegangen, sie wartet nicht auf
                    // jemanden — und beides trug dieselbe Farbe.
                    Text(fehler)
                        .font(Stil.klein)
                        .foregroundStyle(Stil.fehler)
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                }

                if let letzte = model.letzterServer, letzte.adresse != adresse {
                    zuletzt(letzte)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            // Sonst zieht sich das Feld über die ganze iPad-Breite.
            .frame(maxWidth: Stil.formularbreite)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { if adresse.isEmpty { adresse = model.letzterServer?.adresse ?? "" } }
    }

    /// Beim zweiten Mal tippt niemand die Adresse erneut.
    private func zuletzt(_ letzte: Servererinnerung) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Gruppentitel(text: "Zuletzt verbunden")
            Trennlinie()
            Button {
                adresse = letzte.adresse
                verbinden()
            } label: {
                HStack(spacing: 12) {
                    Circle().fill(Stil.akzent).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(letzte.name)
                            // Listenzeile aus der Leiter — vorher 15 als Zahl.
                            .font(Stil.listentitel)
                            .foregroundStyle(Stil.schrift)
                        Text("\(letzte.adresse) · Jellyfin \(letzte.version)")
                            // Die Angabe der Leiter, 12 Regular. Vorher 12 als
                            // Zahl an der Aufrufstelle.
                            .font(Stil.klein)
                            .foregroundStyle(Stil.schriftSehrLeise)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        // 13 Semibold: der Winkel rechts in einer Zeile, wie
                        // in `Wertzeile` und `Profilzeile`. 12 war die zweite
                        // Zahl fuer dasselbe Zeichen.
                        .font(.system(size: 13, weight: .semibold))
                        // Weiss 28 Prozent sind 2,50:1 - fuer ein Bedienzeichen
                        // liegt die Grenze bei 3:1.
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(Stil.Druckzeile())
            Trennlinie()
        }
        .padding(.top, 36)
    }

    private func verbinden() {
        guard !adresse.isEmpty else { return }
        Task { await model.connect(to: adresse, koepfe: koepfe.koepfe) }
    }
}

// MARK: - Anmelden

/// Zweiter Schritt: wer schaut.
///
/// Jellyfin gibt die öffentlichen Benutzer ohne Anmeldung heraus. Sie als
/// Bilder anzubieten, statt den Namen abtippen zu lassen, den der Server
/// schon kennt, ist der eigentliche Unterschied zu vorher.
struct LoginView: View {
    let model: AppModel
    let serverName: String
    let version: String
    /// Als Blatt aus dem Profil geoeffnet: derselbe Server, ein weiteres
    /// Konto. Dann gibt es keinen Weg zu einem anderen Server — und das Blatt
    /// muss sich selbst schliessen koennen.
    var weiteresKonto = false
    /// Wird beim Hinzufuegen nicht mehr gebraucht — die Seite geht selbst
    /// zurueck. Bleibt fuer die Anmeldung an der Wurzel, die kein Zurueck hat.
    var fertig: () -> Void = {}

    @Environment(\.dismiss) private var schliessen

    @State private var benutzer = ""
    @State private var passwort = ""
    @State private var bekannte: [OeffentlicherBenutzer] = []
    @State private var bilder: [String: URL] = [:]
    @State private var quickConnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                kopf
                if !bekannte.isEmpty { wahl }
                felder
                quickConnectWeg
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: Stil.formularbreite)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        // **Beim Hinzufuegen traegt die Leiste oben den Rueckweg.**
        //
        // Unten stand „Abbrechen" — das brauchte es, solange die Ansicht als
        // Blatt kam. Als geschobene Seite hat sie oben denselben Rueckweg wie
        // jede andere Unterseite, und zwei Wege zurueck sind einer zu viel.
        // An der Wurzel bleibt die Zeile: dort gibt es kein Zurueck, sondern
        // nur den Weg zu einem anderen Server.
        .safeAreaInset(edge: .top, spacing: 0) {
            if weiteresKonto {
                Unterseitenkopf(titel: String(localized: "Konto hinzufügen")) {
                    schliessen()
                } rechts: { EmptyView() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !weiteresKonto {
                Button("Anderer Server") { model.signOut() }
                    .buttonStyle(Stil.Druckzeile())
                    // 12 Regular aus der Leiter; 13 Regular steht dort nicht.
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .padding(.bottom, 22)
            }
        }
        #if os(iOS)
        // Nur beim Hinzufuegen: an der Wurzel gibt es keine Leiste, die stoeren
        // koennte, und `WischZurueck` haette dort nichts zurueckzuwischen.
        .toolbar(weiteresKonto ? .hidden : .automatic, for: .navigationBar)
        #endif
        // **Wer das Blatt zeigt, schliesst es auch.** Nach dem Hinzufuegen
        // blieb es sonst stehen und es sah aus, als sei nichts passiert.
        //
        // `kontowechsel` steigt genau dann, wenn schon jemand angemeldet war —
        // also beim Hinzufuegen und nicht bei der ersten Anmeldung. Und **nur
        // ohne Fehlermeldung**: sonst verschluckt das Schliessen sie.
        .onChange(of: model.kontowechsel) { _, _ in
            guard weiteresKonto, model.errorMessage == nil else { return }
            schliessen()
        }
        .task {
            bekannte = await model.oeffentlicheBenutzer()
            bilder = await model.bildAdressen(bekannte)
            // Bei genau einem Konto gibt es nichts zu wählen. Den Namen dann
            // trotzdem eintippen zu lassen — und den Anmeldeknopf so lange
            // grau zu lassen — ist eine Hürde ohne Zweck.
            if bekannte.count == 1, benutzer.isEmpty {
                benutzer = bekannte[0].name
            }
        }
        .fullScreenCover(isPresented: $quickConnect) {
            QuickConnectAnmeldung(model: model)
        }
    }

    private var kopf: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Stil.akzent).frame(width: 7, height: 7)
                Text("Verbunden · Jellyfin \(version)")
                    // Die Angabe der Leiter, 12 Regular. Vorher als Zahl.
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
            Text(serverName)
                .font(Stil.titel)
                .foregroundStyle(Stil.schrift)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 48)
    }

    private var wahl: some View {
        VStack(alignment: .leading, spacing: 0) {
            Gruppentitel(text: "Wer schaut?")
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(bekannte) { person in
                        Button { benutzer = person.name } label: {
                            Kontozeichen(name: person.name,
                                         bild: bilder[person.id],
                                         gewaehlt: benutzer == person.name)
                        }
                        .buttonStyle(Stil.Druckzeile())
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, 22)
    }

    private var felder: some View {
        VStack(spacing: 10) {
            Eingabefeld(text: $benutzer, symbol: "person",
                        platzhalter: "Benutzername")
            Eingabefeld(text: $passwort, symbol: "lock",
                        platzhalter: "Passwort", geheim: true,
                        abschluss: anmelden)

            // Derselbe Grund wie oben: der Knopf bleibt stehen.
            do {
                Button(model.isWorking ? "Anmelden…" : "Anmelden", action: anmelden)
                    .buttonStyle(HauptknopfStil())
                    .padding(.top, 10)
                    .disabled(model.isWorking)
                    .disabled(benutzer.isEmpty)
                    .opacity(benutzer.isEmpty ? 0.4 : 1)
            }

            if let fehler = model.errorMessage {
                Text(fehler)
                    .font(Stil.klein)
                    .foregroundStyle(Stil.fehler)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 28)
    }

    /// Gleichrangig, nicht versteckt: ein Passwort mit Sonderzeichen tippt
    /// sich auf einer Glasscheibe schlecht.
    private var quickConnectWeg: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                Rectangle().fill(Stil.linie).frame(height: 1)
                Text("oder")
                    // Die Angabe der Leiter, 12 Regular. Vorher als Zahl.
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
                Rectangle().fill(Stil.linie).frame(height: 1)
            }
            Button {
                quickConnect = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "tv")
                    Text("Mit Quick Connect anmelden")
                }
            }
            .buttonStyle(NebenknopfStil(akzent: true))
        }
        .padding(.top, 26)
    }

    private func anmelden() {
        guard !benutzer.isEmpty else { return }
        Task { await model.login(username: benutzer, password: passwort) }
    }
}

/// Rundes Zeichen für ein Konto auf der Anmeldeseite.
struct Kontozeichen: View {
    let name: String
    let bild: URL?
    let gewaehlt: Bool

    var body: some View {
        VStack(spacing: 8) {
            // **Der Baustein, nicht sein Nachbau.**
            //
            // Hier stand das Zeichen ein zweites Mal von Hand: `erhoeht` als
            // Grund statt des Verlaufs, weisser Ring 2 pt statt `hervorgehoben`,
            // 20 Semifett als Buchstabe statt `groesse * 0,38`, und das Bild
            // ueber `Bild` statt ueber den Bildspeicher — also ohne den
            // synchronen Blick, der das Aufblitzen des Buchstaben verhindert.
            // Dasselbe Ding in zwei Bauarten heisst zwei Profilringe in einer
            // App. Dass der Ring hier weiss ist und nicht im Akzent, ist
            // richtig und steht jetzt als `gewaehlt` im Baustein.
            Profilzeichen(name: name, bild: bild, groesse: 60, gewaehlt: gewaehlt)
            Text(name)
                // Titel unter einem Zeichen: 13 aus der Leiter, vorher als
                // Zahl. Ein Gewicht, nicht zwei: `semibold` ist breiter als
                // `medium`, und bei zwei Zeilen mit `minimumScaleFactor`
                // entscheidet die Breite ueber den Umbruch — der Name brach
                // beim Auswaehlen anders. Ton und Ring sagen die Wahl.
                .font(Stil.kachel)
                .foregroundStyle(gewaehlt ? Stil.schrift : Stil.schriftLeise)
                // Zwei Zeilen und etwas mehr Breite: ein elfstelliger Name wurde bei
                // 66 Punkt und einer Zeile auf zehn Zeichen verstümmelt, und
                // ein abgeschnittener Name auf einem Anmeldebildschirm sieht
                // nach Fehler aus.
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
        }
        .frame(width: 84)
        // **Die Wahl sagt sich nicht nur ueber Ton und Ring.** Beides ist
        // Farbe, und Farbe allein erreicht niemanden, der die Seite vorlesen
        // laesst: VoiceOver sagte bei jedem Konto dasselbe. `.isSelected`
        // ist das Merkmal, das das System dafuer kennt.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(gewaehlt ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Bibliotheken

