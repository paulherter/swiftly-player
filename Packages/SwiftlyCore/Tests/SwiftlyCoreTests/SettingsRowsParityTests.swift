import Foundation
import Testing

@testable import SwiftlyCore

/// Walks every row the old Swift settings screens showed (`SettingsView`, `PlaybackSettingsView`,
/// `PresentationView`, written down below by section, order, title, second line and value text)
/// and compares it with what `SettingsModel` serves, on a fresh install and on a few states that
/// change the rows. The old screens read the same `UserDefaults` keys, so the values come from there.
struct SettingsRowsParityTests {
    struct Old {
        let key: String
        let title: String
        var under: String? = nil
        /// The text on the right (choice / info / link rows); `nil` for switches.
        var value: String? = nil
        var enabled = true
    }

    @MainActor
    private func model(_ facts: SettingsFacts, _ prepare: (UserDefaults) -> Void = { _ in }) throws -> SettingsModel {
        let suite = "swiftly.parity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        prepare(defaults)
        let store = UserDefaultsSettingsStore(defaults: defaults)
        return SettingsModel(vm: makeCore().settingsVmNative(store: store, locale: "de", facts: facts))
    }

    private func value(_ row: SettingsRow) -> String? {
        switch row.control {
        case .choice(_, let shown, _): shown
        case .info(let value): value
        case .link(let value): value
        case .switch: nil
        }
    }

    @MainActor
    private func expect(_ model: SettingsModel, section: String, _ old: [Old]) {
        let rows = model.sections.sections.first { $0.titleKey == section }?.rows ?? []
        #expect(rows.map(\.key) == old.map(\.key), "\(section): order")
        for (row, was) in zip(rows, old) {
            #expect(row.title == was.title, "\(was.key) title")
            #expect(row.under == was.under, "\(was.key) under")
            #expect(value(row) == was.value, "\(was.key) value")
            #expect(row.enabled == was.enabled, "\(was.key) enabled")
        }
    }

    @Test @MainActor func freshInstallPlayback() throws {
        let m = try model(settingsFacts())
        expect(m, section: "Qualität", [
            Old(key: "immerDirectPlay", title: "Immer Direct Play", under: "Der Server wandelt nie um"),
            // Direct Play is on by default, so the bitrate row is dimmed with its note.
            Old(key: "bitratenGrenze", title: "Höchste Bitrate", under: "Nicht nötig bei Direct Play",
                value: "Unbegrenzt", enabled: false),
        ])
        expect(m, section: "Sprache", [
            Old(key: "tonSprache", title: "Ton", value: "Wie die Datei"),
            Old(key: "utSprache", title: "Untertitel", value: "Aus"),
            Old(key: "utAuto", title: "Untertitel automatisch", under: "Wenn der Ton nicht deine Sprache ist"),
            Old(key: "utAussehen", title: "Untertitel-Stil", value: ""),
        ])
        expect(m, section: "Ablauf", [
            Old(key: "naechsteAuto", title: "Nächste Folge automatisch"),
            Old(key: "introAbspannAuto", title: "Intro und Abspann", under: "Werden automatisch übersprungen"),
        ])
        expect(m, section: "Im Player", [
            Old(key: "zurueckSek", title: "Zurückspulen", value: "10 s"),
            Old(key: "vorSek", title: "Vorspulen", value: "30 s"),
            Old(key: "querformatFest", title: "Querformat sperren"),
            Old(key: "technikschild", title: "Technische Daten", under: "Zeigt Format und Bitrate im Player"),
            Old(key: "endzeitImPlayer", title: "Endzeit im Player", under: "Zeigt, wann der Titel endet"),
        ])
    }

    @Test @MainActor func iPadHasNoLandscapeLockAndNoConvertingServerFixesDirectPlay() throws {
        var facts = settingsFacts()
        facts.landscapeLockPossible = false
        facts.canConvert = false
        let m = try model(facts) { $0.set(false, forKey: "immerDirectPlay") }
        let rows = m.sections.sections.flatMap(\.rows)
        #expect(!rows.contains { $0.key == "querformatFest" })
        let direct = try #require(rows.first { $0.key == "immerDirectPlay" })
        #expect(direct.enabled == false)
        if case .switch(let on) = direct.control { #expect(on) }
    }

    @Test @MainActor func bitrateLimitAndSeconds() throws {
        var facts = settingsFacts()
        facts.server = "http://a:8096"
        let m = try model(facts) {
            $0.set(false, forKey: "immerDirectPlay|http://a:8096")
            $0.set(8, forKey: "bitratenGrenze|http://a:8096")
            $0.set(15, forKey: "zurueckSek")
        }
        expect(m, section: "Qualität", [
            Old(key: "immerDirectPlay", title: "Immer Direct Play", under: "Der Server wandelt nie um"),
            Old(key: "bitratenGrenze", title: "Höchste Bitrate", value: "8 Mbit/s"),
        ])
        let rows = m.sections.sections.flatMap(\.rows)
        #expect(value(try #require(rows.first { $0.key == "zurueckSek" })) == "15 s")
    }

    @Test @MainActor func offlineGroup() async throws {
        var facts = settingsFacts()
        facts.storedDownloads = 3
        facts.storedBytes = 2_310_000_000
        let off = try model(facts)
        expect(off, section: "Offline", [
            Old(key: "downloadsAn", title: "Downloads", under: "Titel offline schauen"),
        ])
        let on = try model(facts) { $0.set(true, forKey: "downloadsAn") }
        expect(on, section: "Offline", [
            Old(key: "downloadsAn", title: "Downloads", under: "Titel offline schauen"),
            Old(key: "nurUeberWLAN", title: "Nur über WLAN", under: "Downloads warten auf WLAN"),
            Old(key: "naechsteFolgeLaden", title: "Nächste Folge vorab laden",
                under: "Lädt die nächste, löscht die gesehene"),
            Old(key: "downloadsSpeicher", title: "Speicher", under: "3 Titel auf diesem Gerät", value: "2,31 GB"),
        ])
        // Turning Downloads off while titles are stored asks first; nothing is written yet.
        let observing = Task { @MainActor in await on.observe() }
        try on.setSwitch("downloadsAn", false)
        #expect(await eventuallyOnMain { on.status.confirm == .disableDownloads })
        try on.cancelConfirm()
        #expect(await eventuallyOnMain { on.status.confirm == nil })
        observing.cancel()
        await observing.value
    }

    @Test @MainActor func serverAndSyncGroups() throws {
        var facts = settingsFacts()
        facts.ownHeaders = 2
        facts.seerrConnected = true
        let m = try model(facts)
        expect(m, section: "Server und Dienste", [
            Old(key: "eigeneHeader", title: "Eigene Header", under: "Für einen Dienst vor dem Server", value: "2"),
            Old(key: "seerr", title: "Seerr", under: "Anfragen, was noch nicht da ist", value: "Verbunden"),
        ])
        expect(m, section: "Synchronisierung", [
            Old(key: "einstellungenSync", title: "Auf allen Geräten gleich", under: "Liegt auf deinem Server"),
        ])
        // A server without Seerr and without display preferences shows neither.
        facts.seerr = false
        facts.settingsSync = false
        let bare = try model(facts)
        #expect(bare.sections.sections.first { $0.titleKey == "Synchronisierung" } == nil)
        #expect(bare.sections.sections.flatMap(\.rows).contains { $0.key == "seerr" } == false)
    }

    @Test @MainActor func appearanceGroup() throws {
        let plain = try model(settingsFacts())
        expect(plain, section: "Filme und Serien", [
            Old(key: "fortschritt", title: "Fortschritt auf Kacheln"),
            Old(key: "merklisteAn", title: "Merkliste", under: "Auf Film- und Serienseiten"),
            Old(key: "alphabetAn", title: "Alphabet in Listen"),
            Old(key: "titelAlsLogo", title: "Titel als Logo", under: "Wenn dein Server eins hat"),
        ])
        var facts = settingsFacts()
        facts.watchersPlugin = true
        let withPlugin = try model(facts)
        let keys = withPlugin.sections.sections.first { $0.titleKey == "Filme und Serien" }?.rows.map(\.key)
        #expect(keys == ["fortschritt", "merklisteAn", "gesehenVonAn", "alphabetAn", "titelAlsLogo"])
        let gesehen = withPlugin.sections.sections.flatMap(\.rows).first { $0.key == "gesehenVonAn" }
        #expect(gesehen?.title == "Gesehen von")
        #expect(gesehen?.under == "Zeigt auf Titelseiten, wer einen Titel gesehen hat")
        let start = plain.sections.sections.first { $0.titleKey == "Startseite" }?.rows
        #expect(start?.first?.title == "Neuzugänge getrennt")
        #expect(start?.first?.under == "Als eigene Reihen")
    }

    /// Old screen: choosing a subtitle language switches "automatic" on.
    @Test @MainActor func subtitleLanguageSwitchesAutomaticOn() throws {
        let suite = "swiftly.parity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let m = SettingsModel(vm: makeCore().settingsVmNative(store: store, locale: "de", facts: settingsFacts()))
        try m.setChoice("utSprache", "Deutsch")
        store.flush()
        #expect(defaults.string(forKey: "utSprache") == "Deutsch")
        #expect(defaults.object(forKey: "utAuto") as? Bool == true)
    }
}
