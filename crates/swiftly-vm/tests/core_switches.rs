//! "Leere Serien ausblenden" and "Löschen vom Server sperren": the settings rows, and what the core does with them.
//! One test body in this file: the two switches are process-wide, so nothing else may run beside it.

#![allow(clippy::unwrap_used)]

use std::sync::Arc;
use swiftly_l10n::Locale;
use swiftly_model::{ItemsResponse, switches};
use swiftly_settings::{KeyValueStore, MemoryStore, Settings, StoreError, Value, keys};
use swiftly_vm::{
    RowControl, SettingsContext, SettingsIntent, SettingsVm, apply_stored_settings, delete_offered,
};

const LIST: &str = r#"{"Items":[
  {"Id":"a","Name":"No seasons","Type":"Series","ChildCount":0},
  {"Id":"b","Name":"No episodes","Type":"Series","ChildCount":2,"RecursiveItemCount":0},
  {"Id":"c","Name":"Full","Type":"Series","ChildCount":2,"RecursiveItemCount":24},
  {"Id":"d","Name":"Film","Type":"Movie"},
  {"Id":"e","Name":"Not asked","Type":"Series"}
],"TotalRecordCount":5}"#;

/// A store two readers can hold.
#[derive(Clone, Default)]
struct Shared(Arc<MemoryStore>);

impl KeyValueStore for Shared {
    fn get(&self, key: &str) -> Option<Value> {
        self.0.get(key)
    }
    fn set(&self, key: &str, value: Value) -> Result<(), StoreError> {
        self.0.set(key, value)
    }
    fn remove(&self, key: &str) -> Result<(), StoreError> {
        self.0.remove(key)
    }
    fn keys(&self) -> Vec<String> {
        self.0.keys()
    }
}

fn ids() -> Vec<String> {
    let list: ItemsResponse = serde_json::from_str(LIST).unwrap();
    list.items.into_iter().map(|i| i.id).collect()
}

fn vm(context: SettingsContext) -> SettingsVm<Shared> {
    SettingsVm::new(Shared::default(), Locale::parse("de"), context, |_| {})
}

fn switch_on(vm: &SettingsVm<Shared>, key: &str) -> Option<bool> {
    vm.sections()
        .sections
        .iter()
        .flat_map(|s| s.rows.iter())
        .find(|r| r.key == key)
        .map(|r| match r.control {
            RowControl::Switch { on } => on,
            _ => panic!("{key} is no switch"),
        })
}

fn set(vm: &SettingsVm<Shared>, key: &str, on: bool) {
    vm.send(SettingsIntent::SetSwitch {
        key: key.to_owned(),
        on,
    })
    .unwrap();
}

#[test]
fn the_two_switches_drive_the_core_for_every_list_and_every_delete_entry() {
    // Defaults: empty series hidden, deleting open.
    let v = vm(SettingsContext::default());
    assert_eq!(switch_on(&v, "leereSerienAusblenden"), Some(true));
    assert_eq!(switch_on(&v, "loeschenSperren"), Some(false));
    assert_eq!(
        ids(),
        ["c", "d", "e"],
        "no seasons and no episodes are hidden; unknown counts stay"
    );
    assert!(delete_offered(true));
    assert!(
        !delete_offered(false),
        "without the right nothing is offered"
    );

    // Showing empty series again.
    set(&v, "leereSerienAusblenden", false);
    assert_eq!(switch_on(&v, "leereSerienAusblenden"), Some(false));
    assert_eq!(ids(), ["a", "b", "c", "d", "e"]);
    set(&v, "leereSerienAusblenden", true);
    assert_eq!(ids(), ["c", "d", "e"]);

    // The lock takes the delete entry away for an account that holds the right.
    set(&v, "loeschenSperren", true);
    assert_eq!(switch_on(&v, "loeschenSperren"), Some(true));
    assert!(switches::server_delete_locked());
    assert!(!delete_offered(true));
    set(&v, "loeschenSperren", false);
    assert!(delete_offered(true));

    // A relaunch: the store holds both values, the process starts with the defaults, and no settings page opens. The
    // start call alone puts the saved values into effect (this failed while only the settings view model loaded them).
    let saved = Shared::default();
    let stored = Settings::new(saved.clone());
    stored.set(&keys::LEERE_SERIEN_AUSBLENDEN, false).unwrap();
    stored.set(&keys::LOESCHEN_SPERREN, true).unwrap();
    switches::set_hide_empty_series(true);
    switches::set_server_delete_locked(false);
    assert_eq!(ids(), ["c", "d", "e"], "before the start call: defaults");
    apply_stored_settings(&stored);
    assert_eq!(
        ids().len(),
        5,
        "saved 'off' shows the empty series from the first list on"
    );
    assert!(
        !delete_offered(true),
        "saved lock holds from the first call on"
    );
    // A store that never saw the switches keeps the defaults at start.
    apply_stored_settings(&Settings::new(Shared::default()));
    assert_eq!(ids(), ["c", "d", "e"]);
    assert!(delete_offered(true));
    // The start also does the one-time subtitle migration: a language chosen before the switch existed turns it on.
    let old_install = Shared::default();
    let old_settings = Settings::new(old_install.clone());
    old_settings
        .set(&keys::UT_SPRACHE, "deu".to_owned())
        .unwrap();
    old_settings.set(&keys::UT_AUTO, false).unwrap();
    apply_stored_settings(&old_settings);
    assert!(old_settings.get(&keys::UT_AUTO));
    assert!(old_settings.get(&keys::UT_AUTO_NACHGEZOGEN));

    // A device that stored both values hands them to the core when its settings open.
    let store = Shared::default();
    let settings = Settings::new(store.clone());
    settings.set(&keys::LEERE_SERIEN_AUSBLENDEN, false).unwrap();
    settings.set(&keys::LOESCHEN_SPERREN, true).unwrap();
    let _started = SettingsVm::new(
        store,
        Locale::parse("de"),
        SettingsContext::default(),
        |_| {},
    );
    assert_eq!(ids().len(), 5);
    assert!(!delete_offered(true));

    // Without Seerr there is nothing to lock, so the row is not shown.
    let mut no_seerr = SettingsContext::default();
    no_seerr.capabilities.seerr = false;
    assert_eq!(switch_on(&vm(no_seerr), "loeschenSperren"), None);

    // Leave the process as found.
    switches::set_hide_empty_series(true);
    switches::set_server_delete_locked(false);
}
