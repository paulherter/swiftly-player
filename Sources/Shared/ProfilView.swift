import JellyfinKit
import SwiftUI

/// Profil, Quick Connect, Einstellungen, Abmelden.
///
/// Eigene Seite statt Aufklappmenü. Das Menü stand als einziges seiner Art in
/// der App und wirkte wie ein Fremdkörper; dazu hing es an einem 34-pt-Ziel
/// oben in der Ecke, obwohl alles darin ohnehin weiterführt.
///
/// Aufbau aus drei Vorbildern zusammengelegt: der mittige Bildblock von
/// Netflix und Disney+, die flachen Zeilen mit Haarlinien und die nur durch
/// Leerraum getrennten Gruppen von Disney+ und Prime Video. Karten wären
/// Netflix pur und stehen neben unseren flachen Flächen fremd da.
struct ProfilView: View {

    let model: AppModel

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit

    @State private var kontoAufnehmen = false

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    if model.konten.count > 1 { Kontenstreifen(model: model) }
                    else { bildblock }

                    gruppe {
                        Profilzeile(symbol: "rectangle.and.text.magnifyingglass",
                                    titel: "Quick Connect",
                                    unter: "Code vom Fernseher eingeben",
                                    akzent: true, letzte: true, ziel: QuickConnectRoute())
                    }

                    Color.clear.frame(height: 26)

                    gruppe {
                        Profilzeile(symbol: "play.fill", titel: "Wiedergabe",
                                    unter: "Sprache, Untertitel, Tempo",
                                    ziel: WiedergabeRoute())
                        Profilzeile(symbol: "gearshape", titel: "Einstellungen",
                                    letzte: true, ziel: EinstellungenRoute())
                    }

                    Color.clear.frame(height: 26)

                    gruppe {
                        // Ohne Anstrich, und bewusst immer da: wer nur ein
                        // Konto hat, soll nicht das Gefuehl haben, ihm fehle
                        // eines. Fuehrt auf die Anmeldung **ohne Serverfeld**
                        // — es ist derselbe Server.
                        Profilzeile(symbol: "person.badge.plus",
                                    titel: "Weiteres Konto hinzufügen",
                                    unter: "Auf demselben Server") { kontoAufnehmen = true }
                        // **Trifft nur das aktive Konto.** Sind noch andere
                        // da, schaltet die App auf das naechste um; erst beim
                        // letzten geht es zurueck zur Anmeldung. Steht so im
                        // Zustandshalter, nicht hier.
                        Profilzeile(symbol: "rectangle.portrait.and.arrow.right",
                                    titel: "Abmelden", letzte: true) { model.signOut() }
                    }

                    Text(verbatim: Fassung.zeile)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Stil.rand(breit: breit))
                        .padding(.top, 26)
                }
                .padding(.bottom, 40)
                // Breit ein Maß: über die volle iPad-Breite stünde der Pfeil
                // einen halben Meter neben seiner Beschriftung. Mittig, weil
                // der Bildblock darüber es auch ist.
                .frame(maxWidth: breit ? Stil.lesebreite : .infinity)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)

            // Nur der Pfeil, kein Titel — der Bildblock ist der Titel.
            Seitenpfeil { zurueck() }
        }
        #if os(iOS)
        // Ohne das steht Apples Leiste mit eigenem Zurueckpfeil darueber —
        // dann sind es zwei, einer davon aus Glas.
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .fullScreenCover(isPresented: $kontoAufnehmen) {
            // Dieselbe Anmeldung wie beim ersten Konto, nur ohne den Weg zu
            // einem anderen Server — und sie schliesst sich selbst.
            LoginView(model: model,
                      serverName: model.serverName ?? "",
                      version: model.serverVersion ?? "",
                      weiteresKonto: true) { kontoAufnehmen = false }
        }
    }

    private var bildblock: some View {
        VStack(spacing: 10) {
            Profilzeichen(name: model.session?.userName ?? "?",
                          bild: model.benutzerbildURL(groesse: 200),
                          groesse: 84)
            VStack(spacing: 3) {
                Text(model.session?.userName ?? "Angemeldet")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Stil.schrift)
                Text(untertitel)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
        .padding(.bottom, 30)
    }

    private var untertitel: String {
        var teile: [String] = []
        if let name = model.serverName { teile.append(name) }
        if let fassung = model.serverVersion { teile.append("Jellyfin \(fassung)") }
        return teile.joined(separator: " · ")
    }

    /// Haarlinie oben und unten, dazwischen die Zeilen. Keine Karte, keine
    /// Überschrift — getrennt wird nur durch Leerraum.
    private func gruppe<Inhalt: View>(@ViewBuilder _ inhalt: () -> Inhalt) -> some View {
        VStack(spacing: 0) { inhalt() }
            .background(alignment: .top) { Trennlinie() }
            .background(alignment: .bottom) { Trennlinie() }
    }
}

/// Quick Connect: einen Code freigeben, der auf einem anderen Gerät steht.
///
/// Eigene Seite im selben Aufbau wie die Profilseite — Pfeil oben links,
/// Inhalt darunter. Vorher war es ein Blatt mitten im Bild, das seine eigene
/// Gestalt mitbrachte.
struct QuickConnectView: View {
    @Environment(\.breit) private var breit
    let model: AppModel

    @Environment(\.dismiss) private var zurueck
    @FocusState private var imFeld: Bool

    @State private var code = ""
    @State private var laeuft = false
    @State private var meldung: String?
    @State private var geschafft = false

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("Quick Connect")
                    .font(.system(size: 27, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Stil.schrift)
                    .padding(.top, 8)

                Text("Auf dem anderen Gerät steht ein sechsstelliger Code. Gib ihn hier ein, dann meldet es sich mit deinem Konto an.")
                    .font(Stil.koerper)
                    .lineSpacing(3)
                    .foregroundStyle(Stil.schriftLeise)
                    .padding(.top, 10)

                TextField("", text: $code, prompt: Text("000000")
                    .foregroundColor(Color.white.opacity(0.22)))
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .foregroundStyle(Stil.schrift)
                    .focused($imFeld)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.ecke))
                    .overlay { RoundedRectangle(cornerRadius: Stil.ecke).strokeBorder(Stil.rand) }
                    .padding(.top, 26)

                if let meldung {
                    Text(meldung)
                        .font(.system(size: 13))
                        .foregroundStyle(geschafft ? Stil.akzent : Stil.warnung)
                        .padding(.top, 12)
                }

                Button(laeuft ? "Moment…" : "Freigeben") { freigeben() }
                    .buttonStyle(HauptknopfStil())
                    .disabled(laeuft || code.count < 4)
                    .padding(.top, 22)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, 96)
            // Dasselbe Maß wie Anmeldung und Server: ein sechsstelliger Code
            // in einem 1036 Punkt breiten Feld ist absurd.
            .frame(maxWidth: Stil.formularbreite)
            .frame(maxWidth: .infinity)

            Seitenpfeil { zurueck() }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .task {
            // Erst nach dem Übergang: holt man den Fokus sofort, schiebt die
            // aufziehende Tastatur die Seite mitten in der Animation und es
            // zuckt einmal.
            try? await Task.sleep(for: .milliseconds(420))
            imFeld = true
        }
    }

    private func freigeben() {
        laeuft = true
        meldung = nil
        Task {
            defer { laeuft = false }
            do {
                try await model.quickConnectFreigeben(code: code)
                geschafft = true
                meldung = String(localized: "Freigegeben. Das andere Gerät ist gleich angemeldet.")
                try? await Task.sleep(for: .seconds(2))
                zurueck()
            } catch {
                geschafft = false
                // **`lesbar` und nicht `localizedDescription`.**
                //
                // Bei einem `JellyfinError` liefert `localizedDescription`
                // den Typnamen — „The operation couldn't be completed
                // (JellyfinKit.JellyfinError error 2)". `AppModel.lesbar`
                // gibt es genau dafuer, und `Anmeldemodell` sagt im
                // Kommentar daneben, warum. Die Mac-Fassung machte es
                // richtig, diese hier nicht; von der macOS-Sitzung im
                // Tiefendurchgang gefunden.
                meldung = model.lesbar(error)
            }
        }
    }
}

// MARK: - Kontenstreifen

/// Mehrere Jellyfin-Konten auf demselben Server, waagerecht über der Seite.
///
/// **Groß ist, was in der Mitte steht — verbunden ist, was Ring und Punkt
/// trägt.** Die Trennung dieser beiden ist der Kern des Entwurfs. Die Größe
/// folgt dem Scrollen und bedeutet nichts; sie sagt nur, was man gerade
/// ansieht. Erst das Antippen meldet um, und erst danach wandern Akzentring
/// und Punkt mit. Wer beides zusammenlegt, hat einen Streifen gebaut, der
/// beim Scrollen ständig zu wechseln scheint.
///
/// Bei **einem** Konto steht hier nichts — dann bleibt der einzelne Bildblock
/// der Profilseite, unverändert.
private struct Kontenstreifen: View {
    let model: AppModel

    /// Welches Konto gerade mittig steht. Anfangs das angemeldete, damit der
    /// Streifen nicht irgendwo beginnt.
    @State private var zentriert: String?
    /// Breite des Streifens — daraus der Rand, den die äußeren Kacheln
    /// brauchen, um überhaupt in die Mitte scrollen zu können.
    @State private var breite: CGFloat = 0

    /// Ab vier Konten rücken die Nachbarn eine Stufe zurück, sonst passt zu
    /// wenig ins Bild.
    private var viele: Bool { model.konten.count >= 4 }
    private var kleinesMass: CGFloat { viele ? 56 : 64 }
    private var abstand: CGFloat { viele ? 22 : 26 }

    var body: some View {
        VStack(spacing: 0) {
            streifen
            beschriftung
        }
        .padding(.top, 56)
        .padding(.bottom, 30)
        .onAppear { if zentriert == nil { zentriert = model.session?.userID } }
        // Nach einem Wechsel wandert die Mitte auf das neue Konto — sonst
        // stünde der Ring beim einen und die große Kachel beim anderen, ohne
        // dass jemand gescrollt hätte.
        .onChange(of: model.kontowechsel) { _, _ in
            withAnimation(.easeOut(duration: 0.25)) { zentriert = model.session?.userID }
        }
    }

    private var streifen: some View {
        ScrollView(.horizontal) {
            HStack(spacing: abstand) {
                ForEach(model.konten, id: \.userID) { konto in
                    kachel(konto).id(konto.userID)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        // Ohne diesen Rand kommen die äußeren Kacheln nie in die Mitte — der
        // Streifen ließe sich scrollen, das erste und letzte Konto würden
        // aber nie groß.
        .contentMargins(.horizontal, max((breite - 84) / 2, 0), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $zentriert, anchor: .center)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { breite = $0 }
    }

    private func kachel(_ konto: Session) -> some View {
        let verbunden = konto.userID == model.session?.userID
        let mittig = konto.userID == zentriert
        let mass = mittig ? 84 : kleinesMass
        return Button {
            model.kontoWechseln(zu: konto.userID)
        } label: {
            VStack(spacing: 0) {
                // Feste Höhe, damit die Reihe beim Wachsen nicht springt.
                ZStack {
                    Profilzeichen(name: konto.userName,
                                  bild: model.benutzerbildURL(fuer: konto, groesse: 240),
                                  groesse: mass,
                                  hervorgehoben: verbunden)
                }
                .frame(height: 84)

                // Der Punkt gehört zum Ring, nicht zur Größe: beide sagen
                // „verbunden".
                Circle()
                    .fill(verbunden ? Stil.akzent : Color.clear)
                    .frame(width: 5, height: 5)
                    .padding(.top, 8)
                    .frame(height: 13, alignment: .top)
            }
            // Verbunden bleibt hell, auch weit außen. Gedimmt wird nur, was
            // weder verbunden noch angesehen ist.
            .opacity(verbunden || mittig ? 1 : 0.55)
            .animation(.easeOut(duration: 0.2), value: mittig)
        }
        .buttonStyle(.plain)
        // E8: eigene Bedienelemente sagen VoiceOver ihren Zustand.
        .accessibilityLabel(verbunden ? Text("\(konto.userName), angemeldet")
                                      : Text("Zu \(konto.userName) wechseln"))
        .accessibilityAddTraits(verbunden ? [.isButton, .isSelected] : .isButton)
    }

    /// Name dessen, was in der Mitte steht — nicht dessen, was verbunden ist.
    /// Sonst widerspräche die Zeile dem, was darüber groß dasteht.
    private var beschriftung: some View {
        let konto = model.konten.first { $0.userID == zentriert } ?? model.session
        return VStack(spacing: 3) {
            Text(konto?.userName ?? "")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Stil.schrift)
            Text(konto?.userID == model.session?.userID
                 ? "Angemeldet" : "Tippen, um zu wechseln")
                .font(.system(size: 13))
                .foregroundStyle(Stil.akzent)
        }
        .padding(.top, 14)
        .animation(.easeOut(duration: 0.2), value: zentriert)
    }
}
