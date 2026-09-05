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

    /// „Swiftly for Jellyfin 1.0.0 (Build 7)".
    ///
    /// **Aus dem Bündel gelesen, nicht getippt.** Hier stand „Swiftly 1.0" —
    /// eine Zahl, die niemand mitgezogen hat und die seit der ersten Abgabe
    /// falsch war. Eine Fassungsangabe, die man von Hand pflegen muss, ist
    /// schlimmer als keine: sie sieht verlässlich aus.
    ///
    /// Die Baunummer gehört dazu, weil sie in Fehlerberichten die eigentliche
    /// Auskunft ist — „1.0.0" haben acht Builds getragen.
    static var fassungszeile: String {
        let b = Bundle.main.infoDictionary
        let fassung = b?["CFBundleShortVersionString"] as? String ?? "?"
        let bau = b?["CFBundleVersion"] as? String ?? "?"
        return "Swiftly for Jellyfin \(fassung) (Build \(bau))"
    }

    let model: AppModel

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit

    /// Welches Konto gerade **in der Mitte** des Streifens steht.
    ///
    /// Nicht welches angemeldet ist — das ist `model.session?.userID`. Die
    /// beiden auseinanderzuhalten ist der Kern des Entwurfs: groß ist, was in
    /// der Mitte steht, verbunden ist, was Ring und Punkt trägt.
    @State private var mitte: String?
    @State private var kontoAufnehmen = false

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    bildblock

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
                        // **Ohne Anstrich, und über „Abmelden".** Wer nur ein
                        // Konto hat, soll nicht das Gefühl bekommen, ihm fehle
                        // eines — deshalb steht die Zeile still da und nicht
                        // im Akzent wie Quick Connect.
                        Profilzeile(symbol: "person.badge.plus",
                                    titel: "Weiteres Konto hinzufügen",
                                    unter: "Auf demselben Server") {
                            kontoAufnehmen = true
                        }
                        Profilzeile(symbol: "rectangle.portrait.and.arrow.right",
                                    titel: "Abmelden", letzte: true) { model.signOut() }
                    }

                    Text(verbatim: Self.fassungszeile)
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
        // **Ein Blatt, keine Unterseite.** Ein weiteres Konto aufzunehmen ist
        // ein Einschub und kein Ort, an dem man bleibt; danach steht man
        // wieder hier. Der Server steht schon fest, deshalb ohne Serverfeld —
        // `LoginView` ist ohnehin der zweite Schritt und kennt keins.
        .sheet(isPresented: $kontoAufnehmen) {
            LoginView(model: model,
                      serverName: model.serverName ?? "Server",
                      version: model.serverVersion ?? "?",
                      fertig: { kontoAufnehmen = false })
        }
    }

    /// **Ein Kreis, solange es einer ist.** Erst mit dem zweiten Konto wird
    /// daraus ein Streifen. Vorher gäbe es nichts zu wählen, und ein Bild, das
    /// auf Antippen nichts tut, ist schlechter als eins, das gar nicht danach
    /// aussieht.
    @ViewBuilder private var bildblock: some View {
        if model.konten.count > 1 {
            VStack(spacing: 0) {
                Kontenstreifen(model: model, mitte: $mitte)
                beschriftung.padding(.top, 14)
            }
            .padding(.top, 56)
            .padding(.bottom, 30)
        } else {
            VStack(spacing: 10) {
                Profilzeichen(name: model.session?.userName ?? "?",
                              bild: model.benutzerbildURL(groesse: 200),
                              groesse: 84)
                beschriftung
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 56)
            .padding(.bottom, 30)
        }
    }

    /// Name und Zeile darunter — beide gehören dem Konto **in der Mitte**.
    ///
    /// Steht dort ein anderes als das angemeldete, sagt die zweite Zeile, was
    /// zu tun ist. Sonst steht dort der Server, wie bisher. So trägt die
    /// Beschriftung die Bedeutung, die der große Kreis ausdrücklich *nicht*
    /// hat.
    private var beschriftung: some View {
        let konto = model.konten.first { $0.userID == mitte } ?? model.session
        let istAngemeldet = konto?.userID == model.session?.userID
        return VStack(spacing: 3) {
            Text(konto?.userName ?? "Angemeldet")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Stil.schrift)
            if istAngemeldet {
                Text(untertitel)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.45))
            } else {
                Text("Tippen, um zu wechseln")
                    .font(.system(size: 13))
                    .foregroundStyle(Stil.akzent)
            }
        }
        .frame(maxWidth: .infinity)
        // Sonst springt die Seite, wenn der Name eines Kontos zwei Zeilen
        // braucht und der des Nachbarn eine.
        .animation(.easeInOut(duration: 0.15), value: konto?.userID)
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

// MARK: - Der Kontenstreifen

/// Die Konten dieses Servers, waagerecht, mit dem mittleren groß.
///
/// **Zwei Zustände, die man nicht verwechseln darf.**
///
/// *Groß* ist, was gerade in der Mitte steht. Das ändert sich beim Scrollen
/// und bedeutet nichts weiter — es ist die Leserichtung, nicht die Anmeldung.
///
/// *Verbunden* ist, was den Akzentring und den Punkt darunter trägt. Das
/// ändert sich erst beim Antippen. Beide können auf verschiedenen Kreisen
/// liegen, und genau dafür ist der Entwurf gebaut: man schiebt sich durch die
/// Konten, sieht groß, wen man gerade betrachtet, und sieht am Ring weiterhin,
/// wer angemeldet ist.
///
/// Die Vorlage ist `Sources/tvOS/ProfilView.swift`. Verschieden ist nur, was
/// die Eingabeart verlangt: dort trägt der **Fokus**, was hier die Mitte
/// trägt, und dort steht der Streifen fest, weil eine Fernbedienung ihn
/// durchläuft. Hier wird geschoben.
private struct Kontenstreifen: View {
    let model: AppModel
    @Binding var mitte: String?

    /// Breite des Streifens — daraus kommt der Rand, mit dem auch das erste
    /// und das letzte Konto die Mitte erreichen können.
    @State private var breite: CGFloat = 0

    /// Ab vier Konten werden die Nachbarn kleiner, damit mehr hineinpasst.
    /// Der mittlere bleibt bei 84.
    private var nebenGroesse: CGFloat { model.konten.count >= 4 ? 56 : 64 }

    private static let gross: CGFloat = 84

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 22) {
                ForEach(model.konten, id: \.userID) { konto in
                    knopf(konto)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        // Einrasten, damit immer genau ein Konto in der Mitte steht — sonst
        // wäre „groß ist, was in der Mitte steht" eine Behauptung, die
        // zwischen zwei Kreisen niemand einlöst.
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $mitte, anchor: .center)
        // Ohne diesen Rand erreichen das erste und das letzte Konto die Mitte
        // nie: sie stoßen vorher an den Rand des Streifens. (390 − 84) / 2
        // ergibt die 153, mit denen der Entwurf beginnt.
        .contentMargins(.horizontal, max(0, (breite - Self.gross) / 2),
                        for: .scrollContent)
        // **Erst mit der Breite, dann die Mitte.** Der Rand oben haengt an
        // `breite`; solange die null ist, gibt es keinen, und ein Einrasten
        // auf die Mitte liefe ins Leere. Bei zwei Konten faellt das nicht auf
        // — da passt ohnehin alles —, ab vier schon: der Streifen stuende
        // beim Oeffnen am linken Anschlag statt beim angemeldeten Konto.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { neu in
            let ersteMessung = breite == 0
            breite = neu
            if ersteMessung, neu > 0 { mitte = model.session?.userID }
        }
        // Nach einem Wechsel rückt das neue Konto nach — sonst bliebe der
        // Streifen dort stehen, wo der Finger ihn abgelegt hat, und der Ring
        // wanderte allein.
        .onChange(of: model.kontowechsel) { _, _ in
            withAnimation(.snappy(duration: 0.28)) { mitte = model.session?.userID }
        }
    }

    private func knopf(_ konto: Session) -> some View {
        let verbunden = konto.userID == model.session?.userID
        let inDerMitte = konto.userID == mitte
        let groesse = inDerMitte ? Self.gross : nebenGroesse
        return Button {
            guard !verbunden else { return }
            model.kontoWechseln(zu: konto.userID)
        } label: {
            VStack(spacing: 0) {
                // Feste Höhe und mittig: sonst wandern die kleinen Kreise mit
                // ihrer eigenen Höhe nach oben, und der Streifen wippt beim
                // Scrollen.
                Profilzeichen(name: konto.userName,
                              bild: model.benutzerbildURL(fuer: konto, groesse: 240),
                              groesse: groesse,
                              hervorgehoben: verbunden)
                    .frame(height: Self.gross)
                // Der Punkt sagt dasselbe wie der Ring, nur von unten — er
                // trägt die Aussage dorthin, wo auch bei einem hellen
                // Profilbild noch Grund ist.
                Circle()
                    .fill(verbunden ? Stil.akzent : Color.clear)
                    .frame(width: 5, height: 5)
                    .frame(height: 13, alignment: .bottom)
            }
            // Voll nur, was gemeint ist: die Mitte, weil man sie liest, und
            // das verbundene Konto, weil es gilt. Der Rest tritt zurück.
            .opacity(inDerMitte || verbunden ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.24), value: inDerMitte)
        .accessibilityLabel(verbunden ? Text("\(konto.userName), angemeldet")
                                      : Text("Zu \(konto.userName) wechseln"))
        .accessibilityAddTraits(verbunden ? [.isButton, .isSelected] : .isButton)
    }
}
