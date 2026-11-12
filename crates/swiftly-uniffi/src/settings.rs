//! The exported settings view model (`swiftly_vm::SettingsVm`). The values live in the host's
//! key-value store (typed values are packed as bytes, see `TypedStore`); the effects the vm
//! raises are queued for the host (`take_effects`).

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, PoisonError};

use swiftly_l10n::Locale;
use swiftly_settings::{KeyValueStore as TypedKv, StoreError, Value};
use swiftly_vm::{
    Capabilities, Change, Confirm, Platform as VmPlatform, Rejected, RowControl, SettingsContext,
    SettingsEffect, SettingsIntent as VmIntent,
};

use crate::error::CoreError;
use crate::stores::KeyValueStore;

const PREFIX: &str = "setting.";
const INDEX: &str = "setting.index";

/// Typed settings over the byte store: one tag byte, then the payload.
pub(crate) struct TypedStore {
    kv: Arc<dyn KeyValueStore>,
    keys: Mutex<Option<Vec<String>>>,
}

/// A stored setting value as the host (`UserDefaults`) holds it.
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum SettingValue {
    Bool { value: bool },
    Int { value: i64 },
    Double { value: f64 },
    Text { value: String },
    Data { value: Vec<u8> },
    List { value: Vec<String> },
    Map { value: HashMap<String, String> },
}

/// Typed settings the host stores natively. Apple: `UserDefaults` (standard or the app-group
/// suite), the same keys and types the `@AppStorage` screens use, so core and screens share values.
#[uniffi::export(with_foreign)]
pub trait SettingsStore: Send + Sync {
    fn get(&self, key: String) -> Option<SettingValue>;
    fn set(&self, key: String, value: SettingValue);
    fn remove(&self, key: String);
    /// Every key the host holds (the vm lists them for settings sync).
    fn keys(&self) -> Vec<String>;
}

impl From<SettingValue> for Value {
    fn from(v: SettingValue) -> Self {
        match v {
            SettingValue::Bool { value } => Self::Bool(value),
            SettingValue::Int { value } => Self::Int(value),
            SettingValue::Double { value } => Self::Double(value),
            SettingValue::Text { value } => Self::Str(value),
            SettingValue::Data { value } => Self::Data(value),
            SettingValue::List { value } => Self::StrList(value),
            SettingValue::Map { value } => Self::StrMap(value.into_iter().collect()),
        }
    }
}

impl From<&Value> for SettingValue {
    fn from(v: &Value) -> Self {
        match v {
            Value::Bool(value) => Self::Bool { value: *value },
            Value::Int(value) => Self::Int { value: *value },
            Value::Double(value) => Self::Double { value: *value },
            Value::Str(value) => Self::Text {
                value: value.clone(),
            },
            Value::Data(value) => Self::Data {
                value: value.clone(),
            },
            Value::StrList(value) => Self::List {
                value: value.clone(),
            },
            Value::StrMap(value) => Self::Map {
                value: value.iter().map(|(k, v)| (k.clone(), v.clone())).collect(),
            },
        }
    }
}

/// What the vm reads and writes: the byte store (packed) or the host's typed store.
pub(crate) enum Backing {
    Packed(TypedStore),
    Native(Arc<dyn SettingsStore>),
}

impl TypedKv for Backing {
    fn get(&self, key: &str) -> Option<Value> {
        match self {
            Self::Packed(s) => s.get(key),
            Self::Native(s) => s.get(key.to_owned()).map(Value::from),
        }
    }
    fn set(&self, key: &str, value: Value) -> Result<(), StoreError> {
        match self {
            Self::Packed(s) => s.set(key, value),
            Self::Native(s) => {
                if matches!(value, Value::Double(d) if !d.is_finite()) {
                    return Err(StoreError::Unsupported(format!(
                        "{key}: not a finite number"
                    )));
                }
                s.set(key.to_owned(), SettingValue::from(&value));
                Ok(())
            }
        }
    }
    fn remove(&self, key: &str) -> Result<(), StoreError> {
        match self {
            Self::Packed(s) => s.remove(key),
            Self::Native(s) => {
                s.remove(key.to_owned());
                Ok(())
            }
        }
    }
    fn keys(&self) -> Vec<String> {
        match self {
            Self::Packed(s) => s.keys(),
            Self::Native(s) => s.keys(),
        }
    }
}

impl TypedStore {
    pub(crate) fn new(kv: Arc<dyn KeyValueStore>) -> Self {
        Self {
            kv,
            keys: Mutex::new(None),
        }
    }

    fn index(&self) -> Vec<String> {
        if let Some(known) = self
            .keys
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
        {
            return known;
        }
        // The store is foreign code: read it without holding the lock.
        let loaded: Vec<String> = self
            .kv
            .get(INDEX.to_owned())
            .and_then(|b| String::from_utf8(b).ok())
            .map(|t| t.lines().map(str::to_owned).collect())
            .unwrap_or_default();
        let mut guard = self.keys.lock().unwrap_or_else(PoisonError::into_inner);
        guard.get_or_insert(loaded).clone()
    }

    fn save_index(&self, keys: Vec<String>) {
        self.kv.set(INDEX.to_owned(), keys.join("\n").into_bytes());
        *self.keys.lock().unwrap_or_else(PoisonError::into_inner) = Some(keys);
    }
}

fn encode(value: &Value) -> Vec<u8> {
    let (tag, body): (u8, Vec<u8>) = match value {
        Value::Bool(b) => (b'b', vec![u8::from(*b)]),
        Value::Int(i) => (b'i', i.to_le_bytes().to_vec()),
        Value::Double(d) => (b'd', d.to_le_bytes().to_vec()),
        Value::Str(s) => (b's', s.as_bytes().to_vec()),
        Value::Data(d) => (b'x', d.clone()),
        Value::StrList(l) => (b'l', l.join("\u{1f}").into_bytes()),
        Value::StrMap(m) => (
            b'm',
            m.iter()
                .map(|(k, v)| format!("{k}\u{1e}{v}"))
                .collect::<Vec<_>>()
                .join("\u{1f}")
                .into_bytes(),
        ),
    };
    let mut out = vec![tag];
    out.extend(body);
    out
}

fn decode(bytes: &[u8]) -> Option<Value> {
    let (tag, body) = bytes.split_first()?;
    let text = || String::from_utf8(body.to_vec()).ok();
    Some(match tag {
        b'b' => Value::Bool(*body.first()? != 0),
        b'i' => Value::Int(i64::from_le_bytes(body.try_into().ok()?)),
        b'd' => Value::Double(f64::from_le_bytes(body.try_into().ok()?)),
        b's' => Value::Str(text()?),
        b'x' => Value::Data(body.to_vec()),
        b'l' => {
            let t = text()?;
            Value::StrList(if t.is_empty() {
                Vec::new()
            } else {
                t.split('\u{1f}').map(str::to_owned).collect()
            })
        }
        b'm' => {
            let t = text()?;
            let mut map = BTreeMap::new();
            for pair in t.split('\u{1f}').filter(|p| !p.is_empty()) {
                let (k, v) = pair.split_once('\u{1e}')?;
                map.insert(k.to_owned(), v.to_owned());
            }
            Value::StrMap(map)
        }
        _ => return None,
    })
}

impl TypedKv for TypedStore {
    fn get(&self, key: &str) -> Option<Value> {
        decode(&self.kv.get(format!("{PREFIX}{key}"))?)
    }
    fn set(&self, key: &str, value: Value) -> Result<(), StoreError> {
        self.kv.set(format!("{PREFIX}{key}"), encode(&value));
        let mut keys = self.index();
        if !keys.iter().any(|k| k == key) {
            keys.push(key.to_owned());
            keys.sort();
            self.save_index(keys);
        }
        Ok(())
    }
    fn remove(&self, key: &str) -> Result<(), StoreError> {
        self.kv.remove(format!("{PREFIX}{key}"));
        let mut keys = self.index();
        if keys.iter().any(|k| k == key) {
            keys.retain(|k| k != key);
            self.save_index(keys);
        }
        Ok(())
    }
    fn keys(&self) -> Vec<String> {
        self.index()
    }
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SettingsPlatform {
    Phone,
    Tablet,
    Desktop,
    Tv,
}

/// What the host knows that the store does not; send a new one whenever it changes.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SettingsFacts {
    pub platform: SettingsPlatform,
    pub seerr: bool,
    pub settings_sync: bool,
    pub downloads: bool,
    pub server: String,
    pub can_convert: bool,
    pub watchers_plugin: bool,
    pub landscape_lock_possible: bool,
    pub seerr_connected: bool,
    pub own_headers: u32,
    pub subtitle_look_summary: String,
    pub stored_downloads: u32,
    pub stored_bytes: i64,
    pub account_next_auto: Option<bool>,
}

impl From<SettingsFacts> for SettingsContext {
    fn from(f: SettingsFacts) -> Self {
        Self {
            platform: match f.platform {
                SettingsPlatform::Phone => VmPlatform::Phone,
                SettingsPlatform::Tablet => VmPlatform::Tablet,
                SettingsPlatform::Desktop => VmPlatform::Desktop,
                SettingsPlatform::Tv => VmPlatform::Tv,
            },
            capabilities: Capabilities {
                seerr: f.seerr,
                settings_sync: f.settings_sync,
                downloads: f.downloads,
            },
            server: f.server,
            can_convert: f.can_convert,
            watchers_plugin: f.watchers_plugin,
            landscape_lock_possible: f.landscape_lock_possible,
            seerr_connected: f.seerr_connected,
            own_headers: f.own_headers as usize,
            subtitle_look_summary: f.subtitle_look_summary,
            stored_downloads: f.stored_downloads as usize,
            stored_bytes: f.stored_bytes,
            account_next_auto: f.account_next_auto,
            ..Self::default()
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct SettingsOption {
    pub value: String,
    pub label: String,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum SettingsControl {
    Switch {
        on: bool,
    },
    Choice {
        selected: String,
        shown: String,
        options: Vec<SettingsOption>,
    },
    Info {
        value: String,
    },
    Link {
        value: Option<String>,
    },
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SettingsRow {
    pub key: String,
    pub title_key: String,
    pub title: String,
    pub under: Option<String>,
    pub control: SettingsControl,
    pub enabled: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SettingsSection {
    pub title_key: String,
    pub title: String,
    pub rows: Vec<SettingsRow>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SettingsSections {
    pub version: u64,
    pub sections: Vec<SettingsSection>,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SettingsConfirm {
    DisableDownloads,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct SettingsStatus {
    pub version: u64,
    pub confirm: Option<SettingsConfirm>,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum SettingsIntent {
    SetSwitch { key: String, on: bool },
    SetChoice { key: String, value: String },
    ConfirmDisableDownloads { delete: bool },
    CancelConfirm,
    Facts { facts: SettingsFacts },
    Reload,
}

/// What the host must do after a change.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum SettingsEffectOut {
    Changed { key: String, synced: bool },
    DownloadsSwitched { on: bool },
    DeleteDownloads,
}

/// Bit of `Change.parts`: the sections.
#[uniffi::export]
pub fn part_settings_sections() -> u32 {
    swiftly_vm::settings_part::SECTIONS
}

/// Bit of `Change.parts`: the pending question.
#[uniffi::export]
pub fn part_settings_status() -> u32 {
    swiftly_vm::settings_part::STATUS
}

type Effects = Arc<Mutex<Vec<SettingsEffectOut>>>;

#[derive(uniffi::Object)]
pub struct SettingsVm {
    vm: swiftly_vm::SettingsVm<Backing>,
    effects: Effects,
}

impl SettingsVm {
    pub(crate) fn new(kv: Arc<dyn KeyValueStore>, locale: &str, facts: SettingsFacts) -> Arc<Self> {
        Self::with_backing(Backing::Packed(TypedStore::new(kv)), locale, facts)
    }

    pub(crate) fn native(
        store: Arc<dyn SettingsStore>,
        locale: &str,
        facts: SettingsFacts,
    ) -> Arc<Self> {
        // The one-time `utAuto` migration (AppModel.swift:683); done at most once per install.
        crate::rules::migrate_on(Backing::Native(Arc::clone(&store)));
        Self::with_backing(Backing::Native(store), locale, facts)
    }

    fn with_backing(backing: Backing, locale: &str, facts: SettingsFacts) -> Arc<Self> {
        let effects: Effects = Arc::default();
        let sink = Arc::clone(&effects);
        let vm = swiftly_vm::SettingsVm::new(
            backing,
            Locale::parse(locale),
            facts.into(),
            move |effect| {
                sink.lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push(match effect {
                        SettingsEffect::Changed { key, synced } => {
                            SettingsEffectOut::Changed { key, synced }
                        }
                        SettingsEffect::DownloadsSwitched { on } => {
                            SettingsEffectOut::DownloadsSwitched { on }
                        }
                        SettingsEffect::DeleteDownloads => SettingsEffectOut::DeleteDownloads,
                    });
            },
        );
        Arc::new(Self { vm, effects })
    }
}

#[uniffi::export]
impl SettingsVm {
    pub fn version(&self) -> u64 {
        self.vm.version()
    }

    pub fn sections(&self) -> SettingsSections {
        let part = self.vm.sections();
        SettingsSections {
            version: part.version,
            sections: part
                .sections
                .iter()
                .map(|s| SettingsSection {
                    title_key: s.title_key.to_owned(),
                    title: s.title.clone(),
                    rows: s
                        .rows
                        .iter()
                        .map(|r| SettingsRow {
                            key: r.key.to_owned(),
                            title_key: r.title_key.to_owned(),
                            title: r.title.clone(),
                            under: r.under.clone(),
                            enabled: r.enabled,
                            control: match &r.control {
                                RowControl::Switch { on } => SettingsControl::Switch { on: *on },
                                RowControl::Choice {
                                    selected,
                                    shown,
                                    options,
                                } => SettingsControl::Choice {
                                    selected: selected.clone(),
                                    shown: shown.clone(),
                                    options: options
                                        .iter()
                                        .map(|o| SettingsOption {
                                            value: o.value.clone(),
                                            label: o.label.clone(),
                                        })
                                        .collect(),
                                },
                                RowControl::Info { value } => SettingsControl::Info {
                                    value: value.clone(),
                                },
                                RowControl::Link { value } => SettingsControl::Link {
                                    value: value.clone(),
                                },
                            },
                        })
                        .collect(),
                })
                .collect(),
        }
    }

    pub fn status(&self) -> SettingsStatus {
        let part = self.vm.status();
        SettingsStatus {
            version: part.version,
            confirm: part
                .confirm
                .map(|Confirm::DisableDownloads| SettingsConfirm::DisableDownloads),
        }
    }

    /// An intent. A refused one (unknown, hidden or dimmed row, value not offered) throws and
    /// changes nothing.
    pub fn send(&self, intent: SettingsIntent) -> Result<(), CoreError> {
        let intent = match intent {
            SettingsIntent::SetSwitch { key, on } => VmIntent::SetSwitch { key, on },
            SettingsIntent::SetChoice { key, value } => VmIntent::SetChoice { key, value },
            SettingsIntent::ConfirmDisableDownloads { delete } => {
                VmIntent::ConfirmDisableDownloads { delete }
            }
            SettingsIntent::CancelConfirm => VmIntent::CancelConfirm,
            SettingsIntent::Facts { facts } => VmIntent::Context(Box::new(facts.into())),
            SettingsIntent::Reload => VmIntent::Reload,
        };
        self.vm.send(intent).map_err(|rejected| CoreError::Failed {
            message: match rejected {
                Rejected::UnknownKey => "unknown setting".to_owned(),
                Rejected::NotAllowed => "setting not allowed".to_owned(),
                Rejected::InvalidValue => "invalid value".to_owned(),
                Rejected::Store(m) => m,
            },
        })
    }

    /// What the host must do; empties the list.
    pub fn take_effects(&self) -> Vec<SettingsEffectOut> {
        std::mem::take(&mut self.effects.lock().unwrap_or_else(PoisonError::into_inner))
    }

    #[uniffi::method(async_runtime = "tokio")]
    pub async fn changed(&self, seen: u64) -> Result<Change, CoreError> {
        Ok(self.vm.changed(seen).await)
    }
}
