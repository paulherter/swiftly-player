#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = swiftly_jellyfin::normalize_server_url_string(&String::from_utf8_lossy(data));
});
