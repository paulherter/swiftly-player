import JellyfinKit
import SwiftUI

/// **Was geladen wird, wird ausgewählt — nicht erraten.**
///
/// Vorher gab es drei Wege zum Laden und keinen davon für „gib mir Staffel 2
/// und 3". Der auffälligste war ein runder Chip neben der Staffelwahl, der
/// genau eine Staffel nahm, und zwar die gerade gewählte. Wer zwei wollte,
/// tippte zweimal; wer eine ganze Serie wollte, tippte sieben Mal.
///
/// Hier steht stattdessen ein Baum mit drei Ebenen — **ganze Serie, Staffel,
/// Folge** —, und jede Ebene trägt denselben runden Kasten in drei Zuständen:
/// leer, teilweise, voll. Wer eine Staffel hakt, hakt ihre Folgen mit; wer
/// eine Folge abwählt, macht die Staffel teilweise.
///
/// **Der Schalter wählt nichts aus.** „Nur ungesehene" entscheidet, *was* ein
/// Haken auswählt. Wer ihn umlegt, verliert seine Auswahl nicht — sie wird neu
/// gerechnet.
///
/// Geladen wird hier nichts. Am Ende reicht das Blatt die gewählten Folgen an
/// `Ladeblatt` weiter, und dort gelten unverändert dieselben drei Lagen:
/// Platz, WLAN, Normalfall. Die Auswahl ist eine Stufe **davor**, kein zweiter
/// Weg daneben.
///
/// **Aufbau wie die Mac-Tafel (`MacLadeauswahl`), Töne nach BRAND 4.** Bis
/// zum 22.09. stand hier fast derselbe Aufbau, aber das Blatt war `flaeche`
/// und die Karten darin auch — von den zwei Gruppen blieben nur die Linien.
/// Der Mac legt die Karten eine Stufe *dunkler* als seine Tafel. Fürs
/// Telefon wurde die andere Richtung gewählt: **Tiefe geht nach oben** — das
/// Blatt bleibt `flaeche` wie jedes Blatt, die Karten liegen auf `erhoeht`.
/// Etwas Dunkleres in Hellerem läse sich als Loch.
struct Ladeauswahl: View {
    @Binding var offen: Bool
    let model: AppModel
    let serie: Item
    let staffeln: [Item]
    /// Die Folgen, die die Serienseite schon hat — meist die gewählte Staffel.
    let vorgeladen: [String: [Item]]
    /// Was die Auswahl hergibt: die Folgen, die geladen werden sollen.
    let weiter: ([Item]) -> Void

    @State private var folgen: [String: [Item]] = [:]
    @State private var gewaehlt: Set<String> = []
    @State private var offeneStaffel: String?
    @State private var nurUngesehene = false
    @State private var laedt = true
    /// **Der Fehlfall gehört dazu** — wie am Mac. Scheitert der Abruf, darf
    /// die Auswahl nicht leer dastehen; dann wüsste niemand, ob die Serie
    /// keine Folgen hat oder der Server nicht antwortet. Vorher blieb die
    /// Staffel am Telefon einfach offen.
    @State private var gestoert = false

    private var alleFolgen: [Item] { staffeln.compactMap { folgen[$0.id] }.flatMap { $0 } }

    /// **Was ein Haken nimmt.** Ohne Schalter alles, mit Schalter nur, was
    /// offen ist — und was schon auf dem Gerät liegt, nie.
    private func nehmbar(_ liste: [Item]) -> [Item] {
        liste.filter { folge in
            guard model.downloads.posten(fuer: folge.id) == nil else { return false }
            guard nurUngesehene else { return true }
            return !(folge.userData?.played ?? false)
        }
    }

    private var gewaehlteFolgen: [Item] { alleFolgen.filter { gewaehlt.contains($0.id) } }
    private var bytes: Int64 {
        gewaehlteFolgen.reduce(0) { $0 + Int64($1.mediaSources?.first?.size ?? 0) }
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .blatt(offen: $offen) { inhalt }
            .task(id: offen) { if offen { await alleLaden() } }
    }

    /// Wie hoch die beiden Karten zusammen sind — gemessen, damit das Blatt
    /// nicht hoeher wird als sein Inhalt.
    @State private var inhaltshoehe: CGFloat = 0

    private var inhalt: some View {
        VStack(spacing: 0) {
            Blattrubrik(text: Text(verbatim: serie.name))

            if gestoert, alleFolgen.isEmpty {
                Stoerhinweis(model: model, erneut: { Task { await alleLaden() } },
                             abstandOben: 10)
                    .padding(.bottom, 16)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        serienkarte
                        staffelkarte
                    }
                    .padding(.bottom, 12)
                    // Gemessen, nicht angenommen.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height }
                        action: { hoeheSetzen($0) }
                }
                // **So hoch wie die Karten, hoechstens 440.**
                //
                // Ohne Deckel waechst das Blatt bei fuenfzehn Staffeln ueber den
                // Schirm hinaus, und der Fuss mit dem Knopf wandert mit. Der
                // Deckel allein reicht aber nicht: eine `ScrollView` ist senkrecht
                // gierig und nimmt sich die ganze Hoehe auch bei zwei Staffeln.
                // Dann steht unter der letzten Karte ein Hohlraum, und weil der
                // Fuss darunter trotzdem am Blattrand klebt, sieht das Blatt
                // aus, als sei etwas verrutscht.
                //
                // 440 statt der 360 vom Mac: das Telefon hat die Hoehe, und der
                // Fuss mit dem Knopf bleibt trotzdem unten im Daumenbereich.
                // Die Mac-Tafel haengt am Knopf der Serie und hat sie nicht.
                .frame(height: min(max(inhaltshoehe, 58), 440))
                .scrollIndicators(.hidden)

                fuss
            }
        }
    }

    /// **Das Blatt waechst mit, statt zu springen.**
    ///
    /// Die Zeilen klappten in einer Animation auf, die Hoehe darueber aber
    /// nicht: gemessen wird erst nach dem Aufklappen, und der Wert kam ohne
    /// Animation an. Also stand das Blatt schlagartig hoch, und die Zeilen
    /// schoben sich danach hinein — Rückmeldung: „zack oben, zack unten". Jetzt
    /// laeuft die Hoehe in derselben Kurve wie das Blatt selbst
    /// (`blattbewegung`, bei reduzierter Bewegung eine Blende). Nur die erste
    /// Messung setzt hart, sonst wuechse das Blatt beim Oeffnen aus null.
    private func hoeheSetzen(_ neu: CGFloat) {
        guard inhaltshoehe > 0, offen else { inhaltshoehe = neu; return }
        withAnimation(Stil.blattbewegung) { inhaltshoehe = neu }
    }

    // MARK: Die Karten

    /// **Karten auf `erhoeht`, Ecke 14.** `eckeKarte` wie jede Gruppe und
    /// wie am Mac; 16 ist die Ecke einer eigenen Fläche, und hier stand sie.
    private var kartenform: RoundedRectangle {
        RoundedRectangle(cornerRadius: Stil.eckeKarte, style: .continuous)
    }

    private var serienkarte: some View {
        VStack(spacing: 0) {
            zeile(kasten: standAlle, titel: String(localized: "Ganze Serie"),
                  rechts: serienRechts) {
                umschalten(alleFolgen)
            }
            Blattlinie()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 13) {
                    Text("Nur ungesehene")
                        // **Mitwachsend, nicht fest** — BRAND.md, Abschnitt 2. Zeilentitel
                        // und Unterzeilen folgen der Systemschrift, die Zeilenhöhen sind
                        // dafür Mindestmaße. Die Zahlenspalte rechts, der Fuß und die
                        // Plakette bleiben fest: tabellarische Ziffern und eine Leiste.
                        .mitwachsend(15, .semibold)
                        .foregroundStyle(Stil.schrift)
                    Spacer(minLength: 12)
                    Schalter(an: $nurUngesehene)
                }
                Text("Entscheidet, was ein Haken auswählt.")
                    .mitwachsend(12)
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Stil.erhoeht, in: kartenform)
        .padding(.horizontal, 16)
        // Legt man den Schalter um, ändert sich nicht die Auswahl, sondern
        // ihre Grundmenge — also wird sie neu gerechnet.
        .onChange(of: nurUngesehene) { _, _ in neuRechnen() }
    }

    /// **„Ganze Serie" nennt nur, was noch fehlt.** Was schon auf dem Gerät
    /// liegt, zählt nicht mit — sonst stünden dort 38 Folgen, von denen elf
    /// gar nicht mehr geladen werden können.
    private var serienRechts: String {
        if laedt { return String(localized: "wird gelesen …") }
        if standAlle == .da { return String(localized: "alles da") }
        if !alleFolgen.isEmpty, sichtbar(alleFolgen).isEmpty {
            return String(localized: "alles gesehen")
        }
        return zahlUndGroesse(nehmbar(alleFolgen).count, bytesVon(alleFolgen))
    }

    private var staffelkarte: some View {
        VStack(spacing: 0) {
            ForEach(Array(staffeln.enumerated()), id: \.element.id) { nr, staffel in
                let eigene = sichtbar(folgen[staffel.id] ?? [])
                let kasten = stand(eigene)
                zeile(kasten: kasten, titel: staffel.name,
                      rechts: staffelRechts(folgen[staffel.id], sichtbar: eigene, kasten),
                      aufgeklappt: offeneStaffel == staffel.id) {
                    umschalten(eigene)
                } aufklappen: {
                    withAnimation(Stil.blattbewegung) {
                        offeneStaffel = offeneStaffel == staffel.id ? nil : staffel.id
                    }
                }
                if offeneStaffel == staffel.id {
                    // **Nur eingerückt, keine zweite Fläche.** Im Dunkelmodus
                    // geht Tiefe nach oben; etwas Dunkleres in einer hellen
                    // Karte sieht aus wie ein Loch.
                    ForEach(eigene) { folge in
                        // Durchgehend, auch unter den eingerueckten Folgen:
                        // ein Strich, der bei 38 anfaengt, waehrend der
                        // darueber bei 18 anfaengt, hat keine Kante, mit der
                        // er fluchtet. Die Begruendung steht bei `Blattlinie`.
                        Blattlinie()
                        let posten = model.downloads.posten(fuer: folge.id)
                        zeile(kasten: posten != nil ? .da
                                      : (gewaehlt.contains(folge.id) ? .voll : .leer),
                              titel: folge.name,
                              rechts: posten.map(ladestand) ?? folgenRechts(folge),
                              klein: true, einzug: 38,
                              leise: gesehen(folge)) {
                            umschalten([folge])
                        }
                    }
                }
                if nr < staffeln.count - 1 { Blattlinie() }
            }
        }
        .background(Stil.erhoeht, in: kartenform)
        .padding(.horizontal, 16)
        // Der Schalter nimmt Folgen aus der Liste — sie gehen weich, nicht
        // schlagartig, und das Blatt schrumpft in derselben Kurve.
        .animation(Stil.blattbewegung, value: nurUngesehene)
    }

    /// **Was in der Liste steht.** Mit „Nur ungesehene" stehen gesehene
    /// Folgen gar nicht erst da und zählen nirgends mit — vorher blieben sie
    /// sichtbar und waren nur nicht mehr wählbar.
    private func sichtbar(_ liste: [Item]) -> [Item] {
        nurUngesehene ? liste.filter { !gesehen($0) } : liste
    }

    private func gesehen(_ folge: Item) -> Bool { folge.userData?.played ?? false }

    /// **Gesehen steht dabei, bevor man wählt.** Ohne Schalter bleiben
    /// gesehene Folgen wählbar — also Kreis wie jede andere, aber Titel leise
    /// und rechts „gesehen" vor der Größe. Vom leisen Haken der geladenen
    /// Folgen unterscheidet sie der Kreis: der Haken heisst „nichts mehr zu
    /// tun", der Kreis „wählbar".
    private func folgenRechts(_ folge: Item) -> String {
        gesehen(folge) ? String(localized: "gesehen") + " · " + groesse(folge)
                       : groesse(folge)
    }

    /// Rechts in der Staffelzeile: was ein Haken dort noch nehmen würde.
    ///
    /// **„alles da" nur, wenn es stimmt.** Hier stand es immer, sobald nichts
    /// mehr zu nehmen war — auch während die Staffel noch gelesen wurde und
    /// auch, wenn „Nur ungesehene" alles ausgeschlossen hatte.
    private func staffelRechts(_ alle: [Item]?, sichtbar eigene: [Item],
                               _ kasten: Kasten) -> String {
        guard let alle else {
            return laedt ? String(localized: "wird gelesen …") : "—"
        }
        if alle.isEmpty { return String(localized: "Keine Folgen") }
        if eigene.isEmpty { return String(localized: "alles gesehen") }
        if kasten == .da { return String(localized: "alles da") }
        let frei = nehmbar(eigene)
        if frei.isEmpty { return String(localized: "alles da") }
        return folgenzahl(frei.count)
    }

    /// **Eine geladene Folge sagt, dass sie da ist.** Vorher stand dort ein
    /// leerer Kreis, der auf Tippen nichts tat.
    private func ladestand(_ posten: Downloadposten) -> String {
        switch posten.stand {
        case .fertig: String(localized: "geladen")
        case .laedt: String(localized: "lädt")
        default: String(localized: "wartet")
        }
    }

    /// **Der Fuss rechnet mit.** Links, was gewaehlt ist; rechts, was danach
    /// frei bleibt — nicht, was jetzt frei ist. Die Zahl, die man wissen will,
    /// ist die nach dem Laden.
    private var fuss: some View {
        VStack(spacing: 10) {
            Blattlinie()
            HStack(spacing: 10) {
                Text(verbatim: gewaehlt.isEmpty
                     ? String(localized: "Nichts gewählt")
                     : zahlUndGroesse(gewaehlt.count, bytes))
                    // „Titel unter Plakat" aus der Leiter, wie am Mac. Hier
                    // stand 13 Semifett — ein Grad ausserhalb der Leiter.
                    .font(Stil.kachel)
                    .foregroundStyle(Stil.schrift)
                    .monospacedDigit()
                Spacer(minLength: 8)
                platzangabe
            }
            .padding(.horizontal, 16)
            // **Die Qualitaet steht dabei, nicht im Kleingedruckten.** Swiftly
            // laedt die Originaldatei — bei 35 GB ist das die Erklaerung fuer
            // die Zahl darueber und kein Nebensatz.
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(Stil.gruppe)
                Text("Direct Play · Originalqualität")
                    .font(Stil.klein)
            }
            .foregroundStyle(Stil.akzent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Stil.akzent.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: Stil.eckeKlein, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

            // **Mit Pfeil, wie am Mac.** Derselbe Pfeil steht in der
            // Knopfreihe der Serie, von dort kommt man her. Reicht der Platz
            // nicht, bleibt der Knopf an: er fuehrt ins Blatt „Nicht genug
            // Platz", und dort steht der Ausweg ueber gesehene Titel.
            Button {
                offen = false
                weiter(gewaehlteFolgen)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down")
                        .font(Stil.rubrikGross)
                        .accessibilityHidden(true)
                    Text(verbatim: gewaehlt.isEmpty
                         ? String(localized: "Laden")
                         : String(localized: "\(gewaehltZahl) laden"))
                }
            }
            // Gesperrt auf `erhoeht`: auf dem Blatt in `flaeche` waere ein
            // gesperrter Knopf in `flaeche` nur noch leise Schrift.
            .buttonStyle(HauptknopfStil(gesperrtFlaeche: Stil.erhoeht))
            .disabled(gewaehlt.isEmpty)
            .padding(.horizontal, 16)
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// **Rechts im Fuss: frei danach, oder was fehlt.** Vorher stand bei zu
    /// wenig Platz „Danach 0 GB frei" — richtig gerechnet und trotzdem
    /// falsch, denn es sagte nicht, dass es nicht reicht. Ob es reicht,
    /// entscheidet `Downloadregeln.fussplatz`, mit derselben Reserve wie das
    /// Blatt danach.
    @ViewBuilder
    private var platzangabe: some View {
        switch Downloadregeln.fussplatz(fuer: bytes, frei: model.downloads.frei) {
        case .frei(let rest):
            Text(verbatim: String(localized: "Danach \(Downloadregeln.groesse(rest)) frei"))
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
                .monospacedDigit()
        case .zuWenig(let fehlt):
            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(verbatim: String(localized: "\(Downloadregeln.groesse(fehlt)) zu wenig"))
                    .font(Stil.klein)
                    .monospacedDigit()
            }
            // `warnung` auf `flaeche`: 5,58:1.
            .foregroundStyle(Stil.warnung)
        }
    }

    private var gewaehltZahl: String { folgenzahl(gewaehlt.count) }

    private func folgenzahl(_ n: Int) -> String {
        n == 1 ? String(localized: "1 Folge") : String(localized: "\(n) Folgen")
    }

    /// „23 Folgen · 31,4 GB" — Anzahl und Groesse in einem Zug, damit die Zeile
    /// eine Aussage traegt und nicht zwei.
    private func zahlUndGroesse(_ anzahl: Int, _ bytes: Int64) -> String {
        folgenzahl(anzahl) + " · " + Downloadregeln.groesse(bytes)
    }

    // MARK: Der Kasten und die Zeile

    /// Vier Zustände: die drei der Auswahl, und **da** für das, was schon auf
    /// dem Gerät liegt und nicht mehr gewählt werden kann.
    private enum Kasten { case leer, teil, voll, da }

    private func stand(_ alle: [Item], daZaehlt: Bool = true) -> Kasten {
        let liste = sichtbar(alle)
        if daZaehlt, !liste.isEmpty,
           liste.allSatisfy({ model.downloads.posten(fuer: $0.id) != nil }) {
            return .da
        }
        let frei = nehmbar(liste)
        guard !frei.isEmpty else { return .leer }
        let an = frei.filter { gewaehlt.contains($0.id) }.count
        return an == 0 ? .leer : (an == frei.count ? .voll : .teil)
    }
    /// Solange nicht jede Staffel gelesen ist, ist die Serie nicht „da" —
    /// auch wenn die erste gelesene zufällig ganz geladen ist.
    private var standAlle: Kasten { stand(alleFolgen, daZaehlt: !laedt) }

    private func zeile(kasten: Kasten, titel: String, rechts: String,
                       klein: Bool = false, einzug: CGFloat = 16,
                       aufgeklappt: Bool? = nil,
                       leise: Bool = false,
                       tun: @escaping () -> Void,
                       aufklappen: (() -> Void)? = nil) -> some View {
        // **Kreis 22, Trefferflaeche 44** (BRAND 7). Die 44 ragen je 11 ueber
        // den Kreis hinaus; Einzug und Abstand ziehen sie wieder ab, damit
        // der Kreis dort stehen bleibt, wo er stand.
        HStack(spacing: 13 - 11) {
            Button(action: tun) {
                kastenbild(kasten)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Stil.Druckknopf())
            .disabled(kasten == .da)
            .accessibilityLabel(Text(verbatim: titel))
            .accessibilityValue(kastenwert(kasten))
            .accessibilityAddTraits(kasten == .voll ? .isSelected : [])
            // Ohne Aufklapper tut die Zeile daneben dasselbe wie der Kreis —
            // dann liest VoiceOver sie einmal, nicht zweimal.
            .accessibilityHidden(aufklappen == nil)

            Button { (aufklappen ?? tun)() } label: {
                HStack(spacing: 10) {
                    Text(verbatim: titel)
                        .mitwachsend(klein ? 13 : 15, klein ? .medium : .semibold)
                        .foregroundStyle(kasten == .da || leise ? Stil.schriftLeise : Stil.schrift)
                        .lineLimit(1)
                    Spacer(minLength: 10)
                    Text(verbatim: rechts)
                        .font(Stil.klein)
                        .foregroundStyle(Stil.schriftSehrLeise)
                        .monospacedDigit()
                    if let aufgeklappt {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Stil.schriftSehrLeise)
                            .rotationEffect(.degrees(aufgeklappt ? 0 : -90))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(Stil.Druckzeile())
            .accessibilityValue(aufklappen == nil ? kastenwert(kasten) : Text(verbatim: ""))
            .accessibilityAddTraits(aufklappen == nil && kasten == .voll ? .isSelected : [])
            .accessibilityHint(aufgeklappt.map { Text($0 ? LocalizedStringKey("Zuklappen") : LocalizedStringKey("Aufklappen")) }
                               ?? Text(verbatim: ""))
        }
        .padding(.leading, einzug - 11)
        .padding(.trailing, 16)
        // **Die Folgenzeile traegt die 52 der uebrigen Blaetter, die
        // Staffelzeile eine Stufe darueber.**
        //
        // Hier stand, beide Hoehen seien „dieselben wie in den uebrigen
        // Blaettern" — das stimmt nur fuer die 52. Die 58 sind die Ausnahme
        // und sie ist gewollt: die eingerueckte Folgenzeile soll flacher
        // stehen als die Staffel, zu der sie gehoert. Vorher waren es 46 und
        // 52, damit lag die Folgenzeile unter dem Blattmass.
        .frame(minHeight: klein ? 52 : 58)
    }

    /// Was VoiceOver zum Kreis sagt. „Gewählt" sagt die Eigenschaft
    /// `isSelected` selbst.
    private func kastenwert(_ k: Kasten) -> Text {
        switch k {
        case .leer, .voll: Text(verbatim: "")
        case .teil: Text("teilweise")
        case .da: Text("geladen")
        }
    }

    @ViewBuilder
    private func kastenbild(_ k: Kasten) -> some View {
        ZStack {
            switch k {
            case .leer:
                // **Der wichtigste Zustand war der unsichtbarste.** Hier
                // stand weiss 26 %: gerechnet 2,36:1 auf `erhoeht`, und
                // BRAND 1 nennt schon weiss 28 % (2,50:1) als verboten.
                // Bedienzeichen brauchen 3:1. `Stil.rand` waere mit 12 %
                // noch weniger — `schriftSehrLeise` traegt 4,58:1 auf
                // `erhoeht`, der Karte, auf der er jetzt liegt.
                Circle().strokeBorder(Stil.schriftSehrLeise, lineWidth: 1.6)
            case .teil:
                Circle().fill(Stil.akzent)
                // Semifett, nicht `.heavy`: drei Gewichte, und `.heavy`
                // faellt weg (BRAND 2).
                Image(systemName: "minus").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Stil.aufAkzent)
            case .voll:
                Circle().fill(Stil.akzent)
                Image(systemName: "checkmark").font(Stil.gruppe)
                    .foregroundStyle(Stil.aufAkzent)
            case .da:
                // **Leise, ohne Kreis.** Ein Haken in Akzent hiesse
                // „gewählt"; dieser sagt nur, dass nichts mehr zu tun ist.
                Image(systemName: "checkmark").font(Stil.listentitel)
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
        }
        .frame(width: 22, height: 22)
        .animation(Stil.umschalten, value: k)
    }

    // MARK: Auswahl und Daten

    private func umschalten(_ liste: [Item]) {
        let frei = nehmbar(liste)
        guard !frei.isEmpty else { return }
        let alleAn = frei.allSatisfy { gewaehlt.contains($0.id) }
        withAnimation(Stil.umschalten) {
            for f in frei {
                if alleAn { gewaehlt.remove(f.id) } else { gewaehlt.insert(f.id) }
            }
        }
    }

    /// Nach dem Schalter: alles, was nicht mehr nehmbar ist, fällt heraus.
    private func neuRechnen() {
        let erlaubt = Set(nehmbar(alleFolgen).map(\.id))
        withAnimation(Stil.umschalten) { gewaehlt.formIntersection(erlaubt) }
    }

    private func bytesVon(_ liste: [Item]) -> Int64 {
        nehmbar(liste).reduce(0) { $0 + Int64($1.mediaSources?.first?.size ?? 0) }
    }

    private func groesse(_ folge: Item) -> String {
        guard let b = folge.mediaSources?.first?.size, b > 0 else { return "—" }
        return Downloadregeln.groesse(Int64(b))
    }

    /// **Jede Staffel einmal, und der Speicher zählt.**
    ///
    /// Die Serienseite hat nur die gewählte Staffel geladen. Für „ganze Serie"
    /// braucht das Blatt jede — sonst stünde dort eine Zahl, die nicht stimmt.
    /// Geholt wird nacheinander, damit der Server nicht sieben Anfragen auf
    /// einmal bekommt, und was schon da ist, wird nicht neu geholt.
    ///
    /// **`nil` heißt gestört, `[]` heißt leer.** Gescheiterte Abrufe werden
    /// nicht gemerkt — sonst stünde die leere Liste später als Tatsache da.
    private func alleLaden() async {
        laedt = true
        gestoert = false
        model.downloads.platzAuffrischen()
        folgen = vorgeladen
        for staffel in staffeln where folgen[staffel.id] == nil {
            guard let liste = await model.folgen(serie: serie.id, staffel: staffel.id) else {
                gestoert = true
                continue
            }
            folgen[staffel.id] = liste
            Serienspeicher.geteilt.merken(serie.id) { $0.folgen[staffel.id] = liste }
        }
        laedt = false
        // Was seit dem letzten Öffnen geladen wurde, ist nicht mehr wählbar —
        // sonst zählte der Fuss es noch mit.
        neuRechnen()
    }
}
