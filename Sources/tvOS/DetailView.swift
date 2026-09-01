import JellyfinKit
import SwiftUI

// MARK: - Der Kopf, den Film und Serie teilen

/// Kulisse, Titel, Angaben, Beschreibung und Knopfreihe — die obere Haelfte
/// jeder Detailseite.
///
/// Auf dem iPhone sind Film- und Serienseite **dieselbe Seite**: gleicher
/// Kopf, gleiche Belegzeile, gleicher weisser Knopf, gleiche Aktionsreihe. Nur
/// die Beschriftung des Knopfes wechselt, und bei Serien kommen darunter die
/// Folgen. Genau so ist es hier — deshalb steht der Kopf in einem eigenen
/// Baustein und nicht zweimal.
///
/// **510 hoch, nicht 1080.** Vorher fuellte der Kopf den ganzen Schirm, das
/// Poster stand links und der Text daneben. Der Entwurf nimmt stattdessen die
/// Kopfzone der Startseite: Kulisse rechts, Text links, und darunter beginnen
/// bei 534 die Reihen — **dieselbe Zeile, in der auf der Startseite der erste
/// Reihentitel steht** (510 + `Stil.reihenKopfLuft`). Beim Wechsel von Start
/// auf Detail bleiben die Reihen also stehen. Das ist der Griff, der die
/// beiden Seiten zusammenhaelt.
///
/// Das Poster faellt damit weg. Es trug den Fortschrittsbalken; der steht
/// jetzt dort, wo er auf jeder anderen Kachel auch steht — an der Folge in
/// der Reihe darunter.
///
/// Kein Zurueckpfeil und keine Reiterleiste: die Seite ist aufgeschlagen,
/// nicht eine Ebene der Startseite. Zurueck macht auf tvOS die Menue-Taste.
struct Detailkopf<Knoepfe: View>: View {
    let model: AppModel
    let item: Item
    let plan: PlaybackPlan?
    /// Ob der Kopf ueberhaupt etwas Fokussierbares enthaelt.
    ///
    /// Die Serienseite hat seit dem Umbau keine Knopfreihe mehr — dort steht
    /// nur Text. Ein `focusSection` ohne Ziel darin ist kein leerer Aufwand,
    /// sondern schaedlich: tvOS meldet einen Bereich an, zieht den Druck
    /// dorthin, findet nichts und laesst ihn fallen. Genau daran ist die
    /// Besetzungsreihe schon einmal haengengeblieben.
    var fokussierbar = true
    @ViewBuilder var knoepfe: () -> Knoepfe

    @ViewBuilder
    var body: some View {
        if fokussierbar { rumpf.focusSection() } else { rumpf }
    }

    private var rumpf: some View {
        ZStack(alignment: .topLeading) {
            Stil.grund
            Kulisse(url: model.querbildURL(for: item, breite: 1600)
                         ?? model.backdropURL(for: item))
                .frame(maxWidth: .infinity, alignment: .trailing)
            block
                .padding(.leading, Stil.randSeite)
                .padding(.top, 140)
        }
        // Nicht beschnitten: die Kulisse ist 700 hoch und darf nach unten
        // ueberragen, ihr eigener Verlauf beendet sie. Die erste Reihe
        // zeichnet darueber, sie ist das naechste Geschwister.
        .frame(height: Stil.heldenHoehe, alignment: .topLeading)
    }

    // **Der ganze Kopf ist ein Fokusabschnitt, nicht nur die Knopfreihe.**
    //
    // tvOS sucht geometrisch. Ohne den Abschnitt findet ein Druck nach oben
    // aus der ersten Reihe nur, was zufaellig in derselben Spalte steht — und
    // links steht die Kulisse, die kein Ziel ist. Umfasst der Abschnitt den
    // ganzen Kopf, landet jeder Weg nach oben auf dem einzigen
    // Fokussierbaren darin: der Knopfreihe. Siehe `fokussierbar`.

    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.name)
                .font(.system(size: 60, weight: .bold))
                .tracking(-1.4)
                .lineSpacing(8)
                .foregroundStyle(Stil.schrift)
                .lineLimit(2)
                .frame(width: 1000, alignment: .leading)

            HStack(spacing: 24) {
                Text(item.nebenzeile)
                    .font(.system(size: 29))
                    .foregroundStyle(Stil.schriftLeise)
                    .lineLimit(1)

                // Angaben zuerst, der Beleg zuletzt — siehe `belegZuletzt`.
                Belegzeile(direktplay: plan?.isLossless ?? false,
                           hinweis: plan.map { $0.isLossless ? nil : $0.method.rawValue } ?? nil,
                           bewertung: item.communityRating,
                           freigabe: item.officialRating,
                           belegZuletzt: true)
            }
            .padding(.top, 14)

            if let text = item.overview, !text.isEmpty {
                Text(text)
                    .font(.system(size: 29))
                    .lineSpacing(11)
                    .foregroundStyle(Stil.schriftLeise)
                    // Zwei Zeilen, nicht drei: sonst waechst der Block ueber
                    // die 510 hinaus und schiebt die Knopfreihe in die erste
                    // Kachelreihe.
                    .lineLimit(2)
                    .padding(.top, 22)
                    .frame(width: 1000, alignment: .leading)
            }

            // Die Knopfreihe darf breiter werden als die 1000 des Textes —
            // fuenf Pillen sind rund 1400 breit. Deshalb liegt der Deckel am
            // Text und nicht am ganzen Block; einmal stand er aussen, und
            // jede Beschriftung war abgeschnitten.
            knoepfe()
                .padding(.top, 36)
        }
    }
}

// MARK: - Merkliste und Gesehen

/// Die zwei Knöpfe, die auf jeder Detailseite gleich sind.
struct Zustandsknoepfe: View {
    let model: AppModel
    let item: Item
    @Binding var gemerkt: Bool
    @Binding var gesehen: Bool
    @Binding var meldung: String?

    var body: some View {
        Group {
            Button {
                gemerkt.toggle()
                // Sofort umschalten, damit der Knopf antwortet — aber
                // zurückdrehen, wenn der Server nein sagt.
                Task {
                    if let grund = await model.setzeMerkliste(item, an: gemerkt) {
                        gemerkt.toggle()
                        meldung = grund
                    }
                }
            } label: {
                Label("Merkliste", systemImage: gemerkt ? "bookmark.fill" : "bookmark")
            }
            .buttonStyle(KnopfStil())
            // Gefuelltes gegen leeres Symbol ist der ganze Unterschied —
            // fuer VoiceOver heissen beide „Merkliste".
            .accessibilityAddTraits(gemerkt ? [.isButton, .isSelected] : .isButton)

            Button {
                gesehen.toggle()
                Task {
                    if let grund = await model.setzeGesehen(item, an: gesehen) {
                        gesehen.toggle()
                        meldung = grund
                    }
                }
            } label: {
                Label("Gesehen", systemImage: gesehen ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .buttonStyle(KnopfStil())
            .accessibilityAddTraits(gesehen ? [.isButton, .isSelected] : .isButton)
        }
    }
}

// MARK: - Filmseite

/// Kopf mit Knopfreihe, darunter „Ähnliche Filme", „Extras" und „Besetzung" —
/// jede Reihe ein `Section`-Abschnitt wie auf der Startseite.
struct DetailView: View {
    let model: AppModel
    let item: Item

    @State private var frisch: Item?
    @State private var plan: PlaybackPlan?
    @State private var gemerkt = false
    @State private var gesehen = false
    @State private var meldung: String?
    /// Der Player liegt im Rahmen — siehe `HauptView`.
    @Environment(\.abspielwunsch) private var abspielen
    @State private var bereitet = false
    @State private var aehnliche: [Item] = []
    @State private var extras: [Item] = []
    @State private var mehrOffen = false

    private var aktuell: Item { frisch ?? item }
    private var darsteller: [Person] { (aktuell.people ?? []).filter(\.istDarsteller) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                kopf

                if !aehnliche.isEmpty {
                    reihenabschnitt {
                        Reihentitel(text: "Ähnliche Filme")
                    } inhalt: {
                        Titelstreifen(model: model, items: aehnliche)
                    }
                }
                if !extras.isEmpty {
                    // **Der Trailer wohnt hier**, nicht als sechste Pille.
                    // Ein Trailer ist etwas zum Abspielen, keine Auskunft —
                    // ein Regalplatz passt besser als eine Zeile in der
                    // Handlungstafel.
                    reihenabschnitt {
                        Reihentitel(text: "Extras")
                    } inhalt: {
                        Titelstreifen(model: model, items: extras) { extra in
                            starte(extra, ab: 0)
                        }
                    }
                }
                if !darsteller.isEmpty {
                    reihenabschnitt {
                        Reihentitel(text: "Besetzung")
                    } inhalt: {
                        Besetzungsstreifen(model: model, leute: darsteller)
                    }
                }
            }
            .padding(.bottom, Stil.abschlussLuft)
        }
        .scrollIndicators(.hidden)
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
        .overlay(alignment: .topLeading) {
            if mehrOffen {
                Handlungstafel(handlungen: mehrHandlungen, offen: $mehrOffen)
                    .padding(.leading, Stil.randSeite)
                    .padding(.top, Handlungstafel.unterDerKnopfreihe)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: mehrOffen)
        .overlay(alignment: .top) {
            if let meldung {
                Hinweisstreifen(text: meldung) { self.meldung = nil }
                    .padding(.top, Stil.randOben)
            }
        }
        .task {
            async let frischerTitel = model.item(id: item.id)
            async let planung = model.plan(for: item.id)
            async let aehnlich = model.aehnliche(item)
            async let extra = model.extras(item)
            async let vorschau = model.trailer(zu: item)
            frisch = await frischerTitel
            plan = await planung
            aehnliche = await aehnlich
            // **Der Trailer steht vorn in den Extras.**
            //
            // Er war vorher eine eigene Pille. Die Knopfreihe des Entwurfs
            // hat dafuer keinen Platz mehr — sechs Pillen sind breiter als
            // die 1600, die zwischen den Raendern liegen. Ersatzlos streichen
            // waere aber falsch: ein Trailer ist etwas zum Abspielen, und
            // dafuer gibt es hier ein Regal. In der Handlungstafel waere er
            // eine Zeile Text unter lauter Auskunft.
            var regal = await extra
            if let vorschau = await vorschau { regal.insert(vorschau, at: 0) }
            extras = regal
            gemerkt = aktuell.userData?.isFavorite ?? false
            gesehen = aktuell.istGesehen
        }
    }

    /// Kulisse, Text und Knopfreihe — 510 hoch.
    private var kopf: some View {
        Detailkopf(model: model, item: aktuell, plan: plan) {
            HStack(spacing: 24) {
                if let ab = aktuell.fortsetzenAb {
                    Button { starte(ab: ab) } label: {
                        Label("Fortsetzen", systemImage: "play.fill")
                    }
                    .buttonStyle(KnopfStil())
                    .disabled(bereitet)

                    // Neu und ausdruecklich im Entwurf: wer schon angefangen
                    // hat, kam sonst nur ueber die Tafel an den Anfang zurueck.
                    Button { starte(ab: 0) } label: {
                        Label("Von vorn", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(KnopfStil())
                    .disabled(bereitet)
                } else {
                    Button { starte(ab: 0) } label: {
                        Label("Abspielen", systemImage: "play.fill")
                    }
                    .buttonStyle(KnopfStil())
                    .disabled(bereitet)
                }

                Zustandsknoepfe(model: model, item: aktuell,
                                gemerkt: $gemerkt, gesehen: $gesehen, meldung: $meldung)

                Mehrknopf(offen: $mehrOffen)
            }
        }
    }

    // MARK: Starten

    private var mehrHandlungen: [Titelhandlung] {
        Titelhandlungen.fuerFilm(aktuell, plan: plan, model: model,
                                 starten: { starte(ab: $0) },
                                 melden: { meldung = $0 },
                                 auffrischen: { await auffrischen() })
    }

    private func auffrischen() async {
        // Auch den Plan: er traegt den Direct-Play-Beleg, und ein Stand ohne
        // seinen Plan ist ein halber Stand.
        async let frischerTitel = model.item(id: item.id)
        async let planung = model.plan(for: item.id)
        frisch = await frischerTitel
        plan = await planung
        gemerkt = aktuell.userData?.isFavorite ?? false
        gesehen = aktuell.istGesehen
    }

    private func starte(ab: Double) {
        Task {
            // Frisch holen: die Position im Listeneintrag ist oft veraltet.
            let ziel = await model.item(id: aktuell.id) ?? aktuell
            starte(ziel, ab: ab)
        }
    }

    /// Einen Titel starten — denselben oder ein Extra.
    private func starte(_ titel: Item, ab: Double) {
        guard !bereitet else { return }
        bereitet = true
        Task {
            defer { bereitet = false }
            guard let plan = await model.plan(for: titel.id) else {
                meldung = String(localized: "Der Server nennt keine Quelle für diesen Titel.")
                return
            }
            abspielen.wrappedValue = Abspielwunsch(item: titel, plan: plan, startAt: ab)
        }
    }
}
