import JellyfinKit
import SwiftUI
import UIKit

/// Der Rahmen um alles: vier Bereiche und die Leiste **oben**.
///
/// Aufbau wie auf dem iPhone — vier eigene Navigationsstapel, nur besuchte
/// werden angelegt —, mit einem Unterschied, der tvOS eigen ist: unsichtbare
/// Stapel müssen auch **unfokussierbar** sein. `opacity(0)` versteckt sie nur
/// fürs Auge; der Fokus wandert weiter hinein, und die Fernbedienung landet
/// in einer Ansicht, die niemand sieht. Dagegen hilft `disabled`.
/// Der laufende Abspielwunsch, durchgereicht bis in jede Unterseite.
///
/// **Warum ueber die Umgebung und nicht je Seite:** der Player muss ueber
/// allem liegen, auch ueber der Kopfleiste, und der Rest der App darf
/// waehrenddessen keinen Fokus mehr annehmen. Beides laesst sich nur an
/// einer Stelle zusagen. Lag die Auflage in der Seite, galt es fuer die
/// Startseite anders als fuer die Detailseite — und genau daran hing der
/// Fehler, bei dem sich der Player nicht mehr verlassen liess.
private struct AbspielSchluessel: EnvironmentKey {
    static let defaultValue: Binding<Abspielwunsch?> = .constant(nil)
}

/// **Eine offene Tafel muss auch die Kopfleiste stilllegen.**
///
/// Dieselbe Begruendung wie beim Abspielwunsch, nur eine Ebene kleiner. Eine
/// Seite kann sich selbst abschalten, solange eine `Handlungstafel` offen
/// steht — die Leiste ueber ihr gehoert ihr aber nicht. Auf den Detail- und
/// Serienseiten fiel das nie auf: dort ist die Leiste ohnehin weg, weil sie
/// im Stapel liegen. Auf Filme und Serien steht sie, und der Fokus stieg aus
/// der offenen Tafel nach oben in die Bereichsknoepfe — Tafel offen, Fokus
/// woanders.
private struct TafelSchluessel: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    var abspielwunsch: Binding<Abspielwunsch?> {
        get { self[AbspielSchluessel.self] }
        set { self[AbspielSchluessel.self] = newValue }
    }

    /// Setzt eine Seite das, nimmt die Kopfleiste keinen Fokus mehr an.
    var tafelOffen: Binding<Bool> {
        get { self[TafelSchluessel.self] }
        set { self[TafelSchluessel.self] = newValue }
    }
}

struct HauptView: View {
    let model: AppModel

    @State private var bereich: Bereich = .start
    @State private var besucht: Set<Bereich> = [.start]
    @State private var pfade = [NavigationPath(), NavigationPath(),
                                NavigationPath(), NavigationPath()]

    /// **Der Player gehoert hierher, nicht in die Seite.**
    ///
    /// Von der Detailseite aus geht er sauber auf, weil dort die Kopfleiste
    /// ohnehin weicht — `anDerWurzel` ist falsch, sobald ein Pfad steht. Auf
    /// der Startseite steht die Leiste aber, und eine Auflage **innerhalb**
    /// des Stapels liegt darunter: das Bild lief, die Leiste blieb im Weg,
    /// und weil der Fokus in ihr sass, griff auch die Menue-Taste ins Leere.
    ///
    /// Deshalb liegt der Wunsch im Rahmen und der Player ganz oben.
    @State private var abspielen: Abspielwunsch?

    /// Auf Unterseiten weicht die Kopfleiste — dort zaehlt der Inhalt, und
    /// zurueck geht es ueber die Menue-Taste.
    ///
    /// `nil` heisst: Menue nicht anfassen, durchfallen lassen — auf Start,
    /// auf Unterseiten und im Player.
    private var zurueckAufStart: (() -> Void)? {
        guard bereich != .start, pfade[bereich.rawValue].isEmpty,
              abspielen == nil else { return nil }
        return { bereich = .start }
    }

    private var anDerWurzel: Bool { pfade[bereich.rawValue].isEmpty && abspielen == nil }

    /// Der Druck aufs Abzeichen.
    ///
    /// **Bei einer Sitzung sofort, bei mehreren erst fragen.** Auf zwei
    /// Geräten zu raten, welches gemeint ist, geht in der Hälfte der Fälle
    /// daneben — und der Preis dafür ist, dass anderswo der Film anhält.
    private func abzeichenGedrueckt() {
        if uebernahme.mehrereDa { auswahlOffen = true }
        else if let eine = uebernahme.angebot { hierWeiterschauen(eine) }
    }

    /// Das andere Gerät anhalten und hier an derselben Stelle weitermachen.
    ///
    /// Die Reihenfolge ist die ganze Sache: erst dort anhalten, dann hier den
    /// Plan holen, dann starten. Geht das Anhalten schief, passiert hier
    /// nichts — sonst liefen zwei Tonspuren im Raum.
    private func hierWeiterschauen(_ sitzung: Fremdsitzung) {
        auswahlOffen = false
        Task { abspielen = await uebernahme.wunsch(fuer: sitzung, model: model) }
    }

    /// **Ob die Kopfleiste steht — als eigener Zustand, nicht abgeleitet.**
    ///
    /// Abgeleitet koennte sie nicht ausblenden: der Pfad wird ohne Animation
    /// gesetzt (siehe die Bindung in `stapel`), und was daran haengt, springt
    /// mit. Paul: „oben die Leiste, da ist alles weg — Profilbild weg, Logo
    /// weg, Start, Filme, Serien, Suche. Das muss ausgeblendet werden."
    ///
    /// Als eigener Zustand, in einem `onChange` gesetzt, laeuft der Wechsel
    /// in einer **neuen** Transaktion — und die darf animieren.
    @State private var leisteDa = true
    @State private var tafelOffen = false
    /// Was auf einem anderen Gerät läuft.
    @State private var uebernahme = Uebernahmemodell()
    /// Steht auf mehreren Geräten etwas, wird gefragt statt geraten.
    @State private var auswahlOffen = false

    // Die Leiste scrollt bewusst **nicht** mit weg.
    //
    // Apples Richtlinie erlaubt es („people can scroll the tab bar offscreen
    // when the current tab contains a single main view"), und gebaut war es
    // auch — aber es sah falsch aus: die Leiste wanderte halb aus dem Bild,
    // und der Verlauf ging mit, sodass der Inhalt oben ungeschützt weiterlief.
    // Erlaubt heißt nicht besser. Sie bleibt stehen.

    var body: some View {
        ZStack {
            // **Der Player ist ein Geschwister, kein Kind.**
            //
            // Vorher lag `.disabled` in der Kette **vor** `.overlay`. Damit
            // erbte der Player die Sperre: er war zu sehen, aber tot —
            // nichts darin fokussierbar, jeder Tastendruck unbehandelt, und
            // Menue fiel durch, was tvOS als Ausstieg las. Er verschwand also
            // beim ersten Druck, und keine Reparatur im Player konnte je
            // greifen, weil keine von ihnen zum Zuge kam.
            //
            // **Auch beim Auswahlblatt sperren, nicht nur beim Player.**
            //
            // Sonst bleibt alles dahinter fokussierbar: Paul kam mit dem Ring
            // nach oben und unten an die Reiter und Kacheln hinter dem Blatt.
            // Sichtbar verdeckt heisst auf dem Fernseher nicht unerreichbar —
            // der Fokusmotor sucht geometrisch und kennt keine Ebenen.
            rahmen
                .disabled(abspielen != nil || auswahlOffen)

            if auswahlOffen {
                TVUebernahmeauswahl(sitzungen: uebernahme.angebote,
                                  waehlen: { hierWeiterschauen($0) },
                                  abbrechen: { auswahlOffen = false })
                    .transition(.opacity)
                    .zIndex(3)
            }

            if let wunsch = abspielen {
                PlayerScreen(model: model, item: wunsch.item, plan: wunsch.plan,
                             startAt: wunsch.startAt) { abspielen = nil }
                .transition(.opacity)
            }
        }
        .environment(\.abspielwunsch, $abspielen)
        .environment(\.tafelOffen, $tafelOffen)
        .animation(.easeInOut(duration: 0.2), value: abspielen?.id)
        .animation(.easeInOut(duration: 0.2), value: auswahlOffen)
        .task { await model.fernsteuerungStarten() }
        // **Nur solange nichts läuft.** Im Player wäre die Abfrage sinnlos —
        // die Leiste ist weg, und der Server hätte alle zehn Sekunden eine
        // Anfrage mehr zu beantworten, während es aufs Bild ankommt.
        .task(id: abspielen == nil) {
            if abspielen == nil { uebernahme.starten(model) } else { uebernahme.beenden() }
        }
        .onDisappear { uebernahme.beenden() }
        #if DEBUG
        .task { await debugSprung() }
        #endif
        .onDisappear { Task { await model.fernsteuerungBeenden() } }
        .onChange(of: bereich) { _, neu in besucht.insert(neu) }
        .onOpenURL { adresse in
            guard adresse.scheme == "swiftly", adresse.host == "titel" else { return }
            let kennung = adresse.lastPathComponent
            guard !kennung.isEmpty else { return }
            Task {
                guard let titel = await model.item(id: kennung) else { return }
                bereich = .start
                besucht.insert(.start)
                pfade[Bereich.start.rawValue].append(titel)
            }
        }
    }

    /// Alles ausser dem Player: Bereiche, Kopfleiste, Fehlerhinweis.
    private var rahmen: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            ZStack {
                ForEach(Bereich.allCases) { b in
                    if besucht.contains(b) {
                        stapel(b)
                            .opacity(bereich == b ? 1 : 0)
                            .disabled(bereich != b)
                    }
                }
            }
            // Der seitliche Rand faellt in den Seiten selbst weg, nicht
            // hier: der `NavigationStack` in `stapel(b)` setzt den sicheren
            // Bereich fuer seinen Inhalt neu, und an dieser Stelle stuende
            // die Angabe wirkungslos da. Einmal ausprobiert und gemessen.
            // Reines Überblenden, ohne Weg.
            //
            // Die Fassung davor liess den neuen Bereich aufsteigen und den
            // alten absinken. Das war erfunden, nicht abgeschaut: die
            // Systemleiste auf tvOS blendet nur über. Zwei schwere Seiten,
            // die sich gleichzeitig gegeneinander verschieben, sehen aus wie
            // ein Fehler — genau das war zu sehen.
            //
            // Kopfleiste und Verlauf bleiben aussen vor; sie gehören zum
            // Rahmen, nicht zur Seite.
            .animation(Stil.seitenwechsel, value: bereich)

            // Zwischen Inhalt und Kopfleiste: der Verlauf soll den Inhalt
            // abdunkeln, aber nicht die Leiste selbst.
            //
            // **Auf der Startseite braucht es ihn nicht mehr.**
            //
            // Er stammt aus der Zeit, als die Reihen bis unter die Leiste
            // liefen. Heute beginnen sie erst bei 560 und werden beschnitten
            // — es kommt nichts mehr hinauf, was abgedunkelt werden muesste.
            // Uebrig blieb nur sein eigener Abfall, und der faellt auf einem
            // hellen Querbild als Kante auf.
            //
            // Auf den anderen Seiten scrollen die Kacheln weiter unter die
            // Leiste, dort bleibt er.
            //
            // **Nicht auf der Startseite, und dort inzwischen gar nicht.**
            //
            // Von hier aus laege er zwangslaeufig obenauf und faerbte den
            // Titel grau — deshalb war er hier schon immer ausgenommen. Die
            // Startseite hatte dafuer einen eigenen, weicheren unter ihrer
            // Schrift.
            //
            // Auch der ist weg: sie zeigt jetzt denselben gefaerbten Grund
            // wie eine Detailseite, und der Verlauf war das Letzte, was sie
            // anders aussehen liess. Paul: „es soll identisch aussehen."
            //
            // Auf den uebrigen Bereichen bleibt er — dort scrollen Kacheln
            // unter die Leiste, und ohne ihn stossen sie hell dagegen.
            if (leisteDa || anDerWurzel), bereich != .start {
                Kopfverlauf().zIndex(1).opacity(leisteDa ? 1 : 0)
            }

            if leisteDa || anDerWurzel {
                Kopfleiste(bereich: $bereich, model: model,
                           aufsProfil: {
                               pfade[bereich.rawValue].append(ProfilRoute())
                           },
                           uebernahme: uebernahme.angebot,
                           uebernehmen: { abzeichenGedrueckt() })
                // Ohne eigenen Abschnitt springt der Fokus aus dem Inhalt
                // nicht sauber in die Leiste, sondern sucht sich den
                // waagerecht nächsten Knopf.
                .focusSection()
                // tvOS hebt die fokussierte Ansicht über ihre Geschwister.
                // Die Leiste liegt zwar auch ohne das oben — aber verlassen
                // will ich mich darauf nicht.
                .zIndex(2)
                .opacity(leisteDa ? 1 : 0)
                // Ausgeblendet ist sie kein Ziel mehr: der Fokus soll nicht
                // in etwas springen, das gerade verschwindet. Und bei offener
                // Tafel ebenso wenig — siehe `tafelOffen`.
                .disabled(!leisteDa || tafelOffen)
            }
        }
        // Der Wechsel laeuft hier, in einer eigenen Transaktion — der Pfad
        // selbst wird bewusst ohne Animation gesetzt, siehe `stapel`.
        .onChange(of: anDerWurzel, initial: true) { _, jetzt in
            withAnimation(.easeInOut(duration: 0.26)) { leisteDa = jetzt }
        }
        // Serverfehler sichtbar machen. `AppModel` sammelt sie in
        // `errorMessage`; auf tvOS hat sie bisher niemand gelesen.
        .overlay(alignment: .top) {
            if let fehler = model.errorMessage {
                Hinweisstreifen(text: fehler) { model.errorMessage = nil }
                    .padding(.top, Stil.leisteUnten + 20)
                    .zIndex(3)
            }
        }
        // **Kein Fokus im Untergrund, solange gespielt wird.**
        //
        // `opacity` allein reicht auf tvOS nie: der Fokus wandert weiter in
        // Ansichten, die niemand sieht. Ohne das hier nahm die Kopfleiste ihn
        // an, die Richtungstasten kamen nie im Player an, und die
        // Menue-Taste fiel bis ans System durch — tvOS verstand sie als
        // „App verlassen". Dieselbe Regel wie bei den unsichtbaren Stapeln.
        //
        // **Menue fuehrt eine Stufe zurueck, nicht aus der App.**
        //
        // Ohne Behandlung faellt der Befehl am Wurzelpunkt eines Bereichs bis
        // ans System durch, und tvOS schliesst die App — auch aus „Suche"
        // heraus. Erwartet wird der Weg nach Start; erst von dort verlaesst
        // Menue die App. `nil` heisst: nicht anfassen, durchfallen lassen.
        //
        // Auf Unterseiten greift der Navigationsstapel zuerst, der ist naeher
        // am Fokus. Der Player ebenso — er hat seine eigene Behandlung.
        .onExitCommand(perform: zurueckAufStart)
        .animation(.easeInOut(duration: 0.2), value: model.errorMessage)
    }

    #if DEBUG
    /// Springt beim Start direkt auf eine Seite — nur zur Fehlersuche.
    ///
    /// Der Simulator nimmt von aussen keine Fernbedienung an: Bildschirmfotos
    /// gehen, Eingaben nicht. Ohne das hier lässt sich alles ausser der
    /// Startseite nie ansehen, ohne jemanden zu bitten, selbst zu klicken.
    ///
    ///     xcrun simctl launch <geraet> de.paulherter.swiftly -zeige serie
    ///     xcrun simctl launch <geraet> de.paulherter.swiftly -zeige film
    private func debugSprung() async {
        let argumente = ProcessInfo.processInfo.arguments
        if let j = argumente.firstIndex(of: "-bereich"), j + 1 < argumente.count {
            switch argumente[j + 1] {
            case "filme":  bereich = .filme
            case "serien": bereich = .serien
            case "suche":  bereich = .suche
            default:       break
            }
            besucht.insert(bereich)
        }
        guard let i = argumente.firstIndex(of: "-zeige"), i + 1 < argumente.count
        else { return }
        if model.views.isEmpty { await model.loadViews() }
        let art = argumente[i + 1] == "film" ? "movies" : "tvshows"
        guard let bib = model.views.first(where: { $0.collectionType == art }),
              let seite = await model.items(in: bib.id),
              let erstes = seite.titel.first
        else { return }
        pfade[bereich.rawValue].append(erstes)
    }
    #endif

    // Kein `@ViewBuilder`: die Funktion rechnet erst die Bindung aus und
    // gibt dann **eine** Ansicht zurueck. Mit Baumeister davor warnt Swift,
    // dass das ausdrueckliche `return` ihn ausser Kraft setzt — er hat hier
    // nichts zu tun.
    private func stapel(_ b: Bereich) -> some View {
        // **Kein Ueberblenden beim Seitenwechsel — an der Bindung.**
        //
        // Paul: beim Oeffnen eines Titels blendet alles um, Bild, Verlauf
        // und Texte, obwohl der halbe Schirm auf beiden Seiten derselbe ist.
        //
        // Es ist keine einzelne Ebene mehr — Kopfblock, Kulissenblende,
        // gefaerbter Grund und Kopfschatten sind inzwischen wirklich
        // dieselben. Es ist SwiftUIs eigener Uebergang: er blendet die neue
        // Seite ueber die alte, **und beide aendern dabei ihre Deckkraft**.
        // In der Mitte liegt keine von beiden voll auf, also sackt die
        // Helligkeit ab. Das sieht man auch bei deckungsgleichen Inhalten:
        // es blendet nicht zwischen zwei Bildern, es blendet beide gegen den
        // Grund.
        //
        // **Am Aufrufort war es zu weit aussen.** Ein `transaction` auf der
        // Ansicht, die den Stapel enthaelt, erreicht die Animation nicht, die
        // der Stapel intern fuer seinen Wechsel fuehrt. Die Bindung ist die
        // engste Stelle, durch die jeder Wechsel muss — die Kacheln mit ihren
        // `NavigationLink`, die Menue-Taste zurueck, die Tiefenverweise.
        // Wer sie setzt, setzt sie ohne Animation.
        let pfad = Binding<NavigationPath>(
            get: { pfade[b.rawValue] },
            set: { neu in
                // **Und zusaetzlich auf UIKit-Ebene.**
                //
                // Die SwiftUI-Transaktion allein reicht nicht: der
                // `NavigationStack` fuehrt seinen Wechsel auf tvOS ueber
                // einen UIKit-Navigationscontroller, und der sieht sie nicht.
                // Man erkennt es am Text — weisse Schrift wird waehrend des
                // Wechsels kurz **grau**, und das ist nichts anderes als
                // halbe Deckkraft ueber dunklem Grund. Genau das hat Paul
                // beschrieben, nachdem die Transaktion schon drin war.
                //
                // Fuer einen Durchlauf abgeschaltet und im naechsten wieder
                // an: laenger waere gefaehrlich, denn daran haengen auch die
                // Fokusbewegungen.
                UIView.setAnimationsEnabled(false)
                var ohne = Transaction()
                ohne.disablesAnimations = true
                withTransaction(ohne) { pfade[b.rawValue] = neu }
                DispatchQueue.main.async { UIView.setAnimationsEnabled(true) }
            }
        )
        return NavigationStack(path: pfad) {
            Group {
                switch b {
                case .start:
                    HomeView(model: model)
                case .filme:
                    BibliothekView(model: model, art: "movies")
                case .serien:
                    BibliothekView(model: model, art: "tvshows",
                                   filter: [.alle, .angefangen, .merkliste])
                case .suche:
                    SucheView(model: model, aktiv: bereich == .suche)
                }
            }
            .zielorte(model: model)
        }
    }
}

// MARK: - Gemeinsame Ziele

extension View {
    /// Die Sprungziele hängen am Stapel, nicht an der einzelnen Seite —
    /// sonst muss jeder Bereich sie einzeln kennen.
    func zielorte(model: AppModel) -> some View {
        self
            .navigationDestination(for: LibraryRoute.self) { route in
                BibliothekView(model: model, bibliothek: route.item)
            }
            // Dieselbe Weiche wie auf dem iPhone: eine Serie führt auf die
            // Serienseite, eine einzelne Folge auf die Staffel, in der sie
            // steht — eine eigene Seite nur für eine Folge trägt nichts, was
            // nicht in der Liste schon steht.
            .navigationDestination(for: Item.self) { item in
                if item.type == "Series" {
                    SerienView(model: model, serie: item)
                } else if item.type == "Episode" {
                    StaffelZiel(model: model, folge: item)
                } else {
                    DetailView(model: model, item: item)
                }
            }
            .navigationDestination(for: StaffelRoute.self) { route in
                SerienView(model: model, serie: route.serie,
                           startStaffelID: route.staffel.id)
            }
            .navigationDestination(for: ProfilRoute.self) { _ in
                ProfilView(model: model)
            }
    }
}


// MARK: - Umweg von einer Folge auf ihre Serie

/// Holt die Serie zur Folge nach und zeigt die Serienseite — mit der Staffel
/// der Folge schon ausgewählt.
///
/// Die Listeneinträge tragen nur `seriesId`, nicht die Serie selbst, deshalb
/// dieser Zwischenschritt. Gleiches Vorgehen wie auf dem iPhone.
struct StaffelZiel: View {
    let model: AppModel
    let folge: Item

    @State private var serie: Item?

    /// **Die Staffel frisch holen, nicht die der Kachel glauben.**
    ///
    /// Der Listeneintrag traegt die Staffel, die er beim Laden der Startseite
    /// hatte. Wer eine Staffel zu Ende sieht und die naechste dazulegt, hat
    /// dort weiter die alte stehen — die Seite oeffnete dann mit „Abspielen
    /// S6E1" oben und Staffel 5 in der Folgenliste. Dasselbe Muster wie bei
    /// der Fortsetzstelle in `HomeView.starte`, und dieselbe Abhilfe.
    @State private var frischeStaffelID: String?

    /// **Die Serie steht sofort, wenn sie schon einmal geholt wurde.**
    ///
    /// Sonst zeigte diese Ansicht bei jedem Oeffnen einer Folge zuerst einen
    /// Ring auf schwarzem Grund und tauschte ihn danach gegen die
    /// Serienseite. Solange der Seitenwechsel ueberblendete, lag das darunter
    /// — ohne ihn ist es das Erste, was man sieht. Paul: „jetzt ist immer
    /// kurz Blackscreen mit Ladebalken, bevor sich die Seite oeffnet."
    @MainActor init(model: AppModel, folge: Item) {
        self.model = model
        self.folge = folge
        _serie = State(initialValue:
            folge.seriesId.flatMap { Serienspeicher.geteilt.stand($0)?.serie }
            ?? StaffelZiel.vorlaeufig(zu: folge))
    }

    /// **Eine vorlaeufige Serie aus dem, was die Folge ohnehin traegt.**
    ///
    /// Paul: „das Bild ist doch schon auf der Startseite, was laedt der da?"
    /// Nicht das Bild — die **Serie**. Ein Listeneintrag einer Folge traegt
    /// nur `seriesId` und `seriesName`, und `SerienView` braucht ein `Item`.
    /// Dafuer lief ein Abruf beim Server, und der war die Wartezeit.
    ///
    /// Gebraucht wird davon beim Aufmachen fast nichts: `id` fuer alle
    /// weiteren Abrufe, `name` fuer die Ueberschrift, `type` fuer die
    /// Weichen. Das Kulissenbild ist ohnehin dasselbe — `querbildURL` baut es
    /// aus `seriesId ?? id`, fuer Folge und Serie also aus derselben Kennung,
    /// und es liegt schon entschluesselt bereit.
    ///
    /// Alles Weitere — Beschreibung, Bewertung, Staffelzahl — holt
    /// `SerienView.laden()` sich selbst nach und schreibt es ueber diesen
    /// Stand (`frisch ?? serie`). Der Umweg wartet also nur noch auf nichts.
    ///
    /// **Ueber JSON und nicht ueber einen Erzeuger**, weil `Item` keinen
    /// oeffentlichen hat: alle Felder sind `let`, den Erzeuger stellt
    /// `Codable`. Einen `Item(id:name:type:)` zu ergaenzen waere sauberer und
    /// gehoert ins Paket — und damit nach der Regel zuerst nach iOS. Gemeldet;
    /// bis dahin steht es hier, wo es niemanden sonst betrifft.
    @MainActor
    private static func vorlaeufig(zu folge: Item) -> Item? {
        guard let id = folge.seriesId, let name = folge.seriesName else { return nil }
        let felder: [String: String] = ["Id": id, "Name": name, "Type": "Series"]
        guard let daten = try? JSONSerialization.data(withJSONObject: felder) else { return nil }
        return try? JSONDecoder().decode(Item.self, from: daten)
    }

    var body: some View {
        ZStack {
            if let serie {
                // Die Folge, ueber die man hereinkam, ist zugleich die
                // Stelle, an der es weitergeht — siehe `SerienView.startFolge`.
                SerienView(model: model, serie: serie,
                           startStaffelID: frischeStaffelID ?? folge.seasonId,
                           startFolge: folge)
            } else {
                // **Kein undurchsichtiges Schwarz.** Beim ersten Mal ist die
                // Wartezeit echt — die Serie muss geholt werden —, aber sie
                // gehoert nicht schwarz unterlegt. Der gefaerbte Grund der
                // Folge steht schon bereit, also steht er auch hier, und der
                // Uebergang auf die Serienseite ist damit nur noch der
                // Inhalt, nicht der ganze Schirm.
                Lader.fern
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .bildgrund(url: model.querbildURL(for: folge, breite: 1600)
                                    ?? model.backdropURL(for: folge))
            }
        }
        .task {
            guard let id = folge.seriesId else { return }
            async let frisch = model.item(id: folge.id)
            if serie == nil { serie = await model.item(id: id) }
            frischeStaffelID = await frisch?.seasonId
        }
    }
}


