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

    public static func groesse(_ quelle: MediaSource) -> String {
        guard let bytes = quelle.size else { return "" }
        return " · " + String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
            .replacingOccurrences(of: ".", with: ",")
    }

    /// Container samt Größe — „MKV · 10,3 GB".
    public static func container(_ quelle: MediaSource) -> String? {
        guard let container = quelle.container else { return nil }
        return container.uppercased() + groesse(quelle)
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
