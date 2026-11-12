#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let text = String::from_utf8_lossy(data);
    if let Ok(url) = swiftly_images::Url::parse(&text) {
        let _ = swiftly_images::store_key(&url);
        let _ = swiftly_images::image_key(&url);
    }
    let _ = swiftly_jellyfin::normalize_server_url_string(&text);
});
