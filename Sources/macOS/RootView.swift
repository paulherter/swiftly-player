import JellyfinKit
import SwiftUI

/// Dieselben drei Zustände wie auf iPhone und Fernseher, aus demselben
/// `AppModel`. Nur die Ansichten dahinter sind eigen.
///
/// Kein Startvorhang: die Lottie-Animation braucht eine Zeichenfläche, die
/// heute nur als `UIViewRepresentable` vorliegt. Sobald
/// `Sources/Shared/Startanimation.swift` einen NSView-Arm hat, gehört sie auch
/// hierher — die Marke soll überall gleich auffahren.
struct RootView: View {
    @State private var model = AppModel()

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
        .background(Fensteranstrich())
        .animation(.default, value: model.phase)
    }
}

// MARK: - Server eingeben

/// Wo steht der Server. Ein Satz, ein Feld, ein Knopf — wie auf dem iPhone,
/// nur mittig im Fenster statt oben am Bildschirm.
struct ServerView: View {
    let model: AppModel
    @State private var adresse = ""
    @FocusState private var imFeld: Bool

    var body: some View {
        VStack(spacing: 0) {
            Wortmarke(hoehe: 44)

            Text("Wo steht dein Jellyfin-Server?")
                .font(Stil.koerper)
                .foregroundStyle(Stil.schriftLeise)
                .padding(.top, 40)

            Eingabezeile(text: $adresse, symbol: "globe",
                         platzhalter: "tv.beispiel.de", abschluss: verbinden)
                .frame(width: 360)
                .padding(.top, 24)
                .focused($imFeld)

            if let fehler = model.errorMessage {
                Text(fehler)
                    .font(Stil.zweitzeile)
                    .foregroundStyle(Stil.warnung)
                    .multilineTextAlignment(.center)
                    .frame(width: 360)
                    .padding(.top, 12)
            }

            Hauptknopf(beschriftung: "Verbinden", symbol: "arrow.right",
                       auswahl: verbinden)
                .padding(.top, 24)
                .disabled(adresse.isEmpty || model.isWorking)
                .opacity(adresse.isEmpty ? 0.4 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { imFeld = true }
    }

    private func verbinden() {
        guard !adresse.isEmpty else { return }
        Task { await model.connect(to: adresse) }
    }
}

// MARK: - Anmelden

struct AnmeldeView: View {
    let model: AppModel
    let serverName: String
    let version: String

    @State private var benutzer = ""
    @State private var kennwort = ""
    @FocusState private var feld: Feld?

    private enum Feld { case benutzer, kennwort }

    var body: some View {
        VStack(spacing: 0) {
            Wortmarke(hoehe: 44)

            Text(serverName)
                .font(Stil.titel)
                .foregroundStyle(Stil.schrift)
                .padding(.top, 34)
            Text(verbatim: "Jellyfin \(version)")
                .font(Stil.zweitzeile)
                .foregroundStyle(Stil.schriftSehrLeise)
                .padding(.top, 4)

            Eingabezeile(text: $benutzer, symbol: "person",
                         platzhalter: String(localized: "Benutzername")) { feld = .kennwort }
                .frame(width: 360)
                .padding(.top, 28)
                .focused($feld, equals: .benutzer)

            Eingabezeile(text: $kennwort, symbol: "lock", geheim: true,
                         platzhalter: String(localized: "Passwort"), abschluss: anmelden)
                .frame(width: 360)
                .padding(.top, 10)
                .focused($feld, equals: .kennwort)

            if let fehler = model.errorMessage {
                Text(fehler)
                    .font(Stil.zweitzeile)
                    .foregroundStyle(Stil.warnung)
                    .multilineTextAlignment(.center)
                    .frame(width: 360)
                    .padding(.top, 12)
            }

            Hauptknopf(beschriftung: "Anmelden", symbol: "arrow.right",
                       auswahl: anmelden)
                .padding(.top, 24)
                .disabled(benutzer.isEmpty || model.isWorking)
                .opacity(benutzer.isEmpty ? 0.4 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { feld = .benutzer }
    }

    private func anmelden() {
        guard !benutzer.isEmpty else { return }
        Task { await model.login(username: benutzer, password: kennwort) }
    }
}

// MARK: - Eingabefeld

/// Eigenes Feld statt `TextField` mit Systemrahmen: der bringt auf dem Mac
/// eine helle Fläche und eine eigene Ecke mit. Der Rahmen ist hier eine
/// Haarlinie in Weiß 12 %, die Ecke 10 — dieselben Werte wie auf dem iPhone.
struct Eingabezeile: View {
    @Binding var text: String
    let symbol: String
    var geheim = false
    let platzhalter: String
    var abschluss: () -> Void = {}

    @FocusState private var drin: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Stil.schriftSehrLeise)
                .frame(width: 17)

            Group {
                if geheim {
                    SecureField("", text: $text, prompt: platz)
                } else {
                    TextField("", text: $text, prompt: platz)
                }
            }
            .textFieldStyle(.plain)
            .font(Stil.koerper)
            .foregroundStyle(Stil.schrift)
            .focused($drin)
            .onSubmit(abschluss)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.eckeFeld))
        .overlay(RoundedRectangle(cornerRadius: Stil.eckeFeld)
            .strokeBorder(drin ? Stil.akzent.opacity(0.5) : Stil.rand, lineWidth: 1))
        .animation(.easeInOut(duration: 0.15), value: drin)
    }

    private var platz: Text {
        Text(verbatim: platzhalter).foregroundColor(Stil.schriftSehrLeise)
    }
}
