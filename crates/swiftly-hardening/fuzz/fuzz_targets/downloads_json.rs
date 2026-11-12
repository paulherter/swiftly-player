#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = swiftly_downloads::decode_list(data);
    let _ = swiftly_downloads::load_list(Some(data));
});
