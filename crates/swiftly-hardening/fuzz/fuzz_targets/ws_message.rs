#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let text = String::from_utf8_lossy(data);
    let _ = swiftly_cache::parse_ws(&text);
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
        let _ = swiftly_sync::syncplay::SyncPlayGroup::from_json(&v);
    }
});
