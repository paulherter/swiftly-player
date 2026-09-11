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
    /// Jemand hat auf „Server hinzufuegen" getippt — siehe dort.
    @State private var zweiterServer = false
    /// Ein weiteres Konto auf einem Server, mit dem wir gerade nicht verbunden
    /// sind — aus dem Plus auf dessen Karte.
    @State private var kontoAufServer: URL?

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            VStack(spacing: 0) {
                // **Ein Seitentitel wie ueberall sonst, neben dem Pfeil.**
                //
                // Hier stand keiner, mit der Begruendung, der Bildblock sei
                // der Titel. Das stimmte, solange er die halbe Seite einnahm
                // und mittig stand; als Karte ist er ein Gegenstand auf der
                // Seite und kein Kopf mehr.
                Unterseitenkopf(titel: String(localized: "Profil")) { zurueck() }

            ScrollView {
                VStack(spacing: 0) {
                    Kontokarte(model: model, hinzufuegenAuf: { kontoAufServer = $0 }) { kontoAufnehmen = true }

                    Color.clear.frame(height: 20)

                    gruppe {
                        Profilzeile(symbol: "rectangle.and.text.magnifyingglass",
                                    titel: "Quick Connect",
                                    unter: "Code vom Fernseher eingeben",
                                    akzent: true, letzte: true, ziel: QuickConnectRoute())
                    }

                    Color.clear.frame(height: 18)

                    gruppe {
                        Profilzeile(symbol: "play.fill", titel: "Wiedergabe",
                                    unter: "Sprache, Untertitel, Tempo",
                                    ziel: WiedergabeRoute())
                        Profilzeile(symbol: "square.grid.2x2", titel: "Darstellung",
                                    unter: "Startseite, Reihen, Genres",
                                    ziel: DarstellungRoute())
                        Profilzeile(symbol: "gearshape", titel: "Einstellungen",
                                    letzte: true, ziel: EinstellungenRoute())
                    }

                    Color.clear.frame(height: 18)

                    gruppe {
                        // **Die Form steht, der Unterbau nicht.** Ein
                        // Kontenbund gehoert im Paket zu genau einem Server;
                        // ein zweiter beruehrt Schluesselbund, Downloads,
                        // Seerr und die Fernsteuerung. Die Zeile ist
                        // entworfen und angeschlossen, damit sie nicht ein
                        // zweites Mal entworfen wird — sie sagt bis dahin,
                        // woran es liegt.
                        Profilzeile(symbol: "externaldrive.connected.to.line.below",
                                    titel: "Server hinzufügen",
                                    unter: "Ein zweiter Jellyfin, eigene Konten") {
                            zweiterServer = true
                        }
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
                // einen halben Meter neben seiner Beschriftung.
                //
                // **Linksbündig, nicht mittig.** Mittig war richtig, solange
                // der Bildblock in der Mitte stand; als Karte haengt er wie
                // alles andere an der linken Kante. Und der Bezug ist die
                // Seitenleiste: was an ihr haengt, faengt an ihrer Kante an,
                // sonst steht die Seite neben ihrer eigenen Navigation.
                .frame(maxWidth: breit ? Stil.lesebreite : .infinity,
                       alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            }

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
        // **Ein zweiter Server** — seit dem 11.09.2026 wirklich. Die laufende
        // Sitzung bleibt, bis die Anmeldung dort klappt; dann wechselt die App.
        .fullScreenCover(isPresented: $zweiterServer) {
            ServerAufnahmeView(model: model) { zweiterServer = false }
        }
        .fullScreenCover(isPresented: Binding(get: { kontoAufServer != nil },
                                              set: { if !$0 { kontoAufServer = nil } })) {
            ServerAufnahmeView(model: model, voreingestellt: kontoAufServer) { kontoAufServer = nil }
        }
    }

    private var bildblock: some View {
        VStack(spacing: 10) {
            Profilzeichen(name: model.session?.userName ?? "?",
                          bild: model.benutzerbildURL(),
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

    /// Eine Gruppe ist seit dem 11.09.2026 eine Karte — siehe ``Karte``.
    ///
    /// `@escaping`, weil `Karte` die Schliessung fuer sich behaelt statt sie
    /// sofort auszuwerten.
    private func gruppe<Inhalt: View>(
        @ViewBuilder _ inhalt: @escaping () -> Inhalt) -> some View {
        Karte(inhalt: inhalt)
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
                // Titel neben dem Pfeil, wie auf den vier anderen Menues —
                // siehe `Unterseitenkopf`.
                Unterseitenkopf(titel: String(localized: "Quick Connect")) { zurueck() }
                    .padding(.horizontal, -Stil.rand(breit: breit))

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
            .padding(.top, 8)
            // Dasselbe Maß wie Anmeldung und Server: ein sechsstelliger Code
            // in einem 1036 Punkt breiten Feld ist absurd.
            .frame(maxWidth: Stil.formularbreite)
            .frame(maxWidth: .infinity)
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
    /// **22, und zwar immer.** Der Entwurf setzt in beiden Artboards
    /// `gap: 22px` — bei zwei Konten wie bei vier. Kleiner werden nur die
    /// Kreise, nicht der Zwischenraum; sonst wandert bei zwei Konten auch der
    /// Rand, und die Zahl aus dem Entwurf stimmt nirgends mehr.
    private static let abstand: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            streifen
            beschriftung
        }
        .padding(.top, 56)
        .padding(.bottom, 30)
        // Nach einem Wechsel wandert die Mitte auf das neue Konto — sonst
        // stünde der Ring beim einen und die große Kachel beim anderen, ohne
        // dass jemand gescrollt hätte.
        .onChange(of: model.kontowechsel) { _, _ in
            withAnimation(.easeOut(duration: 0.25)) { zentriert = model.session?.userID }
        }
    }

    private var streifen: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Self.abstand) {
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
        // **Erst die Breite, dann die Mitte.**
        //
        // Der Rand oben hängt an `breite`; solange die null ist, gibt es
        // keinen, und ein Einrasten auf die Mitte läuft ins Leere. Das stand
        // vorher in `onAppear`, also verlässlich *vor* der ersten Messung.
        //
        // Bei zwei Konten fällt es nicht auf — da passt der Streifen ohnehin
        // nebeneinander. Ab vier stünde er beim Öffnen am linken Anschlag
        // statt beim angemeldeten Konto, und damit fängt ausgerechnet der
        // Fall, für den der Streifen gebaut ist, mit einer Lüge an: groß wäre
        // irgendwer, nur nicht der, den man erwartet.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { neu in
            let ersteMessung = breite == 0
            breite = neu
            if ersteMessung, neu > 0, zentriert == nil {
                zentriert = model.session?.userID
            }
        }
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
                                  bild: model.benutzerbildURL(fuer: konto),
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

/// **Die Kontokarte — A4 aus dem Entwurf vom 11.09.2026.**
///
/// Zwei Achsen, zwei Gesten, und sie sagen zwei verschiedene Sachen: ein
/// Konto in der Reihe **antippen** wechselt den Benutzer auf demselben
/// Server; die Karte **weiterwischen** wechselt den Server. Ein zweites
/// Konto ist der Mitbewohner — gleiche Bibliothek, andere Fortschritte. Ein
/// zweiter Server ist ein anderer Ort.
///
/// **Die zweite Achse ist entworfen, aber nicht gebaut.** Ein Kontenbund
/// gehört im Paket zu genau einem Server; die Karte ist trotzdem schon so
/// gebaut, dass sie mehrere tragen kann, damit sie später niemand ein
/// zweites Mal entwirft. Solange es einen gibt, gibt es keine Punkte und
/// nichts zu wischen — und damit deutet auch nichts auf etwas hin, das es
/// nicht gibt.
///
/// **Randbündig wie jede andere Karte, kein Anschnitt.** Eine angeschnittene
/// Nachbarkarte wäre eine Einladung zum Wischen und bei einem Server ein
/// Anschnitt ohne Nachbarn. Was es mehr gibt, sagen die Punkte.
private struct Kontokarte: View {
    let model: AppModel
    /// Ein Konto auf einem anderen Server als dem verbundenen.
    var hinzufuegenAuf: (URL) -> Void = { _ in }
    let hinzufuegen: () -> Void

    @Environment(\.breit) private var breit
    /// Welcher Server gerade zu sehen ist — zum Blättern, nicht zum Wechseln.
    @State private var seite = ""
    /// Gemessene Höhe jeder Karte — die Seitenfläche nimmt die größte.
    @State private var hoehen: [String: CGFloat] = [:]

    /// **Eine Karte je Server** (Entwurf A3). Innerhalb eines Servers die
    /// Reihe der Konten, zwischen Servern die Karten: man tippt ein Konto an
    /// und wischt die Karte weiter, um zu einem anderen Server zu kommen. Mit
    /// einem Server — dem Normalfall — ist es eine Karte ohne Punkte; nichts
    /// deutet auf etwas hin, das es nicht gibt.
    var body: some View {
        let server = model.server
        if server.count <= 1 {
            karte(model.session?.serverURL)
        } else {
            VStack(spacing: 10) {
                TabView(selection: $seite) {
                    ForEach(server, id: \.absoluteString) { url in
                        karte(url)
                            .fixedSize(horizontal: false, vertical: true)
                            // **Die größte, nicht die zuletzt gemessene.** Sonst
                            // gewann die niedrigere Karte, und die höhere wurde
                            // oben und unten abgeschnitten.
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { neu in
                                if neu > 0 { hoehen[url.absoluteString] = neu }
                            }
                            .frame(maxHeight: .infinity, alignment: .top)
                            .tag(url.absoluteString)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: hoehen.values.max() ?? 170)
                punkte(server)
            }
            .onAppear { seite = model.session?.serverURL.absoluteString ?? "" }
            .onChange(of: model.session?.serverURL) { _, neu in
                if let neu { withAnimation(.easeInOut(duration: 0.25)) { seite = neu.absoluteString } }
            }
        }
    }

    /// Die Punkte darunter sind das Einzige, was sagt, dass hier gewischt
    /// werden kann — und sie erscheinen erst ab dem zweiten Server.
    private func punkte(_ server: [URL]) -> some View {
        HStack(spacing: 7) {
            ForEach(server, id: \.absoluteString) { url in
                Circle()
                    .fill(url.absoluteString == seite ? Stil.schrift : Stil.schriftSehrLeise)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func istAktiv(_ server: URL?) -> Bool {
        server?.absoluteString.lowercased() == model.session?.serverURL.absoluteString.lowercased()
    }

    @ViewBuilder
    private func karte(_ server: URL?) -> some View {
        let alle = server.map { model.konten(auf: $0) } ?? model.konten
        let aktiv = istAktiv(server)
        // Auf dem aktiven Server steht vorn, wer angemeldet ist; auf einem
        // anderen das erste Konto dort — ein Tipp wechselt dorthin.
        let vorn = aktiv ? model.session : alle.first
        let andere = alle.filter { $0.kontoschluessel != vorn?.kontoschluessel }
        Karte {
            kopfzeile(vorn, aktiv: aktiv, server: server)
            Trennlinie().padding(.leading, 0)
            reihe(andere, aktiv: aktiv, server: server)
        }
    }

    @ViewBuilder
    private func kopfzeile(_ konto: Session?, aktiv: Bool, server: URL?) -> some View {
        let inhalt = HStack(spacing: 14) {
            Profilzeichen(name: konto?.userName ?? "?",
                          bild: konto.flatMap { model.benutzerbildURL(fuer: $0) },
                          groesse: 56,
                          hervorgehoben: aktiv && model.server.count > 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: konto?.userName ?? String(localized: "Angemeldet"))
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Stil.schrift)
                // Name und Fassung kennen wir nur vom Server, mit dem wir
                // gerade verbunden sind; bei den anderen steht die Adresse.
                Text(verbatim: aktiv ? (model.serverName ?? server?.host() ?? "")
                                     : (server?.host() ?? ""))
                    .font(.system(size: 13))
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .lineLimit(1)
                if aktiv, let fassung = model.serverVersion {
                    Text(verbatim: "Jellyfin \(fassung)")
                        .font(.system(size: 12))
                        .foregroundStyle(Stil.schriftSehrLeise)
                        .lineLimit(1)
                } else if !aktiv {
                    Text("Antippen zum Wechseln")
                        .font(.system(size: 12))
                        .foregroundStyle(Stil.schriftSehrLeise)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .contentShape(Rectangle())
        if !aktiv, let konto {
            Button { model.kontoWechseln(zu: konto.kontoschluessel) } label: { inhalt }
                .buttonStyle(.plain)
        } else {
            inhalt
        }
    }

    private func reihe(_ andere: [Session], aktiv: Bool, server: URL?) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                // Die Reihe hält ihre Höhe auch leer — sonst ist die Karte
                // eines Servers mit nur einem Konto niedriger als die anderen.
                Color.clear.frame(width: 0, height: 40)
                ForEach(andere, id: \.kontoschluessel) { konto in
                    Button { model.kontoWechseln(zu: konto.kontoschluessel) } label: {
                        Profilzeichen(name: konto.userName,
                                      bild: model.benutzerbildURL(fuer: konto),
                                      groesse: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: konto.userName))
                }
                // **Das Plus steht auf jeder Karte** und legt ein Konto auf
                // *diesem* Server an. Auf dem verbundenen die gewohnte Anmeldung
                // mit „Wer schaut?", auf einem anderen dieselbe wie beim
                // Hinzufügen eines Servers — nur mit schon eingetragener Adresse.
                do {
                    Button {
                        if aktiv { hinzufuegen() } else if let server { hinzufuegenAuf(server) }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Stil.schriftSehrLeise)
                            .frame(width: 40, height: 40)
                            .overlay {
                                Circle().strokeBorder(Stil.rand,
                                                      style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Weiteres Konto hinzufügen"))
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }
}
