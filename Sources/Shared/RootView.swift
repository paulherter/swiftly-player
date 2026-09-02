import JellyfinKit
import SwiftUI

struct RootView: View {
    @State private var model = AppModel()
    /// Der Vorhang liegt über allem, bis die Animation durch ist.
    @State private var gestartet = false

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
        .overlay {
            #if os(iOS)
            if !gestartet {
                Startvorhang {
                    withAnimation(.easeOut(duration: 0.45)) { gestartet = true }
                }
            }
            #endif
        }
        .animation(.default, value: model.phase)
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

                Text("Ohne https:// — das ergänzen wir.")
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 9)
                    .padding(.leading, 2)

                if model.phase == .connecting {
                    Lader().frame(height: 48).padding(.top, 22)
                } else {
                    Button("Verbinden", action: verbinden)
                        .buttonStyle(HauptknopfStil())
                        .padding(.top, 22)
                        .disabled(adresse.isEmpty)
                        .opacity(adresse.isEmpty ? 0.4 : 1)
                }

                if let fehler = model.errorMessage {
                    // Der Fehler steht unter dem Feld, das ihn ausgelöst hat,
                    // nicht am Seitenende.
                    Text(fehler)
                        .font(Stil.klein)
                        .foregroundStyle(Stil.warnung)
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
                            .font(.system(size: 15))
                            .foregroundStyle(Stil.schrift)
                        Text("\(letzte.adresse) · Jellyfin \(letzte.version)")
                            .font(.system(size: 12))
                            .foregroundStyle(Stil.schriftSehrLeise)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.28))
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Trennlinie()
        }
        .padding(.top, 36)
    }

    private func verbinden() {
        guard !adresse.isEmpty else { return }
        Task { await model.connect(to: adresse) }
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
        .safeAreaInset(edge: .bottom) {
            Button("Anderer Server") { model.signOut() }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Stil.schriftSehrLeise)
                .padding(.bottom, 22)
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
                    .font(.system(size: 12))
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
                        .buttonStyle(.plain)
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

            if model.isWorking {
                Lader().frame(height: 48).padding(.top, 10)
            } else {
                Button("Anmelden", action: anmelden)
                    .buttonStyle(HauptknopfStil())
                    .padding(.top, 10)
                    .disabled(benutzer.isEmpty)
                    .opacity(benutzer.isEmpty ? 0.4 : 1)
            }

            if let fehler = model.errorMessage {
                Text(fehler)
                    .font(Stil.klein)
                    .foregroundStyle(Stil.warnung)
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
                    .font(.system(size: 12))
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
            .buttonStyle(NebenknopfStil())
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
            ZStack {
                Circle().fill(Stil.erhoeht)
                if let bild {
                    Bild(url: bild).clipShape(Circle())
                } else {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(gewaehlt ? Stil.schrift : Stil.schriftLeise)
                }
            }
            .frame(width: 60, height: 60)
            .overlay {
                Circle().strokeBorder(gewaehlt ? Stil.akzent : Stil.rand,
                                      lineWidth: gewaehlt ? 2 : 1)
            }
            Text(name)
                .font(.system(size: 13))
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
    }
}

// MARK: - Bibliotheken

