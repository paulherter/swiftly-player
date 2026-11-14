//! `SettingsVm`: the settings screens as sections and rows (`SettingsView.swift`,
//! `PlaybackSettingsView.swift`, `AppearanceView.swift`, tvOS `ProfileView.swift`).
//!
//! The rows carry the exact German keys of the Swift screens (translated here through
//! `swiftly-l10n`) and read and write through the settings store, so the Swift `@AppStorage`
//! views and the core see the same values. A row that is not shown cannot be written, a row
//! that is dimmed cannot be written either, and a choice must be one of the offered options.
//! Dependent rows (Wi-Fi only under Downloads, the bitrate under Direct Play) follow from the
//! stored values and the [`SettingsContext`] the host keeps current.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_l10n::{Arg, Locale, Translator};
use swiftly_library::StartRail;
use swiftly_rules::playback_selection::{BITRATE_LEVELS, SPAN_LEVELS, language_selection_all};
use swiftly_settings::options::BufferLevel;
use swiftly_settings::{Key, KeyValueStore, SettingValue, Settings, keys};

use crate::bell::{Bell, Changed};
use crate::downloads_vm::{decimal_separator, size_text};

/// Part bits of the settings view model (bell indices 0 and 1).
pub mod settings_part {
    /// The sections and rows.
    pub const SECTIONS: u32 = 1;
    /// The pending question.
    pub const STATUS: u32 = 2;
}

/// Which kind of device draws the screen; a few rows exist on one family only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Platform {
    /// iPhone, Android phone.
    #[default]
    Phone,
    /// iPad, Android tablet.
    Tablet,
    /// macOS, Windows, Linux.
    Desktop,
    /// Apple TV, Android TV.
    Tv,
}

/// What the connected server can do (`ServerCapability`); Jellyfin has all, Emby and Plex fewer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capabilities {
    /// Seerr requests.
    pub seerr: bool,
    /// Display preferences kept on the server (settings sync).
    pub settings_sync: bool,
    /// Offline downloads.
    pub downloads: bool,
}

impl Capabilities {
    /// A Jellyfin server.
    pub const ALL: Self = Self {
        seerr: true,
        settings_sync: true,
        downloads: true,
    };
}

/// What the host knows that the store does not. Send a new one whenever it changes.
#[derive(Debug, Clone, PartialEq)]
pub struct SettingsContext {
    /// Device family.
    pub platform: Platform,
    /// Server capabilities; rows of missing ones are not shown.
    pub capabilities: Capabilities,
    /// Per-server key suffix (`Session.serverSuffix`); empty without a session.
    pub server: String,
    /// The account may have the server convert video (`convertAllowed`).
    pub can_convert: bool,
    /// The "Gesehen von" plugin answered on this server.
    pub watchers_plugin: bool,
    /// Landscape can be locked here (not on iPad).
    pub landscape_lock_possible: bool,
    /// Seerr is signed in.
    pub seerr_connected: bool,
    /// Custom request headers for this server.
    pub own_headers: usize,
    /// Text for the subtitle-style row (`SubtitleLook.entryValue`).
    pub subtitle_look_summary: String,
    /// Finished and unfinished downloads on the device.
    pub stored_downloads: usize,
    /// Bytes of the finished ones.
    pub stored_bytes: i64,
    /// The account's own "next episode" choice, used while the setting was never set.
    pub account_next_auto: Option<bool>,
    /// Desktop shell only: "Server und Dienste" also gets the server line, "Verbindung prüfen" and Discord (the
    /// Apple apps draw the first two themselves and hide Discord in the sandbox; they never set this).
    pub server_rows: bool,
    /// The host can show what is playing on Discord. Without it the "Discord" row stays hidden, so no switch does
    /// nothing (the Mac hides it where its presence cannot work). The desktop shell has no presence client yet.
    pub discord_presence: bool,
    /// Name of the connected server (`AppModel.serverName`).
    pub server_name: Option<String>,
    /// Version of the connected server (`AppModel.serverVersion`).
    pub server_version: Option<String>,
    /// A connection check is running ("Moment…").
    pub checking: bool,
    /// The answer of the last check, shown as the second line.
    pub check_result: Option<String>,
}

impl Default for SettingsContext {
    fn default() -> Self {
        Self {
            platform: Platform::Phone,
            capabilities: Capabilities::ALL,
            server: String::new(),
            can_convert: true,
            watchers_plugin: false,
            landscape_lock_possible: true,
            seerr_connected: false,
            own_headers: 0,
            subtitle_look_summary: String::new(),
            stored_downloads: 0,
            stored_bytes: 0,
            account_next_auto: None,
            server_rows: false,
            discord_presence: false,
            server_name: None,
            server_version: None,
            checking: false,
            check_result: None,
        }
    }
}

/// One choice of a [`RowControl::Choice`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChoiceOption {
    /// What is stored and sent back in [`SettingsIntent::SetChoice`].
    pub value: String,
    /// Display text.
    pub label: String,
}

/// What a row does.
#[derive(Debug, Clone, PartialEq)]
pub enum RowControl {
    /// A switch.
    Switch {
        /// Current state.
        on: bool,
    },
    /// A list to pick from.
    Choice {
        /// The stored value of the current choice.
        selected: String,
        /// Its display text (the row's value).
        shown: String,
        /// All options in order.
        options: Vec<ChoiceOption>,
    },
    /// A value that cannot be changed here.
    Info {
        /// The value text.
        value: String,
    },
    /// Opens a page of its own.
    Link {
        /// Value text beside the chevron.
        value: Option<String>,
    },
}

/// One row.
#[derive(Debug, Clone, PartialEq)]
pub struct Row {
    /// The persisted key (or a page name for links).
    pub key: &'static str,
    /// German key of the title.
    pub title_key: &'static str,
    /// Title text.
    pub title: String,
    /// Second line.
    pub under: Option<String>,
    /// The control.
    pub control: RowControl,
    /// Dimmed rows show their value but cannot be changed.
    pub enabled: bool,
}

/// A group of rows with a heading.
#[derive(Debug, Clone, PartialEq)]
pub struct Section {
    /// German key of the heading.
    pub title_key: &'static str,
    /// Heading text.
    pub title: String,
    /// The rows.
    pub rows: Vec<Row>,
}

/// All sections.
#[derive(Debug, Clone, PartialEq)]
pub struct SectionsPart {
    /// Version of the view model when the part was replaced.
    pub version: u64,
    /// The sections in display order.
    pub sections: Vec<Section>,
}

/// A question the view has to put to the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Confirm {
    /// Turning Downloads off while titles are stored: keep them or delete them.
    DisableDownloads,
}

/// The pending question, if any.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsStatusPart {
    /// Version of the view model when the part was replaced.
    pub version: u64,
    /// Unanswered question.
    pub confirm: Option<Confirm>,
}

/// What the view sends.
#[derive(Debug, Clone, PartialEq)]
pub enum SettingsIntent {
    /// Flip a switch.
    SetSwitch {
        /// The row's key.
        key: String,
        /// The new state.
        on: bool,
    },
    /// Pick an option.
    SetChoice {
        /// The row's key.
        key: String,
        /// The option's value.
        value: String,
    },
    /// Answer [`Confirm::DisableDownloads`]; `delete` also removes the stored titles.
    ConfirmDisableDownloads {
        /// Delete the titles too.
        delete: bool,
    },
    /// Leave the question unanswered, nothing changes.
    CancelConfirm,
    /// New host facts.
    Context(Box<SettingsContext>),
    /// The store was changed from outside (for example by `@AppStorage` or a sync).
    Reload,
    /// Move a Home row of the Appearance page up (`delta` -1) or down (+1) among the rows that are shown (the Mac's
    /// "Nach oben" / "Nach unten").
    MoveRow {
        /// The row's key (`startRow.<raw>`).
        key: String,
        /// -1 up, +1 down.
        delta: i32,
    },
    /// An edit of the Home rows or the genres of the Appearance page (libraries, genres, drag and drop).
    Home(HomeEdit),
}

/// What the Home group and the Genres group of the Appearance page can do besides the switches.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HomeEdit {
    /// Move a row up (-1) or down (+1) among the shown ones (`id` as in the combined order).
    Shift {
        /// The row's id.
        id: String,
        /// -1 up, +1 down.
        delta: i32,
    },
    /// Drop a row onto another (the dragged row takes its place).
    Drop {
        /// The dragged row's id.
        source: String,
        /// The row it landed on.
        onto: String,
    },
    /// Add a library or collection as a Home row.
    AddLibrary(swiftly_library::start_libraries::StartLibrary),
    /// Remove a chosen library by its server id.
    RemoveLibrary(String),
    /// Add a genre.
    AddGenre(String),
    /// Remove a genre.
    RemoveGenre(String),
    /// Drop a genre onto another.
    DropGenre {
        /// The dragged genre.
        source: String,
        /// The genre it landed on.
        onto: String,
    },
}

/// Why an intent was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Rejected {
    /// No such row.
    UnknownKey,
    /// The row is not shown, or is dimmed.
    NotAllowed,
    /// The value is not one of the options, or the intent does not fit the row.
    InvalidValue,
    /// The store could not write.
    Store(String),
}

/// What the host must do after a change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SettingsEffect {
    /// A key was written; a synced one should go to the server.
    Changed {
        /// The persisted key.
        key: String,
        /// Whether the settings sync carries it.
        synced: bool,
    },
    /// Downloads were switched; the manager observes the network or pauses everything.
    DownloadsSwitched {
        /// New state.
        on: bool,
    },
    /// Remove every stored download.
    DeleteDownloads,
}

type EffectSink = Arc<dyn Fn(SettingsEffect) + Send + Sync>;

struct Live {
    context: SettingsContext,
    confirm: Option<Confirm>,
}

/// What the view reads. Behind its own small lock that is never held across the store: the store is a foreign
/// callback (a write can take a while), and a reader must not wait for it.
struct Shown {
    sections: Arc<SectionsPart>,
    status: Arc<SettingsStatusPart>,
}

struct Inner<S: KeyValueStore> {
    settings: Settings<S>,
    translator: Translator,
    sink: EffectSink,
    bell: Arc<Bell>,
    live: Mutex<Live>,
    shown: Mutex<Shown>,
}

/// The settings view model. Cheap to clone (a handle).
pub struct SettingsVm<S: KeyValueStore + 'static> {
    inner: Arc<Inner<S>>,
}

impl<S: KeyValueStore + 'static> Clone for SettingsVm<S> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl<S: KeyValueStore + 'static> SettingsVm<S> {
    /// A view model over `store`. `sink` receives the [`SettingsEffect`]s.
    pub fn new(
        store: S,
        locale: Locale,
        context: SettingsContext,
        sink: impl Fn(SettingsEffect) + Send + Sync + 'static,
    ) -> Self {
        let inner = Arc::new(Inner {
            settings: Settings::new(store),
            translator: Translator::new(locale),
            sink: Arc::new(sink),
            bell: Bell::new(),
            live: Mutex::new(Live {
                context,
                confirm: None,
            }),
            shown: Mutex::new(Shown {
                sections: Arc::new(SectionsPart {
                    version: 1,
                    sections: Vec::new(),
                }),
                status: Arc::new(SettingsStatusPart {
                    version: 1,
                    confirm: None,
                }),
            }),
        });
        {
            let mut live = inner.live();
            inner.publish(&mut live);
        }
        Self { inner }
    }

    /// The version; moves whenever a part is replaced.
    pub fn version(&self) -> u64 {
        self.inner.bell.version()
    }

    /// The sections and rows.
    pub fn sections(&self) -> Arc<SectionsPart> {
        Arc::clone(&self.inner.shown().sections)
    }

    /// The Home rows and the chosen genres of the Appearance page, as stored for the current server.
    pub fn home(&self) -> crate::home_rows::HomeView {
        let server = self.inner.live().context.server.clone();
        crate::home_rows::view(&self.inner.settings, &server)
    }

    /// The pending question.
    pub fn status(&self) -> Arc<SettingsStatusPart> {
        Arc::clone(&self.inner.shown().status)
    }

    /// Resolves when the version moves past `seen`.
    pub fn changed(&self, seen: u64) -> Changed {
        self.inner.bell.changed(seen)
    }

    /// An intent from the view. Returns at once; a refused intent changes nothing.
    ///
    /// # Errors
    /// [`Rejected`] when the row is unknown, hidden or dimmed, or the value is not offered.
    pub fn send(&self, intent: SettingsIntent) -> Result<(), Rejected> {
        let inner = &self.inner;
        // The sink may call back into the view model; it runs after the lock is released.
        let mut effects = Vec::new();
        let result = {
            let mut live = inner.live();
            let result = match intent {
                SettingsIntent::SetSwitch { key, on } => {
                    inner.set_switch(&mut live, &key, on, &mut effects)
                }
                SettingsIntent::SetChoice { key, value } => {
                    inner.set_choice(&live, &key, &value, &mut effects)
                }
                SettingsIntent::ConfirmDisableDownloads { delete } => {
                    inner.confirm_disable(&mut live, delete, &mut effects)
                }
                SettingsIntent::CancelConfirm => {
                    live.confirm = None;
                    Ok(())
                }
                SettingsIntent::Context(context) => {
                    live.context = *context;
                    Ok(())
                }
                SettingsIntent::Reload => Ok(()),
                SettingsIntent::MoveRow { key, delta } => {
                    inner.move_row(&live, &key, delta, &mut effects)
                }
                SettingsIntent::Home(edit) => inner.edit_home(&live, &edit, &mut effects),
            };
            inner.publish(&mut live);
            result
        };
        for effect in effects {
            (inner.sink)(effect);
        }
        result
    }
}

/// The key of the Home row `rail` on the Appearance page.
fn start_row_key(rail: StartRail) -> &'static str {
    match rail {
        StartRail::ContinueWatching => "startRow.weiterschauen",
        StartRail::NextEpisode => "startRow.naechsteFolge",
        StartRail::NewMovies => "startRow.neueFilme",
        StartRail::NewSeries => "startRow.neueSerien",
        StartRail::NewArrivals => "startRow.neuzugaenge",
    }
}

fn start_rail_of(key: &str) -> Option<StartRail> {
    StartRail::ALL
        .into_iter()
        .find(|r| start_row_key(*r) == key)
}

fn find<'a>(sections: &'a [Section], key: &str) -> Option<&'a Row> {
    sections.iter().flat_map(|s| &s.rows).find(|r| r.key == key)
}

fn store_error(e: &impl std::fmt::Display) -> Rejected {
    Rejected::Store(e.to_string())
}

impl<S: KeyValueStore + 'static> Inner<S> {
    fn live(&self) -> MutexGuard<'_, Live> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn shown(&self) -> MutexGuard<'_, Shown> {
        self.shown.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn t(&self, key: &str) -> String {
        self.translator.t(key)
    }

    fn get<T: SettingValue>(&self, key: &Key<T>) -> T {
        self.settings.get(key)
    }

    fn put<T: SettingValue>(
        &self,
        key: &Key<T>,
        value: T,
        fx: &mut Vec<SettingsEffect>,
    ) -> Result<(), Rejected> {
        self.settings.set(key, value).map_err(|e| store_error(&e))?;
        fx.push(SettingsEffect::Changed {
            key: key.name.to_owned(),
            synced: key.scope.is_synced(),
        });
        Ok(())
    }

    fn put_server<T: SettingValue>(
        &self,
        key: &Key<T>,
        server: &str,
        value: T,
        fx: &mut Vec<SettingsEffect>,
    ) -> Result<(), Rejected> {
        self.settings
            .set_for_server(key, server, value)
            .map_err(|e| store_error(&e))?;
        fx.push(SettingsEffect::Changed {
            key: key.name.to_owned(),
            synced: key.scope.is_synced(),
        });
        Ok(())
    }

    /// Replaces the parts whose content changed and rings the bell once.
    fn publish(&self, live: &mut Live) {
        let sections = self.build(&live.context);
        let (old_sections, old_status) = {
            let shown = self.shown();
            (Arc::clone(&shown.sections), Arc::clone(&shown.status))
        };
        let mut changed = Vec::new();
        if sections != old_sections.sections {
            changed.push(0);
        }
        if live.confirm != old_status.confirm {
            changed.push(1);
        }
        if changed.is_empty() {
            return;
        }
        let version = self.bell.bump(&changed);
        let mut shown = self.shown();
        if changed.contains(&0) {
            shown.sections = Arc::new(SectionsPart { version, sections });
        }
        if changed.contains(&1) {
            shown.status = Arc::new(SettingsStatusPart {
                version,
                confirm: live.confirm,
            });
        }
        const { assert!(settings_part::SECTIONS == 1 << 0 && settings_part::STATUS == 1 << 1) };
    }

    // MARK: Intents

    fn row(&self, live: &Live, key: &str) -> Result<Row, Rejected> {
        let sections = self.build(&live.context);
        let row = find(&sections, key).ok_or_else(|| {
            if known_key(key) {
                Rejected::NotAllowed
            } else {
                Rejected::UnknownKey
            }
        })?;
        if !row.enabled {
            return Err(Rejected::NotAllowed);
        }
        Ok(row.clone())
    }

    fn set_switch(
        &self,
        live: &mut Live,
        key: &str,
        on: bool,
        fx: &mut Vec<SettingsEffect>,
    ) -> Result<(), Rejected> {
        let row = self.row(live, key)?;
        if !matches!(row.control, RowControl::Switch { .. }) {
            return Err(Rejected::InvalidValue);
        }
        let server = live.context.server.clone();
        match key {
            "immerDirectPlay" => self.put_server(&keys::IMMER_DIRECT_PLAY, &server, on, fx),
            "naechsteAuto" => self.put(&keys::NAECHSTE_AUTO, Some(on), fx),
            _ if start_rail_of(key).is_some() => {
                // A Home row on or off (`startAus` lists the rows that are off).
                let raw = start_rail_of(key).map_or("", StartRail::raw_value);
                let mut off = self.get(&keys::START_AUS);
                off.retain(|r| r != raw);
                if !on {
                    off.push(raw.to_owned());
                }
                self.put(&keys::START_AUS, off, fx)
            }
            "downloadsAn" => {
                // Turning off deletes nothing unasked; with nothing stored there is nothing to ask.
                if !on && live.context.stored_downloads > 0 {
                    live.confirm = Some(Confirm::DisableDownloads);
                    return Ok(());
                }
                self.put(&keys::DOWNLOADS_AN, on, fx)?;
                fx.push(SettingsEffect::DownloadsSwitched { on });
                Ok(())
            }
            _ => {
                let k = bool_key(key).ok_or(Rejected::UnknownKey)?;
                self.put(k, on, fx)
            }
        }
    }

    fn confirm_disable(
        &self,
        live: &mut Live,
        delete: bool,
        fx: &mut Vec<SettingsEffect>,
    ) -> Result<(), Rejected> {
        if live.confirm.take() != Some(Confirm::DisableDownloads) {
            return Err(Rejected::NotAllowed);
        }
        self.put(&keys::DOWNLOADS_AN, false, fx)?;
        fx.push(SettingsEffect::DownloadsSwitched { on: false });
        if delete {
            fx.push(SettingsEffect::DeleteDownloads);
            live.context.stored_downloads = 0;
            live.context.stored_bytes = 0;
        }
        Ok(())
    }

    /// The combined order of the Home rows as the core heals it: stored ids that exist (fixed rows that fit now and
    /// `library:` rows), then every missing fixed row in basic order.
    fn home_order(&self, server: &str) -> Vec<String> {
        let disconnected = self.get(&keys::NEU_GETRENNT);
        let mut order: Vec<String> = Vec::new();
        for id in self
            .settings
            .get_for_server(&keys::START_REIHENFOLGE, server)
        {
            let known = StartRail::from_raw(&id).is_some_and(|r| r.fits(disconnected))
                || id.starts_with("library:");
            if known && !order.contains(&id) {
                order.push(id);
            }
        }
        for rail in StartRail::ALL.into_iter().filter(|r| r.fits(disconnected)) {
            let raw = rail.raw_value().to_owned();
            if !order.contains(&raw) {
                // Missing fixed rows go before the first library row.
                let at = order
                    .iter()
                    .position(|o| o.starts_with("library:"))
                    .unwrap_or(order.len());
                order.insert(at, raw);
            }
        }
        order
    }

    /// The edits of the Home rows and genres; each one that changes something reports the keys it wrote.
    fn edit_home(
        &self,
        live: &Live,
        edit: &HomeEdit,
        fx: &mut Vec<SettingsEffect>,
    ) -> Result<(), Rejected> {
        use crate::home_rows as h;
        let server = live.context.server.clone();
        let settings = &self.settings;
        let (moved, names): (bool, &[&str]) = match edit {
            HomeEdit::Shift { id, delta } => (
                h::shift_row(settings, &server, id, *delta).map_err(|e| store_error(&e))?,
                &["startReihenfolge", "startReihen"],
            ),
            HomeEdit::Drop { source, onto } => (
                h::drop_row(settings, &server, source, onto).map_err(|e| store_error(&e))?,
                &["startReihenfolge", "startReihen"],
            ),
            HomeEdit::AddLibrary(l) => {
                h::add_library(settings, &server, l.clone()).map_err(|e| store_error(&e))?;
                (true, &["startBibliotheken"])
            }
            HomeEdit::RemoveLibrary(id) => {
                h::remove_library(settings, &server, id).map_err(|e| store_error(&e))?;
                (true, &["startBibliotheken"])
            }
            HomeEdit::AddGenre(g) => {
                h::add_genre(settings, g).map_err(|e| store_error(&e))?;
                (true, &["startGenres"])
            }
            HomeEdit::RemoveGenre(g) => {
                h::remove_genre(settings, g).map_err(|e| store_error(&e))?;
                (true, &["startGenres"])
            }
            HomeEdit::DropGenre { source, onto } => (
                h::drop_genre(settings, source, onto).map_err(|e| store_error(&e))?,
                &["startGenres"],
            ),
        };
        if moved {
            for name in names {
                let synced = *name != "startReihenfolge";
                fx.push(SettingsEffect::Changed {
                    key: (*name).to_owned(),
                    synced,
                });
            }
        }
        Ok(())
    }

    fn move_row(
        &self,
        live: &Live,
        key: &str,
        delta: i32,
        fx: &mut Vec<SettingsEffect>,
    ) -> Result<(), Rejected> {
        let rail = start_rail_of(key).ok_or(Rejected::UnknownKey)?;
        let server = live.context.server.clone();
        let mut order = self.home_order(&server);
        let shown: Vec<String> = order
            .iter()
            .filter(|o| StartRail::from_raw(o).is_some())
            .cloned()
            .collect();
        let Some(pos) = shown.iter().position(|s| s == rail.raw_value()) else {
            return Err(Rejected::NotAllowed);
        };
        let target = i64::try_from(pos).unwrap_or(0) + i64::from(delta);
        let Some(other) = usize::try_from(target).ok().and_then(|t| shown.get(t)) else {
            return Ok(());
        };
        let (a, b) = (
            order.iter().position(|o| o == rail.raw_value()),
            order.iter().position(|o| o == other),
        );
        if let (Some(a), Some(b)) = (a, b) {
            order.swap(a, b);
        }
        // The fixed rows' own list follows (`AppModel.storeOrder`).
        let fixed: Vec<String> = order
            .iter()
            .filter(|o| StartRail::from_raw(o).is_some())
            .cloned()
            .collect();
        self.put_server(&keys::START_REIHENFOLGE, &server, order, fx)?;
        self.put(&keys::START_REIHEN, fixed, fx)
    }

    fn set_choice(
        &self,
        live: &Live,
        key: &str,
        value: &str,
        fx: &mut Vec<SettingsEffect>,
    ) -> Result<(), Rejected> {
        let row = self.row(live, key)?;
        let RowControl::Choice { options, .. } = &row.control else {
            return Err(Rejected::InvalidValue);
        };
        if !options.iter().any(|o| o.value == value) {
            return Err(Rejected::InvalidValue);
        }
        let number = || value.parse::<i64>().map_err(|_| Rejected::InvalidValue);
        match key {
            "zurueckSek" => self.put(&keys::ZURUECK_SEK, number()?, fx),
            "vorSek" => self.put(&keys::VOR_SEK, number()?, fx),
            "bitratenGrenze" => {
                self.put_server(&keys::BITRATEN_GRENZE, &live.context.server, number()?, fx)
            }
            "tonSprache" => self.put(&keys::TON_SPRACHE, value.to_owned(), fx),
            "utSprache" => {
                self.put(&keys::UT_SPRACHE, value.to_owned(), fx)?;
                // Choosing a language switches "automatic" on (on its own the language did nothing
                // while the switch stayed off, so a chosen language never showed at the start).
                if !value.is_empty() && !self.get(&keys::UT_AUTO) {
                    self.put(&keys::UT_AUTO, true, fx)?;
                }
                Ok(())
            }
            "pufferstufe" => self.put(&keys::PUFFERSTUFE, value.to_owned(), fx),
            "genreChips" => self.put(&keys::GENRE_CHIPS, value == "chips", fx),
            _ => Err(Rejected::UnknownKey),
        }
    }

    // MARK: Building

    fn switch(
        &self,
        key: &'static str,
        title_key: &'static str,
        under: Option<&str>,
        on: bool,
    ) -> Row {
        Row {
            key,
            title_key,
            title: self.t(title_key),
            under: under.map(|u| self.t(u)),
            control: RowControl::Switch { on },
            enabled: true,
        }
    }

    fn choice(
        &self,
        key: &'static str,
        title_key: &'static str,
        options: Vec<ChoiceOption>,
        selected: &str,
    ) -> Row {
        let shown = options
            .iter()
            .find(|o| o.value == selected)
            .map(|o| o.label.clone())
            .unwrap_or_default();
        Row {
            key,
            title_key,
            title: self.t(title_key),
            under: None,
            control: RowControl::Choice {
                selected: selected.to_owned(),
                shown,
                options,
            },
            enabled: true,
        }
    }

    fn seconds_options(&self) -> Vec<ChoiceOption> {
        SPAN_LEVELS
            .iter()
            .map(|v| ChoiceOption {
                value: v.to_string(),
                label: format!("{v} s"),
            })
            .collect()
    }

    fn bitrate_options(&self) -> Vec<ChoiceOption> {
        BITRATE_LEVELS
            .iter()
            .map(|&v| ChoiceOption {
                value: v.to_string(),
                label: if v == 0 {
                    self.t("Unbegrenzt")
                } else {
                    self.translator.t_args("%lld Mbit/s", &[Arg::Int(v)])
                },
            })
            .collect()
    }

    fn language_options(&self, empty: &str) -> Vec<ChoiceOption> {
        language_selection_all(&self.t(empty))
            .into_iter()
            .map(|l| ChoiceOption {
                value: l.value,
                label: l.name,
            })
            .collect()
    }

    fn section(&self, title_key: &'static str, rows: Vec<Row>) -> Section {
        Section {
            title_key,
            title: self.t(title_key),
            rows,
        }
    }

    /// Every section for the current store and context; sections without rows are left out.
    fn build(&self, c: &SettingsContext) -> Vec<Section> {
        let tv = c.platform == Platform::Tv;
        // The Mac wording and grouping (`PlaybackSettingsView.swift`, `AppearanceView.swift`, `SettingsView.swift` in
        // `Sources/macOS`) differ from the iPhone's; only the desktop shell asks for them (`SettingsContext::server_rows`).
        let desk = c.server_rows;
        let mut out = Vec::new();

        // Playback: quality.
        let direct_play = self
            .settings
            .get_for_server(&keys::IMMER_DIRECT_PLAY, &c.server)
            || !c.can_convert;
        let mut direct = self.switch(
            "immerDirectPlay",
            "Immer Direct Play",
            Some(if desk {
                "Der Server wandelt nie um, es läuft immer die Originaldatei"
            } else {
                "Der Server wandelt nie um"
            }),
            direct_play,
        );
        direct.enabled = c.can_convert;
        let limit = self
            .settings
            .get_for_server(&keys::BITRATEN_GRENZE, &c.server);
        let mut bitrate = self.choice(
            "bitratenGrenze",
            "Höchste Bitrate",
            self.bitrate_options(),
            &limit.to_string(),
        );
        if direct_play {
            // The Mac row has no second line, it is only dimmed.
            bitrate.under = (!desk).then(|| self.t("Nicht nötig bei Direct Play"));
            bitrate.enabled = false;
        }
        let mut quality = vec![direct, bitrate];
        if tv {
            let level = self.settings.buffer_level();
            quality.push(
                self.choice(
                    "pufferstufe",
                    "Puffer",
                    BufferLevel::ALL
                        .iter()
                        .map(|l| ChoiceOption {
                            value: l.raw().to_owned(),
                            label: match l {
                                // The buffer level reads the package wording in Swift ("Обычная" in Russian).
                                BufferLevel::Normal => self.translator.t_package("Normal"),
                                BufferLevel::Bad => self.t("Schlecht"),
                            },
                        })
                        .collect(),
                    level.raw(),
                ),
            );
            quality.push(self.switch(
                "bildrateAnpassen",
                "Bildrate an den Film anpassen",
                None,
                self.get(&keys::BILDRATE_ANPASSEN),
            ));
        }
        out.push(self.section("Qualität", quality));

        // Playback: language.
        let audio: String = self.get(&keys::TON_SPRACHE);
        let subtitle: String = self.get(&keys::UT_SPRACHE);
        let look_title = if desk {
            "Aussehen der Untertitel"
        } else {
            "Untertitel-Stil"
        };
        let look = Row {
            key: "utAussehen",
            title_key: look_title,
            title: self.t(look_title),
            under: None,
            control: RowControl::Link {
                value: Some(c.subtitle_look_summary.clone()),
            },
            enabled: true,
        };
        out.push(self.section(
            "Sprache",
            vec![
                self.choice(
                    "tonSprache",
                    "Ton",
                    self.language_options("Wie die Datei"),
                    &audio,
                ),
                self.choice(
                    "utSprache",
                    "Untertitel",
                    self.language_options("Aus"),
                    &subtitle,
                ),
                self.switch(
                    "utAuto",
                    "Untertitel automatisch",
                    Some(if desk {
                        "Nur wenn der Ton nicht in der gewählten Sprache läuft"
                    } else {
                        "Wenn der Ton nicht deine Sprache ist"
                    }),
                    self.get(&keys::UT_AUTO),
                ),
                look,
            ],
        ));

        // Playback: flow and player.
        let next_auto = self
            .get(&keys::NAECHSTE_AUTO)
            .or(c.account_next_auto)
            .unwrap_or(true);
        if desk {
            // One group "Verhalten", in the Mac order, the switches without a second line (`behavior`).
            let seconds = |key: &'static str, title: &'static str, k: &'static Key<i64>| {
                self.choice(key, title, self.seconds_options(), &self.get(k).to_string())
            };
            out.push(self.section(
                "Verhalten",
                vec![
                    self.switch("naechsteAuto", "Nächste Folge automatisch", None, next_auto),
                    self.switch(
                        "introAbspannAuto",
                        "Intro und Abspann automatisch überspringen",
                        None,
                        self.get(&keys::INTRO_ABSPANN_AUTO),
                    ),
                    self.switch(
                        "technikschild",
                        "Technische Daten im Player",
                        None,
                        self.get(&keys::TECHNIKSCHILD),
                    ),
                    self.switch(
                        "endzeitImPlayer",
                        "Endzeit im Player",
                        None,
                        self.get(&keys::ENDZEIT_IM_PLAYER),
                    ),
                    seconds("zurueckSek", "Zurückspulen", &keys::ZURUECK_SEK),
                    seconds("vorSek", "Vorspulen", &keys::VOR_SEK),
                ],
            ));
        } else {
            out.push(self.section(
                "Ablauf",
                vec![
                    self.switch("naechsteAuto", "Nächste Folge automatisch", None, next_auto),
                    self.switch(
                        "introAbspannAuto",
                        "Intro und Abspann",
                        Some("Werden automatisch übersprungen"),
                        self.get(&keys::INTRO_ABSPANN_AUTO),
                    ),
                ],
            ));
            let mut player = vec![
                self.choice(
                    "zurueckSek",
                    "Zurückspulen",
                    self.seconds_options(),
                    &self.get(&keys::ZURUECK_SEK).to_string(),
                ),
                self.choice(
                    "vorSek",
                    "Vorspulen",
                    self.seconds_options(),
                    &self.get(&keys::VOR_SEK).to_string(),
                ),
            ];
            if c.landscape_lock_possible && !tv && !desk {
                player.push(self.switch(
                    "querformatFest",
                    "Querformat sperren",
                    None,
                    self.get(&keys::QUERFORMAT_FEST),
                ));
            }
            player.push(self.switch(
                "technikschild",
                "Technische Daten",
                Some("Zeigt Format und Bitrate im Player"),
                self.get(&keys::TECHNIKSCHILD),
            ));
            player.push(self.switch(
                "endzeitImPlayer",
                "Endzeit im Player",
                Some("Zeigt, wann der Titel endet"),
                self.get(&keys::ENDZEIT_IM_PLAYER),
            ));
            out.push(self.section("Im Player", player));
        }

        // Appearance and home.
        let mut look_rows = vec![
            self.switch(
                "fortschritt",
                "Fortschritt auf Kacheln",
                None,
                self.get(&keys::FORTSCHRITT),
            ),
            self.switch(
                "merklisteAn",
                "Merkliste",
                Some(if desk {
                    "Seite, Filter und Knopf auf Film- und Serienseiten"
                } else {
                    "Auf Film- und Serienseiten"
                }),
                self.get(&keys::MERKLISTE_AN),
            ),
        ];
        if c.watchers_plugin {
            look_rows.push(self.switch(
                "gesehenVonAn",
                "Gesehen von",
                Some("Zeigt auf Titelseiten, wer einen Titel gesehen hat"),
                self.get(&keys::GESEHEN_VON_AN),
            ));
        }
        look_rows.push(self.switch(
            "alphabetAn",
            if desk {
                "Alphabetische Suche in Listen"
            } else {
                "Alphabet in Listen"
            },
            None,
            self.get(&keys::ALPHABET_AN),
        ));
        look_rows.push(self.switch(
            "titelAlsLogo",
            "Titel als Logo",
            Some(if desk {
                "Auf Film- und Serienseiten, wenn dein Server eins hat"
            } else {
                "Wenn dein Server eins hat"
            }),
            self.get(&keys::TITEL_ALS_LOGO),
        ));
        out.push(self.section(
            if desk {
                "Allgemein"
            } else {
                "Filme und Serien"
            },
            look_rows,
        ));

        let chips = self.get(&keys::GENRE_CHIPS);
        let separate = self.switch(
            "neuGetrennt",
            "Neuzugänge getrennt",
            Some(if desk {
                "Neue Filme und neue Serien als eigene Reihen"
            } else {
                "Als eigene Reihen"
            }),
            self.get(&keys::NEU_GETRENNT),
        );
        let form = self.choice(
            "genreChips",
            "Form",
            vec![
                ChoiceOption {
                    value: "rails".to_owned(),
                    label: self.t("Als eigene Reihen"),
                },
                ChoiceOption {
                    value: "chips".to_owned(),
                    label: self.t("Als Chips über den Reihen"),
                },
            ],
            if chips { "chips" } else { "rails" },
        );
        if desk {
            // The Mac has the groups "Startseite" (the rows, on or off, in the stored order), "Neuzugänge" and
            // "Genres" (`AppearanceView.swift`).
            let disconnected = self.get(&keys::NEU_GETRENNT);
            let off = self.get(&keys::START_AUS);
            let rows: Vec<Row> = self
                .home_order(&c.server)
                .iter()
                .filter_map(|id| StartRail::from_raw(id))
                .filter(|r| r.fits(disconnected))
                .map(|r| {
                    self.switch(
                        start_row_key(r),
                        r.lists_name(),
                        None,
                        !off.iter().any(|o| o == r.raw_value()),
                    )
                })
                .collect();
            out.push(self.section("Startseite", rows));
            out.push(self.section("Neuzugänge", vec![separate]));
            out.push(self.section("Genres", vec![form]));
        } else {
            out.push(self.section("Startseite", vec![separate, form]));
        }

        if tv {
            out.push(self.section(
                "Profil",
                vec![self.switch(
                    "askProfileAtLaunch",
                    "Beim Start fragen, wer schaut",
                    None,
                    self.get(&keys::ASK_PROFILE_AT_LAUNCH),
                )],
            ));
        }

        // Offline.
        if c.capabilities.downloads {
            let on = self.get(&keys::DOWNLOADS_AN);
            let mut rows = vec![self.switch(
                "downloadsAn",
                "Downloads",
                Some("Titel offline schauen"),
                on,
            )];
            if on {
                rows.push(self.switch(
                    "nurUeberWLAN",
                    "Nur über WLAN",
                    Some(if desk {
                        "Downloads warten, bis du im WLAN bist"
                    } else {
                        "Downloads warten auf WLAN"
                    }),
                    self.get(&keys::NUR_UEBER_WLAN),
                ));
                rows.push(self.switch(
                    "naechsteFolgeLaden",
                    if desk {
                        "Nächste Folge laden"
                    } else {
                        "Nächste Folge vorab laden"
                    },
                    Some("Lädt die nächste, löscht die gesehene"),
                    self.get(&keys::NAECHSTE_FOLGE_LADEN),
                ));
                // Not "Mac": the same app runs on Linux and Windows (the catalog key of the phone and the profile row).
                let place = "%lld Titel auf diesem Gerät";
                let count = i64::try_from(c.stored_downloads).unwrap_or(i64::MAX);
                rows.push(Row {
                    key: "downloadsSpeicher",
                    title_key: "Speicher",
                    title: self.t("Speicher"),
                    under: Some(self.translator.t_args(place, &[Arg::Int(count)])),
                    control: RowControl::Info {
                        value: size_text(
                            c.stored_bytes,
                            decimal_separator(self.translator.locale().language()),
                        ),
                    },
                    enabled: true,
                });
            }
            out.push(self.section("Offline", rows));
        }

        // Server and services.
        let mut services = Vec::new();
        if c.server_rows {
            // `SettingsView.swift` (macOS) `server`: the server line and the check come first.
            services.push(Row {
                key: "serverInfo",
                title_key: "Server",
                title: c.server_name.clone().unwrap_or_else(|| self.t("Server")),
                under: None,
                control: RowControl::Info {
                    value: c.server_version.clone().unwrap_or_else(|| "?".to_owned()),
                },
                enabled: true,
            });
            services.push(Row {
                key: "verbindungPruefen",
                title_key: "Verbindung prüfen",
                title: self.t("Verbindung prüfen"),
                under: c.check_result.clone(),
                control: RowControl::Link {
                    value: c.checking.then(|| self.t("Moment…")),
                },
                enabled: !c.checking,
            });
        }
        services.push(Row {
            key: "eigeneHeader",
            title_key: "Eigene Header",
            title: self.t("Eigene Header"),
            under: Some(self.t("Für einen Dienst vor dem Server")),
            control: RowControl::Link {
                value: (c.own_headers > 0).then(|| c.own_headers.to_string()),
            },
            enabled: true,
        });
        if c.capabilities.seerr {
            services.push(Row {
                key: "seerr",
                title_key: "Seerr",
                title: self.t("Seerr"),
                under: Some(self.t("Anfragen, was noch nicht da ist")),
                control: RowControl::Link {
                    value: c.seerr_connected.then(|| self.t("Verbunden")),
                },
                enabled: true,
            });
        }
        if c.server_rows && c.discord_presence {
            // Offered only where presence works (`serviceRows`).
            services.push(self.switch(
                "discordAnzeigen",
                "Discord",
                Some("Zeigt im Profil, was gerade läuft"),
                self.get(&keys::DISCORD_ANZEIGEN),
            ));
        }
        out.push(self.section("Server und Dienste", services));

        if c.capabilities.settings_sync {
            out.push(self.section(
                "Synchronisierung",
                vec![self.switch(
                    "einstellungenSync",
                    "Auf allen Geräten gleich",
                    Some("Liegt auf deinem Server"),
                    self.get(&keys::EINSTELLUNGEN_SYNC),
                )],
            ));
        }
        out
    }
}

/// The plain boolean keys a switch row can write.
fn bool_key(name: &str) -> Option<&'static Key<bool>> {
    Some(match name {
        "technikschild" => &keys::TECHNIKSCHILD,
        "discordAnzeigen" => &keys::DISCORD_ANZEIGEN,
        "introAbspannAuto" => &keys::INTRO_ABSPANN_AUTO,
        "endzeitImPlayer" => &keys::ENDZEIT_IM_PLAYER,
        "querformatFest" => &keys::QUERFORMAT_FEST,
        "bildrateAnpassen" => &keys::BILDRATE_ANPASSEN,
        "utAuto" => &keys::UT_AUTO,
        "titelAlsLogo" => &keys::TITEL_ALS_LOGO,
        "fortschritt" => &keys::FORTSCHRITT,
        "merklisteAn" => &keys::MERKLISTE_AN,
        "alphabetAn" => &keys::ALPHABET_AN,
        "gesehenVonAn" => &keys::GESEHEN_VON_AN,
        "neuGetrennt" => &keys::NEU_GETRENNT,
        "askProfileAtLaunch" => &keys::ASK_PROFILE_AT_LAUNCH,
        "nurUeberWLAN" => &keys::NUR_UEBER_WLAN,
        "naechsteFolgeLaden" => &keys::NAECHSTE_FOLGE_LADEN,
        "einstellungenSync" => &keys::EINSTELLUNGEN_SYNC,
        _ => return None,
    })
}

/// Whether a key name belongs to some row on some device (so "not shown" differs from "unknown").
fn known_key(name: &str) -> bool {
    bool_key(name).is_some()
        || matches!(
            name,
            "immerDirectPlay"
                | "naechsteAuto"
                | "downloadsAn"
                | "zurueckSek"
                | "vorSek"
                | "bitratenGrenze"
                | "tonSprache"
                | "utSprache"
                | "pufferstufe"
                | "genreChips"
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_settings::MemoryStore;

    type Seen = Arc<Mutex<Vec<SettingsEffect>>>;

    fn vm_with(context: SettingsContext) -> (SettingsVm<Mem>, Seen, Arc<MemoryStore>) {
        let store = Arc::new(MemoryStore::new());
        let seen: Seen = Arc::default();
        let sink = Arc::clone(&seen);
        let vm = SettingsVm::new(
            Mem(Arc::clone(&store)),
            Locale::parse("de"),
            context,
            move |e| {
                sink.lock().unwrap().push(e);
            },
        );
        (vm, seen, store)
    }

    fn row(vm: &SettingsVm<Mem>, key: &str) -> Option<Row> {
        find(&vm.sections().sections, key).cloned()
    }

    fn on(vm: &SettingsVm<Mem>, key: &str) -> bool {
        matches!(
            row(vm, key).unwrap().control,
            RowControl::Switch { on: true }
        )
    }

    #[derive(Clone)]
    struct Mem(Arc<MemoryStore>);

    impl KeyValueStore for Mem {
        fn get(&self, key: &str) -> Option<swiftly_settings::Value> {
            self.0.get(key)
        }
        fn set(
            &self,
            key: &str,
            value: swiftly_settings::Value,
        ) -> Result<(), swiftly_settings::StoreError> {
            self.0.set(key, value)
        }
        fn remove(&self, key: &str) -> Result<(), swiftly_settings::StoreError> {
            self.0.remove(key)
        }
        fn keys(&self) -> Vec<String> {
            self.0.keys()
        }
    }

    #[test]
    fn defaults_and_german_titles() {
        let (vm, _, _) = vm_with(SettingsContext::default());
        let sections = vm.sections();
        let titles: Vec<_> = sections.sections.iter().map(|s| s.title_key).collect();
        assert_eq!(
            titles,
            [
                "Qualität",
                "Sprache",
                "Ablauf",
                "Im Player",
                "Filme und Serien",
                "Startseite",
                "Offline",
                "Server und Dienste",
                "Synchronisierung"
            ]
        );
        assert!(on(&vm, "immerDirectPlay"));
        assert!(!on(&vm, "technikschild"));
        assert!(on(&vm, "fortschritt"));
        assert_eq!(
            row(&vm, "vorSek").unwrap().control,
            RowControl::Choice {
                selected: "30".into(),
                shown: "30 s".into(),
                options: SPAN_LEVELS
                    .iter()
                    .map(|v| ChoiceOption {
                        value: v.to_string(),
                        label: format!("{v} s")
                    })
                    .collect(),
            }
        );
        assert_eq!(row(&vm, "Nope"), None);
    }

    #[test]
    fn switch_writes_store_and_rings_bell() {
        let (vm, seen, store) = vm_with(SettingsContext::default());
        let before = vm.version();
        vm.send(SettingsIntent::SetSwitch {
            key: "technikschild".into(),
            on: true,
        })
        .unwrap();
        assert!(on(&vm, "technikschild"));
        assert_eq!(store.get_bool("technikschild"), Some(true));
        assert!(vm.version() > before);
        assert_eq!(
            seen.lock().unwrap().as_slice(),
            [SettingsEffect::Changed {
                key: "technikschild".into(),
                synced: false
            }]
        );
        vm.send(SettingsIntent::SetSwitch {
            key: "fortschritt".into(),
            on: false,
        })
        .unwrap();
        assert!(matches!(
            seen.lock().unwrap().last(),
            Some(SettingsEffect::Changed { synced: true, .. })
        ));
    }

    #[test]
    fn choices_are_validated() {
        let (vm, _, store) = vm_with(SettingsContext::default());
        assert_eq!(
            vm.send(SettingsIntent::SetChoice {
                key: "vorSek".into(),
                value: "7".into()
            }),
            Err(Rejected::InvalidValue)
        );
        assert_eq!(
            vm.send(SettingsIntent::SetSwitch {
                key: "vorSek".into(),
                on: true
            }),
            Err(Rejected::InvalidValue)
        );
        assert_eq!(
            vm.send(SettingsIntent::SetSwitch {
                key: "gibtEsNicht".into(),
                on: true
            }),
            Err(Rejected::UnknownKey)
        );
        vm.send(SettingsIntent::SetChoice {
            key: "vorSek".into(),
            value: "15".into(),
        })
        .unwrap();
        assert_eq!(store.get_int("vorSek"), Some(15));
        vm.send(SettingsIntent::SetChoice {
            key: "tonSprache".into(),
            value: "Deutsch".into(),
        })
        .unwrap();
        assert_eq!(store.get_string("tonSprache").as_deref(), Some("Deutsch"));
    }

    #[test]
    fn choosing_a_subtitle_language_switches_automatic_on() {
        let (vm, _, store) = vm_with(SettingsContext::default());
        assert!(!on(&vm, "utAuto"));
        vm.send(SettingsIntent::SetChoice {
            key: "utSprache".into(),
            value: "Deutsch".into(),
        })
        .unwrap();
        assert!(on(&vm, "utAuto"));
        assert_eq!(store.get_bool("utAuto"), Some(true));
        // Back to "Aus" leaves the switch as it is; a user who turned it off keeps it off.
        vm.send(SettingsIntent::SetSwitch {
            key: "utAuto".into(),
            on: false,
        })
        .unwrap();
        vm.send(SettingsIntent::SetChoice {
            key: "utSprache".into(),
            value: String::new(),
        })
        .unwrap();
        assert!(!on(&vm, "utAuto"));
    }

    #[test]
    fn direct_play_locks_bitrate_and_is_per_server() {
        let ctx = SettingsContext {
            server: "https://a:8096".into(),
            ..Default::default()
        };
        let (vm, _, store) = vm_with(ctx);
        assert!(!row(&vm, "bitratenGrenze").unwrap().enabled);
        assert_eq!(
            vm.send(SettingsIntent::SetChoice {
                key: "bitratenGrenze".into(),
                value: "8".into()
            }),
            Err(Rejected::NotAllowed)
        );
        vm.send(SettingsIntent::SetSwitch {
            key: "immerDirectPlay".into(),
            on: false,
        })
        .unwrap();
        assert_eq!(
            store.get_bool("immerDirectPlay|https://a:8096"),
            Some(false)
        );
        assert_eq!(store.get_bool("immerDirectPlay"), None);
        let bitrate = row(&vm, "bitratenGrenze").unwrap();
        assert!(bitrate.enabled && bitrate.under.is_none());
        vm.send(SettingsIntent::SetChoice {
            key: "bitratenGrenze".into(),
            value: "8".into(),
        })
        .unwrap();
        assert_eq!(store.get_int("bitratenGrenze|https://a:8096"), Some(8));
        assert_eq!(
            row(&vm, "bitratenGrenze").unwrap().control,
            RowControl::Choice {
                selected: "8".into(),
                shown: "8 Mbit/s".into(),
                options: vm_options(&vm)
            }
        );
    }

    fn vm_options(vm: &SettingsVm<Mem>) -> Vec<ChoiceOption> {
        vm.inner.bitrate_options()
    }

    #[test]
    fn server_rows_exist_for_the_desktop_shell_only() {
        let (vm, _, _) = vm_with(SettingsContext::default());
        for k in ["serverInfo", "verbindungPruefen", "discordAnzeigen"] {
            assert!(
                row(&vm, k).is_none(),
                "{k} must stay hidden from the Apple bindings"
            );
        }
        let (vm, _, store) = vm_with(SettingsContext {
            server_rows: true,
            discord_presence: true,
            server_name: Some("Kino".into()),
            server_version: Some("10.10.3".into()),
            ..Default::default()
        });
        let info = row(&vm, "serverInfo").unwrap();
        assert_eq!(info.title, "Kino");
        assert_eq!(
            info.control,
            RowControl::Info {
                value: "10.10.3".into()
            }
        );
        let check = row(&vm, "verbindungPruefen").unwrap();
        assert_eq!(check.control, RowControl::Link { value: None });
        assert!(check.under.is_none() && check.enabled);
        let keys_in_order: Vec<_> = vm
            .sections()
            .sections
            .iter()
            .find(|s| s.title_key == "Server und Dienste")
            .unwrap()
            .rows
            .iter()
            .map(|r| r.key)
            .collect();
        assert_eq!(
            keys_in_order,
            [
                "serverInfo",
                "verbindungPruefen",
                "eigeneHeader",
                "seerr",
                "discordAnzeigen"
            ]
        );
        assert!(!on(&vm, "discordAnzeigen"));
        vm.send(SettingsIntent::SetSwitch {
            key: "discordAnzeigen".into(),
            on: true,
        })
        .unwrap();
        assert!(on(&vm, "discordAnzeigen"));
        assert_eq!(store.get_bool("discordAnzeigen"), Some(true));
        // Unknown server and a running check.
        let (vm, _, _) = vm_with(SettingsContext {
            server_rows: true,
            discord_presence: true,
            checking: true,
            check_result: Some("Erreichbar".into()),
            ..Default::default()
        });
        let info = row(&vm, "serverInfo").unwrap();
        assert_eq!(
            (info.title.as_str(), info.control),
            ("Server", RowControl::Info { value: "?".into() })
        );
        let check = row(&vm, "verbindungPruefen").unwrap();
        assert_eq!(
            check.control,
            RowControl::Link {
                value: Some("Moment…".into())
            }
        );
        assert_eq!(check.under.as_deref(), Some("Erreichbar"));
        assert!(!check.enabled);
    }

    #[test]
    fn mac_wording_and_groups_are_for_the_desktop_shell_only() {
        let order = |vm: &SettingsVm<Mem>| -> Vec<(&'static str, Vec<&'static str>)> {
            vm.sections()
                .sections
                .iter()
                .map(|s| (s.title_key, s.rows.iter().map(|r| r.key).collect()))
                .collect()
        };
        // Apple bindings: the groups and wording stay as they were.
        let (apple, _, _) = vm_with(SettingsContext::default());
        let titles: Vec<_> = order(&apple).into_iter().map(|(t, _)| t).collect();
        assert_eq!(
            titles[2..6],
            ["Ablauf", "Im Player", "Filme und Serien", "Startseite"]
        );
        assert_eq!(row(&apple, "utAussehen").unwrap().title, "Untertitel-Stil");
        assert_eq!(
            row(&apple, "alphabetAn").unwrap().title,
            "Alphabet in Listen"
        );
        assert_eq!(
            row(&apple, "technikschild").unwrap().under.as_deref(),
            Some("Zeigt Format und Bitrate im Player")
        );
        // Desktop: `PlaybackSettingsView` and `AppearanceView` of the Mac.
        let (mac, _, _) = vm_with(SettingsContext {
            server_rows: true,
            discord_presence: true,
            landscape_lock_possible: true,
            ..Default::default()
        });
        let groups = order(&mac);
        let behave = groups.iter().find(|(t, _)| *t == "Verhalten").unwrap();
        assert_eq!(
            behave.1,
            [
                "naechsteAuto",
                "introAbspannAuto",
                "technikschild",
                "endzeitImPlayer",
                "zurueckSek",
                "vorSek"
            ]
        );
        assert!(
            groups
                .iter()
                .all(|(t, _)| !matches!(*t, "Ablauf" | "Im Player" | "Filme und Serien"))
        );
        // The Mac's Appearance page has the Home rows ("Startseite") as a group of switches.
        assert!(
            groups
                .iter()
                .any(|(t, r)| *t == "Startseite" && r.len() >= 3)
        );
        assert!(
            groups
                .iter()
                .any(|(t, r)| *t == "Allgemein" && r.contains(&"titelAlsLogo"))
        );
        assert!(
            groups
                .iter()
                .any(|(t, r)| *t == "Neuzugänge" && *r == ["neuGetrennt"])
        );
        assert!(
            groups
                .iter()
                .any(|(t, r)| *t == "Genres" && *r == ["genreChips"])
        );
        assert!(
            !groups
                .iter()
                .flat_map(|(_, r)| r)
                .any(|k| *k == "querformatFest")
        );
        assert_eq!(
            row(&mac, "utAussehen").unwrap().title,
            "Aussehen der Untertitel"
        );
        assert_eq!(
            row(&mac, "introAbspannAuto").unwrap().title,
            "Intro und Abspann automatisch überspringen"
        );
        assert_eq!(row(&mac, "technikschild").unwrap().under, None);
        assert_eq!(
            row(&mac, "immerDirectPlay").unwrap().under.as_deref(),
            Some("Der Server wandelt nie um, es läuft immer die Originaldatei")
        );
        let bitrate = row(&mac, "bitratenGrenze").unwrap();
        assert!(
            !bitrate.enabled && bitrate.under.is_none(),
            "dimmed, no second line"
        );
    }

    #[test]
    fn server_that_cannot_convert_fixes_direct_play() {
        let ctx = SettingsContext {
            can_convert: false,
            ..Default::default()
        };
        let (vm, _, _) = vm_with(ctx);
        let direct = row(&vm, "immerDirectPlay").unwrap();
        assert!(!direct.enabled);
        assert_eq!(direct.control, RowControl::Switch { on: true });
        assert_eq!(
            vm.send(SettingsIntent::SetSwitch {
                key: "immerDirectPlay".into(),
                on: false
            }),
            Err(Rejected::NotAllowed)
        );
    }

    #[test]
    fn capability_and_platform_rows() {
        let ctx = SettingsContext {
            capabilities: Capabilities {
                seerr: false,
                settings_sync: false,
                downloads: true,
            },
            landscape_lock_possible: false,
            ..Default::default()
        };
        let (vm, _, _) = vm_with(ctx);
        assert!(row(&vm, "seerr").is_none());
        assert!(row(&vm, "einstellungenSync").is_none());
        assert!(row(&vm, "querformatFest").is_none());
        assert!(row(&vm, "gesehenVonAn").is_none());
        assert!(row(&vm, "bildrateAnpassen").is_none());
        assert_eq!(
            vm.send(SettingsIntent::SetSwitch {
                key: "einstellungenSync".into(),
                on: false
            }),
            Err(Rejected::NotAllowed)
        );
        let mut next = vm.sections().sections.len();
        vm.send(SettingsIntent::Context(Box::new(SettingsContext {
            watchers_plugin: true,
            platform: Platform::Tv,
            ..Default::default()
        })))
        .unwrap();
        assert!(row(&vm, "gesehenVonAn").is_some());
        assert!(row(&vm, "bildrateAnpassen").is_some());
        assert!(row(&vm, "querformatFest").is_none());
        assert!(row(&vm, "seerr").is_some());
        next = next.max(vm.sections().sections.len());
        assert!(next >= 9);
    }

    #[test]
    fn server_sync_toggle() {
        let (vm, seen, store) = vm_with(SettingsContext::default());
        assert!(on(&vm, "einstellungenSync"));
        vm.send(SettingsIntent::SetSwitch {
            key: "einstellungenSync".into(),
            on: false,
        })
        .unwrap();
        assert_eq!(store.get_bool("einstellungenSync"), Some(false));
        assert!(!on(&vm, "einstellungenSync"));
        assert_eq!(seen.lock().unwrap().len(), 1);
    }

    #[test]
    fn downloads_rows_depend_on_switch_and_ask_before_turning_off() {
        let (vm, seen, store) = vm_with(SettingsContext::default());
        assert!(row(&vm, "nurUeberWLAN").is_none());
        vm.send(SettingsIntent::SetSwitch {
            key: "downloadsAn".into(),
            on: true,
        })
        .unwrap();
        assert!(row(&vm, "nurUeberWLAN").is_some());
        assert!(row(&vm, "downloadsSpeicher").is_some());
        assert!(
            seen.lock()
                .unwrap()
                .contains(&SettingsEffect::DownloadsSwitched { on: true })
        );

        vm.send(SettingsIntent::Context(Box::new(SettingsContext {
            stored_downloads: 3,
            stored_bytes: 1_100_000_000,
            ..Default::default()
        })))
        .unwrap();
        let speicher = row(&vm, "downloadsSpeicher").unwrap();
        assert_eq!(speicher.under.as_deref(), Some("3 Titel auf diesem Gerät"));
        assert_eq!(
            speicher.control,
            RowControl::Info {
                value: "1,1 GB".into()
            }
        );

        vm.send(SettingsIntent::SetSwitch {
            key: "downloadsAn".into(),
            on: false,
        })
        .unwrap();
        assert_eq!(vm.status().confirm, Some(Confirm::DisableDownloads));
        assert_eq!(store.get_bool("downloadsAn"), Some(true));
        vm.send(SettingsIntent::CancelConfirm).unwrap();
        assert_eq!(vm.status().confirm, None);

        vm.send(SettingsIntent::SetSwitch {
            key: "downloadsAn".into(),
            on: false,
        })
        .unwrap();
        vm.send(SettingsIntent::ConfirmDisableDownloads { delete: true })
            .unwrap();
        assert_eq!(store.get_bool("downloadsAn"), Some(false));
        assert!(
            seen.lock()
                .unwrap()
                .contains(&SettingsEffect::DeleteDownloads)
        );
        assert!(row(&vm, "nurUeberWLAN").is_none());
        assert_eq!(
            vm.send(SettingsIntent::ConfirmDisableDownloads { delete: false }),
            Err(Rejected::NotAllowed)
        );
    }

    #[test]
    fn next_auto_follows_account_until_set() {
        let ctx = SettingsContext {
            account_next_auto: Some(false),
            ..Default::default()
        };
        let (vm, _, store) = vm_with(ctx);
        assert!(!on(&vm, "naechsteAuto"));
        vm.send(SettingsIntent::SetSwitch {
            key: "naechsteAuto".into(),
            on: true,
        })
        .unwrap();
        assert_eq!(store.get_bool("naechsteAuto"), Some(true));
        assert!(on(&vm, "naechsteAuto"));
    }

    #[test]
    fn reload_sees_outside_writes_and_english_titles() {
        let store = Arc::new(MemoryStore::new());
        let vm = SettingsVm::new(
            Mem(Arc::clone(&store)),
            Locale::parse("en"),
            SettingsContext::default(),
            |_| {},
        );
        let title = find(&vm.sections().sections, "technikschild")
            .unwrap()
            .title
            .clone();
        assert_ne!(title, "Technische Daten");
        let v = vm.version();
        store
            .set("technikschild", swiftly_settings::Value::Bool(true))
            .unwrap();
        vm.send(SettingsIntent::Reload).unwrap();
        assert!(vm.version() > v);
        assert!(on(&vm, "technikschild"));
        vm.send(SettingsIntent::Reload).unwrap();
        assert_eq!(vm.version(), v + 1);
    }

    #[test]
    fn home_rows_switch_off_and_move_among_the_shown_ones() {
        let ctx = SettingsContext {
            platform: Platform::Desktop,
            server_rows: true,
            discord_presence: true,
            capabilities: Capabilities::ALL,
            server: "srv".into(),
            ..SettingsContext::default()
        };
        let (vm, _seen, store) = vm_with(ctx);
        let rows = |vm: &SettingsVm<Mem>| -> Vec<(String, bool)> {
            vm.sections()
                .sections
                .iter()
                .find(|s| s.title_key == "Startseite")
                .map(|s| {
                    s.rows
                        .iter()
                        .map(|r| {
                            (
                                r.key.to_owned(),
                                matches!(r.control, RowControl::Switch { on: true }),
                            )
                        })
                        .collect()
                })
                .unwrap_or_default()
        };
        let first = rows(&vm);
        assert!(first.len() >= 3 && first.iter().all(|r| r.1), "{first:?}");
        // Off, and back on.
        vm.send(SettingsIntent::SetSwitch {
            key: first[0].0.clone(),
            on: false,
        })
        .unwrap();
        assert!(!rows(&vm)[0].1);
        assert_eq!(
            store.get("startAus"),
            Some(swiftly_settings::Value::StrList(vec![
                "weiterschauen".into()
            ]))
        );
        vm.send(SettingsIntent::SetSwitch {
            key: first[0].0.clone(),
            on: true,
        })
        .unwrap();
        assert!(rows(&vm)[0].1);
        // Down: the first row swaps with the second and the combined order is stored for this server.
        vm.send(SettingsIntent::MoveRow {
            key: first[0].0.clone(),
            delta: 1,
        })
        .unwrap();
        let moved = rows(&vm);
        assert_eq!(moved[0].0, first[1].0);
        assert_eq!(moved[1].0, first[0].0);
        assert!(store.get("startReihenfolge|srv").is_some());
        // Up at the top does nothing.
        vm.send(SettingsIntent::MoveRow {
            key: moved[0].0.clone(),
            delta: -1,
        })
        .unwrap();
        assert_eq!(rows(&vm), moved);
    }
}
