import SwiftUI

/// Maße, Schriftgrößen und Bausteine für den Fernseher.
///
/// Die Farben stehen in `Sources/Shared/Farben.swift` und sind mit dem iPhone
/// identisch. Alles andere hier ist neu: 1920 × 1080 statt 390 × 844, drei
/// Meter Entfernung statt Armlänge, Fernbedienung statt Finger.
///
/// **Die eine Regel, die alles trägt: Fokus ist weiß, Auswahl ist Akzent.**
/// Der weiße Fokusgrund ist derselbe Knopf, der auf iOS `HauptknopfStil`
/// heißt — weiße Fläche, schwarze Schrift. Auf tvOS wird daraus der Zustand
/// „hier steht die Fernbedienung". Der Akzentring um eine fokussierte Kachel
/// bricht die iOS-Regel nicht, sondern wendet sie an: der Akzent trägt
/// Fortschritt, **Auswahl** und den Direct-Play-Beleg.
///
/// Bewusst keine Apple-Standardsteuerelemente, wie auf iOS auch: kein
/// `TabView`, keine `List`, kein `.buttonStyle(.card)` — Apples Karte bringt
/// Schatten, Parallaxe und ein Aufblitzen mit, die zu einer flachen
/// Gestaltung nicht passen.
extension Stil {

    // MARK: Maße — Apple TV

    /// Der sichere Bereich auf 1920 × 1080. Apples Richtwert, und er stimmt:
    /// Fernseher schneiden am Rand ab, mal mehr, mal weniger.
    ///
    /// **Gemessen ab der Bildkante, nicht ab dem Systemrand.** tvOS haelt
    /// seitlich selbst 80 frei; wer `randSeite` daraufsetzt, landet bei 160
    /// und damit doppelt so weit innen wie der Entwurf. `HauptView` nimmt den
    /// Systemrand deshalb einmal fuer alle Bereiche weg — siehe dort.
    ///
    /// Weniger als 80 waere kein Feinschliff, sondern ein Risiko: darunter
    /// schneiden Fernseher ab, und man sieht es dem Simulator nie an.
    static let randSeite: CGFloat = 80
    static let randOben: CGFloat = 60

    // MARK: Kopfleiste

    /// Oberkante der Leiste, von der Bildkante aus — der sichere Bereich.
    ///
    /// Apples Richtlinie nennt für die **Systemleiste** feste 46 Punkt („its
    /// top edge is 46 points from the top of the screen"). Übernommen sah es
    /// schief aus, und zwar aus einem Grund, der in der Zahl nicht steckt:
    /// Apples Leiste ist waagerecht **mittig** und schmal, unsere ist
    /// linksbündig und beginnt bei 80. 46 oben gegen 80 seitlich liest sich
    /// dann als Fehler.
    ///
    /// Deshalb der sichere Bereich: 60 oben, 80 seitlich. Das ist auf tvOS
    /// ohnehin das Verhältnis, in dem der Rand gedacht ist — waagerecht mehr
    /// wegen des Überstrahlens am Bildrand.
    static let leisteOben: CGFloat = randOben
    static let leisteHoehe: CGFloat = 68
    /// Unterkante — daran hängt der Kopfverlauf, der sich damit selbst
    /// nachrechnet, wenn die Leiste je wandert.
    static var leisteUnten: CGFloat { leisteOben + leisteHoehe }

    static let ecke: CGFloat = 12
    static let eckeKachel: CGFloat = 16

    /// Poster bleiben 2:3 wie auf dem iPhone, nur größer.
    static let posterBreite: CGFloat = 208
    static let posterHoehe: CGFloat = 312

    /// Waagerecht 16:9 — für „Weiterschauen", wo ein Standbild mehr sagt als
    /// das Cover.
    static let querBreite: CGFloat = 448
    static let querHoehe: CGFloat = 252

    /// Alle Abstände sind so gewählt, dass die **fokussierte** Kachel noch
    /// Luft hat, nicht die ruhende. Bei ×1,08 wächst ein Poster um 25 Punkt,
    /// also gut 12 nach jeder Seite; eine Querkachel um 20. Wer die Abstände
    /// am ruhenden Zustand bemisst, bekommt sie beim ersten Fokus zu eng —
    /// genau das war hier zuerst der Fall.
    static let kachelAbstand: CGFloat = 40
    /// Hoehe der festen Auskunftszone, von der Bildkante gemessen.
    ///
    /// **Sie legt das Fenster der Reihen fest: 1080 − 510 = 570.** Und dieses
    /// Fenster muss einen ganzen Reihenabschnitt fassen, sonst kann tvOS Kopf
    /// und Kacheln nicht gemeinsam freistellen und der Titel rutscht wieder
    /// hinaus:
    ///
    ///     Plakatreihe = 24 + 45 + 16 + (20 + 390 + 20) + 28 = 543
    ///     Querreihe   = 24 + 45 + 16 + (20 + 331 + 20) + 28 = 484
    ///
    /// 510 statt der 560 aus `Start-A.dc.html`: mit 560 blieben nur 520, und
    /// da passt die Plakatreihe nicht mehr hinein.
    static let heldenHoehe: CGFloat = 510

    /// Senkrechte Luft im waagerechten Streifen.
    ///
    /// Die fokussierte Kachel waechst um 1,08 ueber ihre Layoutgroesse
    /// hinaus — bei einem Plakat rund 25 Punkt, also gut 12 je Seite. Ohne
    /// diese Luft schneidet die Flaeche oben die Kachel und unten ihre
    /// Nebenzeile an.
    static let reihenLuft: CGFloat = 20

    /// Ueber dem Reihentitel — der obere Teil des Reihenabstands.
    ///
    /// Er gehoert **in den Abschnitt**, nicht zwischen die Abschnitte. Nur so
    /// zaehlt er mit, wenn tvOS den Abschnitt beim Fokussieren freistellt —
    /// zwischen den Abschnitten waere er wieder Beiwerk.
    static let reihenKopfLuft: CGFloat = 24

    /// Von Reihe zu Reihe. Drei Teile, alle im Abschnitt: Abstand unter dem
    /// Streifen (28) + dessen Fokusluft (20) + Luft ueber dem naechsten
    /// Titel (24).
    static let reihenAbstand: CGFloat = 72

    /// Zwischen Reihentitel und den Kacheln darunter. Die Fokusluft des
    /// Streifens zaehlt mit, der Kopf traegt nur den Rest.
    static let titelAbstand: CGFloat = 36

    /// Unter der letzten Reihe, **zusaetzlich**.
    ///
    /// Am Anschlag steht die Unterkante des Inhalts auf der Fensterkante.
    /// Darunter liegt schon der Abstand des letzten Abschnitts samt Fokusluft
    /// — 28 + 20 = 48. Hierher kommt nur der Rest auf die 60, die tvOS unten
    /// ohnehin freihaelt. Mehr waere genau die „riesige Luecke unten", die
    /// vorher da war; abgeleitet statt gesetzt kann sie nicht wieder
    /// auseinanderlaufen.
    static var abschlussLuft: CGFloat {
        randOben - (reihenAbstand - reihenLuft - reihenKopfLuft) - reihenLuft
    }

    /// Die Bibliothek als Gitter.
    static let gitterSpalten = 7
    static let gitterSpalte: CGFloat = 56
    static let gitterZeile: CGFloat = 72

    static let knopfHoehe: CGFloat = 76
    static let chipHoehe: CGFloat = 48
    static let zeilenHoehe: CGFloat = 84

    // MARK: Fokus

    /// Wie stark eine fokussierte Kachel wächst — und das ist alles, was
    /// Fokus auf einer Kachel ausmacht. Kein Ring, keine Fläche, kein
    /// Schatten. Bewusst wenig: Apples Karte springt deutlich weiter und
    /// schiebt in einer dichten Reihe die Nachbarn optisch weg.
    static let fokusLupe: CGFloat = 1.08
    /// Stärke des Akzentrings und sein Abstand zur Kachel.
    static let ringStaerke: CGFloat = 4
    static let ringAbstand: CGFloat = 6
    /// Die ruhige Fläche, die überall Fokus bedeutet, wo kein Knopf steht:
    /// Listenzeilen, Chips, Folgenzeilen. Weiß bleibt den Handlungsknöpfen
    /// vorbehalten — dort ist es der Hauptknopf vom iPhone.
    static let fokusflaeche = Color.white.opacity(0.12)

    /// Fokuswechsel sollen unmittelbar wirken — die Fernbedienung ist
    /// träge genug.
    static let fokusAnimation = Animation.easeOut(duration: 0.14)

    // MARK: Seitenwechsel

    /// Überblenden zwischen zwei Bereichen.
    ///
    /// Reines Überblenden, ohne Verschiebung — mehr macht die Systemleiste
    /// auf tvOS auch nicht. `easeInOut`, weil an beiden Enden etwas
    /// passiert: das eine geht, das andere kommt.
    static let seitenwechsel = Animation.easeInOut(duration: 0.25)

    // MARK: Schrift — Apple TV

    /// Rund verdoppelt gegenüber dem iPhone und an Apples tvOS-Rampe
    /// eingenordet. Die iOS-Entsprechung steht jeweils daneben.
    static let titelHeld  = Font.system(size: 68, weight: .bold)       // iOS 27
    static let titelGross = Font.system(size: 57, weight: .bold)       // iOS 28
    static let reihe      = Font.system(size: 38, weight: .semibold)   // iOS 20
    static let knopf      = Font.system(size: 31, weight: .semibold)   // iOS 15/16
    static let koerper    = Font.system(size: 29)                      // iOS 15
    static let kachel     = Font.system(size: 27, weight: .medium)     // iOS 14
    static let klein      = Font.system(size: 25)                      // iOS 12
    static let plakette   = Font.system(size: 21, weight: .semibold)   // iOS 10
}

// MARK: - Bild

/// Bild in fester Größe, mit Platzhalter.
///
/// Gleiches Vorgehen wie auf iOS: die Größe kommt vom Rahmen, das Bild legt
/// sich nur darüber. `aspectRatio(.fill)` direkt auf dem Bild macht es breiter
/// als seinen Rahmen — `clipped()` beschneidet dann die Darstellung, nicht die
/// Layoutgröße, und alles drumherum verrutscht.
struct Bild: View {
    let url: URL?
    var breite: CGFloat?
    var hoehe: CGFloat?
    var ecke: CGFloat = Stil.eckeKachel
    /// Fortschritt am unteren Rand, innerhalb der Maske.
    var fortschritt: Double? = nil

    var body: some View {
        Color.clear
            .frame(width: breite, height: hoehe)
            .frame(maxWidth: breite == nil ? .infinity : nil)
            .overlay {
                AsyncImage(url: url) { phase in
                    if case let .success(bild) = phase {
                        bild.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Stil.flaeche
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let fortschritt {
                    Fortschrittsbalken(anteil: fortschritt)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: ecke))
    }
}

/// Dünner Balken am unteren Rand einer Kachel. Auf dem Fernseher 6 Punkt —
/// bei 2 wie auf dem iPhone sieht man ihn aus drei Metern nicht.
struct Fortschrittsbalken: View {
    let anteil: Double

    var body: some View {
        GeometryReader { rahmen in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.22))
                Rectangle().fill(Stil.akzent)
                    .frame(width: rahmen.size.width * min(max(anteil, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Kleinteile

// `Reihentitel`, `Plakette`, `Lader` und `Profilzeichen` stehen jetzt in
// `Sources/Shared/Bausteine.swift`. Sie lagen dreimal da — hier, auf iOS und
// auf macOS —, weil `Shared/Stil.swift` iPhone-Maße mit neutralen Bausteinen
// mischte und dieses Ziel die Datei deshalb nicht einbinden konnte. Kopien
// laufen auseinander; bei `nachladen()` ist genau das passiert.
//
// **Die Maße bleiben hier, die Bausteine nicht.** Der geteilte Baustein nimmt
// sie entgegen, das Ziel gibt sie mit.

/// Die Fernseher-Maße der Plakette an einer Stelle.
///
/// Das ist **keine zweite Plakette**, sondern ein Satz Zahlen: die
/// iPhone-Werte (5/2, Rundung 3, Strich 1) sind auf drei Meter Entfernung zu
/// klein. Wer sie ändert, ändert sie hier — nicht in einer Kopie.
///
/// Die Randfarbe leitet sich aus der Schriftfarbe ab, so wie es die eigene
/// Fassung tat. Der geteilte Baustein hält beide getrennt, weil ein
/// gekoppelter Rand die Plakette auf dem iPhone aufgehellt hätte.
extension Plakette {
    static func fern(_ text: String, farbe: Color = Stil.schriftLeise) -> Plakette {
        Plakette(text: text,
                 farbe: farbe,
                 randfarbe: farbe.opacity(0.3),
                 innenWaagerecht: 12,
                 innenSenkrecht: 4,
                 rundung: 6,
                 strichstaerke: 2)
    }
}

/// Der Beleg, dass der Server nicht transkodiert — der Grund für diese App.
///
/// Steht auf der Detailseite. Im Player ausdrücklich **nicht**: dort zählt
/// das Bild, und wer die Wiedergabe schon gestartet hat, hat den Beleg
/// gesehen.
struct Belegzeile: View {
    var direktplay: Bool
    var hinweis: String?
    var bewertung: Double?
    var freigabe: String?
    /// Der Beleg steht hinten statt vorn.
    ///
    /// Auf dem Detailkopf laeuft die Zeile „Jahr · Laufzeit · Gattung",
    /// Bewertung, Freigabe, Beleg — die Angaben zum Titel zuerst, die Aussage
    /// ueber die **Wiedergabe** zuletzt. Im Wiedergabeblatt ist es umgekehrt:
    /// dort ist der Beleg der Grund, warum die Zeile ueberhaupt dasteht.
    var belegZuletzt = false

    var body: some View {
        HStack(spacing: 24) {
            if !belegZuletzt { beleg }
            if let bewertung {
                HStack(spacing: 8) {
                    Image(systemName: "star.fill").font(.system(size: 22))
                    Text(String(format: "%.1f", bewertung).replacingOccurrences(of: ".", with: ","))
                        .font(.system(size: 27))
                }
                .foregroundStyle(Color.white.opacity(0.8))
            }

            if let freigabe { Plakette.fern(freigabe) }

            if belegZuletzt { beleg }
        }
    }

    @ViewBuilder
    private var beleg: some View {
        if direktplay {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .heavy))
                Text("Direct Play").font(.system(size: 27, weight: .medium))
            }
            .foregroundStyle(Stil.akzent)
        } else if let hinweis {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                Text(hinweis).font(.system(size: 27, weight: .medium))
            }
            .foregroundStyle(Stil.warnung)
        }
    }
}

/// Der Ladering in Fernseher-Größe — 68 statt der 34 vom Telefon.
///
/// Wie `Plakette.fern` nur ein Satz Zahlen. Der geteilte Baustein bringt
/// obendrein den blassen Hintergrundring mit, den die eigene Fassung nicht
/// hatte.
extension Lader {
    static var fern: Lader { Lader(groesse: 68, staerke: 5) }
}

/// Wenn nichts da ist.
struct Leerzustand: View {
    let symbol: String
    let titel: LocalizedStringKey
    var hinweis: LocalizedStringKey?
    /// Ein Ausweg, kein Sackgassenschild.
    ///
    /// Auf dem iPhone hat jeder Leerzustand einen: „Aktualisieren",
    /// „Filter zurücksetzen". Ohne den steht man davor und kann nichts tun —
    /// auf der Fernbedienung noch unangenehmer als am Finger.
    var knopf: (titel: LocalizedStringKey, tun: () -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 76, weight: .light))
                .foregroundStyle(Stil.schriftSehrLeise)
            Text(titel)
                .font(Stil.reihe)
                .foregroundStyle(Stil.schrift)
            if let hinweis {
                Text(hinweis)
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .multilineTextAlignment(.center)
            }
            if let knopf {
                Button(knopf.titel, action: knopf.tun)
                    .buttonStyle(KnopfStil())
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


// MARK: - Kopfverlauf

/// Dunkelt den oberen Rand ab, damit die Kopfleiste über durchlaufendem
/// Bildmaterial lesbar bleibt.
///
/// **Der sichere Bereich zählt mit.** Genau daran ist die erste Fassung
/// gescheitert: der Verlauf ignoriert ihn (`ignoresSafeArea`) und beginnt bei
/// null, die Kopfleiste liegt darin und beginnt 60 Punkt tiefer. Die kräftige
/// Zone lag damit über leerem Rand, und die Wortmarke stand schon im
/// Ausklang — auf hellen Postern also praktisch ungeschützt. Mit rotem
/// Verlauf im Simulator war es auf einen Blick zu sehen.
///
/// Deshalb rechnet `kopfhoehe` von der Bildkante, nicht vom sicheren Bereich:
/// 60 Punkt Rand plus 56 Abstand plus 60 Zeile.
///
/// Der Reihentitel steht bei rund 240 und liegt im Ausklang, dort sind es
/// noch etwa 15 Prozent. Auf dem Grundton ist das nichts, und wo ein Poster
/// steht, ist es gewollt.
///
/// Sieben Stützpunkte. Drei ergäben eine sichtbare Kante, wo die Steigung
/// umspringt — derselbe Befund wie auf dem iPhone, dort in OFFEN.md notiert.
struct Kopfverlauf: View {
    /// Unterkante der Kopfleiste, von der Bildkante aus gemessen.
    var kopfhoehe: CGFloat = Stil.leisteUnten
    /// Wie weit der Ausklang darunter hinausreicht.
    ///
    /// Lang, und das ist der Punkt: der Übergang muss weich sein, sonst sieht
    /// man die Kante, an der er endet. Kurz gehalten müsste er in wenigen
    /// Dutzend Punkten von 90 Prozent auf null — das **ist** eine Kante, da
    /// hilft keine Verteilung.
    var ausklang: CGFloat = 220

    /// Ein einziger langer Abfall statt der abgestuften Kurve.
    ///
    /// Die Stufen unten sind fuer Seiten gedacht, auf denen Kacheln unter
    /// die Leiste scrollen: dort soll die kraeftige Zone kurz sein, damit die
    /// erste Reihe nicht angegraut wird. Auf der Startseite kommt nichts mehr
    /// hinauf — dafuer steht dort ein Querbild, und auf hellen Motiven sieht
    /// man jede Stufe als Band. Hier zaehlt nur Weichheit.
    var weich = false

    /// Die Stützpunkte in **Punkten**, nicht in Bruchteilen.
    ///
    /// Bruchteile waren ein Fehler, der sich zweimal gerächt hat: sobald sich
    /// `kopfhoehe` änderte, wanderte die ganze Kurve mit, und die kräftige
    /// Zone endete plötzlich neben der Leiste. So gerechnet hängt jeder Punkt
    /// an der Unterkante der Leiste und bleibt dort.
    ///
    /// Lücke und Weichheit sind **dieselbe Schraube**, und das ist der
    /// Grund, warum hier schon mehrfach hin und her gestellt wurde: je
    /// weiter der Abfall gezogen wird, desto weicher wird er — und desto
    /// tiefer muss die erste Reihe beginnen, damit er sie nicht angraut.
    ///
    /// Der Ausweg ist, nicht auf null zu zielen: beim Reihentitel liegen
    /// noch rund 10 Prozent an, und das sieht auf weißer Schrift niemand.
    /// Der Abfall darf deshalb kurz sein (104 Punkte), der Ausklang läuft
    /// trotzdem über 220 aus — nur eben unsichtbar leise statt sichtbar
    /// endend.
    private var stuetzpunkte: [Gradient.Stop] {
        let gesamt = kopfhoehe + ausklang
        func punkt(_ y: CGFloat, _ deckung: Double) -> Gradient.Stop {
            Gradient.Stop(color: Stil.grund.opacity(deckung),
                          location: min(max(y / gesamt, 0), 1))
        }
        if weich {
            return [
                punkt(0,                    0.72),
                punkt(kopfhoehe,            0.44),
                punkt(kopfhoehe + ausklang * 0.45, 0.14),
                punkt(gesamt,               0.00),
            ]
        }
        return [
            punkt(0,               0.92),
            punkt(kopfhoehe,       0.90),
            punkt(kopfhoehe +  18, 0.72),
            punkt(kopfhoehe +  36, 0.52),
            punkt(kopfhoehe +  54, 0.34),
            punkt(kopfhoehe +  72, 0.18),
            punkt(kopfhoehe +  86, 0.09),
            punkt(kopfhoehe + 104, 0.04),
            punkt(kopfhoehe + 132, 0.015),
            punkt(gesamt,          0.00),
        ]
    }

    var body: some View {
        LinearGradient(stops: stuetzpunkte, startPoint: .top, endPoint: .bottom)
        .frame(height: kopfhoehe + ausklang)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}


// MARK: - Hinweise

/// Kurze Meldung über allem, die von selbst wieder geht.
///
/// Auf dem iPhone landet jeder Serverfehler hier. Auf tvOS lief
/// `model.errorMessage` bisher ins Leere — Fehler waren schlicht unsichtbar,
/// und wenn etwas nicht ging, wusste niemand warum.
struct Hinweisstreifen: View {
    let text: String
    var schliessen: () -> Void = {}

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
            Text(text)
                .font(Stil.kachel)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(Stil.warnung)
        .padding(.horizontal, 30)
        .padding(.vertical, 20)
        .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.ecke))
        .overlay {
            RoundedRectangle(cornerRadius: Stil.ecke)
                .strokeBorder(Stil.warnung.opacity(0.3), lineWidth: 2)
        }
        .frame(maxWidth: 1100)
        .task {
            // Von selbst wieder weg: auf tvOS gibt es keinen bequemen Weg,
            // eine Meldung wegzutippen, und stehen bleiben soll sie nicht.
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            schliessen()
        }
    }
}

// MARK: - Umbrechende Reihe

/// Reihe, die umbricht, wenn die Breite nicht reicht.
///
/// `HStack` bricht nie um, und ein Gitter bräuchte feste Spalten — für
/// verschieden breite Chips ist beides falsch.
struct FlussReihe: Layout {
    var abstand: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let breite = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, zeilenhoehe: CGFloat = 0
        for teil in subviews {
            let mass = teil.sizeThatFits(.unspecified)
            if x + mass.width > breite, x > 0 {
                x = 0
                y += zeilenhoehe + abstand
                zeilenhoehe = 0
            }
            x += mass.width + abstand
            zeilenhoehe = max(zeilenhoehe, mass.height)
        }
        return CGSize(width: breite, height: y + zeilenhoehe)
    }

    func placeSubviews(in rahmen: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = rahmen.minX, y = rahmen.minY, zeilenhoehe: CGFloat = 0
        for teil in subviews {
            let mass = teil.sizeThatFits(.unspecified)
            if x + mass.width > rahmen.maxX, x > rahmen.minX {
                x = rahmen.minX
                y += zeilenhoehe + abstand
                zeilenhoehe = 0
            }
            teil.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(mass))
            x += mass.width + abstand
            zeilenhoehe = max(zeilenhoehe, mass.height)
        }
    }
}

/// Rubrik über einer Gruppe von Zeilen.
struct Gruppentitel: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .font(.system(size: 21, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Stil.schriftSehrLeise)
            .padding(.leading, 26)
            .padding(.bottom, 16)
    }
}
