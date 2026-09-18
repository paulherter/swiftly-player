import Foundation

/// Die Sprachen, die zur Vorwahl stehen — samt der Schreibweisen, unter denen
/// sie in Spurnamen auftauchen.
///
/// Eine reine Tabelle, deshalb außerhalb des Modells: an den Hauptakteur
/// gebunden ließe sie sich aus einer Ansicht nicht ohne Umweg lesen.
public enum Sprache {
    /// Die Sprachen, die zur Auswahl stehen — samt der Schreibweisen, unter
    /// denen sie in Spurnamen auftauchen. VLC meldet je nach Datei „German",
    /// „Deutsch" oder „ger"; ein Vergleich auf einen einzigen Namen greift
    /// deshalb zu kurz.
    public static let alle: [(name: String, formen: [String])] = [
        ("Deutsch", ["deutsch", "german", "ger", "deu"]),
        ("English", ["english", "eng", "en"]),
        ("Français", ["français", "french", "fre", "fra"]),
        ("Español", ["español", "spanish", "spa", "esp"]),
        ("Italiano", ["italiano", "italian", "ita"]),
        ("日本語", ["japanese", "jpn", "japanisch"]),
    ]

    /// Passt der Spurname zur gewünschten Sprache?
    public static func passt(_ spurname: String, zu sprache: String) -> Bool {
        !sprache.isEmpty && erkannt(in: spurname) == sprache
    }

    /// Der erkannte Anzeigename („Deutsch"), wenn eine der hinterlegten
    /// Sprachen im Text steckt — sonst `nil`, statt geraten.
    ///
    /// Wortweise, nicht als Teilzeichenkette. Mit `contains` galt „Slovenian"
    /// als Englisch, weil dort „en" vorkommt — und „Armenian" ebenso. Kurze
    /// Formen wie „en" oder „ger" sind Sprachkürzel und stehen im Spurnamen
    /// immer für sich; lange Formen wie „deutsch" dürfen auch in einem
    /// zusammengesetzten Namen stecken („Deutsch (Kommentar)").
    public static func erkannt(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let klein = text.lowercased()
        let woerter = Set(klein.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return alle.first { eintrag in
            eintrag.formen.contains { form in
                woerter.contains(form) || (form.count > 3 && klein.contains(form))
            }
        }?.name
    }

    /// Steht im Spurnamen, dass nur die fremdsprachigen Stellen untertitelt
    /// sind? Nur für Spuren, zu denen der Server nichts weiß.
    public static func klingtErzwungen(_ name: String) -> Bool {
        let klein = name.lowercased()
        return ["forced", "erzwungen"].contains { klein.contains($0) }
    }
}
