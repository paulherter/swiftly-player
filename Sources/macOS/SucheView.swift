import JellyfinKit
import SwiftUI

/// Suche. Kein `.searchable` — das bringt auf dem Mac eine eigene Leiste,
/// eigene Ecken und eigenes Material mit. Dasselbe Feld wie bei der Anmeldung,
/// nur breiter.
struct SucheView: View {
    let model: AppModel
    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    @State private var begriff = ""
    @State private var treffer: [Item] = []
    /// Was Seerr kennt und der eigene Server nicht — leer, wenn nichts
    /// angebunden ist.
    @State private var seerrtreffer: [Seerrtreffer] = []
    @State private var gesucht = false
    /// **`nil` heisst gestoert, `[]` heisst nichts gefunden.** `model.suche`
    /// gibt beides getrennt zurueck; hier stand `a ?? []`, und damit wurde
    /// aus einem Netzfehler die Aussage „nichts gefunden".
    @State private var gestoert = false
    /// Laeuft gerade eine Anfrage — dann steht das Raster in seiner Form da
    /// statt eines Rings.
    @State private var laedt = false
    @FocusState private var imFeld: Bool

    /// **Was zuletzt gesucht wurde.** Auf dem Gerät, nicht am Server: die
    /// Liste ist eine Bequemlichkeit, kein Teil des Kontos.
    ///
    /// Gemerkt wird beim Abschicken, nicht beim Tippen — wer „Ga", „Gam",
    /// „Game" eingibt, hat einmal gesucht und nicht dreimal. Die Regel steht
    /// in `Suchverlauf`; der Fernseher und das iPhone zeigen dieselbe Liste.
    @AppStorage(Suchverlauf.schluessel) private var letzteRoh = ""

    private var letzte: [String] { Suchverlauf.liste(letzteRoh) }

    /// **Was hier ueberhaupt zu suchen ist.** Steht nur, solange weder ein
    /// Wort im Feld noch ein Verlauf da ist — sonst stuende ein Hinweis ueber
    /// dem, was er erklaert.
    ///
    /// Mittig unter dem Feld, nicht mittig im Fenster: das Feld steht links
    /// in seiner Breite, und ein Hinweis in der Mitte der ganzen Flaeche
    /// schwebte neben dem, worauf er sich bezieht.
    private var leerhinweis: some View {
        // **Der Baustein, nicht eine zweite Bauart.** Hier stand ein
        // Zeichen in 30 `.light` — ein Gewicht, das es in der Leiter nicht
        // gibt — ohne Kreis und mit einer eigenen Anordnung. Zwei Zeilen
        // weiter benutzt dieselbe Datei den Baustein (BAUTEILE 9.17).
        Leerzustand(symbol: "magnifyingglass",
                    kopfzeile: "Filme, Serien und Folgen durchsuchen")
        .frame(maxWidth: Stil.formularbreite)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 70)
    }

    /// „Zuletzt gesucht" — dieselbe Liste wie auf iPhone und Fernseher, hier
    /// als Zeilen in einer Karte.
    private var zuletzt: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                // Dieselbe Rubrik wie ueber jeder anderen Gruppe — sie war
                // hier die dritte Fassung derselben Ueberschrift.
                Gruppentitel(text: "Zuletzt gesucht")
                Spacer(minLength: 8)
                Button { letzteRoh = "" } label: {
                    Text("Löschen")
                        .font(Stil.koerper.weight(.medium))
                        .foregroundStyle(Stil.akzent)
                }
                .buttonStyle(Stil.Druckknopf())
            }
            .padding(.top, 26)
            .padding(.bottom, 8)

            Karte {
                ForEach(Array(letzte.enumerated()), id: \.offset) { stelle, wort in
                    if stelle > 0 { Blattlinie().padding(.leading, Stil.trennEinzugKarte) }
                    Button { begriff = wort } label: {
                        Wertezeile(symbol: "clock.arrow.circlepath",
                                   titel: Text(verbatim: wort), schwebbar: true)
                    }
                    .buttonStyle(Stil.Druckzeile())
                }
            }
        }
        .frame(maxWidth: Stil.lesebreite, alignment: .leading)
    }

    /// Noch einmal versuchen: derselbe Begriff, ein neuer Anlauf. Ein
    /// Zeichen anzuhaengen und wieder zu loeschen waere der Umweg, den ein
    /// Nutzer sonst gehen muesste.
    private func nochEinmal() {
        let wort = begriff
        begriff = ""
        Task { @MainActor in begriff = wort }
    }

    private var spalten: [GridItem] {
        [GridItem(.adaptive(minimum: Stil.kachelBreite, maximum: Stil.kachelBreite),
                  spacing: Stil.kachelAbstand, alignment: .topLeading)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Suche")
                    .font(Stil.titelGross)
                    .tracking(Stil.sperrungTitel)
                    .foregroundStyle(Stil.schrift)

                Eingabezeile(text: $begriff, symbol: "magnifyingglass",
                             platzhalter: String(localized: "Titel, Serie, Person"),
                             abschluss: { letzteRoh = Suchverlauf.merken(begriff, in: letzteRoh) })
                    .frame(maxWidth: Stil.formularbreite)
                    .padding(.top, 14)
                    .focused($imFeld)

                // Ohne Wort im Feld: woran man zuletzt war. Ein Klick sucht
                // es noch einmal.
                if begriff.isEmpty {
                    if letzte.isEmpty { leerhinweis } else { zuletzt }
                }

                if laedt, treffer.isEmpty, seerrtreffer.isEmpty {
                    // **Kein Ladering.** Das Raster steht schon in seiner
                    // Form da und wird ueberblendet, sobald die Treffer
                    // ankommen — wie auf iPhone und Fernseher.
                    Rasterplatzhalter(spalten: 6, reihen: 2)
                        .padding(.top, 24)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                } else if !treffer.isEmpty {
                    LazyVGrid(columns: spalten, alignment: .leading, spacing: 20) {
                        ForEach(treffer, id: \.id) { eintrag in
                            Button { navigator.oeffne(.titel(eintrag), in: bereich) } label: {
                                Posterkachel(titel: eintrag.name,
                                             zweitzeile: eintrag.trefferauskunft,
                                             bild: model.imageURL(for: eintrag, hochkant: true),
                                             fortschritt: eintrag.userData?.playedPercentage.map { $0 / 100 },
                                             marke: Anzeigeregeln.kachelmarke(
                                             art: eintrag.type,
                                             staffeln: eintrag.childCount,
                                             gesehen: eintrag.userData?.played,
                                             offeneFolgen: eintrag.userData?.unplayedItemCount),
                                             zeichen: eintrag.type == "Series" ? "tv" : "film")
                            }
                            .buttonStyle(Stil.Druckknopf())
                        }
                    }
                    .padding(.top, 24)
                } else if gesucht, gestoert, !begriff.isEmpty, seerrtreffer.isEmpty {
                    // Derselbe Text wie in der Bibliothek, samt
                    // Serveradresse — eine Ursache, eine Diagnose.
                    Leerzustand(
                        symbol: "externaldrive.badge.xmark",
                        kopfzeile: "Server ist abgetaucht",
                        text: "\(model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                        hauptknopf: ("Erneut versuchen", { nochEinmal() }))
                        .padding(.top, 120)
                } else if gesucht, !begriff.isEmpty, seerrtreffer.isEmpty {
                    // **Beide leer, nicht nur die Bibliothek.** Stuende hier
                    // `treffer.isEmpty`, gewaenne dieser Zweig, sobald der
                    // eigene Server nichts hat — und der Seerr-Block darunter
                    // wuerde nie erreicht. Genau der Fall, fuer den die ganze
                    // Anbindung gebaut ist.
                    // Wortlaut und Zeichen wie auf dem iPhone — die Suche
                    // sagt, wonach sie nichts gefunden hat, und der zweite
                    // Satz nimmt die Schaerfe heraus.
                    Leerzustand(symbol: "magnifyingglass",
                                kopfzeile: "Nichts gefunden zu \u{201E}\(begriff)\u{201C}",
                                text: "Auf deinem Server steht dazu nichts. Manchmal ist es nur ein Buchstabe.")
                        .padding(.top, 120)
                }

                if !seerrtreffer.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        // **Reihenüberschrift, nicht Versalien.** 13
                        // Semifett steht in keiner Leiter (13 gibt es nur als
                        // Medium), und `Gruppentitel` trägt längst
                        // Normalschreibung — das war die dritte Fassung
                        // derselben Überschrift (BAUTEILE 9.3).
                        Text("Kann angefragt werden")
                            .font(Stil.reihe)
                            .tracking(Stil.sperrungReihe)
                            .foregroundStyle(Stil.schriftLeise)
                        Spacer(minLength: 8)
                        Zaehlmarke(anzahl: seerrtreffer.count)
                    }
                    .padding(.top, treffer.isEmpty ? 30 : 40)

                    LazyVGrid(columns: spalten, alignment: .leading, spacing: 20) {
                        ForEach(seerrtreffer) { t in
                            Button { navigator.oeffne(.seerrTitel(t), in: bereich) } label: {
                                Seerrkachel(treffer: t)
                            }
                            .buttonStyle(Stil.Druckknopf())
                        }
                    }
                    .padding(.top, 18)
                }
            }
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        // **Die milchige Leiste am oberen Rand.** macOS 26 legt sie von sich
        // aus über jede Scrollfläche — sie war nie in unserem Code, und
        // deshalb habe ich zweimal an der falschen Stelle gesucht. Über dem
        // Bild verlor sie sich, links auf blankem Grund stand sie als Balken.
        //
        // E4 wieder: was das Rahmenwerk ungefragt dazustellt, gehört ebenso
        // abgestellt wie das, was man selbst hinschreibt.
        .seitenscrollen()
        .onAppear { imFeld = true }
        .task(id: begriff) {
            // **Die Regel kommt aus dem Paket, nicht von hier.** Hier stand
            // `begriff.count > 1` — dasselbe Ergebnis, aber ohne Trimmen:
            // ein Leerzeichen und ein Buchstabe loesten auf dem Mac schon
            // eine Anfrage aus, auf dem iPhone nicht. Und der Wert haette
            // sich beim naechsten Mal an einer Stelle geaendert.
            guard Anzeigeregeln.suchbegriffTaugt(begriff) else {
                treffer = []; seerrtreffer = []; gesucht = false
                gestoert = false; laedt = false; return
            }
            // Kurz warten, statt bei jedem Tastendruck zu fragen.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            laedt = true
            // **Nebeneinander, nicht nacheinander.** Seerr ist eine Zugabe;
            // kommt von dort nichts oder kommt es spaet, steht trotzdem
            // sofort da, was der eigene Server hat.
            async let eigene = model.suche(begriff)
            async let fremde = model.seerr.suchen(begriff)
            let (a, b) = await (eigene, fremde)
            // **Doppelte Kennungen raus, bevor sie in ein `ForEach` gehen.**
            //
            // Am 07.09.2026 gemeldet: auf „Zuletzt hinzugefuegt" oeffnete ein
            // Druck auf eine Serie die uebernaechste. `ForEach` ordnet ueber
            // die Kennung zu, und der Server liefert denselben Titel
            // gelegentlich zweimal. Die iPhone-Fassung faengt das hier ab —
            // die Mac-Fassung hatte den Schutz nie bekommen.
            gestoert = a == nil
            treffer = Listenregeln.ohneDoppelte(a ?? [])
            // Was schon auf dem Server liegt, gehoert in den oberen Block —
            // sonst staende derselbe Titel zweimal auf der Seite.
            seerrtreffer = b.filter { !$0.stand.schonDa }
            gesucht = true
            laedt = false
        }
        .onReceive(NotificationCenter.default.publisher(for: Kommandopost.name)) { post in
            if Kommandopost.empfangen(post) == .suche { imFeld = true }
        }
    }
}
