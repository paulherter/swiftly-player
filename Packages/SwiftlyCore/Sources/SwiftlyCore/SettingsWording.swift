import Foundation

/// The wording the Apple TV and Mac settings pages have always used where it differs from the
/// core's (the iPhone wording). Rows, order, values, dimming, options and validation are the
/// core's; only the title or second line of a row may read differently on these two devices.
///
/// German keys (the app catalog translates them like the `Text("...")` literals they replace),
/// so the table is plain data and `SettingsRowsParityTests` can compare it with the old screens.
/// iPhone and iPad have no entries: the core's own wording is theirs.
public enum SettingsWording {
    public enum Under: Equatable, Sendable {
        /// The core's second line stays.
        case core
        /// No second line on this device.
        case none
        case text(String)
    }

    public struct Entry: Equatable, Sendable {
        public var title: String?
        public var under: Under
        /// What a choice row shows on its right (selected value -> German key), where it reads
        /// differently from the option's own label (the TV genre form: "Als Chips").
        public var shown: [String: String]

        init(title: String? = nil, under: Under = .core, shown: [String: String] = [:]) {
            self.title = title
            self.under = under
            self.shown = shown
        }
    }

    public static func entry(_ platform: SettingsPlatform, _ key: String) -> Entry? {
        switch platform {
        case .tv: tv[key]
        case .desktop: desktop[key]
        case .phone, .tablet: nil
        }
    }

    /// Apple TV: one line per row, nothing under the titles.
    private static let tv: [String: Entry] = [
        "immerDirectPlay": Entry(under: .none),
        "bitratenGrenze": Entry(under: .none),
        "utAuto": Entry(under: .none),
        "utAussehen": Entry(title: "Aussehen der Untertitel"),
        "introAbspannAuto": Entry(title: "Intro und Abspann automatisch überspringen", under: .none),
        "endzeitImPlayer": Entry(under: .none),
        "merklisteAn": Entry(under: .none),
        "alphabetAn": Entry(title: "Alphabetische Suche in Listen"),
        "titelAlsLogo": Entry(under: .none),
        "neuGetrennt": Entry(under: .none),
        "genreChips": Entry(shown: ["rails": "Als Reihen", "chips": "Als Chips"]),
        "einstellungenSync": Entry(title: "Einstellungen auf allen Geräten gleich halten", under: .none),
    ]

    /// Mac.
    private static let desktop: [String: Entry] = [
        "immerDirectPlay": Entry(under: .text("Der Server wandelt nie um, es läuft immer die Originaldatei")),
        "bitratenGrenze": Entry(under: .none),
        "utAuto": Entry(under: .text("Nur wenn der Ton nicht in der gewählten Sprache läuft")),
        "utAussehen": Entry(title: "Aussehen der Untertitel"),
        "introAbspannAuto": Entry(title: "Intro und Abspann automatisch überspringen", under: .none),
        "technikschild": Entry(title: "Technische Daten im Player", under: .none),
        "endzeitImPlayer": Entry(under: .none),
        "merklisteAn": Entry(under: .text("Seite, Filter und Knopf auf Film- und Serienseiten")),
        "alphabetAn": Entry(title: "Alphabetische Suche in Listen"),
        "titelAlsLogo": Entry(under: .text("Auf Film- und Serienseiten, wenn dein Server eins hat")),
        "neuGetrennt": Entry(under: .text("Neue Filme und neue Serien als eigene Reihen")),
        "nurUeberWLAN": Entry(under: .text("Downloads warten, bis du im WLAN bist")),
        "naechsteFolgeLaden": Entry(title: "Nächste Folge laden"),
    ]
}
