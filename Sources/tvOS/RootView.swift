import JellyfinKit
import SwiftUI

/// Der Einstieg: Server eintragen, anmelden, dann die App.
///
/// Derselbe Ablauf wie auf dem iPhone und derselbe Zustandshalter — nur mit
/// einer Oberfläche für drei Meter Entfernung, und mit demselben
/// Startvorhang: die Marke fährt auf wie auf dem iPhone, nur größer.
struct RootView: View {
    @State private var model = AppModel()
    /// Der Vorhang liegt über allem, bis die Animation durch ist.
    @State private var gestartet = false

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            switch model.phase {
            case .disconnected, .connecting:
                ServerView(model: model)
            case let .needsLogin(serverName, version):
                AnmeldeView(model: model, serverName: serverName, version: version)
            case .ready:
                HauptView(model: model)
            }
        }
        .overlay {
            if !gestartet {
                Startvorhang {
                    withAnimation(.easeOut(duration: 0.45)) { gestartet = true }
                }
            }
        }
        .animation(.default, value: model.phase)
        // Ein helles Thema gibt es nicht — die Gestaltung ist auf Dunkel
        // gebaut. Auf tvOS ohnehin die Regel.
        .preferredColorScheme(.dark)
        .tint(Stil.akzent)
    }
}

// MARK: - Eingabefeld

/// Eigenes Feld — und zwar wörtlich eigenes.
///
/// Auf tvOS ist ein `TextField` keine Fläche, die man einfärben kann: das
/// System zeichnet eine weiße Kapsel mit Schein und Schatten, und weder
/// `.textFieldStyle(.plain)` noch `.focusEffectDisabled()` nehmen sie weg.
/// Im Simulator stand sie als zweite weiße Kapsel mitten in unserer eigenen
/// Fläche.
///
/// Deshalb liegt das echte Feld unsichtbar darüber: es fängt den Fokus, holt
/// die Systemtastatur und trägt den Text — zu sehen ist nur, was wir selbst
/// zeichnen. Ganz auf null darf es dabei nicht, sonst nimmt SwiftUI es aus
/// der Fokuskette.
///
/// `keyboardType` gibt es hier nicht (iOS und Catalyst only), die Art der
/// Eingabe steht deshalb über `textContentType`.
struct Eingabefeld: View {
    let platzhalter: LocalizedStringKey
    @Binding var text: String
    var sicher = false
    var inhalt: UITextContentType?
    /// Von aussen gesetzter Fokus. Die Suche braucht ihn: dort soll die
    /// Tastatur aufgehen, sobald der Bereich offen ist, ohne dass man das
    /// Feld erst noch ansteuern muss.
    var aussen: FocusState<Bool>.Binding?
    var abschluss: () -> Void = {}

    @FocusState private var innen: Bool

    private var gebunden: FocusState<Bool>.Binding { aussen ?? $innen }
    private var fokus: Bool { gebunden.wrappedValue }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Stil.ecke)
                .fill(fokus ? Color.white : Stil.erhoeht)
                .overlay {
                    RoundedRectangle(cornerRadius: Stil.ecke)
                        .strokeBorder(Stil.rand, lineWidth: 2)
                        .opacity(fokus ? 0 : 1)
                }

            beschriftung
                .font(Stil.koerper)
                .lineLimit(1)
                .padding(.horizontal, 30)

            // **Unsichtbare Schrift, sichtbare Ansicht.**
            //
            // Das echte Feld liegt hinter der gestylten Beschriftung und war
            // mit 2 Prozent Deckkraft „versteckt". Auf einem Fernseher sieht
            // man das: weisse Schrift in Systemgroesse, blass unter dem
            // eigenen Text — Paul hat es als Schimmern gemeldet, groesser als
            // das, was er getippt hat.
            //
            // Ganz auf null wollte es niemand setzen, vermutlich aus Sorge um
            // den Fokus. Das ist auch nicht noetig: die Ansicht bleibt voll
            // da und fokussierbar, nur ihre Schrift ist durchsichtig. Der
            // sichtbare Text kommt ohnehin aus `beschriftung`.
            //
            // **Beides zusammen, nicht eins von beidem.**
            //
            // Das echte Feld liegt hinter der gestylten Beschriftung. Es war
            // mit 2 Prozent Deckkraft versteckt — dabei blieb seine weisse
            // Schrift in Systemgroesse als Schimmern sichtbar. Nur die
            // Schrift durchsichtig zu machen und die Ebene voll zu lassen war
            // die andere Haelfte des Fehlers: dann sieht man den Hintergrund,
            // den tvOS dem Feld selbst gibt, als Pille im Feld.
            //
            // Also beides: die Ebene fast unsichtbar **und** die Schrift
            // durchsichtig. Fokussierbar bleibt sie, und der sichtbare Text
            // kommt ohnehin aus `beschriftung`.
            feld
                .foregroundStyle(.clear)
                .tint(.clear)
                .opacity(0.02)
                .padding(.horizontal, 30)
        }
        .frame(height: Stil.knopfHoehe)
        .animation(Stil.fokusAnimation, value: fokus)
    }

    @ViewBuilder
    private var beschriftung: some View {
        if text.isEmpty {
            Text(platzhalter)
                .foregroundStyle(fokus ? Stil.grund.opacity(0.45) : Stil.schriftSehrLeise)
        } else {
            Text(sicher ? String(repeating: "\u{2022}", count: text.count) : text)
                .foregroundStyle(fokus ? Stil.grund : Stil.schrift)
        }
    }

    @ViewBuilder
    private var feld: some View {
        if sicher {
            SecureField("", text: $text, onCommit: abschluss)
                .textContentType(inhalt)
                .focused(gebunden)
        } else {
            TextField("", text: $text, onCommit: abschluss)
                .textContentType(inhalt)
                .autocorrectionDisabled()
                .focused(gebunden)
        }
    }
}

// MARK: - Server

/// Erster Schritt: wo steht der Server.
///
/// Wie auf dem iPhone bewusst nur die Wortmarke, kein Signet daneben — zwei
/// Zeichen übereinander sind eines zu viel. Und ein Satz statt Überschrift
/// plus Beschriftung plus Platzhalter.
struct ServerView: View {
    let model: AppModel
    @State private var adresse = ""

    var body: some View {
        VStack(spacing: 0) {
            Wortmarke(hoehe: 72)

            Text("Wo steht dein Jellyfin-Server?")
                .font(Stil.koerper)
                .foregroundStyle(Stil.schriftLeise)
                .padding(.top, 56)

            Eingabefeld(platzhalter: "tv.beispiel.de", text: $adresse,
                        inhalt: .URL, abschluss: verbinden)
                .frame(width: 760)
                .padding(.top, 28)

            Text("Ohne https:// — das ergänzen wir.")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
                .frame(width: 760, alignment: .leading)
                .padding(.top, 12)

            Button("Verbinden", action: verbinden)
                .buttonStyle(KnopfStil())
                .disabled(adresse.isEmpty || model.phase == .connecting)
                .padding(.top, 36)

            if model.phase == .connecting {
                Lader.fern.padding(.top, 40)
            } else if let fehler = model.errorMessage {
                Text(fehler)
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.warnung)
                    .multilineTextAlignment(.center)
                    .frame(width: 900)
                    .padding(.top, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func verbinden() {
        guard !adresse.isEmpty else { return }
        Task { await model.connect(to: adresse) }
    }
}

// MARK: - Anmeldung

/// Zweiter Schritt: Benutzer und Kennwort.
struct AnmeldeView: View {
    let model: AppModel
    let serverName: String
    let version: String?

    @State private var benutzer = ""
    @State private var kennwort = ""
    @State private var quickConnect = false

    var body: some View {
        VStack(spacing: 0) {
            Wortmarke(hoehe: 60)

            Text(serverName)
                .font(Stil.reihe)
                .foregroundStyle(Stil.schrift)
                .padding(.top, 44)

            if let version {
                Text("Jellyfin \(version)")
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .padding(.top, 6)
            }

            VStack(spacing: 20) {
                Eingabefeld(platzhalter: "Benutzername", text: $benutzer,
                            inhalt: .username)
                Eingabefeld(platzhalter: "Kennwort", text: $kennwort,
                            sicher: true, inhalt: .password,
                            abschluss: anmelden)
            }
            .frame(width: 760)
            .padding(.top, 44)

            Button("Anmelden", action: anmelden)
                .buttonStyle(KnopfStil())
                .disabled(benutzer.isEmpty || model.isWorking)
                .padding(.top, 36)

            if model.isWorking {
                Lader.fern.padding(.top, 40)
            } else if let fehler = model.errorMessage {
                Text(fehler)
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.warnung)
                    .multilineTextAlignment(.center)
                    .frame(width: 900)
                    .padding(.top, 32)
            }

            HStack(spacing: 24) {
                // Auf dem Fernseher der bessere Weg als das Kennwortfeld
                // darüber — deshalb steht er gleichberechtigt daneben und
                // nicht in einem Untermenü wie auf dem iPhone.
                Button("Quick Connect") { quickConnect = true }
                    .buttonStyle(KnopfStil())
                Button("Anderer Server") { model.signOut() }
                    .buttonStyle(KnopfStil())
            }
            .padding(.top, 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if quickConnect {
                QuickConnectView(model: model) { quickConnect = false }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: quickConnect)
    }

    private func anmelden() {
        guard !benutzer.isEmpty else { return }
        Task { await model.login(username: benutzer, password: kennwort) }
    }
}
