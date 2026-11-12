import Foundation
import Testing

@testable import SwiftlyCore

/// The Apple TV and Mac settings pages, written down from the old screens (`tvOS/ProfileView`,
/// `macOS/{SettingsView,PlaybackSettingsView,AppearanceView}`) before their own rows were deleted:
/// the core's rows for `.tv` / `.desktop`, with `SettingsWording` where those devices read
/// differently from the iPhone, give the same title, second line, value, dimming and options.
/// Looked up by key: the two pages group the rows their own way.
struct SettingsRowsParityTvMacTests {
    struct Old {
        let key: String
        let title: String
        var under: String? = nil
        var value: String? = nil
        var enabled = true
        /// Option labels in order, for choice rows the page lists itself.
        var options: [String]? = nil
    }

    @MainActor
    private func model(_ facts: SettingsFacts, _ prepare: (UserDefaults) -> Void = { _ in }) throws -> SettingsModel {
        let defaults = try #require(UserDefaults(suiteName: "swiftly.parity.\(UUID().uuidString)"))
        prepare(defaults)
        let store = UserDefaultsSettingsStore(defaults: defaults)
        return SettingsModel(vm: makeCore().settingsVmNative(store: store, locale: "de", facts: facts))
    }

    private func facts(_ platform: SettingsPlatform, downloads: Bool, plugin: Bool = true) -> SettingsFacts {
        var f = settingsFacts()
        f.platform = platform
        f.downloads = downloads
        f.watchersPlugin = plugin
        f.landscapeLockPossible = false
        return f
    }

    @MainActor
    private func expect(_ m: SettingsModel, _ platform: SettingsPlatform, _ old: [Old]) {
        let rows = m.sections.sections.flatMap(\.rows)
        for was in old {
            guard let row = rows.first(where: { $0.key == was.key }) else {
                Issue.record("\(was.key): missing")
                continue
            }
            let word = SettingsWording.entry(platform, was.key)
            #expect((word?.title ?? row.title) == was.title, "\(was.key) title")
            let under: String? = switch word?.under ?? .core {
            case .core: row.under
            case .none: nil
            case .text(let text): text
            }
            #expect(under == was.under, "\(was.key) under")
            switch row.control {
            case .choice(_, let shown, let options):
                if let labels = was.options {
                    #expect(options.map(\.label) == labels, "\(was.key) options")
                    let selected = options.first { $0.label == shown }
                    #expect(selected.map { word?.shown[$0.value] ?? $0.label } == was.value, "\(was.key) value")
                } else {
                    #expect(shown == was.value, "\(was.key) value")
                }
            case .info(let value): #expect(value == was.value, "\(was.key) value")
            case .link(let value): #expect(value == was.value, "\(was.key) value")
            case .switch: #expect(was.value == nil, "\(was.key) value")
            }
            #expect(row.enabled == was.enabled, "\(was.key) enabled")
        }
    }

    @Test @MainActor func appleTv() throws {
        let m = try model(facts(.tv, downloads: false))
        // The TV page has no Offline group.
        #expect(m.sections.sections.first { $0.titleKey == "Offline" } == nil)
        expect(m, .tv, [
            Old(key: "immerDirectPlay", title: "Immer Direct Play"),
            Old(key: "bitratenGrenze", title: "Höchste Bitrate", value: "Unbegrenzt", enabled: false),
            Old(key: "bildrateAnpassen", title: "Bildrate an den Film anpassen"),
            Old(key: "tonSprache", title: "Ton", value: "Wie die Datei"),
            Old(key: "utSprache", title: "Untertitel", value: "Aus"),
            Old(key: "utAuto", title: "Untertitel automatisch"),
            Old(key: "utAussehen", title: "Aussehen der Untertitel", value: ""),
            Old(key: "naechsteAuto", title: "Nächste Folge automatisch"),
            Old(key: "introAbspannAuto", title: "Intro und Abspann automatisch überspringen"),
            Old(key: "zurueckSek", title: "Zurückspulen", value: "10 s"),
            Old(key: "vorSek", title: "Vorspulen", value: "30 s"),
            Old(key: "endzeitImPlayer", title: "Endzeit im Player"),
            Old(key: "fortschritt", title: "Fortschritt auf Kacheln"),
            Old(key: "merklisteAn", title: "Merkliste"),
            Old(key: "gesehenVonAn", title: "Gesehen von", under: "Zeigt auf Titelseiten, wer einen Titel gesehen hat"),
            Old(key: "alphabetAn", title: "Alphabetische Suche in Listen"),
            Old(key: "titelAlsLogo", title: "Titel als Logo"),
            Old(key: "neuGetrennt", title: "Neuzugänge getrennt"),
            Old(key: "genreChips", title: "Form", value: "Als Reihen", options: ["Als eigene Reihen", "Als Chips über den Reihen"]),
            Old(key: "askProfileAtLaunch", title: "Beim Start fragen, wer schaut"),
            Old(key: "einstellungenSync", title: "Einstellungen auf allen Geräten gleich halten"),
        ])
        let chips = try model(facts(.tv, downloads: false)) { $0.set(true, forKey: "genreChips") }
        expect(chips, .tv, [
            Old(key: "genreChips", title: "Form", value: "Als Chips", options: ["Als eigene Reihen", "Als Chips über den Reihen"]),
        ])
        // Without the watchers plugin the row is not there.
        let bare = try model(facts(.tv, downloads: false, plugin: false))
        #expect(!bare.sections.sections.flatMap(\.rows).contains { $0.key == "gesehenVonAn" })
    }

    @Test @MainActor func mac() throws {
        var f = facts(.desktop, downloads: true)
        f.storedDownloads = 3
        f.storedBytes = 2_310_000_000
        let m = try model(f) { $0.set(true, forKey: "downloadsAn") }
        // The Mac has no landscape lock.
        #expect(!m.sections.sections.flatMap(\.rows).contains { $0.key == "querformatFest" })
        expect(m, .desktop, [
            Old(key: "immerDirectPlay", title: "Immer Direct Play",
                under: "Der Server wandelt nie um, es läuft immer die Originaldatei"),
            Old(key: "bitratenGrenze", title: "Höchste Bitrate", value: "Unbegrenzt", enabled: false),
            Old(key: "tonSprache", title: "Ton", value: "Wie die Datei"),
            Old(key: "utSprache", title: "Untertitel", value: "Aus"),
            Old(key: "utAuto", title: "Untertitel automatisch",
                under: "Nur wenn der Ton nicht in der gewählten Sprache läuft"),
            Old(key: "utAussehen", title: "Aussehen der Untertitel", value: ""),
            Old(key: "naechsteAuto", title: "Nächste Folge automatisch"),
            Old(key: "introAbspannAuto", title: "Intro und Abspann automatisch überspringen"),
            Old(key: "technikschild", title: "Technische Daten im Player"),
            Old(key: "endzeitImPlayer", title: "Endzeit im Player"),
            Old(key: "zurueckSek", title: "Zurückspulen", value: "10 s"),
            Old(key: "vorSek", title: "Vorspulen", value: "30 s"),
            Old(key: "fortschritt", title: "Fortschritt auf Kacheln"),
            Old(key: "merklisteAn", title: "Merkliste",
                under: "Seite, Filter und Knopf auf Film- und Serienseiten"),
            Old(key: "gesehenVonAn", title: "Gesehen von", under: "Zeigt auf Titelseiten, wer einen Titel gesehen hat"),
            Old(key: "alphabetAn", title: "Alphabetische Suche in Listen"),
            Old(key: "titelAlsLogo", title: "Titel als Logo",
                under: "Auf Film- und Serienseiten, wenn dein Server eins hat"),
            Old(key: "neuGetrennt", title: "Neuzugänge getrennt", under: "Neue Filme und neue Serien als eigene Reihen"),
            Old(key: "genreChips", title: "Form", value: "Als eigene Reihen",
                options: ["Als eigene Reihen", "Als Chips über den Reihen"]),
            Old(key: "downloadsAn", title: "Downloads", under: "Titel offline schauen"),
            Old(key: "nurUeberWLAN", title: "Nur über WLAN", under: "Downloads warten, bis du im WLAN bist"),
            Old(key: "naechsteFolgeLaden", title: "Nächste Folge laden",
                under: "Lädt die nächste, löscht die gesehene"),
            Old(key: "downloadsSpeicher", title: "Speicher", under: "3 Titel auf diesem Mac", value: "2,31 GB"),
            Old(key: "seerr", title: "Seerr", under: "Anfragen, was noch nicht da ist"),
            Old(key: "eigeneHeader", title: "Eigene Header", under: "Für einen Dienst vor dem Server"),
            Old(key: "einstellungenSync", title: "Auf allen Geräten gleich", under: "Liegt auf deinem Server"),
        ])
    }

    /// iPhone and iPad keep the core's own wording.
    @Test func phoneAndTabletHaveNoOverrides() {
        #expect(SettingsWording.entry(.phone, "alphabetAn") == nil)
        #expect(SettingsWording.entry(.tablet, "utAussehen") == nil)
    }
}
