import JellyfinKit
import SwiftUI

/// Seerr anbinden — die Fernseherfassung.
///
/// **Der Name steht schon da.** Auf beiden Seiten ist es dasselbe Konto;
/// Seerr fragt Jellyfin selbst, ob Name und Passwort stimmen. Getippt wird
/// nur, was wir nicht haben — und mit einer Fernbedienung ist jedes Zeichen
/// teuer, also so wenige wie möglich.
///
/// Als eigene Seite über allem, nicht als Zeile in den Einstellungen: drei
/// Felder und eine Bildschirmtastatur brauchen den Platz, den eine Zeile in
/// einer Liste nicht hat.
struct SeerrAnbindenView: View {
    let model: AppModel
    let seerr: Seerrmodell
    let schliessen: () -> Void

    @State private var adresse = ""
    @State private var benutzer = ""
    @State private var passwort = ""

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("Seerr")
                    .font(Stil.titelGross)
                    .foregroundStyle(Stil.schrift)

                Text("Jellyseerr oder Overseerr. Damit findest du in der Suche auch, was noch nicht auf deinem Server liegt — und kannst es anfragen.")
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .frame(width: 900, alignment: .leading)
                    .padding(.top, 16)

                if seerr.verbunden { verbunden } else { formular }

                HStack(spacing: 24) {
                    Button("Fertig") { schliessen() }
                        .buttonStyle(KnopfStil())
                }
                .padding(.top, 44)
            }
            .frame(width: 900, alignment: .leading)
        }
        .task {
            if benutzer.isEmpty { benutzer = model.session?.userName ?? "" }
            await seerr.nachsehen()
        }
    }

    @ViewBuilder
    private var verbunden: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: seerr.adresse ?? "")
                .font(Stil.koerper).foregroundStyle(Stil.schrift)
            Text(seerr.traegt ? "Sitzung aktiv" : "Sitzung abgelaufen")
                .font(Stil.klein)
                .foregroundStyle(seerr.traegt ? Stil.akzent : Stil.warnung)
            // **Kein „Abmelden", sondern „Trennen".** Bei Seerr selbst bleibt
            // alles, wie es ist — es geht nur um diesen einen Zugang.
            Button("Verbindung trennen") {
                seerr.trennen(); adresse = ""; passwort = ""
            }
            .buttonStyle(KnopfStil())
        }
        .padding(.top, 44)
    }

    @ViewBuilder
    private var formular: some View {
        VStack(alignment: .leading, spacing: 20) {
            Eingabefeld(platzhalter: "seerr.example.de", text: $adresse, inhalt: .URL)
            Eingabefeld(platzhalter: "Benutzername", text: $benutzer, inhalt: .username)
            Eingabefeld(platzhalter: "Passwort", text: $passwort,
                        sicher: true, inhalt: .password)

            if let fehler = seerr.fehler {
                Text(verbatim: fehler)
                    .font(Stil.klein).foregroundStyle(Stil.warnung)
            }

            // Kein gesperrter Knopf: solange nichts dasteht, ist nichts zu
            // tun, und ein grauer Knopf behauptet das Gegenteil.
            if !adresse.isEmpty, !benutzer.isEmpty, !passwort.isEmpty {
                Button(seerr.meldetAn ? "Verbinde…" : "Verbinden") {
                    guard !seerr.meldetAn else { return }
                    Task {
                        await seerr.verbinden(adresse: adresse, benutzer: benutzer,
                                              passwort: passwort)
                        if seerr.verbunden { passwort = "" }
                    }
                }
                .buttonStyle(KnopfStil())
            }

            Text("Dein Passwort wird nicht gespeichert — nur die Sitzung, die Seerr dafür ausstellt.")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
        }
        .frame(width: 900, alignment: .leading)
        .padding(.top, 44)
    }
}

/// Ein Titel, den der eigene Server noch nicht hat — die Fernseherkachel.
///
/// **Blass, und das ist die ganze Auskunft.** Wer über das Gitter fährt, soll
/// ohne ein Wort zu lesen sehen, dass hier nichts abzuspielen ist.
struct Seerrkachel: View {
    let treffer: Seerrtreffer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Bild(url: treffer.plakat(breite: 500),
                 breite: Stil.posterBreite, hoehe: Stil.posterHoehe)
                .opacity(0.45)
                .overlay(alignment: .bottomLeading) { marke.padding(10) }

            Text(verbatim: treffer.titel)
                .font(Stil.kachel)
                .foregroundStyle(Stil.schriftLeise)
                .lineLimit(1)
                .padding(.top, 14)

            Text(verbatim: untertitel)
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .frame(width: Stil.posterBreite, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(treffer.titel), \(treffer.stand.ansage)"))
    }

    private var untertitel: String {
        let art = treffer.istSerie ? String(localized: "Serie") : String(localized: "Film")
        return treffer.jahr.map { "\($0) · \(art)" } ?? art
    }

    @ViewBuilder
    private var marke: some View {
        if treffer.stand != .da {
            HStack(spacing: 5) {
                Image(systemName: treffer.stand.symbol)
                    .font(.system(size: 15, weight: .bold))
                if let wort = treffer.stand.kurzwort {
                    Text(verbatim: wort).font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(Stil.grund)
            .padding(.horizontal, treffer.stand.kurzwort == nil ? 9 : 12)
            .padding(.vertical, 5)
            .background(treffer.stand.farbe, in: Capsule())
        }
    }
}

/// Die Seite eines Titels, den der eigene Server noch nicht hat.
///
/// **Dieselbe Seite wie sonst, nur eine andere Handlung.** Getauscht ist der
/// grosse Knopf — aus *Abspielen* wird *Anfragen*.
struct SeerrDetailView: View {
    let model: AppModel
    let treffer: Seerrtreffer

    @State private var stand: Seerrstand
    @State private var detail: Seerrdetail?
    @State private var laeuft = false
    @State private var angefragt = false
    @State private var fehler: String?
    @State private var gewaehlt: Set<Int> = []
    @State private var staffelnOffen = false
    @State private var bestaetigt = false

    init(model: AppModel, treffer: Seerrtreffer) {
        self.model = model
        self.treffer = treffer
        _stand = State(initialValue: treffer.stand)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: treffer.titel)
                    .font(Stil.titelGross)
                    .foregroundStyle(Stil.schrift)

                Text(verbatim: nebenzeile)
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .padding(.top, 10)

                belegzeile.padding(.top, 22)

                handlung.padding(.top, 28)

                if let text = detail?.beschreibung {
                    Text(verbatim: text)
                        .font(Stil.koerper)
                        .foregroundStyle(Stil.schrift.opacity(0.78))
                        .lineSpacing(6)
                        .frame(width: 1000, alignment: .leading)
                        .padding(.top, 30)
                }

                besetzung
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Stil.randSeite)
            .padding(.top, Stil.leisteUnten + 40)
            .padding(.bottom, 80)
        }
        .bildgrund(url: treffer.kulisse(breite: 1280))
        .task { detail = await model.seerr.detail(treffer) }
    }

    private var nebenzeile: String {
        var teile: [String] = []
        if let jahr = treffer.jahr { teile.append("\(jahr)") }
        if treffer.istSerie {
            let n = detail?.staffeln.count ?? 0
            if n > 0 { teile.append(n == 1 ? String(localized: "1 Staffel")
                                           : String(localized: "\(n) Staffeln")) }
        } else if let m = detail?.laufzeit, m > 0 {
            teile.append(String(localized: "\(m) Min."))
        }
        let gattungen = detail?.genres ?? []
        if !gattungen.isEmpty { teile.append(gattungen.joined(separator: ", ")) }
        if teile.isEmpty {
            teile.append(treffer.istSerie ? String(localized: "Serie")
                                          : String(localized: "Film"))
        }
        return teile.joined(separator: " · ")
    }

    private var belegzeile: some View {
        HStack(spacing: 22) {
            HStack(spacing: 8) {
                Image(systemName: stand.symbol).font(.system(size: 20, weight: .heavy))
                Text(verbatim: stand.wort).font(.system(size: 24, weight: .medium))
            }
            .foregroundStyle(stand.farbe)

            if let b = detail?.bewertung, b > 0 {
                HStack(spacing: 7) {
                    Image(systemName: "star.fill").font(.system(size: 20))
                    Text(verbatim: String(format: "%.1f", b)
                            .replacingOccurrences(of: ".", with: ","))
                        .font(.system(size: 24))
                }
                .foregroundStyle(Stil.schrift.opacity(0.8))
            }
        }
    }

    /// **Ein Stand ist keine Schaltfläche.** Was wartet oder lädt, lässt sich
    /// nicht noch einmal anfragen; dort steht eine Auskunft.
    @ViewBuilder
    private var handlung: some View {
        if angefragt {
            auskunft(String(localized: "Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."))
        } else if stand.anfragbar {
            VStack(alignment: .leading, spacing: 20) {
                Button(knopftext) { gedrueckt() }
                    .buttonStyle(KnopfStil())
                if treffer.istSerie, staffelnOffen { staffelliste }
                if let fehler {
                    Text(verbatim: fehler).font(Stil.klein).foregroundStyle(Stil.warnung)
                }
            }
        } else {
            auskunft(stand.hinweis)
        }
    }

    private var knopftext: LocalizedStringKey {
        if laeuft { return "Wird angefragt…" }
        if treffer.istSerie { return staffelnOffen ? "Anfragen" : "Staffeln wählen" }
        return bestaetigt ? "Wirklich anfragen?" : "Anfragen"
    }

    /// **Zwei Stufen, und die zweite ist der eigentliche Auftrag.** Mit einer
    /// Fernbedienung ist ein Klick besonders schnell passiert.
    private func gedrueckt() {
        guard !laeuft else { return }
        if treffer.istSerie {
            if staffelnOffen { Task { await anfragen() } }
            else { staffelnOffen = true }
            return
        }
        guard bestaetigt else { bestaetigt = true; return }
        Task { await anfragen() }
    }

    private var staffelliste: some View {
        VStack(spacing: 0) {
            ForEach(detail?.staffeln ?? []) { st in
                Button {
                    guard st.stand.anfragbar else { return }
                    if gewaehlt.contains(st.nummer) { gewaehlt.remove(st.nummer) }
                    else { gewaehlt.insert(st.nummer) }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: st.stand.anfragbar
                              ? (gewaehlt.contains(st.nummer) ? "checkmark.square.fill" : "square")
                              : "checkmark.circle")
                            .foregroundStyle(gewaehlt.contains(st.nummer) ? Stil.akzent
                                                                          : Stil.schriftSehrLeise)
                        Text("Staffel \(st.nummer)")
                            .foregroundStyle(st.stand.anfragbar ? Stil.schrift
                                                                : Stil.schriftSehrLeise)
                        if st.folgen > 0 {
                            Text("· \(st.folgen) Folgen").foregroundStyle(Stil.schriftSehrLeise)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(Stil.koerper)
                    .padding(.horizontal, 22)
                    .frame(height: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 620, alignment: .leading)
        .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.ecke))
        .overlay(RoundedRectangle(cornerRadius: Stil.ecke).strokeBorder(Stil.rand))
    }

    @ViewBuilder
    private var besetzung: some View {
        let leute = detail?.besetzung ?? []
        if !leute.isEmpty {
            Text("Besetzung")
                .font(Stil.reihe).foregroundStyle(Stil.schrift)
                .padding(.top, 50)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 28) {
                    ForEach(leute.prefix(12)) { person in
                        Besetzungskachel(bild: person.bild(breite: 300),
                                         name: person.name, rolle: person.rolle)
                    }
                }
            }
            .padding(.top, 20)
        }
    }

    private func auskunft(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Stil.koerper)
            .foregroundStyle(Stil.schriftLeise)
            .frame(width: 900, alignment: .leading)
            .padding(.vertical, 20).padding(.horizontal, 24)
            .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.ecke))
    }

    private func anfragen() async {
        fehler = nil
        laeuft = true
        defer { laeuft = false }
        do {
            // Leer heisst alle — Seerr versteht das Wort `all`.
            let staffeln = gewaehlt.isEmpty ? nil : Array(gewaehlt).sorted()
            try await model.seerr.anfragen(treffer, staffeln: staffeln)
            angefragt = true
            stand = .wartetAufFreigabe
        } catch {
            fehler = error.localizedDescription
        }
    }
}
