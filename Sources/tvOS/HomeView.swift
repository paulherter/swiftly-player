import JellyfinKit
import SwiftUI

/// Die Startseite: waagerechte Reihen, wie auf dem iPhone — nur größer und
/// mit Fokus statt Berührung.
struct HomeView: View {
    let model: AppModel
    /// Der Player liegt im Rahmen, nicht hier — siehe `HauptView`.
    @Environment(\.abspielwunsch) private var abspielen

    /// Laden und Reihenfolge stehen in `Startseitenmodell` — geteilt mit
    /// der iPhone-Fassung, damit beide Seiten dasselbe Verhalten haben.
    @State private var stand = Startseitenmodell()
    /// Doppelte Ausloesung sperren, waehrend der Plan geholt wird.
    @State private var bereitet = false
    @FocusState private var amTitel: Kachelmarke?
    /// Der Titel, dessen Bild gerade steht — nachgezogen, nicht sofort.
    @State private var imBild: Item?
    @State private var bildwechsel: Task<Void, Never>?
    /// Ob der Startfokus schon einmal gesetzt wurde. **Nicht** `amTitel == nil`
    /// abfragen: tvOS setzt den Fokus selbst, bevor irgendein `onAppear`
    /// laeuft, und dann liesse genau die Pruefung los, die greifen soll.
    @State private var startfokusGesetzt = false
    /// Was in jeder Reihe gerade **vorne** steht, also unter ihrem Titel.
    /// Darauf faellt der Fokus, wenn er von oben oder unten hereinkommt.
    @State private var vorderste: [Reihenkennung: String] = [:]

    var body: some View {
        ZStack {
            if !stand.geladen {
                Lader.fern
            } else if stand.gestoert {
                Leerzustand(symbol: "wifi.exclamationmark",
                            titel: "Der Server antwortet nicht",
                            hinweis: "Prüf die Verbindung und versuch es noch einmal.",
                            knopf: ("Nochmal versuchen", { Task { await laden() } }))
            } else if stand.alleLeer {
                Leerzustand(symbol: "play.rectangle",
                            titel: "Hier ist noch nichts",
                            hinweis: "Sobald auf dem Server etwas liegt, taucht es hier auf.")
            } else {
                inhalt
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await laden() }
    }

    /// Was die Auskunft beschreibt — **abgeleitet, nicht gesetzt.**
    ///
    /// Vorher war das ein Zustand, den `erstenZeigen` beim Erscheinen
    /// beschrieb. Landete der Fokus woanders als erwartet — und tvOS setzt
    /// ihn selbst, bevor irgendein `onAppear` laeuft —, blieb die Auskunft
    /// auf dem alten Titel stehen: oben „Folge 4", markiert war „The
    /// Mentalist". Abgeleitet kann sie das nicht.
    private var aktuell: Item? {
        if let amTitel, let t = alleTitel.first(where: { $0.id == amTitel.titel }) { return t }
        return ersterTitel
    }

    private var alleTitel: [Item] {
        stand.weiterschauen + stand.naechsteFolge + stand.zuletzt
    }

    /// Worauf die Seite beim Oeffnen steht: der erste Eintrag aus
    /// „Weiterschauen", sonst der erste ueberhaupt.
    private var ersterTitel: Item? {
        stand.weiterschauen.first ?? alleTitel.first
    }

    private func liste(_ reihe: Reihenkennung) -> [Item] {
        switch reihe {
        case .weiterschauen: stand.weiterschauen
        case .naechsteFolge: stand.naechsteFolge
        case .zuletzt:       stand.zuletzt
        }
    }

    /// Die vorderste Kachel einer Reihe: die, die gerade unter ihrem Titel
    /// steht. Meldet die Reihe noch nichts, ist es die erste ueberhaupt.
    private func vordersteMarke(_ reihe: Reihenkennung) -> Kachelmarke? {
        let eintraege = liste(reihe)
        guard !eintraege.isEmpty else { return nil }
        let vorn = vorderste[reihe]
        let titel = eintraege.contains { $0.id == vorn } ? vorn! : eintraege[0].id
        return Kachelmarke(reihe: reihe, titel: titel)
    }

    /// Dieselbe Kachel als Fokusmarke — samt Reihe, sonst ist sie zweideutig.
    private var startMarke: Kachelmarke? {
        if let t = stand.weiterschauen.first { return .init(reihe: .weiterschauen, titel: t.id) }
        if let t = stand.naechsteFolge.first { return .init(reihe: .naechsteFolge, titel: t.id) }
        if let t = stand.zuletzt.first { return .init(reihe: .zuletzt, titel: t.id) }
        return nil
    }

    /// **Apples Aufbau, mit fester Kopfzone davor.**
    ///
    /// Neun Runden lang stand hier ein selbstgebauter Reihenkopf: ein
    /// `VStack` aus `Reihentitel` und Streifen. Genau daran lag es. tvOS
    /// kennt einen Reihentitel nur, wenn er als **`Section`-Kopf** deklariert
    /// ist — WWDC24, „Migrate your TVML app to SwiftUI":
    ///
    /// > „A section view will provide each shelf with a title, and that title
    /// > will automatically move out of the way as your lockups gain focus to
    /// > avoid being occluded."
    ///
    /// Der Fokusmotor stellt die **Kachel** frei. Steht der Titel in einem
    /// gewoehnlichen Stapel, ist er fuer diese Rechnung Beiwerk und wandert
    /// unter die Fensterkante — jedes Mal, wenn der Fokus in eine Reihe
    /// springt. Kein Rand, kein Inset und kein Beschnitt konnte das je
    /// ausgleichen, weil der Titel gar nicht mitgezaehlt wurde.
    ///
    /// **Ohne `viewAligned`, und das ist keine Nachlaessigkeit.** Apples
    /// Sitzung setzt es dazu („just to help make that transition more
    /// definite"), aber es haelt nur dort an, wo ein Abschnitt **buendig
    /// oben** steht. Fuer den letzten Abschnitt liegt diese Stelle hinter dem
    /// Scroll-Anschlag — erreichbar waere sie nur mit einem grossen leeren
    /// Bereich unter der letzten Reihe. Genau der soll nicht sein. Mit
    /// `viewAligned` fuhr die unterste Reihe deshalb gar nicht mehr an: sie
    /// fehlte einfach.
    ///
    /// **Die Kopfzone ist ein Geschwister, kein Inset.** Sie zeigt, was unten
    /// markiert ist, also darf sie nicht mitscrollen. Als Geschwister im
    /// `VStack` hat die Scrollflaeche darunter eine eigene, richtige
    /// Geometrie: ihr Fenster **ist** der Platz unter der Kopfzone. Es gibt
    /// nichts, was sie ueberdecken koennte, und nichts, was ihr Platz
    /// wegnimmt, ohne es ihr zu sagen.
    ///
    ///     Fenster = 1080 − heldenHoehe = 570
    ///     Plakatreihe = 24 + 45 + 16 + (20 + 390 + 20) + 28 = 543
    ///
    /// Ein Abschnitt passt also ins Fenster. Das ist die Bedingung, unter der
    /// der Fokusmotor Kopf und Kacheln gemeinsam freistellen kann.
    private var inhalt: some View {
        VStack(spacing: 0) {
            heldenzone
            reihen
        }
        // **Der seitliche Rand wird einmal vergeben, nicht zweimal.**
        //
        // tvOS haelt links und rechts von sich aus 80 Punkt frei, und die
        // Seite legt `Stil.randSeite` (auch 80) darauf. Zusammen waren es
        // 160 — doppelt so viel wie im Entwurf, der immer ab 80 misst.
        // Deshalb faellt der Systemrand hier weg; `randSeite` misst danach
        // ab der Bildkante.
        //
        // **An jeder Seite einzeln, nicht am Rahmen.** Im Rahmen versucht
        // steht es wirkungslos da: der `NavigationStack` in `stapel(b)`
        // setzt den sicheren Bereich fuer seinen Inhalt neu. Gemessen, nicht
        // vermutet — die Wortmarke rueckte, der Inhalt darunter nicht.
        .ignoresSafeArea()
        // Nur das Bild braucht noch einen Zustand — es wird entprellt.
        .onChange(of: aktuell?.id) { _, _ in
            if let t = aktuell { bildwechseln(zu: t) }
        }
        .onAppear { erstenZeigen() }
        .onChange(of: stand.weiterschauen.first?.id) { _, _ in erstenZeigen() }
        // **Den Fokus aus der Kopfleiste in die erste Reihe holen.**
        //
        // `defaultFocus` sagt nur, was **innerhalb** der Scrollflaeche
        // vorgewaehlt ist. Ob beim Oeffnen ueberhaupt die Startseite oder die
        // Kopfleiste den Fokus bekommt, entscheidet tvOS eine Ebene hoeher —
        // und es hat den Reiter „Start" genommen.
        //
        // `initial: true` laeuft beim Erscheinen mit; ist da noch nichts
        // geladen, ist `ersterTitel` nil und es laeuft nochmal, sobald der
        // erste Titel steht. Kein Warten auf Verdacht.
        // **Senkrecht faellt der Fokus auf die vorderste Kachel der Reihe.**
        //
        // Nicht auf dieselbe Spalte und nicht auf die erste ueberhaupt: die
        // Reihe behaelt ihren Scrollstand, und der Fokus nimmt, was dort
        // gerade unter dem Reihentitel steht. Wer in „Zuletzt hinzugefuegt"
        // weit gescrollt hat, findet die Reihe beim naechsten Besuch so
        // wieder vor, wie er sie verlassen hat.
        //
        // Warum nachtraeglich korrigiert und nicht vorgewaehlt: tvOS fragt
        // eine Vorwahl (`prefersDefaultFocus`) nur, wenn es einen Bereich
        // **ohne Richtung** betritt. Bei einem Druck nach unten entscheidet
        // allein die Geometrie — und die kann hier nicht stimmen.
        // „Weiterschauen" ist 448 breit, die Plakatreihen 208; Querkachel 1
        // ueberlappt Plakat 1 **und** 2. Eine gemeinsame Spalte gibt es gar
        // nicht. Also den Systemzug laufen lassen und danach zurechtruecken.
        .onChange(of: amTitel) { vorher, jetzt in
            guard let jetzt, let vorher, vorher.reihe != jetzt.reihe else { return }
            if let ziel = vordersteMarke(jetzt.reihe), ziel != jetzt { amTitel = ziel }
        }
        .onChange(of: startMarke, initial: true) { _, marke in
            guard !startfokusGesetzt, let marke else { return }
            startfokusGesetzt = true
            amTitel = marke
        }
    }

    /// Die Reihen — jede ein `Section`, nichts selbstgebautes.
    ///
    /// **`VStack`, nicht `LazyVStack`** — auch wenn Apples Beispiel den faulen
    /// Stapel nimmt. Der ist fuer Kataloge mit hundert Reihen gedacht; hier
    /// sind es drei, und er kostet nur.
    ///
    /// Nachgerechnet, warum es genau hier weh tut: ein Abschnitt ist 543 hoch,
    /// das Fenster 570. Steht der Fokus auf Reihe 2, beginnt Reihe 3 **auf der
    /// Fensterkante**. Der faule Stapel erzeugt, was den sichtbaren Bereich
    /// schneidet — mal ist sie einen Punkt drin, mal einen Punkt draussen.
    /// Existiert sie nicht, findet der Fokusmotor nichts, und „nach unten"
    /// tut schlicht nichts. Danach ist sie erzeugt und bleibt es, also ging es
    /// beim zweiten Versuch.
    ///
    /// Reihenfolgeabhaengig, also **beweist ein gelungener Durchgang nichts**
    /// — dieselbe Falle wie bei den vier „gesetzt heisst nicht angewandt"-
    /// Fehlern in CLAUDE.md. Und derselbe faule Stapel stand dort schon
    /// einmal: er hat die Reihenhoehen geschaetzt und den Fokusversatz
    /// wachsend verrechnet.
    private var reihen: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if !stand.weiterschauen.isEmpty {
                    // **Weiterschauen startet sofort, ohne Zwischenseite.**
                    // Die anderen beiden fuehren auf die Uebersicht.
                    // `VERHALTEN.md` A1 bis A3.
                    abschnitt("Weiterschauen") {
                        Streifen(model: model, items: stand.weiterschauen,
                                 reihe: .weiterschauen, quer: true,
                                 direkt: starte, amTitel: $amTitel,
                                 vorderste: $vorderste)
                    }
                }
                if !stand.naechsteFolge.isEmpty {
                    abschnitt("Nächste Folge") {
                        Streifen(model: model, items: stand.naechsteFolge,
                                 reihe: .naechsteFolge, amTitel: $amTitel,
                                 vorderste: $vorderste)
                    }
                }
                if !stand.zuletzt.isEmpty {
                    abschnitt("Zuletzt hinzugefügt") {
                        Streifen(model: model, items: stand.zuletzt,
                                 reihe: .zuletzt, neuzugang: true,
                                 amTitel: $amTitel, vorderste: $vorderste)
                    }
                }
            }
            // Damit die unterste Reihe am Anschlag denselben Abstand zur
            // Bildkante hat wie zwei Reihen zueinander. Siehe `abschlussLuft`.
            .padding(.bottom, Stil.abschlussLuft)
        }
        .scrollIndicators(.hidden)
        // **Wo der Fokus beim Oeffnen steht, wird gesagt, nicht gehofft.**
        //
        // Solange der faule Stapel nur die erste Reihe erzeugt hatte, landete
        // er dort — mangels Alternative, nicht weil es so gemeint war. Mit
        // allen drei Reihen sucht tvOS sich selbst eine aus, und das war
        // zuletzt „Zuletzt hinzugefuegt".
        //
        // Nachgereicht ging es nicht: `erstenZeigen` setzte nur, solange der
        // Fokus nirgends stand, und tvOS ist schneller als jedes `onAppear`.
        // Genau die Form, vor der CLAUDE.md warnt — gesetzt, aber die
        // anwendende Stelle laeuft ins Leere. `userInitiated` sticht dabei
        // die Wahl des Systems; `automatic` waere nur ein Vorschlag.
        .defaultFocus($amTitel, startMarke, priority: .userInitiated)
        // **Hier wird beschnitten, und das ist Absicht.** Die Vergroesserung
        // der Kachel faengt der Streifen mit `reihenLuft` in seinen eigenen
        // Grenzen ab; die senkrechte Flaeche darf deshalb schneiden — und nur
        // so kann keine Kachel je in die Kopfzone hineinragen.
    }

    /// Ein Reihenabschnitt. Die Abstaende stehen in `reihenabschnitt`, das
    /// sich Start-, Film- und Serienseite teilen — hier nur die Beschriftung.
    private func abschnitt<Inhalt: View>(_ titel: LocalizedStringKey,
                                         @ViewBuilder _ inhalt: () -> Inhalt) -> some View {
        reihenabschnitt { Reihentitel(text: titel) } inhalt: { inhalt() }
    }

    // MARK: Kopfzone

    /// Querbild und Auskunft — das erste Kind der Scrollflaeche.
    ///
    /// **Nicht beschnitten.** Das Querbild darf die 560 nach unten
    /// ueberragen; sein eigener Verlauf beendet es. Beschnitten entstand die
    /// harte Kante, die als heller Streifen quer ueber den Schirm stand. Die
    /// erste Reihe zeichnet ohnehin darueber, sie ist das naechste Geschwister.
    private var heldenzone: some View {
        ZStack(alignment: .topLeading) {
            Stil.grund
            querbild
                .frame(maxWidth: .infinity, alignment: .trailing)
            // Der Kopfverlauf gehoert **unter** die Schrift. Liegt er
            // darueber, faerbt er den Titel grau — der Entwurf setzt den
            // Textblock ausdruecklich mit `z-index: 1` darueber.
            Kopfverlauf(ausklang: 460, weich: true)
            auskunft
                .padding(.leading, Stil.randSeite)
                .padding(.top, 196)
        }
        // **Volle 510, von der Bildkante gemessen.**
        //
        // Der aeussere Stapel laesst den oberen Rand aussen vor, also faengt
        // die Zone bei null an und die Masse aus `Start-A.dc.html` gelten
        // unveraendert — auch die 196, mit denen die Auskunft ansetzt.
        //
        // Nicht beschnitten: das Querbild ist 700 hoch und beendet sich mit
        // seinem eigenen Verlauf. Bei 510 abgeschnitten stuende dort die
        // harte Kante, die einmal als heller Streifen quer im Bild lag. Die
        // Reihen zeichnen darueber, sie sind das naechste Geschwister.
        .frame(height: Stil.heldenHoehe, alignment: .topLeading)
    }

    /// Das Bild wechselt **entprellt und ueberblendet**.
    ///
    /// Beim Durchhalten der Fernbedienung wandert der Fokus im
    /// Zehntelsekundentakt. Jeder Wechsel ein neues Bild mit neuer Kennung
    /// heisst: leerer Kasten, Netzabruf, Bild — es blitzt bei jedem
    /// Tastendruck. Swiftfin entprellt eine halbe Sekunde
    /// (`CinematicBackgroundView.ViewModel`) und blendet ueber, wobei das
    /// alte Bild stehenbleibt, bis das neue da ist.
    private func bildwechseln(zu titel: Item) {
        bildwechsel?.cancel()
        bildwechsel = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            imBild = titel

            // **Den Farbton schon hier rechnen, gebraucht wird er drueben.**
            //
            // Die Startseite faerbt sich nicht — sie bleibt #0B0B0D. Aber
            // wer hier steht, oeffnet als Naechstes wahrscheinlich genau
            // diesen Titel, und dann soll der Ton **stehen** und nicht
            // aufblenden. Dieselbe Adresse, derselbe Zwischenspeicher.
            if let bild = model.querbildURL(for: titel, breite: 1600)
                       ?? model.backdropURL(for: titel) {
                Bildton.geteilt.vorrechnen(bild)
            }
        }
    }

    /// Aus „Weiterschauen" direkt in die Folge, ohne Zwischenseite.
    /// Vor dem ersten Fokus steht oben, was der Zuschauer ohnehin am
    /// ehesten will — der erste Eintrag aus „Weiterschauen".
    private func erstenZeigen() {
        // **Nur das Bild.** Den Fokus setzt `defaultFocus`, und zwar
        // deklariert. Hier stand einmal eine Zuweisung nach 120 ms, die nur
        // griff, solange der Fokus noch nirgends stand — tvOS war schneller,
        // also griff sie nie, wenn es darauf ankam.
        guard imBild == nil else { return }
        imBild = ersterTitel
    }

    /// Das Querbild rechts, 1180 breit.
    ///
    /// Die Blende ist dieselbe wie auf der Detailseite (`Kulissenblende`) —
    /// das ist Bedingung dafuer, dass beim Oeffnen nichts sichtbar wechselt.
    @ViewBuilder
    private var querbild: some View {
        ZStack {
            if let t = imBild {
                AsyncImage(url: model.querbildURL(for: t, breite: 1600)
                                ?? model.backdropURL(for: t)) { phase in
                    if case let .success(bild) = phase {
                        bild.resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .id(t.id)
                .transition(.opacity)
            }
        }
        .frame(width: 1180, height: 700)
        .clipped()
        // Dieselbe Blende wie auf der Detailseite — siehe `Kulissenblende`.
        // Vorher stand hier eine zweite, uebermalende Fassung mit kurzen
        // Rampen, und beim Oeffnen einer Seite blendete die eine in die
        // andere. Genau das waren die harten Kanten waehrend des Wechsels.
        .kulissenblende()
        .animation(.easeInOut(duration: 0.3), value: imBild?.id)
        // Bis an die Bildkante, ohne den Text mitzunehmen.
        .padding(.trailing, -Stil.randSeite)
        .allowsHitTesting(false)
    }

    /// Titel, Angaben und Beschreibung zum Titel unter dem Fokus.
    @ViewBuilder
    private var auskunft: some View {
        Group {
            if let t = aktuell {
                // **Derselbe Baustein wie auf der Detailseite.** Vorher stand
                // der Aufbau hier ein zweites Mal, und die beiden waren schon
                // auseinander: dort Genres, hier die Restzeit. Siehe
                // `Kopfauskunft`.
                Kopfauskunft(item: t,
                             zweitzeile: t.type == "Episode" ? t.name : nil) {
                    Restzeitmarke(item: t)
                }
            }
        }
    }


    private func starte(_ item: Item) {
        guard !bereitet else { return }
        bereitet = true
        Task {
            defer { bereitet = false }
            // Frisch holen: die Stelle im Listeneintrag ist oft veraltet.
            let aktuell = await model.item(id: item.id) ?? item
            guard let plan = await model.plan(for: aktuell.id) else { return }
            abspielen.wrappedValue = Abspielwunsch(item: aktuell, plan: plan,
                                                   startAt: aktuell.fortsetzenAb ?? 0)
        }
    }

    private func laden() async {
        await stand.laden(model)
        regalSchreiben()
    }

    /// Legt fürs Top Shelf ab, was die Startseite gerade zeigt.
    ///
    /// Genau dieselben drei Rubriken in derselben Reihenfolge — leere fallen
    /// weg. Damit steht auf dem Startbildschirm dasselbe wie in der App, und
    /// wer nur „Weiterschauen" hat, sieht auch nur das.
    ///
    /// Acht Einträge je Rubrik: mehr zeigt der Top Shelf ohnehin nicht auf
    /// einen Blick, und die Datei bleibt klein.
    private func regalSchreiben() {
        func eintraege(_ items: [Item], quer: Bool) -> [Regaleintrag] {
            items.prefix(8).map { item in
                Regaleintrag(
                    id: item.id,
                    titel: item.seriesName ?? item.name,
                    unterzeile: item.folgenkuerzel,
                    bild: quer ? (model.querbildURL(for: item, breite: 900)
                                  ?? model.imageURL(for: item, maxHeight: 600, hochkant: true))
                               : model.imageURL(for: item, maxHeight: 600, hochkant: true),
                    fortschritt: item.gesehenerAnteil)
            }
        }

        var rubriken: [Regalrubrik] = []
        if !stand.weiterschauen.isEmpty {
            rubriken.append(.init(titel: String(localized: "Weiterschauen"), quer: true,
                                  eintraege: eintraege(stand.weiterschauen, quer: true)))
        }
        if !stand.naechsteFolge.isEmpty {
            rubriken.append(.init(titel: String(localized: "Nächste Folge"), quer: false,
                                  eintraege: eintraege(stand.naechsteFolge, quer: false)))
        }
        if !stand.zuletzt.isEmpty {
            rubriken.append(.init(titel: String(localized: "Zuletzt hinzugefügt"), quer: false,
                                  eintraege: eintraege(stand.zuletzt, quer: false)))
        }
        Regal.schreiben(Regalvorschau(rubriken: rubriken))
    }
}

// MARK: - Fokusmarke

/// Welche Reihe. Nur zur Unterscheidung, nicht fuer die Anzeige.
private enum Reihenkennung: Hashable {
    case weiterschauen, naechsteFolge, zuletzt
}

/// Was der Fokus auf der Startseite bezeichnet: **Reihe und Titel**.
///
/// Die Titelkennung allein reicht nicht, und das ist keine Vorsicht, sondern
/// nachgemessen: derselbe Film steht regelmaessig in „Weiterschauen" **und**
/// in „Zuletzt hinzugefuegt" — R.E.D. tat es. Beide Kacheln trugen dann
/// dieselbe Marke. Wird sie gesetzt, hat tvOS zwei Kandidaten und nimmt einen;
/// genommen hat es die untere, und die Seite oeffnete mitten in der letzten
/// Reihe.
///
/// Mit der Reihe darin ist die Marke eindeutig, und zwar ohne dass die
/// Rubriken sich absprechen muessten. (Dass `Startseitenmodell` dieselben
/// Titel doppelt liefert, ist geteilte Logik und gehoert zuerst auf iOS
/// geprueft — die Anzeige darf davon aber nicht abhaengen.)
private struct Kachelmarke: Hashable {
    let reihe: Reihenkennung
    let titel: String
}

// MARK: - Reihe

/// Eine waagerecht scrollende Reihe.
///
/// `scrollClipDisabled` ist hier kein Feinschliff, sondern Voraussetzung:
/// der Fokusring liegt 10 Punkt **außerhalb** der Kachel, und die
/// Scrollfläche würde ihn an ihrer Kante abschneiden. Oben und unten wäre er
/// dann weg.
private struct Streifen: View {
    let model: AppModel
    let items: [Item]
    /// Macht die Fokusmarken dieser Reihe von denen der anderen unterscheidbar.
    let reihe: Reihenkennung
    var quer = false
    var neuzugang = false
    /// Gesetzt heisst: Klicken startet sofort, statt auf die Seite zu fuehren.
    var direkt: ((Item) -> Void)?
    /// Meldet nach oben, welcher Titel gerade unter dem Fokus steht.
    @FocusState.Binding var amTitel: Kachelmarke?
    /// Traegt hier ein, was in dieser Reihe gerade vorne steht.
    @Binding var vorderste: [Reihenkennung: String]

    /// Die Kachel an der Vorderkante — von der Scrollflaeche gemeldet.
    @State private var vorne: String?

    /// **Nur die Kacheln.** Der Titel steht als `Section`-Kopf darueber —
    /// nicht aus Ordnungsliebe, sondern weil tvOS ihn nur so kennt und beim
    /// Fokussieren freihaelt. Selbstgebaut wandert er unter die Fensterkante.
    var body: some View {
        ScrollView(.horizontal) {
            // **`HStack`, nicht `LazyHStack`** — aus demselben Grund wie
            // senkrecht, und er ist hier sogar zwingend.
            //
            // Der Reihenwechsel wird nachtraeglich korrigiert (siehe
            // `inhalt`), und eine Zuweisung an `@FocusState` bewegt den Fokus
            // nur, wenn die Zielkachel **existiert**. Der faule Stapel erzeugt
            // aber nur das gerade Sichtbare. Steht die Reihe um zwei Kacheln
            // verschoben da, gibt es Kachel 1 nicht, die Zuweisung verpufft
            // still, und der Fokus bleibt auf der dritten — jedes Mal auf
            // derselben, weil der Versatz feststeht.
            //
            // Das kostet: die Reihen laden ihre Bilder auf einen Schlag,
            // hoechstens 24 je Reihe (`AppModel.zuletztHinzugefuegt`). Kleine
            // Plakate, und dafuer ist der Fokus vorhersagbar statt manchmal.
            HStack(alignment: .top, spacing: Stil.kachelAbstand) {
                ForEach(items) { item in
                    Group {
                        if let direkt {
                            Button { direkt(item) } label: { kachel(item) }
                        } else {
                            NavigationLink(value: item) { kachel(item) }
                        }
                    }
                    .buttonStyle(KachelStil())
                    .focused($amTitel, equals: .init(reihe: reihe, titel: item.id))
                }
            }
            .padding(.horizontal, Stil.randSeite)
            // **Luft fuer die Vergroesserung.**
            //
            // Die fokussierte Kachel waechst um 1,08 ueber ihre Layoutgroesse
            // hinaus. Diese Luft faengt das **innerhalb** der Reihe ab —
            // deshalb darf die senkrechte Flaeche darueber beschneiden, ohne
            // je eine Kachel anzuschneiden.
            .padding(.vertical, Stil.reihenLuft)
            // Markiert die Kacheln als Bezugspunkte — nur damit
            // `scrollPosition` sagen kann, welche vorne liegt. Ein
            // `scrollTargetBehavior` steht bewusst nicht dabei: es soll
            // nichts einrasten, nur gemeldet werden.
            .scrollTargetLayout()
        }
        .scrollPosition(id: $vorne, anchor: .leading)
        .onChange(of: vorne, initial: true) { _, id in vorderste[reihe] = id }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        // Jede Reihe ist ein eigener Abschnitt.
        //
        // Ohne das sucht tvOS senkrecht nach einer Kachel, die **in
        // derselben Spalte** liegt. „Nächste Folge" hat oft weniger
        // Einträge als „Weiterschauen" — stand man auf der dritten Kachel,
        // fand der Fokus dort nichts und sprang gleich zwei Reihen tiefer.
        // Als Abschnitt gilt die Reihe als Ganzes und wird angesteuert, egal
        // wie breit sie ist.
        .focusSection()
    }

    private func kachel(_ item: Item) -> some View {
        Kachelinhalt(bild: bildURL(item),
                     titel: item.seriesName ?? item.name,
                     unterzeile: unterzeile(item),
                     quer: quer,
                     fortschritt: fortschritt(item))
    }

    private func bildURL(_ item: Item) -> URL? {
        quer ? (model.querbildURL(for: item, breite: 900)
                ?? model.imageURL(for: item, maxHeight: 600, hochkant: true))
             : model.imageURL(for: item, maxHeight: 600, hochkant: true)
    }

    private func unterzeile(_ item: Item) -> String? {
        neuzugang ? item.neuzugangszeile : item.folgenkuerzel
    }

    private func fortschritt(_ item: Item) -> Double? { item.gesehenerAnteil }
}
