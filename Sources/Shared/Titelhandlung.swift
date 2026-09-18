import JellyfinKit
import SwiftUI

/// Eine Handlung, die ein Blatt anbietet: Symbol, Beschriftung, was sie tut.
///
/// Steht bewusst **nicht** in `Handlungsblatt`. Dort war sie als
/// `Handlungsblatt.Handlung` an einen Baustein gebunden, den es nur auf dem
/// iPhone gibt — und damit konnten Fernseher und Mac dieselben Listen nicht
/// bauen, obwohl die Handlungen selbst überall gleich sind: „von vorn
/// abspielen", „Fortschritt zurücksetzen", „Metadaten neu einlesen".
///
/// Wie die Liste **aussieht**, bleibt Sache der Plattform. Das iPhone zeigt
/// sie als Blatt von unten, der Fernseher wird etwas anderes tun. Was
/// drinsteht, ist dieselbe Frage.
struct Titelhandlung: Identifiable {
    let id = UUID()
    let symbol: String
    let text: LocalizedStringKey
    /// Trägt die Warnfarbe statt der Schriftfarbe — für alles, was löscht
    /// oder verwirft.
    var warnend = false
    let tun: () -> Void

    init(symbol: String, text: LocalizedStringKey, warnend: Bool = false,
         tun: @escaping () -> Void) {
        self.symbol = symbol
        self.text = text
        self.warnend = warnend
        self.tun = tun
    }
}

/// Welche Handlungen ein Titel anbietet.
///
/// Die Listen standen viermal: Film und Serie, je einmal am Telefon und
/// einmal am Fernseher. Der Fernseher hat sie kopiert, weil er geteilte
/// Logik nicht anfassen soll und die Liste trotzdem brauchte — und hat es
/// selbst gemeldet, statt es liegenzulassen.
///
/// **Was hier steht, ist die Frage: welche Einträge gibt es und wann.** Wie
/// die Liste aussieht, bleibt Sache der Plattform — Blatt von unten am
/// Telefon, Tafel am Auslöser auf großen Schirmen.
///
/// Die Rückrufe reicht die Ansicht herein: nur sie weiß, wie bei ihr
/// abgespielt, gemeldet und aufgefrischt wird.
@MainActor
enum Titelhandlungen {

    /// Für einen Film.
    static func fuerFilm(_ titel: Item, plan: PlaybackPlan?, model: AppModel,
                         starten: @escaping (Double) -> Void,
                         melden: @escaping (String) -> Void,
                         auffrischen: @escaping () async -> Void) -> [Titelhandlung] {
        var liste: [Titelhandlung] = []
        // Nur wenn es überhaupt etwas zurückzusetzen gibt: „von vorn" bei
        // einem Film, der noch bei null steht, ist eine Zeile ohne Wirkung.
        if plan != nil, titel.fortsetzenAb != nil {
            liste.append(.init(symbol: "gobackward", text: "Von vorn abspielen") {
                starten(0)
            })
            liste.append(.init(symbol: "arrow.counterclockwise.circle",
                               text: "Fortschritt zurücksetzen") {
                Task {
                    if let grund = await model.setzeGesehen(titel, an: false) {
                        melden(grund)
                        return
                    }
                    melden(String(localized: "Der Fortschritt ist zurückgesetzt."))
                    await auffrischen()
                }
            })
        }
        liste.append(metadaten(titel, model: model, melden: melden))
        return liste
    }

    /// Für eine Serie.
    ///
    /// `stand` ist die Folge, bei der der Server den Zuschauer sieht;
    /// `staffel` die gerade gewählte.
    static func fuerSerie(_ serie: Item, stand: Item?, staffel: Item?, model: AppModel,
                          folgeStarten: @escaping (Item, Double) -> Void,
                          melden: @escaping (String) -> Void,
                          auffrischen: @escaping () async -> Void) -> [Titelhandlung] {
        var liste: [Titelhandlung] = []
        if let stand {
            liste.append(.init(symbol: "gobackward", text: "Folge von vorn abspielen") {
                folgeStarten(stand, 0)
            })
            liste.append(.init(symbol: "forward.end.alt", text: "Nächste Folge abspielen") {
                Task {
                    guard let naechste = await model.folgeNach(stand) else {
                        melden(String(localized: "Danach kommt nichts mehr."))
                        return
                    }
                    folgeStarten(naechste, 0)
                }
            })
        }
        if let staffel {
            liste.append(.init(symbol: "checkmark.circle",
                               text: "\(staffel.name) als gesehen") {
                Task {
                    if let grund = await model.setzeGesehen(staffel, an: true) {
                        melden(grund)
                        return
                    }
                    melden(String(localized: "\(staffel.name) ist als gesehen vermerkt."))
                    await auffrischen()
                }
            })
        }
        liste.append(metadaten(serie, model: model, melden: melden))
        return liste
    }

    /// Steht unter beiden Listen, deshalb einmal hier.
    private static func metadaten(_ titel: Item, model: AppModel,
                                  melden: @escaping (String) -> Void) -> Titelhandlung {
        .init(symbol: "arrow.clockwise", text: "Metadaten neu einlesen") {
            Task { melden(await model.metadatenAuffrischen(titel)) }
        }
    }
}
