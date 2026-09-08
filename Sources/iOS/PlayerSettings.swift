import JellyfinKit
import SwiftUI
import VLCKit

/// Einstellungen während der Wiedergabe.
///
/// Vollständig eigene Bausteine: kein `List`, kein `Toggle`, kein `Picker`,
/// kein Blattgriff. Apples Fassungen bringen jeweils ihr eigenes
/// Erscheinungsbild mit, das neben unserer flachen Gestaltung auffällt.
///
/// Flache Liste statt verschachtelter Ebenen: Untertitel und Ton greift man
/// mitten im Film, die sollen nicht hinter zwei Ebenen liegen.
struct PlayerSettingsSheet: View {
    let surface: VLCPlayerView?
    /// Nur fuer die Zeile unter dem Titel: was der Server ausliefert.
    let plan: PlaybackPlan
    @Binding var offen: Bool
    @Binding var tempo: Float
    @Binding var schlafminuten: Int?
    @Binding var querformatFest: Bool

    /// Erzwingt ein Neuzeichnen, wenn VLC die Spurwahl übernommen hat.
    @State private var stand = 0

    /// Die eigene Wahl, unabhängig von VLC.
    ///
    /// VLC übernimmt eine Spurwahl nicht sofort — liest man direkt danach
    /// `isSelected`, steht dort noch der alte Stand. Die Anzeige hing dadurch
    /// einen Klick hinterher, und beim Wechsel von „Aus" auf eine Spur trugen
    /// kurz **beide** einen Haken. Was angetippt wurde, wissen wir aber selbst.
    @State private var tonWahl: String?
    @State private var untertitelWahl: String??
    // Stufen und Beschriftung liegen in JellyfinKit — sie standen dreimal
    // da, einmal je Plattform.
    private let tempi = Tempostufen.werte
    private let schlafzeiten = Schlafzeiten.werte

    @State private var breite: CGFloat = 0
    @AppStorage("technikschild") private var technikschild = false
    @AppStorage("bildfuellend") private var bildfuellend = false

    /// **Welche Ebene die Tafel gerade zeigt.**
    ///
    /// Die Wurzel traegt sechs eingeklappte Zeilen mit ihrem aktuellen Wert;
    /// eine davon anzutippen legt die Auswahl darueber. Vorher stand alles
    /// gleichzeitig offen -- bei drei Ton- und vier Untertitelspuren war das
    /// eine lange Rolle, in der man den eingestellten Stand suchen musste.
    enum Ebene: Equatable {
        case wurzel, ton, untertitel, bildformat, tempo, schlafzeit

        var titel: LocalizedStringKey {
            switch self {
            case .wurzel:     "Wiedergabe"
            case .ton:        "Ton"
            case .untertitel: "Untertitel"
            case .bildformat: "Bildformat"
            case .tempo:      "Tempo"
            case .schlafzeit: "Schlafzeit"
            }
        }
    }

    @State private var ebene: Ebene = .wurzel

    /// **In welche Richtung der letzte Wechsel ging.**
    ///
    /// Ohne das kann der Uebergang nicht wissen, ob er nach links oder nach
    /// rechts schieben soll -- und ein Zurueck, das sich anfuehlt wie ein
    /// Vorwaerts, verliert genau die Ortsangabe, die die Bewegung geben soll.
    @State private var vorwaerts = true

    /// Wie hoch der Inhalt der aktuellen Ebene ist.
    ///
    /// **Damit die Karte sich anlegt, statt sich auszudehnen.** Eine
    /// `ScrollView` nimmt sich alles, was ihr angeboten wird -- im Querformat
    /// ist das genau richtig, im Hochkant stand darunter eine halbe
    /// Bildschirmhoehe leer. Gemessen wird der Inhalt, und die Flaeche wird
    /// darauf gedeckelt; erst wenn er nicht mehr passt, begrenzt der Rand
    /// und es wird gescrollt.
    @State private var inhaltshoehe: CGFloat = 0

    /// Auch dieser Kopf sitzt oben links, und auch er liegt im Fenster
    /// unter der Ampel. Er steht im Player und erbt dessen Lage.
    /// Selbst gerechnet und nicht aus der Umgebung gelesen: der Player ist
    /// ein `fullScreenCover` und haengt ausserhalb der Ansicht, die den Wert
    /// setzt. Ob die Umgebung dorthin durchreicht, will ich nicht annehmen —
    /// angenommen hatte ich hier schon zweimal genug.
    private var imFenster: Bool {
        Fensterknoepfe.imFenster(fensterbreite: breite)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // **Abdunkeln statt zudecken.** Vorher lag hier eine fast
            // deckende Flaeche ueber dem ganzen Schirm (0,97) und der Film
            // war praktisch weg. Er laeuft aber weiter, und man stellt etwas
            // ein, *waehrend* man zusieht -- Ton und Untertitel greift man
            // genau dann, wenn eine Stelle gerade laeuft. Also bleibt er
            // sichtbar, nur zurueckgenommen.
            Stil.grund.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { schliessen() }

            // **Der Inhalt haengt an `offen`, die Flaeche nicht.**
            //
            // Das Blatt bleibt montiert und blendet nur, damit es beim
            // Schliessen nicht schlagartig verschwindet (siehe `PlayerScreen`).
            // Sein Inhalt darf das nicht mitmachen: die Spurlisten gehen
            // direkt in VLCKit, und dauerhaft montiert waeren das bei jedem
            // 500-ms-Takt vier Anfragen, in jeder Wiedergabe.
            if offen { tafel }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { neu in
            breite = neu
        }
        // Beim Schliessen zurueck auf die Wurzel: wer sie neu oeffnet, will
        // die Uebersicht, nicht die Liste von vorhin.
        .onChange(of: offen) { _, jetzt in if !jetzt { ebene = .wurzel } }
    }

    /// **Eine schwebende Karte am Rand, keine Platte ueber dem Schirm.**
    ///
    /// Im Querformat -- und dort haengt der Player fest -- sind nur rund 390
    /// Punkte Hoehe da. Ein Blatt von unten bleibt darin ein Streifen. Eine
    /// Karte an der Seite hat die volle Hoehe, laesst das Bild daneben stehen
    /// und braucht keinen einzigen Bildlauf fuer die Uebersicht.
    private var tafel: some View {
        VStack(alignment: .leading, spacing: 12) {
            kopfzeile
                .id(ebene == .wurzel)
                .transition(.opacity)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch ebene {
                    case .wurzel:     wurzelinhalt
                    case .ton:        tonauswahl
                    case .untertitel: untertitelauswahl
                    case .bildformat: bildformatauswahl
                    case .tempo:      tempoauswahl
                    case .schlafzeit: schlafzeitauswahl
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { hoch in
                    inhaltshoehe = hoch
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: inhaltshoehe > 0 ? inhaltshoehe : nil)
            // **Der Wechsel schiebt, er blendet nicht.** Die Richtung ist die
            // Ortsangabe: hinein geht nach links weg und von rechts herein,
            // zurueck andersherum. Ohne `id` haelt SwiftUI die Ansicht fuer
            // dieselbe und tauscht den Inhalt ohne Uebergang -- genau das
            // war das harte Umspringen.
            .id(ebene)
            .transition(uebergang)
        }
        .padding(14)
        .frame(width: 356)
        .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // **Der Beschnitt gehoert an die Karte, nicht an den Inhalt.**
        //
        // Erst stand er an der Inhaltsflaeche selbst -- und der schiebende
        // Uebergang nimmt den Beschnitt dann einfach mit hinaus, weil er die
        // ganze Ansicht samt ihrem Zuschnitt versetzt. Beschnitten werden
        // muss die Stelle, die stehenbleibt: die Karte. Vor dem Rahmen, damit
        // der obendrauf liegt statt selbst halbiert zu werden.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Stil.rand)
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .padding(.trailing, 14)
        .padding(.vertical, 14)
        // Die Ampel im Fenster liegt oben links, nicht rechts -- die Karte
        // muss ihr nicht ausweichen. Der Abstand oben bleibt derselbe.
        .padding(.top, imFenster ? Fensterknoepfe.hoehe : 0)
    }

    /// Wurzel: Titel und Auslieferungsart. Tiefer: zurueck und der Name der
    /// Liste, in der man steht.
    private var kopfzeile: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if ebene == .wurzel {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wiedergabe")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Stil.schrift)
                    Text(auslieferung)
                        .font(.system(size: 12))
                        .foregroundStyle(Stil.schriftLeise)
                }
                Spacer(minLength: 0)
                schliessknopf
            } else {
                Button { zurueck() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Wiedergabe")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Stil.akzent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Text(ebene.titel)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Stil.schrift)
            }
        }
    }

    private var schliessknopf: some View {
        Button { schliessen() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Stil.schrift.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// **Was der Server liefert, direkt unter dem Titel.**
    ///
    /// Diese App transkodiert nie, und das ist ihre Zusage. Wer die
    /// Einstellungen oeffnet, sieht ohnehin hierher -- also steht es hier,
    /// statt nur im Technikschild.
    private var auslieferung: String {
        var text = Technikangaben.auslieferung(plan.method)
        if let video = plan.quelle.flatMap(Dateiangaben.videospur),
           let codec = Technikangaben.codecname(video.codec) {
            text += " · \(codec)"
        }
        return text
    }

    private var wurzelinhalt: some View {
        VStack(alignment: .leading, spacing: 12) {
            gruppe {
                navzeile("speaker.wave.2.fill", "Ton", tonJetzt ?? String(localized: "Keine")) { hinein(.ton) }
                trenner
                navzeile("captions.bubble.fill", "Untertitel",
                         untertitelJetzt ?? String(localized: "Aus")) { hinein(.untertitel) }
                trenner
                navzeile("aspectratio", "Bildformat",
                         String(localized: bildfuellend ? "Formatfüllend" : "Ganzes Bild")) { hinein(.bildformat) }
                trenner
                navzeile("speedometer", "Tempo", beschriftung(tempo)) { hinein(.tempo) }
                trenner
                navzeile("moon.fill", "Schlafzeit", schlafwort) { hinein(.schlafzeit) }
            }

            // **Schalter stehen getrennt von Wegen.** Eine Zeile, die
            // woanders hinfuehrt, und eine, die hier etwas umlegt, sehen
            // sonst gleich aus und man tippt die falsche.
            gruppe {
                schalterzeile("chart.bar.fill", "Technikschild", an: $technikschild)
                if bildWahlMoeglich {
                    trenner
                    schalterzeile("lock.rotation", "Querformat fest", an: $querformatFest)
                }
            }
        }
    }

    // MARK: - Die Listen

    private var tonauswahl: some View {
        VStack(alignment: .leading, spacing: 8) {
            spaltentitel("In dieser Datei")
            gruppe {
                let spuren = surface?.tonspuren ?? []
                ForEach(Array(spuren.enumerated()), id: \.element.trackId) { paar in
                    if paar.offset > 0 { trenner }
                    auswahlzeile(paar.element.trackName,
                                 gewaehlt: tonJetzt == paar.element.trackName) {
                        tonWahl = paar.element.trackName
                        surface?.waehleTonspur(paar.element)
                    }
                }
            }
        }
        .id(stand)
    }

    private var untertitelauswahl: some View {
        VStack(alignment: .leading, spacing: 8) {
            spaltentitel("In dieser Datei")
            gruppe {
                auswahlzeile(String(localized: "Aus"), gewaehlt: untertitelJetzt == nil) {
                    untertitelWahl = .some(nil)
                    surface?.waehleUntertitel(nil)
                }
                ForEach(surface?.untertitelspuren ?? [], id: \.trackId) { spur in
                    trenner
                    auswahlzeile(spur.trackName, gewaehlt: untertitelJetzt == spur.trackName) {
                        untertitelWahl = .some(spur.trackName)
                        surface?.waehleUntertitel(spur)
                    }
                }
            }
        }
        .id(stand)
    }

    private var bildformatauswahl: some View {
        VStack(alignment: .leading, spacing: 8) {
            gruppe {
                auswahlzeile(String(localized: "Ganzes Bild"), gewaehlt: !bildfuellend) {
                    bildfuellend = false
                    surface?.bildfuellend(false)
                }
                trenner
                auswahlzeile(String(localized: "Formatfüllend"), gewaehlt: bildfuellend) {
                    bildfuellend = true
                    surface?.bildfuellend(true)
                }
            }
            hinweis("Formatfüllend schneidet links und rechts ab, damit keine Balken bleiben. Geht auch mit zwei Fingern im Bild.")
        }
    }

    private var tempoauswahl: some View {
        gruppe {
            ForEach(Array(tempi.enumerated()), id: \.element) { paar in
                if paar.offset > 0 { trenner }
                auswahlzeile(beschriftung(paar.element), gewaehlt: tempo == paar.element) {
                    tempo = paar.element
                }
            }
        }
    }

    private var schlafzeitauswahl: some View {
        gruppe {
            auswahlzeile(String(localized: "Aus"), gewaehlt: schlafminuten == nil) {
                schlafminuten = nil
            }
            ForEach(schlafzeiten, id: \.self) { minuten in
                trenner
                auswahlzeile("\(minuten)", gewaehlt: schlafminuten == minuten) {
                    schlafminuten = minuten
                }
            }
        }
    }

    // MARK: - Bausteine

    private func gruppe<Inhalt: View>(@ViewBuilder _ inhalt: () -> Inhalt) -> some View {
        VStack(spacing: 0) { inhalt() }
            .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Eingerueckt bis unter die Beschriftung, nicht ueber die ganze Breite --
    /// sonst schneidet der Strich das Zeichen ab.
    private var trenner: some View {
        Stil.linie.frame(height: 1).padding(.leading, 46)
    }

    private func navzeile(_ zeichen: String, _ name: LocalizedStringKey,
                          _ wert: String, aktion: @escaping () -> Void) -> some View {
        Button(action: aktion) {
            HStack(spacing: 12) {
                Image(systemName: zeichen)
                    .font(.system(size: 15))
                    .foregroundStyle(Stil.akzent)
                    .frame(width: 22)
                Text(name)
                    .font(.system(size: 16))
                    .foregroundStyle(Stil.schrift)
                Spacer(minLength: 8)
                Text(wert)
                    .font(.system(size: 15))
                    .foregroundStyle(Stil.schriftLeise)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// **Kein Knopf um den Schalter herum.** `Schalter` ist selbst einer;
    /// die Zeile noch einmal antippbar zu machen haette zwei Knoepfe
    /// ineinander gelegt, und dann trifft man beim Zielen auf die Wippe
    /// manchmal den aeusseren.
    private func schalterzeile(_ zeichen: String, _ name: LocalizedStringKey,
                               an: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: zeichen)
                .font(.system(size: 15))
                .foregroundStyle(Stil.akzent)
                .frame(width: 22)
            Text(name)
                .font(.system(size: 16))
                .foregroundStyle(Stil.schrift)
            Spacer(minLength: 8)
            Schalter(an: an)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func auswahlzeile(_ text: String, gewaehlt: Bool,
                              aktion: @escaping () -> Void) -> some View {
        Button(action: aktion) {
            HStack(spacing: 10) {
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(gewaehlt ? Stil.akzent : Stil.schrift)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if gewaehlt {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Stil.akzent)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hinweis(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Stil.schriftSehrLeise)
            .padding(.horizontal, 4)
    }

    private var schlafwort: String {
        schlafminuten.map { "\($0)" } ?? String(localized: "Aus")
    }

    /// Federnd statt linear: `easeOut` ueber 0,18 s kam an, ohne dass die
    /// Bewegung ein Ende hatte. Eine Feder laeuft aus, und das liest sich
    /// als „angekommen".
    private static let bewegung = Animation.spring(response: 0.34, dampingFraction: 0.86)

    private var uebergang: AnyTransition {
        .asymmetric(
            insertion: .move(edge: vorwaerts ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: vorwaerts ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func hinein(_ ziel: Ebene) {
        vorwaerts = true
        withAnimation(Self.bewegung) { ebene = ziel }
    }

    private func zurueck() {
        vorwaerts = false
        withAnimation(Self.bewegung) { ebene = .wurzel }
    }

    private func schliessen() {
        offen = false
    }

    /// Die eigene Wahl hat Vorrang; erst wenn keine getroffen wurde, zählt
    /// das, was VLC meldet.
    private var untertitelJetzt: String? {
        if let untertitelWahl { return untertitelWahl }
        return surface?.gewaehlterUntertitel?.trackName
    }

    private var tonJetzt: String? {
        tonWahl ?? surface?.gewaehlteTonspur?.trackName
    }

    /// Kleiner gesperrter Titel über einer Spalte.
    private func spaltentitel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .textCase(.uppercase)
            .font(.system(size: 11, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(Color.white.opacity(0.4))
            .padding(.bottom, 6)
    }

    /// Auf dem iPad gibt es die Wahl nicht: `Orientierung` ist dort ein
    /// Leerlauf, weil eine multitaskingfähige App die Drehung nicht erzwingen
    /// darf. In den Einstellungen ist die Zeile deshalb schon weg — hier
    /// stand sie noch, und zwar wirkungslos.
    private var bildWahlMoeglich: Bool { Orientierung.querformatSperreMoeglich }

    private func beschriftung(_ wert: Float) -> String {
        Tempostufen.beschriftung(wert)
    }
}
