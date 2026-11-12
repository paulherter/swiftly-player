#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = serde_json::from_slice::<swiftly_model::PlaybackInfoResponse>(data);
    let _ = serde_json::from_slice::<swiftly_model::MediaSource>(data);
});
