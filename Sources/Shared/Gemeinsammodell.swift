import Foundation
import JellyfinKit
import Observation
import SwiftUI

/// Was der Player für „Gemeinsam schauen" hergibt.
///
/// **Ein Objekt, das der Player im Takt nachführt — keine Rückrufe, die ihn
/// festhalten.** Ein Abschluss, der eine SwiftUI-Ansicht fängt, liest ihren
/// Stand von damals (siehe `zentraleUebernehmen` im Player). Hier schreibt
/// der Player Fläche, Titel und „bereit" in jedem Takt neu hinein, und die
/// Gruppe liest immer den jetzigen Stand.
@MainActor
final class Gemeinsamspieler: SyncPlaySpieler {
    weak var flaeche: VLCPlayerView?
    /// Welcher Titel gerade läuft.
    var titelID = ""
    /// Steht das Bild, und wird gerade kein Titel gewechselt?
    var istBereit = false
    /// Zieht Zeitleiste und Knopf nach einem Sprung sofort nach.
    var sprungZeigen: (Double) -> Void = { _ in }
    /// Die Gruppe schaut etwas anderes: im offenen Player wechseln.
    var titelWechseln: (Item, PlaybackPlan, Double) -> Void = { _, _, _ in }

    func titel() -> String { titelID }
    func bereit() -> Bool { istBereit }
    func stelle() -> Double { flaeche?.positionSeconds ?? 0 }
    func weiter() { flaeche?.resume() }
    func anhalten() { flaeche?.pause() }
    func springen(_ ziel: Double) {
        flaeche?.seek(toSeconds: ziel)
        sprungZeigen(ziel)
    }
}

/// **Gemeinsam schauen — der Spiegel für SwiftUI (iPhone, iPad, Mac, Fernseher).**
///
/// Der Ablauf steht im Paket (``SyncPlaySitzung``), gemeinsam mit Mac,
/// Fernseher, Android, Linux und Windows. Hier liegt nur, was an der App
/// hängt: der Spiegel der ``SyncPlayLage`` für SwiftUI, die Blätter, das
/// Laden eines Titels in den Player, und die Zeichen zu den Hinweisen.
///
/// **Einer für die ganze App.** Die Detailseite legt die Gruppe an, der Kopf
/// bietet sie an, der Player führt sie aus — und der Player hängt auf dem
/// iPhone in einem eigenen UIKit-Rahmen, bis zu dem die Umgebung nicht
/// reicht.
@MainActor
@Observable
final class Gemeinsammodell {

    static let geteilt = Gemeinsammodell()

    // MARK: Was die Oberfläche liest

    /// Der letzte Stand aus dem Paket.
    private(set) var lage = SyncPlayLage()

    var recht: SyncPlayRecht? { lage.recht }
    var darfAnlegen: Bool { lage.darfAnlegen }
    var darfBeitreten: Bool { lage.darfBeitreten }
    /// Gruppen auf dem Server, in denen man nicht selbst ist.
    var angebote: [SyncPlayGruppe] { lage.angebote }
    /// Die Gruppe, in der man ist.
    var gruppe: SyncPlayGruppe? { lage.gruppe }
    var zustand: SyncPlayGruppe.Zustand? { lage.zustand }
    /// Für den Streifen „Filmabend verlassen · Wieder beitreten".
    var zuletztVerlassen: SyncPlayGruppe? { lage.zuletztVerlassen }
    var arbeitet: Bool { lage.arbeitet }

    /// Kurz oben im Player: wer kam, wer ging, warum der Film steht.
    struct Ereignis: Equatable, Identifiable {
        let id: UUID
        let symbol: String
        let text: String
    }
    var ereignis: Ereignis? {
        lage.ereignis.map { Ereignis(id: $0.id, symbol: Self.zeichen($0.art), text: $0.text) }
    }

    private static func zeichen(_ art: SyncPlayEreignis.Art) -> String {
        switch art {
        case .dabei: "person.2.fill"
        case .gegangen: "person.2"
        case .wartetAufAlle: "hourglass"
        case .angehalten: "pause.fill"
        case .gehtWeiter: "play.fill"
        case .gesprungen: "arrow.left.and.right"
        case .keinZugriff, .nichtAbspielbar: "exclamationmark.triangle"
        }
    }

    /// Das Blatt „Gemeinsam schauen" für diesen Titel ist offen.
    var anlegenFuer: Item?
    /// Das Blatt zum Beitreten, oder die Auswahl mit „Hier weiterschauen".
    enum Blatt: Equatable { case beitreten(SyncPlayGruppe), auswahl }
    var blatt: Blatt?

    /// Was der Player starten soll — holt ``HauptView`` ab.
    var wunsch: Abspielwunsch?

    /// Für eine Meldung in der Ansicht.
    var fehler: String?

    /// „mit Paul und Tom" — ohne einen selbst.
    var mitWem: String {
        guard let gruppe else { return "" }
        let andere = gruppe.andere(als: ich)
        guard !andere.isEmpty else { return String(localized: "noch niemand dabei") }
        let liste = ListFormatter.localizedString(byJoining: andere)
        return String(localized: "mit \(liste)")
    }

    // MARK: Innen

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var takt: Task<Void, Never>?
    @ObservationIgnored private var zuhoeren: Task<Void, Never>?
    @ObservationIgnored private(set) var spieler: Gemeinsamspieler?

    /// Der Ablauf. Einer für die Laufzeit der App; er fragt bei jedem Schritt
    /// nach dem Client, der gerade gilt.
    @ObservationIgnored private lazy var sitzung: SyncPlaySitzung = {
        let sitzung = SyncPlaySitzung(
            client: { @MainActor [weak self] in self?.model?.client },
            ich: { @MainActor [weak self] in self?.ich },
            titelLaden: { @MainActor [weak self] titel, ab in
                await self?.titelLaden(titel, ab: ab) ?? false
            })
        zuhoeren = Task { @MainActor [weak self] in
            for await m in sitzung.mitteilungen {
                guard let self else { return }
                switch m {
                case let .lage(neu): self.lage = neu
                case let .fehler(f):
                    // **Nicht in `model.errorMessage`** — das zeigt nur die
                    // Anmeldung, in der Hauptansicht las es niemand. Die
                    // Meldung steht als `Hinweisstreifen`, wo man gerade ist.
                    self.fehler = f.text
                }
            }
        }
        return sitzung
    }()

    private var ich: String? { model?.session?.userName }

    /// Was die Gruppe gerade schaut.
    var schlangeTitel: String? { lage.schlangeTitel }

    /// Läuft der Player gerade in der Gruppe?
    var imPlayer: Bool { gruppe != nil && spieler != nil }

    // MARK: Anfang und Ende

    func starten(_ model: AppModel) {
        self.model = model
        let sitzung = self.sitzung
        model.syncPlayNachricht = { sitzung.annehmen($0) }
        guard takt == nil else { return }
        takt = Task {
            await sitzung.rechtHolen()
            while !Task.isCancelled {
                if !Spielstand.spielerLaeuft { await sitzung.angeboteFragen() }
                try? await Task.sleep(for: .seconds(Uebernahmemodell.taktsekunden))
            }
        }
    }

    /// **Das Konto hat gewechselt** (auch Abmelden, auch die erste
    /// Anmeldung) — ruft `AppModel.client` bei jeder Änderung. Die Gruppe des
    /// alten Kontos wird mit dessen Client verlassen, alles andere vergessen,
    /// und das Recht des neuen geholt. Die Abfrage läuft weiter; sie fragt
    /// ohnehin jedes Mal nach dem Client, der gerade gilt.
    func kontoGewechselt(alt: JellyfinClient?) {
        anlegenFuer = nil
        blatt = nil
        fehler = nil
        wunsch = nil
        guard model != nil else { return }
        let sitzung = self.sitzung
        Task {
            await sitzung.beenden(alterClient: alt)
            await sitzung.rechtHolen()
        }
    }

    /// Beim Abmelden und Kontowechsel: raus aus der Gruppe, alles vergessen.
    func beenden() {
        takt?.cancel(); takt = nil
        model?.syncPlayNachricht = nil
        let sitzung = self.sitzung
        Task { await sitzung.beenden() }
    }

    // MARK: Anlegen, beitreten, verlassen

    /// Gruppe öffnen und gleich den Titel setzen. Alle, auch man selbst,
    /// bekommen daraufhin die Warteschlange und öffnen den Player angehalten.
    func anlegen(name: String, titel: Item) async {
        await sitzung.anlegen(name: name, titel: titel.id, angenommen: { @MainActor [weak self] in
            self?.anlegenFuer = nil
        })
    }

    func beitreten(_ ziel: SyncPlayGruppe) async {
        await sitzung.beitreten(ziel, angenommen: { @MainActor [weak self] in
            self?.blatt = nil
        })
    }

    func wiederBeitreten() {
        let sitzung = self.sitzung
        Task { await sitzung.wiederBeitreten() }
    }

    /// Die Gruppe setzt einen Titel: im offenen Player wechseln, sonst den
    /// Player öffnen. Derselbe Titel im offenen Player kommt hier nicht an —
    /// dahin springt die Sitzung selbst.
    private func titelLaden(_ titelID: String, ab: Double) async -> Bool {
        guard let model else { return false }
        async let titelAbruf = model.item(id: titelID)
        async let planAbruf = model.plan(for: titelID)
        guard let titel = await titelAbruf, let plan = await planAbruf else { return false }
        if let spieler {
            // Bis der Player im nächsten Takt nachträgt, gilt der alte Titel
            // als nicht bereit — sonst ginge „bereit" hinaus, bevor der neue
            // überhaupt lädt.
            spieler.istBereit = false
            spieler.titelWechseln(titel, plan, ab)
        } else {
            wunsch = Abspielwunsch(item: titel, plan: plan, startAt: ab)
        }
        return true
    }

    // MARK: Aus dem Player

    /// Der Player ist offen und gehört zur Gruppe.
    func anschliessen(_ s: Gemeinsamspieler) {
        spieler = s
        let sitzung = self.sitzung
        Task { await sitzung.anschliessen(s) }
    }

    /// Der Player geht zu. **Das ist das Verlassen** (Entwurf A).
    func abtrennen() {
        spieler = nil
        let sitzung = self.sitzung
        Task { await sitzung.abtrennen() }
    }

    /// Anhalten und Weiter gehen als Bitte an den Server. Der Knopf springt
    /// erst um, wenn der Befehl zurückkommt — dann bei allen gleichzeitig.
    func bitteUmschalten(laeuftGerade: Bool) {
        let sitzung = self.sitzung
        Task { await sitzung.bitteUmschalten(laeuftGerade: laeuftGerade) }
    }

    func bitteSpringen(auf sekunden: Double) {
        let sitzung = self.sitzung
        Task { await sitzung.bitteSpringen(auf: sekunden) }
    }

    /// Folgenwahl im Player, in der Gruppe: für alle.
    func bitteTitel(_ titelID: String, ab sekunden: Double = 0) {
        let sitzung = self.sitzung
        Task { await sitzung.bitteTitel(titelID, ab: sekunden) }
    }

    /// Einmal je Takt des Players: Puffern melden.
    func spielertakt() {
        let sitzung = self.sitzung
        Task { await sitzung.spielertakt() }
    }
}

extension Gemeinsammodell {
    /// Gehört dieser Titel zu dem, was die Gruppe schaut?
    func gehoertZurGruppe(_ titelID: String) -> Bool {
        lage.gehoertZurGruppe(titelID)
    }
}

// MARK: - Was die Blätter sagen

/// **Einmal für alle Plattformen.** Die Blätter sehen auf Telefon, Mac und
/// Fernseher verschieden aus; was darin steht, ist dasselbe. Lag zuerst in
/// den iOS-Ansichten und wäre mit dem Fernseher zum zweiten Mal entstanden.
extension Gemeinsammodell {
    /// Bei einer Folge die Serie mit Staffel und Folge — sonst weiß man im
    /// Blatt nicht, welche Folge die Gruppe schauen wird.
    static func titelzeile(_ titel: Item) -> String {
        guard titel.type == "Episode", let serie = titel.seriesName, !serie.isEmpty else {
            return titel.name
        }
        if let staffel = titel.parentIndexNumber, let folge = titel.indexNumber {
            return "\(serie) · " + String(localized: "Staffel \(staffel) · Folge \(folge)")
        }
        return "\(serie) · \(titel.name)"
    }

    /// „Paul und Tom schauen gerade".
    static func wer(_ g: SyncPlayGruppe) -> String {
        var gesehen = Set<String>()
        let namen = g.teilnehmer.filter { gesehen.insert($0).inserted }
        guard !namen.isEmpty else { return String(localized: "Noch niemand dabei") }
        let liste = ListFormatter.localizedString(byJoining: namen)
        return namen.count == 1 ? String(localized: "\(liste) schaut gerade")
                                : String(localized: "\(liste) schauen gerade")
    }

    static func zustandText(_ z: SyncPlayGruppe.Zustand?) -> LocalizedStringKey? {
        switch z {
        case .laeuft: "Läuft gerade"
        case .angehalten: "Angehalten"
        case .wartet: "Wartet auf alle"
        case .leer, nil: nil
        }
    }
}
