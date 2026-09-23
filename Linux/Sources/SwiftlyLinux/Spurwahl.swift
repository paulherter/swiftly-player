import CGtk
import Foundation
import JellyfinKit

/// **Welche Ton- und Untertitelspur läuft — entschieden über Jellyfins
/// Index, nicht über VLCs Spurnamen** (Audit 16.09., Stufe 4).
///
/// Die Regeln stehen im Paket: ``Spurregel`` (Handwahl je Serie → App-
/// Einstellungen → Server-Vorgaben → erzwungene Untertitel → aus),
/// ``Spurzuordnung`` (VLC-Spur ↔ `MediaStream`) und ``Spurgedaechtnis``.
/// Hier steht nur, wie libVLC 3 die Spuren herausgibt. Vorbild ist
/// `Sources/Shared/VLCPlayer.swift`, `wendeSprachenAn`.
///
/// **Der eine Unterschied zu Apple: libVLC 3 kennt nur Zahlen als
/// Spurkennung.** VLCKit 4 setzt vor die Spur einer nachgeladenen Datei den
/// MD5 ihrer Adresse (`<md5>/spu/0`), und daran erkennt ``Spurzuordnung``
/// sie. libVLC 3 tut das nicht. Deshalb werden die Dateien hier **einzeln**
/// angehängt, und die Spur, die danach neu in der Liste steht, bekommt den
/// Vorsatz von uns — dieselbe Kennung, dieselbe Zuordnung im Paket.
final class Spurlage {
    /// Serie oder Film, für den eine Handwahl gemerkt wird.
    var titel: String?
    var quelle: MediaSource?
    var dateien: [Untertiteldatei] = []
    /// VLC-Spurnummer → MD5 der Datei, aus der sie kam.
    var dateispuren: [Int32: String] = [:]
    /// Noch anzuhängen, in dieser Reihenfolge.
    var warteschlange: [Untertiteldatei] = []
    /// Die Datei, die gerade angehängt wurde, und was vorher schon da war.
    var unterwegs: (datei: Untertiteldatei, vorher: Set<Int32>, seit: Date)?
    /// Eine gewählte Untertiteldatei, deren Spur noch nicht da ist.
    var offenerUntertitel: Int?
    /// Was zuletzt als laufend gemeldet wurde — geht mit Start und Fortschritt hinaus.
    var gemeldet = Spurindizes()

    /// Ein neuer Titel oder eine neue Folge.
    func neu(titel: String?, quelle: MediaSource?, dateien: [Untertiteldatei]) {
        self.titel = titel
        self.quelle = quelle
        self.dateien = dateien
        gemeldet = Spurindizes()
        neuGeoeffnet()
    }

    /// Der Strom wurde neu aufgebaut: libVLC hat die angehängten Dateien vergessen.
    func neuGeoeffnet() {
        dateispuren = [:]
        warteschlange = []
        unterwegs = nil
        offenerUntertitel = nil
    }
}

extension App {

    /// **Eine eigene Ablage, und nach jedem Merken geschrieben.** Foundation
    /// schreibt `UserDefaults` hier erst beim geordneten Ende in
    /// `~/.config/<name>.plist`; ein beendeter Prozess vergass die Handwahl
    /// (am 17.09.2026 auf cachy gemessen: nach `pkill` keine Datei).
    nonisolated(unsafe) static let spurablage = UserDefaults(suiteName: "de.paulherter.swiftly") ?? .standard

    func spurgedaechtnis() -> Spurgedaechtnis { Spurgedaechtnis(ablage: Self.spurablage) }

    private func spurablageSichern() { _ = Self.spurablage.synchronize() }

    private func spurprotokoll(_ text: String) {
        Protokoll.schreib("[Spuren] \(text)")
        fflush(nil)
    }

    /// Vor jedem Öffnen eines Titels oder einer Folge.
    func spurlageNeu(_ item: Item, plan: PlaybackPlan?) {
        var dateien: [Untertiteldatei] = []
        if let plan, !plan.url.isFileURL, let adressen {
            dateien = Untertiteldatei.aus(stroeme: plan.quelle?.mediaStreams ?? [],
                                          server: adressen.basis, schluessel: adressen.token,
                                          merkmal: Self.untertitelmerkmal)
        }
        spurlage.neu(titel: Spurgedaechtnis.titel(fuer: item), quelle: plan?.quelle, dateien: dateien)
    }

    /// MD5 der Adresse, wie libVLC 4 ihn bildet — über GLib, das es auf
    /// Linux und Windows ohnehin gibt.
    static func untertitelmerkmal(_ adresse: URL) -> String? {
        guard let roh = g_compute_checksum_for_string(G_CHECKSUM_MD5, adresse.absoluteString, -1)
        else { return nil }
        defer { g_free(roh) }
        return String(cString: roh)
    }

    // MARK: Spuren, wie das Paket sie sieht

    private func kennung(_ nummer: Int32, art: String) -> String {
        if art == "spu", let merkmal = spurlage.dateispuren[nummer] { return "\(merkmal)/spu/\(nummer)" }
        return "\(art)/\(nummer)"
    }

    private func abspielerspuren(_ spuren: [Abspieler.Spur], art: String,
                                 angaben: [Int32: Abspieler.Spurangabe]) -> [Abspielerspur] {
        spuren.map { spur in
            let angabe = angaben[spur.kennung]
            return Abspielerspur(kennung: kennung(spur.kennung, art: art), name: spur.name,
                                 sprache: angabe?.sprache,
                                 codec: angabe.flatMap { Technikangaben.codecname(vlcKennung: $0.codec) },
                                 kanaele: angabe?.kanaele)
        }
    }

    /// Die Spuren beider Arten ohne VLCs „Disable", samt Zuordnung.
    private func spurstand() -> (ton: [Abspieler.Spur], untertitel: [Abspieler.Spur],
                                 zuordnung: Spurzuordnung, angaben: [Int32: Abspieler.Spurangabe]) {
        let ton = abspieler.tonspuren.filter { $0.kennung >= 0 }
        let ut = abspieler.untertitelspuren.filter { $0.kennung >= 0 }
        let angaben = abspieler.spurangaben()
        let z = Spurzuordnung.bilden(ton: abspielerspuren(ton, art: "audio", angaben: angaben),
                                     untertitel: abspielerspuren(ut, art: "spu", angaben: angaben),
                                     stroeme: spurlage.quelle?.mediaStreams ?? [],
                                     dateien: spurlage.dateien)
        return (ton, ut, z, angaben)
    }

    // MARK: Beim Start

    /// **Einmal je Titel, sobald VLC die Spuren kennt** (B8).
    func spurenVorwaehlen() {
        let lage = spurlage
        let stroeme = lage.quelle?.mediaStreams ?? []
        let (ton, ut, z, _) = spurstand()
        let gedaechtnis = spurgedaechtnis()

        var tonIndex = Spurregel.ton(stroeme: stroeme,
                                     gemerkt: lage.titel.flatMap { gedaechtnis.ton(fuer: $0) },
                                     wunschsprache: wahlen.tonSprache,
                                     serverVorgabe: lage.quelle?.defaultAudioStreamIndex)
        if let gesucht = tonIndex, let position = z.tonposition(index: gesucht) {
            abspieler.setzeTonspur(ton[position].kennung)
        } else {
            // Nichts zuzuordnen: wie bisher über den Namen, sonst die Datei.
            if !wahlen.tonSprache.isEmpty,
               let treffer = ton.first(where: { Sprache.passt($0.name, zu: wahlen.tonSprache) }) {
                abspieler.setzeTonspur(treffer.kennung)
            }
            let jetzt = abspieler.tonspur
            tonIndex = ton.firstIndex { $0.kennung == jetzt }.flatMap { z.ton[$0] }
        }

        let wahl = Spurregel.untertitel(stroeme: stroeme,
                                        gemerkt: lage.titel.flatMap { gedaechtnis.untertitel(fuer: $0) },
                                        serverVorgabe: lage.quelle?.defaultSubtitleStreamIndex,
                                        automatisch: wahlen.untertitelAutomatisch, tonindex: tonIndex,
                                        tonwunsch: wahlen.tonSprache, wunschsprache: wahlen.untertitelSprache)
        spurprotokoll("Ton \(tonIndex.map(String.init) ?? "Datei") · Untertitel \(wahl)"
            + " · Vorgaben \(lage.quelle?.defaultAudioStreamIndex.map(String.init) ?? "—")/"
            + "\(lage.quelle?.defaultSubtitleStreamIndex.map(String.init) ?? "—")"
            + " · Zuordnung Ton \(z.ton) Untertitel \(z.untertitel)"
            + " · Dateien \(lage.dateien.map(\.index))")
        untertitelSetzen(wahl, spuren: ut, zuordnung: z)
        spurindizesMelden(Spurindizes(ton: tonIndex, untertitel: untertitelindex(wahl)))
        // Erst jetzt: die eingebetteten Spuren stehen, jede neue ist eine Datei.
        lage.warteschlange = lage.dateien
        spurdateienNachfuehren()
    }

    private func untertitelindex(_ wahl: Spurregel.Untertitel) -> Int {
        if case .strom(let index) = wahl { return index }
        return -1
    }

    private func untertitelSetzen(_ wahl: Spurregel.Untertitel, spuren: [Abspieler.Spur],
                                  zuordnung z: Spurzuordnung) {
        spurlage.offenerUntertitel = nil
        guard case .strom(let index) = wahl else {
            // Aktiv abschalten: die Datei bringt oft eine eigene Vorauswahl mit.
            abspieler.setzeUntertitel(-1)
            return
        }
        if let position = z.untertitelposition(index: index) {
            abspieler.setzeUntertitel(spuren[position].kennung)
        } else {
            abspieler.setzeUntertitel(-1)
            if spurlage.dateien.contains(where: { $0.index == index }) {
                spurlage.offenerUntertitel = index
                spurprotokoll("Untertiteldatei \(index) noch nicht da, wartet")
            } else {
                spurprotokoll("Untertitel \(index) nicht zuzuordnen, bleibt aus")
            }
        }
    }

    private func spurindizesMelden(_ neu: Spurindizes) {
        guard neu != spurlage.gemeldet else { return }
        spurlage.gemeldet = neu
        spurprotokoll("gemeldet \(neu.ton.map(String.init) ?? "—")/\(neu.untertitel.map(String.init) ?? "—")")
    }

    // MARK: Externe Untertitel

    /// **Je Takt: die angehängte Datei wiederfinden, dann die nächste anhängen.**
    ///
    /// Eine nach der anderen, weil libVLC 3 nicht sagt, aus welcher Datei eine
    /// Spur kommt — nur, dass sie neu ist. Das Lesen der Liste kostet nur,
    /// solange eine Datei unterwegs ist.
    func spurdateienNachfuehren() {
        let lage = spurlage
        if let unterwegs = lage.unterwegs {
            let neue = abspieler.untertitelspuren.filter { $0.kennung >= 0 && !unterwegs.vorher.contains($0.kennung) }
            if let spur = neue.first, let merkmal = unterwegs.datei.merkmal {
                lage.dateispuren[spur.kennung] = merkmal
                lage.unterwegs = nil
                spurprotokoll("Datei \(unterwegs.datei.index) ist Spur \(spur.kennung), Merkmal \(merkmal)")
                wahlNachDateiHalten()
            } else if Date().timeIntervalSince(unterwegs.seit) > 15 {
                lage.unterwegs = nil
                spurprotokoll("Datei \(unterwegs.datei.index) nach 15 s ohne Spur, uebersprungen")
            } else {
                return
            }
        }
        guard lage.unterwegs == nil, !lage.warteschlange.isEmpty else { return }
        let datei = lage.warteschlange.removeFirst()
        let vorher = Set(abspieler.untertitelspuren.map(\.kennung))
        let gehaengt = abspieler.untertiteldateiAnhaengen(datei.adresse)
        spurprotokoll("Datei \(datei.index) angehängt \(gehaengt), Merkmal \(datei.merkmal ?? "—")")
        if gehaengt { lage.unterwegs = (datei, vorher, Date()) }
    }

    /// Nach einer neuen Datei: die gewählte offene Datei einschalten, sonst
    /// halten, was gewählt war — eine neue Spur darf die Wahl nicht verschieben.
    private func wahlNachDateiHalten() {
        let (_, ut, z, _) = spurstand()
        if let index = spurlage.offenerUntertitel, let position = z.untertitelposition(index: index) {
            spurlage.offenerUntertitel = nil
            abspieler.setzeUntertitel(ut[position].kennung)
            spurprotokoll("Untertiteldatei \(index) nachgereicht")
            spurindizesMelden(Spurindizes(ton: spurlage.gemeldet.ton, untertitel: index))
            return
        }
        guard let soll = spurlage.gemeldet.untertitel else { return }
        let kennung = soll < 0 ? -1 : z.untertitelposition(index: soll).map { ut[$0].kennung }
        if let kennung, abspieler.untertitelspur != kennung { abspieler.setzeUntertitel(kennung) }
    }

    // MARK: Von Hand

    /// Eine Tonspur aus der Tafel — gilt für die ganze Serie (T1-M1).
    func tonspurGewaehlt(_ kennung: Int32) {
        abspieler.setzeTonspur(kennung)
        let (ton, _, z, angaben) = spurstand()
        guard let position = ton.firstIndex(where: { $0.kennung == kennung }) else { return }
        let index = z.ton[position]
        if let titel = spurlage.titel {
            let stroeme = spurlage.quelle?.mediaStreams ?? []
            let spur = abspielerspuren([ton[position]], art: "audio", angaben: angaben)[0]
            let abdruck = index.flatMap { i in stroeme.first { $0.type == "Audio" && $0.index == i } }
                .map { Spurabdruck(strom: $0, in: stroeme, name: spur.name) }
                ?? Spurabdruck(spur: spur)
            spurgedaechtnis().merkeTon(abdruck, fuer: titel)
            spurablageSichern()
            spurprotokoll("Ton von Hand: \(index.map(String.init) ?? "?") \(abdruck)")
        }
        spurindizesMelden(Spurindizes(ton: index, untertitel: spurlage.gemeldet.untertitel))
    }

    /// Ein Untertitel aus der Tafel, `nil` heißt aus — auch das gilt für die Serie.
    func untertitelGewaehlt(_ kennung: Int32?) {
        spurlage.offenerUntertitel = nil
        guard let kennung else {
            if let titel = spurlage.titel {
                spurgedaechtnis().merkeUntertitel(.aus, fuer: titel)
                spurablageSichern()
            }
            abspieler.setzeUntertitel(-1)
            spurprotokoll("Untertitel von Hand: aus")
            spurindizesMelden(Spurindizes(ton: spurlage.gemeldet.ton, untertitel: -1))
            return
        }
        abspieler.setzeUntertitel(kennung)
        let (_, ut, z, angaben) = spurstand()
        guard let position = ut.firstIndex(where: { $0.kennung == kennung }) else { return }
        let index = z.untertitel[position]
        if let titel = spurlage.titel {
            let stroeme = spurlage.quelle?.mediaStreams ?? []
            let spur = abspielerspuren([ut[position]], art: "spu", angaben: angaben)[0]
            let abdruck = index.flatMap { i in stroeme.first { $0.type == "Subtitle" && $0.index == i } }
                .map { Spurabdruck(strom: $0, in: stroeme, name: spur.name) }
                ?? Spurabdruck(spur: spur)
            spurgedaechtnis().merkeUntertitel(.spur(abdruck), fuer: titel)
            spurablageSichern()
            spurprotokoll("Untertitel von Hand: \(index.map(String.init) ?? "?") \(abdruck)")
        }
        spurindizesMelden(Spurindizes(ton: spurlage.gemeldet.ton, untertitel: index))
    }

    // MARK: Namen in der Tafel

    /// **„Deutsch · AAC · 5.1" statt VLCs „Track 2 - [German]"** — dieselbe
    /// Schreibweise wie das Technikschild (`b1b5f82`, `huebscherName`).
    func tonspurnamen() -> [(kennung: Int32, name: String)] {
        let ton = abspieler.tonspuren.filter { $0.kennung >= 0 }
        let angaben = abspieler.spurangaben()
        return ton.map { spur in
            let a = angaben[spur.kennung]
            let name = Technikangaben.tonspurname(
                sprache: a?.sprache,
                codec: a.flatMap { Technikangaben.codecname(vlcKennung: $0.codec) },
                kanaele: a?.kanaele) ?? spur.name
            return (spur.kennung, name)
        }
    }

    /// Gleich heißende und nachgeladene Untertitel bekommen Sprache, Format,
    /// „Erzwungen" und „Datei" — sonst sind sie in der Liste nicht zu
    /// unterscheiden (Apple: `untertitelnamen()`).
    func untertitelnamen() -> [(kennung: Int32, name: String)] {
        let (_, ut, z, _) = spurstand()
        let stroeme = spurlage.quelle?.mediaStreams ?? []
        return ut.enumerated().map { position, spur in
            let doppelt = ut.filter { $0.name == spur.name }.count > 1
            guard let index = z.untertitel[position],
                  let strom = stroeme.first(where: { $0.type == "Subtitle" && $0.index == index }),
                  doppelt || strom.isExternal == true else {
                return (spur.kennung, spur.name)
            }
            let teile: [String?] = [
                Technikangaben.sprache(strom.language) ?? spur.name,
                Technikangaben.codecname(strom.codec),
                strom.isForced == true ? uebersetzt("Erzwungen") : nil,
                strom.isExternal == true ? uebersetzt("Datei") : nil,
            ]
            return (spur.kennung, teile.compactMap { $0 }.joined(separator: " · "))
        }
    }
}
