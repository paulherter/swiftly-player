import JellyfinKit
import SwiftUI

/// **Einen zweiten Jellyfin-Server hinzufügen.**
///
/// Adresse eintippen, dann anmelden — und zwar **per Quick Connect zuerst**.
/// Auf dem Mac steht Name und Passwort vorn, hier ist es umgekehrt: ein
/// Kennwort mit der Fernbedienung einzugeben heißt, sich Buchstabe für
/// Buchstabe durch ein Raster zu wischen. Dieselbe Abwägung wie beim ersten
/// Anmelden (VERHALTEN.md F).
///
/// Die laufende Sitzung merkt nichts davon: erst wenn die Anmeldung drüben
/// klappt, kommt der Server in den Bund und die App wechselt dorthin. Wer
/// abbricht, steht wieder genau da, wo er war.
struct ServerAufnahmeView: View {
    let model: AppModel
    let schliessen: () -> Void

    @State private var adresse = ""
    @State private var server: (name: String, fassung: String)?
    @State private var pruefe = false
    @State private var benutzer = ""
    @State private var passwort = ""
    /// Der Code-Weg läuft erst an, wenn der Server steht — sonst zöge jeder
    /// Besuch dieser Seite einen Code bei einem Server, den es noch nicht gibt.
    @State private var perCode = true
    @State private var stand = QuickConnectModell()

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("Server hinzufügen")
                    .font(Stil.titelGross)
                    .foregroundStyle(Stil.schrift)

                Text("Ein zweiter Jellyfin mit eigenen Konten. Beide bleiben angemeldet; im Profil wechselst du zwischen ihnen.")
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .frame(width: 900, alignment: .leading)
                    .padding(.top, 16)

                if let server { anmeldung(server) } else { adressteil }

                if let fehler = model.errorMessage {
                    Text(verbatim: fehler)
                        .font(Stil.klein)
                        .foregroundStyle(Stil.warnung)
                        .padding(.top, 24)
                }

                Button("Abbrechen") {
                    stand.anhalten()
                    model.serverAufnahmeAbbrechen()
                    schliessen()
                }
                .buttonStyle(KnopfStil())
                .padding(.top, 44)
            }
            .frame(width: 900, alignment: .leading)
        }
        .onAppear {
            // **Aufräumen, bevor es losgeht.** Ein abgebrochener Versuch
            // hinterlässt sonst seinen Server und seine Fehlermeldung.
            model.serverAufnahmeAbbrechen()
            stand.neuerServer = true
        }
        .onDisappear { stand.anhalten() }
        // Der Code wird geholt, sobald ein Server dasteht — und nur dann.
        .task(id: "\(server?.name ?? "")|\(perCode)") {
            guard server != nil, perCode else { return }
            await stand.neuStarten(model)
        }
        .onChange(of: stand.freigegeben) { _, neu in
            guard let neu else { return }
            // **Kein Schliessen von hier aus.** Die Anmeldung wechselt auf den
            // neuen Server; die Seite darüber geht mit dem Wechsel ohnehin zu.
            Task { _ = await model.anmeldenMitQuickConnectAmNeuenServer(neu) }
        }
    }

    // MARK: Adresse

    private var adressteil: some View {
        VStack(alignment: .leading, spacing: 20) {
            Eingabefeld(platzhalter: "tv.beispiel.de", text: $adresse,
                        inhalt: .URL, abschluss: pruefen)
                .frame(width: 760)

            Text("https:// kannst du weglassen.")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)

            Button(pruefe ? "Moment…" : "Weiter", action: pruefen)
                .buttonStyle(KnopfStil())
                .disabled(adresse.isEmpty || pruefe)
        }
        .padding(.top, 44)
    }

    // MARK: Anmelden

    @ViewBuilder
    private func anmeldung(_ server: (name: String, fassung: String)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // **Kein Akzent.** Name und Fassung des Servers sind Auskunft,
            // keine Auswahl — der Ton traegt Fortschritt, Auswahl und den
            // Direct-Play-Beleg (GESTALTUNG A).
            Text(verbatim: "\(server.name) · Jellyfin \(server.fassung)")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftLeise)

            if perCode { codeteil } else { formular }
        }
        .padding(.top, 44)
    }

    @ViewBuilder
    private var codeteil: some View {
        Text("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du an diesem Server schon angemeldet bist.")
            .font(Stil.koerper)
            .foregroundStyle(Stil.schriftLeise)
            .frame(width: 900, alignment: .leading)
            .padding(.top, 24)

        if let vorgang = stand.vorgang {
            Text(verbatim: vorgang.code)
                .font(.system(size: 80, weight: .bold).monospacedDigit())
                .tracking(14)
                .foregroundStyle(Stil.schrift)
                .padding(.top, 24)
            Text("Läuft ab in \(stand.restsekunden / 60):\(String(format: "%02d", stand.restsekunden % 60))")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
                .padding(.top, 12)
        } else if let fehler = stand.fehler {
            Text(verbatim: fehler)
                .font(Stil.koerper)
                .foregroundStyle(Stil.warnung)
                .padding(.top, 24)
        }

        Button("Lieber Name und Passwort") {
            stand.anhalten()
            perCode = false
        }
        .buttonStyle(KnopfStil())
        .padding(.top, 32)
    }

    @ViewBuilder
    private var formular: some View {
        VStack(alignment: .leading, spacing: 20) {
            Eingabefeld(platzhalter: "Benutzername", text: $benutzer, inhalt: .username)
            Eingabefeld(platzhalter: "Passwort", text: $passwort,
                        sicher: true, inhalt: .password, abschluss: anmelden)

            HStack(spacing: 24) {
                Button(model.isWorking ? "Moment…" : "Anmelden", action: anmelden)
                    .buttonStyle(KnopfStil())
                    .disabled(benutzer.isEmpty || model.isWorking)
                Button("Lieber Quick Connect") { perCode = true }
                    .buttonStyle(KnopfStil())
            }
        }
        .frame(width: 760, alignment: .leading)
        .padding(.top, 24)
    }

    // MARK: Ablauf

    private func pruefen() {
        guard !adresse.isEmpty, !pruefe else { return }
        pruefe = true
        Task {
            let antwort = await model.serverPruefen(adresse)
            withAnimation(Stil.einblenden) { server = antwort }
            pruefe = false
        }
    }

    private func anmelden() {
        guard !benutzer.isEmpty else { return }
        Task {
            if await model.anmeldenAmNeuenServer(benutzer: benutzer, passwort: passwort) {
                passwort = ""
            }
        }
    }
}
