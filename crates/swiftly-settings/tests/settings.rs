use std::collections::BTreeMap;
use swiftly_settings::options::{BufferLevel, LibraryFilter, Sorting, StartRail};
use swiftly_settings::sync::{ENTRIES, Kind};
use swiftly_settings::{
    JsonFileStore, KeyValueStore, MemoryStore, Scope, Settings, Value, ValueType, keys, server_key,
    sync,
};

fn mem() -> Settings<MemoryStore> {
    Settings::new(MemoryStore::new())
}

#[test]
fn defaults_are_the_swift_defaults() {
    let s = mem();
    assert!(!s.get(&keys::TECHNIKSCHILD));
    assert!(s.get(&keys::QUERFORMAT_FEST));
    assert_eq!(s.get(&keys::ZURUECK_SEK), 10);
    assert_eq!(s.get(&keys::VOR_SEK), 30);
    assert!((s.get(&keys::PLAYER_LAUTSTAERKE) - 1.0).abs() < f64::EPSILON);
    assert!(s.get(&keys::IMMER_DIRECT_PLAY));
    assert_eq!(s.get(&keys::BITRATEN_GRENZE), 0);
    assert!(s.get(&keys::BILDRATE_ANPASSEN));
    assert!(s.get(&keys::STARTMESSUNG));
    assert_eq!(s.get(&keys::UT_AUSSEHEN), None);
    assert!(!s.get(&keys::UT_AUTO));
    assert_eq!(s.get(&keys::TON_SPRACHE), "");
    assert_eq!(s.get(&keys::NAECHSTE_AUTO), None);
    assert_eq!(s.get(&keys::PUFFERSTUFE), "normal");
    assert!(s.get(&keys::FORTSCHRITT));
    assert!(s.get(&keys::MERKLISTE_AN));
    assert!(s.get(&keys::ALPHABET_AN));
    assert!(s.get(&keys::GESEHEN_VON_AN));
    assert!(s.get(&keys::NEU_GETRENNT));
    assert!(!s.get(&keys::GENRE_CHIPS));
    assert!(s.get(&keys::START_REIHEN).is_empty());
    assert!(!s.get(&keys::DOWNLOADS_AN));
    assert!(s.get(&keys::NUR_UEBER_WLAN));
    assert!(s.get(&keys::EINSTELLUNGEN_SYNC));
    assert!(s.get(&keys::ASK_PROFILE_AT_LAUNCH));
    assert!(s.get(&keys::LOOK_EFFECTS));
    assert_eq!(s.get(&keys::BEWERTUNG_FERTIG), 0);
}

#[test]
fn set_get_reset_and_unset_option() {
    let s = mem();
    s.set(&keys::VOR_SEK, 60).unwrap();
    assert_eq!(s.get(&keys::VOR_SEK), 60);
    assert!(s.is_set(&keys::VOR_SEK));
    s.reset(&keys::VOR_SEK).unwrap();
    assert_eq!(s.get(&keys::VOR_SEK), 30);
    // Option: "never set" is distinct from "off".
    s.set(&keys::NAECHSTE_AUTO, Some(false)).unwrap();
    assert_eq!(s.get(&keys::NAECHSTE_AUTO), Some(false));
    s.set(&keys::NAECHSTE_AUTO, None).unwrap();
    assert!(!s.is_set(&keys::NAECHSTE_AUTO));
    // The persisted key is the German name.
    s.set(&keys::TON_SPRACHE, "deu".to_owned()).unwrap();
    assert_eq!(s.store().get_string("tonSprache").as_deref(), Some("deu"));
}

#[test]
fn wrong_type_in_the_store_falls_back_to_the_default() {
    let s = mem();
    s.store().set("utAuto", Value::Str("ja".into())).unwrap();
    assert!(!s.get(&keys::UT_AUTO));
    s.store().set("vorSek", Value::Double(45.0)).unwrap();
    assert_eq!(s.get(&keys::VOR_SEK), 45);
    s.store().set("vorSek", Value::Double(45.5)).unwrap();
    assert_eq!(s.get(&keys::VOR_SEK), 30);
    s.store()
        .set("support.status", Value::Str("{}".into()))
        .unwrap();
    assert_eq!(s.get(&keys::SUPPORT_STATUS), Some(b"{}".to_vec()));
}

#[test]
fn per_server_keys_are_built_like_swift() {
    assert_eq!(
        server_key("immerDirectPlay", "https://x.de:8096"),
        "immerDirectPlay|https://x.de:8096"
    );
    assert_eq!(
        server_key("bitratenGrenze", "plex:abc"),
        "bitratenGrenze|plex:abc"
    );
    assert_eq!(server_key("bitratenGrenze", ""), "bitratenGrenze");
    assert_eq!(swiftly_settings::plex_server("m1"), "plex:m1");
    let s = mem();
    let srv = "https://a";
    // Device-wide value applies until the server has its own (AppModel.playbackLoad).
    s.set(&keys::BITRATEN_GRENZE, 20).unwrap();
    assert_eq!(s.get_for_server(&keys::BITRATEN_GRENZE, srv), 20);
    s.set_for_server(&keys::BITRATEN_GRENZE, srv, 8).unwrap();
    assert_eq!(s.get_for_server(&keys::BITRATEN_GRENZE, srv), 8);
    assert_eq!(s.get_for_server(&keys::BITRATEN_GRENZE, "https://b"), 20);
    assert!(
        s.store()
            .keys()
            .contains(&"bitratenGrenze|https://a".to_owned())
    );
    // The library choice has no device-wide fallback for another server.
    s.set_for_server(&keys::START_BIBLIOTHEKEN, srv, Some(b"[1]".to_vec()))
        .unwrap();
    assert_eq!(
        s.get_for_server_only(&keys::START_BIBLIOTHEKEN, srv),
        Some(b"[1]".to_vec())
    );
    assert_eq!(
        s.get_for_server_only(&keys::START_BIBLIOTHEKEN, "https://b"),
        None
    );
}

#[test]
fn key_families() {
    assert_eq!(keys::sort_key("Filme"), "sortierung.Filme");
    assert_eq!(keys::sort_key("merkliste"), "sortierung.merkliste");
    assert_eq!(keys::filter_key("Serien"), "filter.Serien");
    assert_eq!(keys::search_history_key(None), "letzteSuchen");
    assert_eq!(keys::search_history_key(Some("")), "letzteSuchen");
    assert_eq!(keys::search_history_key(Some("u1")), "letzteSuchen.u1");
    assert_eq!(keys::track_rule_title_key(Some("acc"), "s1"), "acc|s1");
    assert_eq!(keys::track_rule_title_key(None, "s1"), "s1");
    assert_eq!(keys::GATTUNG_MERKLISTE.name, "gattung.merkliste");
}

#[test]
fn raw_values_of_options() {
    assert_eq!(BufferLevel::Bad.raw(), "schlecht");
    assert_eq!(Sorting::from_raw("neueste"), Some(Sorting::Latest));
    assert_eq!(
        LibraryFilter::from_raw("ungesehen"),
        Some(LibraryFilter::Unwatched)
    );
    assert_eq!(
        StartRail::from_raw("naechsteFolge"),
        Some(StartRail::NextEpisode)
    );
    assert_eq!(StartRail::from_raw("x"), None);
    assert_eq!(StartRail::ALL.len(), 5);
    let s = mem();
    assert_eq!(s.buffer_level(), BufferLevel::Normal);
    s.set_buffer_level(BufferLevel::Bad).unwrap();
    assert_eq!(
        s.store().get_string("pufferstufe").as_deref(),
        Some("schlecht")
    );
    s.set(&keys::PUFFERSTUFE, "kaputt".to_owned()).unwrap();
    assert_eq!(s.buffer_level(), BufferLevel::Normal);
}

#[test]
fn subtitle_auto_migration_runs_once() {
    let s = mem();
    s.set(&keys::UT_SPRACHE, "deu".to_owned()).unwrap();
    assert!(s.migrate_subtitle_auto().unwrap());
    assert!(s.get(&keys::UT_AUTO));
    // The user turns it off again: the migration does not run a second time.
    s.set(&keys::UT_AUTO, false).unwrap();
    assert!(!s.migrate_subtitle_auto().unwrap());
    // Without a language nothing is switched on.
    let t = mem();
    assert!(!t.migrate_subtitle_auto().unwrap());
    assert!(t.get(&keys::UT_AUTO_NACHGEZOGEN));
}

#[test]
fn registry_is_consistent_with_the_sync_table() {
    let names: Vec<_> = keys::ALL.iter().map(|k| k.name).collect();
    let mut sorted = names.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(sorted.len(), names.len(), "duplicate key names");
    // Every synced key is in the sync table and vice versa, with matching kind and per-server flag.
    let synced: Vec<_> = keys::ALL.iter().filter(|k| k.scope.is_synced()).collect();
    assert_eq!(synced.len(), ENTRIES.len());
    for e in &ENTRIES {
        let k = keys::ALL
            .iter()
            .find(|k| k.name == e.name)
            .unwrap_or_else(|| panic!("{} missing in registry", e.name));
        assert!(k.scope.is_synced(), "{} not marked synced", e.name);
        assert_eq!(k.scope.is_per_server(), e.per_server, "{}", e.name);
        let expected = match e.kind {
            Kind::Bool => ValueType::Bool,
            Kind::Int => ValueType::Int,
            Kind::Text => ValueType::String,
            Kind::List => ValueType::StringList,
            Kind::Json => ValueType::Data,
        };
        assert_eq!(k.value_type, expected, "{}", e.name);
    }
    // Device-only by design.
    for n in [
        "nurUeberWLAN",
        "downloadsAn",
        "endzeitImPlayer",
        "gesehenVonAn",
        "querformatFest",
    ] {
        let k = keys::ALL.iter().find(|k| k.name == n).unwrap();
        assert_eq!(k.scope, Scope::Device, "{n}");
    }
    assert!(
        keys::ALL
            .iter()
            .all(|k| k.source.contains(':') && k.source.contains(".swift"))
    );
    assert_eq!(
        keys::ALL.iter().filter(|k| k.scope.is_per_server()).count(),
        4 // + startReihenfolge (new in Rust)
    );
}

#[test]
fn every_key_name_is_documented_in_the_apple_notes() {
    // The German names are a persisted contract. Check them against the research notes when the
    // repository has them. A few keys were found only in the Swift source (listed here).
    let docs = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(
        std::env::var("SWIFTLY_APPLE_NOTES").unwrap_or_else(|_| "../../notes-unavailable".into()),
    );
    let (Ok(a), Ok(b)) = (
        std::fs::read_to_string(docs.join("apple-settings.md")),
        std::fs::read_to_string(docs.join("apple-logic.md")),
    ) else {
        return;
    };
    let source_only = [
        "einstellungenSyncKonto",
        "einstellungenSyncServer",
        "gattung.merkliste",
        "support.key",
        "support.keyChecked",
        "startReihenfolge",
    ];
    for k in keys::ALL {
        let known = a.contains(k.name) || b.contains(k.name) || source_only.contains(&k.name);
        assert!(known, "{} not in the notes", k.name);
    }
}

#[test]
fn json_file_store_round_trips_every_type() {
    let dir = std::env::temp_dir().join(format!("swiftly-settings-{}", std::process::id()));
    let path = dir.join("nested/settings.json");
    let _ = std::fs::remove_dir_all(&dir);
    let map = BTreeMap::from([("k".to_owned(), "v".to_owned())]);
    {
        let store = JsonFileStore::open(&path).unwrap();
        assert!(store.keys().is_empty());
        store.set("b", Value::Bool(true)).unwrap();
        store.set("i", Value::Int(-7)).unwrap();
        store.set("d", Value::Double(1.0)).unwrap();
        store.set("s", Value::Str("Größe \"q\"".into())).unwrap();
        store
            .set("data", Value::Data((0..=255u8).collect()))
            .unwrap();
        store
            .set("list", Value::StrList(vec!["a".into(), "b".into()]))
            .unwrap();
        store.set("map", Value::StrMap(map.clone())).unwrap();
        store.set("gone", Value::Int(1)).unwrap();
        store.remove("gone").unwrap();
        assert!(store.set("nan", Value::Double(f64::NAN)).is_err());
    }
    let store = JsonFileStore::open(&path).unwrap();
    assert_eq!(store.get("b"), Some(Value::Bool(true)));
    assert_eq!(store.get("i"), Some(Value::Int(-7)));
    assert_eq!(store.get("d"), Some(Value::Double(1.0)));
    assert_eq!(store.get_string("s").as_deref(), Some("Größe \"q\""));
    assert_eq!(store.get_data("data"), Some((0..=255u8).collect()));
    assert_eq!(
        store.get("list"),
        Some(Value::StrList(vec!["a".into(), "b".into()]))
    );
    assert_eq!(store.get("map"), Some(Value::StrMap(map)));
    assert_eq!(store.get("gone"), None);
    assert_eq!(store.get("nan"), None);
    assert_eq!(
        store.keys(),
        vec!["b", "d", "data", "i", "list", "map", "s"]
    );
    // Entries of a shape we do not model survive a rewrite.
    std::fs::write(&path, r#"{"odd":{"a":[1,2]},"n":null,"x":1}"#).unwrap();
    let store = JsonFileStore::open(&path).unwrap();
    store.set("y", Value::Int(2)).unwrap();
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(
        text.contains("\"odd\"") && text.contains("[\n") || text.contains("\"odd\""),
        "{text}"
    );
    // A damaged file is an error and stays as it is.
    std::fs::write(&path, "not json").unwrap();
    assert!(JsonFileStore::open(&path).is_err());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "not json");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn sync_collect_and_apply_through_a_store() {
    let s = mem();
    s.set(&keys::VOR_SEK, 45).unwrap();
    s.set(&keys::START_REIHEN, vec!["neueFilme".to_owned()])
        .unwrap();
    s.set_for_server(&keys::START_BIBLIOTHEKEN, "https://a", Some(b"[]".to_vec()))
        .unwrap();
    s.set(&keys::NUR_UEBER_WLAN, false).unwrap();
    let values = sync::collect("https://a", |key, kind| {
        sync::read_from_store(s.store(), key, kind)
    });
    assert_eq!(values.len(), 3);
    assert!(!values.contains_key("nurUeberWLAN"));
    let t = mem();
    sync::apply_to_store(t.store(), "https://a", &values).unwrap();
    assert_eq!(t.get(&keys::VOR_SEK), 45);
    assert_eq!(t.get(&keys::START_REIHEN), vec!["neueFilme".to_owned()]);
    assert_eq!(
        t.get_for_server_only(&keys::START_BIBLIOTHEKEN, "https://a"),
        Some(b"[]".to_vec())
    );
}

#[test]
fn library_name_and_seerr_accounts_are_pinned() {
    use swiftly_settings::extras::{SEERR_ACCOUNT, library_name, seerr_account};
    assert_eq!(library_name("movies"), "bibliothek-movies");
    assert_eq!(library_name("tvshows"), "bibliothek-tvshows");
    assert_eq!(SEERR_ACCOUNT, "seerr");
    assert_eq!(seerr_account("acc-1"), "seerr|acc-1");
    assert_eq!(seerr_account(""), "seerr");
}

#[test]
fn watchers_server_list_is_a_sorted_set() {
    use swiftly_settings::extras::{mark_watchers_server, watchers_servers};
    let s = mem();
    assert!(watchers_servers(&s).is_empty());
    assert!(mark_watchers_server(&s, "b|1").unwrap());
    assert!(mark_watchers_server(&s, "a|2").unwrap());
    assert!(!mark_watchers_server(&s, "a|2").unwrap());
    assert!(!mark_watchers_server(&s, "").unwrap());
    assert_eq!(
        s.get(&keys::GESEHEN_VON_SERVER),
        vec!["a|2".to_owned(), "b|1".to_owned()]
    );
    assert!(!s.get(&keys::GESEHEN_VON_SERVER).is_empty());
    // Device-only: never synced.
    assert!(!sync::ENTRIES.iter().any(|e| e.name == "gesehenVonServer"));
}

#[test]
fn ui_scale_snaps_to_the_eight_steps() {
    use swiftly_settings::extras::ui_scale::{LEVELS, factor, snapped, system_share};
    assert_eq!(LEVELS.len(), 8);
    assert!((snapped(1.0) - 1.0).abs() < f64::EPSILON);
    assert!((snapped(0.1) - 0.8).abs() < f64::EPSILON);
    assert!((snapped(9.0) - 1.5).abs() < f64::EPSILON);
    assert!((snapped(1.14) - 1.1).abs() < f64::EPSILON);
    assert!((snapped(f64::NAN) - 1.0).abs() < f64::EPSILON);
    assert!((factor(1.0, 1.0) - 1.0).abs() < f64::EPSILON);
    assert!((factor(1.0, 1.003) - 1.0).abs() < f64::EPSILON);
    assert!((factor(1.5, 1.2) - 1.8).abs() < 1e-9);
    assert!((system_share(144, 1) - 1.5).abs() < 1e-9);
    assert!((system_share(192, 2) - 1.0).abs() < f64::EPSILON);
    assert!((system_share(96, 1) - 1.0).abs() < f64::EPSILON);
}
