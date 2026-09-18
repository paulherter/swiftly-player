import Foundation

/// Wie die Datei hinter einem Titel beschrieben wird.
///
/// Der Auszug ist der Beleg für das Versprechen der App: Container, Codec,
/// Tonspuren, Untertitel — daran liest man ab, **warum** Direct Play geht.
/// Er gehört deshalb auf beide Plattformen, und die Formulierungen dürfen
/// nicht auseinanderlaufen.
///
/// Lag zuerst als drei private Funktionen in `BrowseViews`, dann in
/// `Sources/Shared`. Das war so lange richtig, wie alle Plattformen SwiftUI
/// waren; die Linux-Fassung erreicht `Sources/Shared` nicht — dort fehlte der
/// Auszug deshalb ganz, ausgerechnet der Beleg für das Versprechen der App.
///
/// Übersetzt wird über ``uebersetzt(_:)`` mit dem Bündel des Pakets.
public enum Dateiangaben {

    /// Auflösung plus Codec — „2160p · HEVC".
    public static func video(_ strom: MediaStream, _ quelle: MediaSource) -> String {
        var teile: [String] = []
        if let hoehe = quelle.hoehe { teile.append("\(hoehe)p") }
        if let codec = strom.codec { teile.append(MediaStream.lesbar(codec)) }
        return teile.isEmpty ? strom.kurz : teile.joined(separator: " · ")
    }

    /// Höchstens drei Sprachen, danach „+ n".
    public static func untertitel(_ stroeme: [MediaStream]) -> String {
        guard !stroeme.isEmpty else { return uebersetzt("Keine") }
        let sprachen = stroeme.compactMap(\.sprachname)
        let einmalig = NSOrderedSet(array: sprachen).array as? [String] ?? []
        let sichtbar = einmalig.prefix(3).joined(separator: " · ")
        let rest = einmalig.count - min(einmalig.count, 3)
        return rest > 0 ? sichtbar + " + \(rest)" : (sichtbar.isEmpty ? "\(stroeme.count)" : sichtbar)
    }

    /// Die Dateigröße — „10,3 GB" auf Deutsch, „10.3 GB" auf Englisch.
    ///
    /// Rechnet über ``Downloadregeln/groesse(_:)``, damit im Auszug und in
    /// der Downloadliste nicht zwei verschiedene Zahlen für dieselbe Datei
    /// stehen. Warum `.file` und nicht Zweierpotenzen, steht dort.
    ///
    /// **Zwei Fehler standen hier vorher.** `String(format: "%.1f GB")` mit
    /// fest eingesetztem Komma war auf Englisch falsch — „10,3 GB", wo der
    /// Rest des Systems „10.3 GB" schreibt. Und die Einheit war immer GB:
    /// eine Tonspur von 112 kB stand als „0,0 GB" da.
    ///
    /// Ohne Größe vom Server bleibt die Zeile leer, nicht „0 bytes".
    public static func groesse(_ quelle: MediaSource) -> String {
        guard let bytes = quelle.size else { return "" }
        return Downloadregeln.groesse(bytes)
    }

    /// Container samt Größe — „MKV · 10,3 GB", ohne Größe nur „MKV".
    ///
    /// Das Trennzeichen steht hier und nicht in ``groesse(_:)``: dort war es
    /// eine Falle, weil Mac und Linux die Größe auch einzeln anzeigen und
    /// dann ein Mittelpunkt vor dem Nichts stand.
    public static func container(_ quelle: MediaSource) -> String? {
        guard let container = quelle.container else { return nil }
        let masz = groesse(quelle)
        return masz.isEmpty ? container.uppercased() : container.uppercased() + " · " + masz
    }

    public static func tonspuren(_ quelle: MediaSource) -> [MediaStream] {
        (quelle.mediaStreams ?? []).filter { $0.type == "Audio" }
    }

    public static func untertitelspuren(_ quelle: MediaSource) -> [MediaStream] {
        (quelle.mediaStreams ?? []).filter { $0.type == "Subtitle" }
    }

    public static func videospur(_ quelle: MediaSource) -> MediaStream? {
        (quelle.mediaStreams ?? []).first { $0.type == "Video" }
    }
}
