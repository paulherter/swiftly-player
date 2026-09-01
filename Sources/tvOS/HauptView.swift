import JellyfinKit
import SwiftUI

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

extension EnvironmentValues {
    var abspielwunsch: Binding<Abspielwunsch?> {
        get { self[AbspielSchluessel.self] }
        set { self[AbspielSchluessel.self] = newValue }
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
            rahmen
                .disabled(abspielen != nil)

            if let wunsch = abspielen {
                PlayerScreen(model: model, item: wunsch.item, plan: wunsch.plan,
                             startAt: wunsch.startAt) { abspielen = nil }
                .transition(.opacity)
            }
        }
        .environment(\.abspielwunsch, $abspielen)
        .animation(.easeInOut(duration: 0.2), value: abspielen?.id)
        .task { await model.fernsteuerungStarten() }
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
            // **Nicht auf der Startseite.**
            //
            // Dort gehoert er unter die Schrift, nicht darueber: der Entwurf
            // setzt den Textblock ausdruecklich mit `z-index: 1` ueber den
            // Verlauf. Von hier aus liegt er zwangslaeufig obenauf und hat
            // den Titel grau eingefaerbt. Die Startseite bringt ihren
            // eigenen mit, siehe `HomeView.deckel`.
            if anDerWurzel, bereich != .start {
                Kopfverlauf().zIndex(1)
            }

            if anDerWurzel {
                Kopfleiste(bereich: $bereich, model: model) {
                    pfade[bereich.rawValue].append(ProfilRoute())
                }
                // Ohne eigenen Abschnitt springt der Fokus aus dem Inhalt
                // nicht sauber in die Leiste, sondern sucht sich den
                // waagerecht nächsten Knopf.
                .focusSection()
                // tvOS hebt die fokussierte Ansicht über ihre Geschwister.
                // Die Leiste liegt zwar auch ohne das oben — aber verlassen
                // will ich mich darauf nicht.
                .zIndex(2)
            }
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

    @ViewBuilder
    private func stapel(_ b: Bereich) -> some View {
        NavigationStack(path: $pfade[b.rawValue]) {
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

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()
            if let serie {
                SerienView(model: model, serie: serie, startStaffelID: folge.seasonId)
            } else {
                Lader()
            }
        }
        .task {
            guard serie == nil, let id = folge.seriesId else { return }
            serie = await model.item(id: id)
        }
    }
}


