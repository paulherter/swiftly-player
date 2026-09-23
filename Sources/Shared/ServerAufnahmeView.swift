import JellyfinKit
import SwiftUI

/// **Einen zweiten Jellyfin-Server hinzufügen.**
///
/// Adresse, dann Name und Passwort — wie beim ersten Anmelden, nur ohne dass
/// die laufende Sitzung etwas davon merkt. Erst wenn die Anmeldung dort
/// klappt, kommt der Server in den Bund, und die App wechselt zu ihm. Wer
/// abbricht, ist wieder genau da, wo er war.
///
/// Dieselben Bausteine wie `LoginView`: Eingabefeld, Hauptknopf, der Kopf mit
/// „Verbunden · Jellyfin …". Die Zugangsdaten werden hier eingegeben und nur
/// an den Server geschickt; gemerkt wird allein die Sitzung, die er ausgibt.
struct ServerAufnahmeView: View {
    let model: AppModel
    /// Ein Server, der schon im Bund ist — dann geht es um ein weiteres Konto
    /// dort, und die Adresse steht schon da.
    var voreingestellt: URL? = nil
    /// **Was am Ende geschieht — oder nichts, dann geht die Seite zurueck.**
    ///
    /// Sie wurde als Blatt aufgerufen und brauchte deshalb jemanden, der das
    /// Blatt schliesst. Als geschobene Seite schliesst sie sich selbst; der
    /// Rueckruf bleibt fuer die Aufrufer, die daneben noch etwas aufraeumen.
    var fertig: (() -> Void)? = nil

    @Environment(\.dismiss) private var schliessen

    private func beenden() {
        if let fertig { fertig() } else { schliessen() }
    }

    @State private var adresse = ""
    @State private var server: (name: String, fassung: String)?
    @State private var pruefe = false
    @State private var benutzer = ""
    @State private var passwort = ""
    @State private var quickConnect = false
    /// „Erweitert" — eigene Header für einen Dienst vor dem Server.
    @State private var koepfe: [Kopfzeile] = []

    /// Was oben neben dem Rueckweg steht — er wechselt mit dem Stand.
    private var seitentitel: String {
        if let server { return server.name }
        return voreingestellt == nil ? String(localized: "Server hinzufügen")
                                     : String(localized: "Konto hinzufügen")
    }

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    kopf
                    // Mit eingetragener Adresse gibt es nichts einzutippen — das
                    // Feld erscheint nur, wenn der Server nicht antwortet.
                    if server != nil { anmeldeteil }
                    else if voreingestellt == nil || model.errorMessage != nil { adressteil }
                    if let fehler = model.errorMessage {
                        Text(fehler)
                            .font(Stil.klein)
                            // Der Server hat nicht geantwortet — das ist
                            // schiefgegangen, nicht abwartend. `fehler`.
                            .foregroundStyle(Stil.fehler)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
                .frame(maxWidth: Stil.formularbreite)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            // **Der Rueckweg ist der Abbruch.** Unten stand eine eigene Zeile
            // „Abbrechen" — die brauchte es, solange die Ansicht als Blatt
            // kam und nur so zu schliessen war. Als geschobene Seite hat sie
            // oben denselben Rueckweg wie jede andere, und zwei Wege zurueck
            // sind einer zu viel.
            .safeAreaInset(edge: .top, spacing: 0) {
                Unterseitenkopf(titel: seitentitel) {
                    model.serverAufnahmeAbbrechen()
                    beenden()
                } rechts: { EmptyView() }
            }
        }
        #if os(iOS)
        // Ohne das steht Apples Leiste mit eigenem Rueckpfeil darueber — dann
        // sind es zwei, und einer davon ist aus Glas. Genau das war hier zu
        // sehen, weil die Ansicht als Blatt entstanden ist und die Leiste nie
        // gebraucht hat.
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .onAppear {
            model.serverAufnahmeAbbrechen()
            if let voreingestellt {
                adresse = voreingestellt.absoluteString
                pruefen()
            }
        }
        .fullScreenCover(isPresented: $quickConnect) {
            QuickConnectAnmeldung(model: model, neuerServer: true) { beenden() }
        }
    }

    /// **Kein eigener grosser Titel mehr.**
    ///
    /// Hier stand der Seitenname in 28 Bold, 48 Punkt unter der Statusleiste —
    /// die Bauart einer Wurzelseite. Als geschobene Unterseite traegt ihn die
    /// Leiste oben neben dem Rueckweg, wie auf jeder anderen Unterseite auch.
    /// Was bleibt, ist, was der Titel nicht sagen kann: der Verbindungsstand
    /// und die Erklaerung.
    @ViewBuilder
    private var kopf: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let server {
                HStack(spacing: 8) {
                    Circle().fill(Stil.akzent).frame(width: 7, height: 7)
                    Text("Verbunden · Jellyfin \(server.fassung)")
                        // Die Angabe der Leiter, 12 Regular. Vorher als Zahl.
                        .font(Stil.klein)
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
            } else if let voreingestellt {
                Text(verbatim: voreingestellt.host() ?? voreingestellt.absoluteString)
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
            } else {
                Text("Die Adresse eines weiteren Jellyfin-Servers. Du bleibst bei beiden angemeldet und wechselst auf der Profilseite zwischen ihnen.")
                    .font(Stil.koerper)
                    .lineSpacing(3)
                    .foregroundStyle(Stil.schriftLeise)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var adressteil: some View {
        VStack(spacing: 10) {
            Eingabefeld(text: $adresse, symbol: "externaldrive.connected.to.line.below",
                        platzhalter: "tv.example.de", abschluss: pruefen)
            Erweitertbereich(zeilen: $koepfe)
            Button(pruefe ? "Verbinden…" : "Verbinden", action: pruefen)
                .buttonStyle(HauptknopfStil())
                .padding(.top, 10)
                .disabled(pruefe || adresse.isEmpty)
                .opacity(adresse.isEmpty ? 0.4 : 1)
        }
        .padding(.top, 28)
    }

    private var anmeldeteil: some View {
        VStack(spacing: 10) {
            Eingabefeld(text: $benutzer, symbol: "person", platzhalter: "Benutzername")
            Eingabefeld(text: $passwort, symbol: "lock", platzhalter: "Passwort",
                        geheim: true, abschluss: anmelden)
            Button(model.isWorking ? "Anmelden…" : "Anmelden", action: anmelden)
                .buttonStyle(HauptknopfStil())
                .padding(.top, 10)
                .disabled(model.isWorking || benutzer.isEmpty)
                .opacity(benutzer.isEmpty ? 0.4 : 1)

            // Wie beim ersten Anmelden: Quick Connect als zweiter Weg — ohne
            // Passwort auf dem Telefon, freigegeben an einem Gerät, an dem man
            // am neuen Server schon angemeldet ist.
            HStack(spacing: 12) {
                Rectangle().fill(Stil.linie).frame(height: 1)
                Text("oder")
                    // Die Angabe der Leiter, 12 Regular. Vorher als Zahl.
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
                Rectangle().fill(Stil.linie).frame(height: 1)
            }
            .padding(.top, 16)
            Button {
                quickConnect = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "tv")
                    Text("Mit Quick Connect anmelden")
                }
            }
            .buttonStyle(NebenknopfStil(akzent: true))
            .padding(.top, 10)
        }
        .padding(.top, 28)
    }

    private func pruefen() {
        guard !adresse.isEmpty, !pruefe else { return }
        pruefe = true
        Task {
            let antwort = await model.serverPruefen(adresse, koepfe: koepfe.koepfe)
            // Der Anmeldeteil kommt, weil der Server geantwortet hat — genau
            // der Fall, für den `Stil.einblenden` da ist. Vorher eine eigene
            // `.easeInOut(0,2)`.
            withAnimation(Stil.einblenden) { server = antwort }
            pruefe = false
        }
    }

    private func anmelden() {
        guard !benutzer.isEmpty else { return }
        Task {
            if await model.anmeldenAmNeuenServer(benutzer: benutzer, passwort: passwort) {
                passwort = ""
                beenden()
            }
        }
    }
}
