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
    let fertig: () -> Void

    @State private var adresse = ""
    @State private var server: (name: String, fassung: String)?
    @State private var pruefe = false
    @State private var benutzer = ""
    @State private var passwort = ""
    @State private var quickConnect = false

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
                            .foregroundStyle(Stil.warnung)
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
            .safeAreaInset(edge: .bottom) {
                Button("Abbrechen") {
                    model.serverAufnahmeAbbrechen()
                    fertig()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Stil.schriftSehrLeise)
                .padding(.bottom, 22)
            }
        }
        .onAppear {
            model.serverAufnahmeAbbrechen()
            if let voreingestellt {
                adresse = voreingestellt.absoluteString
                pruefen()
            }
        }
        .fullScreenCover(isPresented: $quickConnect) {
            QuickConnectAnmeldung(model: model, neuerServer: true) { fertig() }
        }
    }

    @ViewBuilder
    private var kopf: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let server {
                HStack(spacing: 8) {
                    Circle().fill(Stil.akzent).frame(width: 7, height: 7)
                    Text("Verbunden · Jellyfin \(server.fassung)")
                        .font(.system(size: 12))
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
                // Der Name kommt vom Server.
                Text(verbatim: server.name)
                    .font(Stil.titel)
                    .foregroundStyle(Stil.schrift)
            } else if let voreingestellt {
                Text("Konto hinzufügen")
                    .font(Stil.titel)
                    .foregroundStyle(Stil.schrift)
                Text(verbatim: voreingestellt.host() ?? voreingestellt.absoluteString)
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .padding(.top, 4)
            } else {
                Text("Server hinzufügen")
                    .font(Stil.titel)
                    .foregroundStyle(Stil.schrift)
                Text("Die Adresse eines weiteren Jellyfin-Servers. Du bleibst bei beiden angemeldet und wechselst auf der Profilseite zwischen ihnen.")
                    .font(Stil.koerper)
                    .lineSpacing(3)
                    .foregroundStyle(Stil.schriftLeise)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 48)
    }

    private var adressteil: some View {
        VStack(spacing: 10) {
            Eingabefeld(text: $adresse, symbol: "externaldrive.connected.to.line.below",
                        platzhalter: "tv.example.de", abschluss: pruefen)
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
                    .font(.system(size: 12))
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
            .buttonStyle(NebenknopfStil())
            .padding(.top, 10)
        }
        .padding(.top, 28)
    }

    private func pruefen() {
        guard !adresse.isEmpty, !pruefe else { return }
        pruefe = true
        Task {
            let antwort = await model.serverPruefen(adresse)
            withAnimation(.easeInOut(duration: 0.2)) { server = antwort }
            pruefe = false
        }
    }

    private func anmelden() {
        guard !benutzer.isEmpty else { return }
        Task {
            if await model.anmeldenAmNeuenServer(benutzer: benutzer, passwort: passwort) {
                passwort = ""
                fertig()
            }
        }
    }
}
