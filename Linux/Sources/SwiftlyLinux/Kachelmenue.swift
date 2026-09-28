import CGtk
import Foundation
import JellyfinKit

/// Was das Menü einer Kachel wissen muss — der Titel, ob sie quer steht, das
/// Bild, das sie schon zeigt, und ob sie in „Weiterschauen" liegt.
struct Kachelmenueangabe {
    let item: Item
    var quer = false
    /// Dieselbe Adresse und Kante wie die Kachel: der Bildspeicher antwortet
    /// sofort, die Vorschau geht nie leer auf.
    var bild: URL?
    var kante: Int?
    var weiterschauen = false
    /// „Zur Übersicht" — nur bei „Weiterschauen", wo ein Klick startet.
    var uebersicht: (() -> Void)?
    /// **Im Player: nur der Sehstand.** Ohne „Abspielen" und „Gemeinsam
    /// schauen" — die Zeile selbst startet die Folge schon, und beides müsste
    /// den laufenden Player ersetzen. Ohne „Laden": die Tafel ginge unter dem
    /// Player auf. Dieselbe Regel wie auf Apple (`Kachelmenue.imPlayer`).
    var imPlayer = false
    /// Nach einer Änderung am Sehstand, mit dem frisch geholten Titel —
    /// damit die Seite nachzieht (Apple `nachher`).
    var nachher: ((Item) -> Void)?
}

/// **Rechtsklick auf jede Film-, Serien- und Folgenkachel: ein Menü mit
/// Vorschau** — die Zeigerform des langen Drucks am iPhone
/// (`Sources/Shared/Kachelmenue.swift`, 1.0.5). Oben die Vorschau in der
/// Form der Kachel (2:3, bei „Weiterschauen" 16:9), nur größer, darunter:
/// Abspielen oder Fortsetzen, bei „Weiterschauen" „Zur Übersicht", gesehen
/// und ungesehen (beide immer, wie am iPhone: eine Folge, durch die man nur
/// gesprungen ist, gilt als angefangen), Laden, Gemeinsam schauen, bei
/// „Weiterschauen" „Aus Weiterschauen entfernen".
///
/// **Rechtsklick statt Langdruck** (VERHALTEN F, Eingabeart): die Maus hat
/// eine eigene Taste dafür; dazu die Menütaste und Umschalt+F10 für die
/// Tastatur. Hier stand vorher nur „Übersicht öffnen", und nur auf der
/// Querkachel.
extension App {

    static func kachelmenueTraegt(_ item: Item) -> Bool {
        ["Movie", "Series", "Episode"].contains(item.type ?? "")
    }

    func kachelmenueAnlegen(_ knopf: Widget!, _ angabe: Kachelmenueangabe) {
        kachelmenueAnlegen(knopf) { angabe }
    }

    /// **Mit einer Angabe, die erst beim Öffnen gefragt wird** — für Zeilen,
    /// deren Titel sich nach dem Player nachzieht (``folgenzeile``). Rechtsklick,
    /// langer Druck, Menütaste.
    func kachelmenueAnlegen(_ knopf: Widget!, angabe: @escaping () -> Kachelmenueangabe) {
        guard Self.kachelmenueTraegt(angabe().item) else { return }
        beiRechtsklick(knopf) { [weak self] in self?.kachelmenueZeigen(knopf, angabe()) }
        beiLangdruck(knopf) { [weak self] in self?.kachelmenueZeigen(knopf, angabe()) }
        let horcher = gtk_event_controller_key_new()
        let auftrag = Unmanaged.passRetained(Auftrag { [weak self] in
            self?.kachelmenueZeigen(knopf, angabe())
        }).toOpaque()
        g_signal_connect_data(UnsafeMutableRawPointer(horcher), "key-pressed",
                              unsafeBitCast(menuetaste, to: GCallback.self),
                              auftrag, auftragFreigebenOeffentlich, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(knopf, horcher)
    }

    func kachelmenueZeigen(_ knopf: Widget!, _ angabe: Kachelmenueangabe) {
        let item = angabe.item
        let breite = angabe.quer ? 320 : 220
        let hoehe = angabe.quer ? breite * 9 / 16 : breite * 3 / 2
        let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_size_request(liste, Int32(breite), -1)
        let tafel = tafelOeffnen(an: knopf)
        gtk_widget_add_css_class(tafel, "swiftly-kachelmenue")
        gtk_popover_set_child(alsTafel(tafel), liste)

        // Die Vorschau: Bild ohne Rand, darunter Titel und Zeile.
        let (huelle, bild) = gerahmtesBild(breite: breite, hoehe: hoehe, stil: "swiftly-kachelvorschau")
        if let adresse = angabe.bild {
            bildLaden(bild, url: adresse, schluessel: Bildschluessel.fuer(adresse), sofort: true,
                      kante: angabe.kante, ersatzSerie: item.seriesId != nil || item.type == "Series")
        } else {
            zeichenLegen(huelle, serie: item.seriesId != nil || item.type == "Series")
        }
        anhaengen(liste, huelle)
        let text = stapel(GTK_ORIENTATION_VERTICAL, abstand: 3)
        gtk_widget_add_css_class(text, "swiftly-kachelvorschautext")
        let titel = beschriftung(item.seriesName ?? item.name, stil: "swiftly-kachelvorschautitel")
        gtk_label_set_xalign(OpaquePointer(titel), 0)
        gtk_label_set_ellipsize(OpaquePointer(titel), PANGO_ELLIPSIZE_END)
        anhaengen(text, titel)
        let zeile = Self.vorschauzeile(item)
        if !zeile.isEmpty {
            let z = beschriftung(zeile, stil: "swiftly-kachelvorschauzeile", umbruch: true)
            gtk_label_set_xalign(OpaquePointer(z), 0)
            gtk_label_set_lines(OpaquePointer(z), 2)
            gtk_label_set_ellipsize(OpaquePointer(z), PANGO_ELLIPSIZE_END)
            anhaengen(text, z)
        }
        anhaengen(liste, text)
        let linie = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
        gtk_widget_add_css_class(linie, "swiftly-trennlinie")
        anhaengen(liste, linie)

        func eintrag(_ symbol: String, _ wort: String, _ tun: @escaping () -> Void) {
            anhaengen(liste, handlungszeile(symbol, wort) {
                gtk_popover_popdown(alsTafel(tafel))
                tun()
            })
        }
        let serie = item.type == "Series"
        let imPlayer = angabe.imPlayer
        if !imPlayer {
            eintrag("media-playback-start-symbolic",
                    !serie && item.fortsetzenAb != nil ? uebersetzt("Fortsetzen") : uebersetzt("Abspielen")) {
                [weak self] in self?.kachelAbspielen(item)
            }
        }
        if angabe.weiterschauen, let uebersicht = angabe.uebersicht {
            eintrag("dialog-information-symbolic", uebersetzt("Zur Übersicht"), uebersicht)
        }
        let nachher = angabe.nachher
        eintrag("object-select-symbolic", uebersetzt("Als gesehen markieren")) { [weak self] in
            self?.kachelGesehen(item, an: true, nachher: nachher)
        }
        eintrag("edit-undo-symbolic", uebersetzt("Als ungesehen markieren")) { [weak self] in
            self?.kachelGesehen(item, an: false, nachher: nachher)
        }
        if !serie, !imPlayer, downloadKnopfZeigen, downloads.posten(fuer: item.id) == nil {
            eintrag("folder-download-symbolic", uebersetzt("Laden")) { [weak self] in
                self?.kachelLaden(item, an: knopf)
            }
        }
        if !serie, !imPlayer, gemeinsam.lage.darfAnlegen {
            eintrag("system-users-symbolic", uebersetzt("Gemeinsam schauen")) { [weak self] in
                self?.gemeinsamAnlegenZeigen(item, an: knopf)
            }
        }
        if angabe.weiterschauen {
            eintrag("list-remove-symbolic", uebersetzt("Aus Weiterschauen entfernen")) { [weak self] in
                self?.ausWeiterschauenNehmen(item)
            }
        }
        Protokoll.schreib("[Kachelmenü] \(item.id) · Vorschau \(breite)×\(hoehe) · Bild im Speicher: "
            + (angabe.bild.map { Bildspeicher.holen(Bildschluessel.fuer($0) + (angabe.kante.map { "@\($0)" } ?? "")) != nil } == true ? "ja" : "nein"))
        gtk_popover_popup(alsTafel(tafel))
    }

    /// Die Zeile unter dem Titel — bei einer Folge Kürzel, Name und Laufzeit
    /// (iOS `Kachelvorschau.zeile`).
    static func vorschauzeile(_ item: Item) -> String {
        if item.type == "Episode" {
            var teile: [String] = []
            if let kuerzel = item.folgenkuerzel { teile.append(kuerzel) }
            teile.append(item.name)
            if let s = item.runtimeSeconds, s > 0 { teile.append(laufzeit(s)) }
            return teile.joined(separator: " · ")
        }
        return item.nebenzeile
    }

    /// Abspielen — bei einer Serie dort, wo der Server steht
    /// (`standInSerie`, wie der Hauptknopf der Serienseite).
    private func kachelAbspielen(_ item: Item) {
        guard item.type == "Series" else { starte(item); return }
        guard let client else { return }
        Task.detached { [self] in
            let folge = await client.standInSerie(item.id)
            aufHauptfaden {
                guard let folge else {
                    self.kachelmeldung(uebersetzt("Danach kommt nichts mehr."))
                    return
                }
                self.starte(folge)
            }
        }
    }

    private func kachelGesehen(_ item: Item, an: Bool, nachher: ((Item) -> Void)? = nil) {
        guard let client else { return }
        // Der Rückruf hält Widgets und lebt auf GTKs Faden; über die
        // Fadengrenze geht er nur in der Kiste und wird drüben nicht gerufen.
        let nachher = nachher.map(Kachelnachher.init)
        Task.detached { [self] in
            do {
                try await client.setzeGesehen(itemID: item.id, an: an)
                // Mit Seite: den Titel frisch holen, damit Haken und Balken
                // dort nachziehen, wo das Menü aufging.
                let frisch: Item?
                if nachher != nil { frisch = try? await client.item(id: item.id) } else { frisch = nil }
                aufHauptfaden {
                    self.sehstandVergessen(item)
                    self.startseiteLaden()
                    if let frisch { nachher?.tun(frisch) }
                }
            } catch {
                let text = lesbarerFehler(error)
                aufHauptfaden { self.kachelmeldung(text) }
            }
        }
    }

    /// **Aus „Weiterschauen" nehmen** — die Stelle auf null
    /// (``JellyfinClient/stelleZuruecksetzen(itemID:)``); gesehen bleibt, wie
    /// es war.
    private func ausWeiterschauenNehmen(_ item: Item) {
        guard let client else { return }
        Task.detached { [self] in
            do {
                try await client.stelleZuruecksetzen(itemID: item.id)
                aufHauptfaden {
                    self.sehstandVergessen(item)
                    self.startseiteLaden()
                }
            } catch {
                let text = lesbarerFehler(error)
                aufHauptfaden { self.kachelmeldung(text) }
            }
        }
    }

    /// Laden: den vollen Titel holen (die Kachel trägt keine Quelle), dann
    /// dieselbe Nachfrage wie der Ladeknopf der Detailseite, an der Kachel.
    private func kachelLaden(_ item: Item, an knopf: Widget!) {
        guard let client else { return }
        let anker = gehalten(knopf)
        Task.detached { [self] in
            let voll = (try? await client.item(id: item.id)) ?? item
            aufHauptfaden { [self] in
                defer { losgelassen(anker) }
                guard gtk_widget_get_root(anker.widget) != nil else { return }
                self.ladetafelZeigen(voll, an: anker.widget)
            }
        }
    }

    /// Was ein Kachelmenü nicht geschafft hat — auf einer Detailseite im
    /// Hinweis, sonst als kurzer Hinweis im Fenster.
    private func kachelmeldung(_ text: String) {
        Protokoll.schreib("[Kachelmenü] \(text)")
        melden(text)
    }
}

/// Trägt den Rückruf eines Kachelmenüs über die Fadengrenze.
final class Kachelnachher: @unchecked Sendable {
    let tun: (Item) -> Void
    init(_ tun: @escaping (Item) -> Void) { self.tun = tun }
}

/// Menütaste (0xFF67) oder Umschalt+F10 — die Tastaturwege zu einem
/// Kontextmenü.
nonisolated(unsafe) private let menuetaste: @convention(c) (
    OpaquePointer?, UInt32, UInt32, GdkModifierType, gpointer?
) -> gboolean = { _, wert, _, zustand, daten in
    guard let daten else { return 0 }
    let umschalt = (zustand.rawValue & GDK_SHIFT_MASK.rawValue) != 0
    guard wert == 0xFF67 || (wert == 0xFFC7 && umschalt) else { return 0 }
    Unmanaged<Auftrag>.fromOpaque(daten).takeUnretainedValue().block()
    return 1
}
