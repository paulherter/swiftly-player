#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(item) = serde_json::from_slice::<swiftly_model::Item>(data) {
        let text = serde_json::to_vec(&item).expect("encode");
        let again: swiftly_model::Item = serde_json::from_slice(&text).expect("re-decode");
        assert_eq!(item, again);
    }
});
