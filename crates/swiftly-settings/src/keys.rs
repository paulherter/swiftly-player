//! Every persisted key, with the default and the Swift `file:line` it comes from.
//!
//! Paths are relative to the repository root (`Sources/...` is the app,
//! `Packages/JellyfinKit/...` the package; `JK` below stands for
//! `Packages/JellyfinKit/Sources/JellyfinKit`). The names are the German keys devices already
//! hold; **never rename one**. `Option<T>` marks a setting without a default in Swift ("never
//! set" is a state of its own).

use crate::key::{Key, KeyInfo, Scope, SettingValue};
use std::collections::BTreeMap;

macro_rules! keys {
    ($( $(#[$m:meta])* $id:ident : $t:ty = $def:expr, $name:literal, $scope:ident, $src:literal; )*) => {
        $( $(#[$m])* pub const $id: Key<$t> = Key::new($name, { const D: <$t as SettingValue>::Const = $def; D }, Scope::$scope, $src); )*

        /// The registry of all fixed keys, in definition order.
        pub const ALL: &[KeyInfo] = &[
            $( KeyInfo {
                name: $name,
                value_type: <$t as SettingValue>::TYPE,
                default: stringify!($def),
                scope: Scope::$scope,
                source: $src,
            }, )*
        ];
    };
}

keys! {
    // ---- Player and playback ----
    /// Technical badge in the player. Readers: iOS `PlayerScreen.swift:30`, mac `:66`, tvOS `:31`.
    TECHNIKSCHILD: bool = false, "technikschild", Device, "Sources/Shared/PlaybackSettingsView.swift:120";
    /// Measure mode of the technical badge.
    TECHNIKSCHILD_MESSEN: bool = false, "technikschildMessen", Device, "Sources/Shared/TechBadge.swift:63";
    /// Skip intro and credits automatically. Synced.
    INTRO_ABSPANN_AUTO: bool = false, "introAbspannAuto", Synced, "Sources/Shared/PlaybackSettingsView.swift:122";
    /// Show the end time in the player (`PlayerEndTime.key`). Not synced.
    ENDZEIT_IM_PLAYER: bool = false, "endzeitImPlayer", Device, "Sources/Shared/PlayRequest.swift:237";
    /// Fill the frame (crop to the screen).
    BILDFUELLEND: bool = false, "bildfuellend", Device, "Sources/iOS/PlayerScreen.swift:36";
    /// Lock landscape. Default also `AppModel.swift:674`.
    QUERFORMAT_FEST: bool = true, "querformatFest", Device, "Sources/iOS/PlayerScreen.swift:215";
    /// Rewind seconds; options `SKIP_SECONDS_LEVELS`. Store default `AppModel.swift:720`. Synced.
    ZURUECK_SEK: i64 = 10, "zurueckSek", Synced, "Sources/Shared/AppModel.swift:720";
    /// Forward seconds; options `SKIP_SECONDS_LEVELS`. Store default `AppModel.swift:721`. Synced.
    VOR_SEK: i64 = 30, "vorSek", Synced, "Sources/Shared/AppModel.swift:721";
    /// Player volume (macOS only).
    PLAYER_LAUTSTAERKE: f64 = 1.0, "playerLautstaerke", Device, "Sources/macOS/PlayerScreen.swift:85";
    /// Volume before mute (macOS only).
    PLAYER_LAUTSTAERKE_DAVOR: f64 = 1.0, "playerLautstaerkeDavor", Device, "Sources/macOS/PlayerScreen.swift:86";
    /// Always Direct Play; per server, falls back to the device-wide key (`AppModel.swift:239-240`, default `:672`).
    IMMER_DIRECT_PLAY: bool = true, "immerDirectPlay", DevicePerServer, "Sources/Shared/AppModel.swift:239";
    /// Bitrate limit in Mbit/s, 0 = unlimited; per server (`AppModel.swift:241-242`, default `:673`).
    BITRATEN_GRENZE: i64 = 0, "bitratenGrenze", DevicePerServer, "Sources/Shared/AppModel.swift:241";
    /// Match the display frame rate to the film (tvOS only).
    BILDRATE_ANPASSEN: bool = true, "bildrateAnpassen", Device, "Sources/tvOS/ProfileView.swift:15";
    /// Startup measurement (read `VLCPlayer.swift:157,159`; no writer found).
    STARTMESSUNG: bool = true, "startmessung", Device, "Sources/Shared/VLCPlayer.swift:157";
    /// Subtitle look as JSON data (`SubtitleLook`); unset = built-in look. Synced.
    UT_AUSSEHEN: Option<Vec<u8>> = (), "utAussehen", Synced, "Sources/Shared/AppModel.swift:693";
    /// Automatic subtitles. Synced.
    UT_AUTO: bool = false, "utAuto", Synced, "Sources/Shared/AppModel.swift:683";
    /// One-time migration flag for `utAuto` (`AppModel.swift:685-688`).
    UT_AUTO_NACHGEZOGEN: bool = false, "utAutoNachgezogen", Device, "Sources/Shared/AppModel.swift:685";
    /// Audio language, empty = as the file. Synced.
    TON_SPRACHE: String = "", "tonSprache", Synced, "Sources/Shared/AppModel.swift:680";
    /// Subtitle language, empty = off or default. Synced.
    UT_SPRACHE: String = "", "utSprache", Synced, "Sources/Shared/AppModel.swift:681";
    /// Next episode automatically; **unset** follows the account (`AppModel.swift:696`). Synced.
    NAECHSTE_AUTO: Option<bool> = (), "naechsteAuto", Synced, "Sources/Shared/AppModel.swift:696";
    /// Remembered subtitle choice per title (dictionary keyed by `account|seriesId ?? id`). The
    /// value shape is not documented (see NOTES.md); held as a string map.
    UT_JE_TITEL: Option<BTreeMap<String, String>> = (), "utJeTitel", Device, "Packages/JellyfinKit/Sources/JellyfinKit/TrackRule.swift:180";
    /// Remembered audio choice per title (same shape as `utJeTitel`).
    TON_JE_TITEL: Option<BTreeMap<String, String>> = (), "tonJeTitel", Device, "Packages/JellyfinKit/Sources/JellyfinKit/TrackRule.swift:181";
    /// Buffer level, raw of `BufferLevel`: `normal` or `schlecht`. `AppModel.swift:157,717-718`.
    PUFFERSTUFE: String = "normal", "pufferstufe", Device, "Sources/Shared/AppModel.swift:717";

    // ---- Display, home, library ----
    /// Show the title as a logo. Synced.
    TITEL_ALS_LOGO: bool = false, "titelAlsLogo", Synced, "Sources/Shared/AppearanceView.swift:19";
    /// Progress bars on tiles (`Style.swift:761`, default `AppModel.swift:675`). Synced.
    FORTSCHRITT: bool = true, "fortschritt", Synced, "Sources/Shared/Style.swift:761";
    /// Watchlist shown. Synced.
    MERKLISTE_AN: bool = true, "merklisteAn", Synced, "Sources/Shared/AppModel.swift:676";
    /// Alphabet strip in lists. Synced.
    ALPHABET_AN: bool = true, "alphabetAn", Synced, "Sources/Shared/AppModel.swift:677";
    /// Show who watched on title pages. Not synced.
    GESEHEN_VON_AN: bool = true, "gesehenVonAn", Device, "Sources/Shared/AppModel.swift:678";
    /// Servers for "Gesehen von". Not synced.
    GESEHEN_VON_SERVER: Vec<String> = &[], "gesehenVonServer", Device, "Sources/Shared/AppModel.swift:679";
    /// New arrivals as two separate rows. Synced.
    NEU_GETRENNT: bool = true, "neuGetrennt", Synced, "Sources/Shared/AppModel.swift:699";
    /// Home rails, `StartRail` raw values. Synced.
    START_REIHEN: Vec<String> = &[], "startReihen", Synced, "Sources/Shared/AppModel.swift:705";
    /// Hidden home rails. Synced.
    START_AUS: Vec<String> = &[], "startAus", Synced, "Sources/Shared/AppModel.swift:713";
    /// Genre rails. Synced.
    START_GENRES: Vec<String> = &[], "startGenres", Synced, "Sources/Shared/AppModel.swift:715";
    /// Genres as chips instead of rails. Synced.
    GENRE_CHIPS: bool = false, "genreChips", Synced, "Sources/Shared/AppModel.swift:714";
    /// Chosen home libraries (JSON data, `StartLibraries`); per server and synced per server (`AppModel.swift:243,716`).
    START_BIBLIOTHEKEN: Option<Vec<u8>> = (), "startBibliotheken", SyncedPerServer, "Sources/Shared/AppModel.swift:716";
    /// One order for the fixed home rows, the library rows (`library:<id>`) and collection rows, per server, on this device (not part of the cross-app sync). New.
    START_REIHENFOLGE: Vec<String> = &[], "startReihenfolge", DevicePerServer, "Sources/Shared/AppModel.swift:716 (new in Rust, no Swift key)";
    /// Search history, one term per line. The per-account form is `search_history_key`.
    LETZTE_SUCHEN: String = "", "letzteSuchen", Device, "Packages/JellyfinKit/Sources/JellyfinKit/SearchHistory.swift:13";
    /// Ask for the profile at launch (tvOS); unset = on.
    ASK_PROFILE_AT_LAUNCH: bool = true, "askProfileAtLaunch", Device, "Sources/tvOS/ProfilePickerView.swift:14";
    /// Server name cache (tvOS).
    SERVER_NAMEN_CACHE: Option<BTreeMap<String, String>> = (), "serverNamenCache", Device, "Sources/tvOS/ProfilePickerView.swift:56";
    /// Remembered genre filter of the watchlist (absent = all genres).
    GATTUNG_MERKLISTE: Option<String> = (), "gattung.merkliste", Device, "Sources/Shared/WatchlistModel.swift:37";

    // ---- Downloads ----
    /// Downloads switched on. Device only (`AppModel.swift:178-186`, default `:722`).
    DOWNLOADS_AN: bool = false, "downloadsAn", Device, "Sources/Shared/AppModel.swift:722";
    /// Downloads only over Wi-Fi. Never synced (test `SettingsSyncTests.swift:91`).
    NUR_UEBER_WLAN: bool = true, "nurUeberWLAN", Device, "Sources/Shared/AppModel.swift:723";
    /// Download the next episode automatically.
    NAECHSTE_FOLGE_LADEN: bool = false, "naechsteFolgeLaden", Device, "Sources/Shared/DownloadManager.swift:265";

    // ---- Sync, account, misc ----
    /// Keep settings equal across devices. On by default.
    EINSTELLUNGEN_SYNC: bool = true, "einstellungenSync", Device, "Sources/Shared/SettingsSyncRun.swift:24";
    /// Milliseconds since 1970 of the last local change or adoption.
    EINSTELLUNGEN_SYNC_ZEIT: Option<f64> = (), "einstellungenSyncZeit", Device, "Sources/Shared/SettingsSyncRun.swift:25";
    /// The account the device last synced with.
    EINSTELLUNGEN_SYNC_KONTO: Option<String> = (), "einstellungenSyncKonto", Device, "Sources/Shared/SettingsSyncRun.swift:26";
    /// Milliseconds since 1970 of the server copy last seen.
    EINSTELLUNGEN_SYNC_SERVER: Option<f64> = (), "einstellungenSyncServer", Device, "Sources/Shared/SettingsSyncRun.swift:27";
    /// The last server entry (data).
    LETZTER_SERVER: Option<Vec<u8>> = (), "letzterServer", Device, "Sources/Shared/LoginModel.swift:21";
    /// Queued reports (data); semantics not documented.
    NACHMELDUNGEN: Option<Vec<u8>> = (), "nachmeldungen", Device, "Sources/Shared/AppModel.swift:2456";
    /// Discord indicator.
    DISCORD_ANZEIGEN: bool = false, "discordAnzeigen", Device, "Sources/Shared/AppModel.swift:719";
    /// The Discord hint was shown once.
    DISCORD_HINWEIS_GEZEIGT: bool = false, "discordHinweisGezeigt", Device, "Sources/Shared/AppModel.swift:2393";
    /// App version for which the rating question was last asked.
    BEWERTUNG_FASSUNG: Option<String> = (), "bewertungFassung", Device, "Sources/Shared/AppModel.swift:2383";
    /// Count of finished plays for the rating question.
    BEWERTUNG_FERTIG: i64 = 0, "bewertungFertig", Device, "Sources/Shared/AppModel.swift:2373";
    /// Synced by name, but no reader exists in the Swift code (see NOTES.md).
    RESTZEIT_ALS_ENDE: Option<bool> = (), "restzeitAlsEnde", Synced, "Packages/JellyfinKit/Sources/JellyfinKit/SettingsSync.swift:65";
    /// App version whose What's New sheet was seen (`WhatsNew.lastSeenKey`).
    WHATSNEW_LAST_SEEN: Option<String> = (), "whatsnew.lastSeen", Device, "Packages/JellyfinKit/Sources/JellyfinKit/WhatsNew.swift:81";

    // ---- Look ----
    /// Selected look (JSON data, `LookSelection`).
    LOOK_SELECTION: Option<Vec<u8>> = (), "look.selection", Device, "Sources/Shared/LookStore.swift:36";
    /// Owned looks (ids).
    LOOK_OWNED: Vec<String> = &[], "look.owned", Device, "Sources/Shared/LookStore.swift:37";
    /// Gift offers already made (`LookGiftSheet.swift:119-126`).
    LOOK_GIFT_OFFERED: Vec<String> = &[], "look.gift.offered", Device, "Sources/Shared/LookGiftSheet.swift:119";
    /// Look effects on.
    LOOK_EFFECTS: bool = true, "look.effects", Device, "Sources/Shared/LookStore.swift:39";
    /// Debug: force the seasonal look.
    LOOK_DEBUG_SEASON: bool = false, "look.debug.season", Device, "Sources/Shared/LookStore.swift:399";

    // ---- Support ----
    /// Support status (JSON; stored as data or string, read leniently).
    SUPPORT_STATUS: Option<Vec<u8>> = (), "support.status", Device, "Packages/JellyfinKit/Sources/JellyfinKit/SupportStatus.swift:159";
    /// Support usage (watched seconds, first launch; JSON).
    SUPPORT_USAGE: Option<Vec<u8>> = (), "support.usage", Device, "Packages/JellyfinKit/Sources/JellyfinKit/SupportStatus.swift:160";
    /// Support prompt history (sheet dates; JSON).
    SUPPORT_PROMPT_HISTORY: Option<Vec<u8>> = (), "support.promptHistory", Device, "Packages/JellyfinKit/Sources/JellyfinKit/SupportStatus.swift:161";
    /// Kind of support: monthly, lifetime or tip (`SupportStatus.swift:164-165`).
    SUPPORT_PLAN: Option<String> = (), "support.plan", Device, "Packages/JellyfinKit/Sources/JellyfinKit/SupportStatus.swift:164";
    /// Supporter key (`SupporterKeyKeeper.keyStorageKey`).
    SUPPORT_KEY: Option<String> = (), "support.key", Device, "Packages/JellyfinKit/Sources/SupportKeyKit/SupporterKeyKeeper.swift:43";
    /// When the supporter key was last checked (`SupporterKeyKeeper.checkedStorageKey`); stored type not documented.
    SUPPORT_KEY_CHECKED: Option<String> = (), "support.keyChecked", Device, "Packages/JellyfinKit/Sources/SupportKeyKit/SupporterKeyKeeper.swift:44";
    /// Supporter app icon raw value.
    SUPPORT_APP_ICON: Option<String> = (), "support.appIcon", Device, "Sources/Shared/SupportModel.swift:643";
    /// The profile intro of the support preview was shown (`SupportFlow.swift:42,139`).
    SUPPORT_PREVIEW_PROFILE_INTRO_SHOWN: bool = false, "support.preview.profileIntroShown", Device, "Sources/Shared/SupportFlow.swift:42";
    /// Debug: simulate purchases.
    SUPPORT_DEBUG_SIMULATE_PURCHASES: bool = false, "support.debug.simulatePurchases", Device, "Sources/Shared/SupportModel.swift:164";
}

// ---- Key families (a name plus a variable part) ----

/// Prefix of the remembered sort order per library: `sortierung.<library name>`
/// (`Sources/Shared/LibraryModel.swift:64-80`; the watchlist uses the library name `merkliste`,
/// `WatchlistModel.swift:34-42`).
pub const SORT_PREFIX: &str = "sortierung.";
/// Prefix of the remembered filter per library: `filter.<library name>` (`LibraryModel.swift:66-68`).
pub const FILTER_PREFIX: &str = "filter.";

/// `sortierung.<library>` (value: raw of `Sorting`).
pub fn sort_key(library: &str) -> String {
    format!("{SORT_PREFIX}{library}")
}

/// `filter.<library>` (value: raw of `LibraryFilter`).
pub fn filter_key(library: &str) -> String {
    format!("{FILTER_PREFIX}{library}")
}

/// The search history key: `letzteSuchen` without an account, `letzteSuchen.<account>` with one
/// (`SearchHistory.key(account:)`, `SearchHistory.swift:19-22`).
pub fn search_history_key(account: Option<&str>) -> String {
    match account {
        Some(a) if !a.is_empty() => format!("{}.{a}", LETZTE_SUCHEN.name),
        _ => LETZTE_SUCHEN.name.to_owned(),
    }
}

/// The key of one title inside `utJeTitel` / `tonJeTitel`: `<account>|<seriesId ?? id>`, or the bare
/// id without an account (`TrackRule.title(for:account:)`, `TrackRule.swift:186-191`).
pub fn track_rule_title_key(account: Option<&str>, series_id_or_id: &str) -> String {
    match account {
        Some(a) if !a.is_empty() => format!("{a}|{series_id_or_id}"),
        _ => series_id_or_id.to_owned(),
    }
}
