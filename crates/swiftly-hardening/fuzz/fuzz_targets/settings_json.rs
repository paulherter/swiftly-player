#![no_main]
use libfuzzer_sys::fuzz_target;
use swiftly_settings::sync::{Kind, SyncValue};

fuzz_target!(|data: &[u8]| {
    let text = String::from_utf8_lossy(data);
    for kind in [Kind::Bool, Kind::Int, Kind::Text, Kind::List, Kind::Json] {
        let _ = SyncValue::decode(&text, kind);
    }
    if let Ok(v) = serde_json::from_slice::<serde_json::Value>(data) {
        let _ = swiftly_settings::store::value_from_json(&v);
    }
    // The file the settings are loaded from at startup: a corrupt one must be an error, never a panic.
    let path = std::env::temp_dir().join(format!("swiftly-fuzz-settings-{}.json", std::process::id()));
    if std::fs::write(&path, data).is_ok() {
        let _ = swiftly_settings::JsonFileStore::open(&path);
    }
});
